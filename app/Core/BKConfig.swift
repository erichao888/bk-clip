//
//  BKConfig.swift
//  bk剪辑 — 全局配置与调参中枢
//
//  【这个文件为什么独立存在】
//  算法参数是整个 App 唯一的旋钮集合。它们散落在各个类里会很难调：
//  改一个数要翻三个文件，而且容易改漏一半导致行为飘忽。
//  集中在这里，调参只需要动这一个文件。
//
//  【铁律：这里的每个数都必须和 tools/preview_cut.py 一致】
//  Python 脚本是你在电脑上预演算法的尺子，Swift 是真机上跑的刀。
//  尺子和刀不一致，你在电脑上调好的参数到真机上就是另一回事。
//  每次改这个文件，同步改 Python 里那一处，并在两边的注释里都标一句。
//
//  【单位约定】时间一律秒（Double），一切数据处理在 Double 域进行，
//  只在最后转成 CMTime 一次。CMTime 反复做加减会积累 timescale 误差。
//

import Foundation

enum BKConfig {

    // MARK: - 版本

    /// 展示版本号，必须和 release/version.json 的 version 保持一致
    static let appVersion = "1.0.0"
    static let buildNumber = 1

    // MARK: - 气口检测参数
    //
    // 这四个数是「防碎」四重保险，缺一不可。它们的来历和边界都在
    // docs/免费验证方案.md 里逐条验证过，别凭感觉改。

    enum Detect {

        /// 相邻两段气口之间至少保留这么长的有效内容。
        /// 小于它的会被合并回去 —— 连续两刀中间夹 0.1 秒内容，切出来像卡碟。
        /// 这一条决定「片段不会碎」
        static let minGap: Double = 0.20

        /// 单个保留片段的最短时长。低于它的片段会被并进邻居。
        /// 这一条决定「不会有孤零零的碎片」
        static let minSegment: Double = 0.60

        /// 单次切除的最短时长。0.05 秒这种刀肉眼根本看不出来，
        /// 却多一次接缝爆音风险 —— 收益接近零，风险实打实。
        /// 这一条是最后加的第 4 个参数（原打算不做，被真实素材教做人）
        static let minCut: Double = 0.10

        /// 每个气口两端各保留这么长，不切干净。
        /// 切到零点辅音会丢，听感上「字被剁掉一半」
        static let pad: Double = 0.10

        /// dB 阈值的安全夹逼区间。Otsu 算出的原始值落在这外面就拉回来。
        /// 上界 -25 是硬边界：再往上会把探店现场的环境声当静音切掉
        static let clampLow: Double = -50.0
        static let clampHigh: Double = -25.0

        /// 适用性判据：相邻半秒段最大值的起伏低于这个值，
        /// 说明整条素材响度是平的 —— 带 BGM 或做过响度归一化的成品视频
        /// 从原理上无法用静音检测去气口，判死刑并给用户明确提示
        static let minContrastDb: Double = 6.0

        /// 低于这个电平的帧占比，用来辅助判断素材是不是「太安静」
        static let silenceFloorDb: Double = -45.0
    }

    // MARK: - 包络提取

    enum Envelope {
        /// 分析窗长（毫秒）。20ms 是语音短时分析的标准窗
        static let frameMs: Int = 20
        /// 跳距（毫秒）。10ms = 50% 重叠，太疏会漏掉短气口
        static let hopMs: Int = 10
    }

    // MARK: - 素材类型默认阈值
    //
    // App 里放两套默认值：因为不同拍摄环境的底噪水平差得离谱，
    // 想用一套参数通吃，只会两头不讨好。

    enum Preset {
        /// 录音室 / 安静室内口播：底噪极低（-55~-60dB），阈值可以压很低
        static let studioRange: ClosedRange<Double> = -50.0 ... -33.0
        /// 探店外拍（默认）：环境声常顶在 -32~-35dB，Otsu 会被夹逼到上界，
        /// 所以给一段更窄但更贴实际的有效区间。
        /// 这个区间来自两条真实素材（IMG_2969 / IMG_2981）的实测，不是估的
        static let fieldRange: ClosedRange<Double> = -33.0 ... -25.0
    }

    // MARK: - 导出规格
    //
    // 这套参数已经在真 · 剪映上验证通过（2026-10-02 皓哥实测导入正常）。
    // 改任何一个之前先问一句：改了还能不能进剪映？不能就别改。

    enum Export {
        /// CRF。18~20 是画质和体积的甜点区，低于 18 体积暴涨肉眼无感
        static let crf: Int = 20
        /// 预设。veryfast 已足够，medium 换来的体积收益不值当多出的导出时间
        static let preset = "veryfast"
        /// 像素格式。必须是 yuv420p —— 10bit 的片子在部分设备上放不了
        static let pixelFormat = "kCVPixelFormatType_420YpCbCr8Planar"
        /// 关键帧间隔（秒）。1 秒是给后期留的余地：
        /// 剪映里二次拖动、补刀时吸附点密一些更跟手。
        /// 注意：这与「导出用精确重编码、不走关键帧吸附」不矛盾 ——
        /// 我们是先精确切好再编码，这一步设的是输出流的 GOP
        static let keyframeIntervalSec: Double = 1.0
        /// 音频。AAC-LC 兼容性最好，HE-AAC 有设备不认
        static let audioBitrateKbps = 192
        /// 必须开。不开的话网络播放要等整个文件下完，
        /// 而且部分 Android / 网页端解析会直接失败
        static let faststart = true
    }

    // MARK: - 接缝处理

    enum Seam {
        /// 零点对齐容差。把切口收缩到 ±10ms 内的零点上，切在这里不会爆音
        static let zeroCrossToleranceSec: Double = 0.010
        /// 交叉淡化时长。即使做了零点对齐也留这道防线 ——
        /// 波形上的零点不等于听感上的无感，15ms 足以抹掉残余的 Click
        static let crossFadeSec: Double = 0.015
    }

    // MARK: - 自动保存

    enum Draft {
        /// debounce 秒数。改了阈值之类的操作是连续的，
        /// 每次都落盘会拖慢滑动的手感，攒 2 秒再写刚好
        static let debounceSec: Double = 2.0
        /// 单个工程保留多少个历史版本。多了占空间，少了不够用
        static let keepHistory = 5
    }

    // MARK: - 性能红线
    //
    // 这几个数不是配置项，是告警线。超了就说明实现有问题，要去改代码而不是改数字。

    enum Limit {
        /// 波形提取超过这个秒数就该优化算法（19秒素材实测 3.8 秒）
        static let envelopeWarnSec: Double = 5.0
        /// App 占用内存告警线（MB）。后台导出时 4K 素材容易顶到这
        static let memoryWarnMB: Double = 400.0
    }
}
