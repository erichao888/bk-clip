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
//  点开/导入草稿直接 push，改动落 v2 草稿文件。bridgeToV1 仅剩网格「直接导出」用
//  （confirmDirectExport，属 2C 导出管线），其余入口不再走桥接。
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
        fab.backgroundColor = BKTheme.Color.gold
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

    // MARK: - 打开草稿（Batch 1 桥接到 v1 编辑页）

    private func open(draft: BKDraft) {
        guard let assetId = draft.coverAssetId() else { return }
        guard let idx = draft.track.blocks.firstIndex(where: { $0.assetLocalID == assetId }) else { return }

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = BKTheme.Color.gold
        spinner.center = view.center
        spinner.startAnimating()
        view.addSubview(spinner)

        BKVideoLibrary.loadAVAsset(localID: assetId) { [weak self] asset in
            guard let self = self else { return }
            spinner.stopAnimating()
            spinner.removeFromSuperview()
            guard let asset = asset else {
                self.showAlert(title: "素材找不到了",
                               message: "这条草稿对应的原视频可能已经从相册里删除了。")
                BKLog.shared.e("打开草稿失败：AVAsset 取不到 \(assetId)")
                return
            }
            let probe = BKAssetProbe.probe(asset)
            BKLog.shared.i(probe.logLine)
            BKDraftStore.shared.markDraftOpened(draft.id)
            // 波剪子页已迁 v2：直接喂 v2 草稿 + 块下标
            let editor = BKEditorViewController(draft: draft, blockIndex: idx,
                                                asset: asset, probeInfo: probe)
            self.navigationController?.pushViewController(editor, animated: true)
        }
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

        guard let first = ids.first else { return }
        BKVideoLibrary.loadAVAsset(localID: first) { [weak self] asset in
            guard let self = self else { return }
            guard let asset = asset else {
                self.showAlert(title: "读取失败", message: "拿不到这个视频的数据，可能还在 iCloud 上。")
                return
            }
            let probe = BKAssetProbe.probe(asset)
            BKLog.shared.i(probe.logLine)
            if !probe.hasAudio {
                self.showAlert(title: "这条视频没有声音",
                               message: "去气口靠音轨判断呼吸停顿，无声视频没法自动找气口。")
                return
            }
            let idx = draft.track.blocks.firstIndex(where: { $0.assetLocalID == first }) ?? 0
            // 波剪子页已迁 v2：直接喂 v2 草稿 + 块下标
            let editor = BKEditorViewController(draft: draft, blockIndex: idx,
                                                asset: asset, probeInfo: probe)
            self.navigationController?.pushViewController(editor, animated: true)
        }
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
        // ★ TEMP 桥接：直接导出走 v1 批量导出逻辑（它也吃 BKDraftBatch）
        let batch = bridgeToV1(draft)
        let edited = batch.editedItems
        guard !edited.isEmpty else {
            showAlert(title: "这批还没有刀口", message: "先点进去切几刀再导出。")
            return
        }
        let alert = UIAlertController(
            title: "导出这一批？",
            message: "\(edited.count) 条动过刀的素材会逐个导出，全部存入相册（默认同源规格）。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "导出", style: .default) { [weak self] _ in
            self?.runBatchExport(batch: batch, spec: BKConfig.ExportSpec())
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - 批量导出（起始页「直接导出」用，v1 逻辑复用）

extension BKRootViewController {

    private func runBatchExport(batch: BKDraftBatch, spec: BKConfig.ExportSpec) {
        let edited = batch.editedItems
        guard !edited.isEmpty else { return }
        var working = batch

        let hud = UIAlertController(title: "正在导出", message: "准备中…", preferredStyle: .alert)
        present(hud, animated: true)

        var ok = 0
        var failed: [String] = []
        var updated: [BKProject] = []

        func step(_ i: Int) {
            if i >= edited.count {
                for u in updated {
                    if let k = working.items.firstIndex(where: { $0.assetLocalID == u.assetLocalID }) {
                        working.items[k] = u
                    }
                }
                working.lastEditedAt = Date()
                BKDraftStore.shared.scheduleSave(working)
                BKDraftStore.shared.flushIfNeeded()

                hud.dismiss(animated: true) { [weak self] in
                    if failed.isEmpty {
                        self?.showAlert(title: "导出完成", message: "\(ok) 条已存入相册。")
                    } else {
                        self?.showAlert(title: "\(ok) 条成功，\(failed.count) 条失败",
                                        message: "失败的：\n" + failed.joined(separator: "\n"))
                    }
                    self?.reload()
                }
                return
            }

            let item = edited[i]
            hud.message = "正在导出 \(i + 1)/\(edited.count)\n\(item.assetName)"
            guard let idx = working.items.firstIndex(where: { $0.assetLocalID == item.assetLocalID }) else {
                step(i + 1)
                return
            }

            BKVideoLibrary.loadAVAsset(localID: item.assetLocalID) { asset in
                guard let asset = asset else {
                    failed.append(item.assetName)
                    step(i + 1)
                    return
                }
                BKExporter.export(project: working.items[idx], asset: asset, spec: spec,
                                  progress: { _, _, _ in },
                                  completion: { result in
                    switch result {
                    case .failure(let err):
                        BKLog.shared.e("批量导出失败 \(item.assetName)：\(err.localizedDescription)")
                        failed.append(item.assetName)
                        step(i + 1)
                    case .success(let url):
                        let name = working.items[idx].nextExportFileName
                        BKRootViewController.saveToPhotos(url: url, fileName: name) { success in
                            if success {
                                ok += 1
                                var u = working.items[idx]
                                let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
                                let rec = BKExportRecord(id: UUID(), date: Date(),
                                                         fileSize: (attr?[.size] as? Int64) ?? 0,
                                                         duration: u.outputDuration,
                                                         fileName: name,
                                                         elapsedSec: 0)
                                u.exportHistory.append(rec)
                                updated.append(u)
                            } else {
                                failed.append(item.assetName)
                            }
                            step(i + 1)
                        }
                    }
                })
            }
        }
        step(0)
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

// MARK: - v2 → v1 桥接（TEMP，Batch 2 删除）
//
// 编辑页（BKEditorViewController）还没迁 v2，依旧吃 v1 BKDraftBatch / BKProject。
// 这里把 v2 的 BKTrackModel（blocks: [BKClipBlock]）转成 v1 批，喂给编辑页。
// ⚠️ 编辑页的改动会落在 v1 草稿文件（Drafts/），v2 草稿文件（Drafts/v2/）保持创建时状态。
//   这是 Batch 1「外层三页先 v2、编辑器走桥接」的已知临时状态，Batch 2 统一后消除。

private func bridgeBlockToV1(_ b: BKClipBlock) -> BKProject {
    let dur = b.srcDuration
    // 未波剪：整段保留（单段 keptRanges）→ v1 第一阶段（空 keptRanges），
    // 编辑页打开会跑自动检测，符合 v1 习惯
    let isUncut = b.keptRanges.count == 1
        && abs(b.keptRanges[0].start) < 1e-6
        && abs(b.keptRanges[0].end - dur) < 1e-6
    let mid = (BKConfig.Detect.clampLow + BKConfig.Detect.clampHigh) / 2
    let now = Date()
    var proj = BKProject(id: b.id,
                         assetLocalID: b.assetLocalID,
                         assetName: BKVideoLibrary.assetName(localID: b.assetLocalID),
                         duration: dur,
                         displayWidth: 0,
                         displayHeight: 0,
                         sourceRotationDegrees: 0,
                         thresholdDb: mid,
                         autoThresholdDb: nil,
                         sourceApplicable: true,
                         marks: [BKMark(start: 0, end: dur, kind: .keep)],
                         splits: [],
                         playheadTime: 0,
                         createdAt: now,
                         updatedAt: now,
                         exportHistory: [])
    // 波剪过的块 → 直接给 v1 第二阶段（绿区），编辑页能接着调长短
    if !isUncut {
        proj.keptRanges = b.keptRanges.map { Segment(start: $0.start, end: $0.end) }
    }
    return proj
}

func bridgeToV1(_ draft: BKDraft) -> BKDraftBatch {
    BKDraftBatch(id: draft.id,
                 title: draft.title,
                 items: draft.track.blocks.map(bridgeBlockToV1),
                 lastAssetId: draft.coverAssetId(),
                 createdAt: draft.createdAt,
                 lastEditedAt: draft.lastEditedAt,
                 everEdited: draft.everEdited,
                 deletedAt: draft.deletedAt)
}
