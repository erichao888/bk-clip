//
//  BKLog.swift
//  bk剪辑 — 日志核心
//
//  【为什么单独成一个文件、并且必须在 Core 层】
//  1. 皓哥没有 Mac，看不到 Xcode 控制台。真机上出问题时，日志是我唯一的远程眼睛。
//     没有它，每一轮排障都只能靠猜 —— 猜错就是重装重试，白白浪费一个编译轮次。
//  2. 之前 BKLog 混在 app/DebugConsole.swift 里（那个文件是 UI 面板，import UIKit），
//     连日志级别的颜色都写成了 UIColor。Core 层的铁律是「禁 import UIKit」：
//     一旦哪天想在纯逻辑层（比如导出管线、算法）打点，就会被迫把 UIKit 拖进来。
//     所以这里把日志核心抽出来，只依赖 Foundation，UI 只负责显示。
//
//  【这一版补了三件事（2026-10-05）】
//  · 崩溃自捕获：NSException + 常见致命信号，写 crash 文件，下次启动能报出来
//  · 落盘多代轮转：bk.log 写满后依次退成 bk.1.log ~ bk.4.log，不会只留一份
//  · 结构化打点：带标签 + k=v 参数，便于我把日志直接喂给 Python 验证脚本复现
//
//  【接入】AppDelegate.didFinishLaunching 里调一次 BKLog.shared.install()
//
//  【注意】不要在信号处理器里做复杂事（会二次崩溃）。信号处理器只用 write()
//  往预打开的 fd 写一行；真正的崩溃报告由 NSException 处理器和下次启动补齐。
//

import Foundation
import Darwin

// MARK: - 级别

/// 级别沿用旧版 5 档，顺序和数字都不要动 —— DebugConsole 的筛选控件
/// 按下标映射 allCases，插一档或换顺序会让筛选条错位。
public enum BKLogLevel: Int, CaseIterable, Comparable {
    case verbose = 0, debug, info, warn, error

    public static func < (lhs: BKLogLevel, rhs: BKLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var tag: String {
        switch self {
        case .verbose: return "V"
        case .debug:   return "D"
        case .info:    return "I"
        case .warn:    return "W"
        case .error:   return "E"
        }
    }
}

// MARK: - 标签

/// 打点时带上，方便我按模块筛。导出/坐标这两块是重点盯防对象。
public enum BKLogTag: String {
    case timeline          // 主轨时间轴、区块增删改
    case foldmap           // 轨道时间 → 源时间映射（折叠）
    case speed             // 变速
    case export            // 导出管线
    case audio             // 音频/包络/波形
    case video             // 素材读取、尺寸方向
    case thumb             // 缩略图
    case draft             // 草稿读写
    case auth              // 相册 / 麦克风授权
    case ui                // 界面流程
    case rec               // 录音轨
    case pip               // 画中画轨
    case other
}

// MARK: - 条目

public struct BKLogEntry {
    let timestamp: Date
    let level: BKLogLevel
    let message: String
    let file: String
    let line: Int
    let function: String

    /// 一行日志的最终形态。拆成两段拼，是踩过类型检查超时的坑之后养成的习惯：
    /// 单行里塞太多插值 + 拼接，Swift 类型检查会显著变慢甚至超时。
    var formatted: String {
        let head = "\(BKLogEntry.stamp(timestamp)) [\(level.tag)]"
        let tail = "\(file):\(line) \(function) | \(message)"
        return head + " " + tail
    }

    var shortTime: String { BKLogEntry.clockFormat(timestamp) }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func stamp(_ d: Date) -> String { fmt.string(from: d) }
    static func clockFormat(_ d: Date) -> String { clock.string(from: d) }
}

// MARK: - 回调

protocol BKLogSink: AnyObject {
    func logDidAppend()
}

// MARK: - 日志主体

public final class BKLog {

    public static let shared = BKLog()

    /// 内存里保留的条数，防止长时间跑占内存
    public let capacity = 3000

    weak var sink: BKLogSink?

    // MARK: 目录与文件

    private let dir: URL
    private let fileURL: URL
    private let crashesDir: URL
    private let runningMarkerURL: URL

    /// 单个日志文件上限。写满就往后退一代
    private let maxFileSize: UInt64 = 4 * 1024 * 1024
    /// 备份代际数：bk.1.log（最新）… bk.4.log（最老，超了就删）
    private let maxGenerations = 4
    /// 崩溃报告最多留几份
    private let maxCrashFiles = 3

    private let lock = NSLock()
    private var records: [BKLogEntry] = []
    private let writeQueue = DispatchQueue(label: "com.benka.bkclip.log.write")

    /// 崩溃文件句柄。信号处理器只能用它 write()，不能用 FileManager
    private static var crashFd: Int32 = -1
    private static var crashFileURL: URL?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("logs", isDirectory: true)
        dir = base
        fileURL = base.appendingPathComponent("bk.log")
        crashesDir = base.appendingPathComponent("crashes", isDirectory: true)
        runningMarkerURL = base.appendingPathComponent("running.marker")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: crashesDir, withIntermediateDirectories: true)
    }

    // MARK: - 安装（崩溃捕获 + 上次异常退出检测）

    /// 在 AppDelegate.didFinishLaunching 里调用一次。
    /// 顺序有讲究：先装处理器（越早越好），再检查上次是不是没正常退出。
    func install() {
        installSignalHandlers()

        if FileManager.default.fileExists(atPath: runningMarkerURL.path) {
            // 标记还在 = 上次没走到「正常退出」这一步，属于崩溃或被系统杀掉
            let detail = newestCrashFileText()
            if detail == nil {
                e("上次异常退出：进程被终止（无崩溃报告，多半是内存被系统回收 / 后台被杀）")
            } else {
                e("上次异常退出：已捕获崩溃报告，见调试面板或 crashes 目录")
            }
        }
        // 重新立标记；下次启动若还在，就说明本次又没正常出去
        try? Data().write(to: runningMarkerURL)

        i("=== 会话开始 \(Self.sessionHeaderLine()) ===")
    }

    /// 应用进入后台时调用：本次算「正常挂起」，清掉运行标记。
    ///  取舍说明：iOS 上滑强杀 / 后台回收**不给任何回调**，只在 willTerminate 清标记的话，
    ///  几乎每次启动都会误报「异常退出」，噪声大到没人看。所以这里在进后台就清 ——
    ///  真正闪退都发生在前台，根本走不到这一步，能被准确抓到；
    ///  后台被回收的少数情况，配合日志里「进入后台」那一行也能分辨出来。
    func markCleanExit() {
        try? FileManager.default.removeItem(at: runningMarkerURL)
    }

    private func installSignalHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            BKLog.shared.handleException(exception)
        }

        // 打开崩溃文件并常驻 fd，供信号处理器安全写入
        let url = crashesDir.appendingPathComponent(Self.crashFileName())
        Self.crashFileURL = url
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        Self.crashFd = open(url.path, O_WRONLY | O_APPEND)
        if Self.crashFd < 0 { Self.crashFd = -1 }

        _ = signal(SIGABRT, Self.onSignal)
        _ = signal(SIGSEGV, Self.onSignal)
        _ = signal(SIGBUS,  Self.onSignal)
        _ = signal(SIGILL,  Self.onSignal)
        _ = signal(SIGFPE,  Self.onSignal)
    }

    /// 信号处理：只做一件事 —— 往预打开的 fd 写一行。
    /// 这里绝不能加锁、不能碰 Swift 对象、不能调 FileManager，否则极易二次崩溃。
    private static let onSignal: @convention(c) (Int32) -> Void = { sig in
        let text = "[CRASH] signal=\(sig)\n"
        text.withCString { p in
            _ = write(BKLog.crashFd, p, Int(strlen(p)))
        }
        _ = signal(sig, SIG_DFL)   // 交还给系统默认处理，让它生成正常崩溃流程
    }

    /// NSException 不是信号上下文，可以放心组装完整报告（含调用栈 + 死前面包屑）
    private func handleException(_ ex: NSException) {
        let name = ex.name.rawValue
        let reason = ex.reason ?? ""
        writeCrashReport(title: "NSException \(name)",
                         detail: reason,
                         stack: ex.callStackSymbols)
    }

    private func writeCrashReport(title: String, detail: String, stack: [String]) {
        var out: [String] = []
        out.append("===== bk剪辑 崩溃报告 =====")
        out.append("时间：\(Self.fullTimeString(Date()))")
        out.append("标题：\(title)")
        out.append("详情：\(detail)")
        out.append(Self.sessionHeaderLine())
        out.append("")
        out.append("---- 死前最后 80 条 ----")
        lock.lock()
        let tail = Array(records.suffix(80))
        lock.unlock()
        for e in tail { out.append(e.formatted) }
        out.append("")
        out.append("---- 调用栈 ----")
        for line in stack { out.append(line) }
        out.append("===== 报告结束 =====")

        let text = out.joined(separator: "\n") + "\n"
        let url = crashesDir.appendingPathComponent(Self.crashFileName())
        try? text.write(to: url, atomically: true, encoding: .utf8)
        pruneCrashFiles()
    }

    // MARK: - 写入

    public func log(_ message: String,
                    level: BKLogLevel = .info,
                    file: String = #file,
                    line: Int = #line,
                    function: String = #function) {
        let entry = BKLogEntry(timestamp: Date(),
                               level: level,
                               message: message,
                               file: (file as NSString).lastPathComponent,
                               line: line,
                               function: function)
        lock.lock()
        records.append(entry)
        if records.count > capacity { records.removeFirst(records.count - capacity) }
        lock.unlock()

        writeQueue.async { [weak self] in self?.writeToDisk(entry) }
        DispatchQueue.main.async { [weak self] in self?.sink?.logDidAppend() }
    }

    public func v(_ m: String, file: String = #file, line: Int = #line, function: String = #function) { log(m, level: .verbose, file: file, line: line, function: function) }
    public func d(_ m: String, file: String = #file, line: Int = #line, function: String = #function) { log(m, level: .debug, file: file, line: line, function: function) }
    public func i(_ m: String, file: String = #file, line: Int = #line, function: String = #function) { log(m, level: .info, file: file, line: line, function: function) }
    public func w(_ m: String, file: String = #file, line: Int = #line, function: String = #function) { log(m, level: .warn, file: file, line: line, function: function) }
    public func e(_ m: String, file: String = #file, line: Int = #line, function: String = #function) { log(m, level: .error, file: file, line: line, function: function) }

    // MARK: 结构化打点（★ 带标签 + k=v，方便我把日志喂给验证脚本复现）

    /// 例：BKLog.shared.info(.foldmap, "切割落点", ["block": 3, "trackT": 12.34, "sp": 1.0])
    /// 输出：I … | [foldmap] 切割落点 block=3 sp=1.0 trackT=12.34
    public func info(_ tag: BKLogTag, _ msg: String, _ params: [String: Any] = [:],
                     file: String = #file, line: Int = #line, function: String = #function) {
        log(Self.compose(tag, msg, params), level: .info, file: file, line: line, function: function)
    }

    public func warn(_ tag: BKLogTag, _ msg: String, _ params: [String: Any] = [:],
                     file: String = #file, line: Int = #line, function: String = #function) {
        log(Self.compose(tag, msg, params), level: .warn, file: file, line: line, function: function)
    }

    public func error(_ tag: BKLogTag, _ msg: String, _ params: [String: Any] = [:],
                      file: String = #file, line: Int = #line, function: String = #function) {
        log(Self.compose(tag, msg, params), level: .error, file: file, line: line, function: function)
    }

    /// k=v 按键名排序，保证同一操作每次输出一致（便于比对）
    private static func compose(_ tag: BKLogTag, _ msg: String, _ params: [String: Any]) -> String {
        var head = "[" + tag.rawValue + "] " + msg
        if params.isEmpty { return head }
        let body = params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined(separator: " ")
        head += " " + body
        return head
    }

    /// 计时埋点，自动打印耗时
    @discardableResult
    public static func measure<T>(_ label: String, _ block: () throws -> T) rethrows -> T {
        let start = Date()
        defer {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            shared.d("⏱ \(label) 耗时 \(ms)ms")
        }
        return try block()
    }

    // MARK: - 读取

    public func snapshot(minLevel: BKLogLevel = .verbose, keyword: String = "") -> [BKLogEntry] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock()
        let all = records
        lock.unlock()
        return all.filter { entry in
            guard entry.level >= minLevel else { return false }
            if kw.isEmpty { return true }
            return entry.message.lowercased().contains(kw)
                || entry.file.lowercased().contains(kw)
                || entry.function.lowercased().contains(kw)
        }
    }

    public func clear() {
        lock.lock()
        records.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
        DispatchQueue.main.async { [weak self] in self?.sink?.logDidAppend() }
    }

    // MARK: - 文件

    public var logFileURL: URL { fileURL }
    public var logDirectoryURL: URL { dir }

    /// 当前日志 + 历代备份，新的在前
    public var allLogFileURLs: [URL] {
        var list = [fileURL]
        for i in 1...maxGenerations {
            let u = generationURL(i)
            if FileManager.default.fileExists(atPath: u.path) { list.append(u) }
        }
        return list
    }

    public var logFileSizeText: String {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// 把还没落完的条目刷下去。AppDelegate 进后台时调一次。
    /// ⚠️ 不要在 writeQueue 内部调用（会自己等自己，死锁）
    public func flush() {
        writeQueue.sync { }
    }

    // MARK: 落盘与轮转

    private func writeToDisk(_ entry: BKLogEntry) {
        let text = entry.formatted + "\n"
        guard let data = text.data(using: .utf8) else { return }
        rotateIfNeeded()

        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
        } else if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// bk.log 写满 → bk.1.log（最新备份）… bk.4.log（最老，超出即删）
    private func rotateIfNeeded() {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
        guard size > maxFileSize else { return }
        let fm = FileManager.default
        var i = maxGenerations
        while i >= 2 {
            let dst = generationURL(i)
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: generationURL(i - 1), to: dst)
            i -= 1
        }
        try? fm.removeItem(at: generationURL(1))
        try? fm.moveItem(at: fileURL, to: generationURL(1))
    }

    private func generationURL(_ n: Int) -> URL {
        dir.appendingPathComponent("bk.\(n).log")
    }

    // MARK: 崩溃文件

    private static func crashFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "crash-" + f.string(from: Date()) + ".txt"
    }

    private func newestCrashFileText() -> String? {
        let urls = crashFileURLs()
        guard let newest = urls.first else { return nil }
        return try? String(contentsOf: newest, encoding: .utf8)
    }

    /// 崩溃报告列表，新的在前
    public func crashFileURLs() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: crashesDir,
                                                      includingPropertiesForKeys: [.creationDateKey],
                                                      options: []) else { return [] }
        return items.filter { $0.pathExtension == "txt" }
            .sorted { u1, u2 in
                let d1 = (try? u1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                let d2 = (try? u2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                return d1 > d2
            }
    }

    private func pruneCrashFiles() {
        let urls = crashFileURLs()
        guard urls.count > maxCrashFiles else { return }
        for u in urls.suffix(from: maxCrashFiles) {
            try? FileManager.default.removeItem(at: u)
        }
    }

    // MARK: - 导出（给巴蒂排障用）

    /// 会话头：版本 / 提交 / 机型 / 系统 / 磁盘。知道日志是哪一份代码跑出来的全靠它
    public static func sessionHeaderLine() -> String {
        let info = Bundle.main.infoDictionary
        let ver = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let sha = info?["BKCommitSHA"] as? String ?? "unknown"
        // 本地编译没走 CI 时，$(GIT_SHA) 不会被替换，值就是字面量 "$(GIT_SHA)" —— 认出来当没有
        let commit = (sha.isEmpty || sha.hasPrefix("$")) ? "unknown" : sha
        return "v\(ver) build \(build) commit \(commit) · \(deviceModel()) · iOS \(systemVersion())"
    }

    /// 拼一份可直接粘贴给巴蒂的文本：环境头 + 全部日志 + 崩溃报告
    public func exportText(minLevel: BKLogLevel = .verbose) -> String {
        var out: [String] = []
        out.append("===== bk剪辑 日志导出 =====")
        out.append("导出时间：\(Self.fullTimeString(Date()))")
        out.append(Self.sessionHeaderLine())
        out.append("日志文件：\(fileURL.path)")
        out.append("")
        for e in snapshot(minLevel: minLevel) { out.append(e.formatted) }
        if let crash = newestCrashFileText() {
            out.append("")
            out.append(crash)
        }
        out.append("===== 导出结束 =====")
        return out.joined(separator: "\n")
    }

    // MARK: - 环境

    private static func fullTimeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    /// 机型标识（如 iPhone16,2）。Core 层不能碰 UIDevice（那是 UIKit），走 uname
    private static func deviceModel() -> String {
        var sys = utsname()
        uname(&sys)
        let bytes = Mirror(reflecting: sys.machine).children
            .compactMap { $0.value as? Int8 }
            .prefix { $0 != 0 }
            .map { UInt8(truncatingIfNeeded: $0) }
        return String(bytes: bytes, encoding: .utf8) ?? "unknown"
    }

    private static func systemVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
