//
//  BKTrackView.swift
//  bk剪辑 — 滚动主轨道（第四批改：定稿版 —— 加缩放、加把手、配色焊死）
//
//  【为什么推翻更早的全览式波形】
//  最早是整条素材摊开在固定宽度里，橙色播放头从左跑到右。
//  皓哥要的是剪映那种：**橙色指针钉死在正中央不动，内容在底下左右滚**。
//  差别不是动画，是操作精度 —— 全览式里 42 秒素材挤进 350pt，
//  一秒才 8pt，手指在屏幕上 1pt 的误差就是 0.12 秒，微调刀口根本下不去手。
//
//  【几何约定】先把数学说清楚，后面全靠它（定稿第 4.3 节）：
//    W    = 可视宽度
//    pad  = W / 2            左右各留半屏余量（皓哥要求：首尾也要能推到指针下）
//    pps  = 每秒像素数        由缩放决定
//    L    = duration * pps   内容本身的长度
//    画布总宽 = L + W        内容 + 左右半屏余量
//    滚动范围 = [0, L]       offset 0 时指针指向 0 秒，offset L 时指向末尾
//  **指针所指时间 t = offset / pps** —— 因为 pad 正好等于 W/2，两者相消。
//  这个巧合不是巧合，是刻意把余量取成半屏换来的，别改成别的数。
//
//  【可见时间窗】给概览条画橙色视窗框用：
//    t0 = t - W/(2*pps)      t1 = t + W/(2*pps)
//  同样是因为 pad = W/2。
//
//  【谁负责滚】UIScrollView 负责惯性和回弹，不自己撸 pan。
//  只有「拖边界把手」这一种手势要跟滚动抢，做法是摸到把手才临时关掉滚动。
//

import UIKit

// 波形纵轴的 dB 显示范围，与 tools/preview_cut.py 的波形图一致
private let dbLo: Double = -70
private let dbHi: Double = -5

// 注：`BKHandleEnd` 已移到 Core 层（app/Core/BKModels.swift）——
// `BKTimeline.resizeKeeps`（第二阶段核心算法）也要用它，Core 不该反向依赖 UI。

protocol BKTrackViewDelegate: AnyObject {
    /// 内容被滚动了。time 是当前指针所指的时间
    func track(_ view: BKTrackView, didScrollTo time: Double)
    /// 点了一下一个片段
    func track(_ view: BKTrackView, didTogglePieceAt time: Double)
    /// 缩放变了（滑杆或双指捏合）。screens 是「整条素材摊成几屏宽」
    func track(_ view: BKTrackView, didChangeZoomTo screens: CGFloat)
    /// 手指一碰轨道。**正在播放时收到它就该立刻 pause**（定稿 4.5.1），
    /// 晚一步就会在拖动的第一帧漏出一点声音
    func trackDidTouchDown(_ view: BKTrackView)
    /// 已经在片头，松手时还被往右拽过 60pt → 该换上一条了（定稿 4.5.3）
    func trackDidPullBeyondHead(_ view: BKTrackView)
    /// 已经在片尾，松手时还被往左拽过 60pt → 该换下一条了
    func trackDidPullBeyondTail(_ view: BKTrackView)

    // MARK: v1.3.4 第一阶段（拖红区边缘调气口大小）

    /// 按下红区边缘开始拖。VC 收到就开「合并提交」
    func track(_ view: BKTrackView, didBeginRedEdgeDragNear time: Double)
    /// 拖红区边缘。near 是起手时的旧位置，newTime 是要挪到的新位置（**原片时间**）
    func track(_ view: BKTrackView, didDragRedEdgeNear near: Double, to newTime: Double)
    /// 松手，结束这次拖动
    func trackDidEndRedEdgeDrag(_ view: BKTrackView)

    // MARK: v1.3.4 第二阶段（长按绿区 → 黄把手 → 调这块的长短）

    /// 长按进入了编辑态
    func track(_ view: BKTrackView, didBeginRegionEditFrom start: Double, to end: Double)
    /// 拖动编辑态某一端的把手。`handle` 是哪一端，newTime 是要挪到的新位置（画布时间）
    func track(_ view: BKTrackView, didDragRegionEdge handle: BKHandleEnd, to newTime: Double)
    /// 拖把手松手，提交最终区间。VC 在这里把区间换算成 cuts 并落一次撤销
    func track(_ view: BKTrackView, didCommitRegionEditFrom start: Double, to end: Double)
}

final class BKTrackView: UIView {

    weak var delegate: BKTrackViewDelegate?

    private let scroll = UIScrollView()
    private let canvas = TrackCanvas()
    private let pointer = TrackPointer()
    private var tap: UITapGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!
    /// v1.3.0 长按：进入区域编辑态（定稿 4.3）。**仅第二阶段**
    private var longPress: UILongPressGestureRecognizer!
    /// v1.3.4 第一阶段：拖红区边缘调大小。**仅第一阶段**
    private var redEdgePan: UIPanGestureRecognizer!
    /// 正在拖的那条红区边缘（起手时的原片时间）
    private var draggingRedEdge: Double?
    /// 第二阶段锁定：点过「一键去红」之后为 true，第一阶段的手势全部停用。
    /// 由 `setContent(redFolded:)` 同步 —— 红区不在轨道上了，拖红区边缘没有意义。
    private var stage2Locked = false

    private var duration: Double = 0
    private var pps: CGFloat = 60
    private var lastWidth: CGFloat = 0
    /// 程序滚动的标志：播放时是代码在推 contentOffset，别再回调给外部去 seek
    private var programmatic = false
    private var pinchBaseZoom: CGFloat = 6
    /// 捏合时钉住的那一点：手指中点底下对应的时间，以及它在屏幕上的横坐标
    private var pinchAnchorTime: Double = 0
    private var pinchAnchorX: CGFloat = 0

    // MARK: - v1.3.0 区域编辑态

    /// 当前进入编辑态的那一段（画布时间）。private(set)：只有视图自己能改
    private(set) var editingSegmentBase: (start: Double, end: Double)?
    /// 编辑态淡入进度 0~1。做成渐变而不是硬切，符合 iOS 观感
    private(set) var editFade: Double = 0
    private(set) var draggingHandle: BKHandleEnd?
    /// 拖把手时**松手前**的临时区间。拖动中不能直接改 marks（每帧重建太贵、
    /// 撤销栈也扛不住），只记在这里，松手才提交给 VC。
    private(set) var dragPreview: (start: Double, end: Double)?

    /// 整条素材摊成几屏宽。默认 6 屏：再密手指抹不开，再松就看不见气口
    private(set) var zoomScreens: CGFloat = 6

    /// 允不允许「拖到头再拽」换素材。只有一条素材 / 正在加载时由外部关掉
    var allowsSiblingSwitch = true

    /// 缩放上下限。1 屏 = 全览（看全局），20 屏 = 贴脸（单帧级微调）
    static let zoomMin: CGFloat = 1
    static let zoomMax: CGFloat = 20


    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        clipsToBounds = true

        scroll.backgroundColor = .clear
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.delaysContentTouches = false
        scroll.delegate = self
        addSubview(scroll)

        canvas.backgroundColor = .clear
        scroll.addSubview(canvas)

        // 指针压在最上层，但不能吃掉触摸 —— 否则中央这一竖条永远点不到波形
        pointer.backgroundColor = .clear
        pointer.isUserInteractionEnabled = false
        addSubview(pointer)

        // ============================================================
        // 【v1.3.4 手势重构】把原来那个 `pan`（拖接缝）改成 `redEdgePan`（拖红区边缘）
        //
        // v1.3.4 那版把 `onPan` 清空、shouldBegin 恒 true，结果它**每次都抢下
        // UIScrollView 的滚动**而什么都不做 —— 轨道完全滑不动、黄把手也拖不动
        // （真机 2026-10-04 18:39 报障）。根因就是「在 canvas 上放了一个不干活的 pan」。
        //
        // 现在 canvas 上**没有任何抢滚动的手势**：滚动 100% 由 UIScrollView 原生负责。
        // 两个阶段各一套手势（皓哥 18:39 定的两阶段逻辑）：
        //   第一阶段：`redEdgePan` 拖红区边缘调大小 —— 只在手指确实按在红区边缘
        //           ±28pt 内才起手（shouldBegin 里判），其余情况让给滚动
        //   第二阶段：`longPress` 0.5s 进编辑态 → 拖黄把手
        // ============================================================
        redEdgePan = UIPanGestureRecognizer(target: self, action: #selector(onRedEdgePan(_:)))
        redEdgePan.delegate = self
        redEdgePan.maximumNumberOfTouches = 1
        canvas.addGestureRecognizer(redEdgePan)

        tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        tap.delegate = self
        canvas.addGestureRecognizer(tap)

        pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        pinch.delegate = self
        canvas.addGestureRecognizer(pinch)

        // v1.3.0 长按进区域编辑态。0.5s，位移容忍 10pt（按住时手会抖，
        // 容忍太小会被判定为移动而取消长按）。按住不放时 pan/tap 都让它先走 ——
        // 三个手势的仲裁见 gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)。
        longPress = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
        longPress.minimumPressDuration = BKConfig.RegionEdit.longPressSec
        longPress.allowableMovement = 10
        longPress.delegate = self
        canvas.addGestureRecognizer(longPress)
    }

    // MARK: - v1.3.0 区域编辑态对外接口

    /// 把编辑态状态同步进画布渲染层。
    /// 状态在 BKTrackView 上、画在 canvas 上，中间必须过一道 —— 散着写迟早漏。
    private func syncEditState() {
        canvas.r.editingBase = editingSegmentBase
        canvas.r.dragPreview = dragPreview
        canvas.r.editFade = editFade
        switch draggingHandle {
        case .head: canvas.r.draggingHandle = 1
        case .tail: canvas.r.draggingHandle = 2
        case nil: canvas.r.draggingHandle = 0
        }
    }

    /// 退出编辑态。VC 在切换素材、点别处、提交拖动之后调它
    func exitRegionEdit() {
        guard editingSegmentBase != nil || draggingHandle != nil else { return }
        editingSegmentBase = nil
        draggingHandle = nil
        dragPreview = nil
        editFade = 0
        // ⚠️ 必须把 allowableMovement 复位 —— 进场时放开了，不复位的话
        // 下次长按就少了「手抖不算移动」这层保护
        longPress.allowableMovement = 10
        scroll.isScrollEnabled = true
        syncEditState()
        redrawVisible()
    }

    /// 当前是不是在拖把手（VC 用它决定要不要把拖动合并成一步撤销）
    var isDraggingHandle: Bool { draggingHandle != nil }

    /// 拖把手松手时 VC 要拿「拖动前的原区间」去算 cuts 怎么改 ——
    /// 所以这个得对外暴露。（`dragPreview` 是拖动中的预览，松手时已经清掉了）
    var editingSegment: (start: Double, end: Double)? { editingSegmentBase }

    // MARK: - 对外接口

    func setContent(envelope: BKEnvelope?,
                    pieces: [BKMark],
                    splits: [Double],
                    duration: Double,
                    thresholdDb: Double,
                    foldMap: [(out: Double, src: Double, dur: Double)]? = nil,
                    redFolded: Bool = false) {
        let keep = currentTime
        self.duration = duration
        canvas.r.envelope = envelope
        canvas.r.pieces = pieces
        canvas.r.splits = splits
        canvas.r.duration = duration
        canvas.r.thresholdDb = thresholdDb
        canvas.r.foldMap = foldMap
        canvas.r.redFolded = redFolded
        // 【v1.3.4】第二阶段锁定：点过「一键去红」后停用第一阶段手势
        // （红区不在轨道上了，红区边缘拖动没有意义；长按才是第二阶段的入口）
        if stage2Locked != redFolded {
            stage2Locked = redFolded
            // 阶段切换时清掉进行中的手势状态
            draggingRedEdge = nil
            if stage2Locked { exitRegionEdit() }
        }
        relayout(keepPointerTime: keep)
        // ⚠️⚠️ 【v1.4.6 修】这里必须**全量重绘**，不能只重画可见区。
        //
        // 现象（2026-10-04 20:33 皓哥真机截图）：点「一键去红」后，
        // **屏幕内**的红区消失了，**屏幕外**的红区还留在画面上。
        //
        // 根因：`redrawVisible()` 只调 `setNeedsDisplay(可见区)`，
        // 于是屏幕外那些**从没被重画过**的区域继续显示旧内容（带红区）。
        // 数据其实是对的（keptRanges 已经更新），是画面没刷新。
        //
        // 区分两种重绘：
        //   · **内容变了**（删红、检测、换素材、撤销）→ 全量，整条都要更新
        //   · **只是滚动/拖动** → 只画可见区（每帧都走全量会卡顿，v1.3.3 的教训）
        canvas.setNeedsDisplay()
    }

    /// 只重画当前可见的那一屏。
    ///
    /// 【为什么必须显式传 rect】`UIView.setNeedsDisplay()` 无参时，
    /// 系统给的脏矩形是整个 bounds。而我们这个 canvas 在 UIScrollView 里、
    /// 宽可达 7800pt，`draw(_:)` 里的列裁剪（c0/c1）就白算了。
    /// 拖动时每帧走一遍 refreshTrack → setContent，无参调用 = 每帧全量重画 = 卡顿。
    ///
    /// 可见区怎么算：canvas 局部坐标 = 内容时间 × pps + pad，
    /// 而当前指针时间两侧各半屏（pad = 宽/2，这个巧合是刻意的，见文件头几何约定）。
    private func redrawVisible() {
        guard pps > 0, bounds.width > 1, duration > 0 else {
            canvas.setNeedsDisplay()
            return
        }
        let vis = viewport
        // 上下留一点余量，避免边界处出现 1px 缝
        let padY: CGFloat = 4
        let x0 = canvas.r.pad + CGFloat(vis.start) * pps - 2
        let x1 = canvas.r.pad + CGFloat(vis.end) * pps + 2
        let r = CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: canvas.bounds.height)
            .intersection(canvas.bounds.insetBy(dx: 0, dy: -padY))
        if r.isNull || r.width < 1 {
            canvas.setNeedsDisplay()
        } else {
            canvas.setNeedsDisplay(r)
        }
    }

    /// 当前指针所指时间
    var currentTime: Double {
        guard pps > 0 else { return 0 }
        return Double(scroll.contentOffset.x) / Double(pps)
    }

    /// 当前可见的时间窗，给概览条画橙色视窗框用
    var viewport: (start: Double, end: Double) {
        guard pps > 0, bounds.width > 0 else { return (0, 0) }
        let half = Double(bounds.width / 2) / Double(pps)
        let t = currentTime
        return (t - half, t + half)
    }

    func setPointerTime(_ t: Double) {
        guard pps > 0, duration > 0 else { return }
        let x = min(max(CGFloat(t) * pps, 0), CGFloat(duration) * pps)
        guard abs(scroll.contentOffset.x - x) > 0.4 else { return }
        programmatic = true
        scroll.contentOffset = CGPoint(x: x, y: 0)
        // 在同一轮 runloop 结束前保持这个标志 —— delegate 回调就在这一轮里，
        // 提前清掉等于没设
        DispatchQueue.main.async { self.programmatic = false }
    }

    /// 缩放。默认保持指针所指的时间不变：放大时是「以指针为中心放大」，
    /// 否则一拉滑杆画面就跳到别处，根本没法对着气口调
    func setZoomScreens(_ screens: CGFloat) {
        applyZoom(screens, anchorTime: nil, anchorScreenX: nil)
    }

    /// 真正干活的缩放。捏合时额外传一个锚点，把手指底下那一刻钉住。
    private func applyZoom(_ screens: CGFloat, anchorTime: Double?, anchorScreenX: CGFloat?) {
        let clamped = min(max(screens, BKTrackView.zoomMin), BKTrackView.zoomMax)
        guard abs(clamped - zoomScreens) > 0.001 else { return }
        zoomScreens = clamped

        // 先按「指针时间不变」重排，拿到新的 pps
        relayout(keepPointerTime: currentTime)

        // 再把锚点挪回手指底下。几何还是那条：
        //   canvasX = pad + t*pps，pad = W/2，offset = canvasX - 屏幕x
        // 想让 t 停在屏幕 sx 处，offset 就必须等于 t*pps + W/2 - sx
        if let t = anchorTime, let sx = anchorScreenX {
            let target = CGFloat(t) * pps + bounds.width / 2 - sx
            let maxOffset = CGFloat(duration) * pps
            programmatic = true
            scroll.contentOffset = CGPoint(x: min(max(target, 0), maxOffset), y: 0)
            DispatchQueue.main.async { self.programmatic = false }
        }
        redrawVisible()
    }

    // MARK: - 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1 else { return }
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            relayout(keepPointerTime: currentTime)
            redrawVisible()
        }
    }

    private func relayout(keepPointerTime t: Double) {
        let w = bounds.width
        guard w > 1 else { return }

        pps = duration > 0 ? max((w * zoomScreens) / CGFloat(duration), 8) : 60
        let contentLen = CGFloat(duration) * pps
        let total = contentLen + w           // 内容 + 左右各半屏余量

        scroll.frame = bounds
        scroll.contentSize = CGSize(width: total, height: bounds.height)
        canvas.frame = CGRect(x: 0, y: 0, width: total, height: bounds.height)
        canvas.r.pad = w / 2
        canvas.r.pps = pps
        pointer.frame = CGRect(x: w / 2 - 7, y: 0, width: 14, height: bounds.height)

        setPointerTime(t)
    }

    // MARK: - 坐标换算

    private func canvasX(of time: Double) -> CGFloat {
        canvas.r.pad + CGFloat(time) * canvas.r.pps
    }

    private func timeAt(canvasX x: CGFloat) -> Double {
        guard canvas.r.pps > 0 else { return 0 }
        return Double((x - canvas.r.pad) / canvas.r.pps)
    }

}

// MARK: - 手势

extension BKTrackView: UIGestureRecognizerDelegate {

    /// 【v1.3.3 手势统一 —— 拖接缝 pan 已取消】
    ///
    /// 原来这里判断「手指是否摸到分界线」，摸到就抢下 pan 自己去拖接缝。
    /// 现在**一律放行给 UIScrollView 去滚**，拖边界只走「长按 → 黄把手」这一条路。
    ///
    /// 【为什么取消】方案甲（皓哥 17:41 定）：两套拖拽逻辑在数学上不等价 ——
    ///   拖接缝（moveBoundary）：改接缝位置，左右两段**同时**变
    ///   黄把手（cutsAfterResize）：改**这一段**，邻居**被动让位**
    /// 并存 = 同一件事两种做法，行为取决于手指落在哪儿 —— 这是原方案最含糊的地方。
    /// 统一后只有一条语义：**拖哪一段的哪一端，那一段变长/变短，扫过区域继承该段颜色。**
    /// 红区绿区完全对等。
    ///
    /// 代价：微调刀口前多一次长按（0.5s）。取舍理由是这个 App 的核心竞争力是「精度可控」，
    /// **行为唯一 > 少一次长按**。剪映本身也是长按才出精确调节手柄。
    ///
    /// ⚠️⚠️ **这里是 v1.3.4「轨道完全滑不动」的修复点**
    /// v1.3.4 这里恒返回 `true`，而 canvas 上那个 pan 是空函数 ——
    /// 于是它**每次都抢下 UIScrollView 的滚动**然后什么都不做，轨道就锁死了。
    /// （同一根因还导致黄把手拖不动：长按后 pan 仍在竞争。）
    ///
    /// v1.3.4 的正确做法：**canvas 上不放任何抢滚动的手势**。
    /// `redEdgePan` 只在「手指确实按在红区边缘附近」时才起手，其余一律让给滚动。
    ///
    /// 注意这是 UIView 自带的方法，必须 override —— 直接写 func 会报
    /// "overriding declaration requires an 'override' keyword"
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === redEdgePan {
            // 第二阶段：红区已经不在轨道上了，红区边缘拖动停用
            guard !stage2Locked, editingSegmentBase == nil else { return false }
            // 只有真的按在红区边缘附近才起手，否则**让给 UIScrollView 滚动**
            let x = gestureRecognizer.location(in: canvas).x
            guard let edge = nearestRedEdge(to: timeAt(canvasX: x)) else { return false }
            return abs(canvasX(of: edge) - x) <= CGFloat(BKConfig.RegionEdit.handleGrabTolerance)
        }
        if gestureRecognizer === longPress {
            // 长按进编辑态只属于第二阶段（第一阶段长按没有可编辑的东西）
            return stage2Locked
        }
        return true
    }

    /// v1.3.4 手势仲裁：
    ///
    /// | 手势 | 起手条件 |
    /// |---|---|
    /// | `redEdgePan` | 仅第一阶段，且手指按在红区边缘 ±28pt 内 |
    /// | `longPress` | 仅第二阶段（长按片段进编辑态） |
    /// | `tap` | 第一阶段切红绿；第二阶段点别处退出编辑态 |
    /// | `pinch` | 一直可以 |
    /// | UIScrollView 原生 pan | **一直可以，我们不抢** ← 轨道能滑动全靠这条
    ///
    /// 长按 → tap 的顺序由 UIKit 自动处理：长按先 recognized，tap 就自动 fail。
    ///
    /// ⚠️ **这里不能加 `override`**：上面那个 `gestureRecognizerShouldBegin` 是
    /// UIView **自带**的方法（要 override），而这个是 `UIGestureRecognizerDelegate` 的
    /// **协议方法**（加了 override 就报 "does not override any method from its superclass"）。
    /// 两者长得像但性质不同，混淆过一次。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // 双指捏合缩放要能和滚动同时进行
        if gestureRecognizer === pinch || other === pinch { return true }
        // 第二阶段拖黄把手时，longPress 与滚动可以共存
        if editingSegmentBase != nil && (gestureRecognizer === longPress || other == longPress) { return true }
        return false
    }

    /// 第一阶段：拖红区边缘调大小（v1.3.4）
    ///
    /// 只在 `gestureRecognizerShouldBegin` 判定「手指确实按在红区边缘附近」时才进来。
    /// 拖动中每帧回调一次，VC 侧用 `coalesce` 合并成**一步撤销**。
    @objc private func onRedEdgePan(_ g: UIPanGestureRecognizer) {
        let here = g.location(in: canvas)
        let t = timeAt(canvasX: here.x)
        switch g.state {
        case .began:
            // 关掉滚动，否则拖边缘的同时内容会跟着漂走
            scroll.isScrollEnabled = false
            draggingRedEdge = nearestRedEdge(to: t)
            if let e = draggingRedEdge {
                delegate?.track(self, didBeginRedEdgeDragNear: e)
            }
        case .changed:
            guard let from = draggingRedEdge else { return }
            delegate?.track(self, didDragRedEdgeNear: from, to: t)
        case .ended, .cancelled, .failed:
            if draggingRedEdge != nil {
                delegate?.trackDidEndRedEdgeDrag(self)
            }
            draggingRedEdge = nil
            scroll.isScrollEnabled = true
        default:
            break
        }
    }

    /// 离 t 最近的一条**红区边缘**（第一阶段拖它调红区大小）。
    /// 只看红区的两端，素材首尾不算。
    private func nearestRedEdge(to t: Double) -> Double? {
        var best: Double?
        // 超过 0.5 秒就不算摸到：不然手指一放下去就抓住远处的边界
        var bestDist = 0.5
        for pc in canvas.r.pieces where pc.kind == .cut {
            for edge in [pc.start, pc.end] where edge > 0.001 && edge < duration - 0.001 {
                let d = abs(edge - t)
                if d < bestDist { bestDist = d; best = edge }
            }
        }
        return best
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        // 编辑态里点别处 = 退出编辑态，不该顺手把那一段 toggle 了
        if editingSegmentBase != nil {
            exitRegionEdit()
            return
        }
        let t = timeAt(canvasX: g.location(in: canvas).x)
        guard t >= 0, t <= duration else { return }
        delegate?.track(self, didTogglePieceAt: t)
    }

    // MARK: - v1.3.0 长按 → 区域编辑态

    /// 找离触点最近的一段（编辑态的对象）。
    /// 折叠状态下轨道画布是成品时间轴，直接用 `pieces` 即可（渲染的本来就是它）。
    private func segment(at t: Double) -> (start: Double, end: Double)? {
        var best: (start: Double, end: Double)?
        var bestDist = Double.greatestFiniteMagnitude
        var bestWidth: Double = 0
        for pc in canvas.r.pieces {
            // 【v1.3.3】跳过零长度标记。
            // 第二阶段 `keepsToPieces` 会在区与区之间插一个 start == end 的标记当分割线，
            // 而零长度段对 t 的区间判断是 `t >= start && t <= end` —— 任何落在该点上的
            // 手指都会命中它，返回一个宽度为 0 的段 → 黄框宽度 0。
            if pc.duration <= 1e-9 { continue }
            if t >= pc.start - 1e-9 && t <= pc.end + 1e-9 {
                // ⚠️⚠️ **v1.4.6 修「黄框位置不对」的关键**（2026-10-04 20:33 皓哥截图）
                //
                // 原来算的是「t 到该段**端点**的距离」，取最小。
                // 问题：手指正好落在两个绿区之间的**分割线**上时，
                // 相邻两段到 t 的距离**都是 0** → 平局 → 取先遍历到的**前一段**。
                // 于是明明长的是右边那块，黄框却画在了左边那块上（截图里就是这个现象）。
                //
                // 正解：**手指落点更靠近哪一段的内部，就选哪一段**。
                // 用「到该段中点的距离」比较 —— 分割线正好是两段的中点分界，
                // 落在线上时距离相等，此时取**更长**的那段（用户更可能想调大的那块），
                // 并且遍历顺序改成**从后往前**，保证平局时取靠手指右侧的那段。
                let mid = (pc.start + pc.end) / 2
                let dMid = abs(mid - t)
                let width = pc.duration
                if best == nil {
                    best = (pc.start, pc.end); bestDist = dMid; bestWidth = width
                } else if dMid < bestDist - 1e-9 {
                    best = (pc.start, pc.end); bestDist = dMid; bestWidth = width
                } else if abs(dMid - bestDist) <= 1e-9 && width > bestWidth {
                    // 平局：取更长的那段
                    best = (pc.start, pc.end); bestWidth = width
                }
            }
        }
        return best
    }

    @objc private func onLongPress(_ g: UILongPressGestureRecognizer) {
        let here = g.location(in: canvas)
        let t = timeAt(canvasX: here.x)

        switch g.state {
        case .began:
            // 编辑态里再长按 = 退出（给用户一个反悔的机会）
            if editingSegmentBase != nil {
                exitRegionEdit()
                return
            }
            guard let seg = segment(at: t) else { return }
            editingSegmentBase = seg
            editFade = 0
            // ⚠️ 进编辑态后把 allowableMovement 放开到无限。
            // 它默认 10pt 的作用是「按住时手抖别误判成滚动」；但进了编辑态就该一直跟到底 ——
            // 保持 10pt 的话，用户按住把手一抖就会被判 cancelled，把手凭空消失。
            longPress.allowableMovement = .greatestFiniteMagnitude
            // 轻震：确认「进编辑态了」这一步被系统接收到
            let fb = UIImpactFeedbackGenerator(style: .light)
            fb.prepare()
            fb.impactOccurred()
            syncEditState()
            animateEditFade(to: 1)
            delegate?.track(self, didBeginRegionEditFrom: seg.start, to: seg.end)

        case .changed:
            // 编辑态里继续按住并左右挪 = 直接进入拖把手（省一次抬手再按）。
            // ⚠️ 必须允许长按在手抖超限后继续跟随：allowableMovement 只在**未进入编辑态前**
            // 用来区分「按住」和「按住后想滚动」。进了编辑态就得一直跟到底，
            // 否则用户按住拖把手时手一抖，手势被判 cancelled、把手就丢了。
            guard var seg = editingSegmentBase, draggingHandle == nil else { return }
            // ⚠️⚠️ **v1.4.3「黄把手出得来但拖不动」的根因**（2026-10-04 19:50）
            //
            // 原来这里要求「手指离某端 < handleGrabTolerance(28pt)」才起手。
            // 但长按 0.5 秒期间手指必然有轻微抖动，等到 .changed 触发时偏移已超过 28pt
            // → `return` → **永远进不了拖动状态**，表现为「按住了但拖不动」。
            //
            // v1.4.4 正解：**进入编辑态后，手指落在框内任意位置都算抓住把手**，
            // 离哪端近就拖哪端（不设最小距离门槛）。理由：
            //   ① 编辑态是「我已经决定要调这段」的明确意图，不需要再判断「是否摸到把手」
            //   ② 把手已移到框外，用户看到的是箭头，指向性已经够强
            //   ③ 判定放宽后手感顺滑，不用精确瞄准
            let xHead = canvasX(of: seg.start)
            let xTail = canvasX(of: seg.end)
            // 手指在段的哪一侧就拖哪一端；正好在中间则取最近的那端
            let dHead = abs(xHead - here.x)
            let dTail = abs(xTail - here.x)
            let h: BKHandleEnd = (dHead <= dTail) ? .head : .tail
            draggingHandle = h
            dragPreview = seg
            scroll.isScrollEnabled = false
            syncEditState()
            delegate?.track(self, didDragRegionEdge: h, to: t)
            _ = seg

        case .changed where draggingHandle != nil:
            // 已经在拖某端了：持续更新预览区间（不松手就一直跟）
            guard var prev = dragPreview else { return }
            // ⚠️ 先夹取再更新：拖出 [0, duration] 要挡住，
            // 压到比 minSegmentSec 还短也要挡住 —— 不然拖到边界外再拖回来，
            // 中间会经历「非法区间」，松手时提交出一个越界的段
            let wantStart = (draggingHandle == .head) ? t : prev.start
            let wantEnd = (draggingHandle == .tail) ? t : prev.end
            let clamped = BKTimeline.clampRegion(wantStart, wantEnd,
                                                 duration: duration,
                                                 minSeg: BKConfig.RegionEdit.minSegmentSec)
            prev.start = clamped.start
            prev.end = clamped.end
            dragPreview = prev
            syncEditState()
            redrawVisible()
            delegate?.track(self, didDragRegionEdge: draggingHandle!, to: t)

        case .ended, .cancelled, .failed:
            // 抬手：结束拖动（如果拖过），否则就只是退出/保持编辑态
            if draggingHandle != nil {
                if let prev = dragPreview {
                    delegate?.track(self, didCommitRegionEditFrom: prev.start, to: prev.end)
                }
                draggingHandle = nil
                dragPreview = nil
                scroll.isScrollEnabled = true
                syncEditState()
            } else if editingSegmentBase != nil {
                // 纯长按没拖 → 松手后**保持**编辑态，方便继续拖把手
                syncEditState()
            }

        default:
            break
        }
    }

    /// 编辑态淡入淡出。用 UIView.animate 但不带视图，只驱动一个数值，
    /// 每步 setNeedsDisplay 重画画布那一层。
    ///
    /// ⚠️ **这里必须调 syncEditState()**（v1.3.2 漏了，导致黄框黄把手完全出不来）：
    /// 状态同步在 `canvas.r` 上，光改 `self.editFade` 画布并不知道；
    /// 而 `draw` 里的判断是 `r.editFade > 0.01`，不同步就永远是 0 → 整个编辑态被跳过。
    /// 凡是改完会影响画布的状态，都要用这一处出口，别散着写。
    private func animateEditFade(to target: Double) {
        UIView.animate(withDuration: BKConfig.RegionEdit.fadeSec,
                       delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.editFade = target
            self.syncEditState()
            self.redrawVisible()
        }
    }

    /// 双指捏合缩放。刻度是「整条素材摊成几屏宽」，1 屏 = 全览，20 屏 = 贴脸。
    ///
    /// 【为什么锚点取手指中点而不是屏幕正中】
    /// 屏幕正中是橙色指针。你两根手指明明捏在左边第 5 秒那个气口上，
    /// 结果放大的是正中间第 20 秒 —— 想看的东西一放大就跑出屏幕了。
    /// 钉住手指底下那一刻才是符合直觉的。
    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchBaseZoom = zoomScreens
            let sx = g.location(in: self).x
            pinchAnchorX = sx
            // 屏幕坐标 → 画布坐标：加上当前的滚动偏移
            pinchAnchorTime = timeAt(canvasX: scroll.contentOffset.x + sx)
        case .changed:
            applyZoom(pinchBaseZoom * g.scale,
                      anchorTime: pinchAnchorTime,
                      anchorScreenX: pinchAnchorX)
            delegate?.track(self, didChangeZoomTo: zoomScreens)
        default:
            break
        }
    }
}

// MARK: - 滚动回调

extension BKTrackView: UIScrollViewDelegate {

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 播放时是代码在推滚动 —— 这时候再去 seek 播放器就成死循环了
        guard !programmatic else { return }
        delegate?.track(self, didScrollTo: currentTime)
    }

    /// 手指一碰轨道就上报。播放中收到它就 pause —— 比等到「滚起来了」再停要早一帧，
    /// 那一帧的差别就是「拖动会不会漏出一点声音」
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        delegate?.trackDidTouchDown(self)
    }

    /// 越界换素材的判定**放在松手那一刻**，不在滚动过程中。
    ///
    /// 两个原因：
    /// 1. 定稿写的是「拽超过 60pt **再松手**」—— 判定点是松手，不是拖动中
    /// 2. 滚动过程中系统会有一段回弹动画，那期间 contentOffset 也在动，
    ///    中途判定会在回弹路上误触发第二次
    ///
    /// ⚠️ 判的是「越界了多少」，**不判手指速度** ——
    /// 慢悠悠拖过头也算数，快甩一下但没过阈值也不算。
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard allowsSiblingSwitch else { return }
        let threshold = BKConfig.Layout.siblingPullThreshold
        let x = scrollView.contentOffset.x
        let maxX = CGFloat(duration) * pps
        if x < -threshold {
            delegate?.trackDidPullBeyondHead(self)
        } else if x > maxX + threshold {
            delegate?.trackDidPullBeyondTail(self)
        }
    }
}

// MARK: - 画布

// 全部标 fileprivate：它们是这个文件内部的绘制助手，本身不该对外可见。
// 一旦成员是 private 类型而属性是 internal，编译器会直接报
// "property must be declared private because its type uses a private type"
fileprivate struct TrackRender {
    var pad: CGFloat = 0
    var pps: CGFloat = 60
    var duration: Double = 0
    var thresholdDb: Double = -35
    var envelope: BKEnvelope?
    var pieces: [BKMark] = []
    var splits: [Double] = []

    /// v1.3.0 折叠映射：成品时间 → 原片时间。
    ///
    /// 【为什么必须有它】删红键折叠后，轨道画布的 duration 变成**成品时长**（比原片短），
    /// 但 `envelope` 的波形包络是按**原片时间轴**算的。
    /// 波形绘制里 `env.peak(from: t0, to: t1)` 的 t 是「画布上的时间」，
    /// 直接拿它查包络就会查到原片更靠后的位置 —— **波形会画错位置**（能画出来，但不对）。
    ///
    /// 映射表 = 折叠后的绿段 [(成品起点, 原片起点, 时长)]，与 BKJointBuilder 的 segments 同构。
    /// nil = 没折叠，成品时间就是原片时间，直接用。
    var foldMap: [(out: Double, src: Double, dur: Double)]?

    /// 画布时间（折叠后的成品时间）→ 波形包络该查的原片时间
    func sourceTime(_ t: Double) -> Double {
        guard let map = foldMap, !map.isEmpty else { return t }
        for seg in map {
            if t >= seg.out && t <= seg.out + seg.dur {
                return seg.src + (t - seg.out)
            }
        }
        // 落在缝隙里（理论上不该发生，normalize 保证严丝合缝）：夹到最近的边界
        if let first = map.first, t < first.out { return first.src }
        if let last = map.last { return last.src + last.dur }
        return t
    }

    // MARK: v1.3.0 区域编辑态（由 BKTrackView 每帧同步进来）

    /// 拖动中的临时区间。**拖动中不改 marks**，只改这里（松手才提交）。
    /// nil = 没在拖。`editing` 优先用它。
    var dragPreview: (start: Double, end: Double)?
    /// 当前编辑中的区间。拖动中用 `dragPreview`（拖动中不改 marks，只改这里）
    var editing: (start: Double, end: Double)? { dragPreview ?? editingBase }
    /// 进入编辑态时那段（拖动中不变，作为回退）
    var editingBase: (start: Double, end: Double)?
    /// 淡入进度 0~1
    var editFade: Double = 0
    /// 正在拖哪一端：0 = 无，1 = 开头，2 = 结尾
    var draggingHandle: Int = 0
    /// 【v1.3.3】是否处于「一键去红已应用」状态。
    /// 折叠后波形连成一片，但**区与区的分割线要保留**（每个绿区仍可长按编辑），
    /// 靠 `pieces` 里插的零长度标记（start == end）来定位分割线。
    var redFolded: Bool = false
}

fileprivate final class TrackCanvas: UIView {

    fileprivate var r = TrackRender()

    /// 把手尺寸（定稿第 1.1 节：4×8pt 小白条）
    private let handleW: CGFloat = 4
    private let handleH: CGFloat = 8

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let pad = r.pad
        let pps = r.pps
        guard pps > 0 else { return }

        let h = bounds.height
        let contentLen = CGFloat(r.duration) * pps
        let waveTop: CGFloat = 16
        let waveH = max(10, h - waveTop - 10)
        let mid = waveTop + waveH / 2
        let amp = waveH / 2 - 3

        // 【2026-10-04 性能：只画脏矩形覆盖的列，别每帧重画整条波形】
        // 放大 20 屏时画布宽 7800pt，而屏幕只看得见 390pt —— 全量重画 = 95% 白画，
        // 每根柱还查一次 env.peak(from:to:)，拖接缝时每秒 60 次，卡顿就是这么来的。
        // rect 是 canvas 的**局部坐标**（draw 的入参），要减掉 pad 才是列下标。
        // 上下各多留 1 列做保险，避免边界处出现 1px 缝。
        let c0 = max(0, Int(floor(rect.minX - pad)) - 1)
        let c1 = min(Int(ceil(rect.maxX - pad)) + 1, Int(contentLen) + 1)

        // 轨道底色（浅绿 #C7D8BD）
        if contentLen > 0 {
            ctx.setFillColor(BKTheme.Color.track.cgColor)
            ctx.fill(CGRect(x: pad, y: waveTop, width: contentLen, height: waveH))
        }

        // 波形本体：逐像素列取区间峰值，一遍 O(可见列数) 画完
        if let env = r.envelope, contentLen > 1, c1 > c0 {
            let path = CGMutablePath()
            for c in c0 ..< c1 {
                let t0 = Double(c) / Double(pps)
                guard t0 < r.duration else { break }
                let t1 = min(Double(c + 1) / Double(pps), r.duration)
                // v1.3.0：折叠后画布时间是成品时间，包络是原片时间，必须过映射表。
                // 不换的话波形会整体画错位置（能画出来，但和绿区对不上）。
                let s0 = r.sourceTime(t0)
                let s1 = r.sourceTime(t1)
                let peak = Double(env.peak(from: s0, to: s1))
                let conv = min(max((peak - dbLo) / (dbHi - dbLo), 0.0), 1.0)
                let half = CGFloat(conv) * amp
                if half < 0.5 { continue }
                path.addRect(CGRect(x: pad + CGFloat(c), y: mid - half, width: 1, height: half * 2))
            }
            ctx.setFillColor(BKTheme.Color.wave.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }

        // 待删除区间：粉红半透明覆盖 + 两侧边界线
        // 【2026-10-04】同样只画与脏矩形相交的那些段 —— 段数多时（几十段）逐段画也不便宜
        for pc in r.pieces where pc.kind == .cut {
            let x0 = pad + CGFloat(pc.start) * pps
            let x1 = pad + CGFloat(pc.end) * pps
            if x1 < rect.minX || x0 > rect.maxX { continue }
            ctx.setFillColor(BKTheme.Color.cut.cgColor)
            ctx.fill(CGRect(x: x0, y: waveTop, width: max(1, x1 - x0), height: waveH))

            ctx.setStrokeColor(BKTheme.Color.cutLine.cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: x0, y: waveTop))
            ctx.addLine(to: CGPoint(x: x0, y: waveTop + waveH))
            ctx.move(to: CGPoint(x: x1, y: waveTop))
            ctx.addLine(to: CGPoint(x: x1, y: waveTop + waveH))
            ctx.strokePath()
        }

        // 手动切口：把这一竖条挖成页面底色，再在两侧各画一条描边 ——
        // 看上去是真被剪开的一道缝，而不是一条线。视觉上「切开」这件事必须看得见
        for s in r.splits {
            let x = pad + CGFloat(s) * pps
            if x < rect.minX - 4 || x > rect.maxX + 4 { continue }
            ctx.setFillColor(BKTheme.Color.page.cgColor)
            ctx.fill(CGRect(x: x - 2, y: waveTop, width: 4, height: waveH))
            ctx.setStrokeColor(BKTheme.Color.selection.cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: x - 2, y: waveTop))
            ctx.addLine(to: CGPoint(x: x - 2, y: waveTop + waveH))
            ctx.move(to: CGPoint(x: x + 2, y: waveTop))
            ctx.addLine(to: CGPoint(x: x + 2, y: waveTop + waveH))
            ctx.strokePath()
        }

        // 阈值虚线：低于这条线的才算静音（黄 #EF9F27）
        let conv = min(max((r.thresholdDb - dbLo) / (dbHi - dbLo), 0.0), 1.0)
        let ty = mid - CGFloat(conv) * amp
        ctx.setStrokeColor(BKTheme.Color.warning.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        // 虚线只画可见段（画 7800pt 长的虚线本身也贵）
        let lineX0 = max(pad, rect.minX)
        let lineX1 = min(pad + contentLen, rect.maxX)
        if lineX1 > lineX0 {
            ctx.move(to: CGPoint(x: lineX0, y: ty))
            ctx.addLine(to: CGPoint(x: lineX1, y: ty))
            ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])

        // 边界把手：粉红块两端各一枚小白条
        //
        // 【v1.3.3 删除】原来这里给红区两端画白色小把手（4×8pt）。
        // 去掉的原因（皓哥 18:41 定）：
        //   ① 视觉上有**两套把手**（白色小条 + 长按出现的黄把手），用户要分辨「哪个能拖」
        //   ② 红绿区待遇不平等（红区有把手、绿区没有）—— 而实际上两者都该长按进编辑态
        // 现在统一成一套：**长按任意段 → 黄框 + 两端黄把手**（见文件末尾的编辑态绘制）。
        // 「被切开」这件事改由**分割线**表达（见下面 foldedSeams 的绘制）。

        // 【v1.3.3】已删除状态下的区分割线。
        //
        // 分割线是「区的分隔」不是「删除的痕迹」：红区删掉后波形连成一片，
        // 但每个绿区仍是独立可编辑单元（要能长按它），所以要画出边界。
        // 画法沿用手动切口那套「挖成页面底色 + 两侧描边」——「被切开」必须看得见。
        //
        // 缝宽随缩放自适应：折叠后段很密（样片 29 段 / 成品 10.5s），
        // 1 屏时每段只 22px，固定 4px 缝会占 18%、轨道碎成筛子。
        if r.redFolded {
            let ppsRef = pps
            // 每 px 代表多少秒 → 缝宽取「不超过该段宽度 1/6」，并夹在 1...4pt
            let segTypical = max(1.0 / max(ppsRef, 0.001), 0.001)
            let gap = min(max(CGFloat(segTypical * ppsRef) / 6.0, 1), 4)
            for seg in r.pieces where seg.duration <= 1e-9 {
                let x = pad + CGFloat(seg.start) * pps
                if x < rect.minX - 8 || x > rect.maxX + 8 { continue }
                ctx.setFillColor(BKTheme.Color.page.cgColor)
                ctx.fill(CGRect(x: x - gap / 2, y: waveTop, width: gap, height: waveH))
                ctx.setStrokeColor(BKTheme.Color.selection.cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: x - gap / 2, y: waveTop))
                ctx.addLine(to: CGPoint(x: x - gap / 2, y: waveTop + waveH))
                ctx.move(to: CGPoint(x: x + gap / 2, y: waveTop))
                ctx.addLine(to: CGPoint(x: x + gap / 2, y: waveTop + waveH))
                ctx.strokePath()
            }
        }

        // 时间刻度：每 5 秒一个小齿
        if r.duration > 0 {
            ctx.setStrokeColor(BKTheme.Color.text3.cgColor)
            ctx.setLineWidth(0.5)
            var t: Double = 0
            while t <= r.duration {
                let tx = pad + CGFloat(t) * pps
                if tx >= rect.minX - 4 && tx <= rect.maxX + 4 {
                    ctx.move(to: CGPoint(x: tx, y: h - 6))
                    ctx.addLine(to: CGPoint(x: tx, y: h))
                }
                t += 5
            }
            ctx.strokePath()
        }

        // ── v1.3.0 区域编辑态 ──────────────────────────────
        // 黄边包住选中区 + 两端各一个黄色拖拽把手（定稿 4.3 / 拖拽把手样式.svg）
        // 尺寸全部从 BKConfig.RegionEdit 读，规格只在那一处改。
        if let seg = r.editing, r.editFade > 0.01 {
            // ⚠️ 不能写 `let cfg = BKConfig.RegionEdit` —— 那是嵌套 **类型**不是值，
            // Swift 会报 "expected member name or initializer call after type name"。
            // 直接用全限定名取它的静态常量。
            let alpha = CGFloat(max(0, min(1, r.editFade)))
            let x0 = pad + CGFloat(seg.start) * pps
            let x1 = pad + CGFloat(seg.end) * pps
            let box = CGRect(x: x0, y: waveTop, width: max(1, x1 - x0), height: waveH)
            // 不在可见区就整个跳过
            if box.maxX >= rect.minX - 48 && box.minX <= rect.maxX + 48 {
                let bw = CGFloat(BKConfig.RegionEdit.selectionBorderWidth)
                let corner = CGFloat(BKConfig.RegionEdit.selectionCorner)

                // ① 框内压暗蒙层（参照图 2：编辑态下框内整体发暗，与框外对比）
                //    这一层是「我正在编辑这一段」的最强信号，比光有黄框明确得多
                let dim = CGFloat(BKConfig.RegionEdit.selectionDimAlpha) * alpha
                if dim > 0.01 {
                    ctx.saveGState()
                    ctx.setFillColor(BKTheme.Color.selection.cgColor)
                    ctx.setAlpha(dim)
                    ctx.fill(box)
                    ctx.restoreGState()
                }

                ctx.saveGState()
                ctx.setAlpha(alpha)

                // ② 3pt 圆角黄框。圆角要向内缩半个线宽，否则描边有一半露在框外
                ctx.setStrokeColor(BKTheme.Color.warning.cgColor)
                ctx.setLineWidth(bw)
                let border = CGRect(x: box.minX + bw / 2, y: box.minY + bw / 2,
                                    width: max(0.5, box.width - bw),
                                    height: max(0.5, box.height - bw))
                let borderPath = CGPath(roundedRect: border,
                                        cornerWidth: corner, cornerHeight: corner,
                                        transform: nil)
                ctx.addPath(borderPath)
                ctx.strokePath()
                ctx.restoreGState()

                // ③ 两端把手：**框外紧贴的小圆角方块**（参照图）
                //
                // ⚠️⚠️ v1.3.0~1.4.4 的最大设计错误：把手续了「贯穿整个轨道高度的竖条」，
                //    既挡内容又不像「可拖」。参照图是 20×20pt 左右的小方块，
                //    垂直居中，贴在框外侧。
                // ⚠️ 箭头是**黑色**（在黄底上），不是白色。
                let size = CGFloat(BKConfig.RegionEdit.handleSize)
                let cr = CGFloat(BKConfig.RegionEdit.handleCorner)
                let gap = CGFloat(BKConfig.RegionEdit.handleGap)
                let aLen = CGFloat(BKConfig.RegionEdit.handleArrowLen) / 2
                let aW = CGFloat(BKConfig.RegionEdit.handleArrowWidth)
                let hs = size / 2

                for (edgeX, isHead, isDragging) in [(box.minX, true, r.draggingHandle == 1),
                                                    (box.maxX, false, r.draggingHandle == 2)] {
                    // 只画可见那一侧（把手悬在框外，留 24pt 余量）
                    if edgeX < rect.minX - 30 || edgeX > rect.maxX + 30 { continue }
                    // 中心：框边 + gap，再往框外偏半个方块
                    let cx = edgeX + (isHead ? -(gap + hs) : (gap + hs))
                    let cy = box.midY
                    // ⚠️ 变量名别叫 `rect` —— 它会遮蔽 `draw(_ rect:)` 的参数，
                    // 下面判可见性时用到的是外层那个脏矩形，一混淆就是隐蔽 bug
                    let hRect = CGRect(x: cx - hs, y: cy - hs, width: size, height: size)
                    if hRect.maxX < rect.minX - 20 || hRect.minX > rect.maxX + 20 { continue }

                    ctx.saveGState()
                    ctx.setAlpha(alpha)
                    // 拖动时放大 1.15 倍，给「你正捏着它」的实感
                    let scale: CGFloat = isDragging ? 1.15 : 1.0
                    let drawRect = CGRect(x: cx - hs * scale, y: cy - hs * scale,
                                          width: size * scale, height: size * scale)
                    let pill = CGPath(roundedRect: drawRect,
                                      cornerWidth: cr, cornerHeight: cr, transform: nil)
                    // 黄底
                    ctx.setFillColor(BKTheme.Color.warning.cgColor)
                    ctx.addPath(pill)
                    ctx.fillPath()
                    // 黑色箭头：左端尖头朝左 ‹，右端尖头朝右 ›
                    //
                    // ⚠️⚠️ v1.4.6 修：之前**左右反了**（2026-10-04 20:33 皓哥截图）。
                    // 原因：折线的「尖端」应该在 `dir` 指向的那一侧，我却把
                    // 尖端放在了 `-dir` 那一侧 —— 画出来左端是 `>`、右端是 `<`。
                    //
                    // 正确画法：尖端在 `dir` 方向，两条尾巴在 `-dir` 方向。
                    //   dir = -1（左端）：尖端在 cx - aLen，尾巴在 cx + aLen → ‹
                    //   dir = +1（右端）：尖端在 cx + aLen，尾巴在 cx - aLen → ›
                    let dir: CGFloat = isHead ? -1 : 1
                    let tipX = cx + dir * aLen * scale
                    let tailX = cx - dir * aLen * scale
                    let aH = aLen * scale
                    ctx.setStrokeColor(BKTheme.Color.selection.cgColor)
                    ctx.setLineWidth(aW * scale)
                    ctx.setLineCap(.round)
                    ctx.setLineJoin(.round)
                    ctx.move(to: CGPoint(x: tailX, y: cy - aH))
                    ctx.addLine(to: CGPoint(x: tipX, y: cy))
                    ctx.addLine(to: CGPoint(x: tailX, y: cy + aH))
                    ctx.strokePath()
                    ctx.restoreGState()
                }
            }
        }
    }
}

// MARK: - 中置指针

/// 钉在正中央不动的橙色指针：顶部一个倒三角 + 一条竖线。
/// 参考图里就是这副样子，倒三角的作用是让人一眼认出「这才是当前位置」
fileprivate final class TrackPointer: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let cx = bounds.width / 2
        ctx.setFillColor(BKTheme.Color.playhead.cgColor)

        let tri = CGMutablePath()
        tri.move(to: CGPoint(x: cx - 5, y: 0))
        tri.addLine(to: CGPoint(x: cx + 5, y: 0))
        tri.addLine(to: CGPoint(x: cx, y: 7))
        tri.closeSubpath()
        ctx.addPath(tri)
        ctx.fillPath()

        ctx.fill(CGRect(x: cx - 1, y: 4, width: 2, height: bounds.height - 4))
    }
}
