import UIKit

// bk剪辑 · App 内检查更新
// 用法：在第一个界面的 viewDidAppear 里调用一次
//     UpdateChecker.checkAndPrompt(on: self)
// 前置：把 kManifestURL 换成你自己的 version.json 地址（必须 HTTPS）

struct ReleaseInfo: Decodable {
    let version: String
    let build: Int
    let date: String?
    let size: String?
    let note: [String]?
    let url: String
    let mandatory: Bool?

    var changelog: String {
        guard let note = note, !note.isEmpty else { return "修复若干问题，优化稳定性" }
        return note.map { "· \($0)" }.joined(separator: "\n")
    }
}

enum UpdateChecker {

    // MARK: - 配置区（只需改这里）

    static let kManifestURL = URL(string: "https://example.com/bk/version.json")!

    // 静默天数：同一个 build 在这段时间内最多打扰一次
    static let kSilentDays = 1

    // MARK: - 公开方法

    static func checkAndPrompt(on vc: UIViewController) {
        var request = URLRequest(url: kManifestURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil,
                  let data = data,
                  let info = try? JSONDecoder().decode(ReleaseInfo.self, from: data) else { return }

            guard info.build > currentBuild else { return }
            guard shouldPrompt(for: info) else { return }

            DispatchQueue.main.async { present(info, on: vc) }
        }.resume()
    }

    // MARK: - 内部实现

    static var currentBuild: Int {
        let raw = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return Int(raw) ?? 0
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private static func shouldPrompt(for info: ReleaseInfo) -> Bool {
        let key = "bk_update_prompted_build"
        let lastBuild = UserDefaults.standard.integer(forKey: key)
        if lastBuild == info.build { return false }

        let mandatory = info.mandatory ?? false
        if mandatory { return true }

        let dateKey = "bk_update_prompted_date"
        if let last = UserDefaults.standard.object(forKey: dateKey) as? Date,
           Date().timeIntervalSince(last) < Double(kSilentDays) * 86400 {
            return false
        }
        return true
    }

    private static func present(_ info: ReleaseInfo, on vc: UIViewController) {
        let alert = UIAlertController(
            title: "发现新版本 \(info.version)",
            message: "\(info.changelog)\n\n当前版本 \(currentVersion)",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "立即更新", style: .default) { _ in
            UserDefaults.standard.set(info.build, forKey: "bk_update_prompted_build")
            UserDefaults.standard.set(Date(), forKey: "bk_update_prompted_date")
            guard let url = URL(string: info.url) else { return }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        })

        let dismiss = UIAlertAction(title: "稍后再说", style: .cancel) { _ in
            UserDefaults.standard.set(Date(), forKey: "bk_update_prompted_date")
        }
        alert.addAction(dismiss)

        vc.present(alert, animated: true)
    }
}
