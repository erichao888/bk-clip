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
//  打开 App 看到的是一整套暗色波形。剪辑软件要的是「颜色稳定可预期」：
//  白天剪和夜里剪，同一段素材看起来必须一样，
//  否则你对「这一段到底静不静」的判断会被环境光带偏。剪映同理。
//
//  所以从今往后：
//    · 全 App 只准用下面这些固定色值
//    · 不准用 .label / .systemBackground 之类跟随系统的语义色
//    · 不准再写 UIColor.bk(light:dark:)（这个 helper 已经删掉，防止有人捡回去）
//    · project.yml 里 UIUserInterfaceStyle 锁成 Dark（2.0 定稿就是深色，见 Color 注释）
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

        // ★★ 2.0 深色基调（皓哥 2026-10-06 指正：效果图全是深色，之前照 v1.x 浅色做反了）★★
        // 唯一真值来源 = proto/ui-spec-v1.5.7/index.html 的 :root（效果图本体）。
        // ⚠️ 规格补充A §1.1 给的底色值（#0E1114/#171B21）与原型（#0A0C10/#12151B）不一致，
        //    这里按**原型**走 —— 皓哥记忆里的「效果图」就是原型截图。
        //    改色先改原型和规格补充A，再回来改这里，三处必须同一轮同步。

        // ---- 容器（--bg / --bg-1 / --bg-2 / --bg-3 / --line）----
        /// 页面底 / 内容区背景（--bg 最底）
        static let page  = UIColor(hex: 0x0A0C10)
        static let bg    = UIColor(hex: 0x0A0C10)
        /// 工具栏 / 底栏（--bg-2 浮起层，比页面底亮一档才浮得起来）
        static let bar   = UIColor(hex: 0x1A1F27)
        /// 面板、卡片、导航栏背景（--bg-1 表面）
        static let panel = UIColor(hex: 0x12151B)
        /// 次级面板（按钮按下态、胶囊标签底、hover = --bg-3）
        static let panel2 = UIColor(hex: 0x232A34)
        /// 分隔线 / 按钮描边（--line）
        static let line  = UIColor(hex: 0x2C333D)
        /// 更弱分隔线（--line-soft，面板内部用）
        static let lineSoft = UIColor(hex: 0x1F242C)

        // ---- 文字（--text / --text-2 / --text-3）----
        static let text  = UIColor(hex: 0xEAF0F7)
        static let text2 = UIColor(hex: 0x9AA4B2)
        static let text3 = UIColor(hex: 0x5F6B7A)

        // ---- 品牌 / 语义（--accent / --red / --green）----
        /// 操作主色：选中态、强调、进度、主行动按钮。2.0 起它是**蓝**不是黑
        static let accent = UIColor(hex: 0x2F6DF4)
        /// 强调黄：滑杆填充、变速选中档位底（补充A §1.1）
        static let slider = UIColor(hex: 0xEAC54F)

        // ---- 主轨 / 波剪轨（--bed + 气口语义）----
        /// 轨道底板（--bed）。⚠️ 2.0 起主轨是**中性深色**，不再是浅绿；
        /// 绿/红只许在**波剪页气口语义**出现，主轨画面条/波形条保持纯净（补充A §1.1）
        static let track = UIColor(hex: 0x141719)
        /// 波形本体 = 保留（绿区）语义色。波剪页里波形画的就是「留下来」的那部分
        static let wave  = UIColor(hex: 0x3ECC77)
        /// 待删气口：红罩（半透明压在波形上）
        static let cut     = UIColor(hex: 0xD8574E, alpha: 0.55)
        /// 气口边界线：红实心
        static let cutLine = UIColor(hex: 0xD8574E)
        /// 边界把手：小白条
        static let handle  = UIColor(hex: 0xFFFFFF)
        /// 把手描边。深底上白把手本身够亮，描边用底色把它从绿区里切出来
        static let handleLine = UIColor(hex: 0x0A0C10, alpha: 0.9)
        /// 指针：白（--playhead。2.0 起不再是橙）
        static let playhead = UIColor(hex: 0xFFFFFF)
        /// 阈值虚线：用强调黄，跟滑杆一个语义（「可调的值」）
        static let warning = UIColor(hex: 0xEAC54F)

        // ---- 概览条 ----
        static let ovBg   = UIColor(hex: 0x1A1F27)
        static let ovWave = UIColor(hex: 0x5F6B7A)

        // ---- 选中（规格 §1.3：.on = accent + rgba(47,109,244,.12) 底）----
        /// 选中蓝框。与 accent 同值但**语义不同**：它是「当前框选的区块」，
        /// 底栏/面板都跟着它走，别拿去做普通点缀
        static let select   = UIColor(hex: 0x2F6DF4)
        /// 选中态的淡蓝底
        static let selectBg = UIColor(hex: 0x2F6DF4, alpha: 0.12)
        /// 手动切口的缝线。深底上黑色看不见，用主文字色
        static let selection = UIColor(hex: 0xEAF0F7)

        // ---- 预览区 ----
        /// 播放器背景。给视频画面染色会污染你对画面的判断，一律近黑不解释
        static let preview = UIColor(hex: 0x141414)

        // ---- 语义色 ----
        static let success = UIColor(hex: 0x3ECC77)
        static let danger  = UIColor(hex: 0xD8574E)
    }

    // MARK: - 按钮样式
    //
    // 2.0 深色版：圆钮底 = panel（深）、线条/图标 = text（浅），
    // 主行动钮 = accent 蓝，危险钮 = danger 红。尺寸不变。
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
