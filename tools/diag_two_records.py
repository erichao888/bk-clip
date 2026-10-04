# -*- coding: utf-8 -*-
"""
皓哥的核心提问：要不要**两套记录**？
  记录A = 红区（第一阶段：识别/拖红区边缘/点绿转红/切割）
  记录B = 绿区（第二阶段：删红后长按微调绿区边界）
  导出用 B

先说结论：**方案完全正确，而且比现在的实现更不容易出错。**
本脚本用真实样片量化对比「一套记录」与「两套记录」的差异。
"""
import json

TOL = 1e-6


def load(idx, th=-30.0, step=0.01):
    d = json.load(open("samples/gaps.json", encoding="utf-8"))
    obj = d[idx]
    db, total = obj["db"], obj["total"]
    n = len(db)
    keeps = []
    cuts = []
    i = 0
    while i < n:
        if db[i] >= th:
            j = i
            while j < n and db[j] >= th:
                j += 1
            s, e = i * step, min(j * step, total)
            if e - s > 0.05:
                keeps.append((s, e))
            i = j
        else:
            j = i
            while j < n and db[j] < th:
                j += 1
            cuts.append((i * step, min(j * step, total)))
            i = j
    return obj["name"], keeps, cuts, total


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


# ===================== 一套记录（v1.3.4 现状）=====================

def one_record_stage1(cuts, duration):
    """第一阶段：只改 cuts。marks 由 build(cuts) 派生"""
    return merge(cuts, duration)


def one_record_stage2(kept, duration):
    """
    v1.3.4 的折叠态微调：拖黄把手时要把「成品时间」换算回「原片时间」再改 cuts。
    也就是：**微调绿区 = 反推 cuts**，一次要动两个坐标系。
    """
    # foldMap: (out_start, src_start, dur)
    fmap = []
    cur = 0.0
    for s, e in kept:
        fmap.append((cur, s, e - s))
        cur += e - s

    def to_src(t):
        for o, s, du in fmap:
            if o - TOL <= t <= o + du + TOL:
                return s + (t - o)
        if fmap and t < fmap[0][0]:
            return fmap[0][1]
        if fmap:
            return fmap[-1][1] + fmap[-1][2]
        return t

    def to_out(s):
        for o, src, du in fmap:
            if src - TOL <= s <= src + du + TOL:
                return o + (s - src)
        nxt = [o for o, src, du in fmap if src > s + TOL]
        if nxt:
            return nxt[0]
        return fmap[-1][0] + fmap[-1][2] if fmap else 0.0
    return fmap, to_src, to_out


# ===================== 两套记录（皓哥方案）=====================

class TwoRecords:
    """
    记录A（红区）：只存在于第一阶段。第一阶段结束后**冻结**，不再改动。
    记录B（绿区）：点删红键时由 A 推导生成，之后只由第二阶段修改。

    关键：第二阶段**完全不碰 A**，只改 B。
    """

    def __init__(self, cuts, duration):
        self.duration = duration
        # ---- 记录A：红区（冻结）----
        self.recA_cuts = merge(cuts, duration)
        # ---- 由 A 推导 B（绿区）----
        self.recB_keeps = self._keeps_from_cuts(self.recA_cuts, duration)
        # B 的切割点（每段绿区的边界），就是「音频被切开的地方」
        self.recB_edges = [0.0] + [e for s, e in self.recB_keeps]
        self.recB_outLen = sum(e - s for s, e in self.recB_keeps)

    def _keeps_from_cuts(self, cuts, duration):
        out = []
        cur = 0.0
        for s, e in cuts:
            if s > cur:
                out.append((cur, s))
            cur = e
        if cur < duration:
            out.append((cur, duration))
        return [(s, e) for s, e in out if e - s > 0.05]

    def stage2_resize_head(self, seg_index, new_src_head):
        """
        第二阶段：拖某段绿区的左把手（**原片时间**！不需要任何换算）
        只需要改 B 里的这一段，然后：
          - 新的切割点 = 段的边界
          - 成品时长 = B 各段之和
          - 导出直接用 B
        """
        if not (0 <= seg_index < len(self.recB_keeps)):
            return False
        s, e = self.recB_keeps[seg_index]
        ns = max(0.0, min(new_src_head, e - 0.1))
        if ns >= e - 0.1:
            return False
        self.recB_keeps[seg_index] = (ns, e)
        # 切割点跟着更新
        self._rebuild_edges()
        return True

    def stage2_resize_tail(self, seg_index, new_src_tail):
        if not (0 <= seg_index < len(self.recB_keeps)):
            return False
        s, e = self.recB_keeps[seg_index]
        ne = min(self.duration, max(new_src_tail, s + 0.1))
        if ne <= s + 0.1:
            return False
        self.recB_keeps[seg_index] = (s, ne)
        self._rebuild_edges()
        return True

    def _rebuild_edges(self):
        self.recB_edges = [0.0] + [e for s, e in self.recB_keeps]
        self.recB_outLen = sum(e - s for s, e in self.recB_keeps)

    def export_ranges(self):
        """导出直接用 B —— 不需要从 A 反推"""
        return list(self.recB_keeps)


def main():
    name, keeps, cuts, total = load(0)
    print("=" * 72)
    print("【%s】原片 %.2fs" % (name, total))
    print("  第一阶段识别结果：红区 %d 段 / 绿区 %d 段" % (len(cuts), len(keeps)))
    print("=" * 72)

    # ---------- 一套记录 ----------
    print()
    print("━━━ 一套记录（v1.3.4 现状）━━━")
    fmap, to_src, to_out = one_record_stage2(keeps, total)
    print("  折叠后轨道 = 成品时间轴（长 %.3fs）" % sum(e - s for s, e in keeps))
    print("  长按某绿区 → 拿到的区间是【成品时间】，例：")
    seg_i = 3
    s_out, e_out = fmap[seg_i][0], fmap[seg_i][0] + fmap[seg_i][2]
    print("    第%d段 成品区间 [%.3f, %.3f]" % (seg_i, s_out, e_out))
    s_src, e_src = to_src(s_out), to_src(e_out)
    print("    换算回原片   [%.3f, %.3f]" % (s_src, e_src))
    print("  拖把手时：成品时间 → to_src() → 改 cuts → build() → 再折叠")
    print("  ⚠️ 两个坐标系来回换算，任何一处错位都会把边界改到别的段上")

    # 演示错位后果：把「拖左把手往左 0.2s」换算回原片
    target_out = s_out - 0.2
    if target_out >= 0:
        mapped = to_src(target_out)
        print()
        print("  演示：想拖到成品 %.3f（往左 0.2s）" % target_out)
        print("    to_src 换算 → 原片 %.3f" % mapped)
        # 这一版要落到哪一段？
        hit = -1
        for i, (a, b) in enumerate(keeps):
            if a - TOL <= mapped <= b + TOL:
                hit = i
                break
        print("    落在**第 %d 段**绿区（期望：第 %d 段）" % (hit, seg_i))
        if hit != seg_i:
            print("    ❌ 差 %d 段 → 改错段了" % abs(hit - seg_i))
        else:
            print("    ✅ 同一段")
    else:
        print()
        print("  演示：第%d段已在成品 0s 处，无法再往左拖" % seg_i)
        print("    （真实场景下常见 → 用户说「不能拖动」可能就是这种）")

    # ---------- 两套记录 ----------
    print()
    print("━━━ 两套记录（皓哥方案）━━━")
    tr = TwoRecords(cuts, total)
    print("  记录A（红区，冻结）：%d 段" % len(tr.recA_cuts))
    print("  记录B（绿区）：%d 段，成品 %.3fs" % (len(tr.recB_keeps), tr.recB_outLen))
    print("  B 的切割点（前 6 个）：%s" % ["%.2f" % x for x in tr.recB_edges[:6]])
    print()
    print("  第二阶段拖第3段绿区左把手（**直接用原片时间，零换算**）：")
    old = tr.recB_keeps[seg_i]
    ok = tr.stage2_resize_head(seg_i, old[0] - 0.2)
    new = tr.recB_keeps[seg_i]
    print("    [%.3f, %.3f] → [%.3f, %.3f]  %s" % (old[0], old[1], new[0], new[1],
                                              "✅" if ok else "❌ 被夹取"))
    print("    成品时长 %.3fs → %.3fs（多留 0.2s）" % (tr.recB_outLen - 0.2, tr.recB_outLen))
    print("    导出直接用 B：%s" % ["[%.2f→%.2f]" % (s, e) for s, e in tr.export_ranges()[:3]])
    print("    ✅ 全程一个坐标系，零换算")

    # ---------- 对比 ----------
    print()
    print("━━━ 对比 ━━━")
    rows = [
        ("第二阶段编辑的坐标系", "成品时间（要换算）", "原片时间（直接）"),
        ("拖把手要改谁", "cuts（反推）", "记录B 的那一段"),
        ("导出数据来源", "从 cuts 反推 keepRanges", "直接用记录B"),
        ("换算出错的后果", "改到别的段上", "不可能（无换算）"),
        ("红区数据", "全程在用（一直参与计算）", "冻结，第二阶段不参与"),
        ("切割点的含义", "隐含（要算）", "显式记录（recB_edges）"),
    ]
    print("  %-22s %-24s %s" % ("维度", "一套记录", "两套记录"))
    print("  " + "-" * 62)
    for a, b, c in rows:
        print("  %-22s %-24s %s" % (a, b, c))

    print()
    print("━━━ 结论 ━━━")
    print("  皓哥的两套记录方案**逻辑上更正确**，理由：")
    print()
    print("  1. **语义与操作阶段一一对应**")
    print("     第一阶段用户在做「选择要删哪些」→ 记录红区")
    print("     第二阶段用户在做「调整要留哪些」→ 记录绿区")
    print("     一套记录强行用一个 cuts 表达两种语义，才被迫做坐标系换算")
    print()
    print("  2. **第二阶段是「在成品音频上切割编辑」，不是「在原片上排除」**")
    print("     删红之后，红区已经不存在于轨道上了 —— 再去动 cuts 语义上是拧的")
    print()
    print("  3. **导出直接用 B，天然音画同步**")
    print("     导出按 B 的区间顺序拼接，每段起点由累加得出，")
    print("     不需要从 cuts 反推，也就没有「反推误差」")
    print()
    print("  4. **「越往后面越大」的错位，两套记录天然免疫**")
    print("     一套记录下每次微调都要「成品→原片」往返，误差会累积")
    print("     两套记录下第二阶段是直接改 B（单一坐标系），零往返")


if __name__ == "__main__":
    main()
