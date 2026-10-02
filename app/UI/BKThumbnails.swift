//
//  BKThumbnails.swift
//  bk剪辑 — 相册缩略图
//
//  【为什么放在 UI 层，不进 Core】
//  BKVideoLibrary.swift 头注释写着「这层不碰 UIKit，Core 层保持干净」——
//  之前有人在这里放过一个取缩略图的方法（用到 UIImage），独立列表页删掉后
//  连 UIKit 依赖一起删了。现在勾选页又要缩略图，就老老实实放 UI 层，
//  别再往 Core 里塞 UIKit 类型。**这条铁律是有前科的，别重蹈。**
//
//  【为什么要缓存】
//  300 条素材每条都要 Photos 解一次码，滑一遍要等好几秒。
//  NSCache 命中就直接给，opportunistic 模式先给低清再补高清，滑动不掉帧。
//
//  【异步回调必须比对 id】
//  cell 是复用的：请求 A 的图，回来时 cell 已经被复用给 B 了，
//  直接 set image 就会出现「A 的封面画到 B 上面」。所以回调里要核对 id。
//

import UIKit
import Photos

enum BKThumbnails {

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 400
        return c
    }()

    /// 取缩略图。命中缓存同步回调（便宜），否则异步向 Photos 要一张。
    /// - parameter size: 期望的**点**尺寸，内部会乘屏幕密度
    static func image(localID: String,
                      size: CGSize,
                      completion: @escaping (UIImage?) -> Void) {
        let key = localID as NSString
        if let hit = cache.object(forKey: key) {
            completion(hit)
            return
        }
        guard let phAsset = BKVideoLibrary.phAsset(localID: localID) else {
            completion(nil)
            return
        }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic      // 先低清再补高清
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true      // iCloud 上的素材允许拉
        let scale = UIScreen.main.scale
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        PHImageManager.default().requestImage(for: phAsset, targetSize: target,
                                              contentMode: .aspectFill, options: opts) { image, _ in
            if let image = image {
                // degraded 图也存，否则「低清→高清」这一轮会反复请求同一张
                cache.setObject(image, forKey: key)
            }
            // 回调统一回主线程，cell 才能安全改 UI
            if Thread.isMainThread {
                completion(image)
            } else {
                DispatchQueue.main.async { completion(image) }
            }
        }
    }
}
