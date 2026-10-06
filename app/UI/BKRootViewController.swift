//
//  BKRootViewController.swift
//  bk剪辑 v2.0 — 起始页（草稿网格）
//
//  【v2.0 重写：用 BKTrackModel 全新写】
//  一个草稿 = 一条多片段主轨（BKTrackModel），不再有 v1 的「批 / 素材项」两层。
//  数据模型真源：docs/v2.0数据模型-多片段主轨与变速坐标.md。
//
//  【一格 = 一个草稿 = 一条主轨】
//  导入 N 条视频 → 起始页多 1 格 → 主轨上 N 个块，各自的波剪 / 指针 / 倍速都在。
//
//  【不做底部 tab】单功能工具，两个入口（导入 ⊕ / 回收站）一个在右下角、一个在导航栏。
//
//  【起始页不显示「一刀没切」的草稿】整批从头到尾没动过刀 → 退出编辑页时直接丢掉
//  （定稿 3.1）。判据是 everEdited（曾经动过刀），只置不清。
//
//  【Batch 2 已迁 v2】编辑页（BKEditorViewController）现直吃 v2 BKDraft + blockIndex，
//  点开/导入草稿直接 push，改动落 v2 草稿文件。导出也走 v2 主轨
//  （BKExporter.export(title:sources:)），bridgeToV1 已删。
//

import UIKit
import Photos
import AVFoundation

final class BKRootViewController: UIViewController {

    // MARK: - 数据

    private var drafts: [BKDraft] = []
    /// 多选态（批量删）
    private var picking = false

    // MARK: - 界面

    private let grid: UICollectionView
    private let emptyLabel = UILabel()
    private let fab = UIButton(type: .system)
    private let versionLabel = UILabel()

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 4, left: 16, bottom: 90, right: 16)
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("本 App 不走 storyboard") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BKTheme.Color.page
        title = "草稿"
        setupUI()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        reload()
    }

    // MARK: - 布局

    private func setupUI() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "trash"), style: .plain,
            target: self, action: #selector(trashTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "checkmark.circle"), style: .plain,
            target: self, action: #selector(pickTapped))

        grid.backgroundColor = .clear
        grid.dataSource = self
        grid.delegate = self
        grid.alwaysBounceVertical = true
        grid.register(BKDraftCell.self, forCellWithReuseIdentifier: BKDraftCell.reuseId)
        view.addSubview(grid)

        emptyLabel.text = "还没有草稿\n点右下角 ⊕ 导入视频"
        emptyLabel.font = BKTheme.Font.body
        emptyLabel.textColor = BKTheme.Color.text3
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        view.addSubview(emptyLabel)

        // 右下角金色悬浮 ⊕：导入新的一批
        fab.setImage(UIImage(systemName: "plus"), for: .normal)
        fab.tintColor = .white
        fab.backgroundColor = BKTheme.Color.accent
        fab.layer.cornerRadius = 28
        fab.layer.shadowColor = UIColor.black.cgColor
        fab.layer.shadowOpacity = 0.25
        fab.layer.shadowOffset = CGSize(width: 0, height: 3)
        fab.layer.shadowRadius = 6
        fab.addTarget(self, action: #selector(importTapped), for: .touchUpInside)
        view.addSubview(fab)

        versionLabel.font = BKTheme.Font.small
        versionLabel.textColor = BKTheme.Color.text3
        versionLabel.textAlignment = .center
        versionLabel.isUserInteractionEnabled = true
        // 调试入口藏在版本号后面，连点 7 次
        versionLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(versionTapped))
        )
        view.addSubview(versionLabel)

        for v in [grid, emptyLabel, fab, versionLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),

            fab.widthAnchor.constraint(equalToConstant: 56),
            fab.heightAnchor.constraint(equalToConstant: 56),
            fab.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            fab.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),

            versionLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -2),
            versionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 60),
            versionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -60),
            versionLabel.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    // MARK: - 刷新

    private func reload() {
        drafts = BKDraftStore.shared.allDrafts
        title = "草稿 (\(drafts.count))"
        emptyLabel.isHidden = !drafts.isEmpty
        grid.isHidden = drafts.isEmpty
        grid.reloadData()
        navigationItem.rightBarButtonItem?.isEnabled = !drafts.isEmpty
        versionLabel.text = "BK剪辑 专剪口播 v\(BKConfig.appVersion) · 已导出 \(BKDraftStore.shared.totalExportCount) 条"
    }

    // MARK: - 打开草稿

    /// 2B：点草稿进**主编辑页**，不再直接进波剪子页。
    /// 主编辑页管结构（这条片子由哪几块组成），点「波剪」键才进某一块内部剪气口。
    /// 这里不再预加载 AVAsset —— 主编辑页只在进波剪那一步才需要素材，
    /// 素材丢了的话在那一层提示，比在这儿拦住整条草稿更准（一条草稿可能有多条素材）
    private func open(draft: BKDraft) {
        guard !draft.track.blocks.isEmpty else { return }
        BKDraftStore.shared.markDraftOpened(draft.id)
        let editor = BKMainEditorViewController(draft: draft)
        navigationController?.pushViewController(editor, animated: true)
    }

    // MARK: - 导入

    @objc private func importTapped() {
        let status = Self.photoAuthStatus()
        switch status {
        case .authorized, .limited:
            presentPicker()
        case .notDetermined:
            Self.requestPhotoAccess { [weak self] granted in
                if granted { self?.presentPicker() } else { self?.showPermissionDenied() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self else { return }
                let now = Self.photoAuthStatus()
                let systemShowing = self.presentedViewController != nil
                if now == .notDetermined && !systemShowing {
                    self.showPermissionDenied()
                }
            }
        default:
            showPermissionDenied()
        }
    }

    // MARK: - 相册权限（iOS 16+ 用现代 API）

    private static func photoAuthStatus() -> PHAuthorizationStatus {
        if #available(iOS 16.0, *) {
            return PHPhotoLibrary.authorizationStatus(for: .readWrite)
        } else {
            return PHPhotoLibrary.authorizationStatus()
        }
    }

    private static func requestPhotoAccess(then: @escaping (Bool) -> Void) {
        let decide: (PHAuthorizationStatus) -> Void = { s in then(s == .authorized || s == .limited) }
        if #available(iOS 16.0, *) {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { st in
                DispatchQueue.main.async { decide(st) }
            }
        } else {
            PHPhotoLibrary.requestAuthorization { st in
                DispatchQueue.main.async { decide(st) }
            }
        }
    }

    private func presentPicker() {
        let picker = BKVideoPickerViewController()
        picker.onDone = { [weak self] ids in
            self?.dismiss(animated: true) { self?.handleImported(ids: ids) }
        }
        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    /// 一次导入 = 建一个 v2 草稿。每条视频是一个未波剪的块（整段保留），倍速 1
    private func makeDraft(ids: [String]) -> BKDraft {
        let now = Date()
        let blocks = ids.map { id -> BKClipBlock in
            let dur = BKVideoLibrary.duration(localID: id)
            return BKClipBlock.uncutted(assetLocalID: id, srcDuration: dur,
                                        assetName: BKVideoLibrary.assetName(localID: id))
        }
        return BKDraft(id: UUID(), title: "", blocks: blocks,
                       lastAssetId: ids.first, createdAt: now, lastEditedAt: now, everEdited: false)
    }

    private func handleImported(ids: [String]) {
        guard !ids.isEmpty else { return }
        let draft = makeDraft(ids: ids)
        BKDraftStore.shared.scheduleSaveV2(draft)
        BKDraftStore.shared.markDraftOpened(draft.id)
        BKLog.shared.i("新建 v2 草稿 \(draft.id.uuidString.prefix(8)) · \(ids.count) 条")

        // 2B：导入完先进主编辑页。原来这里会先 probe 一遍首条素材判「有没有声音」——
        // 那条告警挪到真正点「波剪」时再给（见 BKMainEditorViewController.openWaveCut），
        // 放进主编辑页没意义：主轨本身不需要音轨，无声素材照样能排版
        let editor = BKMainEditorViewController(draft: draft)
        navigationController?.pushViewController(editor, animated: true)
    }

    // MARK: - 批量多选

    @objc private func pickTapped() {
        picking.toggle()
        grid.allowsMultipleSelection = picking
        if !picking {
            for ip in selectedRows { grid.deselectItem(at: ip, animated: false) }
        }
        grid.reloadData()
        navigationController?.setToolbarHidden(!picking, animated: true)
        navigationItem.rightBarButtonItem?.image =
            UIImage(systemName: picking ? "xmark.circle" : "checkmark.circle")

        let del = UIBarButtonItem(title: "删除", style: .plain, target: self,
                                  action: #selector(deleteSelectedTapped))
        del.tintColor = BKTheme.Color.danger
        let all = UIBarButtonItem(title: "全选", style: .plain, target: self,
                                  action: #selector(selectAllTapped))
        all.tintColor = BKTheme.Color.text
        toolbarItems = [
            del,
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            all
        ]
    }

    private var selectedRows: [IndexPath] {
        grid.indexPathsForSelectedItems ?? []
    }

    @objc private func selectAllTapped() {
        for i in 0 ..< drafts.count {
            grid.selectItem(at: IndexPath(item: i, section: 0), animated: false, scrollPosition: [])
        }
    }

    /// 批量删。删掉的是刀口数据，只提示「已移到最近删除」——不弹确认框（定稿 3.2）
    @objc private func deleteSelectedTapped() {
        let rows = selectedRows
        guard !rows.isEmpty else {
            showAlert(title: "还没选", message: "先点几格，再按删除。")
            return
        }
        for ip in rows where ip.item < drafts.count {
            BKDraftStore.shared.moveDraftToTrash(drafts[ip.item])
        }
        pickTapped()          // 顺带退出多选态
        reload()
        showAlert(title: "已移到最近删除",
                  message: "\(rows.count) 批已移入回收站，30 天内可以在左上角回收站里恢复。")
    }

    @objc private func trashTapped() {
        let vc = BKTrashViewController()
        vc.onChanged = { [weak self] in self?.reload() }
        navigationController?.pushViewController(vc, animated: true)
    }

    @objc private func versionTapped() {
        BKDebug.tapVersionTag(self)
    }

    // MARK: - 提示

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        present(alert, animated: true)
    }

    private func showPermissionDenied() {
        let alert = UIAlertController(
            title: "需要相册权限",
            message: "去「设置 → bk剪辑 → 照片」里改成「所有照片」。\n选「限定的照片」也行，但要确定包含了你想剪的那段视频。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "去设置", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - 网格

extension BKRootViewController: UICollectionViewDataSource, UICollectionViewDelegate,
                                 UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        drafts.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: BKDraftCell.reuseId, for: indexPath) as? BKDraftCell else {
            return UICollectionViewCell()
        }
        let d = drafts[indexPath.item]
        let coverId = d.coverAssetId()
        let firstName = (d.track.blocks.first).map { BKVideoLibrary.assetName(localID: $0.assetLocalID) } ?? ""
        let img = coverId.flatMap { BKCovers.load(batchId: d.id, assetId: $0) }
        cell.configure(title: d.displayTitle(firstName: firstName),
                       cuts: d.totalCuts, count: d.blockCount, coverImage: img, picking: picking)
        cell.onMenu = { [weak self] in self?.showDraftMenu(for: d) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if picking { return }                 // 多选态下交给底部操作条
        guard indexPath.item < drafts.count else { return }
        open(draft: drafts[indexPath.item])
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        // 三列：左右各 16、列间距 8×2 → (屏宽 − 32 − 16) / 3
        let total = collectionView.bounds.width - 32 - 16
        let w = max(60, floor(total / 3))
        return CGSize(width: w, height: w * 1.32)
    }

    /// 「···」菜单三项：重命名 / 删除 / 直接导出（定稿 3.1）
    private func showDraftMenu(for draft: BKDraft) {
        let firstName = (draft.track.blocks.first).map { BKVideoLibrary.assetName(localID: $0.assetLocalID) } ?? ""
        let sheet = UIAlertController(title: draft.displayTitle(firstName: firstName), message: nil, preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: "重命名", style: .default) { [weak self] _ in
            self?.promptRename(draft)
        })
        sheet.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            BKDraftStore.shared.moveDraftToTrash(draft)
            self?.reload()
            self?.showAlert(title: "已移到最近删除",
                            message: "30 天内可以在左上角回收站里恢复。")
        })
        sheet.addAction(UIAlertAction(title: "直接导出", style: .default) { [weak self] _ in
            self?.confirmDirectExport(draft)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX,
                                                                 y: view.bounds.midY, width: 0, height: 0)
        present(sheet, animated: true)
    }

    private func promptRename(_ draft: BKDraft) {
        let firstName = (draft.track.blocks.first).map { BKVideoLibrary.assetName(localID: $0.assetLocalID) } ?? ""
        let alert = UIAlertController(title: "重命名", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text = draft.displayTitle(firstName: firstName)
            tf.placeholder = "给这一批起个名字"
        }
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
            var d = draft
            d.title = alert.textFields?.first?.text ?? ""
            BKDraftStore.shared.scheduleSaveV2(d)
            BKDraftStore.shared.flushV2IfNeeded()
            self?.reload()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func confirmDirectExport(_ draft: BKDraft) {
        guard !draft.track.blocks.isEmpty else {
            showAlert(title: "空草稿", message: "这条草稿没有内容可导出。")
            return
        }
        let msg = String(format: "整条主轨 %d 段 · 成品 %02d:%02d，按各块源规格存入相册。",
                         draft.track.blocks.count,
                         Int(draft.track.total) / 60, Int(draft.track.total) % 60)
        let alert = UIAlertController(
            title: "导出这条草稿？",
            message: msg,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "导出", style: .default) { [weak self] _ in
            self?.runDirectExport(draft: draft, spec: BKConfig.ExportSpec())
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - 直接导出（起始页网格菜单用）

extension BKRootViewController {

    /// v2：一条草稿 = 一个成品文件。逐块加载素材（顺序链）→ 一次导出 → 存相册。
    /// v1 的「批量多条各自导出」没了 —— 草稿就是片子，不存在一批多条的概念
    private func runDirectExport(draft: BKDraft, spec: BKConfig.ExportSpec) {
        let blocks = draft.track.blocks
        guard !blocks.isEmpty else { return }

        let title = draft.displayTitle(firstName: blocks.first?.assetName ?? "")
        let hud = UIAlertController(title: "正在导出", message: "准备中…", preferredStyle: .alert)
        present(hud, animated: true)

        var parts: [BKCompositionBuilder.Part] = []

        func load(_ i: Int) {
            if i >= blocks.count {
                BKExporter.export(title: title, sources: parts, spec: spec,
                                  progress: { _, _, frac in
                                      hud.message = String(format: "%d%%", Int(frac * 100))
                                  },
                                  completion: { [weak self] result in
                                      guard let self = self else { return }
                                      switch result {
                                      case .failure(let err):
                                          hud.dismiss(animated: true) {
                                              self.showAlert(title: "导出失败",
                                                             message: err.localizedDescription)
                                          }
                                      case .success(let url):
                                          BKRootViewController.saveToPhotos(url: url,
                                                                            fileName: url.lastPathComponent) { ok in
                                              hud.dismiss(animated: true) {
                                                  if ok {
                                                      self.showAlert(title: "导出完成",
                                                                     message: "已存入相册。")
                                                  } else {
                                                      self.showAlert(title: "导出成功",
                                                                     message: "但存相册失败，成品留在文件 App 的 Exports 目录里。")
                                                  }
                                              }
                                          }
                                      }
                                  })
                return
            }
            let b = blocks[i]
            hud.message = "读取素材 \(i + 1)/\(blocks.count)…"
            BKVideoLibrary.loadAVAsset(localID: b.assetLocalID) { [weak self] asset in
                guard let self = self else { return }
                guard let asset = asset else {
                    hud.dismiss(animated: true) {
                        self.showAlert(title: "导出中止",
                                       message: "「\(b.assetName)」读不到，可能已从相册删除。")
                    }
                    return
                }
                parts.append(BKCompositionBuilder.Part(
                    asset: asset,
                    name: b.assetName,
                    keeps: b.keptRanges.map { ($0.start, $0.end) },
                    speed: b.speed))
                load(i + 1)
            }
        }
        load(0)
    }

    /// 存相册。必须用 PHAssetCreationRequest 指定 originalFilename，保住 BK_ 前缀
    static func saveToPhotos(url: URL, fileName: String, completion: @escaping (Bool) -> Void) {
        func work() {
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                opts.originalFilename = fileName
                req.addResource(with: .video, fileURL: url, options: opts)
            }) { ok, err in
                DispatchQueue.main.async {
                    if ok {
                        BKLog.shared.i("成品已存相册 \(fileName)")
                    } else {
                        BKLog.shared.e("存相册失败：\(err?.localizedDescription ?? "未知原因")")
                    }
                    completion(ok)
                }
            }
        }

        switch Self.photoAuthStatus() {
        case .authorized, .limited:
            work()
        case .notDetermined:
            Self.requestPhotoAccess { granted in
                if granted { work() } else { completion(false) }
            }
        default:
            completion(false)
        }
    }
}

