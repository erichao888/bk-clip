//
//  BKExporter.swift
//  bk剪辑 — 导出（第三批）
//
//  【策略：重编码导出（H.264 + AAC-LC）】
//  第一版写的是「直通转封装」（reader/writer 的 outputSettings 全给 nil，
//  原样搬运源素材的 H.264/AAC 压缩数据）—— 方案很美：画质零损、速度快。
//  但真机上一试就死在这：`writer.canAdd(videoInput)` 直接返回 false。
//  **MP4 容器不接受原始比特流直通**，必须给出明确的编码参数。
//  所以改回标准做法：reader 出原始帧 → writer 压缩，参数照
//  tools/preview_cut.py 里已通过剪映实测的那套规格来设。
//
//  【已知取舍】接缝暂不做 15ms 淡入淡出（Python 版 preview_cut.py 有）。
//  先验这版接缝在剪映里有没有爆音，有再补 —— 别为了理论完美拖延上线。
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

    /// progress 回调 (已完成段数, 总段数, 完成度 0~1)。
    /// 给完成度是因为「第几段」的观感很差：一上来第 1/12 段，
    /// 用户根本不知道要等多久 —— 百分比才是人能感知的进度
    static func export(project: BKProject,
                       asset: AVAsset,
                       progress: @escaping (Int, Int, Double) -> Void,
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
                                   progress: @escaping (Int, Int, Double) -> Void) throws -> URL {
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

        let natural = videoTrack.naturalSize
        let fps = videoTrack.nominalFrameRate > 0 ? videoTrack.nominalFrameRate : 30.0
        let bitrate = BKExporter.videoBitrate(for: videoTrack)

        BKLog.shared.i(String(format: "导出参数 %.0f×%.0f %.0ffps %.1fMbps %d段",
                              natural.width, natural.height, fps,
                              Double(bitrate) / 1_000_000, keeps.count))

        // 视频必须重编码：MP4 容器不接受原始比特流直通（nil 会被 canAdd 拒掉）
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            // 铁律尺寸：写入的是「未旋转」的自然尺寸，朝向交给下面的 transform
            AVVideoWidthKey: Int(natural.width),
            AVVideoHeightKey: Int(natural.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: max(1, Int(round(fps))),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true
            ] as [String: Any]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        // 铁律②：transform 必须显式赋值，漏了成品必躺下
        videoInput.transform = videoTrack.preferredTransform
        guard writer.canAdd(videoInput) else {
            throw BKExportError.writerSetupFailed("视频轨无法加入导出器")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioTrack != nil {
            // AAC-LC 192k 是兼容性最好的组合，HE-AAC 有设备不认
            let audioWriterSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioWriterSettings)
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                BKLog.shared.w("音频轨无法加入导出器，成品将无声")
            }
        }

        guard writer.startWriting() else {
            throw BKExportError.writeFailed(writer.error?.localizedDescription ?? "未知原因")
        }
        writer.startSession(atSourceTime: .zero)

        var outputCursor = CMTime.zero
        // 完成度按「已写出的成品时长」算，而不是按段数 ——
        // 各段长度不一样，按段数报出来的进度会一顿一顿的
        var written: Double = 0
        let planned = keeps.reduce(0.0) { $0 + ($1.1 - $1.0) }

        for (i, seg) in keeps.enumerated() {
            let segStart = CMTime(seconds: seg.0, preferredTimescale: 600)
            let segEnd = CMTime(seconds: seg.1, preferredTimescale: 600)
            let segRange = CMTimeRange(start: segStart, duration: segEnd - segStart)
            // 这一段在成品里的新起点，减去段起点就是全体时间戳要平移的量
            let offset = outputCursor - segStart

            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = segRange

            // reader 出「原始帧」交给 writer 压缩：
            // 视频给 yuv420p 像素缓冲（对应已验证过的 yuv420p 规格），
            // 音频给交错立体声 PCM（AAC 编码器要的是 PCM 输入）
            let videoReaderSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8Planar
            ]
            let audioReaderSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]

            let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoReaderSettings)
            guard reader.canAdd(videoOut) else { throw BKExportError.readerSetupFailed }
            reader.add(videoOut)

            var audioOut: AVAssetReaderTrackOutput?
            if let track = audioTrack, audioInput != nil {
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: audioReaderSettings)
                if reader.canAdd(out) {
                    reader.add(out)
                    audioOut = out
                }
            }

            guard reader.startReading() else {
                throw BKExportError.readFailed(reader.error?.localizedDescription ?? "未知原因")
            }
            // 搬完就释放解码占地（十几段素材时每个 reader 都留着会很可观）
            defer { reader.cancelReading() }

            // 双通道交替搬运（见 drainSegment 的注释：先搬完一条再搬另一条会死锁）
            try drainSegment(video: videoOut,
                             videoInput: videoInput,
                             audio: audioOut,
                             audioInput: audioInput,
                             offset: offset,
                             writer: writer)

            outputCursor = outputCursor + segRange.duration
            written += segRange.duration.seconds
            let fraction = planned > 0 ? min(max(written / planned, 0), 1) : 1.0
            DispatchQueue.main.async { progress(i + 1, keeps.count, fraction) }
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

    /// 输出码率：跟随源素材（重编码不额外丢画质），但夹到合理区间 ——
    /// 有些 4K/高码率素材的 estimatedDataRate 会让成品体积失控
    private static func videoBitrate(for track: AVAssetTrack) -> Int {
        let raw = Int(track.estimatedDataRate)
        switch raw {
        case 0 ..< 4_000_000:    return 8_000_000    // 估不出来就给 1080p 的常用值
        case 4_000_000 ..< 30_000_000: return raw
        default:                 return 30_000_000
        }
    }

    // MARK: - 搬运一段的所有采样

    /// 时间戳平移：把采样挪到它在成品里的新位置。
    ///
    /// DTS 可能是 invalid（无 B 帧的流），invalid 直接原样带过去 ——
    /// Swift 里 CMTime 只有 .isValid（isInvalid 是 C 宏，不进 Swift）。
    private static func retimedBuffer(_ sb: CMSampleBuffer,
                                      offset: CMTime) throws -> CMSampleBuffer {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let dts = CMSampleBufferGetDecodeTimeStamp(sb)
        let dur = CMSampleBufferGetDuration(sb)

        var timing = CMSampleTimingInfo(
            duration: dur,
            presentationTimeStamp: CMTimeAdd(pts, offset),
            decodeTimeStamp: dts.isValid ? CMTimeAdd(dts, offset) : dts
        )

        // Swift 导入后的真实标签（不对称，别想当然！）：
        // allocator: / sampleBuffer: / sampleTimingEntryCount: / sampleTimingArray: / sampleBufferOut:
        // 计数带 Entry，数组不带 —— 这是 C 声明和 Swift 导入两层改名叠出来的
        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sb,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed)
        CMSampleBufferInvalidate(sb)

        guard status == noErr, let out = retimed else {
            throw BKExportError.retimeFailed(status)
        }
        return out
    }

    /// 交替搬运一段的音视频采样。
    ///
    /// 【为什么一定要交替】writer 同时挂着视频、音频两个 input 时，它们共享同一条
    /// 容器写入队列。视频压缩慢、通道很快就填满，writer 在等音频的包来拼交织
    /// （interleave）；这时候如果代码还在视频通道上傻等就绪，两边互不相让 ——
    /// 视频等 writer 排空、writer 等音频数据，死锁。
    ///
    /// 第一版就是「先把整段视频搬完再搬音频」，真机直接报：
    /// 导出失败：写入失败：输入通道 10 秒不就绪。
    /// 改成「谁就绪喂谁」之后解开。
    ///
    /// 顺带一提，10 秒上限的语义也变了：不是「某一条通道久不就绪」就算卡死，
    /// 而是「一整轮里两条通道谁都没喂进去」持续 10 秒才算真卡死 ——
    /// 背压等待本身是完全正常的，不该被判死刑。
    private static func drainSegment(video: AVAssetReaderTrackOutput,
                                     videoInput: AVAssetWriterInput,
                                     audio: AVAssetReaderTrackOutput?,
                                     audioInput: AVAssetWriterInput?,
                                     offset: CMTime,
                                     writer: AVAssetWriter) throws {
        // 没有音轨（或音频没能加进 writer）时退化成单通道搬运，逻辑同一份
        var videoDone = false
        var audioDone = (audio == nil || audioInput == nil)
        var idleRounds = 0

        while !(videoDone && audioDone) {
            var fedAnything = false

            if !videoDone, videoInput.isReadyForMoreMediaData {
                if let sb = video.copyNextSampleBuffer() {
                    let buffer = try retimedBuffer(sb, offset: offset)
                    guard videoInput.append(buffer) else {
                        throw BKExportError.writeFailed(writer.error?.localizedDescription ?? "视频写入失败")
                    }
                } else {
                    videoDone = true   // 这一段视频搬完了
                }
                fedAnything = true
            }

            if !audioDone, let audioOut = audio, let audioIn = audioInput,
               audioIn.isReadyForMoreMediaData {
                if let sb = audioOut.copyNextSampleBuffer() {
                    let buffer = try retimedBuffer(sb, offset: offset)
                    guard audioIn.append(buffer) else {
                        throw BKExportError.writeFailed(writer.error?.localizedDescription ?? "音频写入失败")
                    }
                } else {
                    audioDone = true   // 这一段音频搬完了
                }
                fedAnything = true
            }

            if fedAnything {
                idleRounds = 0
            } else {
                // 两条通道都堵着：让出 CPU 等 writer 消化，别让它俩空转抢锁
                idleRounds += 1
                Thread.sleep(forTimeInterval: 0.005)
                if idleRounds > 2000 {
                    throw BKExportError.writeFailed("视频/音频通道同时超过 10 秒不就绪")
                }
            }
        }
    }
}

// MARK: - 错误定义

enum BKExportError: LocalizedError {
    case nothingToExport
    case noVideoTrack
    case writerSetupFailed(String)
    case readerSetupFailed
    case readFailed(String)
    case writeFailed(String)
    case retimeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .nothingToExport:     return "没有保留片段可导出"
        case .noVideoTrack:        return "素材没有视频轨"
        case .writerSetupFailed(let m):return "导出器初始化失败：\(m)"
        case .readerSetupFailed:   return "读取器初始化失败"
        case .readFailed(let m):   return "读取失败：\(m)"
        case .writeFailed(let m):  return "写入失败：\(m)"
        case .retimeFailed(let s): return "时间戳重排失败（\(s)）"
        }
    }
}
