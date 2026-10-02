//
//  DebugConsole.swift
//  bk剪辑 — App 内调试面板
//
//  没有 Mac 就看不到 Xcode 控制台，这个文件就是替代品。
//
//  【接入三步】
//  1. 把本文件拖进 Xcode 工程
//  2. 写日志：BKLog.shared.i("xxx") / .w() / .e() / .d()
//     计时：BKLog.measure("提取波形") { ... }
//  3. 唤出面板（二选一，都写在响应速度最快的那个 VC 里）：
//     · 摇一摇：在剪辑界面的 VC 里加
//         override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
//             if motion == .motionShake { BKDebug.handleShake() }
//         }
//     · 连点版本号：设置页版本号那一行点一下调一次
//         BKDebug.tapVersionTag(self)
//         （默认连点 7 次弹出，推荐这个，防走路误触）
//
//  【为什么不用 #if DEBUG】
//  Ad Hoc 分发出来的是 Release 构建，编译宏不生效。这里用 UserDefaults 运行时开关，
//  线上包照样能开。关掉：BKDebug.isEnabled = false
//

import UIKit

// MARK: - 日志级别

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

    var color: UIColor {
        switch self {
        case .verbose: return UIColor(hex: 0x8E8E93)
        case .debug:   return UIColor(hex: 0x85B7EB)
        case .info:    return UIColor(hex: 0x8FC98A)
        case .warn:    return UIColor(hex: 0xEF9F27)
        case .error:   return UIColor(hex: 0xE24B4A)
        }
    }
}

public struct BKLogEntry {
    let timestamp: Date
    let level: BKLogLevel
    let message: String
    let file: String
    let line: Int
    let function: String

    var formatted: String {
        "\(Self.stamp(timestamp)) [\(level.tag)] \(file):\(line) \(function) | \(message)"
    }

    var shortTime: String {
        Self.clockFormat(timestamp)
    }

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

protocol BKLogSink: AnyObject {
    func logDidAppend()
}

// MARK: - 日志核心

public final class BKLog {

    public static let shared = BKLog()

    /// 内存里保留的条数，防止长时间跑占内存
    public let capacity = 3000

    weak var sink: BKLogSink?

    private let lock = NSLock()
    private var records: [BKLogEntry] = []
    private let fileURL: URL
    private let rotatedURL: URL
    private let maxFileSize: UInt64 = 4 * 1024 * 1024

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("bk.log")
        rotatedURL = base.appendingPathComponent("bk.old.log")
    }

    // MARK: 写入

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

        let captured = entry
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.writeToDisk(captured) }
        DispatchQueue.main.async { [weak self] in self?.sink?.logDidAppend() }
    }

    public func v(_ m: String, file: String = #file, line: Int = #line, function: String = #function) { log(m, level: .verbose, file: file, line: line, function: function) }
    public func d(_ m: String, file: String = #file, line: Int = #line, function: String = #function) { log(m, level: .debug, file: file, line: line, function: function) }
    public func i(_ m: String, file: String = #file, line: Int = #line, function: String = #function) { log(m, level: .info, file: file, line: line, function: function) }
    public func w(_ m: String, file: String = #file, line: Int = #line, function: String = #function) { log(m, level: .warn, file: file, line: line, function: function) }
    public func e(_ m: String, file: String = #file, line: Int = #line, function: String = #function) { log(m, level: .error, file: file, line: line, function: function) }

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

    // MARK: 读取

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

    public var logFileURL: URL { fileURL }

    public var logFileSizeText: String {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    // MARK: 落盘

    private var didHint = false

    private func writeToDisk(_ entry: BKLogEntry) {
        let text = entry.formatted + "\n"
        guard let data = text.data(using: .utf8) else { return }
        let fm = FileManager.default

        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
        if size > maxFileSize {
            try? fm.removeItem(at: rotatedURL)
            try? fm.moveItem(at: fileURL, to: rotatedURL)
        }

        if !fm.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
        } else if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }

        if !didHint {
            didHint = true
            i("日志文件：\(fileURL.path)")
        }
    }
}

// MARK: - 系统探针

enum BKProbe {

    /// 当前 App 实际占用的物理内存（MB），不是系统总量
    static func memoryUsedMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }

    static func freeDiskText() -> String {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let free = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? -1
        return free < 0 ? "未知" : ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
    }

    static func cachesSizeText() -> String {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ByteCountFormatter.string(fromByteCount: Int64(folderSize(at: url)), countStyle: .file)
    }

    static func appSupportSizeText() -> String {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ByteCountFormatter.string(fromByteCount: Int64(folderSize(at: url)), countStyle: .file)
    }

    static func folderSize(at url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
            total += size
        }
        return total
    }

    static let deviceName: String = {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let id = mirror.children.compactMap { $0.value as? Int8 }.filter { $0 != 0 }.map { String(UnicodeScalar(UInt8($0))) }.joined()
        return id.isEmpty ? UIDevice.current.model : id
    }()

    static var batteryText: String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = Int(abs(UIDevice.current.batteryLevel) * 100)
        switch UIDevice.current.batteryState {
        case .charging:  return "\(level)% · 充电中"
        case .full:      return "\(level)% · 已充满"
        case .unplugged: return "\(level)%"
        default:         return "未知"
        }
    }
}

// MARK: - 入口

public enum BKDebug {

    private static let enabledKey = "bk_debug_enabled"
    private static var versionTaps = 0
    private static var lastTapDate = Date()

    /// 调试面板总开关。Release 包也能开——Ad Hoc 分发本来就没有 DEBUG 宏
    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) == nil ? true : UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 是否响应摇一摇。默认关闭——走路时容易误触
    public static var shakeEnabled = false

    /// 版本号连点几次唤出
    public static var requiredTaps = 7

    public static func handleShake() {
        guard isEnabled, shakeEnabled else { return }
        present()
    }

    public static func tapVersionTag(_ from: UIViewController? = nil) {
        guard isEnabled else { return }
        let now = Date()
        if now.timeIntervalSince(lastTapDate) > 2 { versionTaps = 0 }
        lastTapDate = now
        versionTaps += 1
        if versionTaps >= requiredTaps {
            versionTaps = 0
            present(from: from)
        }
    }

    public static func present(from source: UIViewController? = nil) {
        guard isEnabled else { return }
        DispatchQueue.main.async {
            let vc = source ?? Self.topViewController()
            guard let vc = vc, !(vc is BKDebugPanelViewController) else { return }
            let nav = UINavigationController(rootViewController: BKDebugPanelViewController())
            nav.modalPresentationStyle = .fullScreen
            vc.present(nav, animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

// MARK: - 面板

public final class BKDebugPanelViewController: UIViewController, BKLogSink {

    private static let cellID = "BKLogCell"

    private let searchBar = UISearchBar()
    private let levelControl = UISegmentedControl(items: ["全部", "D", "I", "W", "E"])
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let followSwitch = UISwitch()
    private let statusLabel = UILabel()

    private var entries: [BKLogEntry] = []
    private var follow = true
    private var timer: Timer?

    private var minLevel: BKLogLevel {
        switch levelControl.selectedSegmentIndex {
        case 1: return .debug
        case 2: return .info
        case 3: return .warn
        case 4: return .error
        default: return .verbose
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "调试面板"
        view.backgroundColor = UIColor(hex: 0x1C1C1E)
        BKLog.shared.sink = self

        setupNavigation()
        setupFilterBar()
        setupTable()
        setupToolbar()
        reload()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let mb = BKProbe.memoryUsedMB()
            self.statusLabel.text = String(format: "内存 %.0f MB · 日志 %@", mb, BKLog.shared.logFileSizeText)
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            BKLog.shared.sink = nil
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: 界面

    private func setupNavigation() {
        navigationController?.navigationBar.barTintColor = UIColor(hex: 0x2C2C2E)
        navigationController?.navigationBar.tintColor = UIColor(hex: 0xF09A28)
        navigationController?.navigationBar.titleTextAttributes = [.foregroundColor: UIColor(hex: 0xF5F5F5)]

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "信息", style: .plain, target: self, action: #selector(showInfo))
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .stop, target: self, action: #selector(closePanel))
    }

    private func setupFilterBar() {
        let bar = UIView()
        bar.backgroundColor = UIColor(hex: 0x2C2C2E)
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        levelControl.selectedSegmentIndex = 0
        levelControl.selectedSegmentTintColor = UIColor(hex: 0xF09A28)
        levelControl.setTitleTextAttributes([.foregroundColor: UIColor(hex: 0xF5F5F5)], for: .normal)
        levelControl.addTarget(self, action: #selector(reload), for: .valueChanged)
        levelControl.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(levelControl)

        searchBar.searchBarStyle = .minimal
        searchBar.placeholder = "搜索消息 / 文件 / 函数"
        searchBar.delegate = self
        searchBar.searchTextField.textColor = UIColor(hex: 0xF5F5F5)
        searchBar.searchTextField.backgroundColor = UIColor(hex: 0x3A3A3C)
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(searchBar)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 96),
            levelControl.topAnchor.constraint(equalTo: bar.topAnchor, constant: 10),
            levelControl.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            levelControl.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            searchBar.topAnchor.constraint(equalTo: levelControl.bottomAnchor, constant: 8),
            searchBar.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 6),
            searchBar.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -6)
        ])
    }

    private func setupTable() {
        tableView.backgroundColor = UIColor(hex: 0x1C1C1E)
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 96),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -52)
        ])
    }

    private func setupToolbar() {
        let toolbar = UIView()
        toolbar.backgroundColor = UIColor(hex: 0x2C2C2E)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)

        statusLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = UIColor(hex: 0x8E8E93)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(statusLabel)

        followSwitch.isOn = true
        followSwitch.onTintColor = UIColor(hex: 0xF09A28)
        followSwitch.addTarget(self, action: #selector(toggleFollow), for: .valueChanged)
        followSwitch.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(followSwitch)

        let followLabel = UILabel()
        followLabel.text = "跟随"
        followLabel.font = UIFont.systemFont(ofSize: 11)
        followLabel.textColor = UIColor(hex: 0x8E8E93)
        followLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(followLabel)

        let clear = makeButton("清空", action: #selector(clearLog))
        let share = makeButton("导出", action: #selector(shareLog))
        let copy = makeButton("复制", action: #selector(copyLog))

        let stack = UIStackView(arrangedSubviews: [copy, share, clear, followLabel, followSwitch])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            toolbar.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor, constant: 52),
            statusLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: followSwitch.centerYAnchor),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor)
        ])
    }

    private func makeButton(_ title: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        b.tintColor = UIColor(hex: 0xF09A28)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    // MARK: 数据

    @objc private func reload() {
        entries = BKLog.shared.snapshot(minLevel: minLevel, keyword: searchBar.text ?? "")
        tableView.reloadData()
        if follow && !entries.isEmpty {
            tableView.scrollToRow(at: IndexPath(row: entries.count - 1, section: 0), at: .bottom, animated: false)
        }
    }

    func logDidAppend() { reload() }

    @objc private func toggleFollow() { follow = followSwitch.isOn }

    @objc private func clearLog() { BKLog.shared.clear() }

    @objc private func closePanel() { dismiss(animated: true) }

    @objc private func copyLog() {
        let text = entries.map { $0.formatted }.joined(separator: "\n")
        UIPasteboard.general.string = text.isEmpty ? BKLog.shared.snapshot().map { $0.formatted }.joined(separator: "\n") : text
        hint("日志已复制到剪贴板")
    }

    @objc private func shareLog() {
        let url = BKLog.shared.logFileURL
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(vc, animated: true)
    }

    @objc private func showInfo() {
        navigationController?.pushViewController(BKDeviceInfoViewController(), animated: true)
    }

    private func hint(_ text: String) {
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { alert.dismiss(animated: true) }
    }
}

extension BKDebugPanelViewController: UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        let entry = entries[indexPath.row]

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: entry.shortTime + " ",
                                       attributes: [.foregroundColor: UIColor(hex: 0x8E8E93),
                                                    .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]))
        text.append(NSAttributedString(string: entry.level.tag + " ",
                                       attributes: [.foregroundColor: entry.level.color,
                                                    .font: UIFont.systemFont(ofSize: 11, weight: .bold)]))
        text.append(NSAttributedString(string: entry.message + "\n",
                                       attributes: [.foregroundColor: UIColor(hex: 0xF5F5F5),
                                                    .font: UIFont.systemFont(ofSize: 12)]))
        text.append(NSAttributedString(string: "\(entry.file):\(entry.line) · \(entry.function)",
                                       attributes: [.foregroundColor: UIColor(hex: 0x6B6B66),
                                                    .font: UIFont.systemFont(ofSize: 10)]))

        cell.textLabel?.attributedText = text
        cell.textLabel?.numberOfLines = 0
        cell.backgroundColor = indexPath.row % 2 == 0 ? UIColor(hex: 0x1C1C1E) : UIColor(hex: 0x212123)
        cell.selectionStyle = .none
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let entry = entries[indexPath.row]
        let alert = UIAlertController(title: entry.level.tag, message: entry.formatted, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "复制", style: .default) { _ in UIPasteboard.general.string = entry.formatted })
        alert.addAction(UIAlertAction(title: "关闭", style: .cancel))
        present(alert, animated: true)
    }

    public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { reload() }
    public func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
}

// MARK: - 设备信息页

final class BKDeviceInfoViewController: UITableViewController {

    private var rows: [(String, String)] = []
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设备信息"
        view.backgroundColor = UIColor(hex: 0x1C1C1E)
        tableView.backgroundColor = UIColor(hex: 0x1C1C1E)
        tableView.separatorColor = UIColor(hex: 0x3A3A3C)
        tableView.tableFooterView = UIView()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "info")
        refresh()

        // 内存和电量是跳动的，每秒刷一次才有参考价值
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let info = Bundle.main.infoDictionary ?? [:]
        rows = [
            ("设备型号", BKProbe.deviceName),
            ("系统版本", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"),
            ("App 版本", "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"),
            ("Bundle ID", Bundle.main.bundleIdentifier ?? "—"),
            ("已用内存", String(format: "%.1f MB", BKProbe.memoryUsedMB())),
            ("可用磁盘", BKProbe.freeDiskText()),
            ("App 缓存", BKProbe.cachesSizeText()),
            ("App 数据", BKProbe.appSupportSizeText()),
            ("电量", BKProbe.batteryText),
            ("日志大小", BKLog.shared.logFileSizeText),
            ("调试开关", BKDebug.isEnabled ? "开" : "关"),
            ("摇一摇", BKDebug.shakeEnabled ? "开" : "关（默认）")
        ]
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "info", for: indexPath)
        let row = rows[indexPath.row]
        var config = UIListContentConfiguration.valueCell()
        config.text = row.0
        config.secondaryText = row.1
        config.textProperties.color = UIColor(hex: 0xF5F5F5)
        config.secondaryTextProperties.color = UIColor(hex: 0x8E8E93)
        config.textProperties.font = UIFont.systemFont(ofSize: 14)
        config.secondaryTextProperties.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        cell.contentConfiguration = config
        cell.backgroundColor = UIColor(hex: 0x1C1C1E)
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.row == 6 else { return }
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let size = BKProbe.folderSize(at: url)
        let alert = UIAlertController(title: "清缓存", message: "缓存目录 \(BKProbe.cachesSizeText())，确认清空？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { _ in
            FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.forEach { obj in
                if let file = obj as? URL { try? FileManager.default.removeItem(at: file) }
            }
            BKLog.shared.i("手动清空缓存，释放 \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
            self.refresh()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - 颜色工具
//
// UIColor(hex:) 已迁到 Core/BKTheme.swift —— 同模块只能定义一次。
// 这里保留一小段派生用法给面板专用。

extension UIColor {
    /// 按一定比例把当前色压向背景色，用于表格的斑马纹
    func bkDimmed(_ ratio: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * (1 - ratio), green: g * (1 - ratio), blue: b * (1 - ratio), alpha: a)
    }
}
