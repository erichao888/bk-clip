//
//  BKExporter.swift
//  bk剪辑 — 导出
//
//  【策略：重编码导出（H.264 + AAC-LC）】
//  第一版写的是「直通转封装」（reader/writer 的 outputSettings 全给 nil，
//  原样搬运源素材的 H.264/AAC 压缩数据）—— 方案很美：画质零损、速度快。
//  但真机上一试就死在这：`writer.canAdd(videoInput)` 直接返回 false。
//  **MP4 容器不接受原始比特流直通**，必须给出明确的编码参数。
//  所以改回标准做法：reader 出原始帧 → writer 压缩。
//
//  【容器与编码是焊死的，别动】
//  MP4 / H.264 / yuv420p / AAC-LC 192k / faststart 这一套已经在真·剪映上
//  实测导入通过（2026-10-02 皓哥验证）。可选项**只有分辨率和帧率**两项
//  （定稿 4.9）。改任何一个编码参数之前先问：改了还能进剪映吗？
//
//  【三条方向铁律在这里的落点】
//  ② writerInput.transform = track.preferredTransform 必须显式赋值，漏了成品必躺下
//  ③ 导出日志永久记录显示尺寸
//  ⚠️ 改分辨率时最容易忘第 ② 条：分辨率变了，写入的宽高要跟着变，
//     但 transform **永远是源素材那个 preferredTransform**（定稿 4.9.2）
//
//  【时间轴重排】每一段的采样时间戳统一平移到它在成品里的新位置：
//  新 PTS = 原 PTS - 段起点 + 已拼接时长。视频的 DTS（B 帧存在时早于 PTS）
//  同样平移，否则播放器解码顺序会乱。
//

import Foundation
import AVFoundation

enum BKExporter {

    /// 实际采用的导出规格。分辨率 / 帧率可能被源素材夹回来，
    /// 状态行显示的必须是**实际值**，不是用户选的值 ——
    /// 定稿 4.9.1 明确要求：别让人以为文件变大了是出错了
    struct Plan {
        /// 写入 AVAssetWriter 的宽高（**未旋转**的存储方向）
        let writeSize: CGSize
        /// 对应的显示尺寸（已应用 preferredTransform）
        let displaySize: CGSize
        /// 实际输出帧率
        let fps: Double
        /// 源素材帧率，用来判断要不要丢帧
        let sourceFps: Double
        /// 丢帧时的最小 PTS 间隔（秒）。nil = 不丢帧
        var minFrameInterval: Double? {
            guard fps > 0, sourceFps > fps + 0.01 else { return nil }
            return 1.0 / fps
        }
        var summary: String {
            String(format: "%d×%d · %.0ffps",
                   Int(displaySize.width), Int(displaySize.height), fps)
        }
    }

    /// 批量导出时的「参考规格」—— 定稿 4.9.1：
    /// 用户选「同源文件」但一批里各条参数不一样时，全批按**时长最长那条**统一。
    /// 传了它，长宽和帧率就照它来，不再各用各的；手动选了具体值则听手动的
    struct ExportReference {
        var displayWidth: Double
        var displayHeight: Double
        var fps: Double
    }

    /// progress 回调 (已完成段数, 总段数, 完成度 0~1)。
    /// 给完成度是因为「第几段」的观感很差：一上来第 1/12 段，
    /// 用户根本不知道要等多久 —— 百分比才是人能感知的进度
    ///
    /// - parameter reference: 批量导出的统一基准。单条导出传 nil（各用各的源参数）
    static func export(project: BKProject,
                       asset: AVAsset,
                       spec: BKConfig.ExportSpec,
                       reference: ExportReference? = nil,
                       progress: @escaping (Int, Int, Double) -> Void,
                       completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try exportSync(project: project, asset: asset,
                                         spec: spec, reference: reference, progress: progress)
                DispatchQueue.main.async { completion(.success(url)) }
            } catch {
                // 【IMG_4873 案】失败现场全部打包成可复制报告。
                // 光弹一句「写入失败：10 秒不就绪」什么都定位不了，必须把
                // 素材规格 / 导出参数 / 段边界 / 卡在哪一段 / writer 真实错误都记上。
                let report = buildFailureReport(project: project, asset: asset,
                                                spec: spec, reference: reference,
                                                error: error)
                BKLog.shared.e(report)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// 拼一份「人能看懂 + 我能直接定位」的失败报告（纯文本，方便微信粘贴）
    private static func buildFailureReport(project: BKProject,
                                           asset: AVAsset,
                                           spec: BKConfig.ExportSpec,
                                           reference: ExportReference?,
                                           error: Error) -> String {
        BKDiag.shared.reset()
        BKDiag.shared.add("错误：\(error.localizedDescription)")
        BKDiag.shared.noteStage("抛错：\(error.localizedDescription)")

        if let videoTrack = asset.tracks(withMediaType: .video).first {
            let n = videoTrack.naturalSize
            let d = n.applying(videoTrack.preferredTransform)
            // 长串用 + 拼超过 5 段，Swift 编译器会「unable to type-check in reasonable time」；
            // 跨行续行 + 前缀在某些上下文还会解析成 String.Stride。两头都避开：
            // 拆成独立变量，且每条 add() 只写一行、不用续行 +。
            let storeWH = "\(Int(n.width))×\(Int(n.height))"
            let dispWH = "\(Int(abs(d.width)))×\(Int(abs(d.height)))"
            let fpsText = String(format: "%.2f", videoTrack.nominalFrameRate)
            let kbps = Int(videoTrack.estimatedDataRate / 1000)
            let durText = BKDiag.s(CMTimeGetSeconds(asset.duration))
            // ⚠️ track 上是 preferredTransform，不是 transform（transform 是 writerInput 的属性）
            let vtXform = Self.brief(videoTrack.preferredTransform)
            let head = "源视频：存储 \(storeWH) → 显示 \(dispWH) · \(fpsText)fps"
            let tail = "码率 \(kbps)kbps · 时长 \(durText)s"
            BKDiag.shared.add("\(head) · \(vtXform) · \(tail)")

            if let audioTrack = asset.tracks(withMediaType: .audio).first {
                let aDur = BKDiag.s(CMTimeGetSeconds(audioTrack.timeRange.duration))
                let atXform = Self.brief(audioTrack.preferredTransform)
                BKDiag.shared.add("源音频：\(atXform) · 时长 \(aDur)s")
            } else {
                BKDiag.shared.add("源音频：无音轨")
            }

            let plan = makePlan(videoTrack: videoTrack, project: project, spec: spec, reference: reference)
            let wWH = "\(Int(plan.writeSize.width))×\(Int(plan.writeSize.height))"
            let dWH = "\(Int(plan.displaySize.width))×\(Int(plan.displaySize.height))"
            let outFps = String(format: "%.0f", plan.fps)
            let srcFps = String(format: "%.0f", plan.sourceFps)
            let frameText: String
            if let gap = plan.minFrameInterval {
                frameText = "降帧，间隔 \(BKDiag.s(gap))s"
            } else {
                frameText = "不丢帧"
            }
            BKDiag.shared.add("导出规格：写入 \(wWH) · 显示 \(dWH) · \(outFps)fps（源 \(srcFps)） · \(frameText)")
        } else {
            BKDiag.shared.add("源视频：取不到视频轨")
        }

        let keeps = project.keepRanges
        var keepLine = "保留段数：\(keeps.count)"
        if keeps.count <= 12 {
            // 每段单独拼好再 joined —— 三元里直接塞 map(...).joined 类型检查扛不住
            let bounds = keeps
                .map { seg in "[\(BKDiag.s(seg.0))→\(BKDiag.s(seg.1))]" }
                .joined(separator: " ")
            keepLine += " · 边界 " + bounds
        } else {
            keepLine += " · 太多不逐条列"
        }
        BKDiag.shared.add(keepLine)
        // 红区段（相邻两段之间的空隙）是最可疑的元凶：段边界对不齐音频样本就会越界
        if keeps.count > 1 {
            var gaps: [String] = []
            for i in 0 ..< (keeps.count - 1) {
                gaps.append(String(format: "%.3f", keeps[i + 1].0 - keeps[i].1))
            }
            BKDiag.shared.add("段间红区宽度(s)：" + gaps.joined(separator: " "))
        }
        return BKDiag.shared.makeReport(title: "导出失败 · \(project.assetName)")
    }

    /// CGAffineTransform 简短描述，看不出翻转/镜像时就打印 identity
    private static func brief(_ t: CGAffineTransform) -> String {
        if t == .identity { return "identity" }
        return String(format: "[%.2f %.2f %.2f %.2f %.1f %.1f]",
                      t.a, t.b, t.c, t.d, t.tx, t.ty)
    }

    // MARK: - 输出规格换算

    /// 算出真正要写进 writer 的宽高、帧率。
    ///
    /// 【分辨率作用在显示尺寸上】定稿 4.9.2：
    ///   目标显示尺寸：竖版 1080P = 1080×1920（短边是 1080）
    ///   写入宽高    ：把显示尺寸按 transform **反方向转回去**
    /// 用 `transform.inverted()` 而不是「如果是 90 度就交换宽高」——
    /// 后者遇到镜像（自拍，a 或 d 为负）就直接给错答案。
    static func makePlan(videoTrack: AVAssetTrack,
                         project: BKProject,
                         spec: BKConfig.ExportSpec,
                         reference: ExportReference? = nil) -> Plan {
        let transform = videoTrack.preferredTransform
        let natural = videoTrack.naturalSize
        // 源素材的显示尺寸。批量导出的「同源文件」模式直接采用参考条的尺寸
        var dispW: CGFloat
        var dispH: CGFloat
        if let r = reference, r.displayWidth > 0, r.displayHeight > 0 {
            dispW = CGFloat(r.displayWidth)
            dispH = CGFloat(r.displayHeight)
        } else if project.displayWidth > 0, project.displayHeight > 0 {
            dispW = CGFloat(project.displayWidth)
            dispH = CGFloat(project.displayHeight)
        } else {
            dispW = abs(natural.applying(transform).width)
            dispH = abs(natural.applying(transform).height)
        }
        if dispW <= 0 || dispH <= 0 {
            dispW = abs(natural.width); dispH = abs(natural.height)
        }

        // 分辨率：短边缩放到目标值（1080P = 短边 1080）
        if let short = spec.resolution.targetShortSide {
            let minSide = min(dispW, dispH)
            if minSide > 0, abs(minSide - CGFloat(short)) > 1 {
                let k = CGFloat(short) / minSide
                dispW *= k
                dispH *= k
            }
        }

        // 显示尺寸 → 存储尺寸：把变换矩阵逆过去
        let inv = transform.inverted()
        let back = CGSize(width: dispW, height: dispH).applying(inv)
        // H.264 要求宽高都是偶数，奇数会直接初始化失败
        let writeW = max(2, Int((abs(back.width) / 2).rounded()) * 2)
        let writeH = max(2, Int((abs(back.height) / 2).rounded()) * 2)

        // 帧率：只做「降」不做「升」。源素材 30fps 拉到 60 只能靠复制帧，
        // 体积翻倍画质不变，没意义 —— 如实按源帧率输出，状态行会写清楚
        var srcFps = videoTrack.nominalFrameRate > 0 ? Double(videoTrack.nominalFrameRate) : 30.0
        if let r = reference, r.fps > 0 { srcFps = r.fps }
        var outFps = srcFps
        if let target = spec.frameRate.value, target < srcFps - 0.01 {
            outFps = target
        }

        return Plan(writeSize: CGSize(width: writeW, height: writeH),
                    displaySize: CGSize(width: dispW, height: dispH),
                    fps: outFps,
                    sourceFps: srcFps)
    }

    // MARK: - 同步实现（后台线程调用）

    private static func exportSync(project: BKProject,
                                   asset: AVAsset,
                                   spec: BKConfig.ExportSpec,
                                   reference: ExportReference?,
                                   progress: @escaping (Int, Int, Double) -> Void) throws -> URL {
        let keeps = project.keepRanges
        guard !keeps.isEmpty else { throw BKExportError.nothingToExport }

        let outDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // 定稿 4.8 的命名：BK_ 前缀 + 重复导出的 _k 后缀
        let fileName = project.nextExportFileName
        let url = outDir.appendingPathComponent(fileName)
        // 同名残留文件会让 writer 初始化失败，先清掉
        try? FileManager.default.removeItem(at: url)

        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw BKExportError.noVideoTrack
        }
        let audioTrack = asset.tracks(withMediaType: .audio).first

        let plan = makePlan(videoTrack: videoTrack, project: project,
                            spec: spec, reference: reference)
        let bitrate = BKExporter.videoBitrate(for: videoTrack)

        BKLog.shared.i(String(format: "导出参数 写入 %d×%d 显示 %d×%d %.0ffps（源 %.0f） %.1fMbps %d段 | %@",
                              Int(plan.writeSize.width), Int(plan.writeSize.height),
                              Int(plan.displaySize.width), Int(plan.displaySize.height),
                              plan.fps, plan.sourceFps,
                              Double(bitrate) / 1_000_000, keeps.count, spec.summary))

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // 视频必须重编码：MP4 容器不接受原始比特流直通（nil 会被 canAdd 拒掉）
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            // 铁律尺寸：写入的是「未旋转」的存储尺寸，朝向交给下面的 transform
            AVVideoWidthKey: Int(plan.writeSize.width),
            AVVideoHeightKey: Int(plan.writeSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: max(1, Int(round(plan.fps))),
                AVVideoExpectedSourceFrameRateKey: plan.fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true
            ] as [String: Any]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        // 铁律②：transform 必须显式赋值，漏了成品必躺下。
        // 分辨率怎么改，transform 都是源素材这一个 —— 定稿 4.9.2
        videoInput.transform = videoTrack.preferredTransform
        // 【2026-10-04 删掉 expectsMediaDataInRealTime —— 它是「画面滞后于声音」的元凶】
        // v1.2.11~1.2.14 这里设过 `videoInput.expectsMediaDataInRealTime = true`，
        // 是 IMG_4873 死锁案的权宜之计：真机遇到「两条通道永远 isReadyForMoreMediaData = false」
        // 时它能让 writer 放宽就绪判定。**但它只设在视频轨、音频轨没设**，于是：
        //
        //   实时模式下 AVFoundation 不再保证按 append 顺序交织，会**自行重排时间戳来追实时**。
        //   视频按「实时流」缓冲、音频按「离线精确」写入，两轨处理策略不一致
        //   → 成品画面比声音滞后（皓哥 2026-10-04 真机实测报障）。
        //   副作用还有：实时模式可能悄悄丢帧。
        //
        // 而 IMG_4873 的**真根因**是「越界样本让时间戳倒退」——那个已经被下面的
        // `inRange` 过滤治住了（只放行原始 PTS 落在 [segStart, segEnd) 内的样本）。
        // 所以这个标志属于误用，删掉。死锁的兜底另有三道：
        //   ① 每轮检查 writer.status，失败立刻抛真实错误
        //   ② idleRounds > 2000 才判卡死（背压等待是正常的，不该判死刑）
        //   ③ 超时错误里带上 writer 真实 error，不吞
        videoInput.expectsMediaDataInRealTime = false
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
            BKDiag.shared.noteStage("搬运第 \(i + 1)/\(keeps.count) 段 源[\(BKDiag.s(seg.0))→\(BKDiag.s(seg.1))]"
                                    + " → 成品[\(BKDiag.s(outputCursor.seconds))→\(BKDiag.s((outputCursor + segRange.duration).seconds))]"
                                    + " 平移 \(BKDiag.s(offset.seconds))s")

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
            // 【2026-10-04】返回值 = 本段实际写入成品的时长，**不是**标称段长。
            // 段末尾被 inRange 丢掉的那点尾巴（不足一帧/一音频块）会让实际 < 标称，
            // 按标称推进 cursor 的话这个差会逐段累积成音画错位。
            let actualLen = try drainSegment(video: videoOut,
                                             videoInput: videoInput,
                                             audio: audioOut,
                                             audioInput: audioInput,
                                             offset: offset,
                                             writer: writer,
                                             reader: reader,
                                             segStart: seg.0,
                                             segEnd: seg.1,
                                             planFps: plan.fps,
                                             minFrameInterval: plan.minFrameInterval)

            // cursor 前进「实际长度」，下一段的 offset 才和这一段末尾严丝合缝
            outputCursor = outputCursor + CMTime(seconds: actualLen, preferredTimescale: 600)
            written += actualLen
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
        BKLog.shared.i(String(format: "导出完成 %@ | %d 段 | 写入 %d×%d 显示 %d×%d %.0ffps | 源 %.1fs → 成品 %.1fs",
                              fileName, keeps.count,
                              Int(plan.writeSize.width), Int(plan.writeSize.height),
                              Int(plan.displaySize.width), Int(plan.displaySize.height), plan.fps,
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
    ///
    /// - parameter minFrameInterval: 降帧率用的最小 PTS 间隔。
    ///   源 60fps 选 30fps 时，间隔不足 1/30 秒的帧直接丢掉（不写入），
    ///   这样出来的才是真的 30fps，而不是「标着 30 但帧数没变」
    ///
    /// - parameter reader: 传进来只为读 status/error。copyNextSampleBuffer 返回 nil
    ///   有「搬完了」和「解码中途挂了」两种含义，不查 status 就分不出来（IMG_4873 案）
    ///
    /// - returns: 本段**实际写入成品的时长（秒）**。调用方必须用它推进 outputCursor，
    ///   **不能**用标称的 `segEnd - segStart`。
    ///
    /// 【2026-10-04 为什么返回值不能是标称段长】
    /// `inRange` 按 `[segStart, segEnd)` 放行，段末尾那点「不足一帧 / 不足一个音频块」的
    /// 尾巴会被丢掉。于是**实际写入的时长 < 标称段长**：
    ///   视频末帧落在 ceil(segEnd/帧长) 之前，音频末块落在 ceil(segEnd/块长) 之前，
    ///   两者余数不同（60fps 是 16.67ms、AAC 块 21.33ms）→ 每段视频轨和音频轨的
    ///   收尾余量不一样。
    /// 老代码按标称推进 cursor，这两份余量差就**逐段累积、永不归零** → 音画持续错位。
    /// 实测末段累计：4580 −6.1ms / 4582 −5.1ms / 4583 −14.6ms。
    /// 改成按实际写入长度推进后，每段起点严丝合缝，误差不再跨段累积。
    @discardableResult
    private static func drainSegment(video: AVAssetReaderTrackOutput,
                                     videoInput: AVAssetWriterInput,
                                     audio: AVAssetReaderTrackOutput?,
                                     audioInput: AVAssetWriterInput?,
                                     offset: CMTime,
                                     writer: AVAssetWriter,
                                     reader: AVAssetReader,
                                     segStart: Double,
                                     segEnd: Double,
                                     planFps: Double,
                                     minFrameInterval: Double?) throws -> Double {
        // 没有音轨（或音频没能加进 writer）时退化成单通道搬运，逻辑同一份
        var videoDone = false
        var audioDone = (audio == nil || audioInput == nil)
        var idleRounds = 0
        /// 上一帧写进成品的 PTS，用来判「间隔够不够」
        var lastVideoPTS: Double?
        var droppedFrames = 0
        /// 因越界被丢弃的样本数（诊断用）
        var outOfRangeDrops = 0
        /// 【2026-10-04】两轨各自「实际写入到成品的哪个时间点」（相对本段起点，即已减掉 offset）
        /// 取两者的较大值作为本段实际长度 —— 取小的会让另一轨的尾巴越过下一段起点。
        var videoRealEnd: Double = 0
        var audioRealEnd: Double = 0

        // 【IMG_4873 死锁案的真正根因，2026-10-03】
        // 现象：多次都恰好卡在 54%，删掉主轨道所有红区（= 只剩一段连续）就导出成功。
        // 病因：AVAssetReader 的 timeRange 是「尽力而为」的语义，**会吐出略微越过边界的样本**
        //   —— 音频一个样本 21ms，段边界几乎不可能落在样本中间；视频为了 GOP 解码也会带回
        //   边界外的帧。这些越界样本经 offset 平移后，PTS 会和「下一段」的首帧重叠甚至倒退，
        //   AVAssetWriter 一旦遇到时间戳倒退/交叠就内部卡死，两条通道永远 isReady=false。
        //   删掉红区后没有任何段边界，样本不越界，所以不卡 —— 完美吻合现象。
        // 药方：每段只放行「原始 PTS 严格落在 [segStart, segEnd) 内」的样本。
        //   这样各段平移后的时间戳严格递增、段间严丝合缝，倒退不可能发生。
        //   容差 1e-4 秒：CMTime 换算有浮点误差，卡太死会误丢边界帧。
        func inRange(_ seconds: Double) -> Bool {
            seconds >= segStart - 1e-4 && seconds < segEnd - 1e-4
        }

        while !(videoDone && audioDone) {
            // writer 中途异步失败后，两条通道的 isReadyForMoreMediaData 会永远返回 false。
            // 旧代码在这里空转 10 秒报「超时」，把真实错误（磁盘满/编码器中断等）吞掉了。
            // 每轮先查状态，挂了立刻抛真错误，别让诊断信息只剩一句没用的超时。
            if writer.status == .failed {
                throw BKExportError.writeFailed(
                    writer.error?.localizedDescription ?? "写入器中途失败（无详细信息）")
            }

            var fedAnything = false

            if !videoDone, videoInput.isReadyForMoreMediaData {
                if let sb = video.copyNextSampleBuffer() {
                    let raw = CMSampleBufferGetPresentationTimeStamp(sb)
                    let pts = CMTimeGetSeconds(raw)
                    if !inRange(pts) {
                        // 越界样本：丢掉，绝不让它带着越界时间戳进 writer
                        CMSampleBufferInvalidate(sb)
                        outOfRangeDrops += 1
                        fedAnything = true
                    } else {
                        var keep = true
                        if let gap = minFrameInterval, let last = lastVideoPTS, (pts - last) < gap - 1e-6 {
                            keep = false
                            droppedFrames += 1
                        }
                        if keep {
                            let buffer = try retimedBuffer(sb, offset: offset)
                            guard videoInput.append(buffer) else {
                                throw BKExportError.writeFailed(
                                    writer.error?.localizedDescription ?? "视频写入失败")
                            }
                            lastVideoPTS = pts
                            // 这一帧在成品里占到哪 —— 帧长按「实际输出的帧间隔」算：
                            // 降帧时相邻两帧隔的是 minFrameInterval，不是 1/源帧率
                            let frameSpan = minFrameInterval ?? (1.0 / planFps)
                            let writtenEnd = pts - segStart + frameSpan
                            if writtenEnd > videoRealEnd { videoRealEnd = writtenEnd }
                        } else {
                            // 丢掉的帧也要 Invalidate，否则 CMSampleBuffer 的缓存会一直堆着
                            CMSampleBufferInvalidate(sb)
                        }
                        fedAnything = true
                    }
                } else {
                    // nil 有两种含义：这段搬完了 / reader 中途挂了。不查 status 分不出来
                    if reader.status == .failed {
                        throw BKExportError.readFailed(
                            reader.error?.localizedDescription ?? "读取器中途失败（无详细信息）")
                    }
                    videoDone = true   // 这一段视频搬完了
                    fedAnything = true
                }
            }

            if !audioDone, let audioOut = audio, let audioIn = audioInput,
               audioIn.isReadyForMoreMediaData {
                if let sb = audioOut.copyNextSampleBuffer() {
                    let raw = CMSampleBufferGetPresentationTimeStamp(sb)
                    let pts = CMTimeGetSeconds(raw)
                    if !inRange(pts) {
                        CMSampleBufferInvalidate(sb)
                        outOfRangeDrops += 1
                        fedAnything = true
                    } else {
                        let buffer = try retimedBuffer(sb, offset: offset)
                        guard audioIn.append(buffer) else {
                            throw BKExportError.writeFailed(
                                writer.error?.localizedDescription ?? "音频写入失败")
                        }
                        // 音频块的时长用它自己带的 duration（换算成秒）。
                        // 不写死 1024/48000 —— 源素材的块长可能不是这个值
                        let blockSpan = CMSampleBufferGetDuration(sb).seconds
                        let span = blockSpan.isFinite && blockSpan > 0 ? blockSpan : (1024.0 / 48000.0)
                        let writtenEnd = pts - segStart + span
                        if writtenEnd > audioRealEnd { audioRealEnd = writtenEnd }
                        fedAnything = true
                    }
                } else {
                    if reader.status == .failed {
                        throw BKExportError.readFailed(
                            reader.error?.localizedDescription ?? "读取器中途失败（无详细信息）")
                    }
                    audioDone = true   // 这一段音频搬完了
                    fedAnything = true
                }
            }

            if fedAnything {
                idleRounds = 0
            } else {
                // 两条通道都堵着：让出 CPU 等 writer 消化，别让它俩空转抢锁
                idleRounds += 1
                Thread.sleep(forTimeInterval: 0.005)
                if idleRounds > 2000 {
                    // 兜底：把 writer 的真实状态写进报错，别再只留一句「超时」
                    // ⚠️ `Error?` 没有 .map（那是 Optional.map，但 writer.error 是 Error?，
                    // 用 map 会报 "value of type 'any Error' has no member 'map'"）—— 用 if let
                    var extra = ""
                    if let e = writer.error {
                        extra = "（writer：\(e.localizedDescription)）"
                    }
                    throw BKExportError.writeFailed("视频/音频通道同时超过 10 秒不就绪\(extra)")
                }
            }
        }

        if droppedFrames > 0 {
            BKLog.shared.d("本段降帧：丢掉 \(droppedFrames) 帧")
        }
        if outOfRangeDrops > 0 {
            BKLog.shared.d("本段丢弃越界样本 \(outOfRangeDrops) 个（段边界对齐，IMG_4873 案）")
        }

        // 【2026-10-04】返回本段实际写入的长度，取两轨较大值。
        // 为什么取较大：cursor 是下一段的起点，取小的会让另一轨的尾巴越过它 → 时间戳倒退，
        // 那是 IMG_4873 死锁的诱因。两轨都空（段太短，一个样本都没放行）时退回标称段长。
        let nominal = segEnd - segStart
        let real = max(videoRealEnd, audioRealEnd)
        let actual = real > 0.001 ? real : nominal
        // 长串用 + 拼超过 5 段、或者跨行续行 +，Swift 编译器会类型检查超时 / 解析成
        // String.Stride + String（v1.1.8 连红两轮全是它）。拆成独立变量、一次拼完。
        let head = "本段实际写入 \(BKDiag.s(actual))s（标称 \(BKDiag.s(nominal))s）"
        let tails = "视频尾 \(BKDiag.s(videoRealEnd))s 音频尾 \(BKDiag.s(audioRealEnd))s"
        BKDiag.shared.noteStage(head + tails)
        return actual
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
