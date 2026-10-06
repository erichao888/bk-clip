//
//  BKTrackModel.swift
//  bk剪辑 v2.0 — 多片段主轨数据模型 + 坐标映射 + 编辑操作
//
//  【这份是 v2.0 的全新模型，不是 v1.x 的改造】
//  设计真源：docs/v2.0数据模型-多片段主轨与变速坐标.md
//  逻辑已由 tools/verify_v2_model.py 做 5000 轮随机模糊验证（I1–I12 全绿），
//  本文件是那份 Python 逻辑的 Swift 镜像，改任何一处都要回头重跑验证。
//
//  【★ 最重要的收敛】
//  未波剪 = keptRanges 单段 [(0, srcDuration)]；已波剪 = 多段绿区。
//  两者是同一结构的两种取值，代码里**没有**「有没有波剪」的分支。
//
//  【坐标两级映射】
//    片段内：folded → src（累计绿区定位）
//    主轨上：local = trackT − T_i → folded = local × speed → foldMap → src
//    out == trackT（决策 ⑤），先折叠再变速（决策 ④）
//
//  【本文件只 import Foundation】—— 这样 macOS 上也能编译，
//  可以进 SPM 测试 target（Core 里 BKTheme / BKDiag / BKCovers 因 import UIKit 进不去）。
//

import Foundation

// MARK: - 区间（源时间上）

struct BKRange: Codable, Equatable {
    var start: Double
    var end: Double

    var length: Double { end - start }

    init(_ start: Double, _ end: Double) {
        self.start = start
        self.end = end
    }

    func contains(_ t: Double, eps: Double = BKTrackModel.eps) -> Bool {
        t >= start - eps && t <= end + eps
    }
}

// MARK: - 主轨区块

struct BKClipBlock: Codable, Identifiable {
    var id: UUID
    var assetLocalID: String

    /// 源素材总时长，永不改变
    var srcDuration: Double
    /// 源时间上的保留区间（绿区），升序、不重叠
    var keptRanges: [BKRange]
    /// 逐区块倍速（★ 每块独立，禁全局乘数）
    var speed: Double

    /// speed=1 时的折叠后时长（= Σ 绿区长度）
    var baseDuration: Double { keptRanges.reduce(0) { $0 + $1.length } }
    /// 在主轨/输出上占的时长
    var timelineDuration: Double { baseDuration / speed }

    /// 只是给调试/日志看的便利属性，**业务逻辑不要用它做分支**
    var isWaveCut: Bool { keptRanges.count > 1 }

    init(id: UUID = UUID(),
         assetLocalID: String,
         srcDuration: Double,
         keptRanges: [BKRange],
         speed: Double = 1.0) {
        self.id = id
        self.assetLocalID = assetLocalID
        self.srcDuration = srcDuration
        self.keptRanges = keptRanges
        self.speed = speed
    }

    /// 未波剪：整段保留，单段
    static func uncutted(assetLocalID: String, srcDuration: Double, speed: Double = 1.0) -> BKClipBlock {
        BKClipBlock(assetLocalID: assetLocalID,
                    srcDuration: srcDuration,
                    keptRanges: [BKRange(0, srcDuration)],
                    speed: speed)
    }
}

// MARK: - 叠加轨片段（录音 / 画中画）

/// 锚定**输出时间 = trackT**（主轨标记存源时间，两者不要混）
struct BKOverlayClip: Codable, Identifiable {
    var id: UUID
    var start: Double
    var end: Double

    init(id: UUID = UUID(), start: Double, end: Double) {
        self.id = id
        self.start = start
        self.end = end
    }
}

// MARK: - 轨道模型

struct BKTrackModel {

    static let eps = 1e-9
    static let minLen = 1e-6

    var blocks: [BKClipBlock]
    /// 单条叠加轨（录音、画中画各持一个实例）
    var overlays: [BKOverlayClip]

    init(blocks: [BKClipBlock] = [], overlays: [BKOverlayClip] = []) {
        self.blocks = blocks
        self.overlays = overlays
    }

    // MARK: 拼接与前缀和

    var total: Double { blocks.reduce(0) { $0 + $1.timelineDuration } }

    /// 块 i 在主轨上的起点
    func startOf(_ i: Int) -> Double {
        var acc = 0.0
        var k = 0
        while k < i && k < blocks.count {
            acc += blocks[k].timelineDuration
            k += 1
        }
        return acc
    }

    // MARK: 坐标映射（两级）

    /// 片段内：折叠后时间 → (段序号, 源时间)
    private func foldIndex(_ kept: [BKRange], _ folded: Double) -> (Int, Double) {
        guard !kept.isEmpty else { return (0, 0) }
        var cum = 0.0
        for (j, r) in kept.enumerated() {
            let len = r.length
            if folded <= cum + len + BKTrackModel.eps {
                let off = min(max(folded - cum, 0), len)
                return (j, r.start + off)
            }
            cum += len
        }
        let last = kept.count - 1
        return (last, kept[last].end)
    }

    /// 轨道时间 → (块序号, 源时间)。★ 先解变速再解折叠
    func trackToSrc(_ t: Double) -> (block: Int, src: Double) {
        guard !blocks.isEmpty else { return (0, 0) }
        let tt = max(0.0, t)
        var acc = 0.0
        for (i, b) in blocks.enumerated() {
            let len = b.timelineDuration
            if tt <= acc + len + BKTrackModel.eps {
                let local = min(max(tt - acc, 0), len)
                let folded = local * b.speed
                let pair = foldIndex(b.keptRanges, folded)
                return (i, pair.1)
            }
            acc += len
        }
        let i = blocks.count - 1
        return (i, blocks[i].keptRanges.last?.end ?? 0)
    }

    /// 源时间 → 轨道时间（trackToSrc 的逆）
    func srcToTrack(block i: Int, src: Double) -> Double {
        guard i >= 0 && i < blocks.count else { return 0 }
        let b = blocks[i]
        var cum = 0.0
        for r in b.keptRanges {
            if r.contains(src) {
                let folded = cum + (src - r.start)
                return startOf(i) + folded / b.speed
            }
            cum += r.length
        }
        return startOf(i)
    }

    // MARK: 编辑操作

    /// 在 trackT 处切割。返回 false = 落在绿区边界（不切，避免零宽）
    mutating func cut(at t: Double) -> Bool {
        guard !blocks.isEmpty else { return false }
        let hit = trackToSrc(t)
        let i = hit.block
        let b = blocks[i]
        for (j, r) in b.keptRanges.enumerated() {
            if r.start + BKTrackModel.eps < hit.src && hit.src < r.end - BKTrackModel.eps {
                var leftKept = Array(b.keptRanges[..<j])
                leftKept.append(BKRange(r.start, hit.src))
                var rightKept = [BKRange(hit.src, r.end)]
                rightKept.append(contentsOf: b.keptRanges[(j + 1)...])

                let left = BKClipBlock(assetLocalID: b.assetLocalID,
                                       srcDuration: b.srcDuration,
                                       keptRanges: leftKept,
                                       speed: b.speed)
                let right = BKClipBlock(assetLocalID: b.assetLocalID,
                                        srcDuration: b.srcDuration,
                                        keptRanges: rightKept,
                                        speed: b.speed)
                guard left.baseDuration > BKTrackModel.minLen,
                      right.baseDuration > BKTrackModel.minLen else { return false }

                blocks.remove(at: i)
                blocks.insert(left, at: i)
                blocks.insert(right, at: i + 1)
                normalizeOverlays()
                return true
            }
        }
        return false
    }

    mutating func insert(_ block: BKClipBlock, at index: Int) {
        let k = max(0, min(index, blocks.count))
        blocks.insert(block, at: k)
        normalizeOverlays()
    }

    /// 替换：换进来的素材是未波剪的 → 裁到锁定值。素材太短则拒绝（模型不变）
    mutating func replace(blockAt i: Int, newSrcDuration: Double) -> Bool {
        guard i >= 0 && i < blocks.count else { return false }
        let locked = blocks[i].timelineDuration
        let need = locked * blocks[i].speed
        guard newSrcDuration + BKTrackModel.eps >= need else { return false }
        blocks[i].srcDuration = newSrcDuration
        blocks[i].keptRanges = [BKRange(0, need)]
        normalizeOverlays()
        return true
    }

    /// 变速：块时长变化 → 其后的叠加 clip 联动平移
    mutating func setSpeed(_ sp: Double, blockAt i: Int) {
        guard i >= 0 && i < blocks.count else { return }
        let oldEnd = startOf(i) + blocks[i].timelineDuration
        blocks[i].speed = sp
        let newEnd = startOf(i) + blocks[i].timelineDuration
        shiftOverlays(after: oldEnd, by: newEnd - oldEnd)
        normalizeOverlays()
    }

    /// 主轨拖动重排
    mutating func move(from: Int, to: Int) {
        guard from >= 0 && from < blocks.count, from != to else { return }
        let b = blocks.remove(at: from)
        let k = max(0, min(to, blocks.count))
        blocks.insert(b, at: k)
        normalizeOverlays()
    }

    /// 波剪页改了绿区 → 块时长变化 → 联动
    mutating func setKeptRanges(blockAt i: Int, _ newKept: [BKRange]) {
        guard i >= 0 && i < blocks.count else { return }
        let oldEnd = startOf(i) + blocks[i].timelineDuration
        blocks[i].keptRanges = newKept
        let newEnd = startOf(i) + blocks[i].timelineDuration
        shiftOverlays(after: oldEnd, by: newEnd - oldEnd)
        normalizeOverlays()
    }

    // MARK: 叠加轨联动与归一化

    /// ★ 联动（技术方案 §11，默认开）：块之后的所有 clip 整体平移 Δ
    private mutating func shiftOverlays(after boundary: Double, by delta: Double) {
        for k in overlays.indices {
            if overlays[k].start >= boundary - BKTrackModel.eps {
                overlays[k].start += delta
                overlays[k].end += delta
            }
        }
    }

    /// 排序 → 挤压保序 → 夹回 [0, total] → 丢弃零宽
    /// ★ 为什么有「挤压」：Δ<0 时后续 clip 左移会撞上前面的，同轨不允许重叠
    private mutating func normalizeOverlays() {
        let total = self.total
        overlays.sort { $0.start < $1.start }
        var out: [BKOverlayClip] = []
        var prevEnd = 0.0
        for c in overlays {
            let s = min(max(c.start, prevEnd), total)
            let e = min(max(c.end, s), total)
            if e - s > BKTrackModel.minLen {
                out.append(BKOverlayClip(id: c.id, start: s, end: e))
                prevEnd = e
            }
        }
        overlays = out
    }

    // MARK: 自检（对应 verify_v2_model.py 的 I1–I11，供单元测试调用）

    /// 返回违规描述，空数组 = 全绿
    func validate() -> [String] {
        var bad: [String] = []
        guard !blocks.isEmpty else {
            bad.append("空时间线")
            return bad
        }

        // I1 无缝 / 无重叠
        if abs(startOf(0)) > 1e-6 { bad.append("I1 首块起点非 0") }
        for i in 0..<(blocks.count - 1) {
            let want = startOf(i) + blocks[i].timelineDuration
            if abs(startOf(i + 1) - want) > 1e-6 {
                bad.append("I1 块\(i)→\(i+1) 接缝不连续")
            }
        }

        for (i, b) in blocks.enumerated() {
            // I2 无零宽
            if b.timelineDuration <= BKTrackModel.minLen { bad.append("I2 块\(i) 零宽") }

            // I3 绿区合法
            var base = 0.0
            var prevEnd = 0.0
            for r in b.keptRanges {
                if r.length <= BKTrackModel.eps { bad.append("I3 块\(i) 绿区零宽") }
                if r.start < -BKTrackModel.eps || r.end > b.srcDuration + 1e-6 {
                    bad.append("I3 块\(i) 绿区越出源范围")
                }
                if r.start + BKTrackModel.eps < prevEnd { bad.append("I3 块\(i) 绿区重叠/乱序") }
                base += r.length
                prevEnd = r.end
            }

            // I4 派生一致
            if abs(base - b.baseDuration) > 1e-6 { bad.append("I4 块\(i) baseDuration 不一致") }
            if abs(b.timelineDuration - b.baseDuration / b.speed) > 1e-6 {
                bad.append("I4 块\(i) timelineDuration ≠ base/speed")
            }

            // I5 / I6 / I7
            var prevSrc: Double?
            for f in [0.11, 0.29, 0.47, 0.63, 0.79, 0.93] {
                let t = startOf(i) + f * b.timelineDuration
                let hit = trackToSrc(t)
                if hit.block != i {
                    bad.append("I5 块\(i) 采样落到块\(hit.block)")
                    continue
                }
                var inGreen = false
                for r in b.keptRanges where r.contains(hit.src) { inGreen = true }
                if !inGreen { bad.append("I5 块\(i) src 不在绿区内") }

                let back = srcToTrack(block: i, src: hit.src)
                if abs(back - t) > 1e-4 { bad.append("I6 块\(i) 往返漂移") }

                if let p = prevSrc, hit.src < p - 1e-6 { bad.append("I7 块\(i) src 非单调") }
                prevSrc = hit.src
            }
        }

        // I11 叠加 clip
        var prevEnd: Double?
        for (k, c) in overlays.enumerated() {
            if c.end - c.start <= BKTrackModel.eps { bad.append("I11 clip\(k) 零宽") }
            if c.start < -1e-6 || c.end > total + 1e-6 { bad.append("I11 clip\(k) 越出 TOTAL") }
            if let p = prevEnd, c.start + BKTrackModel.eps < p { bad.append("I11 clip\(k) 重叠/乱序") }
            prevEnd = c.end
        }

        return bad
    }
}
