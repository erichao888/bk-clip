//
//  BKJointBuilder.swift
//  bk剪辑 — 联播键的「拼起来播」
//
//  【联播键（皓哥命名，不是"连播"）】定稿 4.5.4：
//  把绿区临时接成一条再放，全程连贯不断，等于**预演成品**。
//
//  【为什么不导出成文件再播】
//  又慢又占空间，还多一份临时垃圾要清理。
//  AVMutableComposition 拼好直接给 AVPlayerItem 播，秒开，播完自动没。
//
//  【接缝必须跟导出一致】
//  联播存在的唯一目的就是**听接缝** —— 气口去干净没、接得顺不顺。
//  所以接缝处理必须和导出一样做 15ms 淡入淡出，不一致就白听了。
//  这里用 AVAudioMix 的音量斜坡实现（导出那边是 ffmpeg 的 afade，时长同一个数）。
//
//  【方向：联播的画面也不能躺】
//  composition 里的视频轨是新建的，它的 preferredTransform 默认是 identity。
//  不把源素材的 preferredTransform 抄过去，联播的画面就会横过来 ——
//  方向铁律在这里是第 6 个落点。
//
//  【成品时间 ↔ 原片时间】
//  主轨道画的是原片时间轴，联播放的是成品，两边长度不一样。
//  播放中要反查：成品时间 → 查它落在哪个 keep 段 → 加该段在原片的起点 → 原片时间。
//  这样指针在轨道上一路走、遇红区「跨」过去一小段，画面连贯又跟轨道不脱节。
//

import AVFoundation

enum BKJointBuilder {

    /// 拼好的一条成品。segments 是「成品 → 原片」的对照表
    struct Joint {
        let item: AVPlayerItem
        /// (成品起点, 原片起点, 时长)
        let segments: [(out: Double, src: Double, dur: Double)]
        /// 成品总时长
        let total: Double

        /// 成品时间 → 原片时间。超出范围就夹到两端，别返回 nil 让调用方崩
        func sourceTime(at outputTime: Double) -> Double {
            for s in segments {
                if outputTime >= s.out && outputTime <= s.out + s.dur {
                    return s.src + (outputTime - s.out)
                }
            }
            if let first = segments.first, outputTime < first.out { return first.src }
            if let last = segments.last { return last.src + last.dur }
            return 0
        }

        /// 原片时间 → 成品时间（联播起播时要把指针位置换成成品位置）
        func outputTime(at sourceTime: Double) -> Double {
            for s in segments {
                if sourceTime >= s.src && sourceTime <= s.src + s.dur {
                    return s.out + (sourceTime - s.src)
                }
            }
            // 落在红区里：跳到下一个绿区的开头
            for s in segments where s.src > sourceTime {
                return s.out
            }
            return 0
        }
    }

    /// 按 keepRanges 拼一条临时 composition。segments 为空返回 nil
    static func build(asset: AVAsset, keeps: [(Double, Double)]) -> Joint? {
        guard !keeps.isEmpty else { return nil }
        guard let srcVideo = asset.tracks(withMediaType: .video).first else { return nil }

        let comp = AVMutableComposition()
        guard let dstVideo = comp.addMutableTrack(withMediaType: .video,
                                                  preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        // 方向：composition 的轨道是新建的，必须把源素材的变换抄过来，否则画面躺下
        dstVideo.preferredTransform = srcVideo.preferredTransform

        var cursor = CMTime.zero
        var table: [(out: Double, src: Double, dur: Double)] = []

        for (a, b) in keeps {
            let start = CMTime(seconds: a, preferredTimescale: 600)
            let dur = CMTime(seconds: max(0, b - a), preferredTimescale: 600)
            guard dur.seconds > 0 else { continue }
            let range = CMTimeRange(start: start, duration: dur)
            do {
                try dstVideo.insertTimeRange(range, of: srcVideo, at: cursor)
            } catch {
                BKLog.shared.w("联播插入视频段失败：\(error.localizedDescription)")
                continue
            }
            table.append((out: cursor.seconds, src: a, dur: dur.seconds))
            cursor = cursor + dur
        }
        guard !table.isEmpty else { return nil }

        // ---- 音频轨 + 接缝淡入淡出 ----
        let fade = BKConfig.Seam.crossFadeSec
        if let srcAudio = asset.tracks(withMediaType: .audio).first,
           let dstAudio = comp.addMutableTrack(withMediaType: .audio,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) {
            let params = AVMutableAudioMixInputParameters(track: dstAudio)
            var audioCursor = CMTime.zero

            for (a, b) in keeps {
                let start = CMTime(seconds: a, preferredTimescale: 600)
                let dur = CMTime(seconds: max(0, b - a), preferredTimescale: 600)
                guard dur.seconds > 0 else { continue }
                let range = CMTimeRange(start: start, duration: dur)
                do {
                    try dstAudio.insertTimeRange(range, of: srcAudio, at: audioCursor)
                } catch {
                    BKLog.shared.w("联播插入音频段失败：\(error.localizedDescription)")
                    audioCursor = audioCursor + dur
                    continue
                }

                // 跟导出一致的 15ms：段首淡入、段尾淡出。
                // 太短的段不做（fade 比段还长的话两条斜坡会打架）
                if dur.seconds > fade * 2.5 {
                    let fadeT = CMTime(seconds: fade, preferredTimescale: 600)
                    params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                                         timeRange: CMTimeRange(start: audioCursor, duration: fadeT))
                    params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                         timeRange: CMTimeRange(start: audioCursor + dur - fadeT,
                                                                duration: fadeT))
                }
                audioCursor = audioCursor + dur
            }

            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]

            let item = AVPlayerItem(asset: comp)
            item.audioMix = mix
            return Joint(item: item, segments: table, total: cursor.seconds)
        }

        let item = AVPlayerItem(asset: comp)
        return Joint(item: item, segments: table, total: cursor.seconds)
    }

    /// 联播的起播位置（定稿 4.5.5）：
    ///   起点就落在绿区里 → 从那儿直接播
    ///   起点落在红区里   → 往下跳到第一个绿区的开头
    /// 跳转是瞬间的 —— 界面上会看到指针往右挪一小段然后开始播，不是慢慢滑过去
    static func startKeptTime(for t: Double, keeps: [(Double, Double)]) -> Double? {
        for (a, b) in keeps where b > t + 0.001 {
            return max(t, a)
        }
        return nil
    }
}
