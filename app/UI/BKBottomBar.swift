//
//  BKBottomBar.swift
//  bk剪辑 — v1.5.7 上下文底栏（第一批：底栏骨架）
//
//  规格真源：`docs/上下文底栏与参数面板-实现规格.md §1.1~§1.7`
//  规格补充：`docs/规格补充A-数值状态机吸附与状态清单.md §2.1 / §2.3`
//  行为真源：`ref/proto-2026-10-06-125e64d9/index.html`（sha 125e64d929c8d37f…）
//  机器可读契约：`ref/bottombar-spec.json`（本文件与之逐项对齐，
//                由 `tools/verify_barbar_swift.py` 交叉校验）
//
//  ═══════════════════════════════════════════════════════════════════════
//  核心心智（做歪了就全废，先读这段）
//  ═══════════════════════════════════════════════════════════════════════
//  **底栏 = 当前上下文的函数，不是固定的全局工具栏。**
//  底部按钮永远作用于「当前框选的区块」：
//      · 主轨（默认）  → 10 键
//      · 画中画选中    →  9 键
//      · 录音轨选中    →  5 键
//  主轨区块被拖动经过中央指针时**自动出蓝框**，无需先点选。
//
//  ⚠️ **默认必须是主轨**，不是"没选中就空"。
//     这是「底栏永远有 10 键可用」的前提（规格 §1.1）。
//
//  ═══════════════════════════════════════════════════════════════════════
//  ★ 约束（都是原型里实际踩出来的，别自行去掉）
//  ═══════════════════════════════════════════════════════════════════════
//  ★1 蓝框只在「跨过区块边界」时重绘，不要每像素重绘。
//     本文件对应：`BKSelectionState` 变化时的等值短路（见 `selection` 的 didSet）。
//
//  ★2 程序化滚动必须让位自动蓝框 → `autoFrameLock`（宿主侧实现）。
//
//  ★3 scrollTo 必须夹取 [0, maxScrollPx]，否则边界处区块无法居中（宿主侧实现）。
//
//  ★4 底栏 / 工具面板必须在「点空白关菜单」排除名单里
//     ← 见本文件的 `containsTouch(_:in:)`。
//     ⚠️ 这条极易漏：若底栏没在排除名单里，用户按下音量键的瞬间选中态就被清空，
//     面板拿到空目标会**静默失败——不报错、无提示**，表现为"点了没反应"。
//
//  ★5 pointerdown 要 setPointerCapture + preventDefault，否则 iOS 滑动手势抢走拖动。
//     iOS 对应：对"点按"用 UIButton 触摸事件而非 pan 手势；
//     底栏自身横滑用 UIScrollView 的 pan，两者互不抢（见 setup()）。
//
//  ★6 变速刻度必须用对数映射（本文件不涉及，见变速面板）。
//

import UIKit

// MARK: - 轨道种类

/// 三条轨。原型的 `selTrack` 取值 `'main' / 'pip' / 'rec'`。
///
/// ⚠️ 这是**全新类型**：本次改动前 `grep TrackKind app/` 是 0 命中，
///    `BKTrackModel` 是单素材模型、`BKTrackView` 是波剪页，都不含轨道具名。
enum BKTrackKind: String, CaseIterable {
    case main
    case pip
    case rec

    var displayName: String {
        switch self {
        case .main: return "主轨"
        case .pip:  return "画中画"
        case .rec:  return "录音"
        }
    }
}

// MARK: - 底栏键定义

/// 一个底栏键。
///
/// 原型里长这样（`TOOLBARS` / `index.html`）：
/// ```js
/// {ic:'ic-scissors', t:'切割', fn:()=>cutAtPointer('main')}
/// {ic:'ic-trash',    t:'删除', fn:()=>delFramed('main'), del:true}
/// ```
struct BKBottomBarItem {
    /// 语义动作。**不存闭包** —— 闭包无法等值比较，会导致
    /// 「上下文没变却重建底栏」，也会让 XCTest 无法断言键位表。
    let action: BKBottomBarAction
    /// 键名（原型 `t`），同时用作 accessibilityLabel / title
    let title: String
    /// 是否标红（原型 `del:true`）
    let isDestructive: Bool

    init(_ action: BKBottomBarAction, _ title: String, destructive: Bool = false) {
        self.action = action
        self.title = title
        self.isDestructive = destructive
    }
}

/// 底栏语义动作。
///
/// ⚠️ **这不是 UI 细节，是契约**：`ref/bottombar-spec.json` 里 23 个动作名
///    与下面的 case 一一对应，XCTest 直接遍历断言。
///    漏一个 case 就会在真机上表现为"某个键点了没反应"。
enum BKBottomBarAction: String, CaseIterable {
    case cut
    case waveCut
    case volume
    case size
    case rotate
    case flip
    case speed
    case copy
    case delete
    case record
    case replace

    /// SF Symbols 名。
    ///
    /// 规格 §1.3 要求「SF Symbols 单线条图标，不带文字」。
    /// 原型用自绘 SVG（`ic-scissors / ic-wavecut / ic-mute2 / …`），
    /// 这里映射到语义最接近的系统符号。
    ///
    /// ⚠️ **命名保守是有原因的**：本项目 `deploymentTarget` 是 **iOS 15.0**
    ///    （见 `project.yml`）。很多"新式"符号名是 iOS 16/17 才加的，例如
    ///    `gauge.with.dots.needle.67percent`（iOS 16+）、`waveform.path`（iOS 16+）。
    ///    在 iOS 15 上 `UIImage(systemName:)` 返回 **nil** —— 按钮不报错、
    ///    只是**变空白**，且只有真机才看得见，极难排查。
    ///
    ///    所以策略是：**优先用最保守的老符号名**，并在 `makeKeyButton` 里
    ///    做 nil 兜底（退化成文字键）。宁可字丑，也绝不留一个点不动的空白键。
    var symbolName: String {
        switch self {
        case .cut:     return "scissors"                            // iOS 13+
        case .waveCut: return "waveform"                            // iOS 13+（waveform.path 是 16+）
        case .volume:  return "speaker.wave.2"                      // iOS 13+
        case .size:    return "arrow.up.left.and.arrow.down.right"   // iOS 13+
        case .rotate:  return "rotate.right"                        // iOS 14+
        case .flip:    return "arrow.left.and.right"                // iOS 13+（镜像无稳妥老符号，先用双向箭头）
        case .speed:   return "speedometer"                         // iOS 13+
        case .copy:    return "doc.on.doc"                          // iOS 13+
        case .delete:  return "trash"                               // iOS 13+（与 BKRootViewController 一致）
        case .record:  return "mic"                                 // iOS 13+
        case .replace: return "arrow.2.squarepath"                  // iOS 13+（不用 arrow.triangle.2.circlepath）
        }
    }
}

// MARK: - 三套键位表（规格 §1.1 唯一真源）

/// 底栏键位表。
///
/// 与 `ref/bottombar-spec.json` **逐项一致**，
/// 由 `tools/verify_bottombar_spec.py` + `tools/verify_barbar_swift.py` 机械校验。
/// 改这里必须同时改规格文档 §1.1 与原型，否则校验脚本会报失败。
enum BKBottomBarSpec {

    /// 主轨 10 键（**默认**）
    static let main: [BKBottomBarItem] = [
        .init(.cut,     "切割"),
        .init(.waveCut, "波剪"),
        .init(.volume,  "音量"),
        .init(.size,    "画面大小"),
        .init(.rotate,  "旋转"),
        .init(.flip,    "左右镜像"),
        .init(.speed,   "变速"),
        .init(.copy,    "复制"),
        .init(.delete,  "删除", destructive: true),
        .init(.record,  "录音"),
    ]

    /// 录音轨选中 5 键
    static let rec: [BKBottomBarItem] = [
        .init(.cut,    "切割"),
        .init(.volume, "音量"),
        .init(.copy,   "复制"),
        .init(.record, "录音"),
        .init(.delete, "删除", destructive: true),
    ]

    /// 画中画选中 9 键
    static let pip: [BKBottomBarItem] = [
        .init(.cut,     "切割"),
        .init(.volume,  "音量"),
        .init(.replace, "替换"),
        .init(.size,    "画面大小"),
        .init(.rotate,  "旋转"),
        .init(.flip,    "左右镜像"),
        .init(.speed,   "变速"),
        .init(.copy,    "复制"),
        .init(.delete,  "删除", destructive: true),
    ]

    static func items(for track: BKTrackKind) -> [BKBottomBarItem] {
        switch track {
        case .main: return main
        case .pip:  return pip
        case .rec:  return rec
        }
    }

    /// 录音轨不支持变速（无画面）—— 规格 §2.2⑥。
    static func supportsSpeed(_ track: BKTrackKind) -> Bool { track != .rec }
}

// MARK: - 选择状态

/// 编辑页的选中态。
///
/// 对应原型的 `selTrack / selectedId / pipSelId / recSelId`。
///
/// ⚠️ 用**值类型**而不是散落的几个 var：状态机（规格补充A §2.2）里
///    "哪条轨选中 + 哪个区块 id"是一个整体，拆开存会出现
///    「selTrack 说画中画、pipSelId 却是 nil」这类非法态。
struct BKSelectionState: Equatable {

    /// 当前显式选中哪条轨（点区块 / 点轨头时设置）
    var track: BKTrackKind = .main
    /// 主轨选中区块
    var mainId: String?
    /// 画中画选中区块
    var pipId: String?
    /// 录音选中区块
    var recId: String?

    static let empty = BKSelectionState()

    /// 当前应显示哪套底栏。
    ///
    /// 规格 §1.1 伪码，**直接照搬**：
    /// ```swift
    /// if selectedTrack == .pip, selectedPipId != nil { return .pip }
    /// if selectedTrack == .rec, selectedRecId != nil { return .rec }
    /// return .main                                  // 主轨恒为默认
    /// ```
    ///
    /// ★ 为什么侧轨要额外判 `id != nil`：
    ///   只判 track 会出现「点过画中画又取消选中」后底栏卡在 9 键、
    ///   而实际没有作用目标 → 按下任何键都静默无反应。
    var barTrack: BKTrackKind {
        if track == .pip, pipId != nil { return .pip }
        if track == .rec, recId != nil { return .rec }
        return .main
    }

    /// 当前轨的选中区块 id（可能为 nil）
    var currentId: String? {
        switch track {
        case .main: return mainId
        case .pip:  return pipId
        case .rec:  return recId
        }
    }

    mutating func setSelectedId(_ id: String?, for kind: BKTrackKind) {
        switch kind {
        case .main: mainId = id
        case .pip:  pipId = id
        case .rec:  recId = id
        }
        if id != nil { track = kind }
    }

    /// 清空全部选中（点空白处调用，规格 §1.5）
    mutating func clearAll() {
        mainId = nil; pipId = nil; recId = nil
        track = .main          // ★ 回主轨，底栏恒有 10 键
    }
}

// MARK: - 委托

protocol BKBottomBarDelegate: AnyObject {
    /// 用户点了某个键。实现方按 `selection.barTrack` 决定作用对象。
    func bottomBar(_ bar: BKBottomBar, didTrigger action: BKBottomBarAction, on track: BKTrackKind)
    /// 底栏上下文（10/9/5 键）发生变化。
    func bottomBar(_ bar: BKBottomBar, didChangeTrack track: BKTrackKind)
}

// MARK: - 底栏视图

/// 上下文底栏。
///
/// 组成：`UIScrollView`（横滑）+ `UIStackView`（不换行、不压缩）。
/// 规格 §1.2 明确「不换行、不压缩（`flex: 0 0 auto`）」，
/// 所以每个键固定 `42 × 48pt`，**不用 UICollectionView 的自适应布局**，
/// 也不给约束优先级留"压缩"的口子。
final class BKBottomBar: UIView {

    weak var delegate: BKBottomBarDelegate?

    /// 当前选择态。设置后会按需重建键位表。
    private(set) var selection: BKSelectionState = .empty {
        didSet {
            guard selection != oldValue else { return }        // ★1 未变直接返回
            let oldTrack = oldValue.barTrack
            let newTrack = selection.barTrack
            if oldTrack != newTrack {
                rebuildKeys(for: newTrack)
                delegate?.bottomBar(self, didChangeTrack: newTrack)
            } else {
                refreshSelectedAppearance()
            }
        }
    }

    /// 当前显示的键位表所属轨
    private(set) var barTrack: BKTrackKind = .main

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let topHairline = UIView()
    private var keyButtons: [UIButton] = []

    // MARK: 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = BKThemeV2.Color.bg1
        // 规格 §1.6 绘制层级：录音浮层 75 < 工具面板 78/79 < 悬浮菜单 80
        // 底栏在这些之下，由父视图插入顺序决定，不设 zPosition

        // 顶边 1px 分隔线（规格 §1.2）
        topHairline.backgroundColor = BKThemeV2.Color.line
        topHairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topHairline)

        // ★5 横滑容器：owns 自己的 pan，与键的触摸事件互不冲突
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // 键容器：用 .fill + 每键固定宽约束，绝不让键被压缩
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = BKThemeV2.BottomBar.keyGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        let inset = BKThemeV2.BottomBar.sideInset

        NSLayoutConstraint.activate([
            topHairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            topHairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            topHairline.topAnchor.constraint(equalTo: topAnchor),
            topHairline.heightAnchor.constraint(equalToConstant: BKThemeV2.Color.hairline),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topHairline.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                                           constant: inset),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                                            constant: -inset),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),

            heightAnchor.constraint(equalToConstant: BKThemeV2.BottomBar.height),
        ])

        rebuildKeys(for: barTrack)
    }

    // MARK: 构建键位

    /// 按轨重建键位表。
    ///
    /// ⚠️ 只在 `barTrack` 真正变化时调用（★1）。
    ///    每像素重建 10 个 UIButton 是原型卡顿的同一个根因。
    private func rebuildKeys(for track: BKTrackKind) {
        barTrack = track

        keyButtons.forEach { $0.removeFromSuperview() }
        keyButtons.removeAll()

        for item in BKBottomBarSpec.items(for: track) {
            let button = makeKeyButton(item)
            button.widthAnchor.constraint(equalToConstant: BKThemeV2.BottomBar.keyWidth).isActive = true
            button.heightAnchor.constraint(equalToConstant: BKThemeV2.BottomBar.keyHeight).isActive = true
            stack.addArrangedSubview(button)
            keyButtons.append(button)
        }

        refreshSelectedAppearance()
        // 上下文切换后回到起点，避免上一套键的滚动位置残留
        scrollView.setContentOffset(.zero, animated: false)
    }

    private func makeKeyButton(_ item: BKBottomBarItem) -> UIButton {
        let config = UIImage.SymbolConfiguration(
            pointSize: BKThemeV2.BottomBar.iconPoint, weight: .regular)

        let button = UIButton(type: .custom)

        // ⚠️ nil 兜底：`UIImage(systemName:)` 在符号不存在时返回 nil，
        //    iOS 15 上不少"新式"符号名都属于这种情况。
        //    若直接 setImage(nil)，按钮**不报错、只是变空白** —— 用户看到的是
        //    一个点不动也没有图案的键，而日志里什么都没有。极难排查。
        //    所以这里退化成文字键：难看，但至少能看出它是什么、能点。
        let name = item.action.symbolName
        if let img = UIImage(systemName: name, withConfiguration: config) {
            button.setImage(img, for: .normal)
        } else {
            button.setTitle(item.title, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .medium)
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.7
            BKLog.shared.w("底栏符号缺失，退化为文字键：\(name)（\(item.title)）")
        }

        button.tintColor = item.isDestructive
            ? BKThemeV2.Color.barIconDelete
            : BKThemeV2.Color.barIcon
        // 文字键时要显式给 titleColor，否则 .custom 按钮的标题默认是白色，
        // 在浅底上会看不见（这里底是深色，但删除键的红色语义要保留）
        button.setTitleColor(item.isDestructive
                             ? BKThemeV2.Color.barIconDelete
                             : BKThemeV2.Color.barIcon, for: .normal)

        button.backgroundColor = .clear
        button.layer.cornerRadius = BKThemeV2.BottomBar.keyRadius
        button.layer.cornerCurve = .continuous
        button.clipsToBounds = true

        // 规格 §1.3：无文字，但保留无障碍标签
        button.accessibilityLabel = item.title
        button.accessibilityTraits = .button
        // 用 accessibilityIdentifier 携带语义动作；keyButtons 顺序即键序
        button.accessibilityIdentifier = "bb.\(item.action.rawValue)"

        // 按下态 scale(0.9)（规格 §1.3）
        button.addTarget(self, action: #selector(keyTouchDown(_:)), for: [.touchDown, .touchDragEnter])
        button.addTarget(self, action: #selector(keyTouchUp(_:)),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)

        return button
    }

    // MARK: 按下态

    @objc private func keyTouchDown(_ sender: UIButton) {
        UIView.animate(withDuration: 0.08) {
            sender.transform = CGAffineTransform(scaleX: BKThemeV2.BottomBar.pressedScale,
                                                 y: BKThemeV2.BottomBar.pressedScale)
        }
    }

    @objc private func keyTouchUp(_ sender: UIButton) {
        UIView.animate(withDuration: 0.12) { sender.transform = .identity }
    }

    // MARK: 点击派发

    @objc private func keyTapped(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier,
              id.hasPrefix("bb."),
              let action = BKBottomBarAction(rawValue: String(id.dropFirst(3)))
        else { return }

        // 录音轨底栏不出「变速」键（规格 §2.2⑥）。
        // 再兜一层，防止键位表被误改后仍派发出非法动作。
        if action == .speed, !BKBottomBarSpec.supportsSpeed(barTrack) { return }

        delegate?.bottomBar(self, didTrigger: action, on: barTrack)
    }

    // MARK: 选中态外观

    /// 刷新选中态外观。
    ///
    /// ⚠️ 原型里底栏**没有持久高亮**：底栏作用对象由 `barTrack` 决定，
    ///    而"哪个区块被选中"是轨道上的蓝框在表达。
    ///    规格 §1.3 的 `.on` 态（accent + rgba(47,109,244,.12)）留给
    ///    「面板已打开 / 该功能处于激活」的场景，第一批暂不点亮任何键。
    private func refreshSelectedAppearance() {
        for button in keyButtons {
            button.backgroundColor = .clear
        }
    }

    // MARK: ★4 点空白关菜单的排除名单

    /// 本次触摸是否发生在本视图内（用于「点空白关菜单」的排除判断）。
    ///
    /// ★4 是**最容易漏**的一条约束：
    /// 若底栏没在排除名单里，`pointerdown` 会先于 `click` 触发，
    /// 选中态在按键的瞬间被 `clearSelection()` 清空，
    /// 等按键回调执行时拿到空目标 → **静默失败，不报错、无提示**，
    /// 用户主观感受就是"点了没反应"，最难定位。
    ///
    /// ⚠️ **为什么要求传 `host` 而不是用 `superview`**：
    /// 早期写法是 `convert(point, from: superview)`，这**假定调用方传来的点
    /// 是「superview 坐标系」的**。而实际调用点在宿主的 tap 手势回调里，
    /// 拿到的是**宿主视图坐标系**的点 —— 一旦 superview ≠ host，
    /// 换算就会偏掉，表现为「点底栏却被判成点空白」，
    /// 于是选中态被清空、面板静默失效：**恰好就是 ★4 要防的那个 bug，绕了一圈又回来了**。
    /// 显式要求传 host，让坐标系无歧义。
    ///
    /// 用法（宿主控制器）：
    /// ```swift
    /// @objc private func onTap(_ g: UITapGestureRecognizer) {
    ///     let p = g.location(in: view)                  // 宿主坐标系
    ///     if bottomBar.containsTouch(p, in: view) { return }
    ///     if toolPanel.containsTouch(p, in: view) { return }
    ///     selection.clearAll()                          // 只有真正点在空白处才清
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - point: `host` 坐标系下的触摸点
    ///   - host: 该点所属的坐标系宿主视图（通常是宿主控制器自己的 `view`）
    /// - Returns: `true` 表示这次触摸落在底栏内 → **不要清选中**
    func containsTouch(_ point: CGPoint, in host: UIView) -> Bool {
        // 视图树关系异常时不猜：保守保留选中，避免误清
        guard isDescendant(of: host) || self === host else { return true }
        let local = convert(point, from: host)
        return bounds.contains(local)
    }
}
