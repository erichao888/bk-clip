//
//  BKIcons.swift
//  bk剪辑 — 自定义图标
//
//  【为什么还有自定义图标，不全用 SF Symbols】
//  工具栏里绝大多数按钮都能在 SF Symbols 里找到现成的（剪刀、吸管、播放……），
//  但「反选当前片段」这个语义没有对应的系统图标 —— 它是个「圆环双箭头首尾相接」，
//  表达的是「留 ↔ 删 来回倒」。皓哥从画的 5 个方案里选了 B，这里就是方案 B。
//
//  【为什么画成模板图（alwaysTemplate）】
//  模板图只取 alpha 通道，颜色由按钮的 tintColor 决定。
//  这样按下 / 禁用时图标会跟着系统一起变色，不用为每种状态再画一张。
//
//  【⚠️ 透明通道必须显式开】
//  模板图看的是 alpha。如果绘制上下文是不透明的（opaque），整张图 alpha 全是 1，
//  结果按钮上会出现一个实心方块而不是线条图标 —— 而且这个 bug 只在真机上才看得见。
//  所以下面用 UIGraphicsBeginImageContextWithOptions(..., false, ...)，
//  第二个参数 false 就是「不要不透明背景」。
//

import UIKit

enum BKIcons {

    /// ⟳ 反选当前片段（定稿第 4.2 节，方案 B）
    ///
    /// 图形是两段半圆 + 两个箭头，首尾相接成一个环：
    ///   上半弧 从 (5,12) 经顶部 到 (19,12)，运动方向朝下 → 箭头尖朝下
    ///   下半弧 从 (19,12) 经底部 到 (5,12)，运动方向朝上 → 箭头尖朝上
    ///
    /// 坐标系统是 24×24（和 SVG viewBox 一致），绘制前整体缩放到 side。
    /// 注意 UIKit 里 y 轴朝下，所以「顺时针」= 角度递增：
    ///   θ=0 → 右，θ=π/2 → 下，θ=π → 左，θ=3π/2 → 上
    /// 上半弧取 π → 2π（经过 3π/2 也就是顶部），下半弧取 0 → π（经过 π/2 底部）。
    static func loopArrow(side: CGFloat = 24, weight: CGFloat = 1.8) -> UIImage {
        let half = CGFloat(Double.pi)
        let full = CGFloat(Double.pi) * 2

        // false = 透明背景。改成 true 这个图标就变成实心方块了
        UIGraphicsBeginImageContextWithOptions(CGSize(width: side, height: side), false, 0)

        if let ctx = UIGraphicsGetCurrentContext() {
            let scale = side / 24.0
            ctx.scaleBy(x: scale, y: scale)
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setLineWidth(weight / scale)   // 先缩放了，线宽要还原回去
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // 上半弧：π → 2π，顺时针，经过顶部
            ctx.move(to: CGPoint(x: 5, y: 12))
            ctx.addArc(center: CGPoint(x: 12, y: 12), radius: 7,
                       startAngle: half, endAngle: full, clockwise: true)
            ctx.strokePath()

            // 下半弧：0 → π，顺时针，经过底部
            ctx.move(to: CGPoint(x: 19, y: 12))
            ctx.addArc(center: CGPoint(x: 12, y: 12), radius: 7,
                       startAngle: 0, endAngle: half, clockwise: true)
            ctx.strokePath()

            // 右上箭头：尖在 (19,12)，尖朝下
            ctx.move(to: CGPoint(x: 16, y: 9))
            ctx.addLine(to: CGPoint(x: 19, y: 12))
            ctx.addLine(to: CGPoint(x: 22, y: 9))
            ctx.strokePath()

            // 左下箭头：尖在 (5,12)，尖朝上
            ctx.move(to: CGPoint(x: 8, y: 15))
            ctx.addLine(to: CGPoint(x: 5, y: 12))
            ctx.addLine(to: CGPoint(x: 2, y: 15))
            ctx.strokePath()
        }

        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image.withRenderingMode(.alwaysTemplate)
    }
}
