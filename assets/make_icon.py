#
#  make_icon.py — bk剪辑 App 图标生成（C 方案 橙红正底）
#
#  【为什么不用 SVG 转 PNG】
#  cairosvg 在 Windows 上缺底层 cairo 动态库（装得上包、跑不起来），
#  与其折腾系统依赖，不如用 PIL 直接画 —— 反正这图标就是「渐变圆角方块 + 白色 BK 描边」，
#  手绘能精确控制，不会有转码走样。
#
#  【几何完全对齐 assets/icon-C-solid.svg】
#  · 画布 1024×1024，圆角半径 223（iOS 图标标准，squircle 近似用圆角矩形）
#  · 渐变沿左上→右下对角线，#FFC46B → #F0633C(0.5) → #BF3A86
#  · BK 字形：SVG 里是 translate(202,286) scale(4.66) 的 6 条折线路径，
#    这里直接在同一坐标系里算点，描边宽 17*4.66≈79，圆头圆角
#
#  【输出】
#  AppIcon 完整尺寸一套（1024/512/180/120/76/60），
#  另出一张 1024 的无圆角版（App Store 用）和一张预览拼图。
#

import os
import numpy as np
from PIL import Image, ImageDraw

S = 1024
RADIUS = 223

# 渐变三色
C0 = (0xFF, 0xC4, 0x6B)   # 顶部浅金
C1 = (0xF0, 0x63, 0x3C)   # 中部橙红
C2 = (0xBF, 0x3A, 0x86)   # 底部紫红

# SVG 的 linearGradient x2=0.6 y2=1（归一化坐标）
GX, GY = 0.6, 1.0


def make_gradient() -> Image.Image:
    """沿左上→右下对角线做三段渐变。"""
    ys, xs = np.mgrid[0:S, 0:S].astype(np.float32)
    # 投影到渐变轴上，归一化到 0..1
    t = (GX * xs + GY * ys) / (GX * S + GY * S)
    t = np.clip(t, 0.0, 1.0)

    out = np.zeros((S, S, 3), dtype=np.float32)
    # 第一段 0..0.5
    m1 = t <= 0.5
    u = (t / 0.5)[m1][:, None]
    for ch in range(3):
        out[..., ch][m1] = (C0[ch] + (C1[ch] - C0[ch]) * u)[:, 0]
    # 第二段 0.5..1
    m2 = ~m1
    u = ((t - 0.5) / 0.5)[m2][:, None]
    for ch in range(3):
        out[..., ch][m2] = (C1[ch] + (C2[ch] - C1[ch]) * u)[:, 0]

    return Image.fromarray(out.astype(np.uint8), mode="RGB")


def rounded_mask(size: int, radius: int) -> Image.Image:
    """圆角矩形遮罩：白=保留，黑=透明。size 用 4 倍超采样抗锯齿。"""
    ss = 4
    m = Image.new("L", (size * ss, size * ss), 0)
    d = ImageDraw.Draw(m)
    r = radius * ss
    # PIL 的 rounded_rectangle 半径要按超采样后的尺寸给
    d.rounded_rectangle([0, 0, size * ss - 1, size * ss - 1], radius=r, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def bk_paths():
    """把 SVG 里的 BK 折线换算到 1024 画布坐标。
    SVG: <g transform="translate(202,286) scale(4.66)" stroke-width="17">
    坐标原点在路径自身的 0..124 × 0..94 空间。"""
    ox, oy, sc = 202, 286, 4.66
    def P(x, y):
        return (ox + x * sc, oy + y * sc)

    return [
        # B 的竖干 + 上下两个半圆环（横线 + 右侧圆角）
        [P(8.5, 8.5), P(8.5, 88.5)],
        [P(8.5, 8.5), P(34, 8.5), P(34, 48.5), P(8.5, 48.5)],
        [P(8.5, 48.5), P(34, 48.5), P(34, 88.5), P(8.5, 88.5)],
        # K 的竖干
        [P(82, 8.5), P(82, 88.5)],
        # K 的两条斜臂
        [P(120, 8.5), P(82, 48.5)],
        [P(97, 34), P(124, 88.5)],
    ]


def draw_bk(img: Image.Image) -> Image.Image:
    """在底图上画白色 BK 描边。超采样 4 倍画，再缩小，边缘才干净。"""
    ss = 4
    layer = Image.new("RGBA", (S * ss, S * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    w = 17 * 4.66 * ss          # 描边宽（SVG 里 17 × scale 4.66）
    col = (255, 255, 255, 255)  # SVG 里是白→浅米渐变，纯白在橙红底上更清楚

    for path in bk_paths():
        pts = [(x * ss, y * ss) for (x, y) in path]
        d.line(pts, fill=col, width=int(round(w)), joint="curve")
        # 圆头：两端各补一个圆点（stroke-linecap="round"）
        r = w / 2
        for (x, y) in (pts[0], pts[-1]):
            d.ellipse([x - r, y - r, x + r, y + r], fill=col)

    layer = layer.resize((S, S), Image.LANCZOS)
    out = img.copy().convert("RGBA")
    out.alpha_composite(layer)
    return out.convert("RGB")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    outdir = os.path.join(here, "icon-C-png")
    os.makedirs(outdir, exist_ok=True)

    base = make_gradient()
    # 无圆角母版（App Store 用）+ 圆角版（设备用）
    plain = draw_bk(base)
    plain.save(os.path.join(outdir, "icon-1024-plain.png"))

    rounded = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    rounded.paste(plain, (0, 0), rounded_mask(S, RADIUS))
    # ⚠️ **iOS 主屏图标不允许透明通道**。圆角外补白压平，
    # 不然 Xcode 的 asset 编译会直接失败（不是警告，是 error）。
    rounded_flat = Image.new("RGB", (S, S), (255, 255, 255))
    rounded_flat.paste(rounded, (0, 0), rounded)
    rounded = rounded_flat
    rounded.save(os.path.join(outdir, "icon-1024.png"))

    # 全套尺寸。1024 母版带圆角，缩到小尺寸时圆角自然变钝，
    # 这正是 iOS 期望的效果（不要自己再给小尺寸单独画圆角）
    for s in [512, 180, 120, 76, 60]:
        im = rounded.resize((s, s), Image.LANCZOS)
        # ⚠️ **iOS 主屏图标不允许带透明通道**，带 alpha 会让 asset 编译失败。
        # 圆角外的透明区域必须压成不透明（这里拼白底，iOS 自己会再套一层圆角遮罩）。
        if im.mode == "RGBA":
            bg = Image.new("RGB", im.size, (255, 255, 255))
            bg.paste(im, (0, 0), im)
            im = bg
        im.save(os.path.join(outdir, "icon-%d.png" % s))

    # 预览拼图：浅色/深色底各放一个，模拟主屏观感
    prev = Image.new("RGB", (S, S * 2 + 60), (0xF7, 0xF7, 0xF4))
    prev.paste(rounded, (0, 0))
    dark = Image.new("RGB", (S, S), (0x11, 0x11, 0x12))
    dark.paste(rounded, (0, 0))
    prev.paste(dark, (0, S + 60))
    prev.save(os.path.join(outdir, "preview-light-dark.png"))

    for f in sorted(os.listdir(outdir)):
        p = os.path.join(outdir, f)
        print("  %-28s %7d bytes" % (f, os.path.getsize(p)))
    print("完成 →", outdir)


if __name__ == "__main__":
    main()
