//
//  BKDraftStore.swift
//  bk剪辑 — 草稿落盘
//
//  【存的是什么】
//  一个文件 = **一次导入的一整批**（BKDraftBatch），里面装着这一批的所有素材项。
//  不是「一视频一文件」—— 皓哥 2026-10-02 定的两层模型，理由见 BKModels 的注释。
//
//  【要达成的效果：关掉 App 下次打开还在编辑同一条】
//  这句话听起来像需要一个「退出时保存」的回调，但 iOS 不给这个机会 ——
//  上滑强杀 App 时 applicationWillTerminate 不一定被调用。
//
//  所以实际做法是反过来的：**编辑过程中就一直落盘**，退出与否根本不重要。
//  每次改动攒 2 秒（debounce）写一次；进后台时再补一刀把没写完的刷下去。
//  这样无论你怎么杀 App，磁盘上最多差 2 秒的进度。
//
//  【为什么用 .atomic】
//  写到一半被杀 = 半个 JSON 文件 = 下次打开解析失败 = 用户以为工程丢了。
//  atomic 是先写临时文件再 rename，rename 在文件系统层是原子的，
//  要么拿到旧文件要么拿到新文件，不存在中间态。
//
//  【老草稿怎么办】
//  这个版本之前，一个文件存的是一个 BKProject（单条素材）。
//  皓哥手机上已经存着这类文件，直接换格式会让它们解析失败、看起来像「草稿没了」。
//  所以 loadAll 里做了兼容：先按 BKDraftBatch 解，失败了再按老格式 BKProject 解，
//  解出来就包成一个批接上去。老用户的历史不丢。
//

import Foundation

final class BKDraftStore {

    static let shared = BKDraftStore()

    // MARK: - 路径

    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private let lastOpenedKey = "bk_last_opened_batch"
    private let debounceSec = BKConfig.Draft.debounceSec

    // MARK: - 内部状态

    private var pending: BKDraftBatch?
    private var scheduledWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "bk.draft.store", qos: .utility)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {}

    // MARK: - 写入

    /// 安排一次保存。连续调用只会落最后一次 —— debounce 的意义就在这：
    /// 拖滑块时每秒触发几十次，不该写几十次文件
    func scheduleSave(_ batch: BKDraftBatch) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending = batch
            self.scheduledWork?.cancel()

            let work = DispatchWorkItem { [weak self] in
                guard let self, let b = self.pending else { return }
                self.write(b)
            }
            self.scheduledWork = work
            self.queue.asyncAfter(deadline: .now() + self.debounceSec, execute: work)
        }
    }

    /// 立即把待写的内容落盘。进后台、导出前该调这个。
    /// 「立即」是相对 debounce 说的，实际仍然异步执行以免卡住调用方
    func flushIfNeeded() {
        queue.async { [weak self] in
            guard let self else { return }
            self.scheduledWork?.cancel()
            self.scheduledWork = nil
            guard let b = self.pending else { return }
            self.write(b)
        }
    }

    /// 取消还没落盘的那一次写入。
    ///
    /// ⚠️ 必须有的一个口子：编辑页退出时若发现「整批一刀没切」会直接删掉草稿，
    /// 但 debounce 队列里可能还压着一次待写 —— 不取消的话它两秒后照写不误，
    /// 把刚删掉的文件又变回来（表现为「说好不留的草稿怎么还在」）
    func cancelPending() {
        queue.async { [weak self] in
            guard let self else { return }
            self.scheduledWork?.cancel()
            self.scheduledWork = nil
            self.pending = nil
        }
    }

    private func write(_ batch: BKDraftBatch) {
        let url = fileURL(for: batch.id)
        let bak = url.appendingPathExtension("bak1")
        // 先删旧的再拷：copyItem 遇到已存在的目标会直接失败，
        // 那样 .bak1 永远停留在第一次写的那一版，起不到备份作用
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.copyItem(at: url, to: bak)

        do {
            let data = try encoder.encode(batch)
            try data.write(to: url, options: .atomic)
            pending = nil
            BKLog.shared.d(String(format: "草稿已保存 %@ · %d KB · 合计 %d 刀",
                                  batch.id.uuidString.prefix(8), data.count / 1024, batch.totalCuts))
        } catch {
            // 保存失败不打日志也白搭 —— 磁盘满是最常见的原因，
            // 而这类失败用户完全感知不到，只会觉得「上次的工程没了」
            BKLog.shared.e("草稿保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 读取

    func load(id: UUID) -> BKDraftBatch? {
        decodeBatch(at: fileURL(for: id))
    }

    /// 读一个文件。**兼容老格式**：先按批解，失败再按单条工程解并包成一批
    private func decodeBatch(at url: URL) -> BKDraftBatch? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        if var batch = try? decoder.decode(BKDraftBatch.self, from: data) {
            batch.items = normalized(batch.items)
            return batch
        }

        // 老格式：一个文件 = 一条素材。包成一个只有一条的批，历史不丢
        if var old = try? decoder.decode(BKProject.self, from: data) {
            old.marks = BKTimeline.normalize(old.marks, duration: old.duration)
            var batch = BKDraftBatch(id: old.id,
                                     title: old.assetName,
                                     items: [old],
                                     lastAssetId: old.assetLocalID,
                                     createdAt: old.createdAt,
                                     lastEditedAt: old.updatedAt,
                                     everEdited: old.isEdited,
                                     deletedAt: nil)
            // 立刻按新格式回写一次，之后就走新路径了
            write(batch)
            BKLog.shared.i("老格式草稿已升级为批次 \(old.id.uuidString.prefix(8))")
            return batch
        }

        BKLog.shared.e("草稿解析失败 \(url.lastPathComponent)，已跳过")
        return nil
    }

    /// 从磁盘读回来的东西不能无条件信任：上一个版本可能有 bug。
    /// 交付给 UI 之前，每条素材的 marks 都先过一遍 normalize 修回来
    private func normalized(_ items: [BKProject]) -> [BKProject] {
        items.map { item in
            var p = item
            p.marks = BKTimeline.normalize(p.marks, duration: p.duration)
            return p
        }
    }

    /// 网格里显示的草稿：没被删的、按最后编辑时间倒序、最多 10 批
    var allBatches: [BKDraftBatch] {
        purgeExpiredTrash()
        let all = loadAll().filter { !$0.isTrashed }
        return Array(all.prefix(BKConfig.Draft.maxBatches))
    }

    /// 回收站里的草稿
    var trashedBatches: [BKDraftBatch] {
        loadAll().filter { $0.isTrashed }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// 读盘。一次全读，之后在内存里过滤 ——
    /// 草稿最多十几个文件，每个几百字节，反复读盘的开销远小于维护索引的复杂度
    private func loadAll() -> [BKDraftBatch] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { decodeBatch(at: $0) }
            .sorted { $0.lastEditedAt > $1.lastEditedAt }
    }

    // MARK: - 删除 / 恢复 / 回收站

    /// 删除 ≠ 销毁：打一个时间戳挪进「最近删除」，30 天后才真的清掉（定稿 3.2）
    func moveToTrash(_ batch: BKDraftBatch) {
        var b = batch
        b.deletedAt = Date()
        pending = b
        write(b)
        if lastOpenedID == b.id { lastOpenedID = nil }
        BKLog.shared.i("草稿已移到最近删除 \(b.id.uuidString.prefix(8))")
    }

    /// 恢复。**先检查原视频还在不在相册里** ——
    /// 用户可能删了草稿又把原片删了，那种情况给人话提示，别崩
    func restore(_ batch: BKDraftBatch) -> (ok: Bool, missing: [String]) {
        let missing = batch.items
            .filter { BKVideoLibrary.phAsset(localID: $0.assetLocalID) == nil }
            .map { $0.assetName }
        var b = batch
        b.deletedAt = nil
        pending = b
        write(b)
        BKLog.shared.i("草稿已恢复 \(b.id.uuidString.prefix(8))\(missing.isEmpty ? "" : "（有 \(missing.count) 条原片已失效）")")
        return (true, missing)
    }

    func permanentlyDelete(_ batch: BKDraftBatch) {
        let fm = FileManager.default
        try? fm.removeItem(at: fileURL(for: batch.id))
        try? fm.removeItem(at: fileURL(for: batch.id).appendingPathExtension("bak1"))
        BKCovers.remove(batchId: batch.id)
        if lastOpenedID == batch.id { lastOpenedID = nil }
        BKLog.shared.i("草稿已彻底删除 \(batch.id.uuidString.prefix(8))")
    }

    /// 清空回收站
    func emptyTrash() {
        for b in trashedBatches { permanentlyDelete(b) }
        BKLog.shared.i("回收站已清空")
    }

    /// 超过 30 天的自动清掉。每次读列表时顺手跑一次，不单独开定时器
    private func purgeExpiredTrash() {
        let limit = TimeInterval(BKConfig.Draft.trashKeepDays * 86400)
        var purged = 0
        for b in loadAll() where b.isTrashed {
            if let d = b.deletedAt, Date().timeIntervalSince(d) > limit {
                permanentlyDelete(b)
                purged += 1
            }
        }
        if purged > 0 { BKLog.shared.i("回收站自动清空 \(purged) 批（超过 \(BKConfig.Draft.trashKeepDays) 天）") }
    }

    // MARK: - 最后编辑的批

    var lastOpenedID: UUID? {
        get {
            guard let s = UserDefaults.standard.string(forKey: lastOpenedKey) else { return nil }
            return UUID(uuidString: s)
        }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: lastOpenedKey) }
    }

    func markOpened(_ id: UUID) {
        lastOpenedID = id
        BKLog.shared.d("记录最后编辑批 \(id.uuidString.prefix(8))")
    }

    /// 全部草稿累计导出的成品条数。起始页那句「v1.0 · 已导出 N 条」用它
    var totalExportCount: Int {
        loadAll().reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.exportHistory.count } }
    }

    // MARK: - 工具

    private func fileURL(for id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).json")
    }

    var totalSizeText: String {
        let size = BKProbe.folderSize(at: dir)
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
