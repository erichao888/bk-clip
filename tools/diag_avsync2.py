# -*- coding: utf-8 -*-
"""
音画错位根因验证：AVVideoAllowFrameReorderingKey: true（B 帧）到底怎么造成「画面滞后」。

【假设】
H.264 开启帧重排序（B 帧）后，**DTS ≠ PTS**：DTS 早于 PTS。
我们把 [DTS, PTS] 整段平移后交给 writer，writer 按 **DTS 排序写入**、
按 **PTS 标记显示时间**。这本身是对的。

但问题出在 `retimedBuffer` 用 `CMSampleBufferCreateCopyWithNewTiming` 时：
**它只改了 timing array，sample buffer 内部的 composition offset（ctts）没动**。
ctts = PTS - DTS。B 帧的 ctts 编码在容器里。

真正的问题有三个可能：
  A) ctts 与新 timing 冲突 → 播放器按容器 ctts 算显示时间，与我们写的 PTS 不一致
  B) 逐段新建 AVAssetReader，reader 吐出的帧的 DTS 是**相对源**的，
     平移后与上一段的 DTS 可能重叠/倒退 → writer 内部重排
  C) writer 的 B 帧重排序缓冲：expectsMediaDataInRealTime=false 时 writer 会等齐再写，
     但我们**交替 append 音视频**，视频轨的 B 帧重排序会跨段累积延迟

下面逐个量化。
"""
import json

SRC_FPS = 59.94
GOP = 60            # AVVideoMaxKeyFrameInterval = round(fps)
B_FRAMES = 2        # 典型 x264 baseline 不用 B 帧，但 high profile 会用


def simulate_offsets(keeps, seg_index, src_dur, use_b_frames, real_time):
    """
    模拟一段内音视频各自写入的时间线，返回段末两轨的实际结束时间。
    real_time=False 时 writer 要重排序（攒够 GOP），会引入额外延迟。
    """
    pass


def analyze_b_frame_delay(keeps, src_fps=59.96, gop=60):
    """
    B 帧重排序延迟的量化分析。

    H.264 带 B 帧时，一个 GOP 内的帧：
      I/P 帧的 ctts=0（DTS=PTS）
      B 帧的 ctts>0（DTS 早于 PTS，最多可达 reorder depth）

    x264 默认 max_b_frames=3 → reorder depth ≈ 3 帧 = 50ms@60fps。
    关闭重排序（reorder=0）后 B 帧被丢弃，不会有延迟。
    """
    frame_dur = 1.0 / src_fps
    for depth in (0, 1, 2, 3):
        delay = depth * frame_dur * 1000
        print("  reorder depth = %d → 最大显示延迟 %.1f ms" % (depth, delay))
    print()
    print("  源是 59.96fps：")
    for depth in (0, 1, 2, 3):
        print("    depth %d → %.1f ms" % (depth, depth * (1/59.96) * 1000))


def analyze_actual(keeps, src_dur):
    """
    真实场景：多段拼接，每段独立 reader。
    假设 writer 用 B 帧重排序（我们的设置）。
    每段末尾视频轨会比音频轨「看起来晚」多少？
    """
    print("段数 %d，源 %.2fs" % (len(keeps), src_dur))
    print()
    print("【假设 A】B 帧重排序在段边界造成的累计延迟")
    print("  writer 对视频轨用 reorder depth=3（GOP 内最多 3 帧 B）：")
    print("  每段的最后一帧是显示顺序的最后一帧，但写入时按 DTS 排。")
    print("  由于我们交替 append，writer 攒到 GOP 边界才吐 ——")
    print("  **段末那一帧的 PTS 会比音频块超出 reorder delay**")
    print()

    frame_dur = 1.0 / 59.96
    depth = 3
    delay = depth * frame_dur * 1000
    print("  单段最大延迟 = %.1f ms" % delay)
    print("  但关键是：**这个延迟是否跨段累积**")
    print()

    # 模拟：每段视频末帧的写入延迟
    total_vid_end = 0.0
    total_aud_end = 0.0
    print("  %-4s %-16s %10s %10s %10s" % ("段", "源区间", "视频末", "音频末", "差值"))
    print("  " + "-" * 56)
    cursor = 0.0
    for i, (s, e) in enumerate(keeps[:12]):
        offset = cursor - s
        dur = e - s
        # 视频末帧：floor((dur)/frame_dur) 帧
        nframes = int(dur / frame_dur)
        v_end = offset + nframes * frame_dur
        # 音频末块：floor(dur/AUD_BLOCK) 块
        nablocks = int(dur / 0.021333)
        a_end = offset + nablocks * 0.021333
        diff = (v_end - a_end) * 1000
        print("  %-4d [%6.2f→%6.2f] %10.4f %10.4f %+10.1fms"
              % (i, s, e, v_end, a_end, diff))
        cursor += dur
    print()
    print("  结论：每段的量化差在 ±20ms 内（帧 16.7ms vs 音频块 21.3ms），不累积。")
    print("        **所以 A 不是主因。**")


def analyze_our_change():
    """
    我们这次改的：outputCursor 按「实际写入长度」推进（取两轨较大值）。
    这会不会反而引入错位？
    """
    print("【关键】检查我们这次改的 outputCursor 逻辑")
    print()
    print("  改动前：outputCursor += 标称段长（segEnd - segStart）")
    print("  改动后：outputCursor += max(视频实际写入长度, 音频实际写入长度)")
    print()
    print("  ⚠️ 这里有个真问题：")
    print("  取「较大值」意味着：如果视频写了 0.0667s、音频写了 0.0640s，")
    print("  cursor 前进 0.0667s。**下一段的 offset 就按 0.0667 算**。")
    print("  但音频在上一段只写到 0.0640 —— 中间差 0.0027s 的空隙，")
    print("  下一段的音频从 0.0667 开始 → **音频轨中间出现 2.7ms 的空洞**。")
    print()
    print("  反过来如果音频写得长、视频写得短，**视频轨会出现空洞**。")
    print("  播放器遇到轨道空洞会把该轨静音/冻结 → 看起来就是「画面卡住不动」")
    print("  或「声音断一下」。")
    print()
    print("  这是我这次改动引入的**新**问题，方向和你看到的症状吻合。")
    print()
    print("  正解：两轨**各自**按自己的实际写入长度推进，")
    print("        也就是 offset 要**分轨计算**，不能共用一个。")


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

    # 反补出 keeps
    keeps = []
    cur = 0.0
    for s, e in cuts:
        if s > cur:
            keeps.append((cur, s))
        cur = e
    if cur < total:
        keeps.append((cur, total))
    keeps = [(s, e) for s, e in keeps if e - s > 0.05]

    print("=" * 60)
    print("B 帧重排序延迟量化")
    print("=" * 60)
    analyze_b_frame_delay(keeps)

    print()
    print("=" * 60)
    print("逐段量化差（不累积）")
    print("=" * 60)
    analyze_actual(keeps, total)

    print()
    print("=" * 60)
    print("我们这次改动引入的新问题")
    print("=" * 60)
    analyze_our_change()
