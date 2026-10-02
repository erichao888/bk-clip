//
//  BKEditorViewController.swift
//  bk剪辑 — 编辑页
//
//  【本批范围】波形可视化 + 自动检测 + 手动微调 + 播放校对。
//  导出在下一批接 —— 先把「刀口找得准不准」在真机上验证透，
//  再去碰 AVAssetWriter 那一块高风险代码。
//
//  【数据流】
//  asset → BKAudioAnalyzer 提取包络 → BKDetector 出切点
//        → BKTimeline.build 合成 marks → 波形上画出来
//  手动拖边界 / 点掉某刀 → 改 marks → 波形重画 + 草稿落盘
//  阈值滑杆 → 重跑检测。注意：重跑会覆盖手动调整 —— 这是刻意的简单模型，
//  「在检测结果基础上继续精修」的混合模式等真实使用反馈来了再说。
//
//  【播放语义】AVPlayer 走原始时间轴：播放头扫过红色区间时
//  你听到的是「将被删掉的声音」，这正是调刀口时最需要听的东西。
//  「跳过刀口的连贯试听」需要离线拼接，留给导出批次。
//

import UIKit
import AVFoundation
import Photos

final class BKEditorViewController: UIViewController {

    // MARK: - 状态

    private let asset: AVAsset
    private let localID: String
    private let probeInfo: BKAssetProbe.Info
    /// 恢复编辑时带入已有工程；新素材为 nil
    private var project: BKProject?
    private var envelope: BKEnvelope?
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var timeObserver: Any?

    private var sliderWork: DispatchWorkItem?
    private var playing = false
    private var lastTime: Double = 0
    private var isExporting = false
    /// true = 试听成品模式：播放到刀口直接跳过去，等于听一遍剪完的样子。
    /// 关掉时是正常播放（含刀口）—— 调刀口时恰恰要听「被删掉的是什么」
    private var previewMode = false

    // MARK: - 界面

    private let previewContainer = UIView()
    private let timeLabel = UILabel()
    private let waveContainer = UIView()
    private let waveform = BKWaveformView()
    private let playheadLine = UIView()
    private let thresholdTitle = UILabel()
    private let thresholdSlider = UISlider()
    private let infoLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let playButton = UIButton(type: .system)
    private let previewButton = UIButton(type: .system)
    private let cutButton = UIButton(type: .system)
    private let detectButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)

    private let navPrevButton = UIButton(type: .system)
    private let navNextButton = UIButton(type: .system)
    private let navPositionLabel = UILabel()

    // 素材列表面板：默认隐藏，点导航栏 ☰ 打开
    private let listPanel = UIView()
    private let listTable = UITableView(frame: .zero, style: .plain)
    private var listVisible = false

    private var playheadLeading: NSLayoutConstraint!

    // MARK: - 初始化

    /// 素材库顺序。有它才能「上一条 / 下一条」；只从起始页单挑一条进来时是空的
    private let videoIDs: [String]

    /// 手动切割的起点。nil = 还没按下第一次
    private var manualCutStart: Double?

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
        title = "编辑"
        view.backgroundColor = BKTheme.Color.bg
        setupPlayer()
        setupUI()
        startAnalysis()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        // 边缘右滑返回和「拖分割线 / 扫播放头」是死敌：
        // 手指从屏幕左缘起手往右拖，系统会当成返回手势，整个编辑页跟着滑走
        // （真机实测：拖到一半页面退回了起始页）。剪辑页一律用左上角按钮返回
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 回起始页前把手势还回去，虽然起始页没有东西可 pop，保持干净
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        player?.pause()
        playing = false
        playButton.setTitle("播放", for: .normal)
        BKDraftStore.shared.flushIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer?.frame = previewContainer.bounds
        syncPlayhead(to: lastTime)
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

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.handlePlaybackTime(to: CMTimeGetSeconds(time))
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

    /// 播放时的时间回调。试听模式下一旦发现播放头进到刀口里，
    /// 就直接把它挪到这一刀的末尾 —— 听感上等于这一刀从来没存在过
    private func handlePlaybackTime(to t: Double) {
        guard previewMode, playing, let p = project else {
            syncPlayhead(to: t)
            return
        }
        for (s, e) in p.cutRanges where t >= s && t < e {
            player?.seek(to: CMTime(seconds: e, preferredTimescale: 600))
            syncPlayhead(to: e)
            return
        }
        syncPlayhead(to: t)
    }

    @objc private func playerFinished() {
        playing = false
        playButton.setTitle("播放", for: .normal)
        player?.seek(to: CMTime(seconds: 0, preferredTimescale: 600))
        syncPlayhead(to: 0)
    }

    private func syncPlayhead(to t: Double) {
        guard let p = project else { return }
        let clamped = min(max(t, 0), p.duration)
        lastTime = clamped
        timeLabel.text = "\(formatTime(clamped)) / \(formatTime(p.duration))"
        let w = waveContainer.bounds.width - 4
        playheadLeading.constant = CGFloat(clamped / max(p.duration, 1e-9)) * w + 1
    }

    // MARK: - 布局

    private func setupUI() {
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

        timeLabel.font = BKTheme.Font.mono
        timeLabel.textColor = BKTheme.Color.text2
        timeLabel.text = "00:00.0 / 00:00.0"

        waveContainer.backgroundColor = BKTheme.Color.page
        waveContainer.layer.cornerRadius = BKTheme.Radius.card
        waveContainer.clipsToBounds = true

        waveform.backgroundColor = .clear
        waveform.delegate = self
        waveform.translatesAutoresizingMaskIntoConstraints = false
        waveContainer.addSubview(waveform)

        playheadLine.backgroundColor = BKTheme.Color.playhead
        playheadLine.layer.cornerRadius = 1
        playheadLine.translatesAutoresizingMaskIntoConstraints = false
        waveContainer.addSubview(playheadLine)

        NSLayoutConstraint.activate([
            waveform.leadingAnchor.constraint(equalTo: waveContainer.leadingAnchor),
            waveform.trailingAnchor.constraint(equalTo: waveContainer.trailingAnchor),
            waveform.topAnchor.constraint(equalTo: waveContainer.topAnchor),
            waveform.bottomAnchor.constraint(equalTo: waveContainer.bottomAnchor),

            playheadLine.topAnchor.constraint(equalTo: waveContainer.topAnchor),
            playheadLine.bottomAnchor.constraint(equalTo: waveContainer.bottomAnchor),
            playheadLine.widthAnchor.constraint(equalToConstant: 2)
        ])
        playheadLeading = playheadLine.leadingAnchor.constraint(equalTo: waveContainer.leadingAnchor, constant: 1)
        playheadLeading.isActive = true

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
        thresholdSlider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)

        infoLabel.font = BKTheme.Font.mono
        infoLabel.textColor = BKTheme.Color.text
        infoLabel.numberOfLines = 0
        infoLabel.text = "正在准备…"

        statusLabel.font = BKTheme.Font.caption
        statusLabel.textColor = BKTheme.Color.warning
        statusLabel.numberOfLines = 0

        spinner.hidesWhenStopped = true
        spinner.color = BKTheme.Color.gold

        previewButton.setTitle("成品试听", for: .normal)
        previewButton.setTitleColor(BKTheme.Color.accent, for: .normal)
        previewButton.titleLabel?.font = BKTheme.Font.caption
        previewButton.layer.borderWidth = 1
        previewButton.layer.borderColor = BKTheme.Color.line.cgColor
        previewButton.layer.cornerRadius = 10
        previewButton.addTarget(self, action: #selector(previewTapped), for: .touchUpInside)

        cutButton.setTitle("切割", for: .normal)
        cutButton.setTitleColor(BKTheme.Color.danger, for: .normal)
        cutButton.titleLabel?.font = BKTheme.Font.caption
        cutButton.layer.borderWidth = 1
        cutButton.layer.borderColor = BKTheme.Color.danger.cgColor
        cutButton.layer.cornerRadius = 10
        cutButton.addTarget(self, action: #selector(cutTapped), for: .touchUpInside)

        detectButton.setTitle("自动检测", for: .normal)
        detectButton.setTitleColor(BKTheme.Color.accent, for: .normal)
        detectButton.titleLabel?.font = BKTheme.Font.caption
        detectButton.addTarget(self, action: #selector(detectTapped), for: .touchUpInside)

        playButton.setTitle("播放", for: .normal)
        playButton.setTitleColor(.white, for: .normal)
        playButton.titleLabel?.font = BKTheme.Font.caption
        playButton.backgroundColor = BKTheme.Color.gold
        playButton.layer.cornerRadius = 10
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)

        exportButton.setTitle("导出", for: .normal)
        exportButton.setTitleColor(BKTheme.Color.accent, for: .normal)
        exportButton.titleLabel?.font = BKTheme.Font.caption
        exportButton.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)

        let thresholdRow = UIStackView(arrangedSubviews: [thresholdTitle, thresholdSlider])
        thresholdRow.axis = .horizontal
        thresholdRow.spacing = BKTheme.Space.md
        thresholdRow.alignment = .center

        let statusRow = UIStackView(arrangedSubviews: [statusLabel, spinner])
        statusRow.axis = .horizontal
        statusRow.spacing = BKTheme.Space.sm
        statusRow.alignment = .center

        // ☰ 素材列表：放在导航栏右侧，和编辑按钮彻底分开，
        // 免得调刀口的时候误触把素材换掉
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "☰",
            style: .plain,
            target: self,
            action: #selector(toggleListTapped))
        navigationItem.rightBarButtonItem?.isEnabled = videoIDs.count > 1

        setupListPanel()

        // 上一条 / 下一条：和编辑按钮分开放，避免误触跳素材
        navPrevButton.setTitle("‹ 上一条", for: .normal)
        navPrevButton.titleLabel?.font = BKTheme.Font.caption
        navPrevButton.setTitleColor(BKTheme.Color.accent, for: .normal)
        navPrevButton.addTarget(self, action: #selector(prevVideoTapped), for: .touchUpInside)

        navNextButton.setTitle("下一条 ›", for: .normal)
        navNextButton.titleLabel?.font = BKTheme.Font.caption
        navNextButton.setTitleColor(BKTheme.Color.accent, for: .normal)
        navNextButton.addTarget(self, action: #selector(nextVideoTapped), for: .touchUpInside)

        navPositionLabel.font = BKTheme.Font.monoSmall
        navPositionLabel.textColor = BKTheme.Color.text2
        navPositionLabel.textAlignment = .center
        navPositionLabel.text = ""

        let navRow = UIStackView(arrangedSubviews: [navPrevButton, navPositionLabel, navNextButton])
        navRow.axis = .horizontal
        navRow.spacing = BKTheme.Space.sm
        navRow.alignment = .center
        navRow.distribution = .fillEqually
        navRow.isHidden = videoIDs.count < 2
        updateNavButtons()

        // 主操作一行四个：播放 / 试听 / 切割 / 导出
        let buttonRow = UIStackView(arrangedSubviews: [playButton, previewButton, cutButton, exportButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = BKTheme.Space.sm
        buttonRow.alignment = .fill
        buttonRow.distribution = .fillEqually

        // 自动检测单独一行：它不属于高频操作，塞进主操作行只会让按钮变窄
        let secondRow = UIStackView(arrangedSubviews: [detectButton])
        secondRow.axis = .horizontal
        secondRow.alignment = .fill

        let stack = UIStackView(arrangedSubviews: [
            navRow, listPanel, previewContainer, timeLabel, waveContainer, thresholdRow,
            infoLabel, statusRow, buttonRow, secondRow
        ])
        stack.axis = .vertical
        stack.spacing = BKTheme.Space.md
        stack.alignment = .fill
        stack.setCustomSpacing(BKTheme.Space.sm, after: previewContainer)
        stack.setCustomSpacing(BKTheme.Space.xs, after: timeLabel)
        stack.setCustomSpacing(BKTheme.Space.lg, after: infoLabel)

        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: BKTheme.Space.lg),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -BKTheme.Space.lg),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: BKTheme.Space.md),

            previewContainer.heightAnchor.constraint(equalToConstant: 250),
            waveContainer.heightAnchor.constraint(equalToConstant: 150),
            playButton.heightAnchor.constraint(equalToConstant: BKTheme.Space.minTap)
        ])
    }

    // MARK: - 素材列表面板

    /// 面板高度 = 5 行。多于 5 条就在这 5 行的窗口里上下滚动，
    /// 不撑开页面 —— 撑开的话波形和按钮会被挤出屏幕，比藏起来还难用
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

    private func updateNavButtons() {
        guard let i = currentIndex else {
            navPositionLabel.text = ""
            navPrevButton.isEnabled = false
            navNextButton.isEnabled = false
            return
        }
        navPositionLabel.text = "第 \(i + 1)/\(videoIDs.count) 条"
        navPrevButton.isEnabled = i > 0
        navNextButton.isEnabled = i < videoIDs.count - 1
        navPrevButton.alpha = navPrevButton.isEnabled ? 1.0 : 0.35
        navNextButton.alpha = navNextButton.isEnabled ? 1.0 : 0.35
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

    // MARK: - 手动切割

    /// 两步式：第一次点记起点，第二次点记终点，把这一段标为删除。
    /// 为什么不「点一下就切掉当前整段」：整段往往几秒长，一切就把大段说话也删了。
    /// 让用户自己划范围，代价只是多一点一次点按
    @objc private func cutTapped() {
        guard let p = project else { return }

        if let start = manualCutStart {
            let a = min(start, lastTime)
            let b = max(start, lastTime)
            manualCutStart = nil
            cutButton.setTitle("切割", for: .normal)
            cutButton.backgroundColor = .clear

            guard (b - a) >= BKConfig.Detect.minCut else {
                statusLabel.text = String(format: "这段只有 %.2fs，短于最短一刀 %.2fs，不切",
                                          b - a, BKConfig.Detect.minCut)
                return
            }

            // 手动刀和自动刀走同一条重建路径，保证「相邻严丝合缝」这个不变量不被破坏
            var cuts = p.cutRanges
            cuts.append((a, b))
            applyMarks(BKTimeline.build(duration: p.duration, cuts: cuts))
            statusLabel.text = ""
            BKLog.shared.i(String(format: "手动切掉 %.2f~%.2fs（%.2fs）", a, b, b - a))
        } else {
            manualCutStart = lastTime
            cutButton.setTitle("确认终点", for: .normal)
            cutButton.backgroundColor = BKTheme.Color.danger.withAlphaComponent(0.15)
            statusLabel.text = String(format: "起点 %.1fs —— 播放或拖到终点，再点一次完成切割", lastTime)
        }
    }

    // MARK: - 分析与检测

    private func startAnalysis() {
        spinner.startAnimating()
        statusLabel.text = "正在提取音频波形…"
        BKAudioAnalyzer.extractEnvelope(from: asset) { [weak self] result in
            guard let self = self else { return }
            self.spinner.stopAnimating()
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
                    }
                    self.refreshWaveform()
                    self.updateInfo()
                    self.statusLabel.text = "已恢复上次的编辑进度"
                }
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
            createdAt: Date(),
            updatedAt: Date(),
            exportHistory: []
        )
        project = p
        BKDraftStore.shared.markOpened(p.id)
        BKDraftStore.shared.scheduleSave(p)
        BKLog.shared.i(String(format: "新建工程 %.0f×%.0f %.1fs",
                              p.displayWidth, p.displayHeight, p.duration))
    }

    private func runDetection(override: Double?) {
        guard let env = envelope, let p = project else { return }
        statusLabel.text = "正在检测气口…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = BKDetector.detect(envelope: env,
                                            totalDuration: p.duration,
                                            overrideThreshold: override)
            DispatchQueue.main.async {
                guard let self = self else { return }
                var proj = p
                proj.thresholdDb = outcome.info.thresholdDb
                if override == nil {
                    proj.autoThresholdDb = outcome.info.rawThresholdDb
                }
                proj.sourceApplicable = outcome.info.applicable
                proj.marks = BKTimeline.build(duration: proj.duration, cuts: outcome.cuts)
                proj.updatedAt = Date()
                self.project = proj

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
                self.refreshWaveform()
                self.updateInfo()
                BKDraftStore.shared.scheduleSave(proj)
            }
        }
    }

    // MARK: - 编辑操作

    private func applyMarks(_ marks: [BKMark]) {
        guard var p = project else { return }
        p.marks = BKTimeline.normalize(marks, duration: p.duration)
        p.updatedAt = Date()
        project = p
        refreshWaveform()
        updateInfo()
        BKDraftStore.shared.scheduleSave(p)
    }

    private func refreshWaveform() {
        guard let p = project else { return }
        waveform.setContent(envelope: envelope,
                            marks: p.marks,
                            duration: p.duration,
                            thresholdDb: p.thresholdDb)
    }

    private func updateInfo() {
        guard let p = project else { return }
        if p.cutCount == 0 {
            infoLabel.text = "还没有刀口 —— 拖红色把手微调，或调阈值重测"
        } else {
            infoLabel.text = String(format: "%d 刀 · 删 %.1fs → 剩 %.1fs（%.1f%%）",
                                    p.cutCount, p.removedDuration, p.outputDuration,
                                    p.removedRatio * 100)
        }
    }

    // MARK: - 交互

    @objc private func playTapped() {
        guard let p = player else { return }
        if playing {
            p.pause()
            playing = false
            playButton.setTitle("播放", for: .normal)
        } else {
            p.play()
            playing = true
            playButton.setTitle("暂停", for: .normal)
        }
    }

    @objc private func previewTapped() {
        previewMode.toggle()
        previewButton.setTitle(previewMode ? "试听中" : "成品试听", for: .normal)
        if previewMode {
            previewButton.backgroundColor = BKTheme.Color.accent
            previewButton.setTitleColor(.white, for: .normal)
            statusLabel.text = "试听模式：播放会自动跳过所有刀口（导出前先听一遍）"
        } else {
            previewButton.backgroundColor = .clear
            previewButton.setTitleColor(BKTheme.Color.accent, for: .normal)
            statusLabel.text = ""
        }
        BKLog.shared.i("试听模式 \(previewMode ? "开" : "关")")
    }

    @objc private func detectTapped() {
        runDetection(override: nil)
    }

    @objc private func exportTapped() {
        guard let p = project, !isExporting else { return }
        isExporting = true
        setButtonsEnabled(false)
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
            self.setButtonsEnabled(true)
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

    private func setButtonsEnabled(_ enabled: Bool) {
        playButton.isEnabled = enabled
        detectButton.isEnabled = enabled
        previewButton.isEnabled = enabled
        cutButton.isEnabled = enabled
        exportButton.isEnabled = enabled
        thresholdSlider.isEnabled = enabled
        playButton.alpha = enabled ? 1.0 : 0.5
        detectButton.alpha = enabled ? 1.0 : 0.5
        previewButton.alpha = enabled ? 1.0 : 0.5
        cutButton.alpha = enabled ? 1.0 : 0.5
        exportButton.alpha = enabled ? 1.0 : 0.5
    }

    @objc private func sliderChanged() {
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

    private func formatTime(_ t: Double) -> String {
        let s = max(0, t)
        let m = Int(s) / 60
        let sec = s - Double(m * 60)
        return String(format: "%02d:%04.1f", m, sec)
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

// MARK: - 波形手势回调

extension BKEditorViewController: BKWaveformViewDelegate {

    func waveform(_ view: BKWaveformView, didDragBoundaryAfterIndex index: Int, to time: Double) {
        guard let p = project else { return }
        // 拖到非法位置（越过邻居）时 moveBoundary 返回 nil，界面保持原样
        if let next = BKTimeline.moveBoundary(in: p.marks, afterIndex: index, to: time) {
            applyMarks(next)
        }
    }

    func waveform(_ view: BKWaveformView, didToggleCutAt time: Double) {
        guard let p = project else { return }
        // 只允许点掉已有的刀（红→绿），不支持点一下就加一刀 —— 误触的代价太高
        for (i, m) in p.marks.enumerated() where m.kind == .cut && time >= m.start && time <= m.end {
            applyMarks(BKTimeline.toggle(marks: p.marks, at: i))
            BKLog.shared.i(String(format: "点掉刀口 %.2f~%.2fs", m.start, m.end))
            return
        }
    }

    func waveform(_ view: BKWaveformView, didScrubTo time: Double) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        syncPlayhead(to: time)
    }
}
