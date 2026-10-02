//
//  BKRootViewController.swift
//  bk剪辑 — 起始页
//
//  第一版的职责只有一个：**把素材读进来，并把它的真实尺寸打进日志。**
//
//  为什么要单独强调这一点：这个 App 最大的坑是 iPhone 视频的方向标记
//  （详见 Core/BKAssetProbe.swift 的说明）。在真机第一跑就把
//  「原始尺寸 vs 显示尺寸 vs 旋转角度」三个数摆到屏幕上，
//  一眼就能确认那条方向铁律有没有生效，不用等到导出才发现片子躺了。
//

import UIKit
import Photos
import PhotosUI
import AVFoundation

final class BKRootViewController: UIViewController {

    // MARK: - 界面

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let pickButton = UIButton(type: .system)
    private let resumeButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let versionLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    /// 当前选中的素材。拿到之后暂时只做探测，第二批接波形提取
    private var currentAVAsset: AVAsset?
    private var currentLocalID: String?

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        refreshResumeVisibility()
        BKLog.shared.d("起始页已就绪")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 编辑页回来时把导航栏重新藏起来，保持起始页的沉浸样式
        navigationController?.setNavigationBarHidden(true, animated: animated)
        refreshResumeVisibility()
    }

    // MARK: - 布局

    private func setupUI() {
        view.backgroundColor = BKTheme.Color.bg
        title = "bk剪辑"
        navigationController?.navigationBar.isHidden = true

        titleLabel.text = "bk剪辑"
        titleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        titleLabel.textColor = BKTheme.Color.text

        subtitleLabel.text = "导入一段视频，自动找出气口并剪掉"
        subtitleLabel.font = BKTheme.Font.body
        subtitleLabel.textColor = BKTheme.Color.text2
        subtitleLabel.numberOfLines = 0

        pickButton.setTitle("选择视频", for: .normal)
        pickButton.titleLabel?.font = BKTheme.Font.button
        pickButton.backgroundColor = BKTheme.Color.gold
        pickButton.tintColor = .white
        pickButton.layer.cornerRadius = 10
        pickButton.heightAnchor.constraint(equalToConstant: 50).isActive = true
        pickButton.addTarget(self, action: #selector(pickTapped), for: .touchUpInside)

        resumeButton.setTitle("继续上次编辑", for: .normal)
        resumeButton.titleLabel?.font = BKTheme.Font.button
        resumeButton.setTitleColor(BKTheme.Color.accent, for: .normal)
        resumeButton.heightAnchor.constraint(equalToConstant: BKTheme.Space.minTap).isActive = true
        resumeButton.addTarget(self, action: #selector(resumeTapped), for: .touchUpInside)

        statusLabel.font = BKTheme.Font.mono
        statusLabel.textColor = BKTheme.Color.text2
        statusLabel.numberOfLines = 0
        statusLabel.text = "尚无素材"

        versionLabel.text = "ver \(BKConfig.appVersion)"
        versionLabel.font = BKTheme.Font.small
        versionLabel.textColor = BKTheme.Color.text3
        versionLabel.textAlignment = .center
        versionLabel.isUserInteractionEnabled = true
        // 调试入口藏在版本号后面，连点 7 次。
        // 不放显眼位置是因为现实使用里误触的概率比想debug的概率高得多
        versionLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(versionTapped))
        )

        spinner.hidesWhenStopped = true
        spinner.color = BKTheme.Color.gold

        let stack = UIStackView(arrangedSubviews: [
            titleLabel, subtitleLabel, pickButton, resumeButton, statusLabel, spinner
        ])
        stack.axis = .vertical
        stack.spacing = BKTheme.Space.lg
        stack.alignment = .fill
        stack.setCustomSpacing(BKTheme.Space.xs, after: titleLabel)
        stack.setCustomSpacing(BKTheme.Space.xxl, after: subtitleLabel)
        stack.setCustomSpacing(BKTheme.Space.sm, after: pickButton)

        view.addSubview(stack)
        view.addSubview(versionLabel)

        stack.translatesAutoresizingMaskIntoConstraints = false
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: BKTheme.Space.xl),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -BKTheme.Space.xl),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            versionLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -BKTheme.Space.lg),
            versionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            versionLabel.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func refreshResumeVisibility() {
        resumeButton.isHidden = BKDraftStore.shared.resumeProject() == nil
    }

    // MARK: - 交互

    @objc private func pickTapped() {
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
        // 只要视频。这个过滤是在系统层做的，App 拿到的结果一定是视频
        config.filter = .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .automatic

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func resumeTapped() {
        guard let project = BKDraftStore.shared.resumeProject() else { return }
        BKLog.shared.i("恢复工程 \(project.id.uuidString.prefix(8))，\(project.cutCount) 刀")
        spinner.startAnimating()
        statusLabel.text = "正在找回上次的素材…"

        // 工程里只存了 localIdentifier，素材要靠它重新捞回来
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [project.assetLocalID], options: nil)
        guard let phAsset = fetch.firstObject else {
            spinner.stopAnimating()
            statusLabel.text = "上次的素材找不到了，可能已被删除"
            BKLog.shared.e("恢复失败：localIdentifier 查不到 PHAsset \(project.assetLocalID)")
            return
        }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { [weak self] asset, _, info in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.spinner.stopAnimating()
                guard let asset = asset else {
                    self.statusLabel.text = "素材读取失败"
                    let err = info?[PHImageErrorKey] as? Error
                    BKLog.shared.e("恢复时 AVAsset 请求失败：\(err?.localizedDescription ?? "未知原因")")
                    return
                }
                let probe = BKAssetProbe.probe(asset)
                self.openEditor(asset: asset, localID: project.assetLocalID, project: project, probeInfo: probe)
            }
        }
    }

    private func openEditor(asset: AVAsset, localID: String, project: BKProject?, probeInfo: BKAssetProbe.Info) {
        let editor = BKEditorViewController(asset: asset, localID: localID, probeInfo: probeInfo, project: project)
        navigationController?.pushViewController(editor, animated: true)
    }

    @objc private func versionTapped() {
        // Ad Hoc 是 Release 包，#if DEBUG 不生效，面板开关走运行时判断
        BKDebug.tapVersionTag(self)
    }

    private func showPermissionDenied() {
        let alert = UIAlertController(
            title: "需要相册权限",
            message: "去「设置 → bk剪辑 → 照片」里改成「所有照片」。\n选「限定的照片」也行，但要确定包含了你想剪的那段视频。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "去设置", style: .default) { _ in
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - 相册回调

extension BKRootViewController: PHPickerViewControllerDelegate {

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard let result = results.first else {
            BKLog.shared.d("相册选择已取消")
            return
        }
        // 拿 localIdentifier 而不是直接取数据：
        // 一是它稳定，下次启动还能凭它找回同一条素材；
        // 二是直接取 NSItemProvider 在大文件上会先把整个视频读进内存
        guard let localID = result.assetIdentifier else {
            BKLog.shared.w("拿不到 assetIdentifier，无法定位素材")
            return
        }
        currentLocalID = localID
        loadAsset(localID: localID)
    }

    private func loadAsset(localID: String) {
        spinner.startAnimating()
        statusLabel.text = "正在读取素材…"

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil)
        guard let phAsset = fetch.firstObject else {
            spinner.stopAnimating()
            statusLabel.text = "素材找不到了，可能已被删除"
            BKLog.shared.e("localIdentifier 查不到对应 PHAsset：\(localID)")
            return
        }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true   // 素材在 iCloud 时允许联网拉下来
        options.deliveryMode = .highQualityFormat

        PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { [weak self] asset, _, info in
            DispatchQueue.main.async {
                self?.spinner.stopAnimating()
                guard let asset = asset else {
                    self?.statusLabel.text = "读取失败"
                    let err = info?[PHImageErrorKey] as? Error
                    BKLog.shared.e("AVAsset 请求失败：\(err?.localizedDescription ?? "未知原因")")
                    return
                }
                self?.handleLoaded(asset: asset, localID: localID)
            }
        }
    }

    private func handleLoaded(asset: AVAsset, localID: String) {
        currentAVAsset = asset

        // 规范第 1 条：必打点。这行日志之后所有关于方向的判断都以此为准
        let info = BKLog.measure("素材探测") { BKAssetProbe.probe(asset) }
        BKLog.shared.i(info.logLine)

        statusLabel.text = """
        原始 \(Int(info.naturalWidth))×\(Int(info.naturalHeight))
        显示 \(Int(info.displayWidth))×\(Int(info.displayHeight))（\(info.isPortrait ? "竖版" : "横版")）
        旋转 \(Int(info.rotationDegrees))° · \(String(format: "%.2f", info.fps))fps · \(info.estimatedBitrateKbps)kbps
        音轨 \(info.hasAudio ? "有" : "无")
        """

        if !info.hasAudio {
            BKLog.shared.w("素材没有音轨，去气口无从谈起")
            spinner.stopAnimating()
            let alert = UIAlertController(
                title: "这条视频没有声音",
                message: "去气口靠音轨判断呼吸停顿，无声视频没法自动找气口。",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "知道了", style: .cancel))
            present(alert, animated: true)
            return
        }
        if info.isPortrait && info.displayWidth > info.displayHeight {
            // 理论上不可能，出现了说明 preferredTransform 没取到
            BKLog.shared.e("方向判定异常：isPortrait 与显示尺寸自相矛盾")
        }

        openEditor(asset: asset, localID: localID, project: nil, probeInfo: info)
    }
}
