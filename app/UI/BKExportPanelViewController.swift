//
//  BKExportPanelViewController.swift
//  bk剪辑 — 导出面板（范围 + 规格）
//
//  【点「导出」之后先弹这个，不是直接开跑】
//  定稿 4.8：导出前要选「只导出本段 / 导出全部（改过的）」；
//  定稿 4.9：分辨率、帧率要有可选项，默认同源文件。
//  两件事都发生在开跑之前，所以合成一个面板一次问完，
//  比「弹窗选范围 → 又弹窗选分辨率」那种连弹两次的体验好得多。
//
//  【为什么不用 UIAlertController 塞几个选项】
//  Alert 的 action 是平铺的一列，两组选项（范围 / 分辨率 / 帧率）挤在一起
//  根本分不清哪行属于哪组。这种「三组独立选择 + 一个确认」的形态，
//  分段控件的命中率最高，也是 iOS 设置里一贯的样子。
//
//  【「同源文件」在批量导出时是什么意思】
//  定稿 4.9.1：一批里各条参数不一样时，按**时长最长那条**的参数统一。
//  这条规则要写在面板上让人看见 —— 否则用户会以为「同源」是各自用自己的参数。
//

import UIKit

/// 导出范围
enum BKExportScope {
    /// 只导出当前这一条
    case current
    /// 导出这一批里所有动过刀的
    case allEdited
}

final class BKExportPanelViewController: UIViewController {

    // MARK: - 回调

    /// (范围, 规格)。点「开始导出」时回调一次
    var onStart: ((BKExportScope, BKConfig.ExportSpec) -> Void)?

    // MARK: - 数据

    private let batch: BKDraftBatch
    private let currentIndex: Int
    private var spec = BKConfig.ExportSpec()

    // MARK: - 界面

    private let card = UIView()
    private let scopeSeg = UISegmentedControl(items: ["只导出本段", "导出全部（改过的）"])
    private let resSeg = UISegmentedControl(items: BKConfig.Resolution.allCases.map { $0.rawValue })
    private let fpsSeg = UISegmentedControl(items: BKConfig.FrameRate.allCases.map { $0.rawValue })
    private let noteLabel = UILabel()

    init(batch: BKDraftBatch, currentIndex: Int) {
        self.batch = batch
        self.currentIndex = currentIndex
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overCurrentContext
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("本 App 不走 storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(hex: 0x000000, alpha: 0.35)
        setupCard()
        updateNote()
    }

    // MARK: - 布局

    private func setupCard() {
        card.backgroundColor = BKTheme.Color.panel
        card.layer.cornerRadius = BKTheme.Radius.sheet
        card.clipsToBounds = true
        view.addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "导出"
        title.font = BKTheme.Font.title
        title.textColor = BKTheme.Color.text

        let editedCount = batch.editedItems.count
        scopeSeg.selectedSegmentIndex = 0
        // 一条都没动过刀的话，第二个选项点了也是空跑，直接禁用
        scopeSeg.setEnabled(editedCount > 0, forSegmentAt: 1)
        scopeSeg.addTarget(self, action: #selector(changed), for: .valueChanged)

        resSeg.selectedSegmentIndex = 0
        fpsSeg.selectedSegmentIndex = 0
        resSeg.addTarget(self, action: #selector(changed), for: .valueChanged)
        fpsSeg.addTarget(self, action: #selector(changed), for: .valueChanged)

        noteLabel.font = BKTheme.Font.caption
        noteLabel.textColor = BKTheme.Color.text2
        noteLabel.numberOfLines = 0

        let cancel = UIButton(type: .system)
        cancel.setTitle("取消", for: .normal)
        cancel.setTitleColor(BKTheme.Color.text2, for: .normal)
        cancel.titleLabel?.font = BKTheme.Font.button
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let start = UIButton(type: .system)
        start.setTitle("开始导出", for: .normal)
        start.setTitleColor(.white, for: .normal)
        start.titleLabel?.font = BKTheme.Font.button
        start.backgroundColor = BKTheme.Color.accent
        start.layer.cornerRadius = 8
        start.addTarget(self, action: #selector(startTapped), for: .touchUpInside)

        let btnRow = UIStackView(arrangedSubviews: [cancel, start])
        btnRow.axis = .horizontal
        btnRow.spacing = BKTheme.Space.md
        btnRow.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [
            title,
            labeled("范围", scopeSeg),
            labeled("分辨率", resSeg),
            labeled("帧率", fpsSeg),
            noteLabel,
            btnRow
        ])
        stack.axis = .vertical
        stack.spacing = BKTheme.Space.lg
        stack.alignment = .fill
        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: BKTheme.Space.xl),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: BKTheme.Space.lg),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -BKTheme.Space.lg),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -BKTheme.Space.lg),

            btnRow.heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    private func labeled(_ text: String, _ control: UIView) -> UIStackView {
        let lab = UILabel()
        lab.text = text
        lab.font = BKTheme.Font.caption
        lab.textColor = BKTheme.Color.text2
        lab.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [lab, control])
        row.axis = .horizontal
        row.spacing = BKTheme.Space.md
        row.alignment = .center
        return row
    }

    // MARK: - 交互

    @objc private func changed() {
        spec.resolution = BKConfig.Resolution.allCases[resSeg.selectedSegmentIndex]
        spec.frameRate = BKConfig.FrameRate.allCases[fpsSeg.selectedSegmentIndex]
        updateNote()
    }

    /// 把「实际会发生什么」写出来。批量 + 同源这条最容易产生误解，必须提前说清
    private func updateNote() {
        let isAll = scopeSeg.selectedSegmentIndex == 1
        if isAll {
            let n = batch.editedItems.count
            if spec.resolution == .same || spec.frameRate == .same {
                if let idx = batch.longestItemIndex() {
                    let ref = batch.items[idx]
                    noteLabel.text = String(
                        format: "导出 %d 条（动过刀的）。选了「同源文件」的项按本批时长最长那条统一：%@（%.0f 秒）。",
                        n, ref.assetName, ref.duration)
                } else {
                    noteLabel.text = String(format: "导出 %d 条（动过刀的）。", n)
                }
            } else {
                noteLabel.text = String(format: "导出 %d 条（动过刀的），全批统一按 %@ 输出。", n, spec.summary)
            }
        } else {
            noteLabel.text = "只导出当前这一条，输出规格 \(spec.summary)。"
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func startTapped() {
        let scope: BKExportScope = (scopeSeg.selectedSegmentIndex == 1) ? .allEdited : .current
        dismiss(animated: true) { [weak self] in
            guard let self = self else { return }
            self.onStart?(scope, self.spec)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 点卡片外面 = 取消。面板是浮层，没有这个会让人以为卡住了
        if let t = touches.first {
            let p = t.location(in: card)
            if !card.bounds.contains(p) { dismiss(animated: true) }
        }
    }
}
