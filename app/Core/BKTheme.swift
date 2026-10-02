//
//  BKTheme.swift
//  bk剪辑 — 视觉令牌（颜色 / 字体 / 间距）
//
//  【为什么用一套令牌而不是到处写色值】
//  颜色写在各个 View 里，改一次主题要翻十个文件；而且同一个「次要文字」
//  在不同页面上会慢慢变成三种灰。这里是唯一的定义处，别处只引用。
//
//  【这里的色值和 docs/界面定稿.md 的配色表逐一对齐】
//  定稿是唯一的设计来源，改配色先改定稿，再改这里。
//
//  【⚠️ 配色一律焊死，不跟系统深浅模式 —— 这是踩过坑的地方】
//  这一版之前用的是 UIColor.bk(light:dark:) 动态色，结果皓哥手机开着深色模式，
//  打开 App 看到的是一整套暗色波形 —— 而参考图定的是浅色系。
//  剪辑软件要的是「颜色稳定可预期」：白天剪和夜里剪，同一段素材看起来必须一样，
//  否则你对「这一段到底静不静」的判断会被环境光带偏。剪映同理。
//
//  所以从今往后：
//    · 全 App 只准用下面这些固定色值
//    · 不准用 .label / .systemBackground 之类跟随系统的语义色
//    · 不准再写 UIColor.bk(light:dark:)（这个 helper 已经删掉，防止有人捡回去）
//    · project.yml 里 UIUserInterfaceStyle 也锁成 Light，
//      否则系统弹的告警框、导航栏还是深色的，跟浅色界面拼在一起很割裂
//

import UIKit

// MARK: - 十六进制色
//
// 这个文件是全工程唯一定义 UIColor(hex:) 的地方。
// 原先它写在 DebugConsole.swift 里，为了收敛到这里而迁出 ——
// 同模块内重复 init 会直接报 invalid redeclaration。

extension UIColor {

    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: alpha)
    }
}

// MARK: - 颜色令牌

enum BKTheme {

    enum Color {

        // ---- 容器 ----
        /// 页面底 / 内容区背景（定稿：#F7F7F4 浅白）
        static let page  = UIColor(hex: 0xF7F7F4)
        static let bg    = UIColor(hex: 0xF7F7F4)
        /// 工具栏底（定稿：#F1F1EE，比页面底略深一点，好把工具栏从页面上分出来）
        static let bar   = UIColor(hex: 0xF1F1EE)
        /// 面板、卡片、导航栏背景
        static let panel = UIColor(hex: 0xFFFFFF)
        /// 次级面板（按钮按下态、胶囊标签底）
        static let panel2 = UIColor(hex: 0xE5E5EA)
        /// 分隔线 / 按钮描边（定稿：#D1D1D6）
        static let line  = UIColor(hex: 0xD1D1D6)

        // ---- 文字 ----
        static let text  = UIColor(hex: 0x1A1A1A)
        static let text2 = UIColor(hex: 0x5F5E5A)
        static let text3 = UIColor(hex: 0xAEAEB2)

        // ---- 主轨道（定稿第 4.3 节）----
        /// 轨道底色：浅绿 #C7D8BD
        static let track = UIColor(hex: 0xC7D8BD)
        /// 波形本体：深绿实心 #24430F
        static let wave  = UIColor(hex: 0x24430F)
        /// 待删气口：粉红 60% #D6707A
        static let cut     = UIColor(hex: 0xD6707A, alpha: 0.60)
        /// 气口边界线：粉红实心 #D6707A
        static let cutLine = UIColor(hex: 0xD6707A)
        /// 边界把手：小白条 #FFFFFF
        static let handle  = UIColor(hex: 0xFFFFFF)
        /// 把手的描边。纯白压在浅绿上边界会糊，加一道极淡的灰边把它提出来
        static let handleLine = UIColor(hex: 0x8F9389, alpha: 0.9)
        /// 指针：橙 #F09A28
        static let playhead = UIColor(hex: 0xF09A28)
        /// 阈值虚线：黄 #EF9F27
        static let warning = UIColor(hex: 0xEF9F27)

        // ---- 概览条（定稿第 4.4 节）----
        static let ovBg   = UIColor(hex: 0x8F9389)
        static let ovWave = UIColor(hex: 0x4C5049)

        // ---- 强调 ----
        /// 主动作色。定稿要求按钮一律黑线条，所以它就是正文黑
        static let accent = UIColor(hex: 0x1A1A1A)
        /// 品牌橙。指针、视窗框、当前项高亮专用 —— 它是「正在动」的颜色，
        /// 别拿去当普通点缀，会跟指针抢注意力
        static let gold   = UIColor(hex: 0xF09A28)
        /// 手动切口的缝线
        static let selection = UIColor(hex: 0x1A1A1A)

        // ---- 预览区 ----
        /// 播放器背景。给视频画面染色会污染你对画面的判断，一律近黑不解释
        static let preview = UIColor(hex: 0x141414)

        // ---- 语义色 ----
        static let success = UIColor(hex: 0x24430F)
        static let danger  = UIColor(hex: 0xD6707A)
    }

    // MARK: - 按钮样式
    //
    // 定稿第 1.2 节：一律白圆底 + 黑线条 + SF Symbols，唯一例外是导出按钮。
    // 把尺寸和描边收在这里，是为了避免「五个按钮五种粗细」——
    // 这行代码散在各自的 setup 里写，慢慢一定会歪。

    enum Button {
        /// 直径。44 是苹果规定的最小可点区域，再小手指就开始点不准
        static let size: CGFloat = 44
        /// 圆角半径：直径的一半就是正圆
        static let radius: CGFloat = 22
        /// 描边
        static let border: CGFloat = 1.0
        /// 图标字号。SF Symbols 是字，靠字号控线条粗细
        static let iconPoint: CGFloat = 20
    }

    // MARK: - 字体
    //
    // 全部走系统字体：苹果自己的字重和中文排版是调好的，
    // 自嵌字体只会换来安装包体积和不确定的行高。

    enum Font {
        static let title   = UIFont.systemFont(ofSize: 17, weight: .semibold)
        static let body    = UIFont.systemFont(ofSize: 15, weight: .regular)
        static let caption = UIFont.systemFont(ofSize: 13, weight: .regular)
        static let small   = UIFont.systemFont(ofSize: 11, weight: .regular)
        /// 时间码、参数这类跳动数字：等宽数字不会左右抖
        static let mono    = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        static let monoBig = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        static let monoSmall = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        static let button  = UIFont.systemFont(ofSize: 16, weight: .medium)
    }

    // MARK: - 间距
    //
    // 只用偶数。12 是半格的例外，用来做「比 8 松、比 16 紧」的中间态。

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        /// 苹果规定的最小可点区域。任何小于它的按钮都是给自己挖坑
        static let minTap: CGFloat = 44
    }

    enum Radius {
        static let chip: CGFloat = 99      // 胶囊标签
        static let card: CGFloat = 12
        static let sheet: CGFloat = 14
    }
}
