//
//  BKCovers.swift
//  bk剪辑 — 起始页草稿封面
//
//  【封面取哪一帧】定稿 3.1：**最后编辑那条素材、上次停住的那一帧**。
//  不是随便抽一张，也不是相册给的缩略图 —— 皓哥回马枪是来改某一处气口的，
//  封面就是他上次停的地方，点进去接得上。
//
//  【方向铁律第 ② 条在这里】
//  抽帧必须按**显示尺寸**出图，否则网格里会躺着一张横的封面。
//  AVAssetImageGenerator 的 `appliesPreferredTrackTransform` 默认就是 true，
//  它会自动把 preferredTransform 应用上去 —— 但要**显式写出来**并在注释里点明，
//  因为默认值这种东西会在某次重构里被顺手改成 false，然后没人记得为什么封面躺了。
//
//  【什么时候生成】
//  在编辑页**离开 / 存草稿**的时候生成，那时候 AVAsset 已经加载好了，
//  不用在起始页为了 10 张封面再去开 10 次素材。生成完直接落盘，
//  起始页只是读一张 jpg。
//

import UIKit
import AVFoundation

enum BKCovers {

    private static var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// PHAsset 的 localIdentifier 里带斜杠（"xxxx/L0/001"），不能直接当文件名
    private static func safe(_ s: String) -> String {
        let parts = s.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return parts.filter { !$0.isEmpty }.joined(separator: "_")
    }

    private static func fileURL(batchId: UUID, assetId: String) -> URL {
        dir.appendingPathComponent("\(batchId.uuidString)_\(safe(assetId)).jpg")
    }

    // MARK: - 读写

    static func save(_ image: UIImage, batchId: UUID, assetId: String) {
        guard let data = image.jpegData(compressionQuality: 0.7) else { return }
        do {
            try data.write(to: fileURL(batchId: batchId, assetId: assetId), options: .atomic)
            BKLog.shared.d(String(format: "封面已存 %@ · %d KB", safe(assetId).prefix(24), data.count / 1024))
        } catch {
            BKLog.shared.w("封面保存失败：\(error.localizedDescription)")
        }
    }

    static func load(batchId: UUID, assetId: String) -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL(batchId: batchId, assetId: assetId)) else { return nil }
        return UIImage(data: data)
    }

    /// 整批草稿被彻底删除时，把它名下的封面一起清掉
    static func remove(batchId: UUID) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let prefix = batchId.uuidString
        for f in files where f.lastPathComponent.hasPrefix(prefix) {
            try? fm.removeItem(at: f)
        }
    }

    // MARK: - 抽帧

    /// 按指定时间抽一帧。回调在主线程。
    ///
    /// - parameter appliesTransform: 必须保持 true（方向铁律 ②），
    ///   抽出来的是已经转正的**显示方向**图，竖版素材就是竖的一张
    static func generate(asset: AVAsset,
                         at time: Double,
                         maxSide: CGFloat = 480,
                         completion: @escaping (UIImage?) -> Void) {
        let gen = AVAssetImageGenerator(asset: asset)
        // 方向铁律②：把 preferredTransform 应用上去，抽出来就是「看」的那个方向。
        // iPhone 竖拍素材存的是横的 1920×1080，不应用这个变换封面就会躺着
        gen.appliesPreferredTrackTransform = true
        // 封面要的是指针停的那一帧，容差给零才准（慢一点没关系，只抽一张）
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: maxSide, height: maxSide)

        let t = CMTime(seconds: max(0, time), preferredTimescale: 600)
        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: t)]) { _, cg, _, result, err in
            var image: UIImage?
            if result == .succeeded, let cg = cg {
                image = UIImage(cgImage: cg)
            } else {
                BKLog.shared.w("封面抽帧失败：\(err?.localizedDescription ?? "未知原因")")
            }
            DispatchQueue.main.async { completion(image) }
        }
    }
}
