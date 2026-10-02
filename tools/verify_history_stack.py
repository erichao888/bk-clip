#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
验证 BKHistory（撤销 / 重做栈）的纯逻辑。

【为什么要先写这个】
本机没有 Swift 编译器，UIKit 代码只能靠 CI 报错对齐；但撤销栈是**纯逻辑**，
完全可以先在 Python 里复刻一遍，用随机用例把不变量跑穿，再照抄进 Swift。
这条纪律在 BKTimeline.merge 上已经抓到过真 bug（重叠区间漏缝），别跳过。

【要验证的不变量】
  I1  任何时刻 index 都在 [0, len(items)-1]（items 永不为空白栈）
  I2  current 永远等于 items[index]，且非 None
  I3  undo 一步之后，current 必须等于上一步 undo 之前的那个状态（严格回退）
  I4  连续 undo 到头，current 必须等于最初 reset 进去的那个状态
  I5  redo 与 undo 严格互逆
  I6  undo 之后再来一次新 push，redo 分支必须被砍掉（不能出现分叉幽灵）
  I7  items 长度永不超过 limit
  I8  拖动合并（amend）只改最后一条，不新增条目；且 amend 前必须已经 push 过
      —— 否则第一次拖就会把「拖动前的原状态」覆盖掉，撤不回去
"""

import random

LIMIT = 60


class History:
    """Swift 侧 BKHistory 的逐行复刻"""

    def __init__(self):
        self.items = []
        self.index = -1

    # --- 查询 ---
    @property
    def can_undo(self):
        return self.index > 0

    @property
    def can_redo(self):
        return 0 <= self.index < len(self.items) - 1

    @property
    def current(self):
        if 0 <= self.index < len(self.items):
            return self.items[self.index]
        return None

    # --- 变更 ---
    def reset(self, p):
        self.items = [p]
        self.index = 0

    def push(self, p):
        if self.index < len(self.items) - 1:
            del self.items[self.index + 1:]
        self.items.append(p)
        self.index = len(self.items) - 1
        if len(self.items) > LIMIT:
            drop = len(self.items) - LIMIT
            del self.items[:drop]
            self.index = len(self.items) - 1

    def amend(self, p):
        # 空栈时退化成 push —— Swift 侧同样处理，避免 index 越界
        if self.index < 0:
            self.push(p)
            return
        self.items[self.index] = p

    def undo(self):
        if not self.can_undo:
            return None
        self.index -= 1
        return self.items[self.index]

    def redo(self):
        if not self.can_redo:
            return None
        self.index += 1
        return self.items[self.index]


def invariants(h, tag):
    assert len(h.items) > 0, f"{tag}: 栈不该为空"
    assert 0 <= h.index < len(h.items), f"{tag}: index 越界 {h.index}/{len(h.items)}"
    assert h.current == h.items[h.index], f"{tag}: current 与 index 不一致"
    assert len(h.items) <= LIMIT, f"{tag}: 超过容量上限 {len(h.items)}"


def check_basic():
    """手写用例：最典型的五步，逐条对着人脑预期验"""
    h = History()
    h.reset("S0")
    assert not h.can_undo and not h.can_redo
    assert h.current == "S0"

    h.push("S1")
    h.push("S2")
    assert h.can_undo and not h.can_redo
    assert h.undo() == "S1"          # I3
    assert h.can_redo
    assert h.redo() == "S2"          # I5
    assert h.undo() == "S1"
    assert h.undo() == "S0"          # I4
    assert not h.can_undo
    assert h.undo() is None          # 到底了，返回 nil 而不是崩

    # I6：undo 之后 push，redo 分支必须没了
    h.push("S3")
    assert not h.can_redo
    assert h.items == ["S0", "S3"]
    assert h.current == "S3"

    # I8：拖动合并
    h.push("D1")          # 拖动第一帧 → 新状态入栈
    n = len(h.items)
    h.amend("D2")         # 后续帧 → 只改最后一条
    h.amend("D3")
    assert len(h.items) == n, "amend 不该新增条目"
    assert h.current == "D3"
    assert h.undo() == "S3", "一次撤销应该退回到拖动之前，而不是拖动中间某一帧"

    # 空栈 amend 不能崩
    e = History()
    e.amend("x")
    assert e.current == "x" and len(e.items) == 1
    print("  ✓ 手写用例通过")


def check_random(rounds=4000, seed=20261002):
    rnd = random.Random(seed)
    fails = 0
    for r in range(rounds):
        h = History()
        h.reset("s0")
        # 参考模型：一条独立的期望序列，用来交叉验证 undo/redo 的回退位置
        expect = ["s0"]
        pos = 0
        # 记录每一次 commit 之后的期望值，用于 I3/I4/I5 的核对
        for _ in range(rnd.randint(1, 40)):
            op = rnd.random()
            if op < 0.55:                      # 普通提交
                expect = expect[:pos + 1]
                expect.append(f"n{r}")
                pos = len(expect) - 1
                h.push(expect[pos])
            elif op < 0.75:                    # 拖动合并：先 push 再连续 amend
                expect = expect[:pos + 1]
                expect.append(f"d{r}")
                pos = len(expect) - 1
                h.push(expect[pos])
                for _ in range(rnd.randint(1, 6)):
                    v = f"d{r}-{rnd.random():.6f}"
                    expect[pos] = v
                    h.amend(v)
            elif op < 0.90:                    # 撤销
                # 参考模型独立判断能不能退；两边结论必须一致，这本身也是一条不变量
                if pos > 0:
                    assert h.can_undo, f"round{r}: 模型认为能退，栈说不能"
                    pos -= 1
                    got = h.undo()
                    if got != expect[pos]:
                        fails += 1
                        print(f"  ✗ undo 错位：got={got} want={expect[pos]}")
                else:
                    assert not h.can_undo, f"round{r}: 模型认为到底了，栈还说得能退"
                    assert h.undo() is None, f"round{r}: 到底了 undo 应返回 None"
            else:                              # 重做
                if pos < len(expect) - 1:
                    assert h.can_redo, f"round{r}: 模型认为能进，栈说不能"
                    pos += 1
                    got = h.redo()
                    if got != expect[pos]:
                        fails += 1
                        print(f"  ✗ redo 错位：got={got} want={expect[pos]}")
                else:
                    assert not h.can_redo, f"round{r}: 模型认为到最新了，栈还说得能进"
                    assert h.redo() is None, f"round{r}: 到最新了 redo 应返回 None"

            try:
                invariants(h, f"round{r}")
                assert h.current == expect[pos], f"round{r}: current 与期望序列不一致"
            except AssertionError as e:
                fails += 1
                print(f"  ✗ {e}")
                break

        # 一路 redo 到底，必须回到最近一次提交
        while h.can_redo:
            h.redo()
        assert h.current == expect[-1], f"round{r}: redo 到底未回到最新状态"
        # 一路 undo 到底，必须回到 s0
        while h.can_undo:
            h.undo()
        assert h.current == "s0", f"round{r}: undo 到底未回到初始状态"

    assert fails == 0, f"随机用例失败 {fails} 次"
    print(f"  ✓ 随机用例 {rounds} 组全部通过")


def check_capacity():
    """容量上限：狂推 500 条，不能爆内存表征，且撤销仍然自洽"""
    h = History()
    h.reset("s0")
    for i in range(500):
        h.push(f"x{i}")
    assert len(h.items) == LIMIT, f"容量未生效：{len(h.items)}"
    assert h.current == "x499"
    # 超容量之后最老的状态被挤掉，撤销只能回到 x(500-LIMIT+1) 附近
    depth = 0
    while h.can_undo:
        h.undo()
        depth += 1
    assert depth == LIMIT - 1, f"撤销步数异常：{depth}"
    print(f"  ✓ 容量上限 {LIMIT} 生效，超量后仍可撤销 {depth} 步")


if __name__ == "__main__":
    print("BKHistory 逻辑验证")
    check_basic()
    check_random()
    check_capacity()
    print("全部通过 ✓")
