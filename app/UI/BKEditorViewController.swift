//
//  BKEditorViewController.swift
//  bk剪辑 — 编辑页（第四批改：按 docs/界面定稿.md 重写）
//
//  【这份代码的上级是定稿，不是聊天记录】
//  改任何一处界面之前，先改 docs/界面定稿.md 再改这里。前面十几轮最大的教训是
//  「想到哪写到哪」，约定只落在聊天里，结果代码和皓哥脑子里的图对不上。
//
//  【本页承担什么】
//  波形可视化 + 自动检测 + 手动微调 + 撤销重做 + 播放校对 + 导出。
//
//  【数据流】
//  asset → BKAudioAnalyzer 提取包络 → BKDetector 出切点
//        → BKTimeline.build 合成 marks → 轨道画出来
//  手动拖边界 / 点片段 / 切口 → 改 marks → 走 commit() 入撤销栈 → 重画 + 落盘
//
//  【播放语义】AVPlayer 走原始时间轴：播放头扫过粉红区间时
//  你听到的是「将被删掉的声音」，这正是调刀口时最需要听的东西。
//
//  【指针居中带来的一个连锁变化】
//  指针不动、内容滚，所以「预览画面跟指针跳帧」变成了：
//  滚动回调 → seek 播放器。预览画面本身不需要任何动效代码。
//

import UIKit
import AVFoundation
import Photos

final class BKEditorViewController: UIViewController {

    // MARK: - 状态

    private let asset: AVAsset
    private let localID: String
    private let probeInfo: BKAssetProbe.Info
    private var project: BKProject?
    private var envelope: BKEnvelope?

    /// 撤销栈。所有编辑改动都从它进出，绝不允许有第二处直接改 project.marks
    private var history = BKHistory()
    /// 是否正在拖边界。拖动过程中的连续改动只占撤销栈一格
    private var boundaryDragging = false
    /// 这一次拖动是否已经入过栈。false 时下一次提交走 push，之后走 amend
    private var boundaryCommitted = false

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var timeObserver: Any?

    private var sliderWork: DispatchWorkItem?
    private var playing = false
    private var lastTime: Double = 0
    private var isExporting = false

    // MARK: - 界面

    private let listPanel = UIView()
    private let listTable = UITableView(frame: .zero, style: .plain)
    private var listVisible = false

    private let previewContainer = UIView()
    private let overview = BKOverviewBar()
    private let trackContainer = UIView()
    private let track = BKTrackView()

    // 第一行：停止 / 播放 / 反选 / 切割 / 检测 + 时间码
    private let stopButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let invertButton = UIButton(type: .system)
    private let cutButton = UIButton(type: .system)
    private let detectButton = UIButton(type: .system)
    private let timeLabel = UILabel()

    // 第二行：撤销 / 重做 + 缩放
    private let undoButton = UIButton(type: .system)
    private let redoButton = UIButton(type: .system)
    private let zoomOutButton = UIButton(type: .system)
    private let zoomSlider = UISlider()
    private let zoomInButton = UIButton(type: .system)

    private let exportButton = UIButton(type: .system)
    private let thresholdTitle = UILabel()
    private let thresholdSlider = UISlider()
    private let infoLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    /// 素材库顺序。有它才能「上一条 / 下一条」；只从起始页单挑一条进来时是空的
    private let videoIDs: [String]

    // MARK: - 初始化

    init(asset: AVAsset,
         localID: String,
         probeInfo: BKAssetProbe.Info,
         project: BKProject?,
         videoIDs: [String] = []) {
        self.asset = asset
        self.localID = localID
        self.probeInfo = probeInfo
        self.project = project
        self.videoIDs = videoIDs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("本 App 不走 storyboard")
    }

    deinit {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BKTheme.Color.page
        setupNav()
        setupPlayer()
        setupUI()
        startAnalysis()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        // 边缘右滑返回和「拖边界把手」是死敌：
        // 手指从屏幕左缘起手往右拖，系统会当成返回手势，整个编辑页跟着滑走
        // （真机实测：拖到一半页面退回了起始页）。剪辑页一律用左上角按钮返回
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        player?.pause()
        playing = false
        updatePlayButtonIcon()
        BKDraftStore.shared.flushIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer?.frame = previewContainer.bounds
    }

    // MARK: - 导航栏

    private func setupNav() {
        navigationItem.title = BKVideoLibrary.assetName(localID: localID)

        // 左：☰ 素材列表。用系统图标而不是字面「☰」，字重线宽才和工具栏对得上
        let listItem = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal"),
                                       style: .plain,
                                       target: self,
                                       action: #selector(toggleListTapped))
        listItem.isEnabled = videoIDs.count > 1
        navigationItem.leftBarButtonItem = listItem

        // 右：导出。定稿里唯一「图标 + 文字」的按钮 ——
        // 它按下去不可逆，只给图标认错代价太大
        exportButton.frame = CGRect(x: 0, y: 0, width: 84, height: 32)
        exportButton.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        exportButton.setTitle(" 导出", for: .normal)
        exportButton.tintColor = BKTheme.Color.text
        exportButton.setTitleColor(BKTheme.Color.text, for: .normal)
        exportButton.titleLabel?.font = BKTheme.Font.caption
        exportButton.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: exportButton)
    }

    // MARK: - 播放器

    private func setupPlayer() {
        // 音频会话必须自己显式设。默认的 soloAmbient 会服从机身静音键，
        // 一拨静音视频就没声 —— 视频类 App 一律用 .playback 类别忽略它
        configureAudioSession()

        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        p.volume = 1.0
        p.isMuted = false
        player = p
        logAudioDiagnostics()

        let layer = AVPlayerLayer()
        layer.player = p
        // aspect 保证竖版素材在固定高度里完整显示，不裁切不变形
        layer.videoGravity = .resizeAspect
        playerLayer = layer
        previewContainer.layer.addSublayer(layer)

        // 0.033 ≈ 30fps。滚动是连续画面，20fps 会明显一格一格地跳
        let interval = CMTime(seconds: 0.033, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.syncPlayhead(to: CMTimeGetSeconds(time))
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(playerFinished),
                                               name: .AVPlayerItemDidPlayToEndTime,
                                               object: item)
    }

    /// 音频会话：显式声明这是个要出声的视频播放器
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            // setActive 在别家 App 占着音频通道时会失败。
            // 不打这行日志，用户看到的现象只是「没声音」，根本没法归因
            BKLog.shared.e("音频会话激活失败：\(error.localizedDescription)")
        }
    }

    /// 没有 Xcode 时，排障全靠这一行：真机上如果还是没声，
    /// 用「文件 App → bk剪辑」把 bk.log 拖出来，一眼看出是
    /// 素材没音轨、路由不对，还是类别没设上
    private func logAudioDiagnostics() {
        let session = AVAudioSession.sharedInstance()
        let trackCount = asset.tracks(withMediaType: .audio).count
        BKLog.shared.i(String(
            format: "音频会话 类别=%@ 模式=%@ 输出=%@ 音量=%.2f 他人占道=%@ | 素材音轨=%d",
            session.category.rawValue,
            session.mode.rawValue,
            session.currentRoute.outputs.first?.portName ?? "未知",
            session.outputVolume,
            session.isOtherAudioPlaying ? "是" : "否",
            trackCount))
    }

    @objc private func playerFinished() {
        playing = false
        updatePlayButtonIcon()
        player?.seek(to: CMTime(seconds: 0, preferredTimescale: 600))
        syncPlayhead(to: 0)
    }

    /// 播放回调 / 手动 seek 之后统一走这里：
    /// 时间码、指针、概览条视窗框三处必须同时跟上，漏一处就会看到「画面和框对不上」
    private func syncPlayhead(to t: Double) {
        guard let p = project else { return }
        let clamped = min(max(t, 0), p.duration)
        lastTime = clamped
        timeLabel.text = "\(formatClock(clamped)) / \(formatClock(p.duration))"
        track.setPointerTime(clamped)
        overview.setViewport(track.viewport)
    }

    // MARK: - 布局

    private func setupUI() {
        // ---- 预览画面 ----
        previewContainer.backgroundColor = BKTheme.Color.preview
        previewContainer.layer.cornerRadius = BKTheme.Radius.card
        previewContainer.clipsToBounds = true

        // 画面上左右滑动 = 换上一条 / 下一条。
        // 只在有素材列表时挂 —— 单条素材挂上去，滑一下没反应反而像坏了
        if videoIDs.count >= 2 {
            let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(nextVideoTapped))
            swipeLeft.direction = .left
            let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(prevVideoTapped))
            swipeRight.direction = .right
            previewContainer.addGestureRecognizer(swipeLeft)
            previewContainer.addGestureRecognizer(swipeRight)
            previewContainer.isUserInteractionEnabled = true
        }

        // ---- 概览条 ----
        overview.delegate = self

        // ---- 主轨道 ----
        trackContainer.backgroundColor = BKTheme.Color.page
        trackContainer.layer.cornerRadius = BKTheme.Radius.card
        trackContainer.clipsToBounds = true

        track.delegate = self
        track.translatesAutoresizingMaskIntoConstraints = false
        trackContainer.addSubview(track)
        NSLayoutConstraint.activate([
            track.leadingAnchor.constraint(equalTo: trackContainer.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trackContainer.trailingAnchor),
            track.topAnchor.constraint(equalTo: trackContainer.topAnchor),
            track.bottomAnchor.constraint(equalTo: trackContainer.bottomAnchor)
        ])

        // ---- 工具栏第一排：停止 / 播放 / 反选 / 切割 / 检测 ----
        // 时间码不在这排（皓哥定稿：所有数字放画面预览区下面），两侧各一个弹性空位把它居中
        configureTool(stopButton, systemName: "stop.fill", action: #selector(stopTapped))
        configureTool(playButton, systemName: "play.fill", action: #selector(playTapped))
        updatePlayButtonIcon()

        // ⟳ 反选是自定义图（皓哥从 5 个方案里选的 B），自己设图，只套按钮皮
        invertButton.setImage(BKIcons.loopArrow(), for: .normal)
        applyToolStyle(invertButton, action: #selector(invertTapped))

        configureTool(cutButton, systemName: "scissors", action: #selector(cutTapped))
        // 皓哥指定：自动检测用**吸管**，不是滴管 —— 就是剪映那个取样的东西
        configureTool(detectButton, systemName: "eyedropper", action: #selector(detectTapped))

        let row1Lead = UIView()
        let row1Tail = UIView()
        let row1 = UIStackView(arrangedSubviews: [
            row1Lead, stopButton, playButton, invertButton, cutButton, detectButton, row1Tail
        ])
        row1.axis = .horizontal
        row1.spacing = BKTheme.Space.sm
        row1.alignment = .center

        // ---- 工具栏第二排：撤销 / 重做 + 缩放 ----
        configureTool(undoButton, systemName: "arrow.uturn.backward", action: #selector(undoTapped))
        configureTool(redoButton, systemName: "arrow.uturn.forward", action: #selector(redoTapped))

        zoomOutButton.setImage(UIImage(systemName: "minus"), for: .normal)
        styleZoomStep(zoomOutButton, action: #selector(zoomOutTapped))
        zoomInButton.setImage(UIImage(systemName: "plus"), for: .normal)
        styleZoomStep(zoomInButton, action: #selector(zoomInTapped))

        zoomSlider.minimumValue = Float(BKTrackView.zoomMin)
        zoomSlider.maximumValue = Float(BKTrackView.zoomMax)
        zoomSlider.value = Float(track.zoomScreens)
        zoomSlider.minimumTrackTintColor = BKTheme.Color.gold
        zoomSlider.addTarget(self, action: #selector(zoomSliderChanged), for: .valueChanged)
        // 抗拉伸设成 required：UIStackView 的 fill 会去撑「最能被撑开」的那个，
        // 不钉住的话滑杆会被拉长、而 spacer 拿不到余量，布局就跟设计对不上了
        zoomSlider.setContentHuggingPriority(.required, for: .horizontal)

        let spacer2 = UIView()
        let row2 = UIStackView(arrangedSubviews: [
            undoButton, redoButton, spacer2, zoomOutButton, zoomSlider, zoomInButton
        ])
        row2.axis = .horizontal
        row2.spacing = BKTheme.Space.sm
        row2.alignment = .center
        zoomSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true

        // 两排工具栏共用一条底：把工具栏从页面上分出来（定稿：#F1F1EE）
        let toolbar = UIStackView(arrangedSubviews: [row1, row2])
        toolbar.axis = .vertical
        toolbar.spacing = BKTheme.Space.xs
        toolbar.alignment = .fill
        toolbar.backgroundColor = BKTheme.Color.bar
        toolbar.layer.cornerRadius = BKTheme.Radius.card
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.layoutMargins = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        // ---- 数字行：紧贴画面预览区下面（皓哥 2026-10-02 定稿）----
        // 左边是「当前 / 总长」，右边是「原时长 · 剪后 · 刀数 · 删了多少」。
        // 之前时间码塞在工具栏、统计塞在最底下，皓哥指出 iPhone 屏窄，
        // 工具栏已有 5 个图标 + 缩放滑杆，再塞数字会挤成一团，统一收拢到画面正下方
        timeLabel.font = BKTheme.Font.monoBig
        timeLabel.textColor = BKTheme.Color.text
        timeLabel.text = "00:00 / 00:00"
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        infoLabel.font = BKTheme.Font.monoSmall
        infoLabel.textColor = BKTheme.Color.text2
        infoLabel.numberOfLines = 2
        infoLabel.textAlignment = .right
        infoLabel.text = "正在准备…"

        let statsSpacer = UIView()
        let statsRow = UIStackView(arrangedSubviews: [timeLabel, statsSpacer, infoLabel])
        statsRow.axis = .horizontal
        statsRow.spacing = BKTheme.Space.md
        statsRow.alignment = .center

        // ---- 底部：阈值 + 状态 ----
        thresholdTitle.font = BKTheme.Font.mono
        thresholdTitle.textColor = BKTheme.Color.text
        thresholdTitle.text = "阈值 -37.5 dB"
        thresholdTitle.setContentHuggingPriority(.required, for: .horizontal)

        thresholdSlider.minimumValue = Float(BKConfig.Detect.clampLow)
        thresholdSlider.maximumValue = Float(BKConfig.Detect.clampHigh)
        thresholdSlider.value = Float((BKConfig.Detect.clampLow + BKConfig.Detect.clampHigh) / 2)
        if let p = project {
            thresholdSlider.value = Float(p.thresholdDb)
            thresholdTitle.text = String(format: "阈值 %.1f dB", p.thresholdDb)
        }
        thresholdSlider.minimumTrackTintColor = BKTheme.Color.warning
        thresholdSlider.addTarget(self, action: #selector(thresholdChanged), for: .valueChanged)

        let thresholdRow = UIStackView(arrangedSubviews: [thresholdTitle, thresholdSlider])
        thresholdRow.axis = .horizontal
        thresholdRow.spacing = BKTheme.Space.md
        thresholdRow.alignment = .center

        statusLabel.font = BKTheme.Font.caption
        statusLabel.textColor = BKTheme.Color.warning
        statusLabel.numberOfLines = 0

        spinner.hidesWhenStopped = true
        spinner.color = BKTheme.Color.gold

        let statusRow = UIStackView(arrangedSubviews: [statusLabel, spinner])
        statusRow.axis = .horizontal
        statusRow.spacing = BKTheme.Space.sm
        statusRow.alignment = .center

        setupListPanel()

        // 顺序照定稿第 4 节：工具栏 → 预览 → 数字行 → 主轨道 → 概览条 → 阈值/状态
        let stack = UIStackView(arrangedSubviews: [
            toolbar, listPanel, previewContainer, statsRow, trackContainer, overview,
            thresholdRow, statusRow
        ])
        stack.axis = .vertical
        stack.spacing = BKTheme.Space.sm
        stack.alignment = .fill
        stack.setCustomSpacing(BKTheme.Space.xs, after: toolbar)
        stack.setCustomSpacing(BKTheme.Space.xs, after: previewContainer)
        stack.setCustomSpacing(BKTheme.Space.md, after: listPanel)

        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: BKTheme.Space.md),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -BKTheme.Space.md),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: BKTheme.Space.sm),

            previewContainer.heightAnchor.constraint(equalToConstant: 240),
            trackContainer.heightAnchor.constraint(equalToConstant: 130),
            overview.heightAnchor.constraint(equalToConstant: 30)
        ])

        updateUndoButtons()
    }

    /// 设图 + 套皮 + 挂 action。工具栏按钮一律走这里，样式才会一致
    private func configureTool(_ button: UIButton, systemName: String, action: Selector) {
        let cfg = UIImage.SymbolConfiguration(pointSize: BKTheme.Button.iconPoint, weight: .regular)
        button.setImage(UIImage(systemName: systemName, withConfiguration: cfg), for: .normal)
        applyToolStyle(button, action: action)
    }

    /// 只套皮 + 挂 action，不动图。自定义图标（⟳）用这个入口
    private func applyToolStyle(_ button: UIButton, action: Selector) {
        button.tintColor = BKTheme.Color.text
        button.backgroundColor = BKTheme.Color.panel
        button.layer.cornerRadius = BKTheme.Button.radius
        button.layer.borderWidth = BKTheme.Button.border
        button.layer.borderColor = BKTheme.Color.line.cgColor
        button.clipsToBounds = true
        button.addTarget(self, action: action, for: .touchUpInside)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: BKTheme.Button.size),
            button.heightAnchor.constraint(equalToConstant: BKTheme.Button.size)
        ])
    }

    private func styleZoomStep(_ button: UIButton, action: Selector) {
        button.tintColor = BKTheme.Color.text2
        button.backgroundColor = BKTheme.Color.panel
        button.layer.cornerRadius = 14
        button.layer.borderWidth = BKTheme.Button.border
        button.layer.borderColor = BKTheme.Color.line.cgColor
        button.clipsToBounds = true
        button.addTarget(self, action: action, for: .touchUpInside)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    /// 播放 / 暂停图标互换。收集到一个地方，免得三处调用改了形状忘了另一处
    private func updatePlayButtonIcon() {
        let cfg = UIImage.SymbolConfiguration(pointSize: BKTheme.Button.iconPoint, weight: .regular)
        playButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill",
                                    withConfiguration: cfg),
                            for: .normal)
    }

    // MARK: - 素材列表面板

    /// 面板高度 = 5 行。多于 5 条就在这 5 行的窗口里上下滚动，
    /// 不撑开页面 —— 撑开的话轨道和按钮会被挤出屏幕，比藏起来还难用
    private let listVisibleRows = 5

    private func setupListPanel() {
        listPanel.backgroundColor = BKTheme.Color.panel
        listPanel.layer.cornerRadius = BKTheme.Radius.card
        listPanel.layer.borderWidth = 1
        listPanel.layer.borderColor = BKTheme.Color.line.cgColor
        listPanel.clipsToBounds = true
        listPanel.isHidden = true          // 默认隐藏，UIStackView 会把它折叠掉

        listTable.translatesAutoresizingMaskIntoConstraints = false
        listTable.backgroundColor = .clear
        listTable.separatorColor = BKTheme.Color.line
        listTable.rowHeight = 44
        listTable.dataSource = self
        listTable.delegate = self
        listTable.register(BKVideoNameCell.self, forCellReuseIdentifier: "BKVideoNameCell")
        listPanel.addSubview(listTable)

        NSLayoutConstraint.activate([
            listPanel.heightAnchor.constraint(equalToConstant: CGFloat(listVisibleRows) * 44 + 8),
            listTable.leadingAnchor.constraint(equalTo: listPanel.leadingAnchor),
            listTable.trailingAnchor.constraint(equalTo: listPanel.trailingAnchor),
            listTable.topAnchor.constraint(equalTo: listPanel.topAnchor, constant: 4),
            listTable.bottomAnchor.constraint(equalTo: listPanel.bottomAnchor, constant: -4)
        ])
    }

    @objc private func toggleListTapped() {
        listVisible.toggle()
        listPanel.isHidden = !listVisible
        if listVisible {
            listTable.reloadData()
            // 打开时把当前这条滚到可见处，省得用户自己找
            if let i = currentIndex {
                listTable.scrollToRow(at: IndexPath(row: i, section: 0),
                                      at: .middle,
                                      animated: false)
            }
            BKLog.shared.d("打开素材列表，共 \(videoIDs.count) 条")
        }
    }

    // MARK: - 素材切换

    private var currentIndex: Int? {
        BKVideoLibrary.index(of: localID, in: videoIDs)
    }

    @objc private func prevVideoTapped() {
        guard let i = currentIndex, i > 0 else { return }
        openSibling(localID: videoIDs[i - 1])
    }

    @objc private func nextVideoTapped() {
        guard let i = currentIndex, i < videoIDs.count - 1 else { return }
        openSibling(localID: videoIDs[i + 1])
    }

    /// 换素材 = 换一个编辑页实例，而不是原地复用。
    /// 原地复用要手动清掉播放器、包络、工程、草稿写入状态，漏一个就是脏状态；
    /// 直接替换导航栈里最顶上的那个，干净且不会把栈越堆越深
    private func openSibling(localID targetID: String) {
        guard let nav = navigationController else { return }
        player?.pause()
        playing = false
        updatePlayButtonIcon()
        BKDraftStore.shared.flushIfNeeded()

        BKVideoLibrary.loadAVAsset(localID: targetID) { [weak self, weak nav] asset in
            guard let self = self, let nav = nav, let asset = asset else {
                BKLog.shared.e("切换素材失败：\(targetID)")
                return
            }
            let probe = BKAssetProbe.probe(asset)
            BKLog.shared.i(probe.logLine)
            let project = BKDraftStore.shared.draft(forLocalID: targetID)
            let vc = BKEditorViewController(asset: asset,
                                            localID: targetID,
                                            probeInfo: probe,
                                            project: project,
                                            videoIDs: self.videoIDs)
            var stack = nav.viewControllers
            if stack.last === self { stack.removeLast() }
            stack.append(vc)
            nav.setViewControllers(stack, animated: true)
        }
    }

    // MARK: - 提交与撤销
    //
    // 所有改动统一走 commit。历史栈是唯一入口，别图一时方便直接改 project.marks。

    private func commit(_ updated: BKProject, coalesce: Bool = false) {
        if coalesce && boundaryDragging {
            // 一次拖动只占一格：第一帧 push，之后 amend。
            // 反过来（先 amend）会把拖动前的状态覆盖掉，那一步就永远撤不回来了
            if boundaryCommitted {
                history.amend(updated)
            } else {
                history.push(updated)
                boundaryCommitted = true
            }
        } else {
            history.push(updated)
        }
        project = updated
        refreshTrack()
        updateInfo()
        updateUndoButtons()
        BKDraftStore.shared.scheduleSave(updated)
    }

    @objc private func undoTapped() {
        guard let restored = history.undo() else { return }
        project = restored
        refreshTrack()
        updateInfo()
        updateUndoButtons()
        BKDraftStore.shared.scheduleSave(restored)
        statusLabel.text = "已撤销"
        BKLog.shared.i("撤销 → 栈内第 \(history.depth) 格")
    }

    @objc private func redoTapped() {
        guard let restored = history.redo() else { return }
        project = restored
        refreshTrack()
        updateInfo()
        updateUndoButtons()
        BKDraftStore.shared.scheduleSave(restored)
        statusLabel.text = "已重做"
        BKLog.shared.i("重做 → 栈内第 \(history.depth) 格")
    }

    /// 撤销 / 重做按钮的可用性。灰掉比点了没反应好 ——
    /// 点了没反应，用户会以为是 App 卡了
    private func updateUndoButtons() {
        undoButton.isEnabled = history.canUndo
        redoButton.isEnabled = history.canRedo
        undoButton.alpha = history.canUndo ? 1.0 : 0.35
        redoButton.alpha = history.canRedo ? 1.0 : 0.35
    }

    // MARK: - 编辑操作

    /// 重建 marams 并提交。拖动边界传 coalesce: true
    private func applyMarks(_ marks: [BKMark], coalesce: Bool = false) {
        guard var p = project else { return }
        p.marks = BKTimeline.normalize(marks, duration: p.duration)
        p.updatedAt = Date()
        commit(p, coalesce: coalesce)
    }

    /// 按一下，就从**橙色指针现在指的地方**把轨道切开。
    ///
    /// 【切开 ≠ 删除】切口不进 cutRanges，所以导出时长纹丝不动。
    /// 它的作用是把一段划成两段，好让你单独处理其中一半 ——
    /// 下一步点哪一半，哪一半就变红被删掉。顺序是「先看切开什么样，再决定删哪边」，
    /// 比一按下去就删掉一截要安全得多
    @objc private func cutTapped() {
        guard var p = project else { return }
        let t = min(max(lastTime, 0), p.duration)

        // 离两头太近不切：切出来的是一截 0.1 秒的碎片，没有任何收拾的价值
        guard t > 0.1, t < p.duration - 0.1 else {
            statusLabel.text = "指针太靠两头了，这里切不出东西"
            return
        }
        // 同一个地方不重复下刀
        guard !p.splits.contains(where: { abs($0 - t) < 0.05 }) else {
            statusLabel.text = "这里已经有一道切口了"
            return
        }

        p.splits.append(t)
        p.splits.sort()
        p.updatedAt = Date()
        commit(p)
        statusLabel.text = String(format: "在 %.2fs 处切开 —— 点旁边的片段就能把那一段删掉", t)
        BKLog.shared.i(String(format: "手动切口 %.2fs（现有 %d 道）", t, p.splits.count))
    }

    /// ⟳ 反选：把指针所在的这一段在「留 / 删」之间倒一下。
    /// 和直接点轨道上那一段是同一件事，区别只是不用拿手指去点窄窄的一段
    @objc private func invertTapped() {
        togglePiece(at: lastTime)
    }

    /// 点一下 / 反选一段：粉红的把它恢复，绿的把它删掉
    private func togglePiece(at time: Double) {
        guard let p = project else { return }
        let shown = BKTimeline.pieces(duration: p.duration,
                                      cuts: p.cutRanges,
                                      splits: p.splits)
        for pc in shown where time >= pc.start && time <= pc.end {
            var cuts = p.cutRanges

            if pc.kind == .cut {
                cuts.removeAll { abs($0.0 - pc.start) < 1e-6 && abs($0.1 - pc.end) < 1e-6 }
                statusLabel.text = String(format: "恢复 %.2f~%.2fs", pc.start, pc.end)
                BKLog.shared.i(String(format: "恢复 %.2f~%.2fs", pc.start, pc.end))
            } else {
                guard (pc.end - pc.start) >= BKConfig.Detect.minCut else {
                    statusLabel.text = String(format: "这段只有 %.2fs，短于 %.2fs，不动它",
                                              pc.end - pc.start, BKConfig.Detect.minCut)
                    return
                }
                cuts.append((pc.start, pc.end))
                statusLabel.text = String(format: "删掉 %.2f~%.2fs", pc.start, pc.end)
                BKLog.shared.i(String(format: "删掉 %.2f~%.2fs", pc.start, pc.end))
            }
            // 手动增删和自动刀走同一条重建路径，保住「相邻严丝合缝」这条不变量
            applyMarks(BKTimeline.build(duration: p.duration, cuts: cuts))
            return
        }
        statusLabel.text = "指针这儿没有片段"
    }

    // MARK: - 分析与检测

    private func startAnalysis() {
        spinner.startAnimating()
        setControlsEnabled(false)
        statusLabel.text = "正在提取音频波形…"
        BKAudioAnalyzer.extractEnvelope(from: asset) { [weak self] result in
            guard let self = self else { return }
            self.spinner.stopAnimating()
            self.setControlsEnabled(true)
            switch result {
            case .failure(let err):
                self.statusLabel.text = "波形提取失败：\(err.localizedDescription)"
                BKLog.shared.e("包络提取失败：\(err.localizedDescription)")
            case .success(let env):
                self.envelope = env
                self.statusLabel.text = ""
                if self.project == nil {
                    self.createProject()
                    self.runDetection(override: nil)
                } else {
                    // 恢复编辑：不重跑检测，尊重上次保存的刀口
                    if let p = self.project {
                        BKDraftStore.shared.markOpened(p.id)
                        self.history.reset(p)
                    }
                    self.refreshTrack()
                    self.updateInfo()
                    self.statusLabel.text = "已恢复上次的编辑进度"
                }
                self.updateUndoButtons()
            }
        }
    }

    private func createProject() {
        guard let env = envelope else { return }
        // 时间轴以视频时长为准（音轨可能比画面长或短几毫秒）
        let duration = probeInfo.duration > 0 ? probeInfo.duration : env.duration
        let p = BKProject(
            id: UUID(),
            assetLocalID: localID,
            duration: duration,
            displayWidth: probeInfo.displayWidth,
            displayHeight: probeInfo.displayHeight,
            sourceRotationDegrees: probeInfo.rotationDegrees,
            thresholdDb: (BKConfig.Detect.clampLow + BKConfig.Detect.clampHigh) / 2,
            autoThresholdDb: nil,
            sourceApplicable: true,
            marks: [BKMark(start: 0, end: duration, kind: .keep)],
            splits: [],
            createdAt: Date(),
            updatedAt: Date(),
            exportHistory: []
        )
        project = p
        history.reset(p)
        BKDraftStore.shared.markOpened(p.id)
        BKDraftStore.shared.scheduleSave(p)
        updateUndoButtons()
        BKLog.shared.i(String(format: "新建工程 %.0f×%.0f %.1fs",
                              p.displayWidth, p.displayHeight, p.duration))
    }

    private func runDetection(override: Double?) {
        guard let env = envelope, let p = project else { return }
        statusLabel.text = "正在检测气口…"
        spinner.startAnimating()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = BKDetector.detect(envelope: env,
                                            totalDuration: p.duration,
                                            overrideThreshold: override)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.spinner.stopAnimating()
                var proj = p
                proj.thresholdDb = outcome.info.thresholdDb
                if override == nil {
                    proj.autoThresholdDb = outcome.info.rawThresholdDb
                }
                proj.sourceApplicable = outcome.info.applicable
                proj.marks = BKTimeline.build(duration: proj.duration, cuts: outcome.cuts)
                proj.updatedAt = Date()

                if outcome.info.applicable {
                    self.statusLabel.text = ""
                    BKLog.shared.i(String(format: "检测完成：候选 %d 刀 → 采纳 %d 刀 · 阈值 %.1f dB（原始 %.1f）",
                                          outcome.info.candidateCount,
                                          outcome.info.adoptedCount,
                                          outcome.info.thresholdDb,
                                          outcome.info.rawThresholdDb))
                } else {
                    self.statusLabel.text = outcome.info.reason ?? "素材不适用静音检测"
                    BKLog.shared.w("素材不适用：\(outcome.info.reason ?? "")")
                }

                // 程序设值不触发 valueChanged，不会造成重入
                self.thresholdSlider.value = Float(outcome.info.thresholdDb)
                self.thresholdTitle.text = String(format: "阈值 %.1f dB", outcome.info.thresholdDb)
                self.detectButton.isEnabled = outcome.info.applicable
                self.detectButton.alpha = outcome.info.applicable ? 1.0 : 0.35
                self.commit(proj)
            }
        }
    }

    /// 轨道 + 概览条一起刷新。分开刷迟早会出现「轨道已经切了，概览条还画着旧的」
    private func refreshTrack() {
        guard let p = project else { return }
        // 显示序列 = 删除区间 + 手动切口 一起算出来的片段。
        // 导出永远只认 keepRanges，切口不参与 —— 切一刀不会让成品少一帧
        let shown = BKTimeline.pieces(duration: p.duration,
                                      cuts: p.cutRanges,
                                      splits: p.splits)
        track.setContent(envelope: envelope,
                         pieces: shown,
                         splits: p.splits,
                         duration: p.duration,
                         thresholdDb: p.thresholdDb)
        overview.setContent(envelope: envelope,
                            pieces: shown,
                            duration: p.duration,
                            viewport: track.viewport)
    }

    private func updateInfo() {
        guard let p = project else { return }
        if p.cutCount == 0 {
            infoLabel.text = String(format: "原 %@ · 剪后 %@ · 还没有刀口",
                                    formatClock(p.duration), formatClock(p.outputDuration))
        } else {
            infoLabel.text = String(format: "原 %@ · 剪后 %@ · %d 刀 · 删 %.1fs（%.1f%%）",
                                    formatClock(p.duration), formatClock(p.outputDuration),
                                    p.cutCount, p.removedDuration, p.removedRatio * 100)
        }
    }

    // MARK: - 交互

    @objc private func playTapped() {
        guard let p = player else { return }
        if playing {
            p.pause()
            playing = false
            updatePlayButtonIcon()
        } else {
            // 从橙色指针所在的位置播起 —— 指针在正中不动，画面会持续向左滚过去
            p.seek(to: CMTime(seconds: lastTime, preferredTimescale: 600))
            p.play()
            playing = true
            updatePlayButtonIcon()
        }
    }

    /// ■ 停止：暂停 + 指针回到 0 秒。
    /// 和暂停的区别是它认「归零」—— 听一句口播要反复从头对，省一次拖拽
    @objc private func stopTapped() {
        player?.pause()
        playing = false
        updatePlayButtonIcon()
        player?.seek(to: CMTime(seconds: 0, preferredTimescale: 600))
        syncPlayhead(to: 0)
    }

    @objc private func detectTapped() {
        runDetection(override: nil)
    }

    @objc private func zoomSliderChanged() {
        track.setZoomScreens(CGFloat(zoomSlider.value))
        overview.setViewport(track.viewport)
    }

    /// ± 每次走 2 屏。1 屏一档太慢，从 6 屏拉到 20 屏要按 14 下
    @objc private func zoomInTapped() { zoomStep(by: 2) }

    @objc private func zoomOutTapped() { zoomStep(by: -2) }

    private func zoomStep(by delta: CGFloat) {
        track.setZoomScreens(track.zoomScreens + delta)
        zoomSlider.value = Float(track.zoomScreens)
        overview.setViewport(track.viewport)
    }

    @objc private func exportTapped() {
        guard let p = project, !isExporting else { return }
        isExporting = true
        setControlsEnabled(false)
        statusLabel.text = "正在导出…"
        spinner.startAnimating()
        let startedAt = Date()

        BKExporter.export(project: p, asset: asset) { [weak self] done, total, fraction in
            guard let self = self else { return }
            let pct = Int(fraction * 100)
            self.statusLabel.text = "正在导出… \(pct)%（第 \(done)/\(total) 段）"
        } completion: { [weak self] result in
            guard let self = self else { return }
            self.isExporting = false
            self.setControlsEnabled(true)
            self.spinner.stopAnimating()

            switch result {
            case .failure(let err):
                self.statusLabel.text = "导出失败：\(err.localizedDescription)"
                BKLog.shared.e("导出失败：\(err.localizedDescription)")
            case .success(let url):
                let elapsed = Date().timeIntervalSince(startedAt)
                self.saveToPhotos(url, elapsed: elapsed)
            }
        }
    }

    private func saveToPhotos(_ url: URL, elapsed: Double) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        func request(_ work: @escaping () -> Void) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
                DispatchQueue.main.async { work() }
            }
        }

        func performSave() {
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { [weak self] ok, err in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if ok {
                        // 记进导出历史：排障时「哪个文件、多大、耗时多久」全靠它
                        if var p = self.project {
                            let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
                            let size = (attr?[.size] as? Int64) ?? 0
                            let record = BKExportRecord(id: UUID(),
                                                        date: Date(),
                                                        fileSize: size,
                                                        duration: p.outputDuration,
                                                        fileName: url.lastPathComponent,
                                                        elapsedSec: elapsed)
                            p.exportHistory.append(record)
                            p.updatedAt = Date()
                            self.project = p
                            BKDraftStore.shared.scheduleSave(p)
                            BKLog.shared.i("成品已存相册 \(record.fileName) · \(record.sizeText) · \(String(format: "%.1f", elapsed))s")
                        }
                        self.statusLabel.text = ""
                        let alert = UIAlertController(
                            title: "已保存到相册",
                            message: "成品已存入系统相册，可以直接进剪映。",
                            preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "好", style: .cancel))
                        self.present(alert, animated: true)
                    } else {
                        let msg = err?.localizedDescription ?? "未知原因"
                        self.statusLabel.text = "存相册失败：\(msg)"
                        BKLog.shared.e("存相册失败：\(msg)")
                    }
                }
            }
        }

        switch status {
        case .authorized, .limited:
            performSave()
        case .notDetermined:
            request(performSave)
        default:
            statusLabel.text = "没有相册写入权限，去系统设置里开"
        }
    }

    /// 状态机统一入口：提波形 / 导出期间把整个工具栏灰掉，
    /// 免得在半成品状态上再叠一层编辑
    private func setControlsEnabled(_ enabled: Bool) {
        let buttons = [stopButton, playButton, invertButton, cutButton, detectButton,
                       undoButton, redoButton, zoomOutButton, zoomInButton]
        for b in buttons {
            b.isEnabled = enabled
            b.alpha = enabled ? 1.0 : 0.4
        }
        exportButton.isEnabled = enabled
        exportButton.alpha = enabled ? 1.0 : 0.4
        thresholdSlider.isEnabled = enabled
        zoomSlider.isEnabled = enabled
        // 撤销 / 重做还得再看一眼栈里有没有东西，不能一刀切全亮
        if enabled { updateUndoButtons() }
    }

    @objc private func thresholdChanged() {
        let v = Double(thresholdSlider.value)
        thresholdTitle.text = String(format: "阈值 %.1f dB", v)
        // 滑杆是连续动作，停下 0.4 秒才真正重算 —— 手感优先
        sliderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.runDetection(override: v)
        }
        sliderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - 工具

    /// mm:ss。时间码用这个：小数点后一位在剪辑场景里是噪音
    private func formatClock(_ t: Double) -> String {
        let s = max(0, t)
        let m = Int(s) / 60
        let sec = Int(s) % 60
        return String(format: "%02d:%02d", m, sec)
    }
}

// MARK: - 素材列表数据源

/// 带副标题的 cell。系统默认样式没有 detailTextLabel，
/// register(UITableViewCell.self) 拿到的那种，副标题会静默消失
private final class BKVideoNameCell: UITableViewCell {
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

extension BKEditorViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        videoIDs.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BKVideoNameCell", for: indexPath)
        let id = videoIDs[indexPath.row]
        let isCurrent = (id == localID)

        cell.backgroundColor = .clear
        cell.textLabel?.text = BKVideoLibrary.assetName(localID: id)
        cell.textLabel?.textColor = isCurrent ? BKTheme.Color.gold : BKTheme.Color.text
        cell.detailTextLabel?.text = BKVideoLibrary.formatDuration(BKVideoLibrary.duration(localID: id))
        cell.detailTextLabel?.textColor = BKTheme.Color.text2
        cell.accessoryType = isCurrent ? .checkmark : .none
        cell.tintColor = BKTheme.Color.gold
        cell.selectionStyle = .default
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let id = videoIDs[indexPath.row]
        guard id != localID else {
            // 点的是当前这条 —— 收起列表就好，不用重新加载
            toggleListTapped()
            return
        }
        openSibling(localID: id)
    }
}

// MARK: - 主轨道回调

extension BKEditorViewController: BKTrackViewDelegate {

    func track(_ view: BKTrackView, didScrollTo time: Double) {
        guard let p = project else { return }
        let t = min(max(time, 0), p.duration)
        // 手动一滚就先停播放。否则「用户拖 contentOffset」和
        // 「播放回调推 contentOffset」两边同时发力，画面会来回抽
        if playing {
            player?.pause()
            playing = false
            updatePlayButtonIcon()
        }
        // 预览画面跟指针跳帧：指针是滚动位置换算出来的，这里直接 seek 即可
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        lastTime = t
        timeLabel.text = "\(formatClock(t)) / \(formatClock(p.duration))"
        overview.setViewport(track.viewport)
    }

    func track(_ view: BKTrackView, didTogglePieceAt time: Double) {
        togglePiece(at: time)
    }

    func track(_ view: BKTrackView, didBeginBoundaryDragNear time: Double) {
        boundaryDragging = true
        boundaryCommitted = false
    }

    func track(_ view: BKTrackView, didDragBoundaryNear near: Double, to newTime: Double) {
        guard let p = project else { return }
        // 拖到非法位置（越过邻居）时返回 nil，界面保持原样
        if let next = BKTimeline.moveBoundary(in: p.marks, near: near, to: newTime) {
            applyMarks(next, coalesce: true)
        }
    }

    func trackDidEndBoundaryDrag(_ view: BKTrackView) {
        boundaryDragging = false
        boundaryCommitted = false
    }

    func track(_ view: BKTrackView, didChangeZoomTo screens: CGFloat) {
        zoomSlider.value = Float(screens)
        overview.setViewport(track.viewport)
    }
}

// MARK: - 概览条回调

extension BKEditorViewController: BKOverviewBarDelegate {

    /// 点 / 拖概览条 = 直接跳到那个位置。
    /// 放大之后想从 5 秒跳到 38 秒，靠拖主轨道得划好几下
    func overview(_ bar: BKOverviewBar, didSeekTo time: Double) {
        guard let p = project else { return }
        let t = min(max(time, 0), p.duration)
        if playing {
            player?.pause()
            playing = false
            updatePlayButtonIcon()
        }
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        syncPlayhead(to: t)
    }
}
