import Foundation

/// Checks GitHub for a newer RunMyGames release.
public enum Updater {
    public struct Release: Equatable, Sendable {
        public let version: String
        public let url: URL
    }

    /// The latest published release, if it is newer than this build. Silent (nil) on any failure.
    public static func check() async -> Release? {
        let api = URL(string: "https://api.github.com/repos/\(Project.repo)/releases/latest")!
        guard let data = try? await Downloader.data(api, headers: ["Accept": "application/vnd.github+json"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return isNewer(version, than: Version.current) ? Release(version: version, url: page) : nil
    }

    /// Daily check honoring the user's setting; records the time it ran.
    public static func checkIfDue(_ paths: Paths = .shared, now: Date = Date()) async -> Release? {
        var s = GlobalSettings.load(paths)
        guard s.checkForUpdates else { return nil }
        if let last = s.lastUpdateCheck, now.timeIntervalSince(last) < 86_400 { return nil }
        s.lastUpdateCheck = now
        try? s.save(paths)
        return await check()
    }

    /// Numeric dotted-version comparison ("1.10.0" > "1.9.2"); pre-release suffixes are ignored.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
