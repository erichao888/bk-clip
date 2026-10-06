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

★ 已拍板的 5 项决策（规格补充B §5 + 重排待确认项）：
  ① 音频保持音高 ② 拆 srcDuration/timelineDuration ③ 支持混合倍速
  ④ 先折叠再变速 ⑤ out == trackT（两轴合一，speed 同时压缩两者）

★ 叠加 clip（录音/画中画）存储决策（皓哥 2026-10-06 拍板）：
  存 { anchorBlockID, inBlockStart, inBlockEnd }，单位是「该块的 out/时间线坐标」。
  - 重排跟随：靠 resolve_clip 按 anchor 实时解析，无需手动平移（删 shiftOverlays）。
  - 变速不缩放（决策③）：块内坐标不变 → 绝对时长不变。
  - 切割块：压在旧块上的 clip 按切点劈到左右两块（剪映式）。

★ 本批核心收敛：未波剪（kept 单段）与已波剪（多段）是同一结构的两种取值，
  混排 fuzz，验证「两种情况分别对待」不会出错。
  缩放（PPS）是纯视图变换，不进本模型（见 verify_bottombar.py B5）。
"""

import random

EPS = 1e-9
TOL = 1e-6          # 浮点累积容差
MIN_LEN = 1e-6      # 零宽判定


_next_id = [0]


def new_id():
    _next_id[0] += 1
    return _next_id[0]


class Block:
    """主轨上的一个片段。未波剪 = kept 单段；已波剪 = kept 多段。"""

    __slots__ = ("bid", "src_duration", "kept", "speed")

    def __init__(self, src_duration, kept, speed=1.0, bid=None):
        self.bid = bid if bid is not None else new_id()
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


# ---------------------------------------------------------------- 叠加 clip

class Clip:
    """叠加轨上的一段（录音 / 画中画）。
    锚定 { 块ID, 块内 out/时间线起点, 块内 out/时间线终点 }。"""

    __slots__ = ("anchor_id", "in_block_start", "in_block_end")

    def __init__(self, anchor_id, in_block_start, in_block_end):
        self.anchor_id = anchor_id
        self.in_block_start = float(in_block_start)
        self.in_block_end = float(in_block_end)


def resolve_clip(blocks, clip):
    """把 clip 解析成绝对输出时间区间 (outStart, outEnd)；锚块不存在返回 None。
    ★ 跟随内容的核心：实时读 blocks 的当前排列与时长。"""
    for idx, b in enumerate(blocks):
        if b.bid == clip.anchor_id:
            starts, _ = prefix(blocks)
            base = starts[idx]
            tl = b.timeline_duration
            s = min(max(clip.in_block_start, 0.0), tl)
            e = min(max(clip.in_block_end, s), tl)
            return (base + s, base + e)
    return None


# ---------------------------------------------------------------- 编辑操作

def op_cut(blocks, clips, t):
    """在 trackT=t 处切割。返回 True/False（False = 落在绿区边界，不切）。
    ★ 压在旧块上的 clip 按 localCut 劈到左右两块。"""
    if not blocks:
        return False
    starts, _ = prefix(blocks)
    i, src = track_to_src(blocks, t)
    old_start = starts[i]
    local_cut = t - old_start
    b = blocks[i]
    for j, (a, bb) in enumerate(b.kept):
        if a + EPS < src < bb - EPS:            # 严格内部才切，保证两半都非零宽
            left = Block(b.src_duration, b.kept[:j] + [(a, src)], b.speed, bid=new_id())
            right = Block(b.src_duration, [(src, bb)] + b.kept[j + 1:], b.speed, bid=new_id())
            if left.base_duration <= MIN_LEN or right.base_duration <= MIN_LEN:
                return False
            old_id = b.bid
            left_dur = left.timeline_duration
            blocks[i:i + 1] = [left, right]

            new_clips = []
            for c in clips:
                if c.anchor_id == old_id:
                    # 左块部分
                    le = min(c.in_block_end, left_dur)
                    if le - c.in_block_start > MIN_LEN:
                        new_clips.append(Clip(left.bid, c.in_block_start, le))
                    # 右块部分（坐标相对右块起点 = 旧起点 + left_dur）
                    rs = max(c.in_block_start, local_cut) - left_dur
                    re = c.in_block_end - left_dur
                    if re - rs > MIN_LEN:
                        new_clips.append(Clip(right.bid, rs, re))
                else:
                    new_clips.append(c)
            clips[:] = normalize_overlays(blocks, new_clips)
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
    """变速：仅改 speed。clip 跟随由 resolve_clip 负责，无需手动平移。"""
    blocks[i].speed = sp


def op_move(blocks, from_idx, to_idx):
    """主轨拖动重排。clip 按 anchor 实时解析 → 自动跟着原块走。"""
    if from_idx == to_idx:
        return False
    b = blocks.pop(from_idx)
    to_idx = max(0, min(to_idx, len(blocks)))
    blocks.insert(to_idx, b)
    return True


def op_fold_change(blocks, i, new_kept):
    """模拟「进波剪页改了绿区」→ 块 i 的 keptRanges 变化。
    clip 跟随/夹回由 normalize_overlays 负责。"""
    blocks[i].kept = [(float(a), float(bb)) for a, bb in new_kept]


def normalize_overlays(blocks, clips):
    """丢弃锚块已不存在的 clip（孤儿）；把块内坐标夹回 [0, 该块 timelineDuration]。
    ★ 不做任何平移/挤压，跟随由 resolve_clip 负责。"""
    ids = {b.bid for b in blocks}
    out = []
    for c in clips:
        if c.anchor_id not in ids:
            continue
        tl = next(b.timeline_duration for b in blocks if b.bid == c.anchor_id)
        s = min(max(c.in_block_start, 0.0), tl)
        e = min(max(c.in_block_end, s), tl)
        if e - s > MIN_LEN:
            out.append(Clip(c.anchor_id, s, e))
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

        # I5/I6/I7 采样
        prev_src = None
        for f in (0.11, 0.29, 0.47, 0.63, 0.79, 0.93):
            t = starts[i] + f * b.timeline_duration
            j, src = track_to_src(blocks, t)
            if j != i:
                bad.append("I5 块%d 采样 f=%s 落到块%d" % (i, f, j))
                continue
            if not any(a - TOL <= src <= bb + TOL for a, bb in b.kept):
                bad.append("I5 块%d src=%.6f 不在绿区内" % (i, src))
            t2 = src_to_track(blocks, i, src)
            if abs(t2 - t) > 1e-4:
                bad.append("I6 块%d 往返漂移 %.6f→%.6f" % (i, t, t2))
            if prev_src is not None and src < prev_src - 1e-6:
                bad.append("I7 块%d src 非单调 %.6f<%.6f" % (i, src, prev_src))
            prev_src = src

    # I11 / I12 叠加 clip（锚定模型）
    if clips is not None:
        ids = {b.bid for b in blocks}
        for k, c in enumerate(clips):
            if c.anchor_id not in ids:
                bad.append("I11 clip%d 锚块不存在" % k)
                continue
            tl = next(b.timeline_duration for b in blocks if b.bid == c.anchor_id)
            if c.in_block_start < -TOL or c.in_block_end > tl + TOL:
                bad.append("I11 clip%d 块内越界" % k)
            if c.in_block_end - c.in_block_start <= EPS:
                bad.append("I11 clip%d 零宽" % k)
            # 跟随：解析出的绝对区间必须落在该块 out 区间内且越出 TOTAL
            res = resolve_clip(blocks, c)
            if res is None:
                bad.append("I11 clip%d 解析失败" % k)
            else:
                os_, oe_ = res
                idx = next(j for j, b in enumerate(blocks) if b.bid == c.anchor_id)
                base = starts[idx]
                if os_ < base - TOL or oe_ > base + tl + TOL:
                    bad.append("I11 clip%d 解析越出锚块 out 区间" % k)
                if os_ < -TOL or oe_ > total + TOL:
                    bad.append("I11 clip%d 越出 TOTAL" % k)
                # ★ I12 不缩放：绝对时长 == 块内时长（构造上恒等，这里只兜底）
                if abs((oe_ - os_) - (c.in_block_end - c.in_block_start)) > TOL:
                    bad.append("I12 clip%d 时长不一致" % k)

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


def random_clips(rng, blocks):
    """在块上随机生成若干锚定 clip（块内 out 坐标）。"""
    clips = []
    for _ in range(rng.randint(0, 3)):
        b = rng.choice(blocks)
        tl = b.timeline_duration
        if tl <= 0.4:
            continue
        s = rng.uniform(0.0, tl * 0.7)
        e = min(rng.uniform(s + 0.4, s + 4.0), tl)
        if e - s <= MIN_LEN:
            continue
        clips.append(Clip(b.bid, s, e))
    return clips


# ---------------------------------------------------------------- 模糊测试

def fuzz(iters=5000, seed=20261005):
    rng = random.Random(seed)
    fail = 0
    stats = {"cut": 0, "insert": 0, "replace_ok": 0, "replace_no": 0,
             "speed": 0, "move": 0, "fold": 0}

    for it in range(iters):
        blocks = [random_block(rng) for _ in range(rng.randint(1, 4))]
        clips = random_clips(rng, blocks)

        bad = check(blocks, clips)
        if bad:
            fail += 1
            print("  [轮%d] 初始构造违规: %s" % (it, bad[:2]))
            continue

        for _step in range(rng.randint(1, 5)):
            op = rng.choice(["cut", "insert", "replace", "speed", "move", "fold"])
            _, total = prefix(blocks)

            # ★ 快照 clip 的锚与块内时长，用于验证「跟随 + 不缩放」
            snap = {id(c): (c.anchor_id, c.in_block_end - c.in_block_start)
                    for c in clips}

            if op == "cut":
                op_cut(blocks, clips, rng.uniform(0.0, total))
                stats["cut"] += 1

            elif op == "insert":
                op_insert(blocks, rng.randint(0, len(blocks)), random_block(rng))
                clips[:] = normalize_overlays(blocks, clips)
                stats["insert"] += 1

            elif op == "replace":
                i = rng.randrange(len(blocks))
                before_tl = blocks[i].timeline_duration
                before_kept = list(blocks[i].kept)
                ok, locked = op_replace(blocks, i, rng.uniform(1.0, 120.0))
                if ok:
                    stats["replace_ok"] += 1
                    if len(blocks[i].kept) != 1:
                        fail += 1
                        print("  [轮%d] I8 替换后非单段" % it)
                    if abs(blocks[i].timeline_duration - locked) > TOL:
                        fail += 1
                        print("  [轮%d] I8 替换后时长漂移" % it)
                else:
                    stats["replace_no"] += 1
                    if (abs(blocks[i].timeline_duration - before_tl) > TOL
                            or blocks[i].kept != before_kept):
                        fail += 1
                        print("  [轮%d] I8 拒绝替换却改了模型" % it)
                clips[:] = normalize_overlays(blocks, clips)

            elif op == "move":
                if len(blocks) >= 2:
                    op_move(blocks, rng.randrange(len(blocks)), rng.randrange(len(blocks)))
                    stats["move"] += 1
                    clips[:] = normalize_overlays(blocks, clips)

            elif op == "fold":
                i = rng.randrange(len(blocks))
                op_fold_change(blocks, i, random_kept(rng, blocks[i].src_duration))
                stats["fold"] += 1
                clips[:] = normalize_overlays(blocks, clips)

            else:  # speed
                i = rng.randrange(len(blocks))
                op_speed(blocks, i, rng.uniform(0.1, 4.0))
                stats["speed"] += 1
                clips[:] = normalize_overlays(blocks, clips)

            # ★ I12 跟随 + 不缩放：存活的 clip 锚不变；未被夹回的块内时长不变
            for c in clips:
                if id(c) in snap:
                    old_anchor, old_dur = snap[id(c)]
                    if c.anchor_id != old_anchor:
                        fail += 1
                        print("  [轮%d] I12 重排/变速后锚块变了" % it)
                        break
                    # 若该 clip 没被夹回（仍在块内），绝对时长必须不变（不缩放）
                    tl = next(b.timeline_duration for b in blocks if b.bid == c.anchor_id)
                    if c.in_block_end <= tl + TOL:
                        if abs((c.in_block_end - c.in_block_start) - old_dur) > TOL:
                            fail += 1
                            print("  [轮%d] I12 不缩放被破坏 dur %.6f→%.6f"
                                  % (it, old_dur, c.in_block_end - c.in_block_start))
                            break

            bad = check(blocks, clips)
            if bad:
                fail += 1
                print("  [轮%d] 操作 %s 后违规: %s" % (it, op, bad[:2]))
                break

    print("  操作统计：" + " / ".join("%s=%d" % kv for kv in sorted(stats.items())))
    if fail == 0:
        print("  %d 轮全部通过 ✓（I1 无缝 / I2 无零宽 / I3 绿区合法 / I4 派生一致 / "
              "I5 落绿区 / I6 往返 / I7 单调 / I8 替换对账 / I9 变速 / "
              "I11 锚块存在·块内合法 / I12 重排跟随+变速不缩放）" % iters)
    else:
        print("  ❌ 失败 %d 轮" % fail)
    return fail


if __name__ == "__main__":
    print("=== v2.0 数据模型验证（多片段主轨 · 折叠 · 变速坐标 · 锚定式叠加 clip）===")
    fail = fuzz(iters=5000, seed=20261005)
    if fail == 0:
        print("结论：数据模型可验证逻辑全绿，可抄进 Swift"
              "（BKClipBlock / foldMap 两级映射 / 先折叠再变速 / 替换 crop-to-lock / "
              "clip 锚定块+块内偏移·重排自动跟随·变速不缩放）。")
    else:
        print("结论：存在违规，先修模型再抄 Swift。")
        raise SystemExit(1)
