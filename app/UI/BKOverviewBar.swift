//
//  BKOverviewBar.swift
//  bk剪辑 — 概览条（定稿第 4.4 节）
//
//  【它解决什么问题】
//  主轨道是「放大镜」：指针钉在中央，你只能看到身边这一屏。放大之后
//  很容易失去全局感 —— 不知道自己现在站在整条素材的哪个位置，
//  也不知道前面还有几刀没处理。概览条就是那个永远显示全局的小地图。
//
//  【为什么必须缓存缩略波形】
//  播放时指针每 1/30 秒动一次，视窗框就得跟着重画一次。
//  如果每次重画都把整条包络重新扫一遍（42 秒素材 ≈ 350 列 × 每列上百帧），
//  那是每秒一百万次浮点运算，纯属浪费 —— 而真正在动的只有一个橙框。
//  所以缩略波形只在「素材 / 宽度 / 刀口」变化时算一次，之后只重画框。
//
//  【点它任意位置 = 直接跳过去】
//  这是它存在的第二个意义：在放大状态下，想从 5 秒跳到 38 秒，
//  靠拖主轨道得划好几下，点概览条一下就到。
//

import UIKit

protocol BKOverviewBarDelegate: AnyObject {
    func overview(_ bar: BKOverviewBar, didSeekTo time: Double)
}

final class BKOverviewBar: UIView {

    weak var delegate: BKOverviewBarDelegate?

    // MARK: - 数据

    private var duration: Double = 0
    private var cuts: [(Double, Double)] = []
    private var viewport: (start: Double, end: Double) = (0, 0)
    /// 包络留在手里：旋转屏幕导致宽度变化时要拿它重算缩略波形，
    /// 而 setViewport 那个轻量入口是不带包络的
    private var envelope: BKEnvelope?

    /// 缓存的缩略波形（每列一个 0~1 的归一化高度）
    private var peaks: [CGFloat] = []
    private var peaksWidth: CGFloat = 0

    /// v1.3.0 折叠映射 [(成品起点, 原片起点, 时长)]。nil = 未折叠。
    /// 折叠后 duration 是成品时长、envelope 是原片时间轴，靠它换算。
    private var foldMap: [(out: Double, src: Double, dur: Double)]?
    /// 映射表段数签名。折叠/取消折叠时用来判断缓存的 peaks 作废了
    /// （宽度没变但时间轴变了，只按宽度判缓存会画出上一次的波形）
    private var foldMapSignature: Int = -1

    private let dbLo: Double = -70
    private let dbHi: Double = -5

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
        isUserInteractionEnabled = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        addGestureRecognizer(pan)
    }

    // MARK: - 对外接口

    func setContent(envelope: BKEnvelope?,
                    pieces: [BKMark],
                    duration: Double,
                    viewport: (start: Double, end: Double),
                    foldMap: [(out: Double, src: Double, dur: Double)]? = nil) {
        self.duration = duration
        self.cuts = pieces.filter { $0.kind == .cut }.map { ($0.start, $0.end) }
        self.viewport = viewport
        self.envelope = envelope
        self.foldMap = foldMap
        // 换了素材 / 换了时长映射，缓存的峰值就作废了，必须重算。
        // 原来只按宽度判断缓存，折叠切换时宽度没变 → 会画出上一次的波形
        if let m = foldMap {
            let sig = m.count
            if sig != foldMapSignature { foldMapSignature = sig; peaks = [] }
        }
        rebuildPeaks()
        setNeedsDisplay()
    }

    /// 视窗框每帧都在动，走这个轻量入口：只更新框，不重算波形
    func setViewport(_ viewport: (start: Double, end: Double)) {
        self.viewport = viewport
        setNeedsDisplay()
    }

    // MARK: - 缩略波形

    private func rebuildPeaks() {
        let w = bounds.width
        guard w > 1, duration > 0, let env = envelope else {
            peaks = []
            peaksWidth = w
            return
        }
        // 宽度没变、素材也没变，就没必要重算
        if abs(peaksWidth - w) < 0.5 && !peaks.isEmpty { return }

        let cols = max(1, Int(w))
        var out = [CGFloat]()
        out.reserveCapacity(cols)
        for c in 0 ..< cols {
            let t0 = duration * Double(c) / Double(cols)
            let t1 = duration * Double(c + 1) / Double(cols)
            // v1.3.0 折叠：概览条和主轨道一样，duration 是成品时长、包络是原片时间轴，
            // 必须过映射表反查回原片时间，否则缩略波形整体画错位置
            let peak = Double(env.peak(from: sourceTime(t0), to: sourceTime(t1)))
            let conv = min(max((peak - dbLo) / (dbHi - dbLo), 0.0), 1.0)
            out.append(CGFloat(conv))
        }
        peaks = out
        peaksWidth = w
    }

    /// 画布时间（成品时间）→ 波形包络该查的原片时间。
    /// 与 BKTrackView.TrackRender.sourceTime 同一套逻辑，折叠时才需要映射。
    private func sourceTime(_ t: Double) -> Double {
        guard let map = foldMap, !map.isEmpty else { return t }
        for seg in map {
            if t >= seg.out && t <= seg.out + seg.dur {
                return seg.src + (t - seg.out)
            }
        }
        if let first = foldMap.first, t < first.out { return first.src }
        if let last = foldMap.last { return last.src + last.dur }
        return t
    }

    // MARK: - 绘制

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let w = bounds.width
        let h = bounds.height
        guard w > 1, h > 1 else { return }

        // 底：灰 #8F9389，圆角
        let bgPath = CGPath(roundedRect: bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.setFillColor(BKTheme.Color.ovBg.cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()

        let inset: CGFloat = 4
        let midY = h / 2
        let amp = (h - inset * 2) / 2

        // 缩略波形：深灰 #4C5049
        if !peaks.isEmpty {
            ctx.setFillColor(BKTheme.Color.ovWave.cgColor)
            let path = CGMutablePath()
            for (c, conv) in peaks.enumerated() {
                let half = conv * amp
                if half < 0.4 { continue }
                path.addRect(CGRect(x: CGFloat(c), y: midY - half, width: 1, height: half * 2))
            }
            ctx.addPath(path)
            ctx.fillPath()
        }

        guard duration > 0 else { return }
        let scale = w / CGFloat(duration)

        // 已被删掉的气口：粉红 60%。
        // 定稿原文只写了「灰底小波形 + 橙色视窗框」，这一层是实操补的 ——
        // 概览条上不标气口，你就看不出「前面还有几刀没处理」
        ctx.setFillColor(BKTheme.Color.cut.cgColor)
        for (s, e) in cuts {
            let x0 = CGFloat(s) * scale
            let x1 = CGFloat(e) * scale
            ctx.fill(CGRect(x: x0, y: inset, width: max(1, x1 - x0), height: h - inset * 2))
        }

        // 视窗框：橙 #F09A28 描边 + 极淡填充。
        // 填满不透明会把底下的波形盖掉，那就失去「看全局」的意义了
        let vx0 = max(0, CGFloat(viewport.start) * scale)
        let vx1 = min(w, CGFloat(viewport.end) * scale)
        let box = CGRect(x: vx0, y: 1, width: max(3, vx1 - vx0), height: h - 2)
        ctx.setFillColor(BKTheme.Color.playhead.withAlphaComponent(0.12).cgColor)
        ctx.fill(box)
        ctx.setStrokeColor(BKTheme.Color.playhead.cgColor)
        ctx.setLineWidth(2)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.strokePath()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 宽度变了，缓存的缩略波形就作废 —— 立刻用留在手里的包络重算，
        // 否则旋转屏幕之后概览条会变成一条光秃秃的灰杠
        if abs(peaksWidth - bounds.width) > 0.5 {
            peaks = []
            peaksWidth = bounds.width
            rebuildPeaks()
            setNeedsDisplay()
        }
    }

    // MARK: - 手势

    private func timeAt(x: CGFloat) -> Double {
        guard bounds.width > 1 else { return 0 }
        return min(max(Double(x / bounds.width) * duration, 0), duration)
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        delegate?.overview(self, didSeekTo: timeAt(x: g.location(in: self).x))
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            delegate?.overview(self, didSeekTo: timeAt(x: g.location(in: self).x))
        default:
            break
        }
    }
}
