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
        // 注：源音轨不用取 —— v1.3.4 起音频也走 composition（见下面 BKCompositionBuilder），
        // 那边自己从 asset 取，这里取了会变成未使用变量。

        // ============================================================
        // 【v1.3.4 音画同步第四次修复 —— 根治】
        //
        // 前三次都错在同一个根因：**手算每段的 PTS 偏移**。
        // 而我用来算的那些值（帧长、块长、样本是否越界）全是我**猜的** ——
        // 视频有 B 帧（DTS≠PTS）、CMSampleBufferGetDuration 不等于一帧长、
        // 音频块长也不等于 1024/48000。Python 复刻说「四条样片全绿」，
        // 但那只是**我的模型绿**，真机照样「越往后面越大」。
        //
        // 这次换做法：**先用 AVMutableComposition 把保留段拼成一条**，
        // 系统保证时间轴连续 + 音视频两轨天然对齐，我们**一个 PTS 都不用算**。
        // 然后从 composition 读出来写 writer —— 读出来的 PTS 已经是最终值。
        //
        // 额外收益：联播（BKJointBuilder）和导出共用同一份拼法，
        // 「预演听到的」必然等于「导出的」。
        // ============================================================
        guard let built = BKCompositionBuilder.make(asset: asset, keeps: keeps) else {
            throw BKExportError.nothingToExport
        }
        let compAsset: AVAsset = built.comp
        guard let compVideo = compAsset.tracks(withMediaType: .video).first else {
            throw BKExportError.noVideoTrack
        }
        let compAudio = compAsset.tracks(withMediaType: .audio).first
        BKLog.shared.i(String(format: "导出：已拼成 composition %d 段 / 成品 %.3fs",
                              built.table.count, built.total))

        // 方向铁律要从 composition 的轨道拿 —— 拼接时已经抄过一遍，这里再确认一次，
        // 下面的 writerInput.transform 用的就是这个值
        let compTransform = compVideo.preferredTransform

        let plan = makePlan(videoTrack: videoTrack, project: project,
                            spec: spec, reference: reference)
        let bitrate = BKExporter.videoBitrate(for: videoTrack)

        // ⚠️⚠️ **v1.4.7 导出闪退的根因**（2026-10-04 20:48 皓哥日志，崩在打这条日志之后）
        //
        // 日志原文：`导出参数 写入 1920×1080 显示 1080×1920 60fps`，
        // 然后**直接重启**（连下一条「已拼成 composition」都没打）。
        // 崩在 `AVAssetWriter` 初始化 / `canAdd` 那一带。
        //
        // 病根：**transform 与像素尺寸不匹配**。
        // `makePlan` 用的是**源素材**的 `videoTrack.preferredTransform` 去逆推 writeSize，
        // 而 `videoInput.transform` 用的是 **composition 的** `compTransform`。
        // 竖拍素材（旋转 90°）下两者一旦不一致，
        // 编码器就会拿到「尺寸是横的、transform 说要转成竖的」这种自相矛盾的输入
        // → AVFoundation 内部直接崩（不是报错，是崩溃）。
        //
        // 正解：**两处必须用同一个 transform**。统一用 composition 的（它是从源素材抄的，
        // 而且拼接后才是真正要写出的内容）。
        let planWithComp = makePlan(videoTrack: compVideo,
                                    project: project,
                                    spec: spec,
                                    reference: reference)
        let sameTransform = (compTransform == videoTrack.preferredTransform)
        if !sameTransform {
            BKLog.shared.w("composition transform 与源素材不一致，改用 composition 的重算尺寸")
        }
        let finalPlan = planWithComp
        BKLog.shared.i(String(format: "导出参数 写入 %d×%d 显示 %d×%d %.0ffps（源 %.0f） %.1fMbps %d段 | %@",
                              Int(finalPlan.writeSize.width), Int(finalPlan.writeSize.height),
                              Int(finalPlan.displaySize.width), Int(finalPlan.displaySize.height),
                              finalPlan.fps, finalPlan.sourceFps,
                              Double(bitrate) / 1_000_000, keeps.count, spec.summary))

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // 视频必须重编码：MP4 容器不接受原始比特流直通（nil 会被 canAdd 拒掉）
        // ⚠️ v1.4.7 崩溃防御：H.264 编码器对**尺寸与 transform 不匹配**是直接崩的
        // （不是 canAdd 返回 false，是进程死掉）。这里下断言式检查，
        // 不匹配就退回「关掉 transform」的保守写法 —— 宁可方向不对，也不能崩。
        let transformSwapsAxes = abs(compTransform.b) > 0.001 || abs(compTransform.c) > 0.001
        let writeIsLandscape = finalPlan.writeSize.width > finalPlan.writeSize.height
        let transformMismatch = transformSwapsAxes == writeIsLandscape
        let appliedTransform: CGAffineTransform = transformMismatch
            ? CGAffineTransform.identity
            : compTransform
        if transformMismatch {
            BKLog.shared.w(String(format:
                "⚠️ 尺寸与 transform 不匹配（写入 %d×%d，transform %@）→ 本次不套 transform，成品朝向可能不正",
                Int(finalPlan.writeSize.width), Int(finalPlan.writeSize.height),
                transformSwapsAxes ? "旋转90°" : "无旋转"))
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            // 铁律尺寸：写入的是「未旋转」的存储尺寸，朝向交给下面的 transform
            AVVideoWidthKey: Int(finalPlan.writeSize.width),
            AVVideoHeightKey: Int(finalPlan.writeSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: max(1, Int(round(finalPlan.fps))),
                AVVideoExpectedSourceFrameRateKey: finalPlan.fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true
            ] as [String: Any]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        // 铁律②：transform 必须显式赋值，漏了成品必躺下。
        // v1.3.4：取 **composition 的**轨道的 transform（拼接时已把源素材的抄过去）。
        // 分辨率怎么改，transform 都是源素材那一个 —— 定稿 4.9.2
        videoInput.transform = appliedTransform
        // expectsMediaDataInRealTime = false：v1.2.11~1.3.2 这里设过 true，
        // 实时模式会让 AVFoundation 自行重排时间戳追实时，两轨策略不一致 → 画面滞后于声音。
        // 现在 composition 已经保证了连续性，不需要任何"追实时"的补救。
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw BKExportError.writerSetupFailed("视频轨无法加入导出器")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if compAudio != nil {
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

        // ============================================================
        // 【v1.3.4】搬运：整条 composition 一次读完，不分段、不算偏移
        //
        // 关键认知：**PTS 已经是最终值了**。composition 里系统已经把保留段
        // 首尾相接排好、音视频两轨对齐，我们读出来直接 append 即可。
        //
        // 之前那套「每段新建 reader + 手算 offset」的做法必须整段拿掉 ——
        // 它连错三次（累积错位 / 轨道空洞 / 锚点阈值猜错），
        // 而那些「不越界检查」的阈值全是猜的：视频有 B 帧、duration 不等于帧长、
        // 音频块长不等于 1024/48000。真机「越往后面越大」就是这么来的。
        // ============================================================
        let planned = built.total
        var written: Double = 0
        let reader = try AVAssetReader(asset: compAsset)

        // 从 composition 读出「原始帧」交给 writer 压缩：
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

        let videoOut = AVAssetReaderTrackOutput(track: compVideo, outputSettings: videoReaderSettings)
        guard reader.canAdd(videoOut) else { throw BKExportError.readerSetupFailed }
        reader.add(videoOut)

        var audioOut: AVAssetReaderTrackOutput?
        if let ca = compAudio, audioInput != nil {
            let out = AVAssetReaderTrackOutput(track: ca, outputSettings: audioReaderSettings)
            if reader.canAdd(out) {
                reader.add(out)
                audioOut = out
            }
        }

        guard writer.startWriting() else {
            throw BKExportError.writeFailed(writer.error?.localizedDescription ?? "未知原因")
        }
        writer.startSession(atSourceTime: .zero)

        guard reader.startReading() else {
            throw BKExportError.readFailed(reader.error?.localizedDescription ?? "未知原因")
        }
        defer { reader.cancelReading() }

        // 双通道交替搬运：writer 的两条 input 共享同一条写入队列，
        // 先搬完一条再搬另一条会死锁（详见 drainComposition 的注释）。
        try drainComposition(video: videoOut,
                             videoInput: videoInput,
                             audio: audioOut,
                             audioInput: audioInput,
                             writer: writer,
                             reader: reader,
                             planFps: finalPlan.fps,
                             minFrameInterval: finalPlan.minFrameInterval,
                             total: built.total,
                             progress: { frac in
                                 DispatchQueue.main.async { progress(1, 1, frac) }
                             })

        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        // finishWriting 是异步收尾，用信号量等它落盘完成
        //
        // ⚠️⚠️ **v1.4.3 闪退的元凶**（2026-10-04 19:50 皓哥真机报障）
        // 原来这里是裸 `sem.wait()` —— **无限等待**。而
        // `AVAssetWriter.finishWriting` 的 completion **在 writer 已 failed 时不保证触发**，
        // 于是信号量永远等不到 → 主线程卡死 → iOS 判定「无响应」直接杀进程
        // → 用户看到的就是「导出时 App 闪退」。
        //
        // 为什么会走到 failed：composition 拼接后若某段 `insertTimeRange` 失败
        // （越界/时长为负），表里就少一段而音频轨照样插了，两轨长度不一致，
        // writer 在收尾阶段报错 —— 这时 completion 就不来了。
        //
        // 正解：**带超时的等待**。超时就报真实错误（带上 writer 的 error），不无限卡。
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        // 素材越长落盘越慢，给 120 秒。实测正常导出 30 秒内完成
        let waited = sem.wait(timeout: .now() + 120)
        if waited == .timedOut {
            var extra = ""
            if let e = writer.error { extra = "（\(e.localizedDescription)）" }
            throw BKExportError.writeFailed("导出收尾超时 120 秒\(extra)")
        }

        guard writer.status == .completed else {
            throw BKExportError.writeFailed(writer.error?.localizedDescription ?? "收尾失败")
        }

        // 铁律③：导出记录永久带上显示尺寸
        BKLog.shared.i(String(format: "导出完成 %@ | %d 段 | 写入 %d×%d 显示 %d×%d %.0ffps | 源 %.1fs → 成品 %.1fs",
                              fileName, keeps.count,
                              Int(finalPlan.writeSize.width), Int(finalPlan.writeSize.height),
                              Int(finalPlan.displaySize.width), Int(finalPlan.displaySize.height), finalPlan.fps,
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

    // MARK: - 从 composition 搬运采样（v1.3.4）

    /// 把 composition 里的采样**原封不动**写进 writer。
    ///
    /// 【为什么没有 offset 参数了】以前每个样本都要 `retimedBuffer(sb, offset:)`
    /// 手工平移时间戳 —— 那三次音画错位全出在这件事上：
    /// ① 游标推进量与实际写入不匹配（累积错位）
    /// ② 取两轨较大值（轨道空洞）
    /// ③ 标称推进 + 样本不越界（阈值全靠猜：B 帧、duration≠帧长、块长≠21.33ms）
    ///
    /// 现在 `BKCompositionBuilder` 已经把保留段拼好了，
    /// **系统保证时间轴连续 + 音视频两轨天然对齐**，
    /// 读出来的 PTS 就是最终值 —— **一个数都不用算**。
    ///
    /// 【降帧还在】源 60fps 选 30fps 时要按 `minFrameInterval` 丢帧，
    /// 但**只丢帧、不动时间戳**（丢掉的帧不写，PTS 自然就稀疏了）。
    ///
    /// - Parameter progress: 已写出的时长占比 0~1，用于回传 UI 进度。
    ///   ⚠️ 必须标 `@escaping` —— 它被存进下面的 `tick` 闭包里，
    ///   而闭包默认是非 escaping 的（CI 报 "escaping closure captures non-escaping parameter"）。
    private static func drainComposition(video: AVAssetReaderTrackOutput,
                                         videoInput: AVAssetWriterInput,
                                         audio: AVAssetReaderTrackOutput?,
                                         audioInput: AVAssetWriterInput?,
                                         writer: AVAssetWriter,
                                         reader: AVAssetReader,
                                         planFps: Double,
                                         minFrameInterval: Double?,
                                         total: Double,
                                         progress: @escaping (Double) -> Void) throws {
        var videoDone = false
        var audioDone = (audio == nil || audioInput == nil)
        var idleRounds = 0
        var droppedFrames = 0
        var lastVideoPTS: Double?
        var written: Double = 0
        var lastReported = -1.0

        // 进度按「已写出的成品时长」算。composition 是连续的，按段数报会一顿一顿的
        let tick: (Double) -> Void = { t in
            guard total > 0 else { return }
            let frac = min(max(t / total, 0), 1)
            // 每前进 0.5% 报一次，别每帧都切主线程
            if frac - lastReported >= 0.005 {
                lastReported = frac
                progress(frac)
            }
        }

        while !(videoDone && audioDone) {
            // writer 中途失败后 isReadyForMoreMediaData 会永远 false，
            // 每轮先查状态，挂了立刻抛真错误，别让诊断只剩一句「超时」
            if writer.status == .failed {
                throw BKExportError.writeFailed(
                    writer.error?.localizedDescription ?? "写入器中途失败（无详细信息）")
            }

            var fedAnything = false

            if !videoDone, videoInput.isReadyForMoreMediaData {
                if let sb = video.copyNextSampleBuffer() {
                    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
                    var drop = false
                    if let gap = minFrameInterval, let last = lastVideoPTS, (pts - last) < gap - 1e-6 {
                        drop = true
                        droppedFrames += 1
                    }
                    if drop {
                        // 丢掉的帧也要 Invalidate，否则 CMSampleBuffer 的缓存会一直堆着
                        CMSampleBufferInvalidate(sb)
                    } else {
                        // ⚠️ 直接 append，**不碰时间戳** —— 这是根治音画的关键
                        guard videoInput.append(sb) else {
                            throw BKExportError.writeFailed(
                                writer.error?.localizedDescription ?? "视频写入失败")
                        }
                        lastVideoPTS = pts
                        written = max(written, pts)
                        tick(pts)
                    }
                    fedAnything = true
                } else {
                    // nil 有两种含义：读完了 / 中途挂了。不查 status 分不出来
                    if reader.status == .failed {
                        throw BKExportError.readFailed(
                            reader.error?.localizedDescription ?? "读取器中途失败（无详细信息）")
                    }
                    videoDone = true
                    fedAnything = true
                }
            }

            if !audioDone, let aOut = audio, let aIn = audioInput,
               aIn.isReadyForMoreMediaData {
                if let sb = aOut.copyNextSampleBuffer() {
                    guard aIn.append(sb) else {
                        throw BKExportError.writeFailed(
                            writer.error?.localizedDescription ?? "音频写入失败")
                    }
                    fedAnything = true
                } else {
                    if reader.status == .failed {
                        throw BKExportError.readFailed(
                            reader.error?.localizedDescription ?? "读取器中途失败（无详细信息）")
                    }
                    audioDone = true
                    fedAnything = true
                }
            }

            if fedAnything {
                idleRounds = 0
            } else {
                // 两条通道都堵着：让出 CPU 等 writer 消化，别让它俩空转抢锁。
                // 背压等待本身是正常的，不该判死刑 —— 所以计数上限很宽
                idleRounds += 1
                Thread.sleep(forTimeInterval: 0.005)
                if idleRounds > 4000 {
                    var extra = ""
                    if let e = writer.error {
                        extra = "（writer：\(e.localizedDescription)）"
                    }
                    throw BKExportError.writeFailed("视频/音频通道同时超过 20 秒不就绪\(extra)")
                }
            }
        }

        tick(total)
        if droppedFrames > 0 {
            BKLog.shared.d("降帧：丢掉 \(droppedFrames) 帧")
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
