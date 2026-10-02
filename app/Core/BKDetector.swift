//
//  BKDetector.swift
//  bk剪辑 — 气口检测
//
//  【移植纪律：这是 tools/preview_cut.py 检测管线的逐行翻译】
//  流程：Otsu → 夹逼 → 找候选气口 → PAD → 最短片段合并 → 局部对比度复核（已归零）
//  顺序、阈值、边界条件一律不做「顺手优化」—— 尺子和刀必须一致。
//  这套逻辑已用 tools/verify_detector_port.py 与 Python 原版跑过 300 组随机对照。
//
//  【2026-10-02 定稿改动，三处逻辑翻转，全部有真实数据撑腰】
//   1. detectGaps 不再跳过片头片尾的安静段（旧版方向反了）
//   2. applyPad 片头 / 片尾不收留白，只有中间气口双侧收
//   3. enforceMinSegment 改成「两刀并一刀」，旧版「两刀都撤」会把短素材撤成 0 刀
//  四条样片实测：4580 13.7%→30.4%、4582 0刀→36.6%、4583 0刀→28.9%、4990 21.4%→44.2%
//  参数取值见 docs/算法定稿.md，改之前先看那份。
//
//  与 Python 两处刻意不同的地方：
//  1. 适用性判据（BGM / 响度归一化素材直接判不适用）：Python 里靠人看报告，
//     App 里必须代码先判，不适用就明说，不能给用户一堆莫名奇怪的刀
//  2. 阈值可外部指定（阈值滑杆用），Python 里是命令行参数
//

import Foundation

enum BKDetector {

    struct Outcome {
        let cuts: [(Double, Double)]
        let info: BKDetectResult
    }

    // MARK: - 入口

    static func detect(envelope: BKEnvelope,
                       totalDuration: Double,
                       overrideThreshold: Double? = nil) -> Outcome {

        let db = envelope.frames.map { Double($0) }
        let hop = envelope.hopSec
        let total = totalDuration

        // ① 适用性判据：整条素材响度起伏不足 6dB 判死刑
        let applicability = checkApplicability(envelope: envelope)
        guard applicability.applicable else {
            return Outcome(cuts: [],
                           info: BKDetectResult(rawThresholdDb: 0,
                                                thresholdDb: 0,
                                                applicable: false,
                                                reason: applicability.reason,
                                                candidateCount: 0,
                                                adoptedCount: 0))
        }

        // ② Otsu 自动阈值 + 夹逼（手动阈值同样要夹逼）
        let raw = otsuThreshold(db: db)
        let used = clampDb(overrideThreshold ?? raw)

        // ③④ 顺序与 Python 一致：找气口 → PAD → 合并碎片 → 对比度复核
        // （定稿第 2 节的八步管线，顺序不能变）
        let gaps = detectGaps(db: db, hopSec: hop, threshold: used, totalSec: total)
        let padded = applyPad(gaps, totalSec: total)
        let merged = enforceMinSegment(padded, totalSec: total)
        let final = localContrastPass(merged, db: db, hopSec: hop, totalSec: total)

        let info = BKDetectResult(rawThresholdDb: raw,
                                  thresholdDb: used,
                                  applicable: true,
                                  reason: nil,
                                  candidateCount: gaps.count,
                                  adoptedCount: final.count)
        return Outcome(cuts: final, info: info)
    }

    // MARK: - 适用性判据
    //
    // 0.5 秒一段取峰值，看整条素材的响度起伏。
    // 带 BGM 或做过响度归一化的素材，峰值永远顶在差不多的高度 ——
    // 起伏不足 6dB 意味着「响的地方和不响的地方一样响」，静音检测无从谈起。
    // 判据出自 docs/免费验证方案.md，是两条真实素材上验证过的经验线。

    static func checkApplicability(envelope: BKEnvelope) -> (applicable: Bool, reason: String?) {
        let total = envelope.duration
        guard total > 0, !envelope.frames.isEmpty else {
            return (false, "音频内容为空")
        }
        var peaks: [Double] = []
        var t = 0.0
        while t < total - 1e-9 {
            let segEnd = min(t + 0.5, total)
            peaks.append(Double(envelope.peak(from: t, to: segEnd)))
            t += 0.5
        }
        guard let lo = peaks.min(), let hi = peaks.max() else {
            return (false, "音频内容为空")
        }
        if hi - lo < BKConfig.Detect.minContrastDb {
            return (false, String(format: "整条素材响度太平（起伏不足 %.0fdB）——多半带 BGM 或做过响度归一化，静音检测不适用",
                                  BKConfig.Detect.minContrastDb))
        }
        return (true, nil)
    }

    // MARK: - Otsu 双峰取谷
    //
    // 256 bins 直方图 + 类间方差最大点，与 np.histogram(bins=256) 对齐：
    // 范围取数据本身的 min/max，最右 bin 含右端点。
    // 分箱的浮点实现和 numpy 可能有半个 bin 以内的差异（约 0.1~0.4dB），
    // 对真实的几百毫秒宽的气口毫无影响，随机对照已验证。

    static func otsuThreshold(db: [Double]) -> Double {
        let mid = (BKConfig.Detect.clampLow + BKConfig.Detect.clampHigh) / 2.0
        let finite = db.filter { $0.isFinite }
        guard finite.count >= 32 else { return mid }
        guard let lo0 = finite.min(), let hi0 = finite.max(), hi0 - lo0 > 1e-9 else { return mid }

        let bins = 256
        var hist = [Double](repeating: 0, count: bins)
        let scale = Double(bins) / (hi0 - lo0)
        for v in finite {
            var idx = Int((v - lo0) * scale)
            if idx >= bins { idx = bins - 1 }
            if idx < 0 { idx = 0 }
            hist[idx] += 1
        }

        let s = hist.reduce(0, +)
        guard s > 0 else { return mid }

        func center(_ i: Int) -> Double {
            lo0 + (Double(i) + 0.5) * (hi0 - lo0) / Double(bins)
        }

        var mt = 0.0
        for i in 0..<bins {
            mt += hist[i] / s * center(i)
        }

        var w0 = 0.0
        var m0 = 0.0
        var bestSigma = -1.0
        var bestIdx: Int?
        for i in 0..<bins {
            w0 += hist[i] / s
            m0 += hist[i] / s * center(i)
            let denom = w0 * (1.0 - w0)
            if denom > 1e-9 {
                let sigma = pow(mt * w0 - m0, 2) / denom
                if sigma > bestSigma {
                    bestSigma = sigma
                    bestIdx = i
                }
            }
        }
        guard let idx = bestIdx else { return mid }
        return center(idx)
    }

    static func clampDb(_ v: Double) -> Double {
        min(max(v, BKConfig.Detect.clampLow), BKConfig.Detect.clampHigh)
    }

    // MARK: - 候选气口
    //
    // 低于阈值 → 连续区间。比 MIN_GAP 短的丢掉（那种是音节内的瞬态，碰了会把字切碎）。
    //
    // ⚠️ **片头片尾的安静段不再跳过**（2026-10-02 定稿，方向反过来了）。
    // 旧版这里有一句 `if t0 > 0.02, t1 < totalSec - 0.02`，
    // 皓哥手工刀口里头尾都是整段红的 —— 开头那两秒「嗯…」和结尾的收声都要切掉。
    // 这条是 IMG_4582 / IMG_4583 原来一刀切不出来的元凶之一。

    static func detectGaps(db: [Double], hopSec: Double, threshold: Double, totalSec: Double) -> [(Double, Double)] {
        var gaps: [(Double, Double)] = []
        var i = 0
        let n = db.count
        while i < n {
            if db[i] < threshold {
                var j = i
                while j < n && db[j] < threshold { j += 1 }
                let t0 = Double(i) * hopSec
                let t1 = Double(j) * hopSec
                if (t1 - t0) >= BKConfig.Detect.minGap {
                    gaps.append((t0, t1))
                }
                i = j
            } else {
                i += 1
            }
        }
        return gaps
    }

    // MARK: - 头尾留白
    //
    // **只收「贴语音」的那一侧**：
    //   片头段（t0 就在开头）→ 不往里收，安静段从第 0 帧切起
    //   片尾段（t1 就在末尾）→ 不往里收，一直切到最后一帧
    //   中间气口（两头都是语音）→ 双侧各收 PAD
    // 旧版一律双侧收，配合 PAD=0.10 实际要求气口 ≥0.3s，把 0.16/0.21/0.26s
    // 那一大批又短又深的换气全漏掉了。

    static func applyPad(_ gaps: [(Double, Double)], totalSec: Double) -> [(Double, Double)] {
        var cuts: [(Double, Double)] = []
        let pad = BKConfig.Detect.pad
        for (t0, t1) in gaps {
            let head = t0 <= pad + 0.01
            let tail = t1 >= totalSec - pad - 0.01
            let s = head ? t0 : t0 + pad
            let e = tail ? t1 : t1 - pad
            if (e - s) >= BKConfig.Detect.minCut {
                cuts.append((s, e))
            }
        }
        return cuts
    }

    // MARK: - 最短片段合并
    //
    // 任何保留片段短于 MIN_SEG：
    //   · 中间的过短片段 → 把夹着它的相邻两刀**合并成一刀**，中间那一小截语音也删掉
    //   · 开头的过短片段 → 首刀起点扩到 0（开头那截杂音一并切掉）
    //   · 结尾的过短片段 → 末刀终点扩到片尾
    // 迭代直到稳定。
    //
    // ⚠️ 旧版是「把造成碎片的两刀都撤掉」—— 那等于放着两个气口不切，
    // 短素材上一撤到底就归零了。IMG_4582 / IMG_4583 就是这么变成 0 刀的。

    /// 与删除区间**严格按索引对齐**的保留片段（**不过滤**零宽段）。
    ///
    /// ⚠️ 不能拿 keptSegments 去做这件事 —— 它一过滤，段序号和刀序号就错位了，
    /// 合并逻辑会拿着错位的索引去并刀，越并越乱。这个 bug 是 IMG_4582 的真实
    /// 数据钓出来的：8 把刀只对出 8 个段（应该是 9 个），残留了一堆碎片段没人收拾。
    static func segsAligned(_ dels: [(Double, Double)], totalSec: Double) -> [(Double, Double)] {
        var segs: [(Double, Double)] = []
        var cur = 0.0
        for (s, e) in dels {
            segs.append((cur, s))
            cur = e
        }
        segs.append((cur, totalSec))
        return segs
    }

    /// 过滤掉零宽段之后的保留片段。只用于展示 / 导出，不参与判短
    static func keptSegments(_ cuts: [(Double, Double)], totalSec: Double) -> [(Double, Double)] {
        segsAligned(cuts, totalSec: totalSec).filter { $0.1 > $0.0 + 1e-6 }
    }

    static func enforceMinSegment(_ cuts: [(Double, Double)], totalSec: Double) -> [(Double, Double)] {
        var dels = cuts
        for _ in 0 ..< 300 {
            let segs = segsAligned(dels, totalSec: totalSec)

            // ⚠️ 判短条件必须是「零宽 < 段长 < MIN_SEG」。
            // 零宽段不能参与判断 —— 首刀起点扩到 0 之后该段变成 (0, 0)，
            // 再判短就是原地打转，一直空转到循环上限退出，短片段根本没被收拾。
            var bad = -1
            for (i, seg) in segs.enumerated() {
                let len = seg.1 - seg.0
                if len > 1e-6 && len < BKConfig.Detect.minSegment {
                    bad = i
                    break
                }
            }
            guard bad >= 0 else { break }

            if bad == 0 {
                dels[0].0 = 0.0
            } else if bad == segs.count - 1 {
                dels[dels.count - 1].1 = totalSec
            } else {
                // 把 bad-1 那一刀的终点拉到 bad 那一刀的终点（两刀并一刀），再删掉 bad
                dels[bad - 1].1 = max(dels[bad - 1].1, dels[bad].1)
                dels.remove(at: bad)
            }

            dels = dels.filter { $0.1 - $0.0 > 1e-6 }
            // 显式比较器而不是元组比较：元组 < 在 Swift 里属于未公开的内部运算符
            dels.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            if dels.isEmpty { break }
        }
        return dels
    }

    // MARK: - 6dB 局部对比度复核
    //
    // 气口必须比它两边 200ms 的语音低 6dB 以上，否则判为「其实在说话」，
    // 撤销这一刀。专治音量起伏大的素材被误杀整句。

    static func localContrastPass(_ cuts: [(Double, Double)],
                                  db: [Double],
                                  hopSec: Double,
                                  totalSec: Double) -> [(Double, Double)] {
        func level(_ t0: Double, _ t1: Double) -> Double {
            let a = max(0, Int(t0 / hopSec))
            let b = min(db.count, Int(t1 / hopSec))
            guard b > a else { return -120.0 }
            var m = -Double.infinity
            for k in a..<b { m = max(m, db[k]) }
            return m
        }

        var keep: [(Double, Double)] = []
        for (s, e) in cuts {
            let pre = level(max(0.0, s - BKConfig.Detect.pad - BKConfig.Detect.padSampleSec),
                            max(0.0, s - BKConfig.Detect.pad))
            let post = level(e + BKConfig.Detect.pad,
                             min(totalSec, e + BKConfig.Detect.pad + BKConfig.Detect.padSampleSec))
            let speech = max(pre, post)
            let gap = level(s, e)
            if (speech - gap) >= BKConfig.Detect.localContrastDb {
                keep.append((s, e))
            }
        }
        return keep
    }
}
