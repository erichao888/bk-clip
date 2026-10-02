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
    private let detectButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)

    private var playheadLeading: NSLayoutConstraint!

    // MARK: - 初始化

    init(asset: AVAsset, localID: String, probeInfo: BKAssetProbe.Info, project: BKProject?) {
        self.asset = asset
        self.localID = localID
        self.probeInfo = probeInfo
        self.project = project
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
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
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
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        player = p

        let layer = AVPlayerLayer()
        layer.player = p
        // aspect 保证竖版素材在固定高度里完整显示，不裁切不变形
        layer.videoGravity = .resizeAspect
        playerLayer = layer
        previewContainer.layer.addSublayer(layer)

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.syncPlayhead(to: CMTimeGetSeconds(time))
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(playerFinished),
                                               name: .AVPlayerItemDidPlayToEndTime,
                                               object: item)
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

        detectButton.setTitle("自动检测", for: .normal)
        detectButton.setTitleColor(BKTheme.Color.accent, for: .normal)
        detectButton.titleLabel?.font = BKTheme.Font.button
        detectButton.addTarget(self, action: #selector(detectTapped), for: .touchUpInside)

        playButton.setTitle("播放", for: .normal)
        playButton.setTitleColor(.white, for: .normal)
        playButton.titleLabel?.font = BKTheme.Font.button
        playButton.backgroundColor = BKTheme.Color.gold
        playButton.layer.cornerRadius = 10
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)

        exportButton.setTitle("导出", for: .normal)
        exportButton.setTitleColor(BKTheme.Color.accent, for: .normal)
        exportButton.titleLabel?.font = BKTheme.Font.button
        exportButton.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)

        let thresholdRow = UIStackView(arrangedSubviews: [thresholdTitle, thresholdSlider])
        thresholdRow.axis = .horizontal
        thresholdRow.spacing = BKTheme.Space.md
        thresholdRow.alignment = .center

        let statusRow = UIStackView(arrangedSubviews: [statusLabel, spinner])
        statusRow.axis = .horizontal
        statusRow.spacing = BKTheme.Space.sm
        statusRow.alignment = .center

        let buttonRow = UIStackView(arrangedSubviews: [detectButton, playButton, exportButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = BKTheme.Space.md
        buttonRow.alignment = .fill
        buttonRow.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [
            previewContainer, timeLabel, waveContainer, thresholdRow,
            infoLabel, statusRow, buttonRow
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

    @objc private func detectTapped() {
        runDetection(override: nil)
    }

    @objc private func exportTapped() {
        let alert = UIAlertController(
            title: "导出在下一批",
            message: "先把刀口调对：红色区间就是会删掉的部分。播放校对一遍，确认没有误删，导出功能马上到。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .cancel))
        present(alert, animated: true)
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
