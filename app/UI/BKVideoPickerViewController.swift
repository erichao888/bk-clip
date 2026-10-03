//
//  BKVideoPickerViewController.swift
//  bk剪辑 — 视频勾选页（起始页 ⊕ 打开）
//
//  【为什么自建，不用系统 PHPicker】
//  系统 PHPicker 的选择态是「整格高亮 + 对勾」，没有「点圈选 / 点圈外预览」这套手势，
//  而且预览要退出去、丢上下文。皓哥要的是挑素材时能当场看片段对不对，
//  所以自己搭一个：每格右上角一个小圆圈专管勾选，点圈外直接全屏播。
//
//  【手势分工（定稿 6.1）】
//  · 点右上角小圆圈 → 打勾 / 取消（不触发预览）
//  · 点圆圈以外     → 全屏预览（AVPlayer，带声音）
//  · 右上角数字角标 → 已选条数，点它进「已选」筛选
//
//  【预览必须显式设音频会话】
//  默认 soloAmbient 服从静音键，一静音整条无声 —— 挑素材时听不清就白挑了。
//  一律 .playback + .moviePlayback。
//

import UIKit
import Photos
import AVFoundation

final class BKVideoPickerViewController: UIViewController {

    /// 勾选完成回传 localIdentifier 列表（按点选顺序）
    var onDone: (([String]) -> Void)?

    // MARK: - 数据

    private var allIDs: [String] = []
    /// 已选，保持点选顺序（和系统选择器一致：先点的在前）
    private var picked: [String] = []
    private var pickedSet: Set<String> = []
    private var onlyPicked = false

    // MARK: - 界面

    private let grid: UICollectionView
    private let countButton = UIButton(type: .system)
    private let footer = UIView()
    private let doneButton = UIButton(type: .system)

    // MARK: - 初始化

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 10, left: 10, bottom: 90, right: 10)
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("本 App 不走 storyboard") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BKTheme.Color.page
        title = "选视频"
        setupUI()
        setupAudio()
        loadLibrary()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 预览页可能还在播，走的时候把它收掉
        BKVideoLibrary.stopPreview()
    }

    /// App 内播视频必须显式设音频会话，否则一静音键就全哑
    private func setupAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            BKLog.shared.w("音频会话设置失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 布局

    private func setupUI() {
        grid.backgroundColor = .clear
        grid.dataSource = self
        grid.delegate = self
        grid.alwaysBounceVertical = true
        grid.register(BKVideoPickCell.self, forCellWithReuseIdentifier: BKVideoPickCell.reuseId)
        view.addSubview(grid)

        // 右上角：已选条数角标，点它切「只看已选」
        countButton.titleLabel?.font = BKTheme.Font.button
        countButton.setTitleColor(BKTheme.Color.danger, for: .normal)
        countButton.backgroundColor = BKTheme.Color.panel
        countButton.layer.cornerRadius = 15
        countButton.layer.borderWidth = 1
        countButton.layer.borderColor = BKTheme.Color.danger.cgColor
        countButton.addTarget(self, action: #selector(filterTapped), for: .touchUpInside)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: countButton)

        // 底部：确认条
        footer.backgroundColor = BKTheme.Color.bar
        view.addSubview(footer)

        doneButton.setTitle("添加", for: .normal)
        doneButton.titleLabel?.font = BKTheme.Font.button
        doneButton.setTitleColor(.white, for: .normal)
        doneButton.backgroundColor = BKTheme.Color.accent
        doneButton.layer.cornerRadius = 22
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        doneButton.isEnabled = false
        doneButton.alpha = 0.4
        footer.addSubview(doneButton)

        for v in [grid, footer, countButton, doneButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 88),

            doneButton.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            doneButton.topAnchor.constraint(equalTo: footer.topAnchor, constant: 12),
            doneButton.widthAnchor.constraint(equalToConstant: 160),
            doneButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        updateCount()
    }

    // MARK: - 素材库

    private func loadLibrary() {
        // iOS 16+ 用现代 authorizationStatus(for: .readWrite)，老式无参回调在 iOS 26 不触发
        let status: PHAuthorizationStatus = {
            if #available(iOS 16.0, *) { return PHPhotoLibrary.authorizationStatus(for: .readWrite) }
            return PHPhotoLibrary.authorizationStatus()
        }()
        guard status == .authorized || status == .limited else {
            // 没权限：自己再拉一次授权（双保险，防根页的拉授权在某些系统上没生效）
            requestAccessThenLoad()
            return
        }
        allIDs = BKVideoLibrary.videoLocalIDs()
        grid.reloadData()
        if allIDs.isEmpty {
            showEmpty()
        }
        BKLog.shared.i("勾选页载入 \(allIDs.count) 条视频")
    }

    /// 没权限时拉授权，回调触发后再决定是否载入（现代 API，确保 iOS 26 上回调会来）
    private func requestAccessThenLoad() {
        let decide: (PHAuthorizationStatus) -> Void = { [weak self] s in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if s == .authorized || s == .limited {
                    self.loadLibrary()
                } else {
                    self.showDenied()
                }
            }
        }
        if #available(iOS 16.0, *) {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { decide($0) }
        } else {
            PHPhotoLibrary.requestAuthorization { decide($0) }
        }
    }

    private func showDenied() {
        let label = UILabel()
        label.text = "没有相册权限\n去「设置 › 隐私 › 相册」打开"
        label.font = BKTheme.Font.body
        label.textColor = BKTheme.Color.text2
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func showEmpty() {
        let label = UILabel()
        label.text = "相册里没有视频"
        label.font = BKTheme.Font.body
        label.textColor = BKTheme.Color.text3
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    /// 当前要显示的列表。onlyPicked 时只留已选
    private var visibleIDs: [String] {
        onlyPicked ? allIDs.filter { pickedSet.contains($0) } : allIDs
    }

    /// 勾选序号（1 起）。没选中返回 0
    private func pickIndex(of id: String) -> Int {
        guard let i = picked.firstIndex(of: id) else { return 0 }
        return i + 1
    }

    private func updateCount() {
        let n = picked.count
        countButton.setTitle(" \(n) ", for: .normal)
        countButton.isHidden = n == 0
        doneButton.isEnabled = n > 0
        doneButton.alpha = n > 0 ? 1.0 : 0.4
        let title = n > 0 ? "添加 \(n) 条" : "添加"
        doneButton.setTitle(title, for: .normal)
    }

    // MARK: - 动作

    @objc private func filterTapped() {
        onlyPicked.toggle()
        countButton.backgroundColor = onlyPicked ? BKTheme.Color.danger : BKTheme.Color.panel
        countButton.setTitleColor(onlyPicked ? .white : BKTheme.Color.danger, for: .normal)
        grid.reloadData()
    }

    @objc private func doneTapped() {
        guard !picked.isEmpty else { return }
        onDone?(picked)
    }
}

// MARK: - 网格

extension BKVideoPickerViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        visibleIDs.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: BKVideoPickCell.reuseId, for: indexPath) as! BKVideoPickCell
        let id = visibleIDs[indexPath.item]
        cell.setID(id)
        cell.setPickIndex(pickIndex(of: id))
        cell.onToggle = { [weak self] in self?.togglePick(id) }
        cell.onPreview = { [weak self] in self?.preview(id) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        didSelectItemAt indexPath: IndexPath) {
        // cell 自己的按钮处理点圆圈/点圈外，这里只在空白处兜底当预览
        preview(visibleIDs[indexPath.item])
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        // 三列正方形，间距跟着 sectionInset 走
        let spacing: CGFloat = 6
        let insets: CGFloat = 10
        let columns: CGFloat = 3
        let w = floor((view.bounds.width - insets * 2 - spacing * (columns - 1)) / columns)
        return CGSize(width: w, height: w)
    }

    // MARK: - 勾选 / 预览

    /// 勾选切换。名字带 Pick 后缀是为了不和上面 `onlyPicked.toggle()`（Bool 的内建方法）撞车
    private func togglePick(_ id: String) {
        if pickedSet.contains(id) {
            pickedSet.remove(id)
            if let i = picked.firstIndex(of: id) { picked.remove(at: i) }
        } else {
            pickedSet.insert(id)
            picked.append(id)
        }
        updateCount()
        // 只重载这一格，别整屏闪（几百条视频整屏 reload 会明显卡）
        grid.reloadItems(at: visibleIDs.enumerated()
            .filter { $0.element == id }
            .map { IndexPath(item: $0.offset, section: 0) })
    }

    private func preview(_ id: String) {
        BKVideoLibrary.stopPreview()
        let vc = BKVideoPreviewViewController(localID: id, isPicked: pickedSet.contains(id))
        // 【不要全屏】皓哥定：预览要比全屏小一些，用 .pageSheet 呈半屏卡，
        // 底下勾选页还露着 —— 挑这条的时候还能看到列表和别的素材，
        // 不用退出去再进来。半屏卡可以往上拖成全屏（iOS 原生手势）。
        vc.modalPresentationStyle = .pageSheet
        if let sheet = vc.sheetPresentationController {
            // 【70% 屏高】皓哥定：半屏（50%）太小，画面看着憋屈。
            // 系统只给 .medium / .large 两档，70% 得自己算 —— 用 Detent.custom。
            //
            // ⚠️ **Detent.custom 是 iOS 16.0+ API**，本 App 部署目标 15.0，
            // 直接写上去编译就红（"only available in iOS 16.0 or newer"）。
            // 所以必须用 #available 包一层，15 上回落到 .medium。
            if #available(iOS 16.0, *) {
                let id = UISheetPresentationController.Detent.Identifier("bkPreview70")
                let seventy = UISheetPresentationController.Detent.custom(identifier: id) { ctx in
                    // maximumDetentValue 是整屏高度（不含状态栏/安全区的那部分），
                    // 乘 0.7 就是「七成屏」这个视觉效果
                    ctx.maximumDetentValue * 0.7
                }
                sheet.detents = [seventy, .large()]   // 70% 和全屏，可上拖
                sheet.selectedDetentIdentifier = id   // 默认就停在 70%
            } else {
                // iOS 15 只有 medium / large 两档，用 medium 顶一下
                sheet.detents = [.medium(), .large()]
                sheet.selectedDetentIdentifier = .medium
            }
            // ⚠️ 别用 `largestUndimmedDetentIdentifier`（背景不压暗）——
            // 那也是 **iOS 16.0+** 的 API，本 App 部署目标 15.0，写上去直接编译失败。
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = BKTheme.Radius.sheet
        }
        // 预览页里点右上角小圆圈 = 选中/取消这条，直接同步回列表
        vc.onTogglePick = { [weak self] toggledID in
            self?.togglePick(toggledID)
        }
        vc.onClose = { [weak self] in
            BKVideoLibrary.stopPreview()
            self?.dismiss(animated: true)
        }
        present(vc, animated: true)
    }
}

// MARK: - 勾选格

/// 一格视频：封面 + 时长 + 右上角小圆圈（勾选）+ 时长角标
final class BKVideoPickCell: UICollectionViewCell {

    static let reuseId = "BKVideoPickCell"

    /// 点小圆圈：切换勾选
    var onToggle: (() -> Void)?
    /// 点圆圈以外：预览
    var onPreview: (() -> Void)?

    private let cover = UIImageView()
    private let shade = UIView()
    private let durLabel = UILabel()
    private let circle = UIButton(type: .system)
    private let numLabel = UILabel()
    private var pick = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("本 App 不走 storyboard") }

    private func setup() {
        contentView.backgroundColor = UIColor(hex: 0x2A2A28)
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = 8

        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        contentView.addSubview(cover)

        shade.backgroundColor = UIColor(hex: 0x000000, alpha: 0.45)
        contentView.addSubview(shade)

        durLabel.font = BKTheme.Font.monoSmall
        durLabel.textColor = .white
        durLabel.textAlignment = .right
        contentView.addSubview(durLabel)

        // 小圆圈本体。参考图是空心圈，选中后填成红色 + 序号
        circle.backgroundColor = UIColor(hex: 0x000000, alpha: 0.28)
        circle.layer.cornerRadius = 12
        circle.layer.borderWidth = 1.6
        circle.layer.borderColor = UIColor(hex: 0xFFFFFF, alpha: 0.9).cgColor
        circle.addTarget(self, action: #selector(circleTapped), for: .touchUpInside)
        contentView.addSubview(circle)

        numLabel.font = .systemFont(ofSize: 12, weight: .bold)
        numLabel.textColor = .white
        numLabel.textAlignment = .center
        numLabel.isUserInteractionEnabled = false
        contentView.addSubview(numLabel)

        for v in [cover, shade, durLabel, circle, numLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: contentView.topAnchor),
            cover.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cover.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            shade.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            shade.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            shade.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            shade.heightAnchor.constraint(equalToConstant: 20),

            durLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            durLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            circle.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            circle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            circle.widthAnchor.constraint(equalToConstant: 24),
            circle.heightAnchor.constraint(equalToConstant: 24),

            numLabel.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            numLabel.centerYAnchor.constraint(equalTo: circle.centerYAnchor)
        ])

        // 整格点击 = 预览。小圆圈盖在上面，它的点击优先（后加的子视图在上层）
        let tap = UITapGestureRecognizer(target: self, action: #selector(cellTapped))
        contentView.addGestureRecognizer(tap)
    }

    /// 装填。id 存一份：缩略图是异步的，回调要靠它比对，
    /// 否则会出现「A 的封面画到 B 上面」（cell 复用高频）
    func setID(_ id: String) {
        lastID = id
        durLabel.text = BKVideoLibrary.formatDuration(BKVideoLibrary.duration(localID: id))
        BKThumbnails.image(localID: id, size: CGSize(width: 200, height: 200)) { [weak self] img in
            guard let self = self, self.lastID == id else { return }
            self.cover.image = img
        }
        applyPick()
    }

    /// 勾选序号（1 起），0 = 未选
    func setPickIndex(_ idx: Int) {
        pick = idx
        applyPick()
    }

    private var lastID = ""

    private func applyPick() {
        if pick > 0 {
            circle.backgroundColor = BKTheme.Color.danger
            circle.layer.borderColor = BKTheme.Color.danger.cgColor
            numLabel.text = "\(pick)"
            numLabel.isHidden = false
            contentView.layer.borderWidth = 2
            contentView.layer.borderColor = BKTheme.Color.danger.cgColor
        } else {
            circle.backgroundColor = UIColor(hex: 0x000000, alpha: 0.28)
            circle.layer.borderColor = UIColor(hex: 0xFFFFFF, alpha: 0.9).cgColor
            numLabel.text = nil
            numLabel.isHidden = true
            contentView.layer.borderWidth = 0
        }
    }

    @objc private func circleTapped() {
        onToggle?()
    }

    @objc private func cellTapped() {
        onPreview?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cover.image = nil
        onToggle = nil
        onPreview = nil
        lastID = ""
    }
}
