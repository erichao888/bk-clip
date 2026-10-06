#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bk剪辑 v2.0 · P1 验证脚本
==================================================
主轨道分段导出 —— 纯逻辑复刻（无 UIKit / AVFoundation 依赖）

目标：在写 Swift 之前，用 Python 把下面两件事复刻出来并验证不变量：
  1) 主轨拼接：多片段（BKProject）按 outputDuration 首尾相接 → prefix-sum 输出时间轴
  2) 选区映射：在主轨输出时间上选 [G0, G1] → 逐片段求交 → 经各片段 foldMap
     （只含绿区，气口自动跳过）→ 收集 (asset, 原片区间[]) → 一条 composition → 一个成品

foldMap 定义（与 docs/主轨道分段导出方案.md 一致）：
  BKTimeline.foldMap: [(out, src, dur)]
    out = 该绿区在「片段内输出时间」的起点
    src = 该绿区在「原片源时间」的起点
    dur = 绿区时长（源→输出 1:1，无缩放）
  只含绿区；相邻绿区在原片里可能隔着气口，但输出时间上首尾相接、无缝。

不变量（随机校验必须全绿才抄进 Swift）：
  [主轨拼接]
    M1 主轨从 0 起、到 total 止
    M2 片段之间相邻无缝（无 gap、无 overlap）
    M3 每片段 outputDuration == 其 foldMap 时长之和（>0）
  [选区映射]
    S1 选区映射总输出时长 == 选区长度 (G1-G0)
    S2 选区映射输出的「选区本地时间」覆盖 [0, selLen] 且相邻无缝、无零宽
    S3 每个源区间长度 > 0，且落在 [0, assetDuration] 内
    S4 全量选区 [0, total] 映射结果 == 各片段 keepRanges 原样（绿区不丢不错）
    S5 选区整段 snap 到某片段 [Mi, Mi+1] 时，结果 == 该片段 keepRanges 原样
"""

import random
import math
from dataclasses import dataclass, field

EPS = 1e-9


# ----------------------------------------------------------------------------
# 1. 单片段（BKProject）模型
# ----------------------------------------------------------------------------
@dataclass
class Segment:
    asset_id: str
    asset_duration: float          # 原片总时长（秒）
    keep_ranges: list              # 绿区：[(s0, s1), ...] 源时间，已排序、不重叠、落在 [0, asset_duration]
    foldmap: list = field(default_factory=list)   # [(out, src, dur)]
    output_duration: float = 0.0
    main_start: float = 0.0        # 在主轨输出时间轴上的起点
    main_end: float = 0.0          # 在主轨输出时间轴上的终点


def build_foldmap(keep_ranges: list, asset_duration: float) -> list:
    """keep_ranges（源时间绿区）→ foldMap（片段内输出时间 → 源时间，只含绿区）。"""
    fold = []
    out = 0.0
    for (s0, s1) in keep_ranges:
        dur = s1 - s0
        if dur <= EPS:
            continue
        # 夹紧到 [0, asset_duration]，防御脏数据
        s0c = max(0.0, min(asset_duration, s0))
        s1c = max(0.0, min(asset_duration, s1))
        durc = s1c - s0c
        if durc <= EPS:
            continue
        fold.append((out, s0c, durc))
        out += durc
    return fold


def make_segment(asset_id: str, asset_duration: float, keep_ranges: list) -> Segment:
    seg = Segment(asset_id=asset_id, asset_duration=asset_duration, keep_ranges=keep_ranges)
    seg.foldmap = build_foldmap(keep_ranges, asset_duration)
    seg.output_duration = seg.foldmap[-1][0] + seg.foldmap[-1][2] if seg.foldmap else 0.0
    return seg


# ----------------------------------------------------------------------------
# 2. 主轨拼接（prefix-sum）
# ----------------------------------------------------------------------------
def build_main_track(segments: list) -> float:
    """多片段按 outputDuration 首尾相接，回填每片段 main_start/main_end。返回 total。"""
    t = 0.0
    for seg in segments:
        seg.main_start = t
        seg.main_end = t + seg.output_duration
        t = seg.main_end
    return t


# ----------------------------------------------------------------------------
# 3. 选区映射：主轨输出时间 [G0, G1] → (asset, 原片区间[]) 有序序列
# ----------------------------------------------------------------------------
def map_selection(segments: list, G0: float, G1: float,
                  total: float) -> list:
    """
    返回：[(asset_id, [clip, ...]), ...]  按输出顺序排列
      clip = {src_s, src_e, out_local_s, out_local_e}
        src_s/src_e : 原片源时间区间（喂给 make(segments:) 的 keeps）
        out_local_s/out_local_e : 该 clip 在「选区本地时间」[0, selLen] 中的位置
    """
    sel_len = G1 - G0
    result = []
    for seg in segments:
        m_start, m_end = seg.main_start, seg.main_end
        if G1 <= m_start + EPS or G0 >= m_end - EPS:
            continue  # 不相交
        lo = max(G0, m_start) - m_start   # 片段内输出本地起点
        hi = min(G1, m_end) - m_start     # 片段内输出本地终点
        clips = []
        for (out_off, src_start, dur) in seg.foldmap:
            o0, o1 = out_off, out_off + dur
            a = max(lo, o0)
            b = min(hi, o1)
            if b - a <= EPS:
                continue
            # 源时间 1:1 映射（foldMap 无缩放）
            ss = src_start + (a - o0)
            se = src_start + (b - o0)
            # 该 clip 在主轨输出时间的位置：[m_start+a, m_start+b]
            # 转成选区本地时间：减去 G0
            out_local_s = (m_start + a) - G0
            out_local_e = (m_start + b) - G0
            clips.append({"src_s": ss, "src_e": se,
                          "out_local_s": out_local_s, "out_local_e": out_local_e})
        if clips:
            result.append((seg.asset_id, clips))
    return result


def to_make_compatible(mapped: list) -> list:
    """把 map_selection 结果压成 make(segments:) 签名：[(asset_id, [(s0,s1),...]), ...]"""
    return [(aid, [(c["src_s"], c["src_e"]) for c in clips]) for (aid, clips) in mapped]


# ----------------------------------------------------------------------------
# 4. 不变量校验
# ----------------------------------------------------------------------------
def check_main_track(segments: list, total: float) -> list:
    """M1/M2/M3。返回违规信息列表（空=全过）。"""
    errs = []
    if abs(segments[0].main_start) > EPS:
        errs.append(f"M1 主轨未从0起: start={segments[0].main_start}")
    if abs(segments[-1].main_end - total) > EPS:
        errs.append(f"M1 主轨未到total止: end={segments[-1].main_end} total={total}")
    prev_end = 0.0
    for i, seg in enumerate(segments):
        if abs(seg.main_start - prev_end) > EPS:
            errs.append(f"M2 片段{i} 与上前不相邻: start={seg.main_start} prev_end={prev_end}")
        if seg.output_duration <= EPS:
            errs.append(f"M3 片段{i} outputDuration<=0")
        fold_sum = sum(d for (_, _, d) in seg.foldmap)
        if abs(fold_sum - seg.output_duration) > EPS:
            errs.append(f"M3 片段{i} foldMap和({fold_sum}) != outputDuration({seg.output_duration})")
        prev_end = seg.main_end
    return errs


def check_selection(segments: list, G0: float, G1: float, total: float,
                    mapped: list) -> list:
    """S1/S2/S3。返回违规信息列表（空=全过）。"""
    errs = []
    sel_len = G1 - G0
    dur_sum = 0.0
    out_ranges = []
    asset_dur = {seg.asset_id: seg.asset_duration for seg in segments}

    for (aid, clips) in mapped:
        ad = asset_dur.get(aid, float("inf"))
        for c in clips:
            d = c["src_e"] - c["src_s"]
            if d <= EPS:
                errs.append(f"S3 零宽源区间 {aid}: {c['src_s']}..{c['src_e']}")
            if c["src_s"] < -EPS or c["src_e"] > ad + EPS:
                errs.append(f"S3 源区间越界 {aid}: [{c['src_s']},{c['src_e']}] 资产时长={ad}")
            dur_sum += d
            out_ranges.append((c["out_local_s"], c["out_local_e"]))

    if abs(dur_sum - sel_len) > 1e-6:
        errs.append(f"S1 映射总输出({dur_sum}) != 选区长({sel_len})")

    # S2：选区本地时间覆盖 [0, selLen] 且相邻无缝
    out_ranges.sort(key=lambda x: x[0])
    cur = 0.0
    for (s, e) in out_ranges:
        if s < cur - 1e-6:
            errs.append(f"S2 选区本地时间重叠: cur={cur} 段=[{s},{e}]")
            break
        if s > cur + 1e-6:
            errs.append(f"S2 选区本地时间有缝: cur={cur} 下一段起点={s}")
            break
        if e - s <= EPS:
            errs.append(f"S2 零宽输出段: [{s},{e}]")
            break
        cur = e
    if abs(cur - sel_len) > 1e-6:
        errs.append(f"S2 选区本地未覆盖到 selLen: cur={cur} selLen={sel_len}")
    return errs


def check_full_track_equivalent(segments: list, mapped: list) -> list:
    """S4：全量选区结果需 == 各片段 keepRanges 原样（绿区不丢不错，按片段顺序）。"""
    errs = []
    if len(mapped) != len(segments):
        errs.append(f"S4 全量映射片段数({len(mapped)}) != 片段数({len(segments)})")
        return errs
    for (seg, (aid, clips)) in zip(segments, mapped):
        if aid != seg.asset_id:
            errs.append(f"S4 片段顺序/asset 不符: {aid} vs {seg.asset_id}")
        got = [(round(c["src_s"], 6), round(c["src_e"], 6)) for c in clips]
        exp = [(round(s0, 6), round(s1, 6)) for (s0, s1) in seg.keep_ranges if s1 - s0 > EPS]
        if got != exp:
            errs.append(f"S4 片段 {aid} 绿区不符:\n  得 {got}\n  期 {exp}")
    return errs


def check_snap_whole(segments: list, idx: int, mapped: list) -> list:
    """S5：选区整段 snap 到片段 idx 时，结果 == 该片段 keepRanges 原样。"""
    errs = []
    seg = segments[idx]
    if len(mapped) != 1 or mapped[0][0] != seg.asset_id:
        errs.append(f"S5 snap 片段{idx} 结果不是单片段 {seg.asset_id}: {[a for a,_ in mapped]}")
        return errs
    got = [(round(c["src_s"], 6), round(c["src_e"], 6)) for c in mapped[0][1]]
    exp = [(round(s0, 6), round(s1, 6)) for (s0, s1) in seg.keep_ranges if s1 - s0 > EPS]
    if got != exp:
        errs.append(f"S5 snap 片段{idx} 绿区不符:\n  得 {got}\n  期 {exp}")
    return errs


# ----------------------------------------------------------------------------
# 5. 确定性手算样例（文档可复现）
# ----------------------------------------------------------------------------
def deterministic_example():
    print("=== 确定性样例 ===")
    segA = make_segment("A", asset_duration=100.0, keep_ranges=[(0, 30), (50, 80)])
    segB = make_segment("B", asset_duration=100.0, keep_ranges=[(10, 40)])
    segs = [segA, segB]
    total = build_main_track(segs)
    print(f"  A foldMap={segA.foldmap} outDur={segA.output_duration}")
    print(f"  B foldMap={segB.foldmap} outDur={segB.output_duration}")
    print(f"  主轨 total={total}  A:[{segA.main_start},{segA.main_end}]  B:[{segB.main_start},{segB.main_end}]")

    errs = check_main_track(segs, total)
    assert not errs, f"主轨不变量失败: {errs}"

    # 全量选区
    mapped = map_selection(segs, 0.0, total, total)
    errs = check_selection(segs, 0.0, total, total, mapped) + check_full_track_equivalent(segs, mapped)
    assert not errs, f"全量选区失败: {errs}"
    print(f"  全量 [0,{total}] → {to_make_compatible(mapped)}")
    assert to_make_compatible(mapped) == [("A", [(0, 30), (50, 80)]), ("B", [(10, 40)])]

    # 部分选区 [30, 75]
    G0, G1 = 30.0, 75.0
    mapped = map_selection(segs, G0, G1, total)
    errs = check_selection(segs, G0, G1, total, mapped)
    assert not errs, f"部分选区失败: {errs}"
    print(f"  部分 [30,75] → {to_make_compatible(mapped)}")
    # 手算预期：A 取 (50,80) 输出本地 [0,30]；B 取 (10,25) 输出本地 [30,45]
    assert to_make_compatible(mapped) == [("A", [(50, 80)]), ("B", [(10, 25)])]
    # 验证 out_local 连续覆盖 [0,45]
    all_out = [(c["out_local_s"], c["out_local_e"]) for (_, clips) in mapped for c in clips]
    all_out.sort()
    assert all_out[0][0] == 0.0 and abs(all_out[-1][1] - 45.0) < 1e-6

    # snap 整段到 A [0,60]
    mapped = map_selection(segs, 0.0, segA.main_end, total)
    errs = check_snap_whole(segs, 0, mapped)
    assert not errs, f"snap A 失败: {errs}"
    print(f"  snap A [0,60] → {to_make_compatible(mapped)}")
    assert to_make_compatible(mapped) == [("A", [(0, 30), (50, 80)])]

    print("  确定性样例全部通过 ✓\n")


# ----------------------------------------------------------------------------
# 6. 随机模糊测试
# ----------------------------------------------------------------------------
def random_keep_ranges(dur: float, rng: random.Random) -> list:
    """在 [0, dur] 内随机撒绿区，绿区之间留随机气口。"""
    ranges = []
    t = rng.uniform(0, dur * 0.1)
    while t < dur:
        g = rng.uniform(0.2, dur * 0.15)        # 气口
        s0 = t + g
        if s0 >= dur:
            break
        glen = rng.uniform(0.5, dur * 0.4)       # 绿区长度
        s1 = min(dur, s0 + glen)
        if s1 - s0 > EPS:
            ranges.append((s0, s1))
        t = s1 + rng.uniform(0.0, dur * 0.1)     # 下一段前留白
    ranges.sort()
    return ranges


def fuzz(iters: int = 5000, seed: int = 12345):
    print(f"=== 随机模糊测试 ({iters} 轮, seed={seed}) ===")
    rng = random.Random(seed)
    total_fail = 0
    for it in range(iters):
        n = rng.randint(1, 5)
        segs = []
        for i in range(n):
            dur = rng.uniform(5.0, 300.0)
            kr = random_keep_ranges(dur, rng)
            if not kr:
                kr = [(0.0, dur)]   # 兜底：整段绿
            segs.append(make_segment(f"asset{i}", dur, kr))
        total = build_main_track(segs)

        errs = check_main_track(segs, total)
        if errs:
            total_fail += 1
            if total_fail <= 5:
                print(f"  [轮{it}] 主轨失败: {errs}")
            continue

        # 选三种选区之一：全量 / 整段snap / 随机子区间
        mode = rng.choice(["full", "snap", "rand"])
        if mode == "full":
            G0, G1 = 0.0, total
        elif mode == "snap":
            idx = rng.randrange(n)
            G0, G1 = segs[idx].main_start, segs[idx].main_end
        else:
            a = rng.uniform(0, total)
            b = rng.uniform(0, total)
            G0, G1 = min(a, b), max(a, b)
            if G1 - G0 < EPS:
                G1 = min(total, G0 + 1.0)

        mapped = map_selection(segs, G0, G1, total)
        errs = check_selection(segs, G0, G1, total, mapped)
        if mode == "full":
            errs += check_full_track_equivalent(segs, mapped)
        if mode == "snap":
            errs += check_snap_whole(segs, idx, mapped)
        if errs:
            total_fail += 1
            if total_fail <= 8:
                print(f"  [轮{it}] 模式={mode} G0={G0:.3f} G1={G1:.3f} 失败: {errs}")
                print(f"          片段={[(s.asset_id, round(s.output_duration,3), s.keep_ranges) for s in segs]}")

    if total_fail == 0:
        print(f"  {iters} 轮全部通过 ✓（主轨拼接 + 选区映射不变量无违规）\n")
    else:
        print(f"  ❌ 失败 {total_fail}/{iters} 轮\n")
    return total_fail


if __name__ == "__main__":
    deterministic_example()
    fail = fuzz(iters=5000, seed=12345)
    if fail == 0:
        print("结论：P1 纯逻辑不变量全绿，可抄进 Swift（BKTimeline.foldMap / 主轨 prefix-sum / 选区→源映射）。")
    else:
        print("结论：存在违规，先修逻辑再抄 Swift。")
        raise SystemExit(1)
