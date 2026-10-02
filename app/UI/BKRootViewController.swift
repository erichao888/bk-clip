//
//  BKRootViewController.swift
//  bk剪辑 — 起始页（草稿网格）
//
//  【这个页面是为「回马枪」服务的】
//  皓哥的原话：导出到剪映之后发现有问题，要回到 bk剪辑，点历史里那条，
//  改那一处红区，重新导出。所以它不是「入口页」，是**最近编辑过的 10 批的快捷回马枪**。
//
//  【一格 = 一次导入的一整批】
//  导入 5 条 → 起始页多 1 格 → 点进去 5 条都还在，各自的刀口、指针位置、阈值都在。
//  皓哥 2026-10-02 口述定稿，听完我的复述他说「就是这样」。
//  数据模型是两层的（BKDraftBatch → BKProject[]），别按「一视频一格」存。
//
//  【不做底部 tab】
//  单功能工具，两个入口（导入 ⊕ / 回收站）一个在右下角、一个在导航栏，够用了。
//
//  【起始页不显示「一刀没切」的草稿】
//  整批从头到尾没动过刀 → 退出编辑页时直接丢掉，不进网格（定稿 3.1）。
//  判据是 `everEdited`（**曾经**动过刀），只置不清。
//

import UIKit
import Photos
import PhotosUI
import AVFoundation

final class BKRootViewController: UIViewController {

    // MARK: - 数据

    private var batches: [BKDraftBatch] = []
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
        // 调试入口藏在版本号后面，连点 7 次。
        // 不放显眼位置是因为现实使用里误触的概率比想 debug 的概率高得多
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
        batches = BKDraftStore.shared.allBatches
        title = "草稿 (\(batches.count))"
        emptyLabel.isHidden = !batches.isEmpty
        grid.isHidden = batches.isEmpty
        grid.reloadData()
        navigationItem.rightBarButtonItem?.isEnabled = !batches.isEmpty
        versionLabel.text = "v\(BKConfig.appVersion) · 已导出 \(BKDraftStore.shared.totalExportCount) 条"
    }

    // MARK: - 打开草稿

    private func open(batch: BKDraftBatch) {
        guard let assetId = batch.coverAssetId() else { return }
        guard let idx = batch.items.firstIndex(where: { $0.assetLocalID == assetId }) else { return }

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
            BKDraftStore.shared.markOpened(batch.id)
            let editor = BKEditorViewController(batch: batch, index: idx,
                                                asset: asset, probeInfo: probe)
            self.navigationController?.pushViewController(editor, animated: true)
        }
    }

    // MARK: - 导入

    @objc private func importTapped() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            presentPicker()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        self?.presentPicker()
                    } else {
                        self?.showPermissionDenied()
                    }
                }
            }
        default:
            showPermissionDenied()
        }
    }

    private func presentPicker() {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos          // 系统层过滤，拿到的结果一定是视频
        config.selectionLimit = 0        // 0 = 不限数量，一次选一批
        config.preferredAssetRepresentationMode = .automatic

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    /// 一次导入 = 建一个批。批里每条先把时长和名字记下来，
    /// 显示尺寸要等编辑页探过素材才知道，先留 0
    private func makeBatch(ids: [String]) -> BKDraftBatch {
        let mid = (BKConfig.Detect.clampLow + BKConfig.Detect.clampHigh) / 2
        let now = Date()
        let items = ids.map { id -> BKProject in
            let dur = BKVideoLibrary.duration(localID: id)
            return BKProject(id: UUID(),
                             assetLocalID: id,
                             assetName: BKVideoLibrary.assetName(localID: id),
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
        }
        var batch = BKDraftBatch(id: UUID(), title: "", items: items, lastAssetId: ids.first,
                                 createdAt: now, lastEditedAt: now, everEdited: false, deletedAt: nil)
        batch.title = batch.displayTitle
        return batch
    }

    private func handleImported(ids: [String]) {
        guard !ids.isEmpty else { return }
        let batch = makeBatch(ids: ids)
        BKDraftStore.shared.scheduleSave(batch)
        BKDraftStore.shared.markOpened(batch.id)
        BKLog.shared.i("新建草稿批 \(batch.id.uuidString.prefix(8)) · \(ids.count) 条")

        // 载入第一条直接进编辑页
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
            let editor = BKEditorViewController(batch: batch, index: 0,
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
        for i in 0 ..< batches.count {
            grid.selectItem(at: IndexPath(item: i, section: 0), animated: false, scrollPosition: [])
        }
    }

    /// 批量删。删掉的是刀口数据，所以只提示「已移到最近删除」——
    /// **不弹确认框**，给用户「还能捞回来」的感觉（定稿 3.2）
    @objc private func deleteSelectedTapped() {
        let rows = selectedRows
        guard !rows.isEmpty else {
            showAlert(title: "还没选", message: "先点几格，再按删除。")
            return
        }
        for ip in rows where ip.item < batches.count {
            BKDraftStore.shared.moveToTrash(batches[ip.item])
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
        // Ad Hoc 是 Release 包，#if DEBUG 不生效，面板开关走运行时判断
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
        batches.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: BKDraftCell.reuseId, for: indexPath) as? BKDraftCell else {
            return UICollectionViewCell()
        }
        let b = batches[indexPath.item]
        let coverId = b.coverAssetId()
        let img = coverId.flatMap { BKCovers.load(batchId: b.id, assetId: $0) }
        cell.configure(title: b.displayTitle, cuts: b.totalCuts, coverImage: img, picking: picking)
        cell.onMenu = { [weak self] in self?.showDraftMenu(for: b) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if picking { return }                 // 多选态下交给底部操作条
        guard indexPath.item < batches.count else { return }
        open(batch: batches[indexPath.item])
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
    private func showDraftMenu(for batch: BKDraftBatch) {
        let sheet = UIAlertController(title: batch.displayTitle, message: nil, preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: "重命名", style: .default) { [weak self] _ in
            self?.promptRename(batch)
        })
        sheet.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            BKDraftStore.shared.moveToTrash(batch)
            self?.reload()
            self?.showAlert(title: "已移到最近删除",
                            message: "30 天内可以在左上角回收站里恢复。")
        })
        sheet.addAction(UIAlertAction(title: "直接导出", style: .default) { [weak self] _ in
            self?.confirmDirectExport(batch)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        // iPad 上 actionSheet 必须给锚点，否则直接崩。本 App 只锁竖屏，但这条留着更保险
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX,
                                                                 y: view.bounds.midY, width: 0, height: 0)
        present(sheet, animated: true)
    }

    private func promptRename(_ batch: BKDraftBatch) {
        let alert = UIAlertController(title: "重命名", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text = batch.displayTitle
            tf.placeholder = "给这一批起个名字"
        }
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
            var b = batch
            b.title = alert.textFields?.first?.text ?? ""
            BKDraftStore.shared.scheduleSave(b)
            BKDraftStore.shared.flushIfNeeded()
            self?.reload()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func confirmDirectExport(_ batch: BKDraftBatch) {
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

// MARK: - 批量导出（起始页「直接导出」用）

extension BKRootViewController {

    /// 逐条排队导出。单条失败记下来继续跑，最后统一报一句，不中途弹窗打断整批（定稿 4.8）
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
                // 把导出记录写回草稿 —— 文件名后缀靠 exportCount 递增，不写回去下次重号
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

    /// 存相册。**必须用 PHAssetCreationRequest 指定 originalFilename** ——
    /// 老的 creationRequestForAssetFromVideo 存进去后，相册会自己起一个 IMG_xxxx 的名字，
    /// 皓哥要的 `BK_` 前缀就丢了：同一条片子改一版导一次，剪映里好几版分不清哪版是哪版
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

        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            work()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in DispatchQueue.main.async { work() } }
        default:
            completion(false)
        }
    }
}

// MARK: - 相册回调

extension BKRootViewController: PHPickerViewControllerDelegate {

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        // 拿 localIdentifier 而不是直接取数据：
        // 一是它稳定，下次启动还能凭它找回同一条素材；
        // 二是直接取 NSItemProvider 在大文件上会先把整个视频读进内存
        let ids = results.compactMap { $0.assetIdentifier }
        guard !ids.isEmpty else {
            BKLog.shared.d("相册选择已取消")
            return
        }
        BKLog.shared.i("本次导入 \(ids.count) 条素材")
        handleImported(ids: ids)
    }
}
