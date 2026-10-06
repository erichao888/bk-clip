//
//  BKTrashViewController.swift
//  bk剪辑 — 最近删除（回收站）
//
//  【为什么必须有这一层】定稿 3.2：
//  **删掉的是刀口数据，删了等于白切** —— 一条片子上十几刀，一删全没了，
//  而「删草稿」这个动作在手指上跟「删照片」一样轻。没有退路一定会出事。
//
//  【v2.0：回收站必须跟着草稿一起迁 v2】
//  起始页（BKRootViewController）已经全面走 v2 的 BKDraft，删除动作走
//  BKDraftStore.moveDraftToTrash，文件落在 Drafts/v2/。
//  ⚠️ 如果这里还读 v1 的 trashedBatches（Drafts/），**v2 草稿删完就再也找不回来**
//  —— 两个目录物理隔离，回收站里根本不显示它，单条删除就变成了不可逆操作。
//  迁完的闭环：起始页删 → v2 回收站可见 → 恢复回起始页。
//  旧 v1 草稿按皓哥定的「不迁移、全新起步」处理，本页不再显示。
//
//  【两个确认层级要分清】
//  · 单条删 → 只提示「已移到最近删除」，**不弹确认框**（可撤销感，别烦人）
//  · 清空回收站 → 才弹**真正的二次确认**（这一步是不可逆的）
//
//  【恢复时要检查原片还在不在】
//  用户可能删了草稿之后又把相册里的原片删了。那种情况下草稿能恢复，
//  但点进去会打不开 —— 所以恢复完如实告诉他哪几条的原片找不到了，别让他自己撞。
//
//  【30 天自动清空】
//  跟相册一个套路，不无限堆着。过期判定在 BKDraftStore 每次读列表时顺手做，
//  这里只负责把「还剩几天」显示出来。
//

import UIKit

final class BKTrashViewController: UIViewController {

    private let table = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private var drafts: [BKDraft] = []

    /// 从这个页面恢复了草稿，回起始页要刷新网格
    var onChanged: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "最近删除"
        view.backgroundColor = BKTheme.Color.page
        setupUI()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 「恢复」按钮在底部工具栏上，不显式打开就永远看不到它
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    private func setupUI() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "清空", style: .plain, target: self, action: #selector(clearAllTapped))
        navigationItem.rightBarButtonItem?.tintColor = BKTheme.Color.danger

        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.separatorColor = BKTheme.Color.line
        table.rowHeight = 56
        table.allowsMultipleSelectionDuringEditing = true
        // 必须用 .subtitle 样式的子类：register(UITableViewCell.self) 拿到的是
        // .default 样式，detailTextLabel 是 nil，副标题会静默消失（不是报错，是不显示）
        table.register(BKSubtitleCell.self, forCellReuseIdentifier: "cell")
        view.addSubview(table)

        emptyLabel.text = "最近删除是空的"
        emptyLabel.font = BKTheme.Font.body
        emptyLabel.textColor = BKTheme.Color.text3
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

        let restoreItem = UIBarButtonItem(title: "恢复", style: .plain,
                                          target: self, action: #selector(restoreTapped))
        restoreItem.tintColor = BKTheme.Color.accent
        toolbarItems = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            restoreItem
        ]

        for v in [table, emptyLabel] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func reload() {
        drafts = BKDraftStore.shared.trashedDrafts
        emptyLabel.isHidden = !drafts.isEmpty
        table.isHidden = drafts.isEmpty
        table.reloadData()
        navigationItem.rightBarButtonItem?.isEnabled = !drafts.isEmpty
    }

    // MARK: - 操作

    @objc private func restoreTapped() {
        guard let rows = table.indexPathsForSelectedRows, !rows.isEmpty else {
            showNotice(title: "还没选", message: "先点几条要恢复的草稿，再按恢复。")
            return
        }
        var missing: [String] = []
        for ip in rows where ip.row < drafts.count {
            let r = BKDraftStore.shared.restoreDraft(drafts[ip.row])
            missing.append(contentsOf: r.missing)
        }
        reload()
        onChanged?()
        if missing.isEmpty {
            showNotice(title: "已恢复", message: "\(rows.count) 个草稿已放回起始页。")
        } else {
            showNotice(title: "已恢复，但有原片找不到了",
                       message: "\(rows.count) 个草稿已放回起始页，但其中 \(missing.count) 条素材的原视频已被删除：\n"
                        + missing.prefix(5).joined(separator: "\n"))
        }
    }

    @objc private func clearAllTapped() {
        // 唯一弹真确认框的地方 —— 这一步不可逆
        let alert = UIAlertController(
            title: "清空最近删除？",
            message: "\(drafts.count) 个草稿会被**永久删除**，刀口数据一起消失，无法恢复。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "永久删除", style: .destructive) { [weak self] _ in
            BKDraftStore.shared.emptyTrashV2()
            self?.reload()
            self?.onChanged?()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showNotice(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        present(alert, animated: true)
    }
}

/// 带副标题的 cell。系统默认的 register(UITableViewCell.self) 是 .default 样式，没有副标题
private final class BKSubtitleCell: UITableViewCell {
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }
}

// MARK: - 数据源

extension BKTrashViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        drafts.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let d = drafts[indexPath.row]
        // 模型不碰 Photos，素材名由这里用 BKVideoLibrary 取后再交给 displayTitle
        let firstName = (d.track.blocks.first).map { BKVideoLibrary.assetName(localID: $0.assetLocalID) } ?? ""
        let left = d.trashDaysLeft
        cell.backgroundColor = .clear
        cell.textLabel?.text = d.displayTitle(firstName: firstName)
        cell.textLabel?.textColor = BKTheme.Color.text
        var sub = "\(d.blockCount) 条 · \(d.totalCuts) 刀"
        sub += left > 0 ? " · 剩 \(left) 天自动清空" : " · 即将自动清空"
        cell.detailTextLabel?.text = sub
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // 非编辑态点一下也进多选，省得还要先找「选择」按钮
        if !tableView.isEditing { tableView.setEditing(true, animated: true) }
    }
}
