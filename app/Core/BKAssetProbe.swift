//
//  BKAssetProbe.swift
//  bk剪辑 — 素材几何探针
//
//  【这个文件是第 01 章埋点规范第 1 条的实现】
//  「视频导入后 —— 记真实显示比例」
//
//  为什么值得为这一段单独开一个文件：
//  iPhone 拍的视频存在文件里永远是横的 1920×1080，靠一个 rotation 标记
//  让播放器转过来。只读 naturalSize 会把竖屏素材报成横屏 —— 后果是
//  预览区变形、导出黑边、成品躺在剪映里，而且报错信息完全指不到这里。
//
//  所以全工程只有这一个地方负责「素材到底多大、朝哪边」这个问题。
//  别处要尺寸一律从这里拿，不准自己去读 naturalSize。
//

import AVFoundation
import CoreGraphics

enum BKAssetProbe {

    struct Info {
        /// 素材时长（秒）
        let duration: Double
        /// 原始像素尺寸。这个值在 iPhone 素材上几乎永远是横排的那一组，
        /// 没有十足把握别拿它做 UI 决策 —— 用下面那个 display 尺寸
        let naturalWidth: Double
        let naturalHeight: Double
        /// 真实显示尺寸（应用 preferredTransform 之后）。UI 和导出只认这个
        let displayWidth: Double
        let displayHeight: Double
        var isPortrait: Bool { displayHeight > displayWidth }
        /// 旋转角度（度）：0 / 90 / 180 / 270。导出时原样喂给 writerInput.transform
        let rotationDegrees: Double
        /// 帧率。导出必须跟随源素材，写死数字会让画面一卡一卡的
        let fps: Double
        /// 视频轨道估算码率（kbps）
        let estimatedBitrateKbps: Int
        /// 是否有音频轨道。没有的话整套去气口逻辑就无从谈起
        let hasAudio: Bool

        /// 给日志用的一行摘要。格式刻意写得能被 grep 到：
        /// 真机上拷出日志文件后，直接 grep "导入素材" 就能看到全部历史
        var logLine: String {
            let dir = isPortrait ? "竖" : "横"
            return String(
                format: "导入素材 %.2fs | 原始 %.0f×%.0f 旋转后 %.0f×%.0f | 朝向 %@ | 旋转 %.0f° | %.2ffps | 码率 %dkbps | 音轨 %@",
                duration, naturalWidth, naturalHeight,
                displayWidth, displayHeight, dir,
                rotationDegrees, fps, estimatedBitrateKbps,
                hasAudio ? "有" : "无"
            )
        }
    }

    /// 探测一条素材的全部几何信息。同步调用，首次开轨道会有几十毫秒开销。
    /// 调用方负责放到后台线程 —— 主线程卡这一下就会有肉眼可见的顿挫
    static func probe(_ asset: AVAsset) -> Info {
        let videoTrack = asset.tracks(withMediaType: .video).first
        let audioTrack = asset.tracks(withMediaType: .audio).first

        let natural = videoTrack?.naturalSize ?? .zero
        let transform = videoTrack?.preferredTransform ?? .identity

        // 铁律①：必须过一遍 preferredTransform，直接用 naturalSize 是错的
        let real = natural.applying(transform)
        let displayW = abs(real.width)
        let displayH = abs(real.height)

        let seconds = asset.duration.seconds
        if !seconds.isFinite || seconds <= 0 {
            BKLog.shared.w("素材时长读不出来（\(seconds)），检查是否完成下载")
        }

        return Info(
            duration: max(seconds, 0),
            naturalWidth: natural.width,
            naturalHeight: natural.height,
            displayWidth: displayW,
            displayHeight: displayH,
            rotationDegrees: rotationDegrees(from: transform),
            fps: fps(of: videoTrack),
            estimatedBitrateKbps: Int((videoTrack?.estimatedDataRate ?? 0) / 1000),
            hasAudio: audioTrack != nil
        )
    }

    // MARK: - 内部

    /// 从变换矩阵换算旋转角度。
    /// 用 atan2 而不是逐个矩阵值比对 —— 后者只能覆盖四种标准旋转，
    /// 遇到自拍镜像（a 或 d 为负）会直接给出一个错误答案
    static func rotationDegrees(from t: CGAffineTransform) -> Double {
        let radians = atan2(t.b, t.a)
        var deg = radians * 180.0 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }

    static func fps(of track: AVAssetTrack?) -> Double {
        // 不写成 guard let track 的简写形式：那种写法要 Swift 5.7 编译器，
        // 云端机器上的 Xcode 版本不由我们说了算，没必要为省几个字符冒险
        guard let track = track, track.nominalFrameRate > 0 else { return 30 }
        return Double(track.nominalFrameRate)
    }
}
