# -*- coding: utf-8 -*-
"""
验证：3 个红区为什么只产生 2 段绿区？

`deriveKeeps` 的逻辑：
    cursor = 0
    for (s,e) in cuts:
        if s - cursor > 0.05: 追加 (cursor, s)
        cursor = e
    if duration - cursor > 0.05: 追加 (cursor, duration)

**红区贴着素材开头时**（第一段红区从 0 开始）→ s - cursor = 0 → 不追加绿段。
这是**正确的**（开头就是红区，前面没有绿区可留）。

所以「3 红区 → 2 绿区」在数学上可能是对的：
    红红红 → 0 段
    绿红红绿 → 2 段   ✅
    绿红绿红绿 → 3 段
    绿红绿红绿红 → 2 段

**但皓哥截图上 3 个红区明显都在中间**，所以应该有 4 段绿区。
→ 说明 `cutRanges` 里的数据与界面上看到的不一致。

本脚本枚举所有排列，找出「界面显示 3 个中间红区但只产生 2 段绿区」的情况。
"""

MIN = 0.05


def merge(cuts, duration):
    clean = [(max(a, 0), min(b, duration)) for a, b in cuts]
    clean = [(a, b) for a, b in clean if b > a]
    clean.sort()
    out = []
    for iv in clean:
        if out and iv[0] <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], iv[1]))
        else:
            out.append(iv)
    return out


def derive_keeps(cuts, duration):
    clean = merge(cuts, duration)
    out = []
    cursor = 0.0
    for s, e in clean:
        if s - cursor > MIN:
            out.append((cursor, s))
        cursor = e
    if duration - cursor > MIN:
        out.append((cursor, duration))
    return out


if __name__ == "__main__":
    D = 7.86
    print("=" * 66)
    print("素材 %.2fs，3 个红区，枚举它们的位置" % D)
    print("=" * 66)
    cases = [
        ("三段都在中间",
         [(1.0, 1.2), (3.0, 3.2), (5.0, 5.2)]),
        ("第一段贴开头",
         [(0.0, 0.5), (3.0, 3.2), (5.0, 5.2)]),
        ("最后一段贴结尾",
         [(1.0, 1.2), (3.0, 3.2), (7.0, 7.86)]),
        ("首尾都贴边",
         [(0.0, 0.5), (3.0, 3.2), (7.0, 7.86)]),
        ("两段重叠（merge 后只剩 2 个）",
         [(1.0, 2.0), (1.5, 3.0), (5.0, 5.2)]),
        ("两段相邻（无绿区夹在中间）",
         [(1.0, 1.2), (1.2, 1.4), (5.0, 5.2)]),
    ]
    for label, cuts in cases:
        m = merge(cuts, D)
        keeps = derive_keeps(cuts, D)
        print()
        print("【%s】" % label)
        print("  cuts 原始 %d 个 → merge 后 %d 个: %s"
              % (len(cuts), len(m), ["%.2f→%.2f" % (a, b) for a, b in m]))
        print("  → 绿区 %d 段: %s" % (len(keeps), ["%.2f→%.2f" % (a, b) for a, b in keeps]))
        kept = sum(b - a for a, b in keeps)
        print("  保留 %.2fs / 删除 %.2fs" % (kept, D - kept))

    print()
    print("=" * 66)
    print("关键结论")
    print("=" * 66)
    print("「3 红区 → 2 绿区」在两种情况下是**数学正确**的：")
    print("  ① 有红区贴着素材开头或结尾（那里本来就没有绿区）")
    print("  ② 有两个红区相邻（中间没有绿区）")
    print()
    print("⚠️ 但真正的可疑点：**merge 之后红区数量可能变少**。")
    print("   检测出的 3 刀如果有两个挨得近，merge 会并成 2 个 →")
    print("   界面上画的也是 2 段（应该与数据一致），但**日志说「采纳 3 刀」**。")
    print()
    print("→ 需要打印 merge 前后的数量对比，才能确定是「数据本来就对」")
    print("   还是「界面画了 3 段但数据只有 2 段」。")
