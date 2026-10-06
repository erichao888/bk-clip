#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bk剪辑 v2.0 · 第一批底栏骨架逻辑验证
（对应 docs/上下文底栏与参数面板-实现规格.md ① + docs/规格补充A-数值状态机吸附与状态清单.md ②③）
================================================================================
验证可纯逻辑部分（Swift 落地前先跑绿）：
  B1  currentBarTrack 状态机：无选中恒为 main；侧轨选中才切键组
  B2  自动蓝框 autoFrameMain：只在跨过区块边界时重绘（同 center 二次调用 redraw=False）
  B3  滚动边界（★ 2026-10-05 皓哥拍板，竞品式）：
      · 静止边界 = [−HALF, contentW−HALF]，起点/终点可到中央指针下（各留半屏空腔）
      · 程序化滚动硬夹取到静止边界
      · 手指拖动越界 = 橡皮筋：显示越界量 ≤ OVER=0.3×viewW，tanh 阻尼越拖越紧
      · 松手回弹：越界回弹到最近静止边界，任何静止状态不得越界
  B4  键组数量：main=10 / pip=9 / rec=5
  B5  双指缩放（★ 2026-10-05 皓哥拍板，竞品式）：
      · PPS 动态 ∈ [PPS_MIN=8, PPS_MAX=80]，纯视图层不进数据模型
      · 静止边界随 PPS 缩放：[−HALF, max(−HALF, TOTAL*PPS−HALF)]
      · 焦点稳定：缩放后焦点处 trackT 不变（焦点=双指中点/光标屏内 x）
★ 约束（原型踩过的坑 + 本轮拍板，验证里固化）：
  · 同 center 二次 autoFrame 不重绘（性能关键）
  · scrollTo 必须夹取（旧版下界 0 已废弃 → −HALF）
  · 橡皮筋纯视图层：release 后必须回到边界内；空腔不进数据模型、不影响导出
"""

import random
import math

EPS = 1e-9
PPS = 26.0
PPS_MIN = 8.0
PPS_MAX = 80.0
VIEW_W = 358.0   # iPhone 15 Pro Max 实测可视宽（屏 430 - 左右各 36）
HALF = VIEW_W / 2.0
OVER = VIEW_W * 0.3


def current_bar_track(selected_track, sel_pip_id, sel_rec_id):
    if selected_track == "pip" and sel_pip_id is not None:
        return "pip"
    if selected_track == "rec" and sel_rec_id is not None:
        return "rec"
    return "main"                       # 主轨恒为默认，不是空态


def auto_frame(regions, center_t, selected_id):
    """返回 (new_id, redraw)。redraw 仅在跨过区块边界（id 变化）时为 True。"""
    hit = None
    for (rid, a, b) in regions:
        if a - EPS <= center_t <= b + EPS:      # 闭区间命中
            hit = rid
            break
    new_id = hit
    return new_id, (new_id != selected_id)        # ★ 未变则直接返回，不重绘


def scroll_bounds(total):
    """静止边界（竞品式）：起点/终点都能到指针下。"""
    return (-HALF, max(-HALF, total * PPS - HALF))


def scroll_to(t, total):
    """程序化滚动（区块对准/录音跟随/迷你条拖动）：硬夹取静止边界，不走橡皮筋。"""
    mn, mx = scroll_bounds(total)
    return max(mn, min(t * PPS - HALF, mx))


def rubber(raw, total):
    """手指拖动越界：tanh 阻尼，最大可视过拖 OVER。"""
    mn, mx = scroll_bounds(total)
    if raw < mn:
        return mn - OVER * math.tanh((mn - raw) / OVER)
    if raw > mx:
        return mx + OVER * math.tanh((raw - mx) / OVER)
    return raw


def release(raw, total):
    """松手回弹的目标位置：越界弹回最近静止边界。"""
    mn, mx = scroll_bounds(total)
    if raw < mn:
        return mn
    if raw > mx:
        return mx
    return raw


def key_count(track):
    return {"main": 10, "pip": 9, "rec": 5}[track]


def zoom_offset(old_pps, old_offset, new_pps, focus_x, total):
    """双指缩放：改 PPS（纯视图层）并保持焦点处 trackT 不变，返回 (新PPS, 新offset, 焦点trackT)。
    对应原型 zoomTo()。focus_x = 双指中点/光标 的屏内 x（0..viewW）。"""
    np = max(PPS_MIN, min(PPS_MAX, new_pps))
    focus_t = (old_offset + focus_x) / old_pps          # 缩放前焦点 trackT
    mn = -HALF
    mx = max(-HALF, total * np - HALF)                   # 静止边界随 PPS 缩放
    new_offset = max(mn, min(focus_t * np - focus_x, mx))
    return np, new_offset, focus_t


def fuzz(iters=5000, seed=12345):
    rng = random.Random(seed)
    fail = 0
    for it in range(iters):
        st = rng.choice(["main", "pip", "rec"])
        pid = rng.choice([None, "p1", "p2"]) if st == "pip" else None
        rid = rng.choice([None, "r1", "r2"]) if st == "rec" else None
        if st == "main":
            pid = rid = None
        bt = current_bar_track(st, pid, rid)

        # B1 状态机
        if st == "main" and bt != "main":
            fail += 1; print(f"  [轮{it}] main 默认错: {bt}")
        if st == "pip" and pid is not None and bt != "pip":
            fail += 1; print(f"  [轮{it}] pip 选中错: {bt}")
        if st == "rec" and rid is not None and bt != "rec":
            fail += 1; print(f"  [轮{it}] rec 选中错: {bt}")
        if st in ("pip", "rec") and pid is None and rid is None and bt != "main":
            fail += 1; print(f"  [轮{it}] 无侧轨选中应回 main: {bt}")

        # B4 键组
        if key_count(bt) not in (10, 9, 5):
            fail += 1; print(f"  [轮{it}] 键数错: {key_count(bt)}")

        # 构造区块序列（轨道时间坐标）
        n = rng.randint(1, 5)
        regions = []
        cursor = 0.0
        for i in range(n):
            d = rng.uniform(2, 20)
            regions.append((f"b{i}", cursor, cursor + d))
            cursor += d
        total = cursor

        # B2 自动蓝框边界重绘
        center = rng.uniform(0, total)
        nid1, redraw1 = auto_frame(regions, center, None)
        _, redraw2 = auto_frame(regions, center, nid1)
        if redraw2:
            fail += 1; print(f"  [轮{it}] 同 center 二次应不重绘")

        # B3 滚动边界（竞品式）
        mn, mx = scroll_bounds(total)
        # 3a 两端可达：起点/终点对齐指针
        if abs(scroll_to(0, total) - (-HALF)) > 1e-6:
            fail += 1; print(f"  [轮{it}] offset(0) 应为 −HALF（起点压指针）")
        if abs(scroll_to(total, total) - mx) > 1e-6:
            fail += 1; print(f"  [轮{it}] offset(末尾) 应为 contentW−HALF（终点压指针）")
        # 3b 程序化滚动夹取
        if scroll_to(-5, total) < mn - 1e-9:
            fail += 1; print(f"  [轮{it}] 负时间未夹取到 scrollMin")
        if scroll_to(total + 100, total) > mx + 1e-9:
            fail += 1; print(f"  [轮{it}] 超界未夹取到 scrollMax")
        # 3c 橡皮筋：越界显示量受 OVER 限制且阻尼递增（tanh：等步长下增量单调递减）
        xs = [0.0, 20.0, 40.0, 60.0, 80.0, 100.0, 120.0]   # 等步长采样
        prev_os = None
        prev_inc = None
        for x in xs:
            os_ = mn - rubber(mn - x, total)    # 越界显示量
            if os_ > OVER + 1e-6:
                fail += 1; print(f"  [轮{it}] 越界显示量超过 OVER 上限")
            if prev_os is not None:
                if os_ <= prev_os + 1e-12:      # 随原始量增，显示量增
                    fail += 1; print(f"  [轮{it}] 橡皮筋显示量未随拖动量递增")
                inc = os_ - prev_os
                if prev_inc is not None and inc > prev_inc + 1e-9:
                    fail += 1; print(f"  [轮{it}] 阻尼未递增（等步长增量应变小）")
                prev_inc = inc
            prev_os = os_
        # 3d 松手回弹：release 后必在静止边界内；界内拖动不受影响
        for raw in (mn - 1000, mn - 30, mx + 1000, mx + 30, mn + 5, mx - 5):
            r = release(rubber(raw, total), total)
            if r < mn - 1e-9 or r > mx + 1e-9:
                fail += 1; print(f"  [轮{it}] 松手后越界: {r}")
        if abs(release(mn + 5, total) - (mn + 5)) > 1e-9:
            fail += 1; print(f"  [轮{it}] 界内位置松手不应移动")

        # B5 双指缩放（竞品式）：PPS 动态 + 焦点稳定 + 边界随 PPS 缩放
        for focus_x in (0.0, HALF, VIEW_W):
            for old_pps in (PPS_MIN, PPS, PPS_MAX):
                old_offset = scroll_to(rng.uniform(0, total), total)
                focus_t_before = (old_offset + focus_x) / old_pps
                target = rng.uniform(PPS_MIN, PPS_MAX)
                np, new_offset, _ = zoom_offset(old_pps, old_offset, target, focus_x, total)
                bnd_mx = max(-HALF, total * np - HALF)
                # 5a 新 offset 必须落在随 PPS 缩放的静止边界内
                if new_offset < -HALF - 1e-9 or new_offset > bnd_mx + 1e-9:
                    fail += 1; print(f"  [轮{it}] 缩放后 offset 越界: {new_offset} ∉ [−{HALF},{bnd_mx}]")
                # 未夹取的「理想」焦点位置；若它越界则内容被边界夹住，焦点漂移属不可避免
                unc = focus_t_before * np - focus_x
                if -HALF - 1e-9 <= unc <= bnd_mx + 1e-9:
                    # 5b 未夹取 → 焦点 trackT 必须严格稳定（同屏位对应同一时刻）
                    focus_t_after = (new_offset + focus_x) / np
                    if abs(focus_t_after - focus_t_before) > 1e-6:
                        fail += 1; print(f"  [轮{it}] 未夹取却焦点漂移: {focus_t_before}→{focus_t_after}")
                else:
                    # 5b' 已夹取 → 新 offset 必须等于最近边界（不漂移出界）
                    want = -HALF if unc < -HALF else bnd_mx
                    if abs(new_offset - want) > 1e-9:
                        fail += 1; print(f"  [轮{it}] 夹取边界错: {new_offset} ≠ {want}")
                # 5c 组合缩放（先 target 再 old_pps，同焦点）：两步都不夹取时焦点必须回退
                np2, off2, _ = zoom_offset(np, new_offset, old_pps, focus_x, total)
                unc2 = focus_t_before * old_pps - focus_x
                bnd2 = max(-HALF, total * old_pps - HALF)
                if (-HALF - 1e-9 <= unc <= bnd_mx + 1e-9) and (-HALF - 1e-9 <= unc2 <= bnd2 + 1e-9):
                    if abs((off2 + focus_x) / np2 - focus_t_before) > 1e-6:
                        fail += 1; print(f"  [轮{it}] 组合缩放焦点不回退")

    if fail == 0:
        print(f"  {iters} 轮全部通过 ✓（状态机 / 边界重绘 / 竞品式滚动边界+橡皮筋回弹 / 键组 / 双指缩放焦点稳定）")
    else:
        print(f"  ❌ 失败 {fail}/{iters} 轮")
    return fail


if __name__ == "__main__":
    print("=== 第一批底栏骨架逻辑验证（竞品式滚动边界版）===")
    fail = fuzz(iters=5000, seed=12345)
    if fail == 0:
        print("结论：底栏骨架可验证逻辑全绿，可抄进 Swift（currentBarTrack / autoFrameMain / 滚动边界[−HALF, contentW−HALF] / 橡皮筋回弹 / 双指缩放 PPS 动态+焦点稳定）。")
    else:
        print("结论：存在违规，先修逻辑再抄 Swift。")
        raise SystemExit(1)
