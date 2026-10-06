//
//  BKTrackMedia.swift
//  bk剪辑 — 主轨道三层条的媒体供给（帧条视频帧 + 波形条声音包络）
//
//  【为什么主轨 waveform 之前没显示】
//  2B-1 骨架只铺了单张缩略图，波形条压根没画 —— 皓哥 2026-10-07 指出
//  「竞品主轨有波形我们怎么没有」。对：原型规格（index.html .m-wave）本来就是
//  画面帧条 60px + 声音包络 40px + 时间刻度 13px 三层堆叠，骨架那轮漏了两层。
//  本文件补齐两层的数据源。
//
//  【为什么帧条不用 BKThumbnails】
//  BKThumbnails 是「一个素材一张封面」（PHImageManager，按 asset 取）。
//  主轨帧条要的是**同一素材在多个时间点上的帧**（约 1.2s 一帧，铺满整个块），
//  得走 AVAssetImageGenerator 按时间点抓，缓存键也要带时间 —— 是另一码事。
//
//  【抓帧为什么给 0.6s 容差】
//  一帧管 1.2 秒的展示，没必要精确到帧；宽容差让 AVFoundation 直接取最近的
//  关键帧，不用往前解 GOP，几百毫秒就能出图。真精确抓帧是逐帧预览的事。
//

import UIKit
import AVFoundation

// MARK: - 帧条：按时间点抓视频帧

enum BKFrameGrabs {

    private static let imgCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 800
        return c
    }()
    /// 素材 AVAsset 缓存：滚动主轨逐帧预览时反复抓同一素材的不同时间点，
    /// 每次都向相册重新要 AVAsset 太重 —— 按 localID 缓存一次，之后直接复用
    private static let assetCache: NSCache<NSString, AVAsset> = {
        let c = NSCache<NSString, AVAsset>()
        c.countLimit = 200
        return c
    }()

    /// 取某素材在 srcTime（源时间，秒）处的一帧。
    /// 图像缓存键带 0.25s 粒度的时间 + 目标高：同素材同时间只抓一次
    static func frame(localID: String,
                      at srcTime: Double,
                      size: CGSize,
                      completion: @escaping (UIImage?) -> Void) {
        let t = max(0, srcTime)
        let key = "\(localID)#\(Int(t * 4))#\(Int(size.height))" as NSString
        if let hit = imgCache.object(forKey: key) {
            completion(hit)
            return
        }
        let grab: (AVAsset) -> Void = { asset in
            let gen = AVAssetImageGenerator(asset: asset)
            // ★ 抓出来就是「显示方向」—— generator 自己应用 preferredTransform，
            //   画的时候不用再管横竖（漏了这条帧会躺下）
            gen.appliesPreferredTrackTransform = true
            let scale = UIScreen.main.scale
            gen.maximumSize = CGSize(width: size.width * scale, height: size.height * scale)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.6, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.6, preferredTimescale: 600)
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: t, preferredTimescale: 600))]) { _, cg, _, _, _ in
                let img = cg.map { UIImage(cgImage: $0) }
                if let img = img { imgCache.setObject(img, forKey: key) }
                if Thread.isMainThread { completion(img) }
                else { DispatchQueue.main.async { completion(img) } }
            }
        }
        if let asset = assetCache.object(forKey: localID as NSString) {
            grab(asset)
            return
        }
        BKVideoLibrary.loadAVAsset(localID: localID) { asset in
            guard let asset = asset else {
                completion(nil)
                return
            }
            assetCache.setObject(asset, forKey: localID as NSString)
            grab(asset)
        }
    }
}

// MARK: - 波形条：声音包络（按素材缓存）

final class BKEnvelopeBox {
    let env: BKEnvelope
    init(_ env: BKEnvelope) { self.env = env }
}

enum BKEnvelopeStore {

    private static let cache = NSCache<NSString, BKEnvelopeBox>()
    /// 正在提取的素材，防重复起 reader（reader 挺贵的，重复提取白烧电）
    private static var inflight: Set<String> = []
    private static let lock = NSLock()

    /// 取某素材的全长包络（原片时间轴）。命中缓存同步回调；否则异步提取后回调。
    /// 没音轨 / 提取失败 → completion(nil)，波形条那块就空着（不影响别的块）
    static func envelope(localID: String, completion: @escaping (BKEnvelope?) -> Void) {
        let key = localID as NSString
        if let hit = cache.object(forKey: key) {
            completion(hit.env)
            return
        }
        lock.lock()
        let busy = inflight.contains(localID)
        if !busy { inflight.insert(localID) }
        lock.unlock()
        if busy {
            // 已经在取了。不回调 —— 先到的那一份回调里会触发整条重画，画一次就够了
            return
        }

        BKVideoLibrary.loadAVAsset(localID: localID) { asset in
            guard let asset = asset else {
                Self.done(localID)
                completion(nil)
                return
            }
            BKAudioAnalyzer.extractEnvelope(from: asset) { result in
                Self.done(localID)
                switch result {
                case .success(let env):
                    cache.setObject(BKEnvelopeBox(env), forKey: key)
                    completion(env)
                case .failure(let err):
                    BKLog.shared.w("主轨包络提取失败 \(localID)：\(err.localizedDescription)")
                    completion(nil)
                }
            }
        }
    }

    private static func done(_ localID: String) {
        lock.lock()
        inflight.remove(localID)
        lock.unlock()
    }
}
