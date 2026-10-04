# -*- coding: utf-8 -*-
"""
复刻 BKJointBuilder.startKeptTime 的错误行为，对比皓哥要的正确逻辑。

现有代码（v1.2.14）：
    for (a, b) in keeps where b > t + 0.001 {
        return max(t, a)
    }
    return nil

皓哥要的逻辑：
    指针在绿区   → 从指针处开始播
    指针在红区   → 跳到下一个绿区的开头
"""
import json


def current(t, keeps):
    """现有实现"""
    for (a, b) in keeps:
        if b > t + 0.001:
            return max(t, a)
    return None


def wanted(t, keeps):
    """皓哥要的逻辑"""
    # 1) 指针在某个绿区内 → 从指针处播
    for (a, b) in keeps:
        if a - 1e-9 <= t <= b + 1e-9:
            return t
    # 2) 落在红区 → 往后找第一个「起点大于 t」的绿区
    for (a, b) in keeps:
        if a > t + 1e-9:
            return a
    # 3) 已在末尾之后 → 播最后一个绿区的结尾
    if keeps:
        return keeps[-1][1]
    return None


def keeps_from_gaps(idx, th=-30.0, step=0.01):
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
    return obj["name"], keeps


if __name__ == "__main__":
    name, keeps = keeps_from_gaps(0)
    print(f"【{name}】共 {len(keeps)} 个绿区，前 6 个：")
    for a, b in keeps[:6]:
        print(f"   绿区 [{a:.2f} → {b:.2f}]  长度 {b-a:.2f}s")
    print()

    # 造几个有代表性的测试点
    tests = []
    # 绿区内部
    tests.append(("绿区1 内部", keeps[0][0] + (keeps[0][1] - keeps[0][0]) * 0.5))
    # 第一个红区（绿区1 和 绿区2 之间）
    mid = (keeps[0][1] + keeps[1][0]) / 2
    tests.append(("红区1（绿1与绿2之间）", mid))
    # 绿区2 内部
    tests.append(("绿区2 内部", keeps[1][0] + (keeps[1][1] - keeps[1][0]) * 0.5))
    # 最后一个红区
    if len(keeps) >= 3:
        mid2 = (keeps[-2][1] + keeps[-1][0]) / 2
        tests.append(("最后红区（绿N-1与绿N之间）", mid2))
    # 恰好在边界上
    tests.append(("绿区1 结束边界上", keeps[0][1]))
    tests.append(("绿区2 开始边界上", keeps[1][0]))
    # 开头之前 / 末尾之后
    tests.append(("时间轴最开头", 0.0))
    tests.append(("最后一个绿区之后", keeps[-1][1] + 0.5))
    # 极短绿区（刚好 < 1ms，触发 0.001 容差边界）
    tests.append(("绿区1 结束前 0.0005s", keeps[0][1] - 0.0005))

    print(f"{'测试点':<28} {'指针时间':>9} {'现有实现':>10} {'应为':>10}   判定")
    print("-" * 78)
    bad = 0
    for label, t in tests:
        c = current(t, keeps)
        w = wanted(t, keeps)
        ok = "✅" if (c is None and w is None) or (
            c is not None and w is not None and abs(c - w) < 1e-6) else "❌"
        if ok == "❌":
            bad += 1
        print(f"{label:<28} {t:>9.4f} {str(c):>10} {str(w):>10}   {ok}")
    print("-" * 78)
    print(f"错误 {bad} 处 / 共 {len(tests)} 个测试点")
