//
//  BKWaveformView.swift
//  bk剪辑 — 波形 + 刀口可视化 + 手势
//
//  画三样东西：
//  1. 镜像波形 —— 和 preview_cut.py 的 --html 波形图同一个画法：
//     安静的地方收窄成细线，有声的地方撑成粗带
//  2. 刀口覆盖层 —— cut 区间涂红，边界画白色把手（把手可以拖）
//  3. 阈值虚线 —— 让用户看到「低于这条线的才算静音」
//
//  【为什么逐像素列取峰值而不是画全部点】
//  10 分钟素材有 6 万个包络帧，屏幕宽度只有几百个点。
//  逐像素求区间最大值，一遍 O(帧数) 画完，手势拖动时重画也不卡。
//
//  【手势模型】故意做得极简：
//  · 摸到分界线 ±16pt 内 → 拖动这一条分界线
//  · 其他地方 → 拖动 = 扫播放头；快速点按 = 点掉/恢复某一条刀口
//  不做双指缩放、不做长按菜单 —— 第一版先把核心手感做对。
//

import UIKit

protocol BKWaveformViewDelegate: AnyObject {
    /// 拖动分界线。index 是分界线左侧那条 mark 的下标，time 是新位置
    func waveform(_ view: BKWaveformView, didDragBoundaryAfterIndex index: Int, to time: Double)
    /// 点按某条 cut 区间（撤销/恢复这一刀）
    func waveform(_ view: BKWaveformView, didToggleCutAt time: Double)
    /// 扫动播放头
    func waveform(_ view: BKWaveformView, didScrubTo time: Double)
}

final class BKWaveformView: UIView {

    weak var delegate: BKWaveformViewDelegate?

    private var envelope: BKEnvelope?
    private var marks: [BKMark] = []
    private var duration: Double = 0
    private var thresholdDb: Double = -35

    // dB 纵轴的显示范围（与 Python 波形图一致：下限 -70、上限 -5）
    private let dbLo: Double = -70
    private let dbHi: Double = -5

    // 手势状态
    private enum TouchMode { case none, scrub, boundary(Int) }
    private var touchMode: TouchMode = .none
    private var touchStartX: CGFloat = 0
    private var moved = false

    // MARK: - 数据注入

    func setContent(envelope: BKEnvelope?, marks: [BKMark], duration: Double, thresholdDb: Double) {
        self.envelope = envelope
        self.marks = marks
        self.duration = duration
        self.thresholdDb = thresholdDb
        setNeedsDisplay()
    }

    // MARK: - 坐标换算

    private func time(at x: CGFloat) -> Double {
        guard bounds.width > 1 else { return 0 }
        return min(max(Double(x / bounds.width), 0), 1) * duration
    }

    private func x(of time: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * bounds.width
    }

    // MARK: - 绘制

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let w = bounds.width
        let h = bounds.height
        let waveTop: CGFloat = 14
        let waveH = h - waveTop - 8
        guard waveH > 10, w > 2 else { return }
        let mid = waveTop + waveH / 2
        let amp = waveH / 2 - 3

        // 轨道底色
        ctx.setFillColor(BKTheme.Color.track.cgColor)
        ctx.fill(CGRect(x: 0, y: waveTop, width: w, height: waveH))

        // 波形本体
        if let env = envelope, duration > 0 {
            let cols = Int(w)
            let path = CGMutablePath()
            for c in 0..<cols {
                let t0 = Double(c) / Double(w) * duration
                let t1 = Double(c + 1) / Double(w) * duration
                let peak = Double(env.peak(from: t0, to: t1))
                let conv = min(max((peak - dbLo) / (dbHi - dbLo), 0.0), 1.0)
                let half = CGFloat(conv) * amp
                if half < 0.5 { continue }
                path.addRect(CGRect(x: CGFloat(c), y: mid - half, width: 1, height: half * 2))
            }
            ctx.setFillColor(BKTheme.Color.wave.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }

        // 刀口覆盖：红色区间 + 边界线 + 把手
        if duration > 0 {
            for m in marks where m.kind == .cut {
                let x0 = x(of: m.start)
                let x1 = x(of: m.end)
                ctx.setFillColor(BKTheme.Color.cut.cgColor)
                ctx.fill(CGRect(x: x0, y: waveTop, width: max(1, x1 - x0), height: waveH))

                ctx.setStrokeColor(BKTheme.Color.cutLine.cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: x0, y: waveTop))
                ctx.addLine(to: CGPoint(x: x0, y: waveTop + waveH))
                ctx.move(to: CGPoint(x: x1, y: waveTop))
                ctx.addLine(to: CGPoint(x: x1, y: waveTop + waveH))
                ctx.strokePath()

                // 把手：可拖动的视觉暗示
                for hx in [x0, x1] {
                    let handle = CGRect(x: hx - 6, y: waveTop + 2, width: 12, height: 16)
                    let p = UIBezierPath(roundedRect: handle, cornerRadius: 4)
                    BKTheme.Color.selection.setFill()
                    p.fill()
                    BKTheme.Color.cutLine.setStroke()
                    p.lineWidth = 1
                    p.stroke()
                }
            }
        }

        // 阈值虚线
        let conv = min(max((thresholdDb - dbLo) / (dbHi - dbLo), 0.0), 1.0)
        let ty = mid - CGFloat(conv) * amp
        ctx.setStrokeColor(BKTheme.Color.warning.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.move(to: CGPoint(x: 0, y: ty))
        ctx.addLine(to: CGPoint(x: w, y: ty))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // 时间刻度：每 5 秒一个小齿
        if duration > 0 {
            ctx.setStrokeColor(BKTheme.Color.text3.cgColor)
            ctx.setLineWidth(0.5)
            var t: Double = 0
            while t <= duration {
                let tx = x(of: t)
                ctx.move(to: CGPoint(x: tx, y: h - 6))
                ctx.addLine(to: CGPoint(x: tx, y: h))
                ctx.strokePath()
                t += 5
            }
        }
    }

    // MARK: - 手势

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard duration > 0, let touch = touches.first else { return }
        let p = touch.location(in: self)
        touchStartX = p.x
        moved = false

        // 先看是不是摸到了某条分界线。最后一条 mark 的 end 就是素材末尾，不可拖
        var bestIdx = -1
        var bestDist: CGFloat = 16
        for (i, m) in marks.enumerated() where i < marks.count - 1 {
            let d = abs(x(of: m.end) - p.x)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }

        if bestIdx >= 0 {
            touchMode = .boundary(bestIdx)
        } else {
            touchMode = .scrub
            delegate?.waveform(self, didScrubTo: time(at: p.x))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let p = touch.location(in: self)
        if abs(p.x - touchStartX) > 3 { moved = true }

        switch touchMode {
        case .scrub:
            delegate?.waveform(self, didScrubTo: time(at: p.x))
        case .boundary(let idx):
            delegate?.waveform(self, didDragBoundaryAfterIndex: idx, to: time(at: p.x))
        case .none:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 没怎么动的点按 = 点掉/恢复某一条刀口
        if case .scrub = touchMode, !moved, let touch = touches.first {
            delegate?.waveform(self, didToggleCutAt: time(at: touch.location(in: self).x))
        }
        touchMode = .none
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchMode = .none
    }
}
