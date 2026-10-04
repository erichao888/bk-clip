//
//  BKIcons.swift
//  bk剪辑 — 自定义图标
//
//  【为什么还有自定义图标，不全用 SF Symbols】
//  工具栏里绝大多数按钮都能在 SF Symbols 里找到现成的（剪刀、吸管、播放……），
//  但有些语义没有对应的系统图标 —— 比如「删红 ✗✗」和「阈值恢复自动 ↺」。
//
//  【为什么大部分画成模板图（alwaysTemplate）】
//  模板图只取 alpha 通道，颜色由按钮的 tintColor 决定。
//  这样按下 / 禁用时图标会跟着系统一起变色，不用为每种状态再画一张。
//  ⚠️ 例外是 `deleteRedDoubleX`：红是它的**语义色**，做成模板图会被 tintColor 覆盖，
//  那里刻意不用模板图（详见该函数注释）。
//
//  【⚠️ 透明通道必须显式开】
//  模板图看的是 alpha。如果绘制上下文是不透明的（opaque），整张图 alpha 全是 1，
//  结果按钮上会出现一个实心方块而不是线条图标 —— 而且这个 bug 只在真机上才看得见。
//  所以下面用 UIGraphicsBeginImageContextWithOptions(..., false, ...)，
//  第二个参数 false 就是「不要不透明背景」。
//
//  【v1.3.0 删掉了 loopArrow】
//  原来的「反选 ⟳」被删红键替换（皓哥 2026-10-04 定）。它的能力并进了
//  「点段 toggle 绿↔红」—— 手指直接点那一段就行，不需要专门的键。
//  图标一并删除：零调用的死代码留着，会让人以为反选键还在。
//

import UIKit

enum BKIcons {

    /// `|▶|` 联播键（定稿 4.4，皓哥从 5 个方案里挑的 **E**）
    ///
    /// 三角夹在两条竖线中间：竖线 = 被跳过的气口，左右各一道 = 段与段之间一路跳过去。
    ///
    /// ```
    /// <line x1="5.5" y1="6" x2="5.5" y2="18"/>
    /// <path d="M9 6l7 6-7 6z" fill="currentColor"/>
    /// <line x1="18.5" y1="6" x2="18.5" y2="18"/>
    /// ```
    /// （viewBox 0 0 24 24，两条竖线 stroke 1.9 圆头，三角**实心**）
    ///
    /// ⚠️ 两条竖线用 stroke、三角用 fill，两套绘制方式别混：
    /// 把三角也 stroke 了的话它只是个空框，一眼看过去跟别的图标完全不是一家人
    static func skip(side: CGFloat = 24, weight: CGFloat = 1.9) -> UIImage {
        // false = 透明背景。改成 true 这个图标就变成实心方块了
        UIGraphicsBeginImageContextWithOptions(CGSize(width: side, height: side), false, 0)

        if let ctx = UIGraphicsGetCurrentContext() {
            let scale = side / 24.0
            ctx.scaleBy(x: scale, y: scale)
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.setLineWidth(weight / scale)   // 先缩放了，线宽要还原回去
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // 左右两道竖线：被跳过的气口
            ctx.move(to: CGPoint(x: 5.5, y: 6))
            ctx.addLine(to: CGPoint(x: 5.5, y: 18))
            ctx.strokePath()

            ctx.move(to: CGPoint(x: 18.5, y: 6))
            ctx.addLine(to: CGPoint(x: 18.5, y: 18))
            ctx.strokePath()

            // 中间的实心三角
            let tri = CGMutablePath()
            tri.move(to: CGPoint(x: 9, y: 6))
            tri.addLine(to: CGPoint(x: 16, y: 12))
            tri.addLine(to: CGPoint(x: 9, y: 18))
            tri.closeSubpath()
            ctx.addPath(tri)
            ctx.fillPath()
        }

        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image.withRenderingMode(.alwaysTemplate)
    }

    /// ↺ 阈值的「恢复自动」（定稿 4.7.1）
    ///
    /// 一段圆弧 + 一个箭头尖，像系统那个「撤销」但只有一条弧 ——
    /// 语义是「回到自动算出来的那个值」，不是撤销一步操作。
    static func backToAuto(side: CGFloat = 20, weight: CGFloat = 1.8) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: side, height: side), false, 0)

        if let ctx = UIGraphicsGetCurrentContext() {
            let scale = side / 24.0
            ctx.scaleBy(x: scale, y: scale)
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setLineWidth(weight / scale)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // 一段优弧：从 60° 逆时针绕过顶部到 300°（UIKit y 轴朝下，角度递增为顺时针）
            ctx.addArc(center: CGPoint(x: 12, y: 12), radius: 7,
                       startAngle: .pi / 3, endAngle: -.pi / 3, clockwise: true)
            ctx.strokePath()

            // 箭头尖：在弧的起点 (15.5, 5.94)，尖朝左上
            ctx.move(to: CGPoint(x: 18.5, y: 8.5))
            ctx.addLine(to: CGPoint(x: 15.5, y: 5.5))
            ctx.addLine(to: CGPoint(x: 15.5, y: 9.5))
            ctx.strokePath()
        }

        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image.withRenderingMode(.alwaysTemplate)
    }

    /// ✗✗ 删红键（v1.3.0 定稿 4.1，皓哥 2026-10-04 终选**方案 B · 错位重叠双 X**）
    ///
    /// 两个 X 对角错位、中间交叠，像「✕✕」——比方案 A（同心旋转 30° 的八芒星）更轻盈。
    /// 参照 `docs/删红键图标.svg`。
    ///
    /// ⚠️ **这个图标不能用 alwaysTemplate**，是本文件里唯一的例外。
    /// 其余图标都是线条 + 模板图（颜色交给 tintColor，按下/禁用自动变色）；
    /// 但删红的红是**语义色**（= 红区删除动作色，纯红 #FF3B30），
    /// 做成模板图会被按钮的 tintColor 覆盖掉 —— 按下变灰、禁用变淡，
    /// 就分不出「这是删红键」还是「这是别的键」了。所以这里固定画死纯红，
    /// 代价是按下/禁用时颜色不变（对删除类按钮反而更合适：不该鼓励连点）。
    ///
    /// 坐标系统是 24×24，和其余图标一致，绘制前整体缩放到 side。
    /// 同样必须 `false` = 透明背景，否则 alpha 全 1 会变成实心方块。
    static func deleteRedDoubleX(side: CGFloat = 24, weight: CGFloat = 2.1) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: side, height: side), false, 0)

        if let ctx = UIGraphicsGetCurrentContext() {
            let scale = side / 24.0
            ctx.scaleBy(x: scale, y: scale)
            // 固定纯红，不用模板图（见上面的注释）
            // ⚠️ 写成 0x3B / 255.0 会被当成整数除法（结果 0），
            // 必须让分子是浮点。UIColor(red:green:blue:alpha:) 收 CGFloat，
            // 这里显式给 Double 免得踩整除。
            let red = UIColor(red: 1.0, green: 59.0 / 255.0, blue: 48.0 / 255.0, alpha: 1.0)
            ctx.setStrokeColor(red.cgColor)
            ctx.setLineWidth(weight / scale)
            ctx.setLineCap(.round)

            // X1：中心 (10, 10)
            ctx.move(to: CGPoint(x: 6.5, y: 6.5))
            ctx.addLine(to: CGPoint(x: 13.5, y: 13.5))
            ctx.move(to: CGPoint(x: 13.5, y: 6.5))
            ctx.addLine(to: CGPoint(x: 6.5, y: 13.5))
            ctx.strokePath()

            // X2：中心 (15, 15)，对角错位 5pt —— 这就是「错位重叠」
            ctx.move(to: CGPoint(x: 11.5, y: 11.5))
            ctx.addLine(to: CGPoint(x: 18.5, y: 18.5))
            ctx.move(to: CGPoint(x: 18.5, y: 11.5))
            ctx.addLine(to: CGPoint(x: 11.5, y: 18.5))
            ctx.strokePath()
        }

        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        // ⚠️ 不加 withRenderingMode(.alwaysTemplate) —— 见上面的注释
        return image
    }
}
