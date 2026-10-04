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
    /// (成品起点, 原片起点, 时长)
    let table: [(out: Double, src: Double, dur: Double)]
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

        var cursor = CMTime.zero
        var table: [(out: Double, src: Double, dur: Double)] = []

        for (a, b) in keeps {
            let len = b - a
            guard len > 0.01 else { continue }
            let start = CMTime(seconds: a, preferredTimescale: 600)
            let dur = CMTime(seconds: len, preferredTimescale: 600)
            let range = CMTimeRange(start: start, duration: dur)
            do {
                try dstVideo.insertTimeRange(range, of: srcVideo, at: cursor)
            } catch {
                // 插不进去就跳过这一段，**不要静默吞掉** —— 用户会看到成品比预期短
                BKLog.shared.w("拼视频段失败 [\(BKDiag.s(a))→\(BKDiag.s(b))]：\(error.localizedDescription)")
                continue
            }
            table.append((out: cursor.seconds, src: a, dur: dur.seconds))
            cursor = cursor + dur
        }
        guard !table.isEmpty else { return nil }

        // ---- 音频轨（可选淡入淡出）----
        if let srcAudio = asset.tracks(withMediaType: .audio).first,
           let dstAudio = comp.addMutableTrack(withMediaType: .audio,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) {
            var audioCursor = CMTime.zero
            for (a, b) in keeps {
                let len = b - a
                guard len > 0.01 else { continue }
                let start = CMTime(seconds: a, preferredTimescale: 600)
                let dur = CMTime(seconds: len, preferredTimescale: 600)
                let range = CMTimeRange(start: start, duration: dur)
                do {
                    try dstAudio.insertTimeRange(range, of: srcAudio, at: audioCursor)
                } catch {
                    // 音频插失败比视频更严重（会真的丢内容），必须报出来
                    BKLog.shared.w("拼音频段失败 [\(BKDiag.s(a))→\(BKDiag.s(b))]：\(error.localizedDescription)")
                    audioCursor = audioCursor + dur
                    continue
                }
                audioCursor = audioCursor + dur
            }
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

    /// 成品时间 → 原片时间
    static func sourceTime(_ build: BKCompositionBuild, outputTime: Double) -> Double {
        for seg in build.table {
            if outputTime >= seg.out && outputTime <= seg.out + seg.dur {
                return seg.src + (outputTime - seg.out)
            }
        }
        if let first = build.table.first, outputTime < first.out { return first.src }
        if let last = build.table.last { return last.src + last.dur }
        return 0
    }
}
