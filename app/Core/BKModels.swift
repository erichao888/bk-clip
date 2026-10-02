//
//  BKModels.swift
//  bk剪辑 — 数据模型
//
//  【核心设计：时间线用区间标记而不是片段列表】
//  第一反应可能是「保留段列表 + 删除段列表」两个数组，够直观但会自找麻烦：
//  拖动分界线要同时改两个数组，一次改动可能在不同步的两份数据里。
//  这里改用一条完整覆盖的区间序列 —— 所有相邻标记严丝合缝，
//  首段从 0 开始、末段到 duration 结束，任何时刻都是一个不变量。
//
//  拖动分界线 = 同时改相邻两条的边界。一步到位，不存在不同步的可能。
//  导出 = 滤出所有 .keep 段。撤销 = 直接换整个 marks 数组。
//
//  【为什么全部 Codable】
//  自动保存直接 JSON 落盘。Codable 不用为序列化再写一遍字段映射，
//  也避免「新加了字段，忘了写进序列化」这类只在特定路径下才炸的 bug。
//

import Foundation
import CoreGraphics

// MARK: - 区间标记

/// 时间线上的一段。kind 决定它最终是被保留还是被剪掉。
struct BKMark: Codable, Equatable {

    enum Kind: String, Codable {
        case keep
        case cut
    }

    var id: UUID
    var start: Double
    var end: Double
    var kind: Kind

    init(start: Double, end: Double, kind: Kind, id: UUID = UUID()) {
        self.start = start
        self.end = end
        self.kind = kind
        self.id = id
    }

    var duration: Double { end - start }

    /// 是否短到不值得单独存在。
    /// UI 用它决定要不要给这条标记画可点区域 —— 太窄的段按不到，
    /// 与其让用户戳不中，不如提示他先合并
    var isTooNarrow: Bool { duration < 0.05 }
}

// MARK: - 音频包络

/// 提取出来的响度曲线。
/// frames 是每一帧的 dB 值，相邻两帧间隔 hopSec 秒。
///
/// 这里刻意不存 AVAsset —— 包络是要随草稿一起落盘的，
/// 而 AVAsset 不可序列化；下次打开要靠 assetLocalID 重新取。
struct BKEnvelope: Codable {

    /// 每帧 dB 值
    var frames: [Float]
    /// 相邻帧的时间间隔（秒）
    var hopSec: Double
    /// 素材采样率。不同素材不一样，降采样换算要用到
    var sampleRate: Double
    /// 素材总时长（秒）
    var duration: Double

    /// 某一时刻对应的 dB 值。越界返回最值而不是崩溃 ——
    /// 播放头在边界抖动几毫秒是常态
    func db(at time: Double) -> Float {
        guard !frames.isEmpty, hopSec > 0 else { return -60 }
        let idx = Int(time / hopSec)
        let clamped = min(max(idx, 0), frames.count - 1)
        return frames[clamped]
    }

    /// 区间内的最大 dB。用来判断这一段到底有多响
    func peak(from start: Double, to end: Double) -> Float {
        guard !frames.isEmpty, hopSec > 0, end > start else { return -60 }
        let a = min(max(Int(start / hopSec), 0), frames.count - 1)
        let b = min(max(Int(end / hopSec), 0), frames.count - 1)
        guard b >= a else { return frames[a] }
        return frames[a...b].max() ?? -60
    }
}

// MARK: - 检测结果

/// 一次自动检测的产出。
/// 除了结果，还要把「过程」带出来 —— 埋点要记，UI 要给提示，
/// 全靠这些中间值。只留一个 threshold 是没法排错的。
struct BKDetectResult {

    /// Otsu 算出的原始阈值（未被夹逼）
    let rawThresholdDb: Double
    /// 实际使用的阈值（夹逼之后）
    let thresholdDb: Double
    /// 是否被夹逼过。这个值要为 true 才值得提醒用户
    var wasClamped: Bool { abs(rawThresholdDb - thresholdDb) > 0.01 }
    /// 素材是否适用本算法。否的话下面的 reason 是给用户看的原因
    let applicable: Bool
    let reason: String?
    /// 剔除 minCut 之前一共找出多少刀 —— 让用户知道有多少刀「没切」
    let candidateCount: Int
    /// 最终采纳的刀数
    let adoptedCount: Int
}

// MARK: - 导出记录

struct BKExportRecord: Codable, Identifiable {
    var id: UUID
    var date: Date
    /// 导出文件的字节数
    var fileSize: Int64
    /// 成品时长（秒）
    var duration: Double
    /// 成品文件名
    var fileName: String
    /// 导出耗时（秒）。排障时很关键：变慢了一眼看出来
    var elapsedSec: Double

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

// MARK: - 草稿工程

/// 一个正在编辑的工程，也是自动保存的最小单位。
struct BKProject: Codable, Identifiable {

    var id: UUID

    // 素材定位
    /// PHAsset.localIdentifier。下次启动靠它把素材捞回来
    var assetLocalID: String
    /// 素材总时长（秒）
    var duration: Double

    // 素材几何 —— 铁律③：埋点必须永久记录旋转后的显示尺寸
    /// 真实显示宽高。注意这是 preferredTransform 之后的值，
    /// 不是 naturalSize —— 后者在 iPhone 竖拍素材上会把 1080×1920 报成 1920×1080
    var displayWidth: Double
    var displayHeight: Double
    /// true = 竖版。导出画面朝向全看这一个字段
    var isPortrait: Bool { displayHeight > displayWidth }
    /// 源素材的旋转角度（度）。0 / 90 / 180 / 270，导出时原样喂给 writerInput.transform
    var sourceRotationDegrees: Double

    // 检测参数
    /// 用户最终采用的阈值
    var thresholdDb: Double
    /// 自动检测给出的原始值（未夹逼）。留着做「恢复自动」用
    var autoThresholdDb: Double?
    /// 素材适用性判定的结果，false 时 UI 要持续给出提示
    var sourceApplicable: Bool

    // 编辑内容
    var marks: [BKMark]

    /// 手动切口。**和 cut 是两回事**：切口只把片段划开，不删任何内容。
    /// 导出时长完全不受它影响（keepRanges 不算它），它的作用是让你能
    /// 单独点掉切开的其中一半 —— 这才是「点切割能从指针处分开」的真意
    var splits: [Double]

    // 时间
    var createdAt: Date
    var updatedAt: Date

    // 导出历史
    var exportHistory: [BKExportRecord]
}

// MARK: - 草稿解码兼容

extension BKProject {

    /// 手写这一段就为一个目的：**让旧草稿能被读回来**。
    /// 合成的 init(from:) 遇到缺 key 会直接 throw —— 皓哥手机上已经存着一堆
    /// 没有 splits 字段的草稿，一 throw 就全没了。所以全部用 decodeIfPresent 兜底。
    enum CodingKeys: String, CodingKey {
        case id, assetLocalID, duration, displayWidth, displayHeight
        case sourceRotationDegrees, thresholdDb, autoThresholdDb
        case sourceApplicable, marks, createdAt, updatedAt, exportHistory, splits
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        assetLocalID = try c.decode(String.self, forKey: .assetLocalID)
        duration = try c.decode(Double.self, forKey: .duration)
        displayWidth = try c.decode(Double.self, forKey: .displayWidth)
        displayHeight = try c.decode(Double.self, forKey: .displayHeight)
        sourceRotationDegrees = try c.decode(Double.self, forKey: .sourceRotationDegrees)
        thresholdDb = try c.decode(Double.self, forKey: .thresholdDb)
        autoThresholdDb = try c.decodeIfPresent(Double.self, forKey: .autoThresholdDb)
        sourceApplicable = try c.decode(Bool.self, forKey: .sourceApplicable)
        marks = try c.decode([BKMark].self, forKey: .marks)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        exportHistory = (try? c.decodeIfPresent([BKExportRecord].self, forKey: .exportHistory)) ?? []
        splits = (try? c.decodeIfPresent([Double].self, forKey: .splits)) ?? []
    }
}

// MARK: - 工程派生计算

extension BKProject {

    /// 所有被切除的区间
    var cutRanges: [(Double, Double)] {
        marks.filter { $0.kind == .cut }.map { ($0.start, $0.end) }
    }

    /// 所有保留的区间
    var keepRanges: [(Double, Double)] {
        marks.filter { $0.kind == .keep }.map { ($0.start, $0.end) }
    }

    /// 成品时长 = 所有保留段之和
    var outputDuration: Double {
        keepRanges.reduce(0) { $0 + ($1.1 - $1.0) }
    }

    /// 删掉的总时长
    var removedDuration: Double { duration - outputDuration }

    /// 删除占比（0~1）。UI 上显示百分比
    var removedRatio: Double {
        duration > 0 ? removedDuration / duration : 0
    }

    /// 切了几刀
    var cutCount: Int { cutRanges.count }

    var sizeText: String {
        "\(Int(displayWidth))×\(Int(displayHeight))"
    }

    /// 工程文件大小。超过几 MB 就该反省：是不是把整份波形也塞进来了
    func encodedSizeText() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

// MARK: - 时间线操作
//
// 所有改动统一走这里，保证「相邻严丝合缝」这个不变量不被破坏。
// 散布在各处的直接改 marks 是一定会出问题的，别图一时方便。

enum BKTimeline {

    /// 把一串切点和总时长合成完整的区间序列。
    /// 这是从检测到可编辑状态的唯一入口。
    static func build(duration: Double, cuts: [(Double, Double)]) -> [BKMark] {
        var marks: [BKMark] = []
        var cursor: Double = 0

        let sorted = merge(cuts, duration: duration)

        for (s, e) in sorted {
            if s > cursor {
                marks.append(BKMark(start: cursor, end: s, kind: .keep))
            }
            marks.append(BKMark(start: s, end: e, kind: .cut))
            cursor = e
        }
        if cursor < duration {
            marks.append(BKMark(start: cursor, end: duration, kind: .keep))
        }
        return normalize(marks, duration: duration)
    }

    /// 洗净 + 合并区间：夹回 [0, duration]、丢掉零宽的、排序、**合并重叠与相接的**。
    ///
    /// 合并这一步不是洁癖，是真 bug：手动划掉的一段和自动检出的气口一旦重叠，
    /// 不合并的话游标会往后退，拼出来的序列中间会漏一条缝 ——
    /// 而这条缝在成品里表现为内容凭空消失，完全看不出是这儿出的问题。
    /// （Python 版先在 4000 组随机用例上撞出来：735 组失败，加上合并后 6000 组全绿）
    static func merge(_ cuts: [(Double, Double)], duration: Double) -> [(Double, Double)] {
        let clean = cuts
            .map { (max($0.0, 0), min($0.1, duration)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }

        var out: [(Double, Double)] = []
        for iv in clean {
            if let last = out.last, iv.0 <= last.1 {
                out[out.count - 1].1 = max(last.1, iv.1)
            } else {
                out.append(iv)
            }
        }
        return out
    }

    /// 把「删除区间 + 手动切口」合成**显示用**的片段序列。
    ///
    /// 和 build 的区别：build 出来的每个 keep 是一条整段；pieces 会把 keep 段再按
    /// 切口切开，于是轨道上看到的就是真正一分为二的两段。
    /// **只用于显示与点选，不参与导出** —— 导出只认 keepRanges（不含 splits）。
    ///
    /// 算法与 tools 侧的 Python 逐行对应，不变量已在 6000 组随机用例 + 脏数据上验证：
    /// 覆盖 [0, duration]、相邻严丝合缝、无零宽、切口不吞时间。
    static func pieces(duration: Double,
                       cuts: [(Double, Double)],
                       splits: [Double]) -> [BKMark] {
        let clean = merge(cuts, duration: duration)

        // 切口洗净：夹回素材内、去重排序、删掉落在删除区里的（那里已经看不见了）
        let cutList = clean.filter { $0.1 > $0.0 }
        let edges = Set(splits.map { min(max($0, 0), duration) })
            .filter { t in t > 0 && t < duration && !cutList.contains { t >= $0.0 && t <= $0.1 } }
            .sorted()

        var out: [BKMark] = []
        var cursor: Double = 0

        // 把 [a, b) 这段保留区按落在它内部的切口切开
        func splitKeep(_ a: Double, _ b: Double) {
            guard b > a else { return }
            var from = a
            for t in edges where t > a && t < b {
                if t > from { out.append(BKMark(start: from, end: t, kind: .keep)) }
                from = t
            }
            if b > from { out.append(BKMark(start: from, end: b, kind: .keep)) }
        }

        for iv in clean {
            splitKeep(cursor, iv.0)
            if iv.1 > iv.0 { out.append(BKMark(start: iv.0, end: iv.1, kind: .cut)) }
            cursor = iv.1
        }
        splitKeep(cursor, duration)
        return out
    }

    /// 按「最近的边界」拖动，不按 index。
    /// 原因：index 会随显示粒度变 —— 一段有没有被切口切开，同一次触摸算出来的
    /// index 就不是同一个东西，拖动会错位。时间坐标才是稳的。
    static func moveBoundary(in marks: [BKMark],
                             near time: Double,
                             to newTime: Double) -> [BKMark]? {
        // 找内部边界里离触点最近的那条（最后一条的 end 是素材末尾，不动）
        var bestIdx: Int?
        var bestDist = Double.greatestFiniteMagnitude
        for i in 0 ..< max(0, marks.count - 1) {
            let d = abs(marks[i].end - time)
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        guard let idx = bestIdx else { return nil }
        return moveBoundary(in: marks, afterIndex: idx, to: newTime)
    }

    /// 拖动一条分界线。同时改左右两条标记的边界。
    /// 返回 nil 表示拖到了非法位置 —— 越过邻居就是非法。
    static func moveBoundary(in marks: [BKMark],
                             afterIndex index: Int,
                             to time: Double) -> [BKMark]? {
        guard index >= 0, index < marks.count - 1 else { return nil }
        let left = marks[index]
        let right = marks[index + 1]

        // 两边各留最小长度，防止拖成 0 宽度 —— 0 宽度的段在导出时会
        // 变成 CMTimeRange 的非法 range，报出来的错完全指不到这里是根因
        let minLen = 0.05
        guard time > left.start + minLen, time < right.end - minLen else { return nil }

        var next = marks
        next[index].end = time
        next[index + 1].start = time
        return next
    }

    /// 切换某条标记的状态。
    /// 如果切完之后左右两边状态相同，就合并成一条 —— 否则时间线上会出现
    /// 两个相邻的同状态区间，虽然功能正确但 UI 上会画两遍、也更容易误触
    static func toggle(marks: [BKMark], at index: Int) -> [BKMark] {
        guard index >= 0, index < marks.count else { return marks }
        var next = marks
        next[index].kind = (next[index].kind == .cut) ? .keep : .cut
        return mergeSameKind(next)
    }

    /// 合并相邻的同状态区间
    static func mergeSameKind(_ marks: [BKMark]) -> [BKMark] {
        var out: [BKMark] = []
        for m in marks {
            if let last = out.last, last.kind == m.kind {
                out[out.count - 1].end = m.end
            } else {
                out.append(m)
            }
        }
        return out
    }

    /// 兜底修正：清掉零宽区间、重排顺序、补齐首尾。
    /// 任何从磁盘读回来的数据都应该先过一遍这里 ——
    /// 你没法保证上一个版本写出去的东西一定是对的
    static func normalize(_ marks: [BKMark], duration: Double) -> [BKMark] {
        // 第一件事是把所有边界夹回 [0, duration]。
        // 不夹会出这种事：脏数据里有一条 [-1, 3]，和后面的 [3, 12] 同状态被合并成
        // [-1, 12]，起点跑到了负数 —— 之后导出的 CMTimeRange 起点就是负的，
        // 而报出来的错完全看不出根因在这
        let cleaned = marks
            .map { BKMark(start: min(max($0.start, 0), duration),
                          end: min(max($0.end, 0), duration),
                          kind: $0.kind, id: $0.id) }
            .filter { $0.end - $0.start > 0.001 }
            .sorted { $0.start < $1.start }

        // 第一遍：砍掉重叠、补上缝隙。
        // 补缝一定要做 —— 时间线上有一条 0.3 秒的缝，导出时这段内容会凭空消失，
        // 而成品看起来「好像是连续的」，用户很难察觉丢了什么
        var out: [BKMark] = []
        for m in cleaned {
            if let lastEnd = out.last?.end {
                if m.start < lastEnd {
                    // 重叠：上一段截断到当前起点，重叠部分归后者
                    out[out.count - 1].end = m.start
                }
                if let newEnd = out.last?.end, newEnd < m.start {
                    // 缝隙：一律按保留处理。误删用户的内容比漏删一段气口严重得多
                    out.append(BKMark(start: newEnd, end: m.start, kind: .keep))
                }
            }
            out.append(m)
        }

        let widowed = out.filter { $0.end - $0.start > 0.001 }
        guard !widowed.isEmpty else {
            return [BKMark(start: 0, end: duration, kind: .keep)]
        }

        var result = mergeSameKind(widowed)

        // 第二遍：首尾补齐，让整条序列严丝合缝地覆盖 0...duration
        if let first = result.first, first.start > 0 {
            result.insert(BKMark(start: 0, end: first.start, kind: .keep), at: 0)
        }
        if let last = result.last, last.end < duration {
            result.append(BKMark(start: last.end, end: duration, kind: .keep))
        }
        return result
    }
}
