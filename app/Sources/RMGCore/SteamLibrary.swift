import Foundation

public struct Game: Identifiable, Hashable, Sendable {
    public let id: Int          // Steam appid
    public let name: String
    public let installDir: URL
    public let installed: Bool  // fully downloaded (StateFlags has bit 4)
    public let sizeOnDisk: Int64
}

/// Reads the Windows Steam client's libraries inside the prefix.
public struct SteamLibrary: Sendable {
    public let paths: Paths
    public init(paths: Paths = .shared) { self.paths = paths }

    /// Non-game app ids Steam installs as "apps" (runtimes, redistributables).
    static let ignoredAppIDs: Set<Int> = [228980 /* Steamworks Common Redistributables */]

    /// steamapps folders: the default one plus any from libraryfolders.vdf.
    public func libraryFolders() -> [URL] {
        var folders = [paths.steamDir.appendingPathComponent("steamapps")]
        let vdfURL = paths.steamDir.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdfURL, encoding: .utf8), let vdf = try? VDF.parse(text) {
            for (_, lib) in vdf["libraryfolders"]?.entries ?? [] {
                if let p = lib["path"]?.string, let u = unixPath(p) {
                    let sa = u.appendingPathComponent("steamapps")
                    if !folders.contains(where: { $0.standardizedFileURL == sa.standardizedFileURL }) { folders.append(sa) }
                }
            }
        }
        return folders.filter(\.exists)
    }

    public func games() -> [Game] {
        var out: [Int: Game] = [:]
        let fm = FileManager.default
        for lib in libraryFolders() {
            let files = (try? fm.contentsOfDirectory(atPath: lib.path)) ?? []
            for f in files where f.hasPrefix("appmanifest_") && f.hasSuffix(".acf") {
                guard let text = try? String(contentsOf: lib.appendingPathComponent(f), encoding: .utf8),
                      let acf = try? VDF.parse(text), let st = acf["AppState"],
                      let id = st["appid"]?.string.flatMap(Int.init), !Self.ignoredAppIDs.contains(id),
                      let dir = st["installdir"]?.string else { continue }
                let flags = st["StateFlags"]?.string.flatMap(Int.init) ?? 0
                out[id] = Game(id: id, name: st["name"]?.string ?? "App \(id)",
                               installDir: lib.appendingPathComponent("common").appendingPathComponent(dir),
                               installed: flags & 4 != 0,
                               sizeOnDisk: st["SizeOnDisk"]?.string.flatMap(Int64.init) ?? 0)
            }
        }
        return out.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func game(_ id: Int) -> Game? { games().first { $0.id == id } }

    /// Maps "C:\\Program Files (x86)\\Steam" or "Z:\\Users\\..." to a Unix URL.
    public func unixPath(_ windows: String) -> URL? {
        let p = windows.replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\", with: "/")
        guard p.count >= 2, p.dropFirst().first == ":" else { return nil }
        let drive = p.prefix(1).lowercased()
        let rest = String(p.dropFirst(2))
        if drive == "z" { return URL(fileURLWithPath: rest.isEmpty ? "/" : rest) }
        let devices = paths.prefix.appendingPathComponent("dosdevices/\(drive):")
        return devices.resolvingSymlinksInPath().appendingPathComponent(String(rest.drop { $0 == "/" }))
    }

    /// Artwork Steam already cached (portrait capsule preferred). Handles both the
    /// flat (`<id>_library_600x900.jpg`) and per-app folder cache layouts.
    public func artwork(_ id: Int, portraitOnly: Bool = false) -> URL? {
        let cache = paths.steamDir.appendingPathComponent("appcache/librarycache")
        let candidates = ["library_600x900_2x.jpg", "library_600x900.jpg"]
            + (portraitOnly ? [] : ["header.jpg", "library_header.jpg"])
        let folder = cache.appendingPathComponent("\(id)")
        let fm = FileManager.default
        for c in candidates {
            let flat = cache.appendingPathComponent("\(id)_\(c)")
            if flat.exists { return flat }
            if let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil) {
                for case let u as URL in e where u.lastPathComponent == c { return u }
            }
        }
        return nil
    }

    /// Public CDN fallback for artwork (no login needed).
    public static func artworkCDN(_ id: Int) -> URL {
        URL(string: "https://shared.steamstatic.com/store_item_assets/steam/apps/\(id)/library_600x900_2x.jpg")!
    }
}
