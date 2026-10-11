import Foundation

/// Every on-disk location RunMyGames uses.
public struct Paths: Sendable {
    public let home: URL
    public let resources: URL

    public init(home: URL? = nil, resources: URL? = nil) {
        let env = ProcessInfo.processInfo.environment
        self.home = home ?? env["RMG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/RunMyGames")
        self.resources = resources ?? Paths.locateResources()
    }

    public static let shared = Paths()

    // Engine + renderers
    public var engines: URL { home.appendingPathComponent("engines") }
    public var renderers: URL { home.appendingPathComponent("renderers") }
    public var dxmt: URL { renderers.appendingPathComponent("dxmt") }
    public var d3dmetal: URL { renderers.appendingPathComponent("d3dmetal") }

    // State
    public var prefix: URL { home.appendingPathComponent("prefix") }
    public var settingsFile: URL { home.appendingPathComponent("settings.json") }
    public var gameSettingsDir: URL { home.appendingPathComponent("games") }
    public var logs: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RunMyGames")
    }
    public var launchers: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/RunMyGames")
    }

    // Inside the Windows prefix
    public var driveC: URL { prefix.appendingPathComponent("drive_c") }
    public var rmgWin: URL { driveC.appendingPathComponent("rmg") }
    public var shim: URL { rmgWin.appendingPathComponent("rmgshim.exe") }
    public var gameEnvDir: URL { rmgWin.appendingPathComponent("games") }
    public var steamDir: URL { driveC.appendingPathComponent("Program Files (x86)/Steam") }
    public var steamExe: URL { steamDir.appendingPathComponent("steam.exe") }

    /// "C:\\..." path for a file inside the prefix's drive_c (nil if outside).
    public func windowsPath(_ url: URL) -> String? {
        let root = driveC.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(root + "/") else { return nil }
        return "C:" + p.dropFirst(root.count).replacingOccurrences(of: "/", with: "\\")
    }

    /// Windows path of the shim as Steam must see it.
    public static let shimWindowsPath = #"C:\rmg\rmgshim.exe"#

    // Bundled resources
    public var compatDB: URL { resources.appendingPathComponent("compat/games.json") }
    public var bundledShim: URL {
        let installed = resources.appendingPathComponent("rmgshim.exe")
        return installed.exists ? installed : resources.appendingPathComponent("build/rmgshim.exe") // dev checkout
    }
    public var engineScripts: URL { resources.appendingPathComponent("engine") }
    public var bundledWebhelper: URL {
        let installed = resources.appendingPathComponent("steamwebhelper.exe")
        return installed.exists ? installed : resources.appendingPathComponent("build/steamwebhelper.exe") // dev checkout
    }

    /// Engine to use: the newest CrossOver-source build (`engines/wine-cx-*`), else any
    /// other engine (the prebuilt fallback), each with a working `bin/wine`.
    public var engine: URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: engines, includingPropertiesForKeys: nil) else { return nil }
        let usable = dirs.filter { fm.isExecutableFile(atPath: $0.appendingPathComponent("bin/wine").path) }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
        return usable.last { $0.lastPathComponent.hasPrefix("wine-cx-") } ?? usable.last
    }

    /// Resources are in the .app bundle when installed, or the repo root during development.
    static func locateResources() -> URL {
        let fm = FileManager.default
        if let r = ProcessInfo.processInfo.environment["RMG_RESOURCES"] { return URL(fileURLWithPath: r) }
        if let r = Bundle.main.resourceURL, fm.fileExists(atPath: r.appendingPathComponent("compat/games.json").path) {
            return r
        }
        // argv[0] is just "rmg" when found via PATH, so use the real executable path, then
        // follow the ~/.local/bin/rmg symlink into the .app (or the dev checkout).
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var dir = exe.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            for candidate in [dir, dir.appendingPathComponent("Resources")] // .../Contents/Resources
            where fm.fileExists(atPath: candidate.appendingPathComponent("compat/games.json").path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        return Bundle.main.resourceURL ?? URL(fileURLWithPath: fm.currentDirectoryPath)
    }
}

extension URL {
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}
