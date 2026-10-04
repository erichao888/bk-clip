# -*- coding: utf-8 -*-
"""
N0 段模型设计验证：先想清楚「段」到底要不要真的存起来。

【关键发现】现有 BKMark + normalize 已经做到了：
  覆盖 [0,duration] / 相邻严丝合缝 / 无零宽 / 重叠裁断 / 缝隙补 keep / 同类合并
  → 也就是说「段」这个语义**现在已经被推导出来了**，只是推导发生在
    `pieces()` 里（显示用），而 keepRanges/cutRanges 各自 filter 一次。

所以 N0 有两条路：
  路线甲：真存 segments 数组，marks 变成派生（改动大、风险高，但语义最正）
  路线乙：不新增存储，只在 BKTimeline 上加「段」的构造与查询 API（改动小）

这个脚本验证：**能否从现有 marks 稳定地还原出段序列**，
以及在「折叠删红」的新语义下（ripple 拼接），段模型要额外提供什么。
"""
import json

MIN_SEG = 0.1   # 定稿：最短段 0.1s


def merge(cuts, duration):
    clean = [(max(a, 0), min(b, duration)) for a, b in cuts]
    clean = [(a, b) for a, b in clean if b > a]
    clean.sort()
    out = []
    for iv in clean:
        if out and iv[0] <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], iv[1]))
        else:
            out.append(list(iv) if False else (iv[0], iv[1]))
    return out


def merge_same_kind(segs):
    out = []
    for s in segs:
        if out and out[-1][2] == s[2]:
            out[-1] = (out[-1][0], s[1], s[2])
        else:
            out.append(s)
    return out


def normalize(marks, duration):
    """逐行复刻 BKTimeline.normalize"""
    cleaned = []
    for s, e, k in marks:
        cs = min(max(s, 0), duration)
        ce = min(max(e, 0), duration)
        if ce - cs > 0.001:
            cleaned.append((cs, ce, k))
    cleaned.sort(key=lambda m: m[0])

    out = []
    for m in cleaned:
        if out:
            lastEnd = out[-1][1]
            if m[0] < lastEnd:
                out[-1] = (out[-1][0], m[0], out[-1][2])
            ne = out[-1][1]
            if ne < m[0]:
                out.append((ne, m[0], 'keep'))
        out.append(m)

    widowed = [m for m in out if m[1] - m[0] > 0.001]
    if not widowed:
        return [(0, duration, 'keep')]
    result = merge_same_kind(widowed)
    if result[0][0] > 0:
        result.insert(0, (0, result[0][0], 'keep'))
    if result[-1][1] < duration:
        result.append((result[-1][1], duration, 'keep'))
    return result


def build(duration, cuts):
    """逐行复刻 BKTimeline.build"""
    marks = []
    cursor = 0.0
    for s, e in merge(cuts, duration):
        if s > cursor:
            marks.append((cursor, s, 'keep'))
        marks.append((s, e, 'cut'))
        cursor = e
    if cursor < duration:
        marks.append((cursor, duration, 'keep'))
    return normalize(marks, duration)


def invariants(seg, duration, tag):
    """铁律四条不变量"""
    errs = []
    if abs(seg[0][0]) > 1e-9:
        errs.append("起点不是 0: %.6f" % seg[0][0])
    if abs(seg[-1][1] - duration) > 1e-9:
        errs.append("终点不是 duration: %.6f vs %.6f" % (seg[-1][1], duration))
    for i in range(1, len(seg)):
        if abs(seg[i][0] - seg[i-1][1]) > 1e-9:
            errs.append("第%d段与第%d段不严丝合缝: %.9f vs %.9f"
                        % (i, i-1, seg[i-1][1], seg[i][0]))
    for s, e, k in seg:
        if e - s <= 1e-9:
            errs.append("零宽段 [%s,%s]" % (s, e))
    if errs:
        print("  [FAIL] %s" % tag)
        for e in errs[:5]:
            print("         " + e)
    return len(errs) == 0


def fold_red(seg):
    """
    删红键的语义：把 .cut 段标记为「已折叠」，
    .keep 段按原顺序 ripple 拼接 → 返回「成品序列」。
    ⚠️ 源区间不变（这就是「缓存」），只是不再出现在成品时间轴上。
    """
    kept = [(s, e) for s, e, k in seg if k == 'keep']
    return kept, sum(e - s for s, e in kept)


if __name__ == "__main__":
    d = json.load(open("samples/gaps.json", encoding="utf-8"))
    obj = d[0]
    db, total = obj["db"], obj["total"]
    step, th = 0.01, -30.0

    # 从包络造 cuts
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

    seg = build(total, cuts)
    print("素材 %s 时长 %.2fs" % (obj["name"], total))
    print("从包络造出 %d 个删红区间 → build 出 %d 段" % (len(cuts), len(seg)))
    ok = invariants(seg, total, "真实数据")
    print("不变量:", "全绿" if ok else "有 FAIL")

    print()
    print("前 8 段：")
    for s, e, k in seg[:8]:
        print("  %-6s [%6.2f → %6.2f]  %.2fs" % (k, s, e, e - s))

    # 删红折叠
    kept, keptLen = fold_red(seg)
    print()
    print("删红后：%d 个绿段保留，成品时长 %.3fs（原片 %.3fs，删掉 %.3fs）"
          % (len(kept), keptLen, total, total - keptLen))

    # 验证折叠后绿段严丝合缝拼成一条
    gaps = [(kept[i][0], kept[i-1][1]) for i in range(1, len(kept))
            if kept[i][0] - kept[i-1][1] > 1e-9]
    print("绿段之间的原片缝隙（这正是被删的部分，应有 %d 处）: %d" % (len(cuts), len(gaps)))

    # 随机脏数据压测
    import random
    random.seed(20261004)
    bad = 0
    for n in range(6000):
        dur = random.uniform(0.1, 120)
        k = random.randint(0, 12)
        cs = []
        for _ in range(k):
            a = random.uniform(-5, dur + 5)
            b = random.uniform(-5, dur + 5)
            cs.append((a, b))
        try:
            s2 = build(dur, cs)
        except Exception as ex:
            print("  [异常] %s" % ex)
            bad += 1
            continue
        if not invariants(s2, dur, "随机#%d dur=%.2f cuts=%s" % (n, dur, cs)):
            bad += 1
            if bad > 3:
                break
    print()
    print("随机脏数据 6000 组：%s" % ("全绿" if bad == 0 else "%d 组失败" % bad))
