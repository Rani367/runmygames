import Foundation

/// Removes RunMyGames from the Mac (`rmg uninstall`).
public struct Uninstaller: Sendable {
    public let paths: Paths
    public init(paths: Paths = .shared) { self.paths = paths }

    /// The app bundle the running executable belongs to, if it is a RunMyGames.app.
    public var appBundle: URL? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" && app.lastPathComponent.hasPrefix("RunMyGames") ? app : nil
    }

    public var cliLink: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/rmg")
    }

    /// What `run(all:)` would delete, for the confirmation prompt.
    public func targets(all: Bool) -> [URL] {
        var out = [paths.launchers]
        if let app = appBundle { out.append(app) }
        if isOurLink(cliLink) { out.append(cliLink) }
        if all { out += [paths.home, paths.logs, paths.cache] }
        return out.filter { FileManager.default.fileExists(atPath: $0.path) || isOurLink($0) }
    }

    private func isOurLink(_ u: URL) -> Bool {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: u.path) else { return false }
        return dest.contains("RunMyGames.app")
    }

    public func run(all: Bool, say: (String) -> Void) {
        if let m = try? Manager(paths: paths) {
            m.killAll()
            // Leave Steam usable on its own if the prefix stays.
            if !all, (try? LaunchOptions.inject(appIDs: Array(m.shimmedAppIDs()), paths: paths, remove: true)) != nil {
                say("✓ Removed RunMyGames launch options from Steam")
            }
        }
        for t in targets(all: all) {
            do {
                try FileManager.default.removeItem(at: t)
                say("✓ Removed \(t.path.abbreviatingHome)")
            } catch {
                say("✗ Could not remove \(t.path.abbreviatingHome): \(RMGError.message(for: error))")
            }
        }
        if !all {
            say("Your Windows environment, Steam and games are still in \(paths.home.path.abbreviatingHome); "
                + "delete that folder to remove them too.")
        }
    }
}
