import Foundation

public struct ReleaseInfo {
    public let version: String
    public let url: URL
}

public final class UpdateChecker {
    public static let shared = UpdateChecker()
    private let api = URL(string: "https://api.github.com/repos/timmal/HoldSpeak/releases/latest")!
    private init() {}

    public func latest() async -> ReleaseInfo? {
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return Self.release(from: data)
    }

    /// The GitHub "latest release" response → version + release page. The page is
    /// opened in the browser, so only an https URL on github.com counts; anything
    /// else reads as no update info.
    static func release(from data: Data) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:)),
              htmlURL.scheme?.lowercased() == "https",
              htmlURL.host?.lowercased() == "github.com"
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return ReleaseInfo(version: version, url: htmlURL)
    }

    public static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = components(remote)
        let l = components(local)
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    /// "v0.6.0-beta.2" → [0, 6, 0]: drops a leading "v", the pre-release / build
    /// suffix and everything from the first non-numeric component on, so no
    /// later number can shift into a higher position.
    static func components(_ version: String) -> [Int] {
        var s = Substring(version.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = s[..<cut] }
        var result: [Int] = []
        for part in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(part) else { break }
            result.append(n)
        }
        return result
    }

    public static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}
