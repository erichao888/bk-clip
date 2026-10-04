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

// MARK: - 素材项（草稿的第二层）
//
// ⚠️ **一个草稿 = 一次导入的一整批，不是一条视频。**
// 见下面的 BKDraftBatch —— 皓哥 2026-10-02 口述定稿：
// 「我这次操作添加了 5 个视频……关闭之后草稿箱多了一个草稿，这个草稿包含刚才那 5 个视频。」
// 所以 BKProject 在这里的角色是**批里的一个素材项**，不是顶层草稿。
// 名字沿用了老的 Project 以免全文改名引入新 bug，但语义上是 item。

/// 一次导入里的一条素材 + 它自己的刀口。自动保存的最小单位。
struct BKProject: Codable, Identifiable {

    var id: UUID

    // 素材定位
    /// PHAsset.localIdentifier。下次启动靠它把素材捞回来
    var assetLocalID: String
    /// 素材名（IMG_3027.MOV）。列表里要显示，存一份省得每次去查 PHAsset
    var assetName: String
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

    /// v1.3.0 删红键：是否已把红区**折叠**掉。
    ///
    /// 折叠 = 真折叠：绿区 ripple 拼接、主轨道渲染成一条连续绿轨、时间轴变短。
    /// 但 `marks` 里的 cut 段**一个都不删**（源区间永远保留 = 皓哥说的「缓存」），
    /// 折叠只影响渲染与播放，日后拖接缝能把已删素材拖回来。
    /// 所以这个标志是「显示模式开关」，不是「数据已删除」的记录。
    ///
    /// ⚠️ 旧草稿没有这个字段，必须 decodeIfPresent 兜底成 false（v1.2.x 的老草稿都是未折叠状态）。
    var redFolded: Bool = false

    /// 折叠后的**成品时长**（= 总时长 − 被删红区总长）。导出与进度条都用它。
    var foldedOutputDuration: Double {
        redFolded ? BKTimeline.foldedOutputDuration(duration: duration, cuts: cutRanges) : outputDuration
    }

    /// 橙色指针停在哪儿。换素材 / 退出再进来都要回到这一帧，
    /// 起始页的封面也是这一帧（定稿 3.1）
    var playheadTime: Double

    // 时间
    var createdAt: Date
    var updatedAt: Date

    // 导出历史
    var exportHistory: [BKExportRecord]

    // MARK: 派生

    /// 这条素材导出过几次。**导出文件名的后缀序号靠它**（定稿 4.8）
    /// 直接读历史条数，不另外记账 —— 多一份计数就多一处可能对不上的地方
    var exportCount: Int { exportHistory.count }

    /// 「动过刀没有」—— 三处共用的同一个判定（定稿 7.2）：
    /// ① 编辑页素材列表名字变红  ② 批量导出的范围  ③ 草稿退不退出
    /// ⚠️ 不能用「有没有草稿」代替 —— 进过编辑页一刀没切也会存草稿
    var isEdited: Bool { !cutRanges.isEmpty || !splits.isEmpty }

    /// 导出文件名（不含路径），定稿 4.8 的命名规则：
    ///   第 1 次 → `BK_1.mov`   第 2 次 → `BK_1_1.mov`   第 3 次 → `BK_1_2.mov`
    /// k = 已经导出的次数；k == 0 不加后缀，k >= 1 加 `_k`，往后顺推
    var nextExportFileName: String {
        let src = assetName.isEmpty ? "clip.mov" : assetName
        let base = (src as NSString).deletingPathExtension
        let ext = (src as NSString).pathExtension.isEmpty ? "mp4" : (src as NSString).pathExtension
        let k = exportCount
        if k <= 0 { return "BK_\(base).\(ext)" }
        return "BK_\(base)_\(k).\(ext)"
    }
}

// MARK: - 草稿解码兼容

extension BKProject {

    /// 手写这一段就为一个目的：**让旧草稿能被读回来**。
    /// 合成的 init(from:) 遇到缺 key 会直接 throw —— 皓哥手机上已经存着一堆
    /// 没有 splits 字段的草稿，一 throw 就全没了。所以全部用 decodeIfPresent 兜底。
    enum CodingKeys: String, CodingKey {
        case id, assetLocalID, assetName, duration, displayWidth, displayHeight
        case sourceRotationDegrees, thresholdDb, autoThresholdDb
        case sourceApplicable, marks, createdAt, updatedAt, exportHistory, splits
        case playheadTime
        case redFolded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        assetLocalID = try c.decode(String.self, forKey: .assetLocalID)
        assetName = (try? c.decodeIfPresent(String.self, forKey: .assetName)) ?? ""
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
        playheadTime = (try? c.decodeIfPresent(Double.self, forKey: .playheadTime)) ?? 0
        // v1.3.0 新增字段。旧草稿没有它 —— 缺 key 必须兜底成 false，
        // 不兜底的话合成 init 遇到缺 key 直接 throw，皓哥手机上一堆老草稿全得没
        redFolded = (try? c.decodeIfPresent(Bool.self, forKey: .redFolded)) ?? false
        // 老草稿没有名字，回退到相册里查一次，补上之后下次就不用再查了
        if assetName.isEmpty {
            assetName = BKVideoLibrary.assetName(localID: assetLocalID)
        }
    }
}

// MARK: - 草稿批（第一层）

/// 一次导入 = 一个草稿批，里面装着这一次选中的所有素材。
///
/// 【为什么是两层而不是「一视频一草稿」】
/// 皓哥 2026-10-02 口述：一次加的多条素材本来就是**同一场景的不同口播片段**。
/// 打包成一批之后，导出到剪映发现问题，「回马枪」点一次就能回到那一整批现场，
/// 不用在草稿箱里翻零散的 5 条。他听完我的复述说「就是这样」。
///
/// 【everEdited 的语义（定稿 3.1）】
/// 判据是「**曾经**动过刀」，不是「退出时还有没有刀」。
/// 曾经动过刀 → **永不自动删**，哪怕后来又把刀全删干净了。
/// 理由：一旦入过库，用户心里就认为它已经存下了，再让它凭空消失会让人以为数据丢了。
/// 它**只置不清** —— 撤销是把刀撤掉，不是把「我编辑过这件事」抹掉。
struct BKDraftBatch: Codable, Identifiable {

    var id: UUID
    /// 显示在草稿卡片上的名字。默认「IMG_3027 等 5 条」，可重命名
    var title: String
    /// 这一批的素材项。☰ 素材列表里看到的就是它
    var items: [BKProject]
    /// 上次在改哪一条。封面取它的指针帧，重进也是进这一条
    var lastAssetId: String?
    var createdAt: Date
    var lastEditedAt: Date
    /// 曾经动过刀没有。只置不清，见上面的说明
    var everEdited: Bool
    /// nil = 在网格里；有值 = 已移进回收站，值是删除时间（30 天后自动清空）
    var deletedAt: Date?

    // MARK: 派生

    /// 这一批的合计刀数。起始页角标显示的就是它
    var totalCuts: Int {
        items.reduce(0) { $0 + $1.cutCount }
    }

    /// 这一批里动过刀的素材项（批量导出的范围，定稿 4.8）
    var editedItems: [BKProject] {
        items.filter { $0.isEdited }
    }

    /// 网格上显示的名字。没命名过就用「第一条素材名 + 等 N 条」
    var displayTitle: String {
        if !title.isEmpty { return title }
        guard let first = items.first else { return "草稿" }
        let n = items.count
        return n > 1 ? "\(first.assetName) 等 \(n) 条" : first.assetName
    }

    /// 封面取哪条素材。lastAssetId 失效（素材被删）时退回第一条
    func coverAssetId() -> String? {
        if let lid = lastAssetId, items.contains(where: { $0.assetLocalID == lid }) {
            return lid
        }
        return items.first?.assetLocalID
    }

    /// 时长最长那条的索引。批量导出时全批按它的参数统一（定稿 4.9.1）
    func longestItemIndex() -> Int? {
        guard !items.isEmpty else { return nil }
        var best = 0
        for i in 1 ..< items.count where items[i].duration > items[best].duration {
            best = i
        }
        return best
    }

    /// 是否被移进回收站
    var isTrashed: Bool { deletedAt != nil }

    /// 回收站里的剩余天数（已过期返回 0）
    var trashDaysLeft: Int {
        guard let d = deletedAt else { return BKConfig.Draft.trashKeepDays }
        let passed = Date().timeIntervalSince(d) / 86400.0
        return max(0, BKConfig.Draft.trashKeepDays - Int(passed.rounded(.down)))
    }
}

// MARK: - 草稿批解码兼容

extension BKDraftBatch {

    enum BatchCodingKeys: String, CodingKey {
        case id, title, items, lastAssetId, createdAt, lastEditedAt
        case everEdited, deletedAt
    }

    /// 同样是为主兼容：老版本写出去的文件没有 deletedAt / everEdited，
    /// 合成 init 遇到缺 key 会 throw，一 throw 用户的草稿就没了
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: BatchCodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        items = (try? c.decodeIfPresent([BKProject].self, forKey: .items)) ?? []
        lastAssetId = try? c.decodeIfPresent(String.self, forKey: .lastAssetId)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        lastEditedAt = (try? c.decodeIfPresent(Date.self, forKey: .lastEditedAt)) ?? Date()
        everEdited = (try? c.decodeIfPresent(Bool.self, forKey: .everEdited)) ?? false
        deletedAt = try? c.decodeIfPresent(Date.self, forKey: .deletedAt)
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

    // MARK: - v1.3.0 段模型（删红键地基）

    /// 一段素材的状态。
    ///
    /// 【为什么不是新增一个存储，而是继续用 BKMark】
    /// v1.3.0 原计划把 `marks` 变成派生、`keepRanges` 改 computed。动手前先用 Python 复刻验证
    /// （tools/diag_segment_model.py，6000 组随机脏数据全绿）：**现有 build/normalize 已经做到了
    /// 「覆盖 [0,duration] / 相邻严丝合缝 / 无零宽 / 重叠裁断 / 缝隙补 keep / 同类合并」**，
    /// 也就是说「段」这个语义现在已经被推导出来了，只是推导发生在 `pieces()`（显示用）里，
    /// 而 `keepRanges` / `cutRanges` 各自 filter 一次。
    /// 所以**重写数据模型风险高、收益低**，改成在现有基础上叠加这一层操作。
    /// `marks` 的存储与落盘格式**一个字没动**，旧草稿照常读。
    enum SegState {
        case keep      // 绿区：导出后保留
        case cut       // 红区：导出后不保留
    }

    /// 素材是否被「删红键」折叠过。折叠是真折叠：绿区 ripple 拼接、时间轴变短，
    /// 但 **.cut 段的源区间永远保留**（这就是皓哥说的「缓存」）——
    /// 折叠只影响渲染与播放，不销毁源时间，日后拖接缝能把已删素材拖回来。
    /// ⚠️ 这个标志存在 `marks` 之外（`BKProject.redFolded`），因为它是「整条素材」级别的状态，
    /// 不是某一段的属性。
    static func foldedPieces(duration: Double,
                             cuts: [(Double, Double)],
                             splits: [Double],
                             redFolded: Bool) -> [BKMark] {
        let base = pieces(duration: duration, cuts: cuts, splits: splits)
        guard redFolded else { return base }
        // 折叠 = 只留 keep 段，按原顺序首尾相接拼成一条连续的绿轨。
        // 相邻两个 keep 之间原本夹着 cut，拼接后中间的空洞就合上了 —— 这就是 ripple。
        let kept = base.filter { $0.kind == .keep }
        guard !kept.isEmpty else { return base }
        var out: [BKMark] = []
        var cursor: Double = 0
        for m in kept {
            let len = m.end - m.start
            out.append(BKMark(start: cursor, end: cursor + len, kind: .keep))
            cursor += len
        }
        return out
    }

    /// 折叠后的成品时长（= 总时长 − 被删红区总长）。
    /// （原先写成返回「删除总长」，且拿 greatestFiniteMagnitude 当 duration —— 都会出错，直接重写。）
    static func foldedOutputDuration(duration: Double, cuts: [(Double, Double)]) -> Double {
        let clean = merge(cuts, duration: duration)
        let removed = clean.reduce(0.0) { $0 + ($1.1 - $1.0) }
        return max(0, duration - removed)
    }

    /// 折叠映射表 [(成品起点, 原片起点, 时长)]。
    /// 折叠后轨道画布的时间轴是「成品时间」，而波形包络是「原片时间」，
    /// 两者靠这张表对应起来 —— 不给的话波形会整体画错位置。
    /// 与 `foldedPieces` 的拼接规则严格一致（都只取 keep 段、首尾相接）。
    static func foldMap(duration: Double, cuts: [(Double, Double)]) -> [(out: Double, src: Double, dur: Double)] {
        let base = build(duration: duration, cuts: cuts)
        var out: [(out: Double, src: Double, dur: Double)] = []
        var cursor: Double = 0
        for m in base where m.kind == .keep {
            let len = m.end - m.start
            out.append((out: cursor, src: m.start, dur: len))
            cursor += len
        }
        return out
    }

    /// 段模型里「一个绿区」的定义，供拖把手时夹边界用。
    /// 返回该时刻所在的 keep 段下标；不在任何 keep 段里返回 nil。
    static func keepIndex(at time: Double, in marks: [BKMark]) -> Int? {
        for i in 0 ..< marks.count where marks[i].kind == .keep {
            if time >= marks[i].start - 1e-9 && time <= marks[i].end + 1e-9 { return i }
        }
        return nil
    }

    /// 拖动某一段的**开头**，做三重夹取（v1.3.0 定稿 4.3）：
    ///   ① 不越过原视频开头（0 之前没素材）
    ///   ② 不越过本段终点减最短长度（否则压碎）
    ///   ③ 不往右拖过原起点（那叫「改段边界」，是另一件事，由 N4 的语义处理）
    ///
    /// 段本身的状态（绿/红）不变；扫过的新区域继承该段同色，由调用方拿返回的新区间去改 cuts。
    static func clampHead(_ newHead: Double,
                          ofSegmentAt index: Int,
                          in marks: [BKMark],
                          minSeg: Double) -> Double? {
        guard index >= 0, index < marks.count else { return nil }
        let segStart = marks[index].start
        let segEnd = marks[index].end
        // ① 资产开头 0；② 最短段 → 上限是本段终点往前 minSeg
        let lowerBound = 0.0
        let upperBound = segEnd - minSeg
        guard upperBound > lowerBound else { return nil }
        // ③ 只允许往左拖（扩大本段）。往右拖 = 缩小，交给 moveBoundary 那条路
        if newHead > segStart { return segStart }
        return min(max(newHead, lowerBound), upperBound)
    }

    /// 拖动某一段的**结尾**，三重夹取（对称于 clampHead）
    static func clampTail(_ newTail: Double,
                          ofSegmentAt index: Int,
                          in marks: [BKMark],
                          minSeg: Double,
                          duration: Double) -> Double? {
        guard index >= 0, index < marks.count else { return nil }
        let segStart = marks[index].start
        let segEnd = marks[index].end
        let lowerBound = segStart + minSeg    // 不压碎
        let upperBound = duration             // 不越过原视频结尾
        guard upperBound > lowerBound else { return nil }
        // 只允许往右拖（扩大本段）
        if newTail < segEnd { return segEnd }
        return min(max(newTail, lowerBound), upperBound)
    }
}
