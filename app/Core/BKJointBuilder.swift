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

    /// 联播的起播位置（定稿 4.5.5）—— 返回的是**原片时间**，不是成品时间！
    ///
    /// 【2026-10-04 修：v1.2.14 联播不从指针处开始】
    /// 两个 bug 叠在一起：
    /// ① 判定顺序错：老写法 `for (a,b) in keeps where b > t + 0.001 { return max(t, a) }`
    ///    靠「第一个还没结束的段」来间接判断在绿区还是在红区。指针正好落在**绿区结束边界**上时
    ///    （a=0.63,b=0.69, t=0.69），b > t 不成立 → 被判成红区 → 白跳一段。
    /// ② 单位错配（这才是主因）：本函数返回的是原片时间，调用方却拿它当**成品时间**去 seek。
    ///    联播播的是拼起来的成品（长度 = 各绿区之和，比原片短），两个时间轴根本不是一个数。
    ///    实测：指针在原片 1.745s（绿区2 内部），正确成品位置 0.415s，却 seek 到 1.745s —— 错位 1330ms。
    ///    `Joint.outputTime(at:)` 就是干换算的，v1.2.14 之前**从来没被调用过**。
    ///
    /// 皓哥要的逻辑（2026-10-04 定）：
    ///   指针在绿区 → 从**指针处**开始播
    ///   指针在红区 → 跳到**下一个绿区**开头
    ///
    /// 注意边界用 `1e-9` 而不是老的 `0.001`：
    ///   「绿区结束边界上」按 4.5.5 属于**绿区**，就该就地播；
    ///   老的 0.001 容差（1ms）会把结束前 0.5ms 也算进绿区，边界判定跟着飘。
    static func startKeptTime(for t: Double, keeps: [(Double, Double)]) -> Double? {
        guard !keeps.isEmpty else { return nil }
        // 1) 指针就落在某个绿区里（含两端边界）→ 从指针处播
        for (a, b) in keeps {
            if t >= a - 1e-9 && t <= b + 1e-9 { return t }
        }
        // 2) 落在红区 → 往后找第一个「起点在 t 之后」的绿区，跳它的开头
        for (a, _) in keeps where a > t + 1e-9 { return a }
        // 3) 已经在最后一个绿区之后 → 播最后一个绿区的结尾（老代码返回 nil 会误报
        //    「指针后面没有绿区了」，其实还有内容可播，只是不再往后跳了）
        return keeps[keeps.count - 1].1
    }
}
