//
//  BKMainEditorViewController.swift
//  bk剪辑 — v2 主编辑页（多片段主轨 + 上下文底栏）
//
//  【这一页的心智：底栏是「当前框选区块」的函数】
//  底部按钮永远作用于当前蓝框里的那一块，而不是一个固定的全局工具栏。
//  主轨区块被拖动经过中央指针时自动出蓝框 —— **不需要先点选**（规格 §0）。
//  所以这里绝大部分状态都跟着 `trackView.selectedIndex` 走。
//
//  【本批（2B 第一段）做到哪】
//    ✅ 多片段主轨（BKMainTrackView）· 自动蓝框 · 10 键上下文底栏 · 点「波剪」进波剪子页
//    ✅ 分割 / 复制 / 删除 三个真能用的键
//    ⏸ 音量·画面大小·旋转·左右镜像·变速·录音：底栏先占位（灰），面板属规格「第二批」
//    ⏸ 录音轨 / 画中画轨 UI：5 键 / 9 键的分支骨架已按规格写好（currentBarTrack），
//       但侧轨还没有数据入口，所以暂时恒为主轨 10 键
//    ⏸ 播放：整条主轨要跨素材合成，和第二段的导出管线是同一个 builder，一并做
//
//  【和波剪子页的分工】
//  这一页管「结构」：这条片子由哪几块组成、顺序、切分。
//  波剪子页管「某一块内部」：气口在哪、删掉哪几段。
//  点「波剪」把 draft + blockIndex 交给 BKEditorViewController（2A 已改成直吃 v2）。
//
//  【⚠️ 值类型来回传：为什么从波剪子页回来要重载草稿】
//  BKDraft 是 struct，push 给波剪子页的是一份**拷贝**，它改的是自己那份。
//  它在 finishSession 里已经 flush 到磁盘，所以这里在 viewWillAppear 从磁盘重载，
//  拿回最新的块。不重载的话，主编辑页会一直显示进波剪之前的旧时长。
//

import UIKit

// MARK: - 底栏上下文

/// 三条轨（底栏显示哪套键由它决定）
private enum BKTrackKind { case main, pip, rec }

/// 底栏一个键
private struct BKBottomKey {
    let id: String
    /// SF Symbols 名。**单线条图标、不带文字**（皓哥定的控件风格）
    let icon: String
    let label: String
    /// 本批是否已实现。false = 占位（灰），面板属规格第二批
    let live: Bool
}

final class BKMainEditorViewController: UIViewController {

    private var draft: BKDraft

    /// 底栏当前显示哪套键（只在上下文真的变了才重建按钮）
    private var barTrack: BKTrackKind = .main
    /// 侧轨选中。本批不做侧轨 UI，这两个恒为 nil → currentBarTrack() 恒返回 .main
    private var selectedPipId: UUID? = nil
    private var selectedRecId: UUID? = nil
    private var selectedTrack: BKTrackKind = .main

    /// 整草稿已丢弃（finishSession 里删空后短路，避免又存回去）
    private var didDiscard = false

    private let previewContainer = UIView()
    private let posterView = UIImageView()
    private let trackView = BKMainTrackView()
    private let barScroll = UIScrollView()
    private let barContent = UIView()
    private let timeLabel = UILabel()
    private let statusLabel = UILabel()

    // MARK: - 初始化

    init(draft: BKDraft) {
        self.draft = draft
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("本 App 不走 storyboard") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BKTheme.Color.page
        setupNav()
        setupUI()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        // 同波剪页：边缘右滑返回会和拖轨道打架（真机实测拖到一半页面退回去了）
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        // ★ 从波剪子页回来：它已 flush 到磁盘，这里重载拿最新块（见文件头注释）
        if let fresh = BKDraftStore.shared.loadDraft(id: draft.id) {
            draft = fresh
            reload()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        if isMovingFromParent { finishSession() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layout()
    }

    // MARK: - 布局（一律用 frame，跟工程其余页面保持一致）

    private func layout() {
        let w = view.bounds.width
        let h = view.bounds.height
        // 导航栏高度：没拿到就按 44 算，布局差几 pt 不会出事
        let navH: CGFloat = navigationController?.navigationBar.frame.height ?? 44
        let top = view.safeAreaInsets.top + navH
        let bottomSafe = view.safeAreaInsets.bottom
        let barH: CGFloat = 64

        let previewH: CGFloat = max(150, min(260, (h - top - bottomSafe) * 0.36))
        previewContainer.frame = CGRect(x: 0, y: top, width: w, height: previewH)
        posterView.frame = previewContainer.bounds

        let trackY = previewContainer.frame.maxY + 10
        trackView.frame = CGRect(x: 0, y: trackY, width: w, height: 92)

        timeLabel.frame = CGRect(x: 12, y: trackView.frame.maxY + 6, width: w - 24, height: 18)
        statusLabel.frame = CGRect(x: 12, y: timeLabel.frame.maxY + 2, width: w - 24, height: 18)

        barScroll.frame = CGRect(x: 0, y: h - bottomSafe - barH, width: w, height: barH)
    }

    private func setupUI() {
        previewContainer.backgroundColor = BKTheme.Color.preview
        view.addSubview(previewContainer)

        posterView.contentMode = .scaleAspectFit
        posterView.clipsToBounds = true
        previewContainer.addSubview(posterView)

        trackView.delegate = self
        view.addSubview(trackView)

        timeLabel.font = BKTheme.Font.mono
        timeLabel.textColor = BKTheme.Color.text2
        view.addSubview(timeLabel)

        statusLabel.font = BKTheme.Font.caption
        statusLabel.textColor = BKTheme.Color.text2
        statusLabel.lineBreakMode = .byTruncatingTail
        view.addSubview(statusLabel)

        barScroll.backgroundColor = BKTheme.Color.bar
        barScroll.showsHorizontalScrollIndicator = false
        barScroll.addSubview(barContent)
        view.addSubview(barScroll)

        // 底栏上沿分隔线：把工具栏从页面上分出来
        let line = UIView()
        line.backgroundColor = BKTheme.Color.line
        line.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 1)
        line.autoresizingMask = [.flexibleWidth]
        barScroll.addSubview(line)

        rebuildBar()
    }

    private func setupNav() {
        let first = draft.track.blocks.first?.assetName ?? ""
        navigationItem.title = draft.displayTitle(firstName: first)

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.backward"),
            style: .plain, target: self, action: #selector(closeTapped))

        // 导出归主编辑页（2A 已把波剪子页的导出键去掉）。
        // 管线本体在第二段接 v2，这里先把入口挂上
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "导出", style: .plain, target: self, action: #selector(exportTapped))
    }

    // MARK: - 数据 → 界面

    /// 重新铺轨 + 选中 + 刷底栏/信息。select 不传 = 尽量保持当前选中
    private func reload(select: Int? = nil) {
        let n = draft.track.blocks.count
        trackView.setContent(blocks: draft.track.blocks)
        guard n > 0 else {
            trackView.selectedIndex = nil
            refreshBar()
            updateInfo()
            return
        }
        var idx = 0
        if let s = select {
            idx = min(max(s, 0), n - 1)
        } else if let cur = trackView.selectedIndex {
            idx = min(cur, n - 1)
        } else if let lid = draft.lastAssetId,
                  let i = draft.track.blocks.firstIndex(where: { $0.assetLocalID == lid }) {
            idx = i
        }
        trackView.selectedIndex = idx
        trackView.scrollToBlock(at: idx, autoFrame: false)
        refreshBar()
        updateInfo()
    }

    private func updateInfo() {
        let n = draft.track.blocks.count
        timeLabel.text = String(format: "%d 段 · 总 %@", n, formatClock(draft.track.total))

        guard let i = trackView.selectedIndex, i < n else {
            statusLabel.text = "拖动轨道让指针经过某个区块，或点它选中"
            posterView.image = nil
            return
        }
        let b = draft.track.blocks[i]
        statusLabel.text = String(format: "第 %d/%d 段 · %@ · %@",
                                  i + 1, n, b.assetName, formatClock(b.timelineDuration))

        // 预览海报 = 这一段的第一帧。回调可能晚到，回来时先核对还是不是这一段
        BKThumbnails.image(localID: b.assetLocalID,
                           size: CGSize(width: 640, height: 360),
                           networkAllowed: true) { [weak self] img in
            guard let self = self else { return }
            guard self.trackView.selectedIndex == i else { return }
            self.posterView.image = img
        }
    }

    // MARK: - 底栏

    /// 规格 §1.1：默认必须是主轨，不是"没选中就空"—— 这是「底栏永远有 10 键可用」的前提
    private func currentBarTrack() -> BKTrackKind {
        if selectedTrack == .pip, selectedPipId != nil { return .pip }
        if selectedTrack == .rec, selectedRecId != nil { return .rec }
        return .main
    }

    private func keys(for track: BKTrackKind) -> [BKBottomKey] {
        switch track {
        case .main:
            // 规格 §1.1 主轨 10 键，顺序照抄
            return [
                BKBottomKey(id: "cut",       icon: "scissors",            label: "分割",     live: true),
                BKBottomKey(id: "wave",      icon: "waveform",            label: "波剪",     live: true),
                BKBottomKey(id: "volume",    icon: "speaker.wave.2",      label: "音量",     live: false),
                BKBottomKey(id: "size",      icon: "aspectratio",         label: "画面大小", live: false),
                BKBottomKey(id: "rotate",    icon: "rotate.right",        label: "旋转",     live: false),
                BKBottomKey(id: "mirror",    icon: "arrow.left.and.right", label: "左右镜像", live: false),
                BKBottomKey(id: "speed",     icon: "speedometer",         label: "变速",     live: false),
                BKBottomKey(id: "duplicate", icon: "doc.on.doc",          label: "复制",     live: true),
                BKBottomKey(id: "delete",    icon: "trash",               label: "删除",     live: true),
                BKBottomKey(id: "record",    icon: "mic",                 label: "录音",     live: false)
            ]
        case .pip:
            // 画中画 9 键（比主轨少「波剪」「录音」，多「替换」）
            return [
                BKBottomKey(id: "cut",       icon: "scissors",            label: "分割",     live: false),
                BKBottomKey(id: "volume",    icon: "speaker.wave.2",      label: "音量",     live: false),
                BKBottomKey(id: "replace",   icon: "arrow.triangle.2.circlepath", label: "替换", live: false),
                BKBottomKey(id: "size",      icon: "aspectratio",         label: "画面大小", live: false),
                BKBottomKey(id: "rotate",    icon: "rotate.right",        label: "旋转",     live: false),
                BKBottomKey(id: "mirror",    icon: "arrow.left.and.right", label: "左右镜像", live: false),
                BKBottomKey(id: "speed",     icon: "speedometer",         label: "变速",     live: false),
                BKBottomKey(id: "duplicate", icon: "doc.on.doc",          label: "复制",     live: false),
                BKBottomKey(id: "delete",    icon: "trash",               label: "删除",     live: false)
            ]
        case .rec:
            // 录音 5 键（无画面，所以没有画面类键）
            return [
                BKBottomKey(id: "cut",       icon: "scissors",       label: "分割", live: false),
                BKBottomKey(id: "volume",    icon: "speaker.wave.2", label: "音量", live: false),
                BKBottomKey(id: "duplicate", icon: "doc.on.doc",     label: "复制", live: false),
                BKBottomKey(id: "record",    icon: "mic",            label: "录音", live: false),
                BKBottomKey(id: "delete",    icon: "trash",          label: "删除", live: false)
            ]
        }
    }

    private func rebuildBar() {
        barContent.subviews.forEach { $0.removeFromSuperview() }
        // 规格 §1.2：单键 42×48、间距 1、圆角 12、横滑不换行不压缩
        var x: CGFloat = 8
        for k in keys(for: barTrack) {
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: k.icon), for: .normal)
            b.tintColor = (k.id == "delete") ? BKTheme.Color.danger : BKTheme.Color.text2
            b.accessibilityIdentifier = k.id
            b.accessibilityLabel = k.label
            b.layer.cornerRadius = 12
            b.addTarget(self, action: #selector(barTapped(_:)), for: .touchUpInside)
            b.frame = CGRect(x: x, y: 8, width: 42, height: 48)
            barContent.addSubview(b)
            x += 43
        }
        // 10 键 424pt 在 430pt 屏上必然溢出 → 靠横滑，绝不压缩
        barContent.frame = CGRect(x: 0, y: 0, width: x + 8, height: 64)
        barScroll.contentSize = barContent.bounds.size
        updateBarEnabled()
    }

    private func refreshBar() {
        let t = currentBarTrack()
        if t != barTrack {
            barTrack = t
            rebuildBar()
        } else {
            updateBarEnabled()
        }
    }

    private func updateBarEnabled() {
        let hasSel = (trackView.selectedIndex != nil)
        let canDelete = hasSel && draft.track.blocks.count > 1
        for v in barContent.subviews {
            guard let b = v as? UIButton else { continue }
            let id = b.accessibilityIdentifier ?? ""
            let on: Bool
            switch id {
            case "cut":       on = hasSel
            case "wave":      on = hasSel
            case "duplicate": on = hasSel
            case "delete":    on = canDelete
            default:          on = false      // 本批未接的面板键 / 侧轨键，统一置灰
            }
            b.isEnabled = on
            b.alpha = on ? 1.0 : 0.35
        }
    }

    @objc private func barTapped(_ sender: UIButton) {
        switch sender.accessibilityIdentifier ?? "" {
        case "cut":       cutTapped()
        case "wave":      openWaveCut()
        case "duplicate": duplicateTapped()
        case "delete":    deleteTapped()
        default:
            // ⚠️ 别在字符串插值里再套一层带引号的字面量，长串拼接容易触发类型检查超时
            let nm = sender.accessibilityLabel ?? "这个键"
            statusLabel.text = "「" + nm + "」在后续批次接入"
        }
    }

    // MARK: - 编辑动作（全部走 BKTrackModel，不直接写源时间）

    private func cutTapped() {
        let t = trackView.centerTime
        guard draft.track.cut(at: t) else {
            statusLabel.text = "指针正好压在段边界上，这里切不开"
            return
        }
        draft.everEdited = true
        save()
        reload(select: trackView.selectedIndex)     // 切开后仍选中左边那半
        statusLabel.text = String(format: "已在 %.2fs 处切开 → 现在 %d 段",
                                  t, draft.track.blocks.count)
        BKLog.shared.i(String(format: "主轨切开 @%.2fs → %d 段", t, draft.track.blocks.count))
    }

    private func duplicateTapped() {
        guard let i = trackView.selectedIndex, i < draft.track.blocks.count else { return }
        var copy = draft.track.blocks[i]
        copy.id = UUID()          // ★ 必须换新 id：块 id 是叠加轨锚定的主键，重复会锚错
        draft.track.insert(copy, at: i + 1)
        draft.everEdited = true
        save()
        reload(select: i + 1)
        // ★ 规格 §1.7 验收点：复制后**新段**要处于选中态。
        //   reload 里走的是 scrollToBlock(autoFrame:false)，自动蓝框让位，选中不会被指针抢回去
        statusLabel.text = "已复制这一段"
    }

    private func deleteTapped() {
        guard let i = trackView.selectedIndex, i < draft.track.blocks.count else { return }
        guard draft.track.blocks.count > 1 else {
            statusLabel.text = "只剩这一段了，删掉草稿就空了"
            return
        }
        draft.track.removeBlock(at: i)
        draft.everEdited = true
        save()
        reload(select: min(i, draft.track.blocks.count - 1))
        statusLabel.text = "已删除这一段"
    }

    /// 进波剪子页：把 draft + blockIndex 交过去（2A 已改成直吃 v2）
    private func openWaveCut() {
        guard let i = trackView.selectedIndex, i < draft.track.blocks.count else { return }
        let b = draft.track.blocks[i]
        // 先把主轨的改动落盘，免得波剪子页读到旧草稿
        BKDraftStore.shared.flushV2IfNeeded()

        BKVideoLibrary.loadAVAsset(localID: b.assetLocalID) { [weak self] asset in
            guard let self = self else { return }
            guard let asset = asset else {
                self.statusLabel.text = "这条素材读不到，可能已经从相册里删掉了"
                return
            }
            let probe = BKAssetProbe.probe(asset)
            BKLog.shared.i(probe.logLine)
            // 从 handleImported 挪过来的告警：主轨排版不需要音轨，
            // 但**波剪**是靠音轨找呼吸停顿的，所以到这一步才判
            guard probe.hasAudio else {
                self.statusLabel.text = "这条视频没有声音，没法自动找气口"
                return
            }
            let vc = BKEditorViewController(draft: self.draft, blockIndex: i,
                                            asset: asset, probeInfo: probe)
            self.navigationController?.pushViewController(vc, animated: true)
        }
    }

    @objc private func exportTapped() {
        // 第二段（导出管线迁 v2）接进来后这里直接调 v2 导出面板
        statusLabel.text = "导出管线在本批第二段接入（v2 多轨合成）"
    }

    @objc private func closeTapped() {
        navigationController?.popViewController(animated: true)
    }

    // MARK: - 落盘

    private func save() {
        draft.lastEditedAt = Date()
        BKDraftStore.shared.scheduleSaveV2(draft)
    }

    /// 返回起始页时的结算：定稿 3.1 —— 整草稿一刀没动过就不留
    private func finishSession() {
        guard !didDiscard else { return }
        if !draft.everEdited {
            BKDraftStore.shared.cancelPendingV2()
            BKDraftStore.shared.permanentlyDeleteDraft(draft)
            didDiscard = true
            BKLog.shared.i("主编辑页：整草稿未编辑，已丢弃 \(draft.id.uuidString.prefix(8))")
            return
        }
        draft.lastEditedAt = Date()
        BKDraftStore.shared.scheduleSaveV2(draft)
        BKDraftStore.shared.flushV2IfNeeded()
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

// MARK: - 主轨回调

extension BKMainEditorViewController: BKMainTrackViewDelegate {

    /// 自动蓝框改了选中（手拖轨道经过指针）。底栏与信息随之刷新
    func mainTrack(_ view: BKMainTrackView, didAutoSelectBlockAt index: Int?) {
        refreshBar()
        updateInfo()
    }

    /// 点区块 = 选中 + 三轨同步滚动让它居中。
    /// ⚠️ 这次滚动是**程序化**的，必须 autoFrame:false，否则刚点的会被指针下的旧块抢回去
    func mainTrack(_ view: BKMainTrackView, didTapBlockAt index: Int) {
        view.selectedIndex = index
        view.scrollToBlock(at: index, autoFrame: false)
        refreshBar()
        updateInfo()
    }

    /// 点空白 = 取消选中，底栏回主轨 10 键
    func mainTrackDidTapBlank(_ view: BKMainTrackView) {
        view.selectedIndex = nil
        refreshBar()
        updateInfo()
    }
}
