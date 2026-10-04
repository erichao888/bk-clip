//
//  BKEditorViewController.swift
//  bk剪辑 — 编辑页
//
//  【这份代码的上级是 docs/界面定稿.md，不是聊天记录】
//  改任何一处界面之前，先改定稿再改这里。前面十几轮最大的教训是
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
//  【一个草稿 = 一整批，这一页只编辑批里的其中一条】
//  batch 是整批，itemIndex 指出正在编辑第几条。切换素材 = 换 itemIndex（换 VC 实例），
//  批里其余素材的刀口原封不动地留在 batch 里。
//
//  【两个播放键】
//  ▶ 原片播（红区绿区都播） ｜ `|▶|` 联播（按 keepRanges 拼起来播，跳过红区）
//  两者起点都是橙指针那一帧，互斥：按当前那个 = 停，按另一个 = 切换过去。
//  停止一律**停在原地**（定稿 4.5.2）。
//
//  【指针居中带来的一个连锁变化】
//  指针不动、内容滚，所以「预览画面跟指针跳帧」变成了：
//  滚动回调 → seek 播放器。预览画面本身不需要任何动效代码。
//

import UIKit
import AVFoundation
import Photos

final class BKEditorViewController: UIViewController {

    // MARK: - 播放模式

    private enum PlayMode {
        case idle
        /// ▶ 原片播
        case straight
        /// `|▶|` 联播（拼起来的成品）
        case joint
    }

    // MARK: - 状态

    private let asset: AVAsset
    private let probeInfo: BKAssetProbe.Info
    private var batch: BKDraftBatch
    private var itemIndex: Int
    private var envelope: BKEnvelope?

    /// 撤销栈。所有编辑改动都从它进出，绝不允许有第二处直接改 batch.items[i].marks
    private var history = BKHistory()
    /// 是否正在拖边界。拖动过程中的连续改动只占撤销栈一格
    private var boundaryDragging = false
    /// 这一次拖动是否已经入过栈。false 时下一次提交走 push，之后走 amend
    private var boundaryCommitted = false
    /// v1.3.0 是否处于区域编辑态（长按进的那一段在编辑）
    private var regionEditing = false

    // MARK: - 播放器

    /// 原片播放器。**常驻**，换素材只换 AVPlayerItem，绝不重建 AVPlayer ——
    /// 重建一次几十到几百毫秒就没了，那是起播延迟的大头
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var timeObserver: Any?

    /// 联播播放器。同样常驻，每次联播只换 item
    private var jointPlayer: AVPlayer?
    private var jointObserver: Any?
    private var joint: BKJointBuilder.Joint?

    private var playMode: PlayMode = .idle
    private var prerollWork: DispatchWorkItem?
    private var sliderWork: DispatchWorkItem?

    private var lastTime: Double = 0
    private var isExporting = false
    /// 整批被 ✕ 删空后短路 finishSession，避免把一个空草稿又存回磁盘
    private var didDiscard = false
    /// 换素材的加载锁。**一次只准换一条** —— 不锁的话手指使劲一划能连跳三四条，
    /// 每条都要重新提一次波形，直接卡死（定稿 4.5.3 三个坑里的第一个）
    private var isSwitchingAsset = false

    // MARK: - 界面

    private let listPanel = UIView()
    private let listTable = UITableView(frame: .zero, style: .plain)
    private var listVisible = false

    private let previewContainer = UIView()
    private let overview = BKOverviewBar()
    private let trackContainer = UIView()
    private let track = BKTrackView()

    // 工具栏第一排：撤销 / 重做 / 联播 / 播放 / 删红 / 切割 / 检测
    // ⚠️ v1.3.0：「反选 ⟳」的位置换成了「删红 ✗✗」（皓哥 2026-10-04 定）。
    // 反选 ⟳ 并不是被删掉了 —— 它的能力并进了「点段 toggle 绿↔红」（界面定稿第 5 节第 692 行），
    // 手指直接点那一段就行，不需要一个专门的键。
    private let undoButton = UIButton(type: .system)
    private let redoButton = UIButton(type: .system)
    private let jointButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let deleteRedButton = UIButton(type: .system)
    private let cutButton = UIButton(type: .system)
    private let detectButton = UIButton(type: .system)

    // 工具栏第二排：− +（28pt 小圆，靠右）
    // 工具栏第二排：✕（移除当前条，红色圆）在 − + 左边（定稿 4.4 扩展）
    private let removeButton = UIButton(type: .system)
    private let zoomOutButton = UIButton(type: .system)
    private let zoomInButton = UIButton(type: .system)

    private let exportButton = UIButton(type: .system)
    private let thresholdTitle = UILabel()
    private let thresholdSlider = UISlider()
    private let thresholdAutoButton = UIButton(type: .system)
    private let timeLabel = UILabel()
    private let infoLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    // MARK: - 初始化

    init(batch: BKDraftBatch, index: Int, asset: AVAsset, probeInfo: BKAssetProbe.Info) {
        self.batch = batch
        self.itemIndex = index
        self.asset = asset
        self.probeInfo = probeInfo
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("本 App 不走 storyboard")
    }

    deinit {
        if let o = timeObserver { player?.removeTimeObserver(o) }
        if let o = jointObserver { jointPlayer?.removeTimeObserver(o) }
    }

    /// 当前正在编辑的素材项
    private var item: BKProject { batch.items[itemIndex] }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BKTheme.Color.page
        prepareItem()
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
        stopPlayback()

        // ⚠️ 只有**真的返回起始页**才做结算。切换素材是用 setViewControllers 换栈顶，
        // 那也会走到 viewWillDisappear，但 isMovingFromParent 是 false ——
        // 不加这个判断，换素材的瞬间会把整批草稿当成「退出了」给丢掉
        if isMovingFromParent {
            finishSession()
        } else {
            savePlayhead()
            BKDraftStore.shared.flushIfNeeded()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer?.frame = previewContainer.bounds
    }

    /// 第一次拿到探针结果时，把素材的显示尺寸 / 时长补进素材项。
    /// 老草稿和新建的批里这些字段可能是 0，导出和封面都要用
    private func prepareItem() {
        if probeInfo.duration > 0 { batch.items[itemIndex].duration = probeInfo.duration }
        batch.items[itemIndex].displayWidth = probeInfo.displayWidth
        batch.items[itemIndex].displayHeight = probeInfo.displayHeight
        batch.items[itemIndex].sourceRotationDegrees = probeInfo.rotationDegrees
        if batch.items[itemIndex].assetName.isEmpty {
            batch.items[itemIndex].assetName = BKVideoLibrary.assetName(localID: item.assetLocalID)
        }
        batch.items[itemIndex].marks =
            BKTimeline.normalize(item.marks, duration: batch.items[itemIndex].duration)
        lastTime = min(max(item.playheadTime, 0), batch.items[itemIndex].duration)
    }

    /// 返回起始页时的结算：存草稿 + 生成封面 + 「整批没动过刀就丢掉」
    private func finishSession() {
        guard !didDiscard else { return }
        savePlayhead()
        batch.lastEditedAt = Date()

        // 定稿 3.1：整批从头到尾一刀没切 → 不留。
        // 判据是 everEdited（**曾经**动过刀），只置不清 ——
        // 切过刀后来又把刀删干净的，照样留着
        if !batch.everEdited {
            // 先撤掉待写的那一次，否则它两秒后照写，把刚删的文件又变回来
            BKDraftStore.shared.cancelPending()
            BKDraftStore.shared.permanentlyDelete(batch)
            BKLog.shared.i("整批未编辑，草稿已丢弃 \(batch.id.uuidString.prefix(8))")
            return
        }
        BKDraftStore.shared.scheduleSave(batch)
        BKDraftStore.shared.flushIfNeeded()

        // 封面 = 最后编辑那条素材、上次停住的那一帧（定稿 3.1）
        let bid = batch.id
        let aid = item.assetLocalID
        let t = lastTime
        BKCovers.generate(asset: asset, at: t) { img in
            guard let img = img else { return }
            BKCovers.save(img, batchId: bid, assetId: aid)
        }
    }

    private func savePlayhead() {
        batch.items[itemIndex].playheadTime = lastTime
        batch.lastAssetId = item.assetLocalID
    }

    // MARK: - 导航栏

    private func setupNav() {
        navigationItem.title = item.assetName

        // 左上角返回（关闭）：剪辑页禁用了系统边缘右滑返回（避免和拖轨道冲突），
        // 必须给一个显式入口，否则用户卡在编辑页回不去起始草稿页
        let backItem = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"),
                                       style: .plain,
                                       target: self,
                                       action: #selector(closeTapped))
        backItem.accessibilityLabel = "返回草稿列表"

        let listItem = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal"),
                                       style: .plain,
                                       target: self,
                                       action: #selector(toggleListTapped))
        // 定稿 4.2：素材 ≤1 条时 ☰ 置灰
        listItem.isEnabled = batch.items.count > 1
        navigationItem.leftBarButtonItems = [backItem, listItem]

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

        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        p.volume = 1.0
        p.isMuted = false
        // 默认是 true，系统会为了不卡顿而**故意多缓冲一会儿才起播** ——
        // 这就是「按下 ▶ 到出画面」延迟的大头
        p.automaticallyWaitsToMinimizeStalling = false
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
            guard let self = self, self.playMode == .straight else { return }
            self.syncPlayhead(to: CMTimeGetSeconds(time))
        }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(playerFinished),
                                               name: .AVPlayerItemDidPlayToEndTime,
                                               object: p.currentItem)

        // 联播播放器常驻：每次联播只换 item，不重建 player
        let jp = AVPlayer()
        jp.automaticallyWaitsToMinimizeStalling = false
        jointPlayer = jp
        jointObserver = jp.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, self.playMode == .joint, let j = self.joint else { return }
            let out = CMTimeGetSeconds(time)
            if out >= j.total - 0.02 {
                self.stopPlayback()
                return
            }
            // 成品时间 → 反查落在哪个 keep 段 → 加该段原片起点 → 原片时间。
            // 视觉上指针一路往前走，遇红区「跨」过去一小段，画面连贯又跟轨道不脱节
            self.syncPlayhead(to: j.sourceTime(at: out))
        }
    }

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

    /// 没有 Xcode 时，排障全靠这一行
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
        stopPlayback()
    }

    /// 播放回调 / 手动 seek 之后统一走这里：
    /// 时间码、指针、概览条视窗框三处必须同时跟上，漏一处就会看到「画面和框对不上」
    private func syncPlayhead(to t: Double) {
        let d = item.duration
        let clamped = min(max(t, 0), d)
        lastTime = clamped
        timeLabel.text = "\(formatClock(clamped)) / \(formatClock(d))"
        track.setPointerTime(clamped)
        overview.setViewport(track.viewport)
    }

    // MARK: - 布局

    private func setupUI() {
        // ---- 预览画面：固定高度框，横竖屏都 letterbox 进这个区域（定稿 4.3 修订）----
        let previewH = BKConfig.Layout.previewFixedH
        let trackH = BKConfig.Layout.trackFixedH

        previewContainer.backgroundColor = BKTheme.Color.preview
        previewContainer.layer.cornerRadius = BKTheme.Radius.card
        previewContainer.clipsToBounds = true

        // 画面上左右滑 = 换上一条 / 下一条。**必须加 40pt 门槛**：
        // 画面区又大又居中，剪辑到片头想停在那的时候手一蹭就可能翻篇
        if batch.items.count >= 2 {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(onPreviewPan(_:)))
            previewContainer.addGestureRecognizer(pan)
            previewContainer.isUserInteractionEnabled = true
        }

        overview.delegate = self

        trackContainer.backgroundColor = BKTheme.Color.page
        trackContainer.layer.cornerRadius = BKTheme.Radius.card
        trackContainer.clipsToBounds = true
        track.delegate = self
        trackContainer.addSubview(track)
        track.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            track.leadingAnchor.constraint(equalTo: trackContainer.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trackContainer.trailingAnchor),
            track.topAnchor.constraint(equalTo: trackContainer.topAnchor),
            track.bottomAnchor.constraint(equalTo: trackContainer.bottomAnchor)
        ])

        setupListPanel()
        let toolbar = makeToolbar()

        // ---- 数字行：紧贴画面下面（定稿 4.7）----
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
        // 时间码数字行必须完整显示：竖直方向设为最高抗压，内容超高时让阈值行/留白去吸收，而不是压没它
        statsRow.setContentCompressionResistancePriority(.required, for: .vertical)

        // ---- 阈值行 + 恢复自动按钮（定稿 4.7.1）----
        thresholdTitle.font = BKTheme.Font.mono
        thresholdTitle.textColor = BKTheme.Color.text
        thresholdTitle.setContentHuggingPriority(.required, for: .horizontal)

        thresholdSlider.minimumValue = Float(BKConfig.Detect.clampLow)
        thresholdSlider.maximumValue = Float(BKConfig.Detect.clampHigh)
        thresholdSlider.value = Float(item.thresholdDb)
        thresholdTitle.text = String(format: "阈值 %.1f dB", item.thresholdDb)
        thresholdSlider.minimumTrackTintColor = BKTheme.Color.warning
        thresholdSlider.addTarget(self, action: #selector(thresholdChanged), for: .valueChanged)

        thresholdAutoButton.setImage(BKIcons.backToAuto(side: 20), for: .normal)
        thresholdAutoButton.tintColor = BKTheme.Color.text
        thresholdAutoButton.addTarget(self, action: #selector(thresholdAutoTapped), for: .touchUpInside)
        NSLayoutConstraint.activate([
            thresholdAutoButton.widthAnchor.constraint(equalToConstant: 24),
            thresholdAutoButton.heightAnchor.constraint(equalToConstant: 24)
        ])

        let thresholdRow = UIStackView(arrangedSubviews: [thresholdTitle, thresholdSlider, thresholdAutoButton])
        thresholdRow.axis = .horizontal
        thresholdRow.spacing = BKTheme.Space.sm
        thresholdRow.alignment = .center

        statusLabel.font = BKTheme.Font.caption
        statusLabel.textColor = BKTheme.Color.warning
        statusLabel.numberOfLines = 0

        spinner.hidesWhenStopped = true
        spinner.color = BKTheme.Color.gold

        // 导出/进度提示做成一条独立状态栏，固定贴在工具栏正上方，不再放进可压缩的内容栈。
        // 这样无论上方内容多高，提示区永远不会被底部工具栏遮住（16/16 Pro 小屏最容易触发遮挡）。
        let statusBar = UIStackView(arrangedSubviews: [statusLabel, spinner])
        statusBar.axis = .horizontal
        statusBar.spacing = BKTheme.Space.sm
        statusBar.alignment = .center

        // 顺序照定稿第 4 节：列表 → 画面 → 数字行 → 主轨道 → 概览 → 阈值
        let filler = UIView()
        let stack = UIStackView(arrangedSubviews: [
            listPanel, previewContainer, statsRow, trackContainer,
            overview, thresholdRow, filler
        ])
        stack.axis = .vertical
        // 紧凑：相邻控件统一 8pt（空白1=画面↔数字行↔主轨道、空白2=主轨道↔概览 都收到 8pt）
        stack.spacing = BKTheme.Space.sm
        stack.alignment = .fill

        view.addSubview(stack)
        view.addSubview(toolbar)
        view.addSubview(statusBar)
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        // 提示文案必须完整显示，竖直方向不可被压缩
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        // 小屏竖向预算不够时宁可让内容栈向下溢出、也不能把提示文字压扁：
        // 状态栏是视图最上层 + 垫一层页面底色，溢出内容从它底下穿过被盖住，
        // 黄字永远完整可读（之前被上下削半截 = 约束打架时 Auto Layout 断了文字的抗压）
        statusLabel.backgroundColor = BKTheme.Color.page
        statusBar.backgroundColor = BKTheme.Color.page

        // 内容栈底 ≤ 状态栏顶，优先级 999（全场最低，约束打架时第一个断它）：
        // 竖向预算够时二者照常互不重叠；不够时内容栈向下溢出，保住状态栏文字完整
        let stackUnderStatus = stack.bottomAnchor.constraint(
            lessThanOrEqualTo: statusBar.topAnchor, constant: -BKTheme.Space.md)
        stackUnderStatus.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: BKTheme.Space.lg),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -BKTheme.Space.lg),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: BKTheme.Space.sm),
            // 内容栈底部接到状态栏顶部，把状态栏「顶」在工具栏上方，二者互不重叠
            stackUnderStatus,

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: BKTheme.Space.lg),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -BKTheme.Space.lg),
            statusBar.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -BKTheme.Space.md),

            previewContainer.heightAnchor.constraint(equalToConstant: previewH),
            trackContainer.heightAnchor.constraint(equalToConstant: trackH),
            overview.heightAnchor.constraint(equalToConstant: 30),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: BKTheme.Space.lg),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -BKTheme.Space.lg),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 100)
        ])

        updateThresholdAutoButton()
        updateUndoButtons()
        updateInfo()
        timeLabel.text = "\(formatClock(lastTime)) / \(formatClock(item.duration))"
    }

    /// 工具栏两排（定稿 4.4）：
    /// 第一排 7 个 44pt：`↩ ↪ | ■ ▶ | ⟳ ✂ 💉`，组内间距 8、组间 16，左右各留 13
    /// 第二排 `− +` 两个 28pt 小圆靠右 —— 主力是双指捏合，这两个是捏合失灵时的保底
    private func makeToolbar() -> UIStackView {
        configureTool(undoButton, systemName: "arrow.uturn.backward", action: #selector(undoTapped))
        configureTool(redoButton, systemName: "arrow.uturn.forward", action: #selector(redoTapped))

        // 联播键 `|▶|`（皓哥从 5 个方案里挑的 E）
        jointButton.setImage(BKIcons.skip(), for: .normal)
        applyToolStyle(jointButton, action: #selector(jointTapped))
        // 播放 / 停止是同一个键
        configureTool(playButton, systemName: "play.fill", action: #selector(playTapped))

        // v1.3.0：原来是「反选 ⟳」，现在换成「删红 ✗✗」（自定义纯红双 X，非模板图）
        deleteRedButton.setImage(BKIcons.deleteRedDoubleX(), for: .normal)
        applyToolStyle(deleteRedButton, action: #selector(deleteRedTapped))
        configureTool(cutButton, systemName: "scissors", action: #selector(cutTapped))
        configureTool(detectButton, systemName: "eyedropper", action: #selector(detectTapped))

        let row1 = UIStackView(arrangedSubviews: [
            undoButton, redoButton, jointButton, playButton, deleteRedButton, cutButton, detectButton
        ])
        row1.axis = .horizontal
        row1.spacing = BKTheme.Space.sm
        row1.alignment = .center
        // 均分可用宽度：7 个按钮在任何屏宽下都平分 row1 内部空间，永不溢出挤压
        row1.distribution = .fillEqually
        // 组间 16 = 默认 8 再补 8
        row1.setCustomSpacing(BKTheme.Space.lg, after: redoButton)
        row1.setCustomSpacing(BKTheme.Space.lg, after: playButton)

        removeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        styleRemoveStep(removeButton, action: #selector(removeTapped))

        zoomOutButton.setImage(UIImage(systemName: "minus"), for: .normal)
        styleZoomStep(zoomOutButton, action: #selector(zoomOutTapped))
        zoomInButton.setImage(UIImage(systemName: "plus"), for: .normal)
        styleZoomStep(zoomInButton, action: #selector(zoomInTapped))

        let spacer2 = UIView()
        let row2 = UIStackView(arrangedSubviews: [spacer2, removeButton, zoomOutButton, zoomInButton])
        row2.axis = .horizontal
        row2.spacing = BKTheme.Space.sm
        row2.alignment = .center

        let toolbar = UIStackView(arrangedSubviews: [row1, row2])
        toolbar.axis = .vertical
        toolbar.spacing = BKTheme.Space.sm
        toolbar.alignment = .fill
        // 不要灰色底框：无圆角，按钮直接贴内容区左右边(16pt)，更紧凑。
        // 底色用页面色而非透明：小屏内容栈溢出时穿过工具栏区，页面色能把它盖住
        toolbar.backgroundColor = BKTheme.Color.page
        toolbar.layer.cornerRadius = 0
        toolbar.isLayoutMarginsRelativeArrangement = false
        return toolbar
    }

    private func configureTool(_ button: UIButton, systemName: String, action: Selector) {
        let cfg = UIImage.SymbolConfiguration(pointSize: BKTheme.Button.iconPoint, weight: .regular)
        button.setImage(UIImage(systemName: systemName, withConfiguration: cfg), for: .normal)
        applyToolStyle(button, action: action)
    }

    /// 只套皮 + 挂 action，不动图。自定义图标（联播 `|▶|`、反选 ⟳）用这个入口
    private func applyToolStyle(_ button: UIButton, action: Selector) {
        button.tintColor = BKTheme.Color.text
        button.backgroundColor = BKTheme.Color.panel
        button.layer.cornerRadius = BKTheme.Button.radius
        button.layer.borderWidth = BKTheme.Button.border
        button.layer.borderColor = BKTheme.Color.line.cgColor
        button.clipsToBounds = true
        button.addTarget(self, action: action, for: .touchUpInside)
        // 正方形靠「高 = 宽」保持正圆；宽度不写死，交给 row1 的 fillEqually 按可用宽度均分。
        // 这样 7 个按钮在 15 PM(430pt) 上仍是 44pt，在 16/16 Pro(390/402pt) 上自动缩到
        // 约 38/40pt，不会被 UIStackView 挤成一团（定稿要求窄屏按钮也不能挤压变形）。
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalTo: button.widthAnchor)
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

    /// ✕ 移除按钮：红色实心圆 + 白叉，和上方白底工具按钮拉开对比，一眼认出是「危险操作」。
    /// 放在 −/+ 左边（定稿 4.4 第二排扩展）。点下去**先弹确认框**，不直接删
    private func styleRemoveStep(_ button: UIButton, action: Selector) {
        let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        button.setImage(UIImage(systemName: "xmark", withConfiguration: cfg), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor(hex: 0xC0392B)
        button.layer.cornerRadius = 14
        button.clipsToBounds = true
        button.addTarget(self, action: action, for: .touchUpInside)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    /// 播放键图标 + 联播键高亮，两处一起收在这里，免得改了形状忘了另一处
    private func updatePlayIcons() {
        let cfg = UIImage.SymbolConfiguration(pointSize: BKTheme.Button.iconPoint, weight: .regular)
        playButton.setImage(UIImage(systemName: playMode == .straight ? "stop.fill" : "play.fill",
                                    withConfiguration: cfg), for: .normal)
        jointButton.backgroundColor = (playMode == .joint)
            ? BKTheme.Color.gold.withAlphaComponent(0.30)
            : BKTheme.Color.panel
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
        listTable.register(BKAssetRowCell.self, forCellReuseIdentifier: "BKAssetRowCell")
        listPanel.addSubview(listTable)

        NSLayoutConstraint.activate([
            listPanel.heightAnchor.constraint(equalToConstant: CGFloat(listVisibleRows) * 44 + 8),
            listTable.leadingAnchor.constraint(equalTo: listPanel.leadingAnchor),
            listTable.trailingAnchor.constraint(equalTo: listPanel.trailingAnchor),
            listTable.topAnchor.constraint(equalTo: listPanel.topAnchor, constant: 4),
            listTable.bottomAnchor.constraint(equalTo: listPanel.bottomAnchor, constant: -4)
        ])
    }

    /// 左上角返回：pop 回起始草稿页。
    /// pop 会触发 viewWillDisappear → isMovingFromParent=true → finishSession（存草稿 + 封面），
    /// 所以这里只要 pop 即可，结算逻辑复用已有流程，不用另写
    @objc private func closeTapped() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func toggleListTapped() {
        listVisible.toggle()
        listPanel.isHidden = !listVisible
        if listVisible {
            listTable.reloadData()
            listTable.scrollToRow(at: IndexPath(row: itemIndex, section: 0),
                                  at: .middle, animated: false)
            BKLog.shared.d("打开素材列表，共 \(batch.items.count) 条")
        }
    }

    // MARK: - ✕ 从本批移除当前这条

    /// 点 ✕：先弹确认框，避免手滑把还能用的素材删了。
    @objc private func removeTapped() {
        let name = item.assetName
        let alert = UIAlertController(title: "从本批移除这条视频？",
                                      message: "「\(name)」不会被导出，也不会留在草稿里。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "移除", style: .destructive) { [weak self] _ in
            self?.performRemoveCurrent()
        })
        present(alert, animated: true)
    }

    /// 真正执行移除：从 batch.items 里删掉当前条（不是「跳过导出」，是真删）。
    /// 和列表面板那套同源 —— BKAssetRowCell 只负责显示，数据只在这一个地方改。
    /// 删完分两种：① 整批空了 → 回起始页并丢草稿；② 还有别的 → 跳到相邻那条继续编
    private func performRemoveCurrent() {
        let removedIndex = itemIndex
        var b = batch
        b.items.remove(at: removedIndex)
        b.lastEditedAt = Date()
        batch = b
        BKDraftStore.shared.scheduleSave(b)
        BKDraftStore.shared.flushIfNeeded()

        if b.items.isEmpty {
            // 整批删空：回起始页，并直接把这份空草稿删掉
            // （finishSession 见 didDiscard 短路，不会再把它存回去）
            didDiscard = true
            BKDraftStore.shared.cancelPending()
            BKDraftStore.shared.permanentlyDelete(b)
            navigationController?.popToRootViewController(animated: true)
            return
        }

        // 跳到相邻那条（和 openItem 同一条「换素材」路径，复用已验证的探针 + 换栈顶逻辑）
        let newIndex = min(removedIndex, b.items.count - 1)
        let targetID = b.items[newIndex].assetLocalID
        isSwitchingAsset = true
        stopPlayback()
        BKVideoLibrary.loadAVAsset(localID: targetID) { [weak self] asset in
            guard let self = self else { return }
            self.isSwitchingAsset = false
            guard let asset = asset, let nav = self.navigationController else { return }
            let probe = BKAssetProbe.probe(asset)
            var bb = self.batch
            if probe.duration > 0 { bb.items[newIndex].duration = probe.duration }
            bb.items[newIndex].displayWidth = probe.displayWidth
            bb.items[newIndex].displayHeight = probe.displayHeight
            bb.items[newIndex].sourceRotationDegrees = probe.rotationDegrees
            bb.items[newIndex].playheadTime = 0
            bb.lastAssetId = targetID
            let vc = BKEditorViewController(batch: bb, index: newIndex, asset: asset, probeInfo: probe)
            var stack = nav.viewControllers
            if stack.last === self { stack.removeLast() }
            stack.append(vc)
            nav.setViewControllers(stack, animated: true)
            BKLog.shared.i("移除第 \(removedIndex + 1) 条，跳到第 \(newIndex + 1)/\(bb.items.count) 条")
        }
    }

    // MARK: - 素材切换（两条路并存，定稿第 5 节）

    /// 路①：左右滑画面（随时能用，快速翻找）—— **横向 ≥40pt 且纵向 <12pt 才算数**
    private var swipeFired = false

    @objc private func onPreviewPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            swipeFired = false
        case .changed:
            guard !swipeFired else { return }
            let t = g.translation(in: previewContainer)
            if abs(t.x) >= BKConfig.Layout.swipeMinX && abs(t.y) < BKConfig.Layout.swipeMaxY {
                swipeFired = true
                g.isEnabled = false       // 触发一次就锁住，避免一划连跳好几条
                if t.x < 0 { openItem(at: itemIndex + 1) } else { openItem(at: itemIndex - 1) }
            }
        case .ended, .cancelled, .failed:
            g.isEnabled = true
            swipeFired = false
        default:
            break
        }
    }

    /// 路②：轨道拖到片头/片尾再狠拽 >60pt。两条路底层调的是同一个函数
    private func openItem(at index: Int) {
        guard index >= 0, index < batch.items.count else { return }
        guard !isSwitchingAsset else {
            // 加载锁：上一次还没回来，直接短路返回，不排队
            BKLog.shared.d("换素材被锁：上一次还没加载完")
            return
        }
        isSwitchingAsset = true
        stopPlayback()
        savePlayhead()
        BKDraftStore.shared.flushIfNeeded()

        let targetID = batch.items[index].assetLocalID
        BKVideoLibrary.loadAVAsset(localID: targetID) { [weak self] asset in
            guard let self = self else { return }
            self.isSwitchingAsset = false
            guard let asset = asset, let nav = self.navigationController else {
                BKLog.shared.e("切换素材失败：\(targetID)")
                return
            }
            let probe = BKAssetProbe.probe(asset)
            BKLog.shared.i(probe.logLine)

            var b = self.batch
            if probe.duration > 0 { b.items[index].duration = probe.duration }
            b.items[index].displayWidth = probe.displayWidth
            b.items[index].displayHeight = probe.displayHeight
            b.items[index].sourceRotationDegrees = probe.rotationDegrees
            // 定稿 4.5.3：**指针一律停在新素材片头**，不分从上一条进来还是下一条进来
            b.items[index].playheadTime = 0
            b.lastAssetId = targetID
            b.lastEditedAt = Date()

            let vc = BKEditorViewController(batch: b, index: index, asset: asset, probeInfo: probe)
            var stack = nav.viewControllers
            if stack.last === self { stack.removeLast() }
            stack.append(vc)
            nav.setViewControllers(stack, animated: true)
            BKLog.shared.i("切换到第 \(index + 1)/\(b.items.count) 条：\(b.items[index].assetName)")
        }
    }

    // MARK: - 提交与撤销

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
        applyItem(updated)
    }

    private func applyItem(_ updated: BKProject) {
        batch.items[itemIndex] = updated
        // everEdited **只置不清**：撤销是把刀撤掉，不是把「我编辑过这件事」抹掉
        if updated.isEdited { batch.everEdited = true }
        batch.lastAssetId = updated.assetLocalID
        batch.lastEditedAt = Date()
        refreshTrack()
        updateInfo()
        updateUndoButtons()
        BKDraftStore.shared.scheduleSave(batch)
    }

    @objc private func undoTapped() {
        guard let restored = history.undo() else { return }
        batch.items[itemIndex] = restored
        refreshTrack()
        updateInfo()
        updateUndoButtons()
        BKDraftStore.shared.scheduleSave(batch)
        statusLabel.text = "已撤销"
        BKLog.shared.i("撤销 → 栈内第 \(history.depth) 格")
    }

    @objc private func redoTapped() {
        guard let restored = history.redo() else { return }
        batch.items[itemIndex] = restored
        refreshTrack()
        updateInfo()
        updateUndoButtons()
        BKDraftStore.shared.scheduleSave(batch)
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

    private func applyMarks(_ marks: [BKMark], coalesce: Bool = false) {
        var p = item
        p.marks = BKTimeline.normalize(marks, duration: p.duration)
        p.updatedAt = Date()
        commit(p, coalesce: coalesce)
    }

    /// 按一下，就从**橙色指针现在指的地方**把轨道切开。
    ///
    /// 【切开 ≠ 删除】切口不进 cutRanges，所以导出时长纹丝不动。
    /// 它的作用是把一段划成两段，好让你单独处理其中一半
    @objc private func cutTapped() {
        var p = item
        let t = min(max(lastTime, 0), p.duration)

        guard t > 0.05, t < p.duration - 0.05 else {
            statusLabel.text = "指针太靠两头了，这里切不出东西"
            return
        }
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

    /// ✗✗ 一键去红（v1.3.4）：进入**第二阶段**。
    ///
    /// 【两阶段逻辑，皓哥 2026-10-04 18:39 定】
    ///   第一阶段：自动识别气口 → 红绿交替。此时用户可以
    ///             · 拖红区边缘调气口大小（`redEdgePan`）
    ///             · 点绿区把它转成红区（tap）
    ///             · 用 ✂ 切割键切开波形
    ///             这一阶段的记录是**记录A（红区）**。
    ///   点一下本键 → 按红区位置**切割轨道、删掉红区** → 进入第二阶段。
    ///   第二阶段：轨道上全是绿区，一块一块。用户可以
    ///             · 长按任一绿区 → 黄框 + 黄把手 → 调这块的开头/结尾长短
    ///             这一阶段的记录是**记录B（绿区）**，由 A 推导生成，之后独立。
    ///   **导出直接用 B**。
    ///
    /// 【单向，不可逆】v1.3.4 之前这里有「再按一次取消折叠」，皓哥明确说不对 ——
    /// 删红是终态。想回到第一阶段只有「撤销」一条路（语义清晰）。
    @objc private func deleteRedTapped() {
        guard !item.isStage2 else {
            statusLabel.text = "已经删过红区了 —— 长按某块可以调它的长短"
            return
        }
        let cuts = item.cutRanges
        guard !cuts.isEmpty else {
            statusLabel.text = "当前没有红区可删"
            return
        }

        // 记录A → 记录B：这是两阶段的**唯一一次**坐标系转换，做完 A 就冻结
        let keeps = BKTimeline.deriveKeeps(duration: item.duration, cuts: cuts)
        guard !keeps.isEmpty else {
            statusLabel.text = "没有可保留的绿区"
            return
        }

        var p = item
        p.keptRanges = keeps
        commit(p)

        let total = keeps.reduce(0.0) { $0 + $1.duration }
        // ⚠️ 诊断（v1.4.7）：红区贴着素材首尾时，红红红 的排布会「少一段绿区」
        // （开头是红区就没有绿区可留，这是数学正确的）。
        // 但用户看到的是「界面上 N 个红区，删完只有 M-1 道分割线」，
        // 容易误判成没删干净。**把真实区间全打出来**，一眼能核对。
        let keepDesc = keeps.map { String(format: "%.2f→%.2f", $0.start, $0.end) }
        BKLog.shared.i(String(format:
            "一键去红：删 %d 段 → 留 %d 段绿区，成品 %.2fs（原片 %.2fs）| 绿区区间: %@",
            cuts.count, keeps.count, total, item.duration, keepDesc.joined(separator: " ")))
        BKLog.shared.i(String(format:
            "红区区间: %@", cuts.map { String(format: "%.2f→%.2f", $0.0, $0.1) }
                .joined(separator: " ")))

        let edgeNote = (keeps.first?.start ?? 0) < 0.01
            ? "（首段贴素材开头，其前无绿区）" : ""
        statusLabel.text = String(format: "已删 %d 段气口，剩 %d 段绿区 · 成品 %.1fs · 长按可调长短%@",
                                  cuts.count, keeps.count, total, edgeNote)
        BKLog.shared.i(String(format: "一键去红：删 %d 段 → 留 %d 段绿区，成品 %.2fs（原片 %.2fs）",
                              cuts.count, keeps.count, total, item.duration))
    }

    /// 点段 toggle 绿↔红（v1.3.0 沿用界面定稿第 5 节第 692 行）。
    /// 「反选 ⟳」被删掉后，这个能力**全靠直接点那一段**——
    /// 「只能删红区、绿区想删先点成红」这条规则就是靠它落实的。
    private func togglePiece(at time: Double) {
        let p = item
        // 第二阶段：轨道上全是绿区，没有红区可切换。点段只用来退出编辑态（见 onTap）
        guard !p.isStage2 else {
            statusLabel.text = "已经删过红区了 —— 长按某块可以调它的长短"
            return
        }
        let shown = BKTimeline.pieces(duration: p.duration, cuts: p.cutRanges, splits: p.splits)
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
                if self.item.autoThresholdDb == nil, self.item.exportHistory.isEmpty,
                   !self.item.isEdited {
                    // 全新的素材：跑一次自动检测
                    self.history.reset(self.item)
                    self.runDetection(override: nil)
                } else {
                    // 恢复编辑：不重跑检测，尊重上次保存的刀口
                    self.history.reset(self.item)
                    self.refreshTrack()
                    self.updateInfo()
                    self.track.setPointerTime(self.lastTime)
                    self.statusLabel.text = "已恢复上次的编辑进度"
                }
                BKDraftStore.shared.markOpened(self.batch.id)
                self.updateUndoButtons()
                self.updateThresholdAutoButton()
                self.schedulePreroll()
            }
        }
    }

    private func runDetection(override: Double?) {
        guard let env = envelope else { return }
        statusLabel.text = "正在检测气口…"
        spinner.startAnimating()

        let p = item
        let dur = p.duration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = BKDetector.detect(envelope: env,
                                            totalDuration: dur,
                                            overrideThreshold: override)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.spinner.stopAnimating()
                var proj = self.item
                proj.thresholdDb = outcome.info.thresholdDb
                if override == nil {
                    // 记下这次自动算出来的**实际使用值**（夹逼之后的）——
                    // 「恢复自动」要回到的就是它，不是未夹逼的原始 Otsu
                    proj.autoThresholdDb = outcome.info.thresholdDb
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
                self.updateThresholdAutoButton()
            }
        }
    }

    /// 轨道 + 概览条一起刷新。分开刷迟早会出现「轨道已经切了，概览条还画着旧的」
    private func refreshTrack() {
        let p = item
        // 【v1.3.4 两套记录】
        //   第一阶段：红绿交替（含红区，可拖红区边缘），画布时间轴 = **原片时长**
        //   第二阶段：只有绿区（每块之间有分割线），画布时间轴**仍然是原片时长**
        //
        // ⚠️ 关键差异：v1.3.0~1.3.4 第二阶段把绿区 ripple 拼成「成品时间轴」
        // （长度 = 各绿区之和，比原片短），于是长按拿到的是成品时间、
        // 改数据要换算回原片时间 —— 换算出错就改错段（实测第3段会改到第1段）。
        // 两套记录下第二阶段**全程原片时间、零换算**，所以 duration 不用变。
        let stage2 = p.isStage2
        let shown = p.displayPieces
        track.setContent(envelope: envelope,
                         pieces: shown,
                         splits: stage2 ? [] : p.splits,
                         duration: p.duration,
                         thresholdDb: p.thresholdDb,
                         foldMap: nil,
                         redFolded: stage2)
        overview.setContent(envelope: envelope,
                            pieces: shown,
                            duration: p.duration,
                            viewport: track.viewport,
                            foldMap: nil)
    }

    private func updateInfo() {
        let p = item
        if p.cutCount == 0 {
            infoLabel.text = String(format: "原 %@ · 剪后 %@ · 还没有刀口",
                                    formatClock(p.duration), formatClock(p.outputDuration))
        } else {
            infoLabel.text = String(format: "原 %@ · 剪后 %@ · %d 刀 · 删 %.1fs（%.1f%%）",
                                    formatClock(p.duration), formatClock(p.outputDuration),
                                    p.cutCount, p.removedDuration, p.removedRatio * 100)
        }
    }

    /// 💉 自动检测：按当前阈值重算气口
    @objc private func detectTapped() {
        runDetection(override: Double(thresholdSlider.value))
    }

    /// ± 每次走 2 屏。1 屏一档太慢，从 6 屏拉到 20 屏要按 14 下
    @objc private func zoomInTapped() { zoomStep(by: 2) }

    @objc private func zoomOutTapped() { zoomStep(by: -2) }

    private func zoomStep(by delta: CGFloat) {
        track.setZoomScreens(track.zoomScreens + delta)
        overview.setViewport(track.viewport)
    }

    // MARK: - 播放

    /// ▶ 原片播：从橙指针处起播，红区绿区都播
    @objc private func playTapped() {
        if playMode == .straight { stopPlayback(); return }
        // v1.3.0（定稿 5）：删红折叠后轨道时间轴就是成品时间轴，「原片播放器 + 原片 seek」
        // 已经不是指针所在的那条时间轴了 —— 继续走原片播会「画面在 A、内容是 B」。
        // 所以折叠状态下 ▶ 直接走联播那条路（它本来就是按 keepRanges 拼好播的），
        // 起播点仍按皓哥定的规则算：指针在绿区从指针处、在红区跳下一个绿区。
        if item.isStage2 {
            jointTapped()
            return
        }
        stopPlayback()
        guard let p = player else { return }
        // 起播路径保持极短：只做 play()。seek 和 preroll 早在指针停下时就做完了
        playerLayer?.player = p
        p.play()
        playMode = .straight
        updatePlayIcons()
    }

    /// `|▶|` 联播：按保留段临时拼一条来播，等于预演成品（定稿 4.5.4）
    ///
    /// 【v1.3.4】`item.keepRanges` 已按阶段自动取记录（第二阶段返回记录B），
    /// 所以这里不用再判阶段，也不用换算坐标系。
    @objc private func jointTapped() {
        if playMode == .joint { stopPlayback(); return }
        stopPlayback()

        let keeps = item.keepRanges
        guard let built = BKJointBuilder.build(asset: asset, keeps: keeps) else {
            statusLabel.text = "没有可播放的绿区"
            return
        }
        // 【2026-10-04 修】startKeptTime 返回的是**原片时间**，这里必须先换成成品时间。
        // v1.2.14 直接拿它去 seek，成品时间轴比原片短（只含绿区）→ 错位最大能到 1.3 秒。
        // 皓哥要的逻辑：指针在绿区就从指针处播，指针在红区就跳下一个绿区。
        guard let startSrc = BKJointBuilder.startKeptTime(for: lastTime, keeps: keeps) else {
            statusLabel.text = "没有可播放的绿区"
            return
        }
        let startOut = built.outputTime(at: startSrc)

        guard let jp = jointPlayer else { return }
        joint = built
        jp.replaceCurrentItem(with: built.item)
        jp.seek(to: CMTime(seconds: startOut, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero)
        // 指针跟着挪到对应位置，跳转是瞬间的。
        // ⚠️ 这里传的是**原片**时间 —— 主轨道画的是原片时间轴，别把上面那个成品时间传下来
        syncPlayhead(to: startSrc)

        playerLayer?.player = jp
        jp.play()
        playMode = .joint
        updatePlayIcons()
        BKLog.shared.i(String(format: "联播 %d 段 · 成品 %.1fs（原片 %.1fs）",
                              built.segments.count, built.total, item.duration))
        BKLog.shared.d(String(format: "联播起播 原片 %.2fs → 成品 %.2fs", startSrc, startOut))
    }

    /// 停止。**指针停原地**（定稿 4.5.2）—— 旧版「停止 = 暂停 + 回 0 秒」已作废
    private func stopPlayback() {
        player?.pause()
        jointPlayer?.pause()
        playMode = .idle
        // 画面切回原片播放器，并把主 player 挪到当前指针 ——
        // 这样退出联播之后画面接得上，不会跳回上一次原片播到的地方
        playerLayer?.player = player
        if let p = player {
            p.seek(to: CMTime(seconds: lastTime, preferredTimescale: 600),
                   toleranceBefore: .zero, toleranceAfter: .zero)
        }
        joint = nil
        updatePlayIcons()
        schedulePreroll()
    }

    /// 指针一停下就后台预解码。等按下 ▶ 时只剩 play() 一步 ——
    /// 降延迟靠的是「提前把活干完」，不是优化按下那一刻
    private func schedulePreroll() {
        prerollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.playMode == .idle else { return }
            let t = CMTime(seconds: self.lastTime, preferredTimescale: 600)
            self.player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.player?.preroll(atRate: 1, completionHandler: nil)
            }
        }
        prerollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - 阈值

    @objc private func thresholdChanged() {
        let v = Double(thresholdSlider.value)
        thresholdTitle.text = String(format: "阈值 %.1f dB", v)
        updateThresholdAutoButton()
        // 滑杆是连续动作，停下 0.4 秒才真正重算 —— 手感优先
        sliderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.runDetection(override: v)
        }
        sliderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// 「恢复自动」：当前就是自动值时置灰，手动拖过就亮，按一下回到 Otsu 的值并重算
    @objc private func thresholdAutoTapped() {
        guard let auto = item.autoThresholdDb else {
            statusLabel.text = "还没有自动值，先按一次吸管检测"
            return
        }
        thresholdSlider.value = Float(auto)
        thresholdTitle.text = String(format: "阈值 %.1f dB", auto)
        runDetection(override: auto)
        statusLabel.text = String(format: "已回到自动值 %.1f dB", auto)
    }

    /// 阈值是不是还停在自动算出来的那个值上
    private func updateThresholdAutoButton() {
        guard let auto = item.autoThresholdDb else {
            thresholdAutoButton.isEnabled = false
            thresholdAutoButton.alpha = 0.30
            return
        }
        let isAuto = abs(item.thresholdDb - auto) < 0.01
        thresholdAutoButton.isEnabled = !isAuto
        thresholdAutoButton.alpha = isAuto ? 0.30 : 1.0
    }

    // MARK: - 导出

    @objc private func exportTapped() {
        guard !isExporting else { return }
        stopPlayback()
        savePlayhead()
        BKDraftStore.shared.flushIfNeeded()

        let panel = BKExportPanelViewController(batch: batch, currentIndex: itemIndex)
        panel.onStart = { [weak self] scope, spec in
            self?.runExport(scope: scope, spec: spec)
        }
        present(panel, animated: true)
    }

    private func runExport(scope: BKExportScope, spec: BKConfig.ExportSpec) {
        let targets: [Int]
        switch scope {
        case .current:
            targets = [itemIndex]
        case .allEdited:
            // 「改过的」= cuts 或 splits 非空 —— 跟列表红字、草稿留存**同一个判定**
            targets = batch.items.indices.filter { batch.items[$0].isEdited }
        }
        guard !targets.isEmpty else {
            statusLabel.text = "这一批还没有动过刀的素材"
            return
        }

        isExporting = true
        setControlsEnabled(false)
        spinner.startAnimating()

        // 批量 + 选了「同源文件」→ 按**时长最长那条**的参数全批统一（定稿 4.9.1）。
        // 帧率只有从 AVAsset 上才读得到，所以先加载一次那条素材
        if scope == .allEdited, let li = batch.longestItemIndex() {
            let refItem = batch.items[li]
            BKVideoLibrary.loadAVAsset(localID: refItem.assetLocalID) { [weak self] asset in
                guard let self = self else { return }
                var ref: BKExporter.ExportReference?
                if let a = asset, let t = a.tracks(withMediaType: .video).first {
                    // 显示尺寸一律走 BKAssetProbe —— 它已经把 preferredTransform 应用过了。
                    // ⚠️ **别用 `asset.naturalSize`**：Swift 4.2 起它在 iOS SDK 上是
                    // `unavailable`（不是 deprecated），因为一个 asset 可能挂多条视频轨，
                    // 没说清是哪一条。只有 `AVAssetTrack.naturalSize` 能用。
                    let probe = BKAssetProbe.probe(a)
                    ref = BKExporter.ExportReference(
                        displayWidth: refItem.displayWidth > 0 ? refItem.displayWidth : probe.displayWidth,
                        displayHeight: refItem.displayHeight > 0 ? refItem.displayHeight : probe.displayHeight,
                        fps: t.nominalFrameRate > 0 ? Double(t.nominalFrameRate) : 30)
                    if let r = ref {
                        BKLog.shared.i(String(format: "批量导出统一按最长那条：%@ %.0f×%.0f %.0ffps",
                                              refItem.assetName, r.displayWidth, r.displayHeight, r.fps))
                    }
                }
                self.exportLoop(targets, spec: spec, reference: ref,
                                done: 0, ok: 0, failed: [], skipped: [])
            }
        } else {
            exportLoop(targets, spec: spec, reference: nil, done: 0, ok: 0, failed: [], skipped: [])
        }
    }

    /// 逐条排队。单条失败记下来继续跑完剩下的，最后统一报一句 ——
    /// 中途弹窗把整批打断比让它跑完难受得多（定稿 4.8）
    private func exportLoop(_ targets: [Int],
                            spec: BKConfig.ExportSpec,
                            reference: BKExporter.ExportReference?,
                            done: Int,
                            ok: Int,
                            failed: [(String, String)],
                            skipped: [String]) {
        // 每一轮（一条素材）开始前清一次历史，
        // 免得复制诊断信息时把上一批的旧报告也带进去
        if done == 0 {
            BKDiag.shared.clearHistory()
        }
        if done >= targets.count {
            finishExport(ok: ok, failed: failed, skipped: skipped)
            return
        }
        let idx = targets[done]
        let it = batch.items[idx]

        // 整条都是红区（没有可保留片段）：按「跳过 + 明确提示」处理，不跑导出器。
        // 这是之前两条视频导出失败的根因 —— keepRanges 为空时原代码直接抛错，
        // 把整批记成失败。现在跳过它，让批量继续跑完，最后汇总告诉用户哪几条全红
        if it.keepRanges.isEmpty {
            BKLog.shared.w("跳过 \(it.assetName)：全是红区，没有可保留片段")
            exportLoop(targets, spec: spec, reference: reference, done: done + 1,
                       ok: ok, failed: failed, skipped: skipped + [it.assetName])
            return
        }

        statusLabel.text = "正在导出 \(done + 1)/\(targets.count) · \(it.assetName)"

        BKVideoLibrary.loadAVAsset(localID: it.assetLocalID) { [weak self] asset in
            guard let self = self else { return }
            guard let asset = asset else {
                self.exportLoop(targets, spec: spec, reference: reference, done: done + 1,
                                ok: ok, failed: failed + [(it.assetName, "素材加载失败（AVAsset 为 nil）")], skipped: skipped)
                return
            }
            let name = it.nextExportFileName
            BKExporter.export(project: it, asset: asset, spec: spec, reference: reference,
                              progress: { [weak self] _, _, f in
                                  self?.statusLabel.text = String(
                                      format: "正在导出 %d/%d · %d%%", done + 1, targets.count, Int(f * 100))
                              },
                              completion: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .failure(let err):
                    BKLog.shared.e("导出失败 \(it.assetName)：\(err.localizedDescription)")
                    self.exportLoop(targets, spec: spec, reference: reference, done: done + 1,
                                    ok: ok, failed: failed + [(it.assetName, err.localizedDescription)], skipped: skipped)
                case .success(let url):
                    BKRootViewController.saveToPhotos(url: url, fileName: name) { [weak self] success in
                        guard let self = self else { return }
                        if success {
                            // 记进导出历史：文件名后缀序号（exportCount）就靠它递增
                            let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
                            let rec = BKExportRecord(id: UUID(), date: Date(),
                                                     fileSize: (attr?[.size] as? Int64) ?? 0,
                                                     duration: it.outputDuration,
                                                     fileName: name,
                                                     elapsedSec: 0)
                            self.batch.items[idx].exportHistory.append(rec)
                            self.batch.lastEditedAt = Date()
                            BKDraftStore.shared.scheduleSave(self.batch)
                            self.updateInfo()
                            self.exportLoop(targets, spec: spec, reference: reference,
                                            done: done + 1, ok: ok + 1, failed: failed, skipped: skipped)
                        } else {
                            self.exportLoop(targets, spec: spec, reference: reference, done: done + 1,
                                            ok: ok, failed: failed + [(it.assetName, "保存到相册失败")], skipped: skipped)
                        }
                    }
                }
            })
        }
    }

    private func finishExport(ok: Int, failed: [(String, String)], skipped: [String]) {
        isExporting = false
        setControlsEnabled(true)
        spinner.stopAnimating()
        BKDraftStore.shared.flushIfNeeded()

        // 三类结果分开说：成功 / 全红跳过 / 真失败。只有「全成功」才自动回起始页，
        // 其余都弹一句让用户看清楚再走（弹窗和 pop 会打架，所以回起始页放在按钮里）
        if failed.isEmpty, skipped.isEmpty {
            statusLabel.text = "已导出 \(ok) 条，即将返回草稿列表"
            // 皓哥定：全部导出完成后默认回到起始草稿页。
            // 用延时 1.2s 而非弹 modal alert —— 延时够看清结果即可
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.navigationController?.popToRootViewController(animated: true)
            }
        } else {
            var title = "\(ok) 条成功"
            if skipped.count > 0 { title += "，\(skipped.count) 条全是红区已跳过" }
            if failed.count > 0 { title += "，\(failed.count) 条失败" }
            statusLabel.text = title

            let detail = (skipped.map { "（全红跳过）\($0)" } + failed.map { "\($0.0)：\($0.1)" }).joined(separator: "\n")
            let alert = UIAlertController(title: title,
                                          message: detail.isEmpty ? nil : detail,
                                          preferredStyle: .alert)
            // 【IMG_4873 案】有真失败时给一条「复制诊断信息」：
            // 报告里有素材规格 / 导出参数 / 段边界 / 卡在哪一段 / writer 真实错误，
            // 粘贴给巴蒂就能直接定位，不用再靠猜（UIAlert 按钮从 2 个变 3 个是可读的）
            if !failed.isEmpty {
                alert.addAction(UIAlertAction(title: "复制诊断信息", style: .default) { [weak self] _ in
                    UIPasteboard.general.string = BKDiag.shared.allReportsText()
                    let ok = UIAlertController(title: "已复制",
                                               message: "直接粘贴给巴蒂就行，他看到的是完整现场（哪一段卡死、参数、真实错误）。",
                                               preferredStyle: .alert)
                    ok.addAction(UIAlertAction(title: "好", style: .default))
                    self?.present(ok, animated: true)
                })
            }
            alert.addAction(UIAlertAction(title: "返回草稿列表", style: .default) { [weak self] _ in
                self?.navigationController?.popToRootViewController(animated: true)
            })
            present(alert, animated: true)
        }
    }

    /// 状态机统一入口：提波形 / 导出期间把整个工具栏灰掉，
    /// 免得在半成品状态上再叠一层编辑
    private func setControlsEnabled(_ enabled: Bool) {
        let buttons = [undoButton, redoButton, jointButton, playButton, deleteRedButton,
                       cutButton, detectButton, zoomOutButton, zoomInButton]
        for b in buttons {
            b.isEnabled = enabled
            b.alpha = enabled ? 1.0 : 0.4
        }
        exportButton.isEnabled = enabled
        exportButton.alpha = enabled ? 1.0 : 0.4
        thresholdSlider.isEnabled = enabled
        // 撤销 / 重做 / 恢复自动 三个按钮的可用性各有各的判据，不能一刀切全亮。
        // 少了这一句，恢复之后「恢复自动」会在还是自动值的时候亮着
        if enabled {
            updateUndoButtons()
            updateThresholdAutoButton()
        }
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

// MARK: - 素材列表（定稿 4.2）

/// 左边一条金色竖条，用来标「正在编辑这一条」。
/// 用自定义 cell 而不是 selectedBackgroundView：后者按下就变色，会跟红色名字打架
private final class BKAssetRowCell: UITableViewCell {

    let bar = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        bar.backgroundColor = BKTheme.Color.gold
        bar.isHidden = true
        contentView.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            bar.widthAnchor.constraint(equalToConstant: 3)
        ])
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }
}

extension BKEditorViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        batch.items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: "BKAssetRowCell", for: indexPath) as? BKAssetRowCell else {
            return UITableViewCell()
        }
        let it = batch.items[indexPath.row]
        let isCurrent = (indexPath.row == itemIndex)

        cell.backgroundColor = .clear
        cell.textLabel?.text = it.assetName
        // 定稿 4.2：已切割 → **红色 #C0392B**；没动过 → 默认色。
        // 判定用「cuts 或 splits 非空」，不能用「有没有草稿」
        cell.textLabel?.textColor = it.isEdited ? UIColor(hex: 0xC0392B) : BKTheme.Color.text
        cell.detailTextLabel?.text = it.isEdited
            ? "\(it.cutCount) 刀 · \(BKVideoLibrary.formatDuration(it.duration))"
            : BKVideoLibrary.formatDuration(it.duration)
        cell.detailTextLabel?.textColor = BKTheme.Color.text2
        cell.accessoryType = isCurrent ? .checkmark : .none
        cell.tintColor = BKTheme.Color.gold
        cell.selectionStyle = .default
        cell.bar.isHidden = !isCurrent
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row != itemIndex else {
            toggleListTapped()      // 点的是当前这条 —— 收起列表就好
            return
        }
        openItem(at: indexPath.row)
    }
}

// MARK: - 主轨道回调

extension BKEditorViewController: BKTrackViewDelegate {

    func track(_ view: BKTrackView, didScrollTo time: Double) {
        let t = min(max(time, 0), item.duration)
        // 手动找位置一律静音：seek 走 rate==0 的路径，天然不出声。
        // **绝不能用播放中的 player 去 seek 来模拟 scrub** —— 那样拖动就是有声的
        if playMode != .idle { stopPlayback() }
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        lastTime = t
        timeLabel.text = "\(formatClock(t)) / \(formatClock(item.duration))"
        overview.setViewport(track.viewport)
        schedulePreroll()
    }

    /// 手指一碰轨道就停（定稿 4.5.1）。播放中一拖就暂停，不存在松手续播
    func trackDidTouchDown(_ view: BKTrackView) {
        if playMode != .idle { stopPlayback() }
    }

    func track(_ view: BKTrackView, didTogglePieceAt time: Double) {
        togglePiece(at: time)
    }

    // 【v1.3.3 删除】didBeginBoundaryDragNear / didDragBoundaryNear / trackDidEndBoundaryDrag
    // 「拖接缝」这条路已取消（方案甲：手势统一到「长按 → 黄把手」）。
    // 拖动合并撤销的逻辑改由 didBeginRegionEdit / didCommitRegionEdit 承担。

    func track(_ view: BKTrackView, didChangeZoomTo screens: CGFloat) {
        overview.setViewport(track.viewport)
        BKLog.shared.d(String(format: "轨道缩放 %.1f 屏", screens))
    }

    // MARK: v1.3.4 第一阶段：拖红区边缘调气口大小

    /// 按下红区边缘开始拖。开启「合并提交」—— 拖动过程每帧都回调，
    /// 不合并的话撤销栈会被一帧一帧塞满，撤一次只退一帧
    func track(_ view: BKTrackView, didBeginRedEdgeDragNear time: Double) {
        boundaryDragging = true
        boundaryCommitted = false
        BKLog.shared.d(String(format: "开始拖红区边缘 %.2fs", time))
    }

    /// 拖红区边缘。红区是**记录A**（cuts），改它不影响记录B —— 还没进第二阶段
    func track(_ view: BKTrackView, didDragRedEdgeNear near: Double, to newTime: Double) {
        guard let next = BKTimeline.moveRedEdge(cuts: item.cutRanges,
                                               near: near,
                                               to: newTime,
                                               duration: item.duration) else { return }
        applyMarks(BKTimeline.build(duration: item.duration, cuts: next), coalesce: true)
    }

    func trackDidEndRedEdgeDrag(_ view: BKTrackView) {
        boundaryDragging = false
        boundaryCommitted = false
    }

    // MARK: v1.3.4 第二阶段：长按绿区 → 黄框黄把手 → 调这块的长短

    /// 长按进了编辑态。
    ///
    /// 【两套记录的核心收益】第二阶段轨道显示的就是**原片时间轴**（v1.3.0~1.3.4
    /// 是「成品时间轴」，导致拖把手要换算，实测会改错段）。所以这里拿到的
    /// 区间**就是记录B 里的原片时间**，拖动时直接改，零换算。
    func track(_ view: BKTrackView, didBeginRegionEditFrom start: Double, to end: Double) {
        guard item.isStage2 else { return }
        regionEditing = true
        boundaryDragging = true
        statusLabel.text = String(format: "编辑 %.2f~%.2fs · 拖两端黄把手改长短，点别处退出",
                                   start, end)
        BKLog.shared.d(String(format: "进入区域编辑态 [%.2f, %.2f]", start, end))
    }

    /// 拖把手中。**不落盘** —— 每帧重建+落盘会卡死。只更新状态行，松手才提交
    func track(_ view: BKTrackView, didDragRegionEdge handle: BKHandleEnd, to newTime: Double) {
        guard let seg = view.editingSegment else { return }
        // ⚠️ 变量别叫 `s` / `e` —— 编译器把 `e - s` 里的 `e` 一度推成 `Duration`，
        // 报 "argument type 'Duration' does not conform to 'CVarArg'"。
        // 用明确的 `newStart` / `newEnd` 最省事。
        let newStart = (handle == .head) ? newTime : seg.start
        let newEnd = (handle == .tail) ? newTime : seg.end
        let verb = (handle == .head) ? (newTime < seg.start ? "开头缩短" : "开头延长")
                                      : (newTime > seg.end ? "结尾延长" : "结尾缩短")
        let span = newEnd - newStart
        statusLabel.text = String(format: "%s → %.2f~%.2fs（长 %.2fs）· 松手生效",
                                  verb, newStart, newEnd, span)
    }

    /// 拖把手松手，提交。**直接改记录B**（不反推 cuts、不换算坐标系）
    func track(_ view: BKTrackView, didCommitRegionEditFrom start: Double, to end: Double) {
        boundaryDragging = false
        regionEditing = false
        guard item.isStage2, let base = view.editingSegment else { return }

        let p = item
        // 按坐标找那一段（不能用 index：index 会随显示粒度变 —— 现有代码的教训）
        var idx = -1
        for i in 0 ..< p.keptRanges.count
        where abs(p.keptRanges[i].start - base.start) < 1e-6
            && abs(p.keptRanges[i].end - base.end) < 1e-6 {
            idx = i
            break
        }
        guard idx >= 0 else {
            BKLog.shared.w("提交拖动：记录B 里找不到 [\(base.start), \(base.end)]，放弃")
            return
        }
        // 拖的是哪一端：区间变了的那头
        let edge: BKHandleEnd = (abs(start - base.start) < 1e-6) ? .head : .tail
        let newTime = (edge == .head) ? start : end
        guard let next = BKTimeline.resizeKeeps(p.keptRanges,
                                                index: idx,
                                                edge: edge,
                                                to: newTime,
                                                duration: p.duration,
                                                minSeg: BKConfig.RegionEdit.minSegmentSec) else {
            statusLabel.text = "拖不过去了（会越界或短于 0.1 秒）"
            return
        }

        var q = item
        q.keptRanges = next
        q.updatedAt = Date()
        commit(q)

        // ⚠️ 显式 Double(...)：`Segment.duration` 与 Swift 内置的同名类型会撞，
        // 推断出来的类型不满足 String(format:) 要的 CVarArg。
        let grew = Double(next[idx].duration) - Double(p.keptRanges[idx].duration)
        let totalNow = Double(q.outputDuration)
        statusLabel.text = grew >= 0
            ? String(format: "这段变长 %.2fs · 成品共 %.1fs", grew, totalNow)
            : String(format: "这段变短 %.2fs · 成品共 %.1fs", -grew, totalNow)
        BKLog.shared.i(String(format: "绿区 %d 拖动提交 [%.2f,%.2f] → [%.2f,%.2f]",
                              idx, base.start, base.end, next[idx].start, next[idx].end))
        // 提交后退出编辑态：一次拖动 = 一步撤销 = 一个明确的结束
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.track.exitRegionEdit()
        }
    }

    /// 路②：已经在片头，松手时还被往右拽过 60pt → 换上一条
    func trackDidPullBeyondHead(_ view: BKTrackView) {
        // 加载期间把开关关掉，回来之前不再响应第二次（三个坑里的第一个）
        view.allowsSiblingSwitch = false
        if itemIndex > 0 {
            openItem(at: itemIndex - 1)
        } else {
            // 已经是第一条 / 只有一条素材 → 只回弹，弹到片头那一帧
            view.setPointerTime(0)
            lastTime = 0
            schedulePreroll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { view.allowsSiblingSwitch = true }
    }

    func trackDidPullBeyondTail(_ view: BKTrackView) {
        view.allowsSiblingSwitch = false
        if itemIndex < batch.items.count - 1 {
            openItem(at: itemIndex + 1)
        } else {
            view.setPointerTime(item.duration)
            lastTime = item.duration
            schedulePreroll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { view.allowsSiblingSwitch = true }
    }
}

// MARK: - 概览条回调

extension BKEditorViewController: BKOverviewBarDelegate {

    /// 点 / 拖概览条 = 直接跳到那个位置，**然后就停在那**（静音）
    func overview(_ bar: BKOverviewBar, didSeekTo time: Double) {
        let t = min(max(time, 0), item.duration)
        if playMode != .idle { stopPlayback() }
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        syncPlayhead(to: t)
        schedulePreroll()
    }
}
