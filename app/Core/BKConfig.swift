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

    /// 展示版本号。**唯一真源是 project.yml 的 MARKETING_VERSION**，经 Info.plist 注入后
    /// 在这里从 Bundle 读出——不再写死字面量（v1.2.3 前写死 "1.0.0"，草稿页一直显示假版本号）。
    /// 若取不到（理论上不会）回落 "1.0.0" 兜底。
    static let appVersion =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "1.0.0"
    /// build 号，同上读 CURRENT_PROJECT_VERSION
    static let buildNumber =
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 1

    // MARK: - 气口检测参数
    //
    // 这四个数是「防碎」四重保险，缺一不可。它们的来历和边界都在
    // docs/免费验证方案.md 里逐条验证过，别凭感觉改。

    //
    // ⚠️ 这五个数是 2026-10-02 晚按皓哥的手工刀口重定的，来源是
    // docs/算法定稿.md 第 1 节的参数表，逐项对过 tools/preview_cut.py。
    // 改任何一个数之前先看那份定稿的三条方向原则：
    //   ① 片头片尾的安静段要切  ② 0.1~0.25s 的短换气要切  ③ 整体轻声区也切
    // 总原则「宁多勿少」，误切靠 ⟳ 反选补回来，漏切要人一句一句找。
    // 改完 Swift 必须同步改 preview_cut.py，再拿 samples/ 里的四条样片跑一遍。
    //
    enum Detect {

        /// 最短气口。低于 0.1s 的低幅基本是音节内的瞬态，碰了会把字切碎
        static let minGap: Double = 0.10

        /// 单个保留片段的最短时长。
        /// 旧值 0.6 是 IMG_4582 / IMG_4583 一刀切不出来的元凶，降到 0.3
        static let minSegment: Double = 0.30

        /// 最短一刀。0.04s = 40ms，双 15ms 交叉淡入淡出还盖得住
        static let minCut: Double = 0.04

        /// 气口两侧留白。**只收贴语音的那一侧** —— 片头段不往里收、片尾段不往里收，
        /// 安静段就该从第 0 帧切起、切到最后一帧。
        /// 中间气口（两头都是语音）才双侧各收 PAD
        static let pad: Double = 0.03

        /// dB 阈值的安全夹逼区间。Otsu 算出的原始值落在这外面就拉回来。
        /// 上界 -25 是硬边界：再往上会把探店现场的环境声当静音切掉
        static let clampLow: Double = -50.0
        static let clampHigh: Double = -25.0

        /// 适用性判据：相邻半秒段最大值的起伏低于这个值，
        /// 说明整条素材响度是平的 —— 带 BGM 或做过响度归一化的成品视频
        /// 从原理上无法用静音检测去气口，判死刑并给用户明确提示
        static let minContrastDb: Double = 6.0

        /// 局部对比度余量：气口必须比它两边 200ms 的语音低这么多才下刀。
        /// **归零待命（与 preview_cut.py 的 CONTRAST_DB 一致）** ——
        /// 皓哥拍板「整体轻声区也切」之后，这关卡就没有判别力了：
        /// 真气口深度普遍 20dB+，而尾部轻声区只有 3~10dB 也照样要切。
        /// 留着这个参数只是方便哪天想收紧时改一个数，现在它是 0
        static let localContrastDb: Double = 0.0

        /// 局部对比度取样窗口（秒）（与 preview_cut.py 的 PAD_SAMPLE 一致）
        static let padSampleSec: Double = 0.20

        /// 低于这个电平的帧占比，用来辅助判断素材是不是「太安静」
        static let silenceFloorDb: Double = -45.0
    }

    // MARK: - 包络提取

    enum Envelope {
        /// 分析窗长（毫秒）。20ms 是语音短时分析的标准窗
        static let frameMs: Int = 20
        /// 跳距（毫秒）。10ms = 50% 重叠，太疏会漏掉短气口
        static let hopMs: Int = 10
        /// 分析采样率（Hz）。不用原始 48k，省算力，对气口检测足够
        /// （与 preview_cut.py 的 SR 一致）
        static let sampleRate: Int = 16000
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

    // MARK: - 导出可选项（定稿第 4.9 节：分辨率 / 帧率要有得选，默认同源）
    //
    // 选项刻意做少：分辨率砍掉 720P / 480P，帧率砍掉 24。
    // 探店素材就 1080P 竖版这一种，多一个选项就多一份要维护的参数组合。
    // 容器与编码（MP4 / H.264 / yuv420p / AAC-LC 192k / faststart）**不开选项** ——
    // 那几个是剪映实测过的组合，动一根指头都可能导不进去。

    /// 输出分辨率。作用于**显示尺寸**（已应用 preferredTransform 之后那个），
    /// 不是 naturalSize —— 见定稿 4.9.2
    enum Resolution: String, CaseIterable {
        case same    = "同源文件"
        case p1080   = "1080P"

        /// 目标长边。nil = 不缩放，用源素材的显示尺寸
        var targetShortSide: Int? {
            switch self {
            case .same:  return nil
            case .p1080: return 1080
            }
        }
    }

    /// 输出帧率。nil = 跟随源素材
    enum FrameRate: String, CaseIterable {
        case same = "同源文件"
        case fps60 = "60"
        case fps30 = "30"

        var value: Double? {
            switch self {
            case .same:  return nil
            case .fps60: return 60
            case .fps30: return 30
            }
        }
    }

    /// 一次导出的完整规格
    struct ExportSpec {
        var resolution: Resolution = .same
        var frameRate: FrameRate = .same

        var summary: String {
            "\(resolution.rawValue) · \(frameRate.rawValue)"
        }
    }

    // MARK: - 接缝处理

    enum Seam {
        /// 零点对齐容差。把切口收缩到 ±10ms 内的零点上，切在这里不会爆音
        static let zeroCrossToleranceSec: Double = 0.010
        /// 交叉淡化时长。即使做了零点对齐也留这道防线 ——
        /// 波形上的零点不等于听感上的无感，15ms 足以抹掉残余的 Click
        static let crossFadeSec: Double = 0.015
    }

    /// v1.3.0 区域编辑态（长按进入的「黄边 + 两端黄把手」）
    ///
    /// 数值全部来自定稿 `docs/轨道删除与拖拽定稿.md` 4.3 / 4.3.1 与 `docs/拖拽把手样式.svg`，
    /// 实现时**只从这里读**，别在 UI 里散落魔法数字 —— 改规格只改这一处。
    ///
    /// ⚠️ 尺寸一律用 Double 不用 CGFloat：这个文件只 import Foundation，
    /// CGFloat 靠 Foundation 间接带进来的 CoreGraphics，依赖它不稳。
    /// UI 层用的时候 `CGFloat(RegionEdit.handleWidth)` 转一下就行。
    enum RegionEdit {
        /// 长按多久进编辑态。0.5s 是「不像误触、又不难等」的经验值
        static let longPressSec: Double = 0.5

        /// 把手竖条的宽度（pt）
        static let handleWidth: Double = 16
        /// 把手上下各探出轨道多少（pt）
        static let handleOverhang: Double = 10
        /// 把手中心白抓点的直径（pt）
        static let gripDot: Double = 5
        /// 把手触控区边长（pt）。Apple 建议 ≥44，这里取 44
        static let handleTouchTarget: Double = 44

        /// 选中区黄边线宽（pt）
        static let selectionBorderWidth: Double = 3
        /// 编辑态淡入淡出时长（秒）
        static let fadeSec: Double = 0.18

        /// 一段最短多少秒。拖把手夹到这里就停，防碎成无数小段
        static let minSegmentSec: Double = 0.1

        /// 手指离把手多近才算摸到了。把手本身只有 16pt 宽，
        /// 但手指不是鼠标 —— 按 16pt 判定基本抓不住
        static let handleGrabTolerance: Double = 28
    }

    // MARK: - 自动保存

    enum Draft {
        /// debounce 秒数。改了阈值之类的操作是连续的，
        /// 每次都落盘会拖慢滑动的手感，攒 2 秒再写刚好
        static let debounceSec: Double = 2.0
        /// 单个工程保留多少个历史版本。多了占空间，少了不够用
        static let keepHistory = 5

        /// 起始页最多留几批草稿。超了丢最久没动过的那批（定稿 3.1）
        static let maxBatches = 10

        /// 回收站保留天数。跟相册一个套路，不无限堆着（定稿 3.2）
        static let trashKeepDays = 30

        /// 撤销 / 重做容量（定稿 7.1，皓哥拍板改掉了原来的 60）
        static let undoLimit = 15
        static let redoLimit = 1
    }

    // MARK: - 编辑页几何（定稿 4.3 / 4.5.3 修订：预览与主轨道改为固定高度）
    //
    // 预览区、主轨道都锁成固定值：横屏 / 竖屏素材都进同一个固定框里 letterbox 显示
    //（AVPlayerLayer 用 .resizeAspect），不再随素材比例拉伸、挤压下方区域、或压没时间码。

    enum Layout {
        /// 预览区固定高度。取自皓哥截图上的实际大小（原 previewMaxH=350），
        /// 横竖屏都进这个框，多余部分黑边留白。
        static let previewFixedH: CGFloat = 350
        /// 主轨道固定高度。与预览区一起锁死，配合 8pt 紧凑间距，
        /// 在 16(844pt 高) / 16 Pro(874pt 高) 上都能放下，数字行（时间码）不再被压没。
        static let trackFixedH: CGFloat = 140

        /// 轨道拖到头之后再拽多少 pt 才换素材（定稿 4.5.3）
        static let siblingPullThreshold: CGFloat = 60

        /// 画面左右滑换素材的门槛：横向够长、且几乎不上下飘才算（第 5 节）
        static let swipeMinX: CGFloat = 40
        static let swipeMaxY: CGFloat = 12
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
