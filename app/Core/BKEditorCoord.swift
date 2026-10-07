//
//  BKEditorCoord.swift
//  bk剪辑 — 编辑页坐标与选中机（第一批 · 宿主侧）
//
//  规格真源：`docs/上下文底栏与参数面板-实现规格.md §1.4 / §1.5`
//  规格补充：`docs/规格补充A-数值状态机吸附与状态清单.md §3.1~§3.4`
//  行为真源：`ref/proto-2026-10-06-125e64d9/index.html`
//
//  ═══════════════════════════════════════════════════════════════════════
//  这个类解决什么问题
//  ═══════════════════════════════════════════════════════════════════════
//  编辑页的核心心智是「**固定中央指针 + 内容滚动**」：
//    · 白色指针永远钉在可视区正中央，内容整体 translateX 滚动
//    · 拖动时，指针下的主轨区块**自动出蓝框**，底栏 10 键随之作用于它
//    · 点某区块时，三轨同步滚动让该区块中心对准指针
//
//  这一套坐标与选中态的数学全部集中在**这一个类**里，UI 层只负责画。
//  好处：纯逻辑可单测，且能在 Python 里先复刻验证（见下）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  ✅ 已通过 Python 复刻的随机不变量验证
//  ═══════════════════════════════════════════════════════════════════════
//  `verify/verify_editor_coord.py` —— 5000 轮随机场景（切/插/复制/删/变速/
//  选中/拖动/清选/PPS 变化 混合序列），C1–C13 全部零违规，可复现种子 20261006。
//
//  ═══════════════════════════════════════════════════════════════════════
//  ⚠️ 参照系必须统一在「内容盒宽度」上（这是踩过的坑）
//  ═══════════════════════════════════════════════════════════════════════
//  原型用 `document.getElementById('tlScroll').clientWidth` 作为唯一宽度量。
//  而 `getBoundingClientRect()` 给的是**边框盒** —— 两者相差「边框 + 滚动条」。
//
//  2026-10-06 就因为混用这两者，Playwright 断言（`wf.mjs` ㉑）误报了 17px 偏差：
//      指针 272  vs  矩形中心 289
//  改断言时才发现是参照系错了，不是布局错了。
//
//  **所以本类只暴露一个 `viewWidth`，语义 = clientWidth（内容盒）。**
//  宿主侧对应滚动视图 `bounds.width`（不含 border，也不含 overlay 滚动条）。
//  任何地方要算"可视区中心"，都必须用 `viewWidth / 2`，**不要**再去拿 rect。midX。
//
//  ⚠️ 本文件刻意**不 import UIKit**（Core 层规则，见
//     `docs/编辑页迁v2-改造清单.md` §4：Core 层禁 import UIKit，
//     否则进不了 SPM/测试 target）。所以上面只说"滚动视图 bounds"，
//     不出现任何 UIKit 类型名 —— 请保持这一点。
//

import Foundation
import CoreGraphics

// MARK: - 主轨区块

/// 主轨上的一个区块。`a` / `b` 是**轨道时间轴（trackT）**上的秒，
/// 不是源片时间 —— 变速后两者不等（见 `docs/v2.0数据模型` §2）。
struct BKRegion: Equatable {
    let id: String
    var a: TimeInterval
    var b: TimeInterval

    var length: TimeInterval { b - a }
    var mid: TimeInterval { (a + b) / 2 }
    var isValid: Bool { b >= a }

    func contains(_ t: TimeInterval) -> Bool { t >= a && t <= b }
}

// MARK: - 编辑页坐标与选中机

/// 编辑页坐标与选中机的**唯一实现**。
///
/// 对应原型 `index.html` 里这一组函数：
/// `viewW / contentW / minScrollPx / maxScrollPx / clampScroll /
///  centerT / scrollToT / applyScroll / autoFrameMain / selectBlock / clearSel`
final class BKEditorCoord {

    // MARK: 对外状态

    /// 当前选中态。**只读**，改它请走 `selectBlock` / `clearSelection` /
    /// `setSelectedId`，否则会绕过 `autoFrameMain` 的让位逻辑。
    private(set) var selection: BKSelectionState = .empty

    /// 主轨区块（顺序即拼接顺序，首尾相接）
    private(set) var regions: [BKRegion] = []
    /// 画中画轨区块（与主轨共享同一条 trackT 轴）
    private(set) var pipItems: [BKRegion] = []
    /// 录音轨区块（同上）
    private(set) var recItems: [BKRegion] = []

    /// 滚动位置（px）。正值 = 内容向左移。
    ///
    /// ⚠️ 不要直接赋值：改完必须跑 `applyScroll()`，否则会停在越界位置
    ///    （Python 复刻的 fuzz 第一版就踩了这个 —— 42 项 C9 越界，
    ///     根因是测试驱动漏了"改内容后重夹"，不是逻辑错）。
    private(set) var scrollPx: CGFloat = 0

    /// 每秒像素数（PPS）。**纯视图量**：改它不允许影响任何时间值。
    ///
    /// 原型实测 26 px/秒（规格补充A §3.1）。
    var pps: CGFloat = 26

    /// 可视区宽度（pt）。**语义 = clientWidth（内容盒）**，见文件头注释。
    ///
    /// 由宿主在布局变化时更新（`layoutSubviews` 里塞 `scrollView.bounds.width`）。
    var viewWidth: CGFloat = 358

    // MARK: 回调

    /// 选中态发生变化（跨区块边界 / 显式选中 / 清空）。
    /// 宿主在这里更新底栏上下文（10/9/5 键）。
    var onSelectionChanged: (() -> Void)?
    /// 需要重绘（每次 `applyScroll` 结束都会调）。
    /// 宿主在这里只重绘**选中框与指针**，不要整表重建（★1）。
    var onNeedsRedraw: (() -> Void)?
    /// 底栏上下文（main / pip / rec）发生变化。
    /// 与 `onSelectionChanged` 分开，是因为键位表只在**轨道种类**变了才需要重建。
    var onBarTrackChanged: ((BKTrackKind) -> Void)?

    // MARK: 内部状态

    /// ★2 程序化滚动锁。
    ///
    /// `selectBlock()` 为了把区块中心对准指针会做一次 `scrollToT`，
    /// 这是**程序化滚动**。此时 `centerT()` 落在的区块未必是目标区块
    /// （尤其滚动被边界夹紧时），自动蓝框会把刚选中的区块**覆盖回指针下的旧区块**。
    /// 症状：复制片段后本该选中新段，结果选中态还停在原段。
    private var autoFrameLock = false

    /// 上一次对外广播的底栏上下文，用于只在真正变化时通知
    private var lastBarTrack: BKTrackKind = .main

    /// `autoFrameMain` 实际改变选中的次数。仅用于诊断/测试断言。
    private(set) var autoFrameChangeCount = 0

    // MARK: - 坐标换算（原型同名函数）

    /// `TOTAL`：所有主轨区块时长之和
    var total: TimeInterval { regions.last?.b ?? 0 }

    /// `contentW()`
    var contentWidth: CGFloat { CGFloat(total) * pps }

    /// `minScrollPx()` —— ★竞品式边界：起点静止时可到中央指针下，两端各留半屏空腔
    var minScrollPx: CGFloat { -viewWidth / 2 }

    /// `maxScrollPx()`
    var maxScrollPx: CGFloat { max(minScrollPx, contentWidth - viewWidth / 2) }

    /// `clampScroll(_:)` —— ★3 必须夹取，否则边界处区块无法居中
    func clampScroll(_ v: CGFloat) -> CGFloat {
        max(minScrollPx, min(maxScrollPx, v))
    }

    /// `centerT()` —— 中央指针对应的轨道时间
    var centerT: TimeInterval { TimeInterval((scrollPx + viewWidth / 2) / pps) }

    /// 把轨道时刻换算成 px（`X(t) = t * PPS`）
    func x(forTrackT t: TimeInterval) -> CGFloat { CGFloat(t) * pps }

    // MARK: - 区块编辑

    /// 整体替换主轨区块。传入 `(id, 时长)` 序列，自动拼前缀和保持首尾相接。
    func setRegions(_ specs: [(id: String, length: TimeInterval)]) {
        regions.removeAll()
        var t: TimeInterval = 0
        for s in specs {
            regions.append(BKRegion(id: s.id, a: t, b: t + s.length))
            t += s.length
        }
        applyScroll()
    }

    /// 在开头插入并整体后移（对应「插入视频」）
    func prependRegion(id: String, length: TimeInterval) {
        for i in regions.indices {
            regions[i].a += length
            regions[i].b += length
        }
        regions.insert(BKRegion(id: id, a: 0, b: length), at: 0)
        applyScroll()
    }

    /// 追加到末尾
    func appendRegion(id: String, length: TimeInterval) {
        let t = regions.last?.b ?? 0
        regions.append(BKRegion(id: id, a: t, b: t + length))
        applyScroll()
    }

    /// 在 `t` 处切开所在区块（对应底栏「切割」）。
    ///
    /// - Returns: 新生成的后半段 id；若切点不在任何区块内部则返回 nil。
    @discardableResult
    func cut(atTrackT t: TimeInterval) -> String? {
        // 0.06s 保护间隔与原型一致：避免切出极窄碎片
        guard let i = regions.firstIndex(where: {
            let len = $0.length
            return t > $0.a + 0.06 && t < $0.b - 0.06 && len > 0.12
        }) else { return nil }
        let right = BKRegion(id: regions[i].id + "_b", a: t, b: regions[i].b)
        regions[i].b = t
        regions.insert(right, at: i + 1)
        applyScroll()
        return right.id
    }

    /// 复制某段：插到它之后，后续整体右移（对应底栏「复制」）。
    @discardableResult
    func duplicate(id: String) -> String? {
        guard let i = regions.firstIndex(where: { $0.id == id }) else { return nil }
        let len = regions[i].length
        for j in (i + 1)..<regions.count {
            regions[j].a += len
            regions[j].b += len
        }
        let newID = id + "_copy"
        regions.insert(BKRegion(id: newID, a: regions[i].b, b: regions[i].b + len), at: i + 1)
        applyScroll()
        return newID
    }

    /// 删除某段：后续整体左移（对应底栏「删除」）
    @discardableResult
    func delete(id: String) -> Bool {
        guard let i = regions.firstIndex(where: { $0.id == id }) else { return false }
        let len = regions[i].length
        for j in (i + 1)..<regions.count {
            regions[j].a -= len
            regions[j].b -= len
        }
        regions.remove(at: i)
        if selection.mainId == id { selection.mainId = nil }
        applyScroll()
        return true
    }

    /// 变速：该块的 trackT 轴长度按倍速缩放，后续整体顺移。
    ///
    /// 决策④/⑤：**先折叠再变速**，且 `out == trackT`（两轴合一）。
    /// 逐区块独立，**禁止全局乘数**。
    func setSpeed(id: String, speed: Double) {
        guard let i = regions.firstIndex(where: { $0.id == id }), speed > 0 else { return }
        let oldLen = regions[i].length
        let newLen = oldLen / speed
        let delta = newLen - oldLen
        regions[i].b = regions[i].a + newLen
        for j in (i + 1)..<regions.count {
            regions[j].a += delta
            regions[j].b += delta
        }
        applyScroll()
    }

    /// 拖动重排：把 `id` 移到索引 `to`
    func move(id: String, to toIndex: Int) {
        guard let from = regions.firstIndex(where: { $0.id == id }) else { return }
        let r = regions.remove(at: from)
        let dest = max(0, min(regions.count, toIndex))
        regions.insert(r, at: dest)
        // 重排后必须重算前缀和，保持首尾相接（不变量 I1）
        var t: TimeInterval = 0
        for i in regions.indices {
            let len = regions[i].length
            regions[i].a = t
            regions[i].b = t + len
            t += len
        }
        applyScroll()
    }

    // MARK: - 侧轨

    func setPipItems(_ specs: [(id: String, a: TimeInterval, b: TimeInterval)]) {
        pipItems = specs.map { BKRegion(id: $0.id, a: $0.a, b: $0.b) }
        normalizeSideTrack()
    }

    func setRecItems(_ specs: [(id: String, a: TimeInterval, b: TimeInterval)]) {
        recItems = specs.map { BKRegion(id: $0.id, a: $0.a, b: $0.b) }
        normalizeSideTrack()
    }

    /// 侧轨块必须落在 `[0, TOTAL]` 内（不变量 C11）
    private func normalizeSideTrack() {
        let hi = total
        for i in pipItems.indices {
            pipItems[i].a = max(0, min(pipItems[i].a, hi))
            pipItems[i].b = max(pipItems[i].a, min(pipItems[i].b, hi))
        }
        for i in recItems.indices {
            recItems[i].a = max(0, min(recItems[i].a, hi))
            recItems[i].b = max(recItems[i].a, min(recItems[i].b, hi))
        }
    }

    // MARK: - 滚动与自动蓝框

    /// `applyScroll()` —— 夹取 + 重绘 + 自动蓝框。
    ///
    /// **所有改变 scroll / 内容 / 选中的操作都必须以它收尾。**
    /// 顺序与原型一致：先夹取，再 `autoFrameMain`，最后广播重绘。
    func applyScroll() {
        scrollPx = clampScroll(scrollPx)
        autoFrameMain()
        broadcastBarTrackIfNeeded()
        onNeedsRedraw?()
    }

    /// `scrollToT(_:autoFrame:)` —— 把轨道时刻 `t` 对准中央指针。
    ///
    /// - Parameter autoFrame: 传 `false` 表示这是**程序化滚动**
    ///   （如 `selectBlock` 为对准区块而滚），此时自动蓝框必须让位，见 ★2。
    func scrollToT(_ t: TimeInterval, autoFrame: Bool = true) {
        autoFrameLock = !autoFrame                    // ★2
        scrollPx = clampScroll(x(forTrackT: t) - viewWidth / 2)
        applyScroll()
        autoFrameLock = false
    }

    /// `autoFrameMain()` —— 中央指针落在哪个主轨区块就选中它。
    ///
    /// ★1 `if newId == selection.mainId { return }` 这行是**性能关键**：
    ///    原型早期每像素重绘，拖动明显卡顿。不要因为"代码更简洁"去掉它。
    /// ★2 `autoFrameLock` 期间直接返回，程序化滚动不覆盖显式选中。
    /// ★C10 侧轨选中时让位，不抢主轨选中。
    func autoFrameMain() {
        // ★C10 侧轨选中时让位
        if selection.track == .pip || selection.track == .rec { return }
        // ★2 程序化滚动期间不覆盖选中
        if autoFrameLock { return }

        let t = centerT
        // 命中测试：原型用 `a <= t <= b` 闭区间，两段相接处归前一段
        let newID = regions.first(where: { $0.contains(t) })?.id

        // ★1 未变则直接返回 —— 性能关键，别删
        if newID == selection.mainId { return }

        selection.mainId = newID
        autoFrameChangeCount += 1
        onSelectionChanged?()
    }

    // MARK: - 选中

    /// `selectBlock(_:_:)` —— 显式选中某轨某块，并三轨同步滚动使其中心对准指针。
    func selectBlock(_ track: BKTrackKind, id: String) {
        selection.track = track
        switch track {
        case .main: selection.mainId = id
        case .pip:  selection.pipId = id
        case .rec:  selection.recId = id
        }

        guard let r = region(track, id) else {
            // 目标不存在：仍要广播一次，让底栏按新上下文切键
            applyScroll()
            onSelectionChanged?()
            return
        }
        // ★2 关键：这里是程序化滚动，autoFrame 必须传 false
        scrollToT(r.mid, autoFrame: false)
        onSelectionChanged?()
    }

    /// 按 `id` 兜底设置选中，不做滚动（用于复制后直接选中新段）
    func setSelectedId(_ id: String?, for track: BKTrackKind) {
        selection.setSelectedId(id, for: track)
        onSelectionChanged?()
        broadcastBarTrackIfNeeded()
    }

    /// `clearSel()` —— 点空白处清空选中，底栏回主轨 10 键
    func clearSelection() {
        selection.clearAll()
        onSelectionChanged?()
        applyScroll()
    }

    /// 取某轨某块
    func region(_ track: BKTrackKind, _ id: String) -> BKRegion? {
        switch track {
        case .main: return regions.first { $0.id == id }
        case .pip:  return pipItems.first { $0.id == id }
        case .rec:  return recItems.first { $0.id == id }
        }
    }

    // MARK: - 底栏上下文（规格 §1.1）

    /// 当前应显示哪套底栏
    var currentBarTrack: BKTrackKind { selection.barTrack }

    private func broadcastBarTrackIfNeeded() {
        let t = currentBarTrack
        if t != lastBarTrack {
            lastBarTrack = t
            onBarTrackChanged?(t)
        }
    }

    // MARK: - ★4 点空白关菜单的排除名单支持

    /// 判断某轨道的选中态是否落在合法状态（用于状态机自检/测试）
    ///
    /// 规格补充A §2.2：不允许出现「selTrack 说画中画、pipSelId 却是 nil」这类非法态
    /// 在**底栏上下文**层面的表现 —— 此时 `barTrack` 会自动回落到 `.main`。
    var isSelectionConsistent: Bool {
        switch selection.track {
        case .main: return true                       // 主轨允许无选中（默认态）
        case .pip:  return selection.pipId != nil
        case .rec:  return selection.recId != nil
        }
    }
}
