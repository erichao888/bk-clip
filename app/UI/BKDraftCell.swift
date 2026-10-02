//
//  BKDraftCell.swift
//  bk剪辑 — 起始页草稿卡片
//
//  【一张卡片 = 一次导入的一整批】
//  封面是「最后编辑那条素材、上次停住的那一帧」—— 皓哥回马枪是来改某一处气口的，
//  点进去接得上才是这个封面存在的意义。
//
//  【角标是合计刀数，不是单条的】
//  一格代表一整批，所以角标显示的是这一批所有素材加起来的刀数。
//  定稿 3.1：动过刀的批金底黑字；因为「一刀没切的批退出时就丢了」，
//  理论上不会出现 0 刀的卡片，但万一有（比如老草稿），照样显示，不隐藏。
//
//  【「···」菜单三项：重命名 / 删除 / 直接导出】
//  用按钮 + 回调而不是 UIContextMenuInteraction：后者要长按才出，
//  在网格里长按很容易被误判成想拖动，而且菜单延迟明显。
//  一格就三个动作，点一下弹列表最干脆。
//

import UIKit

final class BKDraftCell: UICollectionViewCell {

    static let reuseId = "BKDraftCell"

    /// 点右上角「···」
    var onMenu: (() -> Void)?

    private let cover = UIImageView()
    private let placeholder = UILabel()
    private let shade = UIView()
    private let titleLabel = UILabel()
    private let badge = UILabel()
    private let countBadge = UILabel()
    private let menuButton = UIButton(type: .system)
    private let checkView = UIImageView()

    /// 多选态的勾选框。平时隐藏
    var isPicking: Bool = false {
        didSet { checkView.isHidden = !isPicking }
    }

    override var isSelected: Bool {
        didSet { applyPickState() }
    }

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("本 App 不走 storyboard") }

    private func setup() {
        contentView.backgroundColor = BKTheme.Color.panel2
        contentView.layer.cornerRadius = BKTheme.Radius.card
        contentView.clipsToBounds = true

        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        cover.backgroundColor = UIColor(hex: 0x2A2A28)
        contentView.addSubview(cover)

        // 封面没生成出来时的兜底：一个居中的胶片图标意思一下，
        // 空白格子比「灰底」更像坏了
        placeholder.text = "🎬"
        placeholder.font = .systemFont(ofSize: 26)
        placeholder.textAlignment = .center
        placeholder.textColor = UIColor(hex: 0xFFFFFF, alpha: 0.45)
        contentView.addSubview(placeholder)

        // 底部压一层渐变，保证标题在亮封面（雪地、白墙）上也读得出来
        shade.backgroundColor = UIColor(hex: 0x000000, alpha: 0.55)
        contentView.addSubview(shade)

        titleLabel.font = BKTheme.Font.caption
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        contentView.addSubview(titleLabel)

        badge.font = BKTheme.Font.small
        badge.textColor = BKTheme.Color.text
        badge.backgroundColor = BKTheme.Color.gold
        badge.textAlignment = .center
        badge.layer.cornerRadius = 3
        badge.clipsToBounds = true
        contentView.addSubview(badge)

        // 视频条数角标：刀数是金底（主信息，不动），条数用低调的黑透明底白字垫在右边，
        // 一眼分清「工作量」和「规模」。单条批（count<2）不显示 —— 写「1 条」是废话
        countBadge.font = BKTheme.Font.small
        countBadge.textColor = .white
        countBadge.backgroundColor = UIColor(hex: 0x000000, alpha: 0.5)
        countBadge.textAlignment = .center
        countBadge.layer.cornerRadius = 3
        countBadge.clipsToBounds = true
        countBadge.isHidden = true
        contentView.addSubview(countBadge)

        menuButton.setTitle("···", for: .normal)
        menuButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .bold)
        menuButton.setTitleColor(.white, for: .normal)
        menuButton.backgroundColor = UIColor(hex: 0x000000, alpha: 0.45)
        menuButton.layer.cornerRadius = 11
        menuButton.addTarget(self, action: #selector(menuTapped), for: .touchUpInside)
        contentView.addSubview(menuButton)

        checkView.image = UIImage(systemName: "checkmark.circle.fill")
        checkView.tintColor = BKTheme.Color.gold
        checkView.backgroundColor = BKTheme.Color.panel
        checkView.layer.cornerRadius = 11
        checkView.clipsToBounds = true
        checkView.isHidden = true
        contentView.addSubview(checkView)

        for v in [cover, placeholder, shade, titleLabel, badge, countBadge, menuButton, checkView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: contentView.topAnchor),
            cover.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cover.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            placeholder.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -8),

            shade.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            shade.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            shade.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            shade.heightAnchor.constraint(equalToConstant: 34),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),

            badge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 5),
            badge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            badge.heightAnchor.constraint(equalToConstant: 17),

            countBadge.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 4),
            countBadge.topAnchor.constraint(equalTo: badge.topAnchor),
            countBadge.heightAnchor.constraint(equalToConstant: 17),

            menuButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            menuButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            menuButton.widthAnchor.constraint(equalToConstant: 30),
            menuButton.heightAnchor.constraint(equalToConstant: 30),

            checkView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            checkView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 5),
            checkView.widthAnchor.constraint(equalToConstant: 22),
            checkView.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    // MARK: - 装填

    func configure(title: String, cuts: Int, count: Int, coverImage: UIImage?, picking: Bool) {
        titleLabel.text = title
        badge.text = "\(cuts) 刀"
        // 单条批（count<2）不显示条数角标；多条才显示，提示「这批要过一遍素材列表」
        if count >= 2 {
            countBadge.isHidden = false
            countBadge.text = "\(count) 条"
        } else {
            countBadge.isHidden = true
        }
        cover.image = coverImage
        placeholder.isHidden = coverImage != nil
        isPicking = picking
        applyPickState()
    }

    private func applyPickState() {
        let picked = isPicking && isSelected
        checkView.image = UIImage(systemName: picked ? "checkmark.circle.fill" : "circle")
        checkView.tintColor = picked ? BKTheme.Color.gold : UIColor(hex: 0xFFFFFF, alpha: 0.8)
        checkView.backgroundColor = picked ? BKTheme.Color.panel : UIColor(hex: 0x000000, alpha: 0.30)
        contentView.layer.borderWidth = picked ? 3 : 0
        contentView.layer.borderColor = BKTheme.Color.gold.cgColor
    }

    @objc private func menuTapped() {
        onMenu?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cover.image = nil
        placeholder.isHidden = false
        onMenu = nil
    }
}
