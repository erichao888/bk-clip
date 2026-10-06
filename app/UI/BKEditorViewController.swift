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
//        → BKTrackModel.displayPieces 合成 marks → 轨道画出来
//  手动拖边界 / 点片段 / 切口 → 改红区或接缝 → 走 commit() 入撤销栈 → 重画 + 落盘
//
//  【一个草稿 = 一条主轨，这一页只编辑主轨里的其中一块】
//  draft 是整条草稿，blockIndex 指出正在编辑第几块。切换素材 = 换 blockIndex（换 VC 实例），
//  主轨其余块的刀口原封不动地留在 draft.track.blocks 里。
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

    /// 撤销栈快照：块 + 波剪瞬态。
    /// 波剪检测态（阈值/红区）不落盘，但撤销要能回退到上一步显示状态
    private struct EditState {
        var block: BKClipBlock
        var redCuts: [BKRange]
        var thresholdDb: Double
        var autoThresholdDb: Double?
        var sourceApplicable: Bool
        var splits: [Double]
    }

    // MARK: - 状态

    private let asset: AVAsset
    private let probeInfo: BKAssetProbe.Info
    private var draft: BKDraft
    private var blockIndex: Int
    private var envelope: BKEnvelope?

    /// 波剪检测态（瞬态，不落盘）：进页重检测、不记忆上次阈值
    private var thresholdDb: Double = 0
    private var autoThresholdDb: Double?
    private var sourceApplicable: Bool = false
    /// 第一阶段红区（检测出来的气口，瞬态）—— 点「删红」才写成 block.keptRanges
    private var redCuts: [BKRange] = []
    /// 纯显示接缝（不改数据，Q3 拍板）
    private var splits: [Double] = []

    /// 撤销栈。所有编辑改动都从它进出，绝不允许有第二处直接改 draft.track.blocks[i].keptRanges
    private var history = BKHistory<EditState>()
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

    private let thresholdTitle = UILabel()
    private let thresholdSlider = UISlider()
    private let thresholdAutoButton = UIButton(type: .system)
    private let timeLabel = UILabel()
    private let infoLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    // MARK: - 初始化

    init(draft: BKDraft, blockIndex: Int, asset: AVAsset, probeInfo: BKAssetProbe.Info) {
        self.draft = draft
        self.blockIndex = blockIndex
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

    /// 当前正在编辑的块（v2：主轨上的一块）
    private var item: BKClipBlock { draft.track.blocks[blockIndex] }

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

    /// 第一次拿到探针结果时补一次 assetName（几何不存块上，导出时由 BKAssetProbe 实时取）
    private func prepareItem() {
        if item.assetName.isEmpty {
            var b = item
            b.assetName = BKVideoLibrary.assetName(localID: item.assetLocalID)
            draft.track.blocks[blockIndex] = b
        }
        // 指针一律停在片头（检测态瞬态，不记忆上次位置）
        lastTime = 0
    }

    /// 返回起始页时的结算：存草稿 + 生成封面 + 「整草稿没动过刀就丢掉」
    private func finishSession() {
        guard !didDiscard else { return }
        savePlayhead()
        draft.lastEditedAt = Date()

        // 定稿 3.1：整个草稿从头到尾一刀没切 → 不留。
        // 判据是 everEdited（**曾经**动过刀），只置不清
        if !draft.everEdited {
            BKDraftStore.shared.cancelPendingV2()
            BKDraftStore.shared.permanentlyDeleteDraft(draft)
            BKLog.shared.i("整草稿未编辑，已丢弃 \(draft.id.uuidString.prefix(8))")
            return
        }
        BKDraftStore.shared.scheduleSaveV2(draft)
        BKDraftStore.shared.flushV2IfNeeded()

        // 封面 = 当前块、上次停住的那一帧（定稿 3.1）
        let bid = draft.id
        let aid = item.assetLocalID
        let t = lastTime
        BKCovers.generate(asset: asset, at: t) { img in
            guard let img = img else { return }
            BKCovers.save(img, batchId: bid, assetId: aid)
        }
    }

    private func savePlayhead() {
        // 指针为瞬态不落盘；lastAssetId 仅用于起始页「回到上次那条」
        draft.lastAssetId = item.assetLocalID
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
        listItem.isEnabled = draft.track.blocks.count > 1
        navigationItem.leftBarButtonItems = [backItem, listItem]
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
        if draft.track.blocks.count >= 2 {
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
        thresholdSlider.value = Float(thresholdDb)
        thresholdTitle.text = String(format: "阈值 %.1f dB", thresholdDb)
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
            listTable.scrollToRow(at: IndexPath(row: blockIndex, section: 0),
                                  at: .middle, animated: false)
            BKLog.shared.d("打开素材列表，共 \(draft.track.blocks.count) 条")
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

    /// 真正执行移除：从 draft.track.blocks 里删掉当前块（不是「跳过导出」，是真删）。
    /// 和列表面板那套同源 —— BKAssetRowCell 只负责显示，数据只在这一个地方改。
    /// 删完分两种：① 整批空了 → 回起始页并丢草稿；② 还有别的 → 跳到相邻那条继续编
    private func performRemoveCurrent() {
        let removedIndex = blockIndex
        draft.track.blocks.remove(at: removedIndex)
        draft.lastEditedAt = Date()
        BKDraftStore.shared.scheduleSaveV2(draft)
        BKDraftStore.shared.flushV2IfNeeded()

        if draft.track.blocks.isEmpty {
            // 整草稿删空：回起始页，并直接把这份空草稿删掉
            didDiscard = true
            BKDraftStore.shared.cancelPendingV2()
            BKDraftStore.shared.permanentlyDeleteDraft(draft)
            navigationController?.popToRootViewController(animated: true)
            return
        }

        // 跳到相邻那块（和 openItem 同一条「换素材」路径，复用已验证的探针 + 换栈顶逻辑）
        let newIndex = min(removedIndex, draft.track.blocks.count - 1)
        let targetID = draft.track.blocks[newIndex].assetLocalID
        isSwitchingAsset = true
        stopPlayback()
        BKVideoLibrary.loadAVAsset(localID: targetID) { [weak self] asset in
            guard let self = self else { return }
            self.isSwitchingAsset = false
            guard let asset = asset, let nav = self.navigationController else { return }
            let probe = BKAssetProbe.probe(asset)
            // 几何不落块，只保证 srcDuration 一致（防 probe 偏差导致坐标错位）
            var bb = self.draft
            if probe.duration > 0, abs(bb.track.blocks[newIndex].srcDuration - probe.duration) > 0.05 {
                bb.track.blocks[newIndex].srcDuration = probe.duration
            }
            bb.lastAssetId = targetID
            let vc = BKEditorViewController(draft: bb, blockIndex: newIndex, asset: asset, probeInfo: probe)
            var stack = nav.viewControllers
            if stack.last === self { stack.removeLast() }
            stack.append(vc)
            nav.setViewControllers(stack, animated: true)
            BKLog.shared.i("移除第 \(removedIndex + 1) 块，跳到第 \(newIndex + 1)/\(bb.track.blocks.count) 块")
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
                if t.x < 0 { openItem(at: blockIndex + 1) } else { openItem(at: blockIndex - 1) }
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
        guard index >= 0, index < draft.track.blocks.count else { return }
        guard !isSwitchingAsset else {
            // 加载锁：上一次还没回来，直接短路返回，不排队
            BKLog.shared.d("换素材被锁：上一次还没加载完")
            return
        }
        isSwitchingAsset = true
        stopPlayback()
        savePlayhead()
        BKDraftStore.shared.flushV2IfNeeded()

        let targetID = draft.track.blocks[index].assetLocalID
        BKVideoLibrary.loadAVAsset(localID: targetID) { [weak self] asset in
            guard let self = self else { return }
            self.isSwitchingAsset = false
            guard let asset = asset, let nav = self.navigationController else {
                BKLog.shared.e("切换素材失败：\(targetID)")
                return
            }
            let probe = BKAssetProbe.probe(asset)
            BKLog.shared.i(probe.logLine)

            var b = self.draft
            if probe.duration > 0, abs(b.track.blocks[index].srcDuration - probe.duration) > 0.05 {
                b.track.blocks[index].srcDuration = probe.duration
            }
            b.lastAssetId = targetID
            b.lastEditedAt = Date()

            let vc = BKEditorViewController(draft: b, blockIndex: index, asset: asset, probeInfo: probe)
            var stack = nav.viewControllers
            if stack.last === self { stack.removeLast() }
            stack.append(vc)
            nav.setViewControllers(stack, animated: true)
            BKLog.shared.i("切换到第 \(index + 1)/\(b.track.blocks.count) 块：\(b.track.blocks[index].assetName)")
        }
    }

    // MARK: - 提交与撤销

    // MARK: - 提交与撤销

    /// 抓当前完整编辑态（块 + 波剪瞬态）。撤销要能回退到上一步显示状态
    private func captureState() -> EditState {
        EditState(block: item, redCuts: redCuts, thresholdDb: thresholdDb,
                  autoThresholdDb: autoThresholdDb, sourceApplicable: sourceApplicable,
                  splits: splits)
    }

    /// 把一份编辑态写回：块落盘（必要时标 everEdited）+ 瞬态恢复 + 刷新
    private func applyState(_ s: EditState) {
        draft.track.blocks[blockIndex] = s.block
        draft.lastEditedAt = Date()
        // everEdited **只置不清**：撤销是把刀撤掉，不是把「我编辑过这件事」抹掉
        if s.block.isWaveCut { draft.everEdited = true }
        redCuts = s.redCuts
        thresholdDb = s.thresholdDb
        autoThresholdDb = s.autoThresholdDb
        sourceApplicable = s.sourceApplicable
        splits = s.splits
        refreshTrack()
        updateInfo()
        updateUndoButtons()
        BKDraftStore.shared.scheduleSaveV2(draft)
    }

    private func commit(_ s: EditState, coalesce: Bool = false) {
        if coalesce && boundaryDragging {
            // 一次拖动只占一格：第一帧 push，之后 amend。
            // 反过来（先 amend）会把拖动前的状态覆盖掉，那一步就永远撤不回来了
            if boundaryCommitted {
                history.amend(s)
            } else {
                history.push(s)
                boundaryCommitted = true
            }
        } else {
            history.push(s)
        }
        applyState(s)
    }

    @objc private func undoTapped() {
        guard let restored = history.undo() else { return }
        applyState(restored)
        statusLabel.text = "已撤销"
        BKLog.shared.i("撤销 → 栈内第 \(history.depth) 格")
    }

    @objc private func redoTapped() {
        guard let restored = history.redo() else { return }
        applyState(restored)
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

    /// 把第一阶段红区写回（瞬态，不落盘；落盘只发生在「删红」写 keptRanges 时）
    private func applyRedCuts(_ cuts: [BKRange], coalesce: Bool = false) {
        redCuts = BKTrackModel.mergeRanges(cuts, duration: item.duration)
        commit(captureState(), coalesce: coalesce)
    }

    /// 按一下，就从**橙色指针现在指的地方**把轨道切开。
    ///
    /// 【切开 ≠ 删除】切口不进 cutRanges，所以导出时长纹丝不动。
    /// 它的作用是把一段划成两段，好让你单独处理其中一半
    @objc private func cutTapped() {
        let t = min(max(lastTime, 0), item.duration)

        guard t > 0.05, t < item.duration - 0.05 else {
            statusLabel.text = "指针太靠两头了，这里切不出东西"
            return
        }
        guard !splits.contains(where: { abs($0 - t) < 0.05 }) else {
            statusLabel.text = "这里已经有一道切口了"
            return
        }

        // 纯显示接缝（Q3 拍板）：不改 keptRanges，只画一条分割线
        splits.append(t)
        splits.sort()
        statusLabel.text = String(format: "在 %.2fs 处加了一道分割线（仅显示）", t)
        BKLog.shared.i(String(format: "手动接缝 %.2fs（现有 %d 道）", t, splits.count))
        refreshTrack()
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
        let cuts = redCuts
        guard !cuts.isEmpty else {
            statusLabel.text = "当前没有红区可删"
            return
        }

        // 记录A（红区）→ 记录B（绿区）：v2 唯一一次坐标系转换，做完就冻结
        let keeps = BKTrackModel.keptFromRed(cuts, duration: item.duration)
        guard !keeps.isEmpty else {
            statusLabel.text = "没有可保留的绿区"
            return
        }

        var p = item
        p.keptRanges = keeps
        // 删红后红区并入绿区，瞬态红区清空
        commit(EditState(block: p, redCuts: [], thresholdDb: thresholdDb,
                         autoThresholdDb: autoThresholdDb, sourceApplicable: sourceApplicable,
                         splits: splits))

        let total = keeps.reduce(0.0) { $0 + $1.length }
        let keepDesc = keeps.map { String(format: "%.2f→%.2f", $0.start, $0.end) }
        BKLog.shared.i(String(format:
            "一键去红：删 %d 段 → 留 %d 段绿区，成品 %.2fs（原片 %.2fs）| 绿区区间: %@",
            cuts.count, keeps.count, total, item.duration, keepDesc.joined(separator: " ")))
        BKLog.shared.i(String(format:
            "红区区间: %@", cuts.map { String(format: "%.2f→%.2f", $0.start, $0.end) }
                .joined(separator: " ")))

        let edgeNote = (keeps.first?.start ?? 0) < 0.01
            ? "（首段贴素材开头，其前无绿区）" : ""
        statusLabel.text = String(format: "已删 %d 段气口，剩 %d 段绿区 · 成品 %.1fs · 长按可调长短%@",
                                  cuts.count, keeps.count, total, edgeNote)
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
        let shown = BKTrackModel.displayPieces(stage2: false, kept: [], red: redCuts,
                                               splits: splits, duration: p.duration)
        for pc in shown where time >= pc.start && time <= pc.end {
            var cuts = redCuts

            if pc.kind == .cut {
                cuts.removeAll { abs($0.start - pc.start) < 1e-6 && abs($0.end - pc.end) < 1e-6 }
                statusLabel.text = String(format: "恢复 %.2f~%.2fs", pc.start, pc.end)
                BKLog.shared.i(String(format: "恢复 %.2f~%.2fs", pc.start, pc.end))
            } else {
                guard (pc.end - pc.start) >= BKConfig.Detect.minCut else {
                    statusLabel.text = String(format: "这段只有 %.2fs，短于 %.2fs，不动它",
                                              pc.end - pc.start, BKConfig.Detect.minCut)
                    return
                }
                cuts.append(BKRange(pc.start, pc.end))
                statusLabel.text = String(format: "删掉 %.2f~%.2fs", pc.start, pc.end)
                BKLog.shared.i(String(format: "删掉 %.2f~%.2fs", pc.start, pc.end))
            }
            applyRedCuts(cuts)
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
                // v2：检测态瞬态，进页即重跑检测（不恢复上次阈值/红区）
                self.history.reset(self.captureState())
                self.runDetection(override: nil)
                BKDraftStore.shared.markDraftOpened(self.draft.id)
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

        let dur = item.duration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = BKDetector.detect(envelope: env,
                                            totalDuration: dur,
                                            overrideThreshold: override)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.spinner.stopAnimating()
                self.redCuts = BKTrackModel.mergeRanges(
                    outcome.cuts.map { BKRange($0.0, $0.1) }, duration: dur)
                self.thresholdDb = outcome.info.thresholdDb
                if override == nil {
                    // 记下这次自动算出来的**实际使用值**（夹逼之后的）——
                    // 「恢复自动」要回到的就是它，不是未夹逼的原始 Otsu
                    self.autoThresholdDb = outcome.info.thresholdDb
                }
                self.sourceApplicable = outcome.info.applicable

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
                self.commit(self.captureState())
                self.updateThresholdAutoButton()
            }
        }
    }

    /// 轨道 + 概览条一起刷新。分开刷迟早会出现「轨道已经切了，概览条还画着旧的」
    private func refreshTrack() {
        let p = item
        // v2：第一阶段红绿交替（含红区，可拖红区边缘），第二阶段只有绿区，
        // 画布时间轴**始终是原片时长**（零换算）。
        let stage2 = p.isStage2
        let shown = BKTrackModel.displayPieces(stage2: stage2,
                                               kept: p.keptRanges,
                                               red: redCuts,
                                               splits: splits,
                                               duration: p.duration)
        track.setContent(envelope: envelope,
                         pieces: shown,
                         splits: stage2 ? [] : splits,
                         duration: p.duration,
                         thresholdDb: thresholdDb,
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
    /// 【v1.3.4】`item.keptRanges` 已按阶段自动取记录（第二阶段返回记录B），
    /// 所以这里不用再判阶段，也不用换算坐标系。
    @objc private func jointTapped() {
        if playMode == .joint { stopPlayback(); return }
        stopPlayback()

        let keeps = item.keptRanges.map { ($0.start, $0.end) }
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
        guard let auto = autoThresholdDb else {
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
        guard let auto = autoThresholdDb else {
            thresholdAutoButton.isEnabled = false
            thresholdAutoButton.alpha = 0.30
            return
        }
        let isAuto = abs(thresholdDb - auto) < 0.01
        thresholdAutoButton.isEnabled = !isAuto
        thresholdAutoButton.alpha = isAuto ? 0.30 : 1.0
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
        draft.track.blocks.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: "BKAssetRowCell", for: indexPath) as? BKAssetRowCell else {
            return UITableViewCell()
        }
        let it = draft.track.blocks[indexPath.row]
        let isCurrent = (indexPath.row == blockIndex)

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
        guard indexPath.row != blockIndex else {
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
        guard let next = BKTrackModel.moveRedEdge(cuts: redCuts,
                                                  near: near,
                                                  to: newTime,
                                                  duration: item.duration) else { return }
        applyRedCuts(next, coalesce: true)
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
        guard let next = BKTrackModel.resizeKept(p.keptRanges,
                                                 at: idx,
                                                 isHead: edge == .head,
                                                 to: newTime,
                                                 duration: p.duration,
                                                 minSeg: BKConfig.RegionEdit.minSegmentSec) else {
            statusLabel.text = "拖不过去了（会越界或短于 0.1 秒）"
            return
        }

        var q = item
        q.keptRanges = next
        commit(EditState(block: q, redCuts: redCuts, thresholdDb: thresholdDb,
                          autoThresholdDb: autoThresholdDb, sourceApplicable: sourceApplicable,
                          splits: splits))

        // ⚠️ 显式 Double(...)：`Segment.duration` 与 Swift 内置的同名类型会撞，
        // 推断出来的类型不满足 String(format:) 要的 CVarArg。
        let grew = Double(next[idx].length) - Double(p.keptRanges[idx].length)
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
        if blockIndex > 0 {
            openItem(at: blockIndex - 1)
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
        if blockIndex < draft.track.blocks.count - 1 {
            openItem(at: blockIndex + 1)
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
