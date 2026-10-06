//
//  BKDraft.swift
//  bk剪辑 v2.0 — 顶层草稿（包装 BKTrackModel）
//
//  【v2.0 的全新草稿模型，不是 v1.x 的改造】
//  设计真源：docs/v2.0数据模型-多片段主轨与变速坐标.md
//
//  v1 的「两层模型」是 BKDraftBatch → [BKProject]（一批 = 多条素材项）。
//  v2 里「一个草稿 = 一条多片段主轨」，所以这里直接用 BKTrackModel
//  （blocks: [BKClipBlock]）当顶层容器，不再有「批 / 素材项」两层。
//
//  【本文件只 import Foundation】—— 和 BKTrackModel 一样，保持 Core 干净，
//  不碰 Photos / UIKit，方便以后进 SPM 测试 target。
//  需要素材名（assetName）这类 UI 层信息时，由外层 UI 用 BKVideoLibrary 取，
//  本模型只存 localIdentifier。
//
//  【Batch 1 临时状态】编辑页（BKEditorViewController）还没迁 v2，仍吃 v1 BKDraftBatch。
//  起始页点开草稿时由 bridgeToV1 把本模型转成 v1 喂给它（见 BKRootViewController）。
//  Batch 2 重写编辑页为 v2 后，桥接删除、全工程统一走本模型。
//

import Foundation

/// v2.0 草稿：一条多片段主轨 + 工程级元数据。
struct BKDraft: Codable, Identifiable {

    var id: UUID
    /// 显示在草稿卡片上的名字。默认空，由 displayTitle 兜底成「第一条素材名 等 N 条」
    var title: String
    /// 主轨（多片段）。草稿的全部剪辑内容都在这里
    var track: BKTrackModel
    /// 上次在编哪条素材（封面取它的帧，重进也进这一条）。存 localIdentifier
    var lastAssetId: String?
    var createdAt: Date
    var lastEditedAt: Date
    /// 曾经动过刀没有。只置不清 —— 退出编辑页时据此决定留不留草稿
    var everEdited: Bool
    /// nil = 在网格里；有值 = 已移进回收站，值是删除时间（30 天后自动清空）
    var deletedAt: Date?

    // MARK: 初始化

    init(id: UUID = UUID(),
         title: String = "",
         blocks: [BKClipBlock],
         lastAssetId: String? = nil,
         createdAt: Date = Date(),
         lastEditedAt: Date = Date(),
         everEdited: Bool = false,
         deletedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.track = BKTrackModel(blocks: blocks)
        self.lastAssetId = lastAssetId ?? blocks.first?.assetLocalID
        self.createdAt = createdAt
        self.lastEditedAt = lastEditedAt
        self.everEdited = everEdited
        self.deletedAt = deletedAt
    }

    // MARK: 派生

    var blockCount: Int { track.blocks.count }

    /// 是否被移进回收站
    var isTrashed: Bool { deletedAt != nil }

    /// 合计刀数（卡片角标用）。v2 里「动过刀」= 某块被波剪过（keptRanges 多段）。
    /// 未波剪的块算 0 刀；波剪过 = 绿区段数 − 1
    var totalCuts: Int {
        track.blocks.reduce(0) { $0 + max(0, $1.keptRanges.count - 1) }
    }

    /// 主轨总时长（秒）
    var totalDuration: Double { track.total }

    /// 封面取哪条素材的 localID（最后编辑那条 / 第一条）。一键回马枪要接得上
    func coverAssetId() -> String? {
        if let lid = lastAssetId, track.blocks.contains(where: { $0.assetLocalID == lid }) {
            return lid
        }
        return track.blocks.first?.assetLocalID
    }

    /// 回收站剩余天数（已过期返回 0）
    var trashDaysLeft: Int {
        guard let d = deletedAt else { return BKConfig.Draft.trashKeepDays }
        let passed = Date().timeIntervalSince(d) / 86400.0
        return max(0, BKConfig.Draft.trashKeepDays - Int(passed.rounded(.down)))
    }

    /// 显示名。本模型不碰 Photos，素材名由外层 UI 用 BKVideoLibrary.assetName 取后传入
    func displayTitle(firstName: String) -> String {
        if !title.isEmpty { return title }
        guard !track.blocks.isEmpty else { return "草稿" }
        let n = track.blocks.count
        if n > 1 { return "\(firstName) 等 \(n) 条" }
        return firstName.isEmpty ? "草稿" : firstName
    }
}
