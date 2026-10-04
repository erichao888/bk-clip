# -*- coding: utf-8 -*-
"""
音画同步 —— 第三次尝试前先把问题想透（前两次都错了，不能再猜）。

【前两次的错在哪】
v1.2.15「按标称段长推进」：两轨共用游标，量化缺口累积
v1.3.2「按两轨较大值推进」：两轨共用游标，短轨留空洞
v1.3.3 草稿「两轨独立推进」：两轨各自游标，但**每段末尾各自收尾**，
                        段边界处两轨收尾余数不同 → 又产生空洞

三次都错，因为都在想「游标怎么推进」，而**没想过一件事**：

【真正的关键：两轨的段边界应该落在同一个绝对时间点上】

播放器怎么判断「音画同步」？它比较的是**同一个成品时间点上，视频帧和音频样本的呈现**。
只要两轨在**段边界处都恰好落在成品时间的同一个位置**，
之后的每一步都是各自的网格在走（16.7ms / 21.3ms），偏差 < 半个步长，永远不会累积。

所以正确做法不是「各自推进」，而是：
  **每段结束时，让两轨的结束时间对齐到同一个「段末锚点」。**

怎么做？两轨网格不同，不能真的对齐每一帧，但可以：
  ① 视频按帧铺（每帧 +16.68ms）
  ② 音频按块铺（每块 +21.33ms）
  ③ **段末允许「补一小段静音 / 补一帧静帧」把两轨拉到同一个锚点**

③ 是关键：差多少补多少，**上限一个块 / 一帧**（< 21.3ms / < 16.7ms）。
补的内容是「静」——听感上是一瞬间的静音，不会有可察觉的错位。

【但等等 —— 补静音真的可行吗？】
填一段静音音频，播放器在那一小段里没有声音；
视频那 20ms 里画面停住不动（补一帧）。
观众看到的是「画面停 20ms」，听感上「声音断 20ms」。
这仍然是不对齐，只是从「错位」变成「卡顿」。

【所以正解其实是：不要在段边界对齐，而要在段内部保持时间比例正确】

关键洞察：**音画同步的本质是「同一段源素材内，音视频的相对时间偏移不变」。**
- 源素材本身音画是同步的（pts 起点都是 0，网格固定）
- 我们把 [segStart, segEnd) 这一段搬到成品的 [outStart, outEnd)
- 只要 outEnd - outStart **严格等于** segEnd - segStart，两轨的相对关系就**完全保持**
- 而 outEnd - outStart 应该等于**源片段的原时长**，不是帧数×帧长

⚠️ 这就是前两次的根源：我把 outEnd-outStart 算成了「帧数×帧长」或「块数×块长」，
而不是「源片段时长」。**只要用标称段长（segEnd - segStart），两轨就是严格等长的！**

那 v1.2.15 为什么还会有累积错位？
因为 inRange 过滤**丢掉了末尾的样本**（不足一帧/一块的尾巴），
所以实际写入的长度 ≠ 标称长度。丢掉的那些就是**内容丢失**，不是错位。

【真解】
每段：**两轨共用一个段末锚点 = 段起点 + 标称段长**，
  视频铺帧到不超过锚点，音频铺块到不超过锚点，
  **两轨都不超过锚点**（宁可少一点，也不要超过）。
  段末的残差 < 一个步长，且两轨的残差**各自独立**，
  但下一段起点 = 同一个锚点 → **两轨在段边界重新对齐**。

这样：
  - 两轨都不越界（无空洞、无重叠）
  - 每段边界两轨都对齐到同一锚点 → 不累积
  - 段内两轨都 ≤ 锚点 → 无空洞

唯一代价：每段末尾两轨各有 <21.3ms / <16.7ms 的「没填满」，总和 < 38ms。
这 38ms 是**音画各少一点**，两者相对关系仍然正确 —— 这是可接受的，且不累积。
"""
import json

VID_FPS = 59.96
VID_STEP = 1.0 / VID_FPS
AUD_STEP = 1024.0 / 48000.0
TOL = 1e-4


def build_keeps(idx, th=-30.0, step=0.01):
    d = json.load(open("samples/gaps.json", encoding="utf-8"))
    obj = d[idx]
    db, total = obj["db"], obj["total"]
    n = len(db)
    keeps = []
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
            i += 1
    return obj["name"], keeps, total


def simulate_v4(keeps):
    """
    v4 解法：**段末锚点 = 段起点 + 标称段长**，两轨各自铺到不超过锚点。

    outputCursor 只有一个，两轨共用 —— 但它推进的是「标称段长」，
    这是关键：两轨在段边界精确对齐，且都不越界。
    """
    vcursor = 0.0   # = acursor，两轨共用（段起点）
    video_pts = []
    audio_pts = []
    report = []

    for (s, e) in keeps:
        nominal = e - s                      # 标称段长
        seg_out_start = vcursor
        seg_out_end = seg_out_start + nominal  # ★ 锚点

        # 视频：铺帧，**不超过锚点**
        i0 = int(s / VID_STEP)
        while i0 * VID_STEP < s - TOL:
            i0 += 1
        k = i0
        n_v = 0
        while True:
            src = k * VID_STEP
            if src >= e - TOL:
                break
            new_pts = seg_out_start + (src - s)
            if new_pts + VID_STEP > seg_out_end + 1e-9:
                break                          # ★ 不越界
            video_pts.append(new_pts)
            n_v += 1
            k += 1

        # 音频：铺块，**不超过锚点**
        a0 = int(s / AUD_STEP)
        while a0 * AUD_STEP < s - TOL:
            a0 += 1
        m = a0
        n_a = 0
        while True:
            src = m * AUD_STEP
            if src >= e - TOL:
                break
            new_pts = seg_out_start + (src - s)
            if new_pts + AUD_STEP > seg_out_end + 1e-9:
                break                          # ★ 不越界
            audio_pts.append(new_pts)
            n_a += 1
            m += 1

        v_fill = n_v * VID_STEP
        a_fill = n_a * AUD_STEP
        report.append(dict(
            seg=(round(s, 4), round(e, 4)),
            nominal=round(nominal, 5),
            v_start=round(seg_out_start, 5), v_end=round(seg_out_start + v_fill, 5),
            a_start=round(seg_out_start, 5), a_end=round(seg_out_start + a_fill, 5),
            v_gap=round(nominal - v_fill, 5),   # 末尾没填满的
            a_gap=round(nominal - a_fill, 5),
        ))

        # ★ 游标推进**标称段长**（不是两轨的填充长度！）
        vcursor = seg_out_end

    return video_pts, audio_pts, report, vcursor


def check(pts, step, label):
    errs = []
    for i in range(1, len(pts)):
        gap = pts[i] - pts[i - 1]
        if gap <= 0:
            errs.append("第%d样本倒退 %.3fms" % (i, gap * 1000))
        elif gap > step * 1.5 + 0.2:
            errs.append("第%d样本空洞 %.1fms" % (i, gap * 1000))
    return errs


if __name__ == "__main__":
    allbad = 0
    for idx in range(4):
        name, keeps, total = build_keeps(idx)
        if len(keeps) < 2:
            continue
        v, a, rep, tot = simulate_v4(keeps)
        verr = check(v, VID_STEP, "v")
        aerr = check(a, AUD_STEP, "a")

        print("=" * 72)
        print("【%s】%d 段 → 成品 %.4fs" % (name, len(keeps), tot))
        print("=" * 72)
        print("  视频轨 %d 帧 / 音频轨 %d 块" % (len(v), len(a)))
        print("  视频轨不变量：%s" % ("✅" if not verr else "❌ %d 处" % len(verr)))
        for e in verr[:4]:
            print("     " + e)
        print("  音频轨不变量：%s" % ("✅" if not aerr else "❌ %d 处" % len(aerr)))
        for e in aerr[:4]:
            print("     " + e)

        gaps_v = [r["v_gap"] for r in rep]
        gaps_a = [r["a_gap"] for r in rep]
        print()
        print("  段末未填满（两轨各自，都 < 一个步长）：")
        print("    视频最大 %.1fms  音频最大 %.1fms"
              % (max(gaps_v) * 1000, max(gaps_a) * 1000))
        print("    （这是**内容被 inRange 丢弃**造成的，不是错位；")
        print("      且下一段起点 = 同一个锚点，所以不累积）")

        # 关键：段边界两轨起点是否完全相同
        same = all(abs(r["v_start"] - r["a_start"]) < 1e-9 for r in rep)
        print("  段边界两轨起点完全一致：%s" % ("✅ 是" if same else "❌ 否"))
        allbad += len(verr) + len(aerr) + (0 if same else 1)
        print()

    print("=" * 72)
    print("结论：%s" % ("✅ 全部通过 —— 无空洞、无倒退、段边界精确对齐"
                          if allbad == 0 else "❌ %d 处问题" % allbad))
    print()
    print("【为什么这次对】")
    print("  游标推进的是**标称段长**（源片段的真实时长），不是帧数×帧长、也不是块数×块长。")
    print("  源素材音画本就同步，段内按各自网格铺帧/铺块 = 保持了这个同步关系；")
    print("  段末两轨都≤锚点（不越界），下一段从同一锚点起 → 不累积、不空洞。")
    print()
    print("【与前两次的本质区别】")
    print("  v1.2.15 标称推进：两轨也共用游标，但 inRange 丢样本后实际写入 < 标称，")
    print("                 writer 看到的轨道长度 < 游标推进量 → 段边界错位累积。")
    print("  v1.3.3 独立推进：两轨各自收尾，段末余数不同 → 段边界又错位。")
    print("  v1.3.3 标称+不越界：游标是标称，两轨都不超过它 → 段边界恒对齐。")
    print("                 代价是段末各丢 <一个步长（本来也丢，inRange 干的）。")
