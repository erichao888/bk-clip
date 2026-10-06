//
//  BKCompositionBuilder.swift
//  bk剪辑 — 导出/联播共用的「按保留段拼一条」逻辑（v1.3.4）
//
//  【这个文件存在的唯一理由：根治音画不同步】
//
//  v1.3.0 ~ v1.3.4 导出是「逐段 AVAssetReader + 手算 PTS 偏移」自己拼的，
//  音画同步连修三次全错：
//    v1.2.15  按标称段长推进，样本照写        → 末尾溢出与下段重叠 → 错位累积
//    v1.3.2  按「两轨较大值」推进             → 短轨留空洞 → 播放器静音/冻结该轨
//    v1.3.4  标称推进 + 样本不越界（加锚点）  → 真机仍「越往后面越大」
//
//  第三次失败暴露了根本问题：**我在脑内模拟 AVFoundation 的样本行为，而那是我看不到的**。
//  视频帧有 B 帧（DTS ≠ PTS）、`CMSampleBufferGetDuration` 不等于一帧长、
//  音频块长也不等于 1024/48000 —— 我用的全是**猜的值**，所以「不越界检查」的阈值本身就是错的，
//  误差逐段累积。Python 复刻说「四条样片全绿」，但那只是**我的模型绿**，不是真机绿。
//
//  【正解：不手算任何一个 PTS】
//  `AVMutableComposition.insertTimeRange` 由系统保证：
//    · 插入的片段在时间轴上首尾相接、连续无空洞
//    · 音视频两条轨**天然对齐**（它们插的是同一批 timeRange）
//  所以只要把保留区间交给它，音画同步就是系统的事，我们不参与。
//
//  【额外收益：预演 = 导出】
//  联播（BKJointBuilder）和导出共用 `makeComposition`，
//  于是「联播里听到的效果」和「导出的成品」必然一致 ——
//  以前是两套代码、两种拼法，理论上可能对不上。
//

import Foundation
import AVFoundation

/// 拼好的成品：composition 本身 + 「成品时间 ↔ 原片时间」对照表
struct BKCompositionBuild {
    let comp: AVMutableComposition
    /// (成品起点 out, 源起点 src, 成品时长 dur, 倍速 speed)
    /// ⚠️ dur 是**成品时长**（已除 speed）；对应源时长 = dur * speed。
    /// 变速时源时间以 speed 倍速推进，所以反查源时间必须带上 speed
    let table: [(out: Double, src: Double, dur: Double, speed: Double)]
    var total: Double { table.last.map { $0.out + $0.dur } ?? 0 }
}

enum BKCompositionBuilder {

    /// 按保留区间拼一条完整的多媒体轨。
    ///
    /// - Parameters:
    ///   - keeps: 保留区间（**原片时间**）。第二阶段直接传记录B；第一阶段传从 cuts 派生的 keepRanges
    /// - Returns: 失败返回 nil（没有可保留段 / 取不到视频轨）
    ///
    /// 接缝淡入淡出**不在这里做**：audioMix 要挂在 AVPlayerItem 上才生效（联播），
    /// 而导出走 AVAssetWriter，挂法不同 → 见 `makeFadeMix`。
    static func make(asset: AVAsset, keeps: [(Double, Double)]) -> BKCompositionBuild? {
        guard !keeps.isEmpty else { return nil }
        guard let srcVideo = asset.tracks(withMediaType: .video).first else { return nil }

        let comp = AVMutableComposition()
        guard let dstVideo = comp.addMutableTrack(withMediaType: .video,
                                                  preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        // 方向铁律在导出链路的第 7 个落点：composition 的轨道是新建的，
        // 必须把源素材的 preferredTransform 抄过去，否则画面横躺。
        dstVideo.preferredTransform = srcVideo.preferredTransform

        // ⚠️⚠️ **v1.4.3 闪退的真病根在这里**（2026-10-04 19:50 皓哥真机报障）
        //
        // 原来视频轨和音频轨是**各自独立**循环、各自 `continue`：
        //   某段视频 insert 成功、音频 insert 失败（或反之）→ 两轨段数/长度不一致
        //   → AVAssetWriter 收尾阶段报错 → **finishWriting 的 completion 不触发**
        //   → 调用方 `sem.wait()` 永等 → 主线程卡死 → iOS 杀进程 = 「闪退」
        //
        // ⚠️ 关键难点：`AVMutableComposition` **没有「删除已插入区间」的 API**。
        // 所以一旦某轨插进去、另一轨失败，就没法回退，composition 会多出一段
        // 只有画面没有声音的内容。
        //
        // 正解：**先用「探测」确定这一段两轨都能插，再真正插**。
        // 探测用 `sourceTrack.hasMediaDuration` 之类不可靠，改用最稳的：
        // **按素材真实时长夹一遍**（`AVAsset.duration`）—— 越界的段在夹完后必然可插，
        // 剩下插不进去的段是素材本身的空洞，两轨会**同时**失败 → 整段跳过，
        // 保证两轨永远成对。
        let assetDur = CMTimeGetSeconds(asset.duration)
        var dstAudioRef: AVMutableCompositionTrack?
        if let sa = asset.tracks(withMediaType: .audio).first,
           let da = comp.addMutableTrack(withMediaType: .audio,
                                         preferredTrackID: kCMPersistentTrackID_Invalid) {
            dstAudioRef = da
            _ = sa
        }

        var cursor = CMTime.zero
        var audioCursor = CMTime.zero
        var table: [(out: Double, src: Double, dur: Double, speed: Double)] = []
        var skipped = 0

        for (a0, b0) in keeps {
            // ① 先按素材真实时长夹取。越界的段（第二阶段拖把手拖过了头）在这里被夹住，
            //    后面两轨就都能插 —— 不会造成两轨不一致
            let a = max(0, min(a0, assetDur))
            let b = max(a, min(b0, assetDur))
            let len = b - a
            guard len > 0.01 else { skipped += 1; continue }
            let start = CMTime(seconds: a, preferredTimescale: 600)
            let dur = CMTime(seconds: len, preferredTimescale: 600)
            let range = CMTimeRange(start: start, duration: dur)

            // ② 音频先试（音频更容易失败：有的片段根本没采样）
            var audioOK = true
            if let da = dstAudioRef, let sa = asset.tracks(withMediaType: .audio).first {
                do {
                    try da.insertTimeRange(range, of: sa, at: audioCursor)
                } catch {
                    BKLog.shared.w("拼音频段失败 [\(BKDiag.s(a))→\(BKDiag.s(b))]：\(error.localizedDescription)")
                    audioOK = false
                }
            }
            if !audioOK {
                // 音频没插进去，视频也**不要**插 —— 两轨必须成对
                skipped += 1
                continue
            }

            // ③ 视频后试。理论上此时必然成功（已经夹过时长）；
            //    万一失败，这段视频缺失但音频已在 —— 记进日志，成品会有一小段无声
            do {
                try dstVideo.insertTimeRange(range, of: srcVideo, at: cursor)
            } catch {
                BKLog.shared.w("拼视频段失败 [\(BKDiag.s(a))→\(BKDiag.s(b))]：\(error.localizedDescription)")
                skipped += 1
                cursor = cursor + dur
                audioCursor = audioCursor + dur
                continue
            }

            table.append((out: cursor.seconds, src: a, dur: dur.seconds, speed: 1.0))
            cursor = cursor + dur
            audioCursor = audioCursor + dur
        }
        guard !table.isEmpty else { return nil }
        if skipped > 0 {
            BKLog.shared.w("拼接跳过 \(skipped)/\(keeps.count) 段（音视频成对，不留半个）")
        }

        return BKCompositionBuild(comp: comp, table: table)
    }

    // MARK: - 多素材主轨拼接（v2）

    /// 主轨上的一个块 = 一个素材 + 它的绿区（源时间）+ 倍速
    struct Part {
        let asset: AVAsset
        /// 展示名（日志/失败报告用，不参与拼接）
        let name: String
        let keeps: [(Double, Double)]
        let speed: Double
    }

    /// 把整条主轨（N 块、可能来自不同素材）拼成一条 composition。
    ///
    /// 【和 make 的区别】make 是「一个素材里的多段」；makeMain 是「多素材多段」。
    /// 拼法完全同一套：**先音频后视频、成对插入**（v1.4.3 教训），
    /// 每段插完把 [cursor, cursor+源长) 缩放到 源长/speed —— 这就是逐块变速，
    /// 不需要算任何 PTS（铁律：out == trackT，先折叠再变速）。
    ///
    /// 【朝向】composition 一条轨只能挂一个 transform，取**第一块有视频轨的**素材的。
    /// 皓哥的素材全是同一台手机拍的，实践里一致；混入不同朝向时按第一块出并记警告。
    ///
    /// 【音频音高】铁律：变速**保持音高**。音频轨挂 `.spectral` 算法（变调不变速的反义词：
    /// 变速不变调），由 scaleTimeRange 触发重采样。
    static func makeMain(_ parts: [Part]) -> BKCompositionBuild? {
        guard !parts.isEmpty else { return nil }

        guard let anchor = parts.first(where: {
            $0.asset.tracks(withMediaType: .video).first != nil
        }), let srcVideo0 = anchor.asset.tracks(withMediaType: .video).first else {
            return nil
        }

        let comp = AVMutableComposition()
        guard let dstVideo = comp.addMutableTrack(withMediaType: .video,
                                                  preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        dstVideo.preferredTransform = srcVideo0.preferredTransform

        var dstAudio: AVMutableCompositionTrack?
        if let da = comp.addMutableTrack(withMediaType: .audio,
                                         preferredTrackID: kCMPersistentTrackID_Invalid) {
            da.audioTimePitchAlgorithm = .spectral     // 变速保持音高（铁律）
            dstAudio = da
        }

        var cursor = CMTime.zero
        var table: [(out: Double, src: Double, dur: Double, speed: Double)] = []
        var skipped = 0
        var mixedOrientationWarned = false

        for part in parts {
            guard let sv = part.asset.tracks(withMediaType: .video).first else {
                BKLog.shared.w("主轨拼接：块「\(part.name)」取不到视频轨，整块跳过")
                skipped += 1
                continue
            }
            if sv.preferredTransform != srcVideo0.preferredTransform && !mixedOrientationWarned {
                mixedOrientationWarned = true
                BKLog.shared.w("主轨里混了不同朝向的素材，成品统一按第一块的朝向输出")
            }
            let sa = part.asset.tracks(withMediaType: .audio).first
            let assetDur = CMTimeGetSeconds(part.asset.duration)
            // ★ speed 夹回 [0.1, 4]（规格补充B 拍板的档位边界），非法值按 1 走
            let sp = (part.speed > 0.1 - 1e-9 && part.speed < 4.0 + 1e-9) ? part.speed : 1.0

            for (a0, b0) in part.keeps {
                // ① 按素材真实时长夹一遍 —— 越界段两轨都插不进去，先夹再插保证成对
                let a = max(0, min(a0, assetDur))
                let b = max(a, min(b0, assetDur))
                let len = b - a
                guard len > 0.01 else { skipped += 1; continue }
                let range = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600),
                                        duration: CMTime(seconds: len, preferredTimescale: 600))

                // ② 音频先试（更易失败）；没有音轨的素材这一步自然跳过（成对 = 两轨都没有）
                var audioInserted = false
                if let da = dstAudio, let sa = sa {
                    do {
                        try da.insertTimeRange(range, of: sa, at: cursor)
                        audioInserted = true
                    } catch {
                        let m = "「\(part.name)」[\(BKDiag.s(a))→\(BKDiag.s(b))] 拼音频失败：\(error.localizedDescription)"
                        BKLog.shared.w(m)
                    }
                }
                if dstAudio != nil && sa != nil && !audioInserted {
                    // 有音轨却插失败 → 整段跳过（两轨必须成对，不许半个）
                    skipped += 1
                    continue
                }

                // ③ 视频后试
                do {
                    try dstVideo.insertTimeRange(range, of: sv, at: cursor)
                } catch {
                    let m = "「\(part.name)」[\(BKDiag.s(a))→\(BKDiag.s(b))] 拼视频失败：\(error.localizedDescription)"
                    BKLog.shared.w(m)
                    skipped += 1
                    cursor = cursor + range.duration
                    continue
                }

                // ④ 逐块变速：把刚插好的 [cursor, cursor+源长) 缩放到 源长/speed
                let outLen = len / sp
                if abs(sp - 1.0) > 1e-9 {
                    let target = CMTime(seconds: outLen, preferredTimescale: 600)
                    dstVideo.scaleTimeRange(range, toDuration: target)
                    // 音频只在「这段真有素材」时缩。没素材的空区间缩放会越界炸
                    // （ObjC 异常 Swift 接不住），且 speed≠1 目前没有 UI 入口，
                    // 真出现「无声块 + 变速」组合时按视频走、记警告
                    if audioInserted {
                        dstAudio?.scaleTimeRange(range, toDuration: target)
                    } else if let da = dstAudio,
                              CMTimeGetSeconds(da.timeRange.duration) < cursor.seconds + len {
                        BKLog.shared.w("块「\(part.name)」变速时音频轨没有对齐素材（无声块），后续音频位置可能偏移")
                    }
                }

                table.append((out: cursor.seconds, src: a, dur: outLen, speed: sp))
                cursor = cursor + CMTime(seconds: outLen, preferredTimescale: 600)
            }
        }

        guard !table.isEmpty else { return nil }
        if skipped > 0 {
            BKLog.shared.w("主轨拼接跳过 \(skipped) 段（音视频成对，不留半个）")
        }
        return BKCompositionBuild(comp: comp, table: table)
    }

    /// 给拼好的 composition 生成接缝淡入淡出的 audioMix。**联播专用**。
    ///
    /// 为什么要单独返回而不是在 make 里挂：audioMix 要挂在 `AVPlayerItem` 上才生效，
    /// 而导出走的是 AVAssetWriter，两者挂法不同。
    static func makeFadeMix(_ build: BKCompositionBuild) -> AVMutableAudioMix? {
        guard let dstAudio = build.comp.tracks(withMediaType: .audio).first else { return nil }
        let fade = BKConfig.Seam.crossFadeSec
        let params = AVMutableAudioMixInputParameters(track: dstAudio)
        var cursor = CMTime.zero
        for seg in build.table {
            // 太短的段不做（fade 比段还长的话两条斜坡会打架）
            if seg.dur > fade * 2.5 {
                let fadeT = CMTime(seconds: fade, preferredTimescale: 600)
                params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                                     timeRange: CMTimeRange(start: cursor, duration: fadeT))
                params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                     timeRange: CMTimeRange(start: cursor + CMTime(seconds: seg.dur, preferredTimescale: 600) - fadeT,
                                                            duration: fadeT))
            }
            cursor = cursor + CMTime(seconds: seg.dur, preferredTimescale: 600)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    /// 成品时间 → 原片时间。变速段里源时间以 speed 倍速推进
    static func sourceTime(_ build: BKCompositionBuild, outputTime: Double) -> Double {
        for seg in build.table {
            if outputTime >= seg.out && outputTime <= seg.out + seg.dur {
                return seg.src + (outputTime - seg.out) * seg.speed
            }
        }
        if let first = build.table.first, outputTime < first.out { return first.src }
        if let last = build.table.last { return last.src + last.dur * last.speed }
        return 0
    }
}
