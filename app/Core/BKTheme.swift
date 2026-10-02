//
//  BKTheme.swift
//  bk剪辑 — 视觉令牌（颜色 / 字体 / 间距）
//
//  【为什么用一套令牌而不是到处写色值】
//  颜色写在各个 View 里，改一次主题要翻十个文件；而且同一个「次要文字」
//  在不同页面上会慢慢变成三种灰。这里是唯一的定义处，别处只引用。
//
//  【这里的色值和 proto/index.html 的 CSS 变量逐一对齐】
//  网页原型是你在电脑上看到的样子，App 是真机上跑出来的样子。
//  两边色值不一致，原型就白做了 —— 改原型改这里，改这里也改原型。
//
//  【深色优先】
//  剪辑软件一律深色为主：波形在浅底上对比度不够，长时间盯也累眼。
//  但 iOS 用户可能开浅色模式，所以两套都给全了，用 dynamic 跟随系统。
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

    /// 跟随系统深浅自动生成。
    /// iOS 13 起 UIColor 支持动态 provider，切深/浅模式时会自动刷新，
    /// 不需要在 traitCollectionDidChange 里手动重设 —— 前提是你别把颜色
    /// 在 viewDidLoad 里提前 resolve 成 cgColor 存起来
    static func bk(light: UInt32, dark: UInt32, alpha: CGFloat = 1.0) -> UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: alpha)
                : UIColor(hex: light, alpha: alpha)
        }
    }
}

// MARK: - 颜色令牌

enum BKTheme {

    enum Color {

        // 容器
        /// 页面底色（ iPhone 屏幕上手指基地之外的区域）
        static let page   = UIColor.bk(light: 0xDCDCE1, dark: 0x2C2C2E)
        /// 内容区背景
        static let bg     = UIColor.bk(light: 0xF2F2F7, dark: 0x000000)
        /// 面板、卡片、导航栏背景
        static let panel  = UIColor.bk(light: 0xFFFFFF, dark: 0x1C1C1E)
        /// 次级面板（按钮按下态、胶囊标签底）
        static let panel2 = UIColor.bk(light: 0xE5E5EA, dark: 0x2C2C2E)
        /// 分隔线
        static let line   = UIColor.bk(light: 0xD1D1D6, dark: 0x38383A)

        // 文字
        static let text   = UIColor.bk(light: 0x1A1A1A, dark: 0xF5F5F5)
        static let text2  = UIColor.bk(light: 0x6E6E73, dark: 0x98989D)
        static let text3  = UIColor.bk(light: 0xAEAEB2, dark: 0x636366)

        // 波形
        /// 波形轨道底色
        static let track  = UIColor.bk(light: 0xC7D8BD, dark: 0x1E2A20)
        /// 波形本体
        static let wave   = UIColor.bk(light: 0x24430F, dark: 0x8FC98A)
        /// 待切除区的高亮覆盖
        static let cut    = UIColor.bk(light: 0xD6707A, dark: 0xC25B5B).withAlphaComponent(0.55)
        /// 待切除区的边框 / 分割线
        static let cutLine = UIColor.bk(light: 0xD6707A, dark: 0xC25B5B)

        // 概览条
        static let ovBg   = UIColor.bk(light: 0x8F9389, dark: 0x3A3A3C)
        static let ovWave = UIColor.bk(light: 0x4C5049, dark: 0x8E8E93)

        // 强调
        /// 主强调色，用于可点文字和链接
        static let accent = UIColor.bk(light: 0x007AFF, dark: 0x0A84FF)
        /// 品牌金。播放头、进度条、调试入口专用 —— 它是「正在动」的颜色，
        /// 别拿去当普通点缀，会跟播放头抢注意力
        static let gold   = UIColor(hex: 0xF09A28)
        /// 播放头
        static let playhead = UIColor(hex: 0xF09A28)
        /// 选中描边
        static let selection = UIColor.bk(light: 0x1A1A1A, dark: 0xFFFFFF)

        // 预览区
        /// 播放器背景。深浅两套都给纯黑/近黑 —— 视频本身是内容背景，
        /// 给它染色会污染你对画面的判断
        static let preview = UIColor.bk(light: 0x141414, dark: 0x000000)

        // 语义色
        static let success = UIColor(hex: 0x8FC98A)
        static let warning = UIColor(hex: 0xEF9F27)
        static let danger  = UIColor(hex: 0xE24B4A)
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
