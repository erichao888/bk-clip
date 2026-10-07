//
//  BKThemeV2.swift
//  bk剪辑 — v1.5.7 / v2 深色视觉令牌
//
//  【为什么新建一套，而不是改 BKTheme.swift】
//  `BKTheme.swift` 是 v1 的**浅色**令牌，注释里明写「配色一律焊死，不跟系统深浅模式」，
//  值是 page/bg=#F7F7F4、accent=#1A1A1A、track=#C7D8BD（浅绿）。
//  而 v1.5.7 原型与 `docs/规格补充A §1.1` 定的是**深色底 + 单一品牌蓝**。
//  两者不兼容：直接在 BKTheme 上改，v1 的编辑页/波剪页/起始页会一起变色。
//
//  `docs/编辑页迁v2-改造清单.md` 定的是 v1/v2 **并行迁移**（2A→2B→2C，
//  v1 的 BKModels.swift / Drafts/ 要到 2C 收尾才能删），所以过渡期必须两套令牌并存。
//
//  【色值来源：机械提取，不手抄】
//  真源是原型 `proto/ui-spec-v1.5.7/index.html` 的 `:root` CSS 变量块
//  （sha256 = 125e64d929c8d37f…，2026-10-06 09:36 版）。
//
//  ⚠️ **已知冲突（勿照抄 规格补充A §1.1 的表）**
//     补充A §1.1 写 `--bg-1 = #0E1114`、`--bg-2 = #171B21`，
//     但原型三份副本（10-05 / 10-06 / 波剪图标页）实测**都是** `#12151B` / `#1A1F27`。
//     此处以原型为准（原型是被 137 项断言验证过的行为真源）。
//
//  【为什么仍然不跟系统深浅模式】
//  沿用 BKTheme 那条踩过坑的结论：剪辑软件要的是「颜色稳定可预期」——
//  白天剪和夜里剪，同一段素材看起来必须一样，否则对「这段到底静不静」的判断会被环境光带偏。
//  所以这里同样是固定色值，禁用 .label / .systemBackground 之类语义色。
//

import UIKit

enum BKThemeV2 {

    // MARK: 颜色
    //
    // 命名与原型 CSS 变量一一对应，方便反查：
    //   --bg      → Color.bg
    //   --bg-1    → Color.bg1
    //   --accent  → Color.accent

    enum Color {

        // ---- 背景层级（原型 :root）----
        /// `--bg` #0A0C10 —— 最底
        static let bg = UIColor(hex: 0x0A0C10)
        /// `--bg-1` #12151B —— 页面底色
        static let bg1 = UIColor(hex: 0x12151B)
        /// `--bg-2` #1A1F27 —— 表面 / 卡片
        static let bg2 = UIColor(hex: 0x1A1F27)
        /// `--bg-3` #232A34 —— 浮起：工具栏 / 面板
        static let bg3 = UIColor(hex: 0x232A34)
        /// `--bed` #141719 —— 主轨道底板（方案 C）
        static let bed = UIColor(hex: 0x141719)

        // ---- 描边 ----
        /// `--line` #2C333D —— 底栏顶边等
        static let line = UIColor(hex: 0x2C333D)
        /// `--line-soft` #1F242C —— 面板内部更弱分隔线
        static let lineSoft = UIColor(hex: 0x1F242C)

        // ---- 文字 ----
        /// `--text` #EAF0F7
        static let text = UIColor(hex: 0xEAF0F7)
        /// `--text-2` #9AA4B2 —— **底栏图标默认色**
        static let text2 = UIColor(hex: 0x9AA4B2)
        /// `--text-3` #5F6B7A —— 未选中档位
        static let text3 = UIColor(hex: 0x5F6B7A)

        // ---- 品牌 ----
        /// `--accent` #2F6DF4 —— 选中态 / 强调 / 进度 / **选中框**
        static let accent = UIColor(hex: 0x2F6DF4)
        /// `--accent-2` #5B8CFF —— 操作主色的亮一档
        static let accent2 = UIColor(hex: 0x5B8CFF)
        /// `--select` #2F6DF4 —— 与 accent 同色（统一品牌蓝）
        static let select = UIColor(hex: 0x2F6DF4)
        /// 选中态底：`rgba(47,109,244,.12)`
        static let accentWash = UIColor(hex: 0x2F6DF4, alpha: 0.12)

        // ---- 语义色（**仅限波剪页气口语义**）----
        /// `--red` #D8574E —— 红区 / 折叠线
        static let red = UIColor(hex: 0xD8574E)
        /// `--green` #3ECC77 —— 绿区 / 保留
        static let green = UIColor(hex: 0x3ECC77)
        /// `--playhead` #FFFFFF —— 播放指针（不随内容移动）
        static let playhead = UIColor(hex: 0xFFFFFF)

        // ---- 滑杆 / 强调黄 ----
        /// 强调黄 #EAC54F —— 滑杆填充 / 把手轨道 / 选中档位底
        static let gold = UIColor(hex: 0xEAC54F)
        /// 滑杆把手 #fff
        static let knob = UIColor(hex: 0xFFFFFF)
        /// 「应用到全部」胶囊：#fff 底 / #12161c 字
        static let pillBG = UIColor(hex: 0xFFFFFF)
        static let pillFG = UIColor(hex: 0x12161C)

        // ---- 删除键 ----
        /// 底栏「删除」键标红。规格 §1.3 只说「标红」，色值取语义红 `--red`
        static let deleteKey = UIColor(hex: 0xD8574E)

        /// 底栏顶边分隔线宽（规格 §1.2：`border-top: 1px`）
        static let hairline: CGFloat = 1.0
    }

    // MARK: 底栏几何（规格 §1.2 —— 唯一真源）
    //
    // ⚠️ 这几个数值不能"顺手调成好看"：
    //    10 键 × 42pt = 424pt，屏宽 430pt、可视宽约 410pt
    //    → 溢出约 14pt，**必须能横滑**。把 42 改小到不溢出，图标会挤到不可点。

    enum BottomBar {
        /// 底栏高 64pt
        static let height: CGFloat = 64
        /// 单键 42 × 48pt
        static let keyWidth: CGFloat = 42
        static let keyHeight: CGFloat = 48
        /// 键圆角 12pt
        static let keyRadius: CGFloat = 12
        /// 键间距 1pt（极窄，靠 42pt 宽度本身留白）
        static let keyGap: CGFloat = 1
        /// 图标点阵尺寸（规格 §1.3：单线条、无文字）
        static let iconPoint: CGFloat = 19
        /// 按下态缩放：`transform: scale(0.9)`
        static let pressedScale: CGFloat = 0.9
        /// 左右内边距：让首尾键不贴边，且横滑到端点时最后一个键完整可见
        static let sideInset: CGFloat = 8
    }

    // MARK: 间距（原型 --s1..--s6，8pt 基准）

    enum Space {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
    }

    // MARK: 圆角（原型 --r / --r-sm）

    enum Radius {
        /// `--r` 14px
        static let base: CGFloat = 14
        /// `--r-sm` 10px
        static let small: CGFloat = 10
    }

    // MARK: 字号（规格补充A §1.2）

    enum Font {
        static let title = UIFont.systemFont(ofSize: 17, weight: .semibold)
        static let body = UIFont.systemFont(ofSize: 15, weight: .regular)
        static let caption = UIFont.systemFont(ofSize: 13, weight: .regular)
        static let small = UIFont.systemFont(ofSize: 11, weight: .regular)
        static let button = UIFont.systemFont(ofSize: 16, weight: .medium)
        /// 等宽数字：时间码 / 数值框，避免跳动
        static let mono = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        static let monoSmall = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    }
}

// MARK: - 便捷取色
//
// 底栏用到的组合色集中在这里，避免在各个 View 里拼 alpha。
// 与原型的 CSS 规则一一对应，方便反查。

extension BKThemeV2.Color {

    /// 底栏键图标默认色（原型：`color: var(--text-2)`）
    static var barIcon: UIColor { text2 }

    /// 底栏「删除」键图标色（原型：`.bb.del` 标红）
    static var barIconDelete: UIColor { deleteKey }

    /// 底栏键选中态底（原型：`.bb.on` = `accent` + `rgba(47,109,244,.12)`）
    static var barKeySelectedBG: UIColor { accentWash }

    /// 底栏键选中态图标色
    static var barKeySelectedFG: UIColor { accent }
}
