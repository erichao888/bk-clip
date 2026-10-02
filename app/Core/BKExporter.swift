//
//  BKExporter.swift
//  bk剪辑 — 导出（第三批）
//
//  【策略：直通转封装，不重编码】
//  读出源素材原始的 H.264 / AAC 压缩数据，按保留段拼接后原样写进新 MP4。
//  好处有三：
//  1. 画质零损失（重编码的 CRF20 再高也是有损）
//  2. 导出速度快一个量级（不碰像素，只搬字节）
//  3. 剪映兼容性 = 源素材本身的兼容性 —— 源是 iPhone 拍的，剪映必然吃得下
//  代价：GOP 继承源素材（没法控制关键帧间隔），接缝落在最近的帧边界上
//  （60fps 素材最多偏 16ms，肉眼不可见）。
//
//  【已知取舍 v1】接缝不做 15ms 淡入淡出（Python 版 preview_cut.py 有）。
//  做淡入淡出必须把音频解码成 PCM 再重新编码，盲写风险高；先把直通版
//  在剪映里验一遍接缝，真有爆音再补 —— 别为了理论完美把能跑的版本押上去。
//
//  【三条方向铁律在这里的落点】
//  ② writerInput.transform = track.preferredTransform 必须显式赋值，漏了成品必躺下
//  ③ 导出日志永久记录显示尺寸
//
//  【时间轴重排】每一段的采样时间戳统一平移到它在成品里的新位置：
//  新 PTS = 原 PTS - 段起点 + 已拼接时长。视频的 DTS（B 帧存在时早于 PTS）
//  同样平移，否则播放器解码顺序会乱。
//

import Foundation
import AVFoundation

enum BKExporter {

    static func export(project: BKProject,
                       asset: AVAsset,
                       progress: @escaping (Int, Int) -> Void,
                       completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try exportSync(project: project, asset: asset, progress: progress)
                DispatchQueue.main.async { completion(.success(url)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - 同步实现（后台线程调用）

    private static func exportSync(project: BKProject,
                                   asset: AVAsset,
                                   progress: @escaping (Int, Int) -> Void) throws -> URL {
        let keeps = project.keepRanges
        guard !keeps.isEmpty else { throw BKExportError.nothingToExport }

        let outDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let url = outDir.appendingPathComponent("bk_\(Int(Date().timeIntervalSince1970)).mp4")
        // 同名残留文件会让 writer 初始化失败，先清掉
        try? FileManager.default.removeItem(at: url)

        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw BKExportError.noVideoTrack
        }
        let audioTrack = asset.tracks(withMediaType: .audio).first

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        videoInput.transform = videoTrack.preferredTransform
        guard writer.canAdd(videoInput) else { throw BKExportError.writerSetupFailed }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let track = audioTrack {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw BKExportError.writeFailed(writer.error?.localizedDescription ?? "未知原因")
        }
        writer.startSession(atSourceTime: .zero)

        var outputCursor = CMTime.zero

        for (i, seg) in keeps.enumerated() {
            let segStart = CMTime(seconds: seg.0, preferredTimescale: 600)
            let segEnd = CMTime(seconds: seg.1, preferredTimescale: 600)
            let segRange = CMTimeRange(start: segStart, duration: segEnd - segStart)
            // 这一段在成品里的新起点，减去段起点就是全体时间戳要平移的量
            let offset = outputCursor - segStart

            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = segRange

            let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            guard reader.canAdd(videoOut) else { throw BKExportError.readerSetupFailed }
            reader.add(videoOut)

            var audioOut: AVAssetReaderTrackOutput?
            if let track = audioTrack, let aIn = audioInput {
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                if reader.canAdd(out) {
                    reader.add(out)
                    audioOut = out
                }
            }

            guard reader.startReading() else {
                throw BKExportError.readFailed(reader.error?.localizedDescription ?? "未知原因")
            }

            try drain(videoOut, into: videoInput, offset: offset, writer: writer)
            if let out = audioOut, let aIn = audioInput {
                try drain(out, into: aIn, offset: offset, writer: writer)
            }

            outputCursor = outputCursor + segRange.duration
            DispatchQueue.main.async { progress(i + 1, keeps.count) }
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        // finishWriting 是异步收尾，用信号量等它落盘完成
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()

        guard writer.status == .completed else {
            throw BKExportError.writeFailed(writer.error?.localizedDescription ?? "收尾失败")
        }

        // 铁律③：导出记录永久带上显示尺寸
        BKLog.shared.i(String(format: "导出完成 %@ | %d 段 | 显示 %@ | 源 %.1fs → 成品 %.1fs",
                              url.lastPathComponent, keeps.count, project.sizeText,
                              project.duration, project.outputDuration))
        return url
    }

    // MARK: - 搬运一段的所有采样

    private static func drain(_ output: AVAssetReaderTrackOutput,
                              into input: AVAssetWriterInput,
                              offset: CMTime,
                              writer: AVAssetWriter) throws {
        while let sb = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let dts = CMSampleBufferGetDecodeTimeStamp(sb)
            let dur = CMSampleBufferGetDuration(sb)

            // DTS 可能是 invalid（无 B 帧的流），invalid 直接原样带过去，
            // 对它做加法只会产出另一个 invalid —— 但不能让它参与 CMTimeAdd 报警
            var timing = CMSampleTimingInfo(
                duration: dur,
                presentationTimeStamp: CMTimeAdd(pts, offset),
                decodeTimeStamp: dts.isInvalid ? dts : CMTimeAdd(dts, offset)
            )

            var retimed: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: nil,
                sourceBuffer: sb,
                numSampleTimingEntries: 1,
                sampleTimingEntries: &timing,
                sampleBufferOut: &retimed)
            CMSampleBufferInvalidate(sb)

            guard status == noErr, let out = retimed else {
                throw BKExportError.retimeFailed(status)
            }

            // 输入通道背压：满了就等。设 10 秒上限防死等
            var waits = 0
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
                waits += 1
                if waits > 2000 {
                    throw BKExportError.writeFailed("输入通道 10 秒不就绪")
                }
            }

            guard input.append(out) else {
                throw BKExportError.writeFailed(writer.error?.localizedDescription ?? "append 失败")
            }
        }
    }
}

// MARK: - 错误定义

enum BKExportError: LocalizedError {
    case nothingToExport
    case noVideoTrack
    case writerSetupFailed
    case readerSetupFailed
    case readFailed(String)
    case writeFailed(String)
    case retimeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .nothingToExport:     return "没有保留片段可导出"
        case .noVideoTrack:        return "素材没有视频轨"
        case .writerSetupFailed:   return "导出器初始化失败"
        case .readerSetupFailed:   return "读取器初始化失败"
        case .readFailed(let m):   return "读取失败：\(m)"
        case .writeFailed(let m):  return "写入失败：\(m)"
        case .retimeFailed(let s): return "时间戳重排失败（\(s)）"
        }
    }
}
