# -*- coding: utf-8 -*-
"""
复刻 BKExporter.exportSync + drainSegment 的时间戳算术，定位音画错位。

复刻点（严格照 BKExporter.swift 现状，v1.2.14）：
  - 每段新建 AVAssetReader，reader.timeRange = [segStart, segEnd)
  - offset = outputCursor - segStart
  - 样本放行条件 inRange: pts >= segStart - 1e-4 && pts < segEnd - 1e-4
  - 新 PTS = 原 PTS + offset
  - outputCursor += segRange.duration   （= segEnd - segStart，标称值）
  - 视频按帧网格推进（60fps），音频按样本块推进（AAC 1024/48000 ≈ 21.33ms）

关键怀疑点：
  (1) 段末尾被 inRange 丢掉的「不足一帧 / 不足一个音频块」的尾巴，
      在视频轨和音频轨上长度不同 → 每段都引入一点相对错位，逐段累积。
  (2) outputCursor 用标称 segEnd-segStart 推进，与实际写入的最后样本
      真实结束时间不重合 → 误差不归零、跨段累积。
"""
import json

VID_FPS = 59.94          # 源 59.96，标称按 60 算网格
VID_TBN = 600            # 源 tbn=600
AUD_RATE = 48000
AUD_FRAME = 1024         # AAC 一帧 1024 samples
AUD_BLOCK = AUD_FRAME / AUD_RATE   # ≈ 0.021333s
TOL = 1e-4


def frames_of_track(duration, fps=VID_FPS, tbn=VID_TBN):
    """模拟 AVAssetReaderTrackOutput 吐出的视频帧 PTS 网格（含 GOP 越界回带）。"""
    step = 1.0 / fps
    n = int(duration * fps) + 4
    return [i * step for i in range(n)]


def audio_blocks_of_track(duration):
    """模拟音频 sample buffer 的 PTS 网格。"""
    n = int(duration / AUD_BLOCK) + 4
    return [i * AUD_BLOCK for i in range(n)]


def run(keeps, label):
    vgrid = frames_of_track(keeps[-1][1] + 1.0)
    agrid = audio_blocks_of_track(keeps[-1][1] + 1.0)

    output_cursor = 0.0
    # 每段：记录视频/音频首末样本的「源时间」与「成品时间」
    rows = []
    for i, (s, e) in enumerate(keeps):
        offset = output_cursor - s

        # --- 视频：inRange 过滤 ---
        vsel = [p for p in vgrid if p >= s - TOL and p < e - TOL]
        v_new_first = vsel[0] + offset
        v_new_last = vsel[-1] + offset
        # 视频样本真实覆盖的结束时间 = 末帧 PTS + 一帧时长
        v_real_end = vsel[-1] + 1.0 / VID_FPS + offset

        # --- 音频：inRange 过滤 ---
        asel = [p for p in agrid if p >= s - TOL and p < e - TOL]
        a_new_first = asel[0] + offset
        a_new_last = asel[-1] + offset
        a_real_end = asel[-1] + AUD_BLOCK + offset

        # 段内音画相对错位 = 视频首帧新PTS - 音频首块新PTS
        #   >0 表示画面比声音晚（正是用户反馈的症状）
        skew_in_seg = v_new_first - a_new_first
        # 累计错位（视频相对音频），以各段末样本为准
        cum_skew_end = (v_real_end) - (a_real_end)

        rows.append(dict(
            seg=i, src=(round(s, 4), round(e, 4)),
            out=(round(output_cursor, 4), round(output_cursor + (e - s), 4)),
            v_first=round(v_new_first, 5), v_last=round(v_new_last, 5),
            a_first=round(a_new_first, 5), a_last=round(a_new_last, 5),
            v_real_end=round(v_real_end, 5), a_real_end=round(a_real_end, 5),
            skew_seg=round(skew_in_seg, 5),
            cum_skew=round(cum_skew_end, 5),
            # 该段视频实际时长 vs 标称时长
            v_span=round(v_real_end - v_new_first, 5),
            a_span=round(a_real_end - a_new_first, 5),
            nom=round(e - s, 5),
        ))
        output_cursor += (e - s)

    print(f"\n{'='*104}")
    print(f"【{label}】 段数={len(keeps)}  成品标称时长={output_cursor:.3f}s")
    print(f"{'='*104}")
    hdr = (f"{'段':>2} {'源区间':>17} {'成品区间':>17} "
           f"{'视频首':>8} {'音频首':>8} {'段内错位':>9} {'段末累计错位':>12} {'视频实长':>9} {'音频实长':>9} {'标称':>8}")
    print(hdr)
    print("-" * 104)
    for r in rows:
        print(f"{r['seg']:>2} {str(r['src']):>17} {str(r['out']):>17} "
              f"{r['v_first']:>8.4f} {r['a_first']:>8.4f} {r['skew_seg']:>+9.4f} "
              f"{r['cum_skew']:>+12.4f} {r['v_span']:>9.4f} {r['a_span']:>9.4f} {r['nom']:>8.4f}")

    final = rows[-1]
    print("-" * 104)
    print(f"末段累计音画错位：{final['cum_skew']:+.4f}s  "
          f"（正 = 画面晚于声音 {final['cum_skew']*1000:+.0f}ms）")
    print(f"成品标称 {output_cursor:.3f}s ；视频实际写到 {final['v_real_end']:.3f}s ；"
          f"音频实际写到 {final['a_real_end']:.3f}s")
    return rows


def keeps_from_gaps(idx, cuts):
    """用真实 db 包络 + 气口阈值切出 keep 段（模拟检测结果）。"""
    d = json.load(open("samples/gaps.json", encoding="utf-8"))
    obj = d[idx]
    db = obj["db"]
    total = obj["total"]
    step = 0.01
    n = len(db)
    # 简单阈值：db < th 判为气口(删)，>= th 判为保留
    th = -30.0
    keeps = []
    i = 0
    while i < n:
        if db[i] >= th:
            j = i
            while j < n and db[j] >= th:
                j += 1
            s, e = i * step, min(j * step, total)
            if cuts:
                e = min(e, total)
            if e - s > 0.05:
                keeps.append((s, e))
            i = j
        else:
            i += 1
    return obj["name"], keeps


if __name__ == "__main__":
    print("源片规格：1920x1080 / 59.96fps / tbn=600 / AAC-LC 48kHz")
    print("网格：视频帧 16.683ms，音频块 21.333ms")
    print()
    for idx, cuts in [(0, False), (1, True), (2, True), (3, True)]:
        name, keeps = keeps_from_gaps(idx, cuts)
        if len(keeps) < 2:
            continue
        run(keeps, f"{name} · 阈值 -30dB 自动检测")
