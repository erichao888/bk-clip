//
//  BKDraftStore.swift
//  bk剪辑 — 草稿落盘
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

    private let lastOpenedKey = "bk_last_opened_project"
    private let debounceSec = BKConfig.Draft.debounceSec
    private let keepHistory = BKConfig.Draft.keepHistory

    // MARK: - 内部状态

    private var pending: BKProject?
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
    func scheduleSave(_ project: BKProject) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending = project
            self.scheduledWork?.cancel()

            let work = DispatchWorkItem { [weak self] in
                guard let self, let p = self.pending else { return }
                self.write(p)
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
            guard let p = self.pending else { return }
            self.write(p)
        }
    }

    private func write(_ project: BKProject) {
        let url = fileURL(for: project.id)
        rotateBackup(of: url)

        do {
            let data = try encoder.encode(project)
            try data.write(to: url, options: .atomic)
            pending = nil
            BKLog.shared.d("草稿已保存 \(project.id.uuidString.prefix(8)) · \(data.count / 1024) KB · \(project.cutCount) 刀")
        } catch {
            // 保存失败不打日志也白搭 —— 磁盘满是最常见的原因，
            // 而这类失败用户完全感知不到，只会觉得「上次的工程没了」
            BKLog.shared.e("草稿保存失败：\(error.localizedDescription)")
        }
    }

    /// 备份轮转。留最近 keepHistory 份旧版本，
    /// 新的版本写坏时能往前回一步 —— 但也不会无限占空间
    private func rotateBackup(of url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }

        // 先把最老的一份丢掉
        let oldest = url.appendingPathExtension("bak\(keepHistory)")
        try? fm.removeItem(at: oldest)

        // 其余往后挪一位
        for n in stride(from: keepHistory - 1, through: 1, by: -1) {
            let from = url.appendingPathExtension("bak\(n)")
            let to = url.appendingPathExtension("bak\(n + 1)")
            if fm.fileExists(atPath: from.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }

        try? fm.copyItem(at: url, to: url.appendingPathExtension("bak1"))
    }

    // MARK: - 读取

    func load(id: UUID) -> BKProject? {
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            var p = try decoder.decode(BKProject.self, from: data)
            // normalize 兜的是第 02 章那条底线：从磁盘读回来的东西不能无条件信任。
            // 上一个版本可能有 bug、文件也可能被外部动过，交付给 UI 之前先修一遍
            p.marks = BKTimeline.normalize(p.marks, duration: p.duration)
            return p
        } catch {
            BKLog.shared.e("草稿解析失败 \(id.uuidString.prefix(8))：\(error.localizedDescription)")
            tryRecoverBackup(id: id)
            return nil
        }
    }

    /// 主文件坏了就往回试备份。这是留 .bak 的唯一价值
    private func tryRecoverBackup(id: UUID) {
        let base = fileURL(for: id)
        for n in 1...keepHistory {
            let url = base.appendingPathExtension("bak\(n)")
            guard let data = try? Data(contentsOf: url),
                  (try? decoder.decode(BKProject.self, from: data)) != nil else { continue }
            try? FileManager.default.copyItem(at: url, to: base)
            BKLog.shared.w("已从 bak\(n) 恢复工程 \(id.uuidString.prefix(8))")
            return
        }
        BKLog.shared.e("工程 \(id.uuidString.prefix(8)) 所有备份均无法解析")
    }

    /// 按素材 ID 找草稿。切换素材时要先看看这条素材有没有编过 ——
    /// 没有才新建工程，否则用户之前的刀口会凭空消失
    func draft(forLocalID id: String) -> BKProject? {
        allDrafts.first { $0.assetLocalID == id }
    }

    /// 全部草稿，按更新时间倒序
    var allDrafts: [BKProject] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> BKProject? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(BKProject.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func delete(id: UUID) {
        let base = fileURL(for: id)
        let fm = FileManager.default
        try? fm.removeItem(at: base)
        for n in 1...keepHistory {
            try? fm.removeItem(at: base.appendingPathExtension("bak\(n)"))
        }
        if lastOpenedID == id { lastOpenedID = nil }
        BKLog.shared.i("草稿已删除 \(id.uuidString.prefix(8))")
    }

    // MARK: - 最后编辑的工程
    //
    // 「下次打开接着编」全靠这一个 UserDefaults key。
    // 它很小，用 UserDefaults 而不是 draftStore 自己的文件，读起来最省事

    var lastOpenedID: UUID? {
        get {
            guard let s = UserDefaults.standard.string(forKey: lastOpenedKey) else { return nil }
            return UUID(uuidString: s)
        }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: lastOpenedKey) }
    }

    func markOpened(_ id: UUID) {
        lastOpenedID = id
        BKLog.shared.d("记录最后编辑工程 \(id.uuidString.prefix(8))")
    }

    /// 启动时决定打开哪一个。有上次打开的直接返回，否则给最近改过的那个
    func resumeProject() -> BKProject? {
        if let id = lastOpenedID, let p = load(id: id) { return p }
        return allDrafts.first
    }

    /// 全部草稿累计导出的成品条数。起始页那句「v1.0 · 已导出 N 条」用它。
    /// 走 allDrafts（真读文件）而不是缓存 —— 这个数只在进起始页时读一次，
    /// 为了它单独维护一份索引不值当
    var totalExportCount: Int {
        allDrafts.reduce(0) { $0 + $1.exportHistory.count }
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
