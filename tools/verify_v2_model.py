#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bk剪辑 v2.0 · 数据模型纯逻辑验证（批 0）
（对应 docs/v2.0数据模型-多片段主轨与变速坐标.md）
================================================================================
验证的不变量（对应设计稿 §6）：

  I1  T_0 == 0 且 T_{i+1} == T_i + timelineDuration       无缝 / 无重叠
  I2  每块 timelineDuration > EPS                          无零宽块
  I3  keptRanges 升序、不重叠、0 <= a < b <= srcDuration   绿区合法
  I4  baseDuration == Σ kept 长度；timelineDuration == baseDuration/speed
  I5  trackT → src 的结果必落在某段绿区内（从不落红区）     折叠正确性
  I6  往返一致：src→trackT→src、trackT→src→trackT（ε 内）  映射可逆
  I7  块内 trackT 增大 → src 单调不减                      无时序倒挂
  I8  替换：接受后为单段且 timelineDuration == 锁定值；
           素材过短则拒绝且模型不变
  I9  变速后播放时长 == baseDuration/speed，且 I5/I6 仍成立

★ 已拍板的 5 项决策（规格补充B §5）：
  ① 音频保持音高 ② 拆 srcDuration/timelineDuration ③ 支持混合倍速
  ④ 先折叠再变速 ⑤ out == trackT（两轴合一，speed 同时压缩两者）

★ 本批核心收敛：未波剪（keptRanges 单段）与已波剪（多段）是同一结构的两种取值，
  混排 fuzz，验证「两种情况分别对待」不会出错。
  缩放（PPS）是纯视图变换，不进本模型（见 verify_bottombar.py B5）。
"""

import random

EPS = 1e-9
TOL = 1e-6          # 浮点累积容差
MIN_LEN = 1e-6      # 零宽判定


class Block:
    """主轨上的一个片段。未波剪 = kept 单段；已波剪 = kept 多段。"""

    __slots__ = ("src_duration", "kept", "speed")

    def __init__(self, src_duration, kept, speed=1.0):
        self.src_duration = float(src_duration)
        self.kept = [(float(a), float(b)) for a, b in kept]
        self.speed = float(speed)

    @property
    def base_duration(self):
        return sum(b - a for a, b in self.kept)

    @property
    def timeline_duration(self):
        return self.base_duration / self.speed


# ---------------------------------------------------------------- 坐标映射

def prefix(blocks):
    """各块在主轨上的起点前缀和 + 总长。"""
    starts = []
    acc = 0.0
    for b in blocks:
        starts.append(acc)
        acc += b.timeline_duration
    return starts, acc


def fold_index(kept, folded):
    """片段内：folded（折叠后时间）→ (段序号, 源时间)。"""
    cum = 0.0
    for j, (a, b) in enumerate(kept):
        L = b - a
        if folded <= cum + L + EPS:
            off = min(max(folded - cum, 0.0), L)
            return j, a + off
        cum += L
    j = len(kept) - 1
    return j, kept[j][1]


def track_to_src(blocks, t):
    """trackT → (块序号, 源时间)。两级：先解变速(×speed)再解折叠。"""
    assert blocks, "空时间线"
    t = max(0.0, float(t))
    acc = 0.0
    for i, b in enumerate(blocks):
        L = b.timeline_duration
        if t <= acc + L + EPS:
            local = min(max(t - acc, 0.0), L)
            folded = local * b.speed          # ★ 先折叠再变速：解变速回折叠空间
            _, src = fold_index(b.kept, folded)
            return i, src
        acc += L
    i = len(blocks) - 1
    return i, blocks[i].kept[-1][1]


def src_to_track(blocks, i, src):
    """源时间 → trackT（track_to_src 的逆）。"""
    b = blocks[i]
    starts, _ = prefix(blocks)
    cum = 0.0
    for a, bb in b.kept:
        L = bb - a
        if a - EPS <= src <= bb + EPS:
            folded = cum + (src - a)
            return starts[i] + folded / b.speed   # 折叠空间 / speed → 轨道空间
        cum += L
    return starts[i]


# ---------------------------------------------------------------- 编辑操作

def op_cut(blocks, t):
    """在 trackT=t 处切割。返回 True/False（False = 落在绿区边界，不切）。"""
    if not blocks:
        return False
    i, src = track_to_src(blocks, t)
    b = blocks[i]
    for j, (a, bb) in enumerate(b.kept):
        if a + EPS < src < bb - EPS:            # 严格内部才切，保证两半都非零宽
            left = Block(b.src_duration, b.kept[:j] + [(a, src)], b.speed)
            right = Block(b.src_duration, [(src, bb)] + b.kept[j + 1:], b.speed)
            if left.base_duration <= MIN_LEN or right.base_duration <= MIN_LEN:
                return False
            blocks[i:i + 1] = [left, right]
            return True
    return False


def op_insert(blocks, at, new_block):
    at = max(0, min(at, len(blocks)))
    blocks.insert(at, new_block)
    return True


def op_replace(blocks, i, new_src_duration):
    """替换：换进来的素材未波剪 → 裁到锁定值。
    返回 (是否接受, 锁定的 timelineDuration)。拒绝时模型必须不变。"""
    b = blocks[i]
    locked = b.timeline_duration
    need = locked * b.speed                      # = base_duration，要凑到的绿区总长
    if new_src_duration + EPS < need:
        return False, locked                     # 素材太短 → 拒绝
    b.src_duration = new_src_duration
    b.kept = [(0.0, need)]                       # 单段裁剪态（未波剪形态）
    return True, locked


def op_speed(blocks, i, sp):
    blocks[i].speed = sp


class Clip:
    """叠加轨上的一段（录音 / 画中画），锚定输出时间 = trackT。"""

    __slots__ = ("start", "end")

    def __init__(self, start, end):
        self.start = float(start)
        self.end = float(end)


def op_move(blocks, from_idx, to_idx):
    """主轨拖动重排（技术方案 §13.6 第 4 条：需要支持）。
    ⚠️ 假设（待皓哥确认）：叠加 clip 锚定输出时间，重排后 clip **留在原输出时刻**，
       不跟着内容走。超出新 TOTAL 的 clip 会被夹回 TOTAL。"""
    if from_idx == to_idx:
        return False
    b = blocks.pop(from_idx)
    to_idx = max(0, min(to_idx, len(blocks)))
    blocks.insert(to_idx, b)
    return True


def shift_clips_after(clips, boundary, delta):
    """★ 联动（技术方案 §11，默认开）：主轨某个块的时长变化 Δ 时，
    该块之后的所有叠加 clip 整体平移 Δ —— 解说是描述画面内容的，
    画面动了配音必须跟着走。"""
    for c in clips:
        if c.start >= boundary - EPS:
            c.start += delta
            c.end += delta


def op_fold_change(blocks, clips, i, new_kept):
    """模拟「进波剪页改了绿区」→ 块 i 的 baseDuration 变化 Δ，并触发联动。返回 Δ。"""
    b = blocks[i]
    starts, _ = prefix(blocks)
    old_tl = b.timeline_duration
    boundary = starts[i] + old_tl          # 块 i 的旧末端
    b.kept = [(float(a), float(bb)) for a, bb in new_kept]
    delta = b.timeline_duration - old_tl
    shift_clips_after(clips, boundary, delta)
    return delta


def clamp_clips(clips, total):
    """归一化叠加轨：排序 → 挤压保序 → 夹回 [0, TOTAL] → 丢掉零宽的。
    ★ 为什么要有「挤压」：联动平移 Δ<0（主轨变短）时，后面的 clip 往左移会
      撞上前面的 clip。同一条轨上 clip 不允许重叠，所以只能把它推到前一个的末尾之后
      （长度被压短），而不是任其交叉。"""
    ordered = sorted(clips, key=lambda c: c.start)
    out = []
    prev_end = 0.0
    for c in ordered:
        s = min(max(c.start, prev_end), total)     # 不许越过前一个的尾
        e = min(max(c.end, s), total)              # 也不许越过轨道总长
        if e - s > MIN_LEN:
            out.append(Clip(s, e))
            prev_end = e
    return out


# ---------------------------------------------------------------- 不变量校验

def check(blocks, clips=None):
    """返回违规描述列表（空 = 全绿）。clips 为叠加轨（录音/画中画）时一并校验。"""
    bad = []
    if not blocks:
        return ["空时间线"]

    starts, total = prefix(blocks)

    # I1 无缝 / 无重叠
    if abs(starts[0]) > TOL:
        bad.append("I1 首块起点非 0")
    for i in range(len(blocks) - 1):
        want = starts[i] + blocks[i].timeline_duration
        if abs(starts[i + 1] - want) > TOL:
            bad.append("I1 块%d→%d 接缝不连续" % (i, i + 1))

    for i, b in enumerate(blocks):
        # I2 无零宽
        if b.timeline_duration <= MIN_LEN:
            bad.append("I2 块%d 零宽" % i)

        # I3 绿区合法 + I4 派生一致
        base = 0.0
        prev_end = 0.0
        for (a, bb) in b.kept:
            if bb - a <= EPS:
                bad.append("I3 块%d 绿区零宽" % i)
            if a < -EPS or bb > b.src_duration + TOL:
                bad.append("I3 块%d 绿区越出源范围" % i)
            if a + EPS < prev_end:
                bad.append("I3 块%d 绿区重叠/乱序" % i)
            base += bb - a
            prev_end = bb
        if abs(base - b.base_duration) > TOL:
            bad.append("I4 块%d baseDuration 不一致" % i)
        if abs(b.timeline_duration - b.base_duration / b.speed) > TOL:
            bad.append("I4 块%d timelineDuration ≠ base/speed" % i)

        # I5/I6/I7 采样：块内取若干点，验证落绿区 + 往返 + 单调
        # ★ 只取严格内部点：f=0/f=1 是块间接缝，按定义归属前一块末尾（正确行为），
        #   拿它断言「必落在本块」会误报。接缝本身由 I1 覆盖。
        prev_src = None
        for f in (0.11, 0.29, 0.47, 0.63, 0.79, 0.93):
            t = starts[i] + f * b.timeline_duration
            j, src = track_to_src(blocks, t)
            if j != i:
                bad.append("I5 块%d 采样 f=%s 落到块%d" % (i, f, j))
                continue
            # I5 必须落在某段绿区内
            if not any(a - TOL <= src <= bb + TOL for a, bb in b.kept):
                bad.append("I5 块%d src=%.6f 不在绿区内" % (i, src))
            # I6 往返一致
            t2 = src_to_track(blocks, i, src)
            if abs(t2 - t) > 1e-4:
                bad.append("I6 块%d 往返漂移 %.6f→%.6f" % (i, t, t2))
            # I7 单调
            if prev_src is not None and src < prev_src - 1e-6:
                bad.append("I7 块%d src 非单调 %.6f<%.6f" % (i, src, prev_src))
            prev_src = src

    # I11 叠加 clip：升序、不重叠、落在 [0, TOTAL]
    if clips is not None:
        prev_end = None
        for k, c in enumerate(clips):
            if c.end - c.start <= EPS:
                bad.append("I11 clip%d 零宽" % k)
            if c.start < -TOL or c.end > total + TOL:
                bad.append("I11 clip%d 越出 TOTAL(%.3f > %.3f)" % (k, c.end, total))
            if prev_end is not None and c.start + EPS < prev_end:
                bad.append("I11 clip%d 重叠/乱序" % k)
            prev_end = c.end

    return bad


# ---------------------------------------------------------------- 随机构造

def random_kept(rng, src_duration):
    """生成「已波剪」的多段绿区（段间是红区，被折叠掉）。"""
    kept = []
    cur = 0.0
    for k in range(rng.randint(2, 4)):
        if k > 0:
            cur += rng.uniform(0.3, 3.0)        # 红区（折叠掉）
        if cur >= src_duration - 0.5:
            break
        room = src_duration - cur
        L = room * rng.uniform(0.3, 0.8)
        if L < 0.2:
            break
        kept.append((cur, cur + L))
        cur += L
    if not kept:
        kept = [(0.0, max(0.5, src_duration * 0.5))]
    return kept


def random_block(rng):
    src_duration = rng.uniform(8.0, 60.0)
    if rng.random() < 0.35:
        kept = [(0.0, src_duration)]             # 未波剪：单段整段保留
    else:
        kept = random_kept(rng, src_duration)    # 已波剪：多段绿区
    speed = 1.0
    if rng.random() < 0.4:
        speed = rng.choice([0.5, 0.75, 1.5, 2.0, 3.0])
    return Block(src_duration, kept, speed)


# ---------------------------------------------------------------- 模糊测试

def random_clips(rng, total):
    """在 [0, total] 上生成若干不重叠、升序的叠加 clip。"""
    clips = []
    cur = rng.uniform(0.0, max(0.0, total * 0.2))
    for _ in range(rng.randint(0, 3)):
        if cur >= total - 0.5:
            break
        L = min(rng.uniform(0.5, 4.0), total - cur)
        if L <= MIN_LEN:
            break
        clips.append(Clip(cur, cur + L))
        cur += L + rng.uniform(0.2, 2.0)      # clip 之间可以留空
    return clips


def fuzz(iters=5000, seed=20261005):
    rng = random.Random(seed)
    fail = 0
    stats = {"cut": 0, "insert": 0, "replace_ok": 0, "replace_no": 0, "speed": 0,
             "move": 0, "fold": 0}

    for it in range(iters):
        blocks = [random_block(rng) for _ in range(rng.randint(1, 4))]
        _, total = prefix(blocks)
        clips = random_clips(rng, total)

        bad = check(blocks, clips)
        if bad:
            fail += 1
            print("  [轮%d] 初始构造违规: %s" % (it, bad[:2]))
            continue

        for _step in range(rng.randint(1, 5)):
            op = rng.choice(["cut", "insert", "replace", "speed", "move", "fold"])
            _, total = prefix(blocks)

            if op == "cut":
                op_cut(blocks, rng.uniform(0.0, total))
                stats["cut"] += 1

            elif op == "insert":
                op_insert(blocks, rng.randint(0, len(blocks)), random_block(rng))
                stats["insert"] += 1

            elif op == "replace":
                i = rng.randrange(len(blocks))
                before_tl = blocks[i].timeline_duration
                before_kept = list(blocks[i].kept)
                ok, locked = op_replace(blocks, i, rng.uniform(1.0, 120.0))
                if ok:
                    stats["replace_ok"] += 1
                    # I8 接受后：单段 且 时长 == 锁定值
                    if len(blocks[i].kept) != 1:
                        fail += 1
                        print("  [轮%d] I8 替换后非单段" % it)
                    if abs(blocks[i].timeline_duration - locked) > TOL:
                        fail += 1
                        print("  [轮%d] I8 替换后时长漂移 %.6f→%.6f"
                              % (it, locked, blocks[i].timeline_duration))
                else:
                    stats["replace_no"] += 1
                    # I8 拒绝后：模型必须原样不动
                    if (abs(blocks[i].timeline_duration - before_tl) > TOL
                            or blocks[i].kept != before_kept):
                        fail += 1
                        print("  [轮%d] I8 拒绝替换却改了模型" % it)

            elif op == "move":
                if len(blocks) >= 2:
                    op_move(blocks, rng.randrange(len(blocks)), rng.randrange(len(blocks)))
                    stats["move"] += 1
                    _, t2 = prefix(blocks)
                    clips[:] = clamp_clips(clips, t2)

            elif op == "fold":
                i = rng.randrange(len(blocks))
                starts_i, _ = prefix(blocks)
                boundary = starts_i[i] + blocks[i].timeline_duration
                before = [(c.start, c.end) for c in clips]
                new_kept = random_kept(rng, blocks[i].src_duration)
                delta = op_fold_change(blocks, clips, i, new_kept)
                stats["fold"] += 1
                # I12 联动：块 i 之后的 clip 平移 Δ（若会撞上前一个则被挤压到更靠后，
                # 因此断言「不小于 Δ 平移后的位置」，见 clamp_clips 的说明）
                for k, (s, _e) in enumerate(before):
                    if s >= boundary - EPS:
                        if clips[k].start < s + delta - TOL:
                            fail += 1
                            print("  [轮%d] I12 联动未平移 Δ=%.4f" % (it, delta))
                            break
                _, t2 = prefix(blocks)
                clips[:] = clamp_clips(clips, t2)

            else:  # speed
                # 变速也会让块时长变化 → 同样要触发联动（否则 clip 会被落在轨道外）
                i = rng.randrange(len(blocks))
                starts_i, _ = prefix(blocks)
                boundary = starts_i[i] + blocks[i].timeline_duration
                before = [(c.start, c.end) for c in clips]
                op_speed(blocks, i, rng.uniform(0.1, 4.0))
                delta = blocks[i].timeline_duration - (boundary - starts_i[i])
                shift_clips_after(clips, boundary, delta)
                stats["speed"] += 1
                for k, (s, _e) in enumerate(before):
                    if s >= boundary - EPS:
                        if clips[k].start < s + delta - TOL:
                            fail += 1
                            print("  [轮%d] I12 变速后联动未平移" % it)
                            break
                _, t2 = prefix(blocks)
                clips[:] = clamp_clips(clips, t2)

            bad = check(blocks, clips)
            if bad:
                fail += 1
                print("  [轮%d] 操作 %s 后违规: %s" % (it, op, bad[:2]))
                break

    print("  操作统计：" + " / ".join("%s=%d" % kv for kv in sorted(stats.items())))
    if fail == 0:
        print("  %d 轮全部通过 ✓（I1 无缝 / I2 无零宽 / I3 绿区合法 / I4 派生一致 / "
              "I5 落绿区 / I6 往返 / I7 单调 / I8 替换对账 / I9 变速）" % iters)
    else:
        print("  ❌ 失败 %d 轮" % fail)
    return fail


if __name__ == "__main__":
    print("=== v2.0 数据模型验证（多片段主轨 · 折叠 · 变速坐标）===")
    fail = fuzz(iters=5000, seed=20261005)
    if fail == 0:
        print("结论：数据模型可验证逻辑全绿，可抄进 Swift"
              "（BKClipBlock / foldMap 两级映射 / 先折叠再变速 / 替换 crop-to-lock）。")
    else:
        print("结论：存在违规，先修模型再抄 Swift。")
        raise SystemExit(1)
