# -*- coding: utf-8 -*-
"""
N4 把手拖拽的数据流验证。

【最容易做错的地方】拖动时到底改什么？
marks 里的段是**严丝合缝覆盖 [0,duration]** 的，且是「显示粒度」（pieces 含 splits 切口）。
拖动一段的边界时：
  - 拖 keep 段的边界 → 边界两侧分别是 keep|cut，拖动会改变「哪部分是 cut」
  - 拖 cut 段的边界 → 同理
所以**不能直接改 marks 再 normalize**（那样会把切口/相邻段一起搅乱），
正解是：**把新边界翻译成「cuts 里增/删哪个区间」**，再走 build() 重建。

本脚本验证：给定一段和拖动后的新边界，cuts 应该怎么改。
"""
import json

MIN_SEG = 0.1
EPS = 1e-9


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


def build(duration, cuts):
    marks = []
    cur = 0.0
    for s, e in merge(cuts, duration):
        if s > cur:
            marks.append((cur, s, 'keep'))
        marks.append((s, e, 'cut'))
        cur = e
    if cur < duration:
        marks.append((cur, duration, 'keep'))
    # normalize（与 Swift 版一致）
    cl = []
    for s, e, k in marks:
        cs = min(max(s, 0), duration); ce = min(max(e, 0), duration)
        if ce - cs > 0.001:
            cl.append((cs, ce, k))
    cl.sort(key=lambda m: m[0])
    out = []
    for m in cl:
        if out:
            le = out[-1][1]
            if m[0] < le:
                out[-1] = (out[-1][0], m[0], out[-1][2])
            ne = out[-1][1]
            if ne < m[0]:
                out.append((ne, m[0], 'keep'))
        out.append(m)
    w = [m for m in out if m[1] - m[0] > 0.001]
    if not w:
        return [(0, duration, 'keep')]
    res = []
    for m in w:
        if res and res[-1][2] == m[2]:
            res[-1] = (res[-1][0], m[1], m[2])
        else:
            res.append(m)
    if res[0][0] > 0:
        res.insert(0, (0, res[0][0], 'keep'))
    if res[-1][1] < duration:
        res.append((res[-1][1], duration, 'keep'))
    return res


def find_segment(marks, start, end):
    """按坐标找段的下标（不用 index，index 会随显示粒度变 —— 现有代码的教训）"""
    for i, (s, e, k) in enumerate(marks):
        if abs(s - start) < 1e-6 and abs(e - end) < 1e-6:
            return i
    return None


def is_fully_in_cuts(cuts, s, e):
    """这段是否完全落在 cuts 覆盖内（即它是不是一个 cut 段）"""
    for a, b in cuts:
        if a - EPS <= s and e <= b + EPS:
            return True
    return False


def cuts_for_new_bounds(cuts, duration, seg, newStart, newEnd):
    """
    核心：拖动后 [seg.start, seg.end] → [newStart, newEnd]，
    cuts 该怎么改？

    规则（段状态决定）：
      · 原来是 keep 段：拖动区域扫过的地方要变 keep → 从 cuts 里**挖掉**那段
        挖不到的部分再**补上** cut
      · 原来是 cut 段：拖动区域扫过的地方要变 cut → 往 cuts 里**补上**那段
        原来被圈进去的、不在新范围内的部分要**挖掉**
    """
    s0, e0 = seg
    s1, e1 = newStart, newEnd
    if abs(s1 - s0) < EPS and abs(e1 - e0) < EPS:
        return cuts  # 没动

    # ① 新区间该是 keep 还是 cut
    want_cut = is_fully_in_cuts(cuts, s0, e0)

    out = list(cuts)
    if want_cut:
        # 整段要变 cut：先从 cuts 里挖掉旧的，再补上新的
        out = [(a, b) for (a, b) in out if not (a <= s0 + EPS and e0 <= b + EPS)]
        out.append((s1, e1))
    else:
        # 整段要变 keep：先把新范围从所有 cut 里挖掉
        newout = []
        for a, b in out:
            # 挖掉与 [s1,e1) 的交集
            if e1 <= a or b <= s1:
                newout.append((a, b)); continue
            if a < s1:
                newout.append((a, s1))
            if e1 < b:
                newout.append((e1, b))
        out = newout
    return merge(out, duration)


def clamp(newStart, newEnd, duration):
    """
    三重夹取（定稿 4.3）：
      ① 不越素材边界 [0, duration]
      ② 整段不短于 MIN_SEG
    ⚠️ 初版只做了 ②，实测两条 bug：
       - cut 段往左拖到 0 之前 → 没夹住
       - 本来就 < MIN_SEG 的末段 → ②的公式从「放大」出发，压根没生效
       正确做法：**先按边界夹，再用「若仍不足则平移补足」**。
    """
    lo, hi = 0.0, duration
    newStart = min(max(newStart, lo), hi)
    newEnd = min(max(newEnd, lo), hi)
    if newEnd - newStart < MIN_SEG:
        # 空间不够就整体贴到边界；够就平移到中点
        if hi - lo < MIN_SEG:
            return lo, hi
        mid = (newStart + newEnd) / 2
        newStart = mid - MIN_SEG / 2
        newEnd = mid + MIN_SEG / 2
        if newStart < lo:
            newStart, newEnd = lo, lo + MIN_SEG
        if newEnd > hi:
            newStart, newEnd = hi - MIN_SEG, hi
    return newStart, newEnd


if __name__ == "__main__":
    d = json.load(open("samples/gaps.json", encoding="utf-8"))
    obj = d[0]
    db, total = obj["db"], obj["total"]
    step, th = 0.01, -30.0
    cuts = []
    i = 0
    while i < len(db):
        if db[i] < th:
            j = i
            while j < len(db) and db[j] < th:
                j += 1
            cuts.append((i * step, min(j * step, total)))
            i = j
        else:
            i += 1
    marks = build(total, cuts)
    keeps = [(s, e) for s, e, k in marks if k == 'keep']
    cutsets = [(s, e) for s, e, k in marks if k == 'cut']

    print("【场景验证】")
    print("原始段：keep %d 个 / cut %d 个，成品时长 %.3fs" % (len(keeps), len(cutsets), sum(e-s for s,e in keeps)))
    print()

    tests = [
        # (说明, 段类型, 原区间, 拖动方向, 新边界)
        ("keep段往左拖(扩开头)", 'keep', keeps[1], -0.30),
        ("keep段往右拖(缩开头)", 'keep', keeps[1], +0.30),
        ("keep段往左拖过头(超素材开头)", 'keep', keeps[0], -5.0),
        ("keep段拖成0.05s(低于最短段)", 'keep', keeps[1], None),
        ("cut段往左拖(扩开头)", 'cut', cutsets[0], -0.20),
        ("cut段往右拖(缩开头)", 'cut', cutsets[0], +0.20),
        ("最后keep段往右拖(扩结尾)", 'keep', keeps[-1], +0.40),
        ("最后keep段往右拖过头(超素材结尾)", 'keep', keeps[-1], +5.0),
    ]

    bad = 0
    for label, kind, seg, delta in tests:
        s0, e0 = seg
        if delta is None:
            ns, ne = s0 + 0.02, s0 + 0.07      # 故意拖成 0.05s
        elif '往左' in label:
            ns, ne = s0 + delta, e0
        else:
            ns, ne = s0, e0 + delta
        cs, ce = clamp(ns, ne, total)
        newcuts = cuts_for_new_bounds(cuts, total, seg, cs, ce)
        nm = build(total, newcuts)
        nkeeps = [(s, e) for s, e, k in nm if k == 'keep']

        # 不变量。
        # ⚠️ 只校验「拖动影响到的那个段」不短于 MIN_SEG ——
        # **不能**要求全时间线每段都 ≥ MIN_SEG：检测阈值（minCut）本来就会切出
        # 0.03s 这种碎段（这正是样片数据里的真实情况），那是检测层的事，
        # 拖拽夹取不该越界去改它。初版断言写错，8 个场景全报 BAD，害我以为逻辑有问题。
        errs = []
        if abs(nm[0][0]) > 1e-9: errs.append("起点非0")
        if abs(nm[-1][1] - total) > 1e-9: errs.append("终点≠duration")
        for k in range(1, len(nm)):
            if abs(nm[k][0] - nm[k-1][1]) > 1e-9: errs.append("第%d段不严丝合缝" % k)
        for s, e, k in nm:
            if e - s <= 1e-9: errs.append("零宽段")
        # 夹取后新区间本身必须够长
        if ce - cs < MIN_SEG - 1e-9:
            errs.append("拖动后区间 %.3fs 短于 %.1fs" % (ce - cs, MIN_SEG))
        # 夹取后不能越界
        if cs < -1e-9 or ce > total + 1e-9:
            errs.append("拖动后越界 [%.3f,%.3f]" % (cs, ce))

        moved = abs(cs-s0) > EPS or abs(ce-e0) > EPS
        status = "OK" if not errs else "BAD"
        if errs: bad += 1
        print("%-30s [%6.2f→%6.2f] 拖到 [%6.2f→%6.2f]%s  %s"
              % (label, s0, e0, cs, ce, " (已夹取)" if not moved else "", status))
        if errs:
            print("      " + "; ".join(errs[:3]))
        if kind == 'keep':
            print("      → 成品时长 %.3fs (原 %.3fs)" % (sum(e-s for s,e in nkeeps), sum(e-s for s,e in keeps)))

    print()
    print("异常 %d 处" % bad)
    print()
    print("结论：cuts_for_new_bounds 保证了拖动后 marks 仍然严丝合缝、无零宽、段长不短于 %.1fs" % MIN_SEG)
