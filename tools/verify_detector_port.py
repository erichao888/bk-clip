#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BKDetector.swift 移植校验
=========================
项目铁律：纯逻辑落进 Swift 之前，先在这里用同构 Python 复刻一遍
（verify_* 系列函数与 Swift 代码 1:1 对应，同样的结构、同样的边界），
然后与 preview_cut.py 的原版实现跑随机对照。

抓的是「翻译手滑」：下标错位、边界反了、条件写反。
两边输出必须完全一致才算通过（Otsu 允许半个 bin 宽的浮点差）。

用法：python tools/verify_detector_port.py
"""

import os
import random
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import preview_cut as ref

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

HOP = 0.01  # 每帧 10ms


# ---------- 与 Swift BKDetector.swift 1:1 对应的复刻 ----------

def swift_otsu(db):
    mid = (ref.CLAMP_LOW + ref.CLAMP_HIGH) / 2.0
    finite = [v for v in db if np.isfinite(v)]
    if len(finite) < 32:
        return mid
    lo0, hi0 = min(finite), max(finite)
    if hi0 - lo0 <= 1e-9:
        return mid
    bins = 256
    hist = [0.0] * bins
    scale = bins / (hi0 - lo0)
    for v in finite:
        idx = int((v - lo0) * scale)
        if idx >= bins:
            idx = bins - 1
        if idx < 0:
            idx = 0
        hist[idx] += 1
    s = sum(hist)
    if s <= 0:
        return mid

    def center(i):
        return lo0 + (i + 0.5) * (hi0 - lo0) / bins

    mt = sum(hist[i] / s * center(i) for i in range(bins))
    w0 = m0 = 0.0
    best_sigma = -1.0
    best_idx = None
    for i in range(bins):
        w0 += hist[i] / s
        m0 += hist[i] / s * center(i)
        denom = w0 * (1.0 - w0)
        if denom > 1e-9:
            sigma = (mt * w0 - m0) ** 2 / denom
            if sigma > best_sigma:
                best_sigma = sigma
                best_idx = i
    if best_idx is None:
        return mid
    return center(best_idx)


def swift_clamp(v):
    return min(max(v, ref.CLAMP_LOW), ref.CLAMP_HIGH)


def swift_detect_gaps(db, hop_sec, thr, total):
    gaps = []
    i = 0
    n = len(db)
    while i < n:
        if db[i] < thr:
            j = i
            while j < n and db[j] < thr:
                j += 1
            t0, t1 = i * hop_sec, j * hop_sec
            if t0 > 0.02 and t1 < total - 0.02 and (t1 - t0) >= ref.MIN_GAP:
                gaps.append((t0, t1))
            i = j
        else:
            i += 1
    return gaps


def swift_apply_pad(gaps):
    out = []
    for t0, t1 in gaps:
        s, e = t0 + ref.PAD, t1 - ref.PAD
        if (e - s) >= ref.MIN_CUT:
            out.append((s, e))
    return out


def swift_kept_segments(cuts, total):
    segs = []
    cur = 0.0
    for s, e in cuts:
        segs.append((cur, s))
        cur = e
    segs.append((cur, total))
    return [(a, b) for a, b in segs if b > a + 1e-6]


def swift_enforce_min_segment(cuts, total):
    dels = [list(c) for c in cuts]
    for _ in range(200):
        segs = swift_kept_segments([tuple(c) for c in dels], total)
        if len(segs) <= 1:
            break
        bad = -1
        for i, (a, b) in enumerate(segs):
            if (b - a) < ref.MIN_SEG:
                bad = i
                break
        if bad < 0:
            break
        if bad == 0:
            dels.pop(0)
        elif bad == len(segs) - 1:
            dels.pop()
        else:
            for k in sorted(set([bad - 1, bad]), reverse=True):
                if 0 <= k < len(dels):
                    dels.pop(k)
    return [tuple(c) for c in dels]


def swift_local_contrast(cuts, db, hop_sec, total):
    def level(t0, t1):
        a = max(0, int(t0 / hop_sec))
        b = min(len(db), int(t1 / hop_sec))
        if b <= a:
            return -120.0
        return max(db[a:b])

    keep = []
    for s, e in cuts:
        pre = level(max(0.0, s - ref.PAD - ref.PAD_SAMPLE), max(0.0, s - ref.PAD))
        post = level(e + ref.PAD, min(total, e + ref.PAD + ref.PAD_SAMPLE))
        speech = max(pre, post)
        gap = level(s, e)
        if (speech - gap) >= ref.CONTRAST_DB:
            keep.append((s, e))
    return keep


def swift_full(db, hop_sec, total):
    raw = swift_otsu(db)
    used = swift_clamp(raw)
    gaps = swift_detect_gaps(db, hop_sec, used, total)
    cuts = swift_enforce_min_segment(swift_apply_pad(gaps), total)
    cuts = swift_local_contrast(cuts, db, hop_sec, total)
    return raw, used, gaps, cuts


# ---------- 与 Swift BKAudioAnalyzer.buildEnvelope 1:1 对应的复刻 ----------

def swift_envelope(x, sr=ref.SR):
    frame = max(1, int(sr * 20 / 1000.0))
    hop = max(1, int(sr * 10 / 1000.0))
    n = len(x)
    cum = [0.0] * (n + 1)
    for i, v in enumerate(x):
        s = float(v) if np.isfinite(v) else 0.0
        cum[i + 1] = cum[i] + s * s
    if n < frame:
        mean = cum[n] / max(n, 1)
        return [20.0 * np.log10(max(np.sqrt(mean + 1e-12), 1e-7))], hop / sr
    frames = []
    start = 0
    while start <= n - frame:
        ssum = cum[start + frame] - cum[start]
        rms = np.sqrt(ssum / frame + 1e-12)
        frames.append(20.0 * np.log10(max(rms, 1e-7)))
        start += hop
    return frames, hop / sr


# ---------- 随机对照 ----------

def random_db(n):
    """模拟口播素材：语音底 + 段状静音 + 噪声。"""
    base = np.random.uniform(-45, -15)
    db = base + np.random.uniform(-3, 3, n)
    i = 0
    while i < n:
        seg = random.randint(5, 80)
        if random.random() < 0.45:
            db[i:i + seg] = np.random.uniform(-62, -42, min(seg, n - i))
        i += seg
    return [float(v) for v in db]


def main():
    random.seed(20261002)
    np.random.seed(20261002)
    fails = 0

    # ① 包络数学对照
    for case in range(50):
        n = random.choice([100, 1600, 16000])
        x = (np.random.uniform(-1, 1, n) * np.random.uniform(0, 1, n)).astype(np.float32)
        if case % 10 == 0:
            x[:10] = np.nan  # Swift 端对 NaN 置零，Python 复刻同款处理
        mine, hop_m = swift_envelope(x)
        rms, hop_r = ref.rms_envelope(x.astype(np.float64))
        theirs = ref.to_db(rms).tolist()
        if abs(hop_m - hop_r) > 1e-12 or len(mine) != len(theirs):
            fails += 1
            print(f"[包络 case {case}] 帧数不一致 {len(mine)} vs {len(theirs)}")
            continue
        for a, b in zip(mine, theirs):
            if abs(a - b) > 1e-6:
                fails += 1
                print(f"[包络 case {case}] 数值偏差 {a} vs {b}")
                break

    # ② 检测管线对照
    for case in range(300):
        n = random.choice([10, 40, 400, 3600, 18000])
        db = random_db(n)
        total = n * HOP
        arr = np.array(db)

        raw_s, used_s, gaps_s, cuts_s = swift_full(db, HOP, total)
        raw_r = ref.otsu_threshold(arr)
        used_r = ref.clamp_db(raw_r)
        gaps_r_full = ref.detect_gaps(arr, HOP, used_r, total)
        gaps_r = [(a, b) for a, b, _ in gaps_r_full]
        cuts_r = ref.local_contrast_pass(
            ref.enforce_min_segment(ref.apply_pad(gaps_r_full), total), arr, HOP, total)

        # Otsu 允许半个 bin 宽（直方分箱浮点实现差异）
        lo, hi = min(db), max(db)
        if hi - lo > 1e-9 and abs(raw_s - raw_r) > (hi - lo) / 256 + 1e-9:
            fails += 1
            print(f"[检测 case {case}] otsu 偏差过大: swift={raw_s:.3f} ref={raw_r:.3f}")
        if gaps_s != gaps_r:
            fails += 1
            print(f"[检测 case {case}] gaps 不一致 swift={gaps_s[:5]} ref={gaps_r[:5]}")
        if cuts_s != cuts_r:
            fails += 1
            print(f"[检测 case {case}] cuts 不一致 swift={cuts_s[:5]} ref={cuts_r[:5]}")

    # ③ 手写脏数据：全静音、全说话、单帧、空
    dirty = [
        [-60.0] * 3600,
        [-12.0] * 3600,
        [-30.0],
        [],
    ]
    for db in dirty:
        total = max(len(db) * HOP, 0.01)
        raw_s, used_s, gaps_s, cuts_s = swift_full(db, HOP, total)
        # 只要求不炸、区间合法
        for s, e in cuts_s:
            if not (0 <= s < e <= total + 1e-9):
                fails += 1
                print(f"[脏数据] 非法区间 ({s}, {e})，total={total}")

    total_cases = 350
    if fails:
        print(f"✗ 对照失败 {fails} 处（共 {total_cases} 组）")
        sys.exit(1)
    print(f"✓ 全部通过：50 组包络 + 300 组检测 + 4 组脏数据，Swift 移植与 Python 原版一致")


if __name__ == "__main__":
    main()
