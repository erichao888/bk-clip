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

protocol BKTrackViewDelegate: AnyObject {
    /// 内容被滚动了。time 是当前指针所指的时间
    func track(_ view: BKTrackView, didScrollTo time: Double)
    /// 点了一下一个片段
    func track(_ view: BKTrackView, didTogglePieceAt time: Double)
    /// 手指摸上了一条边界，拖动开始。VC 收到它就该开「合并提交」，
    /// 否则拖动过程中每一帧都入一次撤销栈，撤一次只退一帧
    func track(_ view: BKTrackView, didBeginBoundaryDragNear time: Double)
    /// 拖某条分界线。near 是起手时的旧位置，newTime 是要挪到的新位置
    func track(_ view: BKTrackView, didDragBoundaryNear near: Double, to newTime: Double)
    /// 手指离开，拖动结束
    func trackDidEndBoundaryDrag(_ view: BKTrackView)
    /// 缩放变了（滑杆或双指捏合）。screens 是「整条素材摊成几屏宽」
    func track(_ view: BKTrackView, didChangeZoomTo screens: CGFloat)
    /// 手指一碰轨道。**正在播放时收到它就该立刻 pause**（定稿 4.5.1），
    /// 晚一步就会在拖动的第一帧漏出一点声音
    func trackDidTouchDown(_ view: BKTrackView)
    /// 已经在片头，松手时还被往右拽过 60pt → 该换上一条了（定稿 4.5.3）
    func trackDidPullBeyondHead(_ view: BKTrackView)
    /// 已经在片尾，松手时还被往左拽过 60pt → 该换下一条了
    func trackDidPullBeyondTail(_ view: BKTrackView)
}

final class BKTrackView: UIView {

    weak var delegate: BKTrackViewDelegate?

    private let scroll = UIScrollView()
    private let canvas = TrackCanvas()
    private let pointer = TrackPointer()
    private var pan: UIPanGestureRecognizer!
    private var tap: UITapGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!

    private var duration: Double = 0
    private var pps: CGFloat = 60
    private var lastWidth: CGFloat = 0
    /// 程序滚动的标志：播放时是代码在推 contentOffset，别再回调给外部去 seek
    private var programmatic = false
    private var draggedEdge: Double?
    private var pinchBaseZoom: CGFloat = 6
    /// 捏合时钉住的那一点：手指中点底下对应的时间，以及它在屏幕上的横坐标
    private var pinchAnchorTime: Double = 0
    private var pinchAnchorX: CGFloat = 0

    /// 整条素材摊成几屏宽。默认 6 屏：再密手指抹不开，再松就看不见气口
    private(set) var zoomScreens: CGFloat = 6

    /// 允不允许「拖到头再拽」换素材。只有一条素材 / 正在加载时由外部关掉
    var allowsSiblingSwitch = true

    /// 缩放上下限。1 屏 = 全览（看全局），20 屏 = 贴脸（单帧级微调）
    static let zoomMin: CGFloat = 1
    static let zoomMax: CGFloat = 20

    /// 手指离边界多近才算「摸到了把手」。把手本身只有 4pt 宽，
    /// 但手指不是鼠标 —— 按 4pt 判定基本抓不住
    private static let handleGrabTolerance: CGFloat = 20

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

        pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.delegate = self
        // 只认单指。默认是允许多指的，那样双指捏合时拖边界的 pan 也会跟着起手，
        // 一边缩放一边把刀口拖跑了
        pan.maximumNumberOfTouches = 1
        canvas.addGestureRecognizer(pan)

        tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        tap.delegate = self
        canvas.addGestureRecognizer(tap)

        pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        pinch.delegate = self
        canvas.addGestureRecognizer(pinch)
    }

    // MARK: - 对外接口

    func setContent(envelope: BKEnvelope?,
                    pieces: [BKMark],
                    splits: [Double],
                    duration: Double,
                    thresholdDb: Double) {
        let keep = currentTime
        self.duration = duration
        canvas.r.envelope = envelope
        canvas.r.pieces = pieces
        canvas.r.splits = splits
        canvas.r.duration = duration
        canvas.r.thresholdDb = thresholdDb
        relayout(keepPointerTime: keep)
        canvas.setNeedsDisplay()
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
        canvas.setNeedsDisplay()
    }

    // MARK: - 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1 else { return }
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            relayout(keepPointerTime: currentTime)
            canvas.setNeedsDisplay()
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

    /// 找离 t 最近的一条内部边界（素材首尾不算）
    private func nearestBoundary(to t: Double) -> Double? {
        var best: Double?
        // 超过 0.6 秒就不算摸到：不然手指一放下去就抓住远处的刀
        var bestDist = 0.6
        for pc in canvas.r.pieces {
            for edge in [pc.start, pc.end] where edge > 0.001 && edge < duration - 0.001 {
                let d = abs(edge - t)
                if d < bestDist { bestDist = d; best = edge }
            }
        }
        return best
    }
}

// MARK: - 手势

extension BKTrackView: UIGestureRecognizerDelegate {

    /// 只有真的摸到分界线，自定义 pan 才接管；否则一律放行给 UIScrollView 去滚。
    /// 注意这是 UIView 自带的方法，必须 override —— 直接写 func 会报
    /// "overriding declaration requires an 'override' keyword"
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return true }
        let x = gestureRecognizer.location(in: canvas).x
        guard let edge = nearestBoundary(to: timeAt(canvasX: x)) else { return false }
        return abs(canvasX(of: edge) - x) <= BKTrackView.handleGrabTolerance
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let here = g.location(in: canvas)
        switch g.state {
        case .began:
            // 关掉滚动，否则拖拉的同时整条内容会跟着漂走
            scroll.isScrollEnabled = false
            draggedEdge = nearestBoundary(to: timeAt(canvasX: here.x))
            if let edge = draggedEdge {
                delegate?.track(self, didBeginBoundaryDragNear: edge)
            }
        case .changed:
            guard let from = draggedEdge else { return }
            delegate?.track(self, didDragBoundaryNear: from, to: timeAt(canvasX: here.x))
        case .ended, .cancelled, .failed:
            if draggedEdge != nil {
                delegate?.trackDidEndBoundaryDrag(self)
            }
            draggedEdge = nil
            scroll.isScrollEnabled = true
        default:
            break
        }
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        let t = timeAt(canvasX: g.location(in: canvas).x)
        guard t >= 0, t <= duration else { return }
        delegate?.track(self, didTogglePieceAt: t)
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

        // 轨道底色（浅绿 #C7D8BD）
        if contentLen > 0 {
            ctx.setFillColor(BKTheme.Color.track.cgColor)
            ctx.fill(CGRect(x: pad, y: waveTop, width: contentLen, height: waveH))
        }

        // 波形本体：逐像素列取区间峰值，一遍 O(帧数) 画完
        if let env = r.envelope, contentLen > 1 {
            let cols = Int(contentLen)
            let path = CGMutablePath()
            for c in 0 ..< cols {
                let t0 = Double(c) / Double(pps)
                guard t0 < r.duration else { break }
                let t1 = min(Double(c + 1) / Double(pps), r.duration)
                let peak = Double(env.peak(from: t0, to: t1))
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
        for pc in r.pieces where pc.kind == .cut {
            let x0 = pad + CGFloat(pc.start) * pps
            let x1 = pad + CGFloat(pc.end) * pps
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
        ctx.move(to: CGPoint(x: pad, y: ty))
        ctx.addLine(to: CGPoint(x: pad + contentLen, y: ty))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // 边界把手：粉红块两端各一枚小白条（定稿：#FFFFFF 4×8pt）
        // 白压在浅绿上边界会糊，加一道极淡的灰边把它提出来
        for pc in r.pieces where pc.kind == .cut {
            for edge in [pc.start, pc.end] {
                let x = pad + CGFloat(edge) * pps
                let box = CGRect(x: x - handleW / 2,
                                 y: mid - handleH / 2,
                                 width: handleW,
                                 height: handleH)
                let rounded = CGPath(roundedRect: box, cornerWidth: 1.5, cornerHeight: 1.5,
                                     transform: nil)
                ctx.setFillColor(BKTheme.Color.handle.cgColor)
                ctx.setStrokeColor(BKTheme.Color.handleLine.cgColor)
                ctx.setLineWidth(0.5)
                ctx.addPath(rounded)
                ctx.drawPath(using: .fillStroke)
            }
        }

        // 时间刻度：每 5 秒一个小齿
        if r.duration > 0 {
            ctx.setStrokeColor(BKTheme.Color.text3.cgColor)
            ctx.setLineWidth(0.5)
            var t: Double = 0
            while t <= r.duration {
                let tx = pad + CGFloat(t) * pps
                ctx.move(to: CGPoint(x: tx, y: h - 6))
                ctx.addLine(to: CGPoint(x: tx, y: h))
                t += 5
            }
            ctx.strokePath()
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
