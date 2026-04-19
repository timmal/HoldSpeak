import Foundation

public struct ReleaseInfo {
    public let version: String
    public let url: URL
}

public final class UpdateChecker {
    public static let shared = UpdateChecker()
    private let api = URL(string: "https://api.github.com/repos/timmal/push-to-talk/releases/latest")!
    private init() {}

    public func latest() async -> ReleaseInfo? {
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return ReleaseInfo(version: version, url: htmlURL)
    }

    public static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    public static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}
