//
//  BKMainTrackView.swift
//  bk剪辑 — v2 主编辑页 · 多片段主轨视图
//
//  【为什么另起一个视图，不去改 BKTrackView】
//  BKTrackView 是**单素材波形**视图（画包络线 + 红绿区 + 拖把手），波剪子页还在用它，
//  2A 刚迁完 v2、不能动。主轨是**多片段**语义：一条横向轨道上按时间铺 N 个区块，
//  每块 = 一个素材 + 它的绿区 + 倍速。两者画的东西完全不同，硬塞进一个视图只会让
//  BKTrackView 变成「一半波形一半片段」的四不像。所以各管各的。
//
//  【坐标：为什么 centerTime = offset.x / pps —— 半屏余量】
//  内容区左右各留半个屏宽的余量（pad = bounds.width/2），这样**第一个和最后一个**
//  区块也能滚到屏幕正中接受选中；没有余量，贴边的块永远框不到（规格 §1.4 的隐含前提）。
//  指针固定在屏幕正中，于是：
//      屏幕中心对应的内容 x = offset.x + pad
//      区块 i 的内容 x 起点  = pad + startOf(i) * pps
//    ⇒ 中心时间 = (offset.x + pad − pad) / pps = offset.x / pps
//  这条「余量让公式退化成一行」是刻意的，别为了省几个点把 pad 去掉。
//
//  【自动蓝框必须遵守的两条约束】规格 §1.4：
//   ① 只在**跨过区块边界**时才改选中并回调。早年的原型每像素重绘，拖动明显卡顿。
//   ② 程序化滚动（点选后 scrollTo 让区块居中）期间**必须让位**（autoFrameLock），
//      否则刚选中的区块会被指针下的旧区块覆盖回去 ——
//      症状是「复制片段后选中的还是原来那段」。
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
        loadThumbs()
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

    /// 缩略图异步补：命中缓存是同步回调，没命中就等 Photos 回来再重画一次
    private func loadThumbs() {
        for b in canvas.blocks where canvas.thumbs[b.assetLocalID] == nil {
            let id = b.assetLocalID
            BKThumbnails.image(localID: id, size: CGSize(width: 160, height: 90)) { [weak self] img in
                guard let self = self, let img = img else { return }
                self.canvas.thumbs[id] = img
                self.canvas.setNeedsDisplay()
            }
        }
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

// MARK: - 轨道内容绘制

/// 画区块本体：缩略图打底 + 圆角 + 块间白缝 + 选中蓝框 + 块名
private final class TrackCanvas: UIView {

    var blocks: [BKClipBlock] = []
    var starts: [Double] = []
    var durations: [Double] = []
    var pps: CGFloat = 26
    var pad: CGFloat = 0
    var selectedIndex: Int? = nil
    /// 素材缩略图缓存（key = assetLocalID）
    var thumbs: [String: UIImage] = [:]

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let top: CGFloat = 8
        let bandH: CGFloat = bounds.height - top * 2
        // 轨道槽底色（浅绿，和波形页同一套色，视觉上是一条"轨道"）
        ctx.setFillColor(BKTheme.Color.track.cgColor)
        ctx.fill(CGRect(x: 0, y: top, width: bounds.width, height: bandH))

        for i in 0 ..< blocks.count {
            let x = pad + CGFloat(starts[i]) * pps
            let w = max(3, CGFloat(durations[i]) * pps)
            let r = CGRect(x: x, y: top, width: w, height: bandH)

            // 缩略图（有就画，没有先用略深的绿占位，等异步回来重画）
            ctx.saveGState()
            let clip = UIBezierPath(roundedRect: r, cornerRadius: 6)
            ctx.addPath(clip.cgPath)
            ctx.clip()
            if let img = thumbs[blocks[i].assetLocalID] {
                img.draw(in: r)
            } else {
                ctx.setFillColor(UIColor(hex: 0xA9BE9C).cgColor)
                ctx.fill(r)
            }
            ctx.restoreGState()

            // 块名：太窄的块（<50pt）写不下就不写，免得糊成一团
            if w > 50 {
                let s = blocks[i].assetName as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: BKTheme.Font.small,
                    .foregroundColor: UIColor.white
                ]
                let tr = CGRect(x: x + 6, y: top + 4, width: w - 12, height: 14)
                s.draw(in: tr, withAttributes: attrs)
            }

            // 块间白缝：把相邻两块分开，否则两块同色素材会连成一条
            if i > 0 {
                ctx.setStrokeColor(UIColor.white.cgColor)
                ctx.setLineWidth(1)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: x, y: top))
                ctx.addLine(to: CGPoint(x: x, y: top + bandH))
                ctx.strokePath()
            }

            // 选中蓝框：内缩 1.5pt，让 3pt 的线完整落在框内不被裁掉半边
            if selectedIndex == i {
                ctx.setStrokeColor(BKTheme.Color.select.cgColor)
                ctx.setLineWidth(3)
                let rr = UIBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 6)
                ctx.addPath(rr.cgPath)
                ctx.strokePath()
            }
        }
    }
}
