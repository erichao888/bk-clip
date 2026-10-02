//
//  BKAudioAnalyzer.swift
//  bk剪辑 — 音频包络提取
//
//  【职责】把视频里的音轨读成一条 dB 包络曲线。这是检测的唯一输入：
//  没有包络，一切静音检测都是空谈。
//
//  【和 Python 版的对应关系】
//  tools/preview_cut.py 里是 ffmpeg 抽 16k 单声道 PCM 再算短时 RMS；
//  这里用 AVAssetReader 做同一件事：解码 → Float32 → 前缀和 → RMS → dB。
//  采样率、窗长、跳距全部来自 BKConfig，与 Python 逐项一致。
//
//  【为什么用前缀和】
//  每个窗都现场求平方和是 O(n × frame)，10 分钟素材就是几十亿次乘加。
//  前缀和把每个窗变成一次减法，O(n) 一遍过 —— Python 版同款思路。
//
//  【内存账】10 分钟 16k 单声道 Float32 ≈ 38MB，前缀和（Double）再翻一倍，
//  仍在 BKConfig.Limit.memoryWarnMB 之内。小时级素材暂不支持，超了会卡。
//

import Foundation
import AVFoundation

enum BKAudioAnalyzer {

    /// 后台提取，完成后回主线程。失败给明确原因，不给一句笼统的「出错了」
    static func extractEnvelope(from asset: AVAsset,
                                completion: @escaping (Result<BKEnvelope, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let env = try extractSync(from: asset)
                DispatchQueue.main.async { completion(.success(env)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - 同步实现（后台线程调用）

    private static func extractSync(from asset: AVAsset) throws -> BKEnvelope {
        let sr = Double(BKConfig.Envelope.sampleRate)

        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw BKAnalyzerError.noAudioTrack
        }

        // 与 Python 端 -ac 1 -ar 16000 -f s16le 对齐：
        // 单声道、分析采样率、32bit 浮点（比 16bit 省一次转换）
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        // 注意：add(_:) 返回 Void，能返回 Bool 预检的是 canAdd(_:) ——
        // CI 第一次编译就在这里栽了（"cannot convert Void to Bool"）
        guard reader.canAdd(output) else {
            throw BKAnalyzerError.readerSetupFailed
        }
        reader.add(output)
        guard reader.startReading() else {
            throw BKAnalyzerError.readFailed(reader.error?.localizedDescription ?? "未知原因")
        }

        var samples: [Float] = []
        // 用 copyNextSampleBuffer 返回 nil 作为结束标志，而不是查 output.status：
        // 后者在某些素材上拿到的是 .unknown，会让这个循环一次都不进，
        // 最终报「音轨内容为空」——一个和真实原因毫不相干的错
        while let sb = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sb) {
                var totalLength = 0
                var dataPointer: UnsafeMutablePointer<Int8>? = nil
                let status = CMBlockBufferGetDataPointer(block,
                                                         atOffset: 0,
                                                         lengthAtOffsetOut: nil,
                                                         totalLengthOut: &totalLength,
                                                         dataPointerOut: &dataPointer)
                if status == kCMBlockBufferNoErr, let ptr = dataPointer, totalLength > 0 {
                    let count = totalLength / MemoryLayout<Float>.size
                    samples.reserveCapacity(samples.count + count)
                    ptr.withMemoryRebound(to: Float.self, capacity: count) { floatPtr in
                        samples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: count))
                    }
                }
            }
            CMSampleBufferInvalidate(sb)
        }

        guard reader.status == .completed else {
            throw BKAnalyzerError.readFailed(reader.error?.localizedDescription ?? "提前结束")
        }
        guard !samples.isEmpty else {
            throw BKAnalyzerError.emptyAudio
        }

        let envelope = BKLog.measure("包络提取") { buildEnvelope(samples: samples, sampleRate: sr) }
        BKLog.shared.i("包络：\(samples.count) 采样 → \(envelope.frames.count) 帧 · \(String(format: "%.2f", envelope.duration))s")
        return envelope
    }

    // MARK: - RMS 包络（与 preview_cut.py 的 rms_envelope / to_db 逐行对齐）

    /// 这一函数不依赖 AVFoundation，逻辑已用 tools/verify_detector_port.py 与 Python 对照验证
    static func buildEnvelope(samples: [Float], sampleRate: Double) -> BKEnvelope {
        let frame = max(1, Int(sampleRate * Double(BKConfig.Envelope.frameMs) / 1000.0))
        let hop = max(1, Int(sampleRate * Double(BKConfig.Envelope.hopMs) / 1000.0))
        let n = samples.count

        // 前缀和。AAC 解码理论上不会出 NaN，但一个 NaN 就会污染之后所有前缀和，
        // 这里花一次遍历买保险
        var cum = [Double](repeating: 0, count: n + 1)
        for i in 0..<n {
            let v = samples[i]
            let s = v.isFinite ? Double(v) : 0
            cum[i + 1] = cum[i] + s * s
        }

        var frames: [Float] = []
        if n < frame {
            // 素材比一个窗还短：整段算一个值（Python 版同款兜底）
            let mean = cum[n] / Double(max(n, 1))
            frames.append(Float(20.0 * log10(max(sqrt(mean + 1e-12), 1e-7))))
        } else {
            let count = (n - frame) / hop + 1
            frames.reserveCapacity(count)
            var start = 0
            while start <= n - frame {
                let sum = cum[start + frame] - cum[start]
                let rms = sqrt(sum / Double(frame) + 1e-12)
                frames.append(Float(20.0 * log10(max(rms, 1e-7))))
                start += hop
            }
        }

        return BKEnvelope(frames: frames,
                          hopSec: Double(hop) / sampleRate,
                          sampleRate: sampleRate,
                          duration: Double(n) / sampleRate)
    }
}

// MARK: - 错误定义

enum BKAnalyzerError: LocalizedError {
    case noAudioTrack
    case readerSetupFailed
    case readFailed(String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:        return "素材没有音轨"
        case .readerSetupFailed:   return "音频读取器初始化失败"
        case .readFailed(let m):   return "音频读取失败：\(m)"
        case .emptyAudio:          return "音轨内容为空"
        }
    }
}
