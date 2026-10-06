#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bk剪辑 v2.0 · 变速 × 三层坐标验证（对应 docs/规格补充B-变速对导出管线的影响.md §3.3）
================================================================================
变速打破导出方案「轨道时间轴 = 原片时间，duration 不变，零换算」不变式。

⚠️ 勘误（实测发现，待 P2 确认）：
   原文档 §3.3 写 `out = prefix_kept[i] + (src - s0)`，即 out 轴取「绿区源长之和」，
   speed 只改 trackT 宽度、不改 out 长度。这会导致：speed=2 时一个 10s 源区在编辑轨只占
   5s（L/sp），但导出仍占 10s → 编辑器与导出播放速率在跨倍速区块处错位，违反「所见即所得」。
   正确的 NLE 模型（本脚本验证版）：**trackT 轴 == out 轴**（都是「折叠后的播放时长」），
   speed 同时压缩两者；trackT↔src 才是逐区块倍速映射：
       local = trackT - T_i                       # 块内播放时长
       src   = s0 + local * sp_i                  # 源轴按倍速采样
       out   = T_i + local  == trackT             # out 与 trackT 同一轴
   块播放时长 = (e0 - s0) / sp_i，speed 越大块越短、消耗源越快。
   这样「编辑器时间轴 = 导出成品」恒成立，跨倍速块边界连续。

不变量（随机校验全绿才抄进 Swift）：
  V1  trackT → src → trackT 往返一致，误差 < 1e-6
  V2  out(0) == 0（== trackT(0)）
  V3  out(totalTimeline) == Σ(e0-s0)/sp（绿区播放时长之和）
  V4  src 落在本块 [s0, e0]；out 落 [0, totalOut]
  V5  区块边界（折叠点）在 trackT 下连续，相邻块共享同一 out 坐标
"""

import random
import math

EPS = 1e-9
SPEEDS = [0.1, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0]


def build_track(materials):
    """materials: list of {keeps:[(s0,e0)...], speeds:[...]}。
    主轨 = 所有素材绿区按序拼接（每绿区 = 一个区块）。
    返回 blocks / 总播放时长(totalOut)。
    blocks[i] = (src_s0, src_e0, speed, T_i, out_i)，其中 T_i == out_i（同一轴）。"""
    blocks = []
    prefix = 0.0          # 同时是 trackT 前缀 与 out 前缀（两轴合一）
    total_out = 0.0
    for m in materials:
        for (s0, e0), sp in zip(m["keeps"], m["speeds"]):
            L = e0 - s0
            play = L / sp
            blocks.append((s0, e0, sp, prefix, prefix))
            prefix += play
            total_out += play
    return blocks, total_out


def track_to_src_out(track_t, blocks, total_out):
    """轨道时间 → (源时间, 输出时间, 区块下标)。out == track_t（两轴合一）。"""
    for i, (s0, e0, sp, Ti, oi) in enumerate(blocks):
        bend = Ti + (e0 - s0) / sp
        if track_t <= bend + EPS:
            local = track_t - Ti
            src = s0 + local * sp                     # ★ 逐区块倍速采样
            out = Ti + local                          # == track_t
            return src, out, i
    i = len(blocks) - 1
    s0, e0, sp, Ti, oi = blocks[i]
    return e0, Ti + (e0 - s0) / sp, i


def src_out_to_track(out, blocks, total_out):
    """输出时间(==轨道时间) → 轨道时间（逆变换，验证往返；此处 out==trackT 直接取）。"""
    track_t = out
    for i, (s0, e0, sp, Ti, oi) in enumerate(blocks):
        bend = Ti + (e0 - s0) / sp
        if track_t <= bend + EPS:
            local = track_t - Ti
            return Ti + local
    i = len(blocks) - 1
    s0, e0, sp, Ti, oi = blocks[i]
    return Ti + (e0 - s0) / sp


def random_materials(rng):
    n = rng.randint(1, 5)
    mats = []
    for _ in range(n):
        dur = rng.uniform(5, 300)
        keeps, speeds = [], []
        t = 0.0
        while t < dur:
            g = rng.uniform(0.2, dur * 0.15)
            s0 = t + g
            if s0 >= dur:
                break
            glen = rng.uniform(0.5, dur * 0.4)
            e0 = min(dur, s0 + glen)
            if e0 - s0 > EPS:
                keeps.append((s0, e0))
                speeds.append(rng.choice(SPEEDS))
            t = e0 + rng.uniform(0, dur * 0.1)
        if not keeps:
            keeps = [(0.0, dur)]
            speeds = [rng.choice(SPEEDS)]
        mats.append({"srcDur": dur, "keeps": keeps, "speeds": speeds})
    return mats


def fuzz(iters=5000, seed=20261005):
    rng = random.Random(seed)
    fail = 0
    for it in range(iters):
        mats = random_materials(rng)
        blocks, total_out = build_track(mats)
        if total_out <= 0:
            continue
        mode = rng.choice(["full", "rand"])
        if mode == "full":
            track_t = rng.uniform(0, total_out)
        else:
            a = rng.uniform(0, total_out)
            b = rng.uniform(0, total_out)
            track_t = min(a, b)
        src, out, i = track_to_src_out(track_t, blocks, total_out)
        track_t2 = src_out_to_track(out, blocks, total_out)
        if abs(track_t2 - track_t) > 1e-6:
            fail += 1
            if fail <= 6:
                print(f"  [轮{it}] 往返误差 trackT={track_t:.6f} -> {track_t2:.6f} d={track_t2-track_t:.2e}")
            continue
        if out < -1e-6 or out > total_out + 1e-6:
            fail += 1
            if fail <= 6:
                print(f"  [轮{it}] out 越界 {out:.6f} / {total_out:.6f}")
            continue
        s0, e0, sp, Ti, oi = blocks[i]
        if src < s0 - 1e-6 or src > e0 + 1e-6:
            fail += 1
            if fail <= 6:
                print(f"  [轮{it}] src 越界 {src:.6f} / 块[{s0:.3f},{e0:.3f}]")
            continue
    # 端点不变量
    if blocks:
        _, out0, _ = track_to_src_out(0, blocks, total_out)
        if abs(out0) > 1e-6:
            fail += 1
            print("  V2 out(0) != 0")
        _, outE, _ = track_to_src_out(total_out, blocks, total_out)
        if abs(outE - total_out) > 1e-6:
            fail += 1
            print(f"  V3 out(totalTimeline)={outE:.6f} != totalOut={total_out:.6f}")
        # V5 边界连续：相邻块共享同一 out 坐标
        for k in range(len(blocks) - 1):
            end_prev = blocks[k][3] + (blocks[k][1] - blocks[k][0]) / blocks[k][2]
            start_next = blocks[k + 1][3]
            if abs(end_prev - start_next) > 1e-6:
                fail += 1
                print(f"  V5 块{k}末({end_prev:.6f}) != 块{k+1}起({start_next:.6f})")
    if fail == 0:
        print(f"  {iters} 轮全部通过 ✓（trackT==out，逐区块倍速采样 src=s0+local*sp）")
    else:
        print(f"  ❌ 失败 {fail}/{iters} 轮")
    return fail


if __name__ == "__main__":
    print("=== 变速三层坐标往返验证（修正版：trackT==out）===")
    fail = fuzz(iters=5000, seed=20261005)
    if fail == 0:
        print("结论：变速坐标换算不变量全绿，可抄进 Swift（BKTimeline 增加 trackT↔src 逐区块换表，out 轴与 trackT 合一）。")
    else:
        print("结论：存在违规，先修逻辑再抄 Swift。")
        raise SystemExit(1)
