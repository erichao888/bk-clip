//
//  BKVideoLibrary.swift
//  bk剪辑 — 相册视频素材库
//
//  【为什么单独一层】
//  之前 App 只能「选一条 → 编辑一条」，切素材必须退回起始页重新挑，
//  对比着看两条素材的刀口几乎不可能。加了这一层之后，
//  编辑页可以「上一条 / 下一条」横向翻，也能从 ☰ 列表里直接点名切换。
//
//  【只存 localIdentifier，不存 AVAsset】
//  localIdentifier 是 Photos 给的稳定 ID，重启后依然能捞回同一条；
//  AVAsset 不能序列化，也没法跨页面传递（大文件读进内存代价高）。
//
//  【这层不碰 UIKit】
//  只做 ID / AVAsset / 文件名 / 时长这类纯数据。之前在这里放过一个
//  取缩略图的方法（用到 UIImage），独立列表页删掉后没人用了，
//  连同 UIKit 依赖一起删 —— Core 层保持干净
//

import Foundation
import Photos
import AVFoundation

/// 能被「统一关掉」的预览页。Core 层不认识具体的 UIViewController 子类，
/// 只约一个纯 Swift 协议，靠动态派发在运行期解析 —— 这样 Core 保持不碰 UIKit。
protocol BKPreviewStopping: AnyObject {
    func stopPreview()
}

enum BKVideoLibrary {
    /// 相册里的视频，最新的排前面。**不再限制条数**：勾选页用 UICollectionView 复用 cell，
    /// 几千条也只是多滚几屏，内存由 BKThumbnails 的 NSCache(400) 钉死，撑得住。
    static func videoLocalIDs() -> [String] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .video, options: opts)
        var ids: [String] = []
        result.enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        return ids
    }

    /// 取 PHAsset。列表页要用它的时长、尺寸和缩略图
    static func phAsset(localID: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject
    }

    /// 按 ID 取可播放的 AVAsset。iCloud 上的素材允许联网拉取
    static func loadAVAsset(localID: String, completion: @escaping (AVAsset?) -> Void) {
        guard let phAsset = phAsset(localID: localID) else {
            completion(nil)
            return
        }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { asset, _, _ in
            DispatchQueue.main.async { completion(asset) }
        }
    }

    /// 素材在列表里显示的名字。iOS 不给文件名，只有从资源里能取到原始文件名
    /// （IMG_2969.MOV 这种）—— 这比「视频 3」有用得多，用户认得自己的素材
    static func assetName(localID: String) -> String {
        guard let asset = phAsset(localID: localID) else { return "素材已失效" }
        let resource = PHAssetResource.assetResources(for: asset).first
        if let name = resource?.originalFilename, !name.isEmpty { return name }
        return "视频"
    }

    /// 时长（秒）。列表副标题用
    static func duration(localID: String) -> Double {
        phAsset(localID: localID)?.duration ?? 0
    }

    static func index(of localID: String, in ids: [String]) -> Int? {
        ids.firstIndex(of: localID)
    }

    /// 正在播放的预览页。勾选页一次只可能有一个在播，记下来是为了
    /// 离开勾选页时能把它关掉（不然声音停不下来）。
    /// ⚠️ **不能用 `weak`**：Swift 不允许 weak 修饰静态存储属性（硬编译错误），
    /// 所以这里用普通强引用 + 手动清空（预览页 close / 消失时置 nil）。
    /// 引用环风险：预览页持有 player，播放器不持有预览页，不会成环。
    ///
    /// 类型是 `AnyObject?` 而不是具体预览页，正是为了**不引入 UIKit**：
    /// 本文件头注释写着「Core 层保持干净」。`stopPreview()` 靠
    /// Swift 的动态派发在运行期解析，Core 层编译时不需要认得那个类。
    static var playingPreview: AnyObject? {
        get { _playingPreview }
        set { _playingPreview = newValue }
    }
    private static var _playingPreview: AnyObject?

    /// 统一收口：关掉正在播的预览页。勾选页离开时调它
    static func stopPreview() {
        (_playingPreview as? BKPreviewStopping)?.stopPreview()
        _playingPreview = nil
    }

    /// 只清引用不回调。**预览页的 stopPreview() 里必须用这个** ——
    /// 回头调 `stopPreview()` 会绕回它自己，无限递归。
    static func clearPreviewRef() {
        _playingPreview = nil
    }

    /// mm:ss 或 hh:mm:ss。素材列表和进度显示共用一套写法
    static func formatDuration(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "--:--" }
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
