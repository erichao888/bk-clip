//
//  BKMainTrackView.swift
//  bk剪辑 — v2 主编辑页 · 多片段主轨视图
//
//  【三层堆叠，共享同一条时间轴】（原型 index.html .trow.main 的规格）
//      画面帧条  60px —— 约 1.2s 一帧铺满整个块（竞品同款，别画成单张拉伸图）
//      声音包络  40px —— 绿渐变 #3ECC77→#239554 从底线填充；只画保留区，
//                        ★ 主轨不画红罩/红折叠线（红绿气口语义只属于波剪页）
//      时间刻度  13px —— 每秒短刻度，每 5s 长刻度 + 文字
//
//  【为什么另起一个视图，不去改 BKTrackView】
//  BKTrackView 是**单素材波形**视图（画包络线 + 红绿区 + 拖把手），波剪子页还在用它，
//  2A 刚迁完 v2、不能动。主轨是多片段语义，两者画的东西完全不同，各管各的。
//
//  【坐标：为什么 centerTime = offset.x / pps —— 半屏余量】
//  内容区左右各留半个屏宽的余量（pad = bounds.width/2），这样第一个和最后一个
//  区块也能滚到屏幕正中接受选中。指针固定在屏幕正中，于是：
//      屏幕中心对应的内容 x = offset.x + pad
//      区块 i 的内容 x 起点  = pad + startOf(i) * pps
//    ⇒ 中心时间 = (offset.x + pad − pad) / pps = offset.x / pps
//
//  【自动蓝框必须遵守的两条约束】规格 §1.4：
//   ① 只在跨过区块边界时才改选中并回调（每像素重绘会卡）。
//   ② 程序化滚动（点选/复制后 scrollTo 居中）期间必须让位（autoFrameLock），
//      否则刚选中的区块会被指针下的旧区块覆盖回去。
//

import UIKit

protocol BKMainTrackViewDelegate: AnyObject {
    /// 自动蓝框选中的区块变了（手拖轨道经过指针）。index = nil 表示指针落在空隙
    func mainTrack(_ view: BKMainTrackView, didAutoSelectBlockAt index: Int?)
    /// 手指点了某个区块
    func mainTrack(_ view: BKMainTrackView, didTapBlockAt index: Int)
    /// 点了轨道空白（区块之间的缝 / 两头余量区）
    func mainTrackDidTapBlank(_ view: BKMainTrackView)
}

final class BKMainTrackView: UIView {

    weak var delegate: BKMainTrackViewDelegate?

    private let scrollView = UIScrollView()
    private let canvas = TrackCanvas()
    /// 指针。刻意放在 scrollView **外面**：它相对屏幕不动，只有内容在动
    private let playhead = UIView()

    private var starts: [Double] = []
    private var durations: [Double] = []
    private var totalSec: Double = 0

    /// 每秒多少点（缩放）。越大 = 时间轴拉得越长
    var pps: CGFloat = 26 { didSet { relayout() } }

    /// 蓝框选中的区块下标
    var selectedIndex: Int? {
        didSet {
            canvas.selectedIndex = selectedIndex
            canvas.setNeedsDisplay()
        }
    }

    /// 程序化滚动期间置 true，禁止自动蓝框改写选中
    var autoFrameLock = false

    /// 指针当前所指的**主轨时间**（trackT）
    var centerTime: Double { Double(scrollView.contentOffset.x / pps) }

    // MARK: - 生命周期

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = BKTheme.Color.bar

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = self
        scrollView.addSubview(canvas)
        addSubview(scrollView)

        playhead.backgroundColor = BKTheme.Color.playhead
        playhead.isUserInteractionEnabled = false
        addSubview(playhead)

        canvas.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onTap(_:))))
    }

    required init?(coder: NSCoder) { fatalError("本 App 不走 storyboard") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        playhead.frame = CGRect(x: bounds.width / 2 - 1, y: 0, width: 2, height: bounds.height)
        relayout()
    }

    // MARK: - 对外

    /// 换一批区块（整条主轨）。starts / durations 由块的 timelineDuration 累加得出
    func setContent(blocks: [BKClipBlock]) {
        canvas.blocks = blocks
        var acc = 0.0
        starts = []
        durations = []
        for b in blocks {
            starts.append(acc)
            // ★ 主轨占位用 timelineDuration（= 折叠后时长 / 倍速），不是 srcDuration
            durations.append(b.timelineDuration)
            acc += b.timelineDuration
        }
        totalSec = acc
        canvas.starts = starts
        canvas.durations = durations
        relayout()
        loadMedia()
    }

    /// 滚到某个主轨时间。autoFrame = false 表示这次是程序化滚动，自动蓝框让位
    func scrollTo(time: Double, autoFrame: Bool = true) {
        autoFrameLock = !autoFrame
        scrollView.setContentOffset(CGPoint(x: CGFloat(time) * pps, y: 0), animated: false)
        autoFrameLock = false
    }

    /// 让第 index 块居中。点选后调它，所以默认 autoFrame = false
    func scrollToBlock(at index: Int, autoFrame: Bool = false) {
        guard index >= 0, index < starts.count else { return }
        scrollTo(time: starts[index] + durations[index] / 2, autoFrame: autoFrame)
    }

    // MARK: - 内部

    private func relayout() {
        guard bounds.width > 0 else { return }
        let pad = bounds.width / 2
        let w = pad * 2 + CGFloat(totalSec) * pps
        scrollView.contentSize = CGSize(width: w, height: bounds.height)
        canvas.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        canvas.pps = pps
        canvas.pad = pad
        canvas.setNeedsDisplay()
    }

    /// 帧条 + 包络的异步供给。只按「块的内容」发请求（与 pps / 屏宽无关），
    /// 所以在 setContent 里发一次就够，回来各自触发一次重画
    private func loadMedia() {
        for b in canvas.blocks {
            // —— 帧条：约 1.2s 一帧（原型 renderThumbs 的密度），单块封顶 30 帧防极端长素材刷爆
            let n = max(1, min(30, Int((b.timelineDuration / 1.2).rounded())))
            for k in 0 ..< n {
                let local = (Double(k) + 0.5) * b.timelineDuration / Double(n)
                let src = Self.srcTime(inBlock: b, localOut: local)
                canvas.requestFrame(localID: b.assetLocalID, srcTime: src)
            }
            // —— 波形：整段素材的包络，画的时候只取保留区
            canvas.requestEnvelope(localID: b.assetLocalID)
        }
    }

    /// 块内时间线偏移（out 坐标，0..timelineDuration）→ 源时间。
    /// 逐段走 keptRanges：每段向时间线贡献 r.length / speed（变速时源时间以 speed 倍速推进）
    static func srcTime(inBlock b: BKClipBlock, localOut l: Double) -> Double {
        var acc = 0.0
        for r in b.keptRanges {
            let seg = r.length / b.speed
            if l <= acc + seg {
                return r.start + (l - acc) * b.speed
            }
            acc += seg
        }
        return b.keptRanges.last?.end ?? 0
    }

    /// 自动蓝框。★ 只在跨过区块边界时才改选中 + 回调（性能关键，别删这个判断）
    private func updateAutoFrame() {
        guard !autoFrameLock else { return }
        let t = centerTime
        var hit: Int? = nil
        for i in 0 ..< starts.count where t >= starts[i] && t <= starts[i] + durations[i] {
            hit = i
            break
        }
        if hit != selectedIndex {
            selectedIndex = hit
            delegate?.mainTrack(self, didAutoSelectBlockAt: hit)
        }
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: canvas)
        let t = Double((p.x - canvas.pad) / pps)
        for i in 0 ..< starts.count where t >= starts[i] && t <= starts[i] + durations[i] {
            delegate?.mainTrack(self, didTapBlockAt: i)
            return
        }
        delegate?.mainTrackDidTapBlank(self)
    }
}

// MARK: - 滚动 → 自动蓝框

extension BKMainTrackView: UIScrollViewDelegate {

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateAutoFrame()
    }
}

// MARK: - 轨道内容绘制（三层）

/// 主轨画板：上 60px 帧条 + 中 40px 包络 + 下 13px 刻度，全部按内容坐标画
private final class TrackCanvas: UIView {

    static let thumbH: CGFloat = 60
    static let waveH: CGFloat = 40
    static let rulerH: CGFloat = 13

    var blocks: [BKClipBlock] = []
    var starts: [Double] = []
    var durations: [Double] = []
    var pps: CGFloat = 26
    var pad: CGFloat = 0
    var selectedIndex: Int? = nil

    /// 已就绪的媒体。帧图键与 BKFrameGrabs 缓存键一致
    var frames: [String: UIImage] = [:]
    var envelopes: [String: BKEnvelope] = [:]
    private var requestedFrames: Set<String> = []
    private var requestedEnvelopes: Set<String> = []

    // dB → 高度归一，与波剪页 BKTrackView 同一套（-70..-5）
    private let dbLo: Double = -70
    private let dbHi: Double = -5

    // MARK: 异步供给入口

    func requestFrame(localID: String, srcTime: Double) {
        let key = Self.frameKey(localID: localID, srcTime: srcTime)
        guard frames[key] == nil, !requestedFrames.contains(key) else { return }
        requestedFrames.insert(key)
        let h = Self.thumbH
        BKFrameGrabs.frame(localID: localID, at: srcTime,
                           size: CGSize(width: 120, height: h)) { [weak self] img in
            guard let self = self, let img = img else { return }
            self.frames[key] = img
            self.setNeedsDisplay()
        }
    }

    func requestEnvelope(localID: String) {
        guard envelopes[localID] == nil, !requestedEnvelopes.contains(localID) else { return }
        requestedEnvelopes.insert(localID)
        BKEnvelopeStore.envelope(localID: localID) { [weak self] env in
            guard let self = self, let env = env else { return }
            self.envelopes[localID] = env
            self.setNeedsDisplay()
        }
    }

    static func frameKey(localID: String, srcTime: Double) -> String {
        "\(localID)#\(Int(max(0, srcTime) * 4))#\(Int(thumbH))"
    }

    // MARK: 绘制

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let thumbTop: CGFloat = 0
        let waveTop = thumbH + 1                      // 1px 分隔线
        let rulerTop = waveTop + waveH + 1
        let waveBottom = waveTop + waveH

        // 轨道床（帧条 + 波形共用）
        ctx.setFillColor(BKTheme.Color.track.cgColor)
        ctx.fill(CGRect(x: 0, y: thumbTop, width: bounds.width, height: waveBottom - thumbTop))
        // 刻度条底（比床更黑一档，原型 --bg-1 #0E1114）
        ctx.setFillColor(UIColor(hex: 0x0E1114).cgColor)
        ctx.fill(CGRect(x: 0, y: rulerTop, width: bounds.width, height: rulerH))
        // 层间分隔线
        ctx.setFillColor(BKTheme.Color.lineSoft.cgColor)
        ctx.fill(CGRect(x: 0, y: thumbH, width: bounds.width, height: 1))
        ctx.fill(CGRect(x: 0, y: waveTop + waveH, width: bounds.width, height: 1))

        // —— 波形条：先攒所有块的所有柱子，最后一次渐变填充（一次 clip 一把画完）
        let wavePath = CGMutablePath()
        let base = waveBottom - 3
        let amp = waveH - 6
        for i in 0 ..< blocks.count {
            let x = pad + CGFloat(starts[i]) * pps
            let w = max(3, CGFloat(durations[i]) * pps)
            if x + w < rect.minX || x > rect.maxX { continue }     // 可见性裁剪
            drawWave(forBlockAt: i, x: x, w: w, base: base, amp: amp, into: wavePath)
        }
        if !wavePath.isEmpty {
            ctx.saveGState()
            ctx.addPath(wavePath)
            ctx.clip()
            let colors = [UIColor(hex: 0x3ECC77).cgColor,
                          UIColor(hex: 0x239554).cgColor] as CFArray
            let locs: [CGFloat] = [0, 1]
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: locs) {
                ctx.drawLinearGradient(grad,
                                       start: CGPoint(x: 0, y: waveTop),
                                       end: CGPoint(x: 0, y: waveBottom), options: [])
            }
            ctx.restoreGState()
        }

        // —— 帧条 + 块边界 + 选中框（逐块画，方便做可见性裁剪）
        for i in 0 ..< blocks.count {
            let x = pad + CGFloat(starts[i]) * pps
            let w = max(3, CGFloat(durations[i]) * pps)
            if x + w < rect.minX || x > rect.maxX { continue }

            drawFilmstrip(forBlockAt: i, x: x, w: w, in: ctx)

            // 块间深色缝（原型 .tseg border-right rgba(0,0,0,.55)）
            if i > 0 {
                ctx.setFillColor(UIColor(white: 0, alpha: 0.55).cgColor)
                ctx.fill(CGRect(x: x - 0.5, y: thumbTop, width: 1, height: waveBottom - thumbTop))
            }

            // 选中蓝框：只框**帧条**那一段（原型 .tframe 挂在 .m-thumb 里），
            // 时长角标也只在选中块出现（原型 .tframe .dur）
            if selectedIndex == i {
                let fr = CGRect(x: x + 1, y: thumbTop + 1, width: w - 2, height: thumbH - 2)
                ctx.setStrokeColor(BKTheme.Color.select.cgColor)
                ctx.setLineWidth(2.5)
                ctx.addPath(UIBezierPath(roundedRect: fr, cornerRadius: 5).cgPath)
                ctx.strokePath()

                let text = String(format: "%.2fs", durations[i]) as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 9.5, weight: .semibold),
                    .foregroundColor: UIColor.white
                ]
                let ts = text.size(withAttributes: attrs)
                let bg = CGRect(x: fr.minX + 4, y: fr.minY + 3,
                                width: ts.width + 8, height: ts.height + 3)
                ctx.setFillColor(UIColor(hex: 0x0A0C10, alpha: 0.72).cgColor)
                ctx.fill(bg)
                text.draw(at: CGPoint(x: bg.minX + 4, y: bg.minY + 1), withAttributes: attrs)
            }
        }

        // —— 时间刻度：每秒短刻度，每 5s 长刻度 + 文字（原型 buildRuler）
        let rulerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8),
            .foregroundColor: BKTheme.Color.text3
        ]
        let sec = Int(totalSec.rounded(.up))
        for s in 0 ... sec {
            let x = pad + CGFloat(s) * pps
            if x < rect.minX - 40 || x > rect.maxX + 40 { continue }
            let major = (s % 5 == 0)
            ctx.setFillColor(major ? BKTheme.Color.text2.cgColor : BKTheme.Color.text3.cgColor)
            ctx.fill(CGRect(x: x, y: rulerTop + rulerH - (major ? 7 : 4),
                            width: 1, height: major ? 7 : 4))
            if major {
                let label = String(format: "%02d:%02d", s / 60, s % 60) as NSString
                label.draw(at: CGPoint(x: x + 3, y: rulerTop + 1), withAttributes: rulerAttrs)
            }
        }
    }

    /// 帧条：n = 时长/1.2 帧，逐帧从缓存取图；没回来的帧用深灰占位
    private func drawFilmstrip(forBlockAt i: Int, x: CGFloat, w: CGFloat, in ctx: CGContext) {
        let b = blocks[i]
        let n = max(1, min(30, Int((durations[i] / 1.2).rounded())))
        let fw = w / CGFloat(n)
        for k in 0 ..< n {
            let fr = CGRect(x: x + CGFloat(k) * fw, y: 0, width: fw, height: Self.thumbH)
            let local = (Double(k) + 0.5) * durations[i] / Double(n)
            let src = BKMainTrackView.srcTime(inBlock: b, localOut: local)
            let key = Self.frameKey(localID: b.assetLocalID, srcTime: src)
            if let img = frames[key] {
                ctx.saveGState()
                ctx.clip(to: fr)
                img.draw(in: fr)
                ctx.restoreGState()
            } else {
                ctx.setFillColor(BKTheme.Color.panel2.cgColor)
                ctx.fill(fr)
            }
            // 帧与帧之间的细缝
            if k > 0 {
                ctx.setFillColor(UIColor(white: 0, alpha: 0.55).cgColor)
                ctx.fill(CGRect(x: fr.minX - 0.5, y: 0, width: 1, height: Self.thumbH))
            }
        }
    }

    /// 波形：逐像素列取区间峰值。列 → 块内时间线偏移 → 源时间 → 包络峰值。
    /// 只画保留区（keptRanges 折叠后的时间线本来就把红区跳过了 —— 列坐标就是 out 坐标）
    private func drawWave(forBlockAt i: Int, x: CGFloat, w: CGFloat,
                          base: CGFloat, amp: CGFloat, into path: CGMutablePath) {
        let b = blocks[i]
        guard let env = envelopes[b.assetLocalID], !env.frames.isEmpty else { return }
        let cols = Int(w.rounded(.up))
        guard cols > 0 else { return }
        for c in 0 ..< cols {
            let lx0 = Double(c) / Double(pps)
            let lx1 = Double(c + 1) / Double(pps)
            let s0 = BKMainTrackView.srcTime(inBlock: b, localOut: lx0)
            let s1 = BKMainTrackView.srcTime(inBlock: b, localOut: lx1)
            let peak = Double(env.peak(from: s0, to: max(s0, s1)))
            let conv = min(max((peak - dbLo) / (dbHi - dbLo), 0.0), 1.0)
            let h = CGFloat(conv) * amp
            let px = x + CGFloat(c)
            if h >= 0.5 {
                // 每列一个 1px 矩形（与 BKTrackView 同款做法，量级：每块几百列）
                path.addRect(CGRect(x: px, y: base - h, width: 1, height: h))
            }
        }
    }
}
