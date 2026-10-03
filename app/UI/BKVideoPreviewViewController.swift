//
//  BKVideoPreviewViewController.swift
//  bk剪辑 — 全屏视频预览（勾选页点圆圈以外进入）
//
//  【为什么单独一个播放器，而不是复用编辑页那个】
//  编辑页的播放器是「工作台」：有波形、有轨道、拖动要跟切点联动。
//  挑素材时只想「看这一条长什么样、听声音对不对」，多一屏控件都是干扰。
//  所以这里是最简形态：黑底、画面、一个中央播放键、底部一条进度。
//
//  【铁律：显式设音频会话】
//  视频不显式设 .playback 就默认服从静音键 —— 一按静音整条无声，
//  「听声音对不对」这个目的直接落空。踩过，记在这。
//
//  【自动播放】
//  进来直接播（看片子的直觉，不用多点一下）。不在后台/离屏时自动播 ——
//  用户自己点开的，静音和暂停都该由他决定。
//

import UIKit
import AVFoundation

final class BKVideoPreviewViewController: UIViewController, BKPreviewStopping {

    /// 关闭回调（勾选页用来 pop / dismiss）
    var onClose: (() -> Void)?

    private let localID: String
    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private let playIcon = UIImageView()
    private let backButton = UIButton(type: .system)
    private let timeLabel = UILabel()
    private let slider = UISlider()
    /// 右上角「选中这个小圆圈」。参考图：空心圈=未选，填红+序号=已选
    private let pickButton = UIButton(type: .system)
    private let pickLabel = UILabel()

    /// 点小圆圈：把「这条视频现在该不该被选」告诉勾选页
    var onTogglePick: ((String) -> Void)?
    /// 当前是否已被选中（进来时由勾选页告知）
    private(set) var isPicked = false

    /// 时间拖动时先暂停，松开再继续 —— 不然跟播放器抢着走，进度条会跳
    private var wasPlayingBeforeScrub = false

    init(localID: String, isPicked: Bool = false) {
        self.localID = localID
        self.isPicked = isPicked
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("本 App 不走 storyboard") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BKTheme.Color.preview
        setupUI()
        setupAudio()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        BKVideoLibrary.playingPreview = self
        loadAndPlay()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player.pause()
    }

    /// 离开时把播放停掉。不停的话声音会盖住下面的界面
    func pauseAndDismiss() {
        stopPreview()
    }

    /// 协议方法：停播 + 清掉 Core 层的静态引用（那是强引用，不清会挂着整个页面）
    func stopPreview() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        // 只清引用，不回头调 BKVideoLibrary.stopPreview() —— 那会绕回本方法无限递归
        BKVideoLibrary.clearPreviewRef()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            BKLog.shared.w("预览音频会话设置失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 布局

    private func setupUI() {
        // 画面层：videoGravity = resizeAspect，竖屏素材在竖屏机上正好铺满
        playerLayer.videoGravity = .resizeAspect
        playerLayer.player = player
        view.layer.addSublayer(playerLayer)

        // 点画面 = 暂停/播放。**装在 view 上而不是 playIcon 上** ——
        // 参考图是点整幅画面任意位置都能暂停，不只是点中间那个圆。
        // 放在最后 add，保证它盖在 playIcon / 按钮之上、优先收到点击；
        // 按钮那些小控件会在下面单独处理，不会被它抢走。
        let tapScreen = UITapGestureRecognizer(target: self, action: #selector(centerTapped))
        view.addGestureRecognizer(tapScreen)

        // 中央播放/暂停键：半透明圆形，暂停时浮现、播放时隐掉
        playIcon.image = UIImage(systemName: "play.fill")
        playIcon.tintColor = UIColor(hex: 0xFFFFFF, alpha: 0.9)
        playIcon.contentMode = .center
        playIcon.backgroundColor = UIColor(hex: 0x000000, alpha: 0.35)
        playIcon.layer.cornerRadius = 28
        playIcon.isHidden = true
        playIcon.isUserInteractionEnabled = false   // 点击交给上面的整屏手势
        view.addSubview(playIcon)

        // 左上角返回。参考图是纯白线条，不带底色
        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = .white
        backButton.backgroundColor = UIColor(hex: 0x000000, alpha: 0.3)
        backButton.layer.cornerRadius = 17
        backButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(backButton)

        // 右上角小圆圈：点它直接选中/取消这条视频，不用退回列表
        pickButton.layer.cornerRadius = 14
        pickButton.layer.borderWidth = 1.6
        pickButton.addTarget(self, action: #selector(pickTapped), for: .touchUpInside)
        view.addSubview(pickButton)
        pickLabel.font = .systemFont(ofSize: 13, weight: .bold)
        pickLabel.textColor = .white
        pickLabel.textAlignment = .center
        pickLabel.isUserInteractionEnabled = false
        view.addSubview(pickLabel)
        applyPickState()

        // 底部进度：时间码 + 拖动条
        timeLabel.font = BKTheme.Font.monoSmall
        timeLabel.textColor = .white
        timeLabel.text = "00:00 / 00:00"
        view.addSubview(timeLabel)

        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor(hex: 0xFFFFFF, alpha: 0.3)
        slider.addTarget(self, action: #selector(scrubStart), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubMove), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        view.addSubview(slider)

        for v in [playIcon, backButton, pickButton, pickLabel, timeLabel, slider] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            playIcon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playIcon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            playIcon.widthAnchor.constraint(equalToConstant: 56),
            playIcon.heightAnchor.constraint(equalToConstant: 56),

            backButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            backButton.widthAnchor.constraint(equalToConstant: 34),
            backButton.heightAnchor.constraint(equalToConstant: 34),

            pickButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            pickButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            pickButton.widthAnchor.constraint(equalToConstant: 28),
            pickButton.heightAnchor.constraint(equalToConstant: 28),

            pickLabel.centerXAnchor.constraint(equalTo: pickButton.centerXAnchor),
            pickLabel.centerYAnchor.constraint(equalTo: pickButton.centerYAnchor),

            slider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            slider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            slider.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),

            timeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            timeLabel.bottomAnchor.constraint(equalTo: slider.topAnchor, constant: -4)
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackEnded),
            name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    /// 右上角小圆圈两态：未选=半透明空心圈，已选=填红
    private func applyPickState() {
        if isPicked {
            pickButton.backgroundColor = BKTheme.Color.danger
            pickButton.layer.borderColor = BKTheme.Color.danger.cgColor
        } else {
            pickButton.backgroundColor = UIColor(hex: 0x000000, alpha: 0.28)
            pickButton.layer.borderColor = UIColor(hex: 0xFFFFFF, alpha: 0.9).cgColor
        }
    }

    @objc private func pickTapped() {
        isPicked.toggle()
        applyPickState()
        onTogglePick?(localID)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // AVPlayerLayer 不吃 Auto Layout，必须手动给 frame
        playerLayer.frame = view.bounds
    }

    // MARK: - 播放

    private func loadAndPlay() {
        BKVideoLibrary.loadAVAsset(localID: localID) { [weak self] asset in
            guard let self = self else { return }
            guard let asset = asset else {
                self.showLoadFailed()
                return
            }
            let item = AVPlayerItem(asset: asset)
            self.player.replaceCurrentItem(with: item)
            self.player.play()
            self.slider.value = 0
            // 滑条刻度统一用「比例 0…1」，三处必须同一套单位：
            // 进度回调写 slider.value = cur/total（比例）、拖动回调读 t = slider.value*total（反推秒）、这里定刻度。
            // 之前刻度设成总秒数（0…7）、进度却写比例 —— 5s/7s=0.71 落在 0…7 刻度上只走 10%，
            // 滑块永远贴着左端（v1.2.14 修，时间码不走滑条所以一直是对的）
            self.slider.minimumValue = 0
            self.slider.maximumValue = 1
            self.playIcon.isHidden = true
            self.installPeriodicTime()
        }
    }

    /// 定时把播放进度刷到进度条和 timeLabel 上
    private func installPeriodicTime() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self = self, let item = self.player.currentItem else { return }
            // 拖动中不刷，否则 slider 会跟手打架
            if self.slider.isTracking { return }
            let cur = CMTimeGetSeconds(t)
            let total = CMTimeGetSeconds(item.duration)
            guard total.isFinite, total > 0 else { return }
            self.slider.value = Float(cur / total)
            let a = BKVideoLibrary.formatDuration(cur)
            let b = BKVideoLibrary.formatDuration(total)
            self.timeLabel.text = "\(a) / \(b)"
        }
    }

    private func showLoadFailed() {
        let label = UILabel()
        label.text = "视频加载失败\n可能还在 iCloud 上，联网重试一次"
        label.font = BKTheme.Font.body
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    // MARK: - 动作

    @objc private func centerTapped() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            // 播完了再点 = 从头重放
            if let item = player.currentItem,
               CMTimeGetSeconds(player.currentTime()) >= CMTimeGetSeconds(item.duration) - 0.1 {
                player.seek(to: .zero)
            }
            player.play()
        }
        syncPlayIcon()
    }

    private func syncPlayIcon() {
        playIcon.isHidden = player.timeControlStatus == .playing
    }

    @objc private func closeTapped() {
        pauseAndDismiss()
        if let cb = onClose {
            cb()
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func playbackEnded() {
        player.seek(to: .zero)
        player.pause()
        syncPlayIcon()
    }

    // MARK: - 拖动进度

    @objc private func scrubStart() {
        wasPlayingBeforeScrub = player.timeControlStatus == .playing
        player.pause()
    }

    @objc private func scrubMove() {
        guard let item = player.currentItem else { return }
        let total = CMTimeGetSeconds(item.duration)
        guard total.isFinite, total > 0 else { return }
        let t = Double(slider.value) * total
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        let a = BKVideoLibrary.formatDuration(t)
        let b = BKVideoLibrary.formatDuration(total)
        timeLabel.text = "\(a) / \(b)"
    }

    @objc private func scrubEnd() {
        if wasPlayingBeforeScrub {
            player.play()
        }
        syncPlayIcon()
    }
}
