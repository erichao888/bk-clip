//
//  BKHistory.swift
//  bk剪辑 — 撤销 / 重做栈
//
//  【为什么撤销的单位是整个工程快照，而不是「操作」】
//  常见做法是记一个操作列表（addCut / moveBoundary / ...），撤销时反向执行。
//  那要求每个操作都能写出严格的逆操作 —— 而这里的编辑结果会互相吞并：
//  两个气口重叠会被 merge 成一条，再「反向」就分不回原来的两条了。
//  工程是值类型（struct），快照一份才几十 KB，直接整份换掉最省心也最不容易错。
//
//  【拖动边界为什么必须合并提交】
//  拖一次边界会触发几十次回调，每次都入栈的话，撤销一次只退回一帧 ——
//  用户拖了 2 秒的边界，得按几十下撤销才退得回去，等于撤销功能废了。
//  所以约定：**一次拖动只占一格**，第一次改动 push，之后全部 amend（改最后一格）。
//
//  【⚠️ 顺序不能反】
//  必须先 push 再 amend。直接 amend 会把「拖动前的状态」覆盖掉，
//  那一次拖动就再也撤不回来了。这条在 tools/verify_history_stack.py 里
//  被随机用例钉住过（I8），改这里之前先跑一遍那个脚本。
//
//  【本文件的逻辑与 Python 版逐行对应】
//  4000 组随机用例 + 容量边界用例全部通过后才落到 Swift。
//

import Foundation

struct BKHistory<T> {

    /// 快照栈。index 指向「当前这一格」
    private(set) var items: [T] = []
    private(set) var index: Int = -1

    /// 撤销容量。皓哥 2026-10-02 晚拍板**改掉了原来的 60**：
    /// 工程快照里含 marks，一条 42 秒素材几十刀也就几百字节，15 格足够退回去。
    /// 再深就是白占内存 —— 真要退 15 步以上，说明该重新检测了
    static let limit = BKConfig.Draft.undoLimit

    /// 重做容量**只有 1 步**。语义是：连着撤两步之后，先撤的那一步就救不回来了。
    /// 这是皓哥明确要的效果 —— 撤销能退得深，但重做只保底下那一步，
    /// 防止来来回回「撤了又做、做了又撤」把状态搅乱
    static let redoLimit = BKConfig.Draft.redoLimit

    // MARK: - 查询

    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index >= 0 && index < items.count - 1 }

    var current: T? {
        guard index >= 0, index < items.count else { return nil }
        return items[index]
    }

    var depth: Int { items.count }

    // MARK: - 变更

    /// 装进初始状态。每次打开一个素材都要调一次，旧栈整个作废
    mutating func reset(_ project: T) {
        items = [project]
        index = 0
    }

    /// 提交一个新状态。当前不在栈顶时（也就是刚撤销过），
    /// 后面那些「重做分支」会被砍掉 —— 撤销之后又改了主意，旧分支就不该再存在
    mutating func push(_ project: T) {
        if index < items.count - 1 {
            items.removeSubrange((index + 1)...)
        }
        items.append(project)
        index = items.count - 1

        if items.count > BKHistory.limit {
            let drop = items.count - BKHistory.limit
            items.removeFirst(drop)
            index = items.count - 1
        }
    }

    /// 改当前这一格，不新增。拖动边界的中间帧走这里
    mutating func amend(_ project: T) {
        // 空栈时退化成 push —— 否则 index 是 -1，直接写会越界崩
        guard index >= 0 else {
            push(project)
            return
        }
        items[index] = project
    }

    /// 撤销一次，并把「可以重做的项」裁到只剩 redoLimit 个。
    ///
    /// 为什么要在 **undo 里**裁而不是在 push 里裁：
    /// 重做栈不是另一份数组，它就是 index 右边那些还没被砍掉的格子。
    /// 撤销只把 index 往左挪，右边的格子还在那里 —— 不裁的话，
    /// 撤 15 步之后右边的「重做分支」还有 15 格，跟「重做只留 1 步」的口径对不上。
    /// 砍最右边 = 砍最早被撤下去的那个状态，留下最近撤掉的那一步给用户反悔。
    mutating func undo() -> T? {
        guard canUndo else { return nil }
        index -= 1
        while (items.count - 1 - index) > BKHistory.redoLimit {
            items.removeLast()
        }
        return items[index]
    }

    mutating func redo() -> T? {
        guard canRedo else { return nil }
        index += 1
        return items[index]
    }
}
