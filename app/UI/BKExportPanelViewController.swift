//
//  BKExportPanelViewController.swift
//  bk剪辑 — 导出面板（规格）
//
//  【点「导出」之后先弹这个，不是直接开跑】
//  定稿 4.9：分辨率、帧率要有可选项，默认同源文件。
//
//  【v2 为什么没有「范围」选项了】
//  v1 一批草稿里每条素材各自独立导出，才需要选「本段 / 全部改过的」；
//  v2 一条草稿 = 一条主轨 = **一个成品文件**，范围这个概念塌缩了 ——
//  导出就是导出整条主轨。面板只剩分辨率 / 帧率两组选择 + 确认。
//

import UIKit

final class BKExportPanelViewController: UIViewController {

    // MARK: - 回调

    /// 点「开始导出」时回调一次
    var onStart: ((BKConfig.ExportSpec) -> Void)?

    // MARK: - 数据

    private let draft: BKDraft
    private var spec = BKConfig.ExportSpec()

    // MARK: - 界面

    private let card = UIView()
    private let resSeg = UISegmentedControl(items: BKConfig.Resolution.allCases.map { $0.rawValue })
    private let fpsSeg = UISegmentedControl(items: BKConfig.FrameRate.allCases.map { $0.rawValue })
    private let noteLabel = UILabel()

    init(draft: BKDraft) {
        self.draft = draft
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overCurrentContext
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("本 App 不走 storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(hex: 0x000000, alpha: 0.45)
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

    /// 把「实际会发生什么」写出来。草稿就是片子 —— 导出整条主轨，一个文件
    private func updateNote() {
        let n = draft.track.blocks.count
        if spec.resolution == .same && spec.frameRate == .same {
            noteLabel.text = String(
                format: "整条主轨 %d 段 · 成品 %@，按各块源规格输出。",
                n, formatClock(draft.track.total))
        } else {
            noteLabel.text = String(
                format: "整条主轨 %d 段 · 成品 %@，统一按 %@ 输出。",
                n, formatClock(draft.track.total), spec.summary)
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func startTapped() {
        dismiss(animated: true) { [weak self] in
            guard let self = self else { return }
            self.onStart?(self.spec)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 点卡片外面 = 取消。面板是浮层，没有这个会让人以为卡住了
        if let t = touches.first {
            let p = t.location(in: card)
            if !card.bounds.contains(p) { dismiss(animated: true) }
        }
    }

    /// mm:ss。时间码用这个：小数点后一位在剪辑场景里是噪音
    private func formatClock(_ t: Double) -> String {
        let s = max(0, t)
        let m = Int(s) / 60
        let sec = Int(s) % 60
        return String(format: "%02d:%02d", m, sec)
    }
}
