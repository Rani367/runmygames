import Foundation

/// A plain-text report to attach to bug reports (`rmg diagnose`, Help > Copy Diagnostics).
/// Paths are shortened to `~` so it does not include the user's account name.
public enum Diagnostics {
    public static func report(_ paths: Paths = .shared) -> String {
        var lines: [String] = []
        func section(_ title: String) { lines.append(""); lines.append("## \(title)") }

        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let model = Shell.output("/usr/sbin/sysctl", ["-n", "hw.model"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        let chip = Shell.output("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        lines.append("RunMyGames \(Version.current)")
        lines.append("macOS \(os), \(model), \(chip)")

        section("Health")
        lines += Doctor.checks(paths).map(Doctor.line)

        guard let m = try? Manager(paths: paths) else { return lines.joined(separator: "\n") + "\n" }
        let settings = GlobalSettings.load(paths)
        section("Settings")
        lines.append("hud=\(settings.metalHUD) retina=\(settings.retinaMode) msync=\(settings.msync) "
            + "quit-steam=\(settings.quitSteamWhenIdle) idle=\(settings.idleSeconds)s")
        lines.append("Steam running: \(m.steam.isRunning), logged in: \(m.hasSteamAccount)")

        section("Games")
        let shimmed = m.shimmedAppIDs()
        let compat = CompatDB.load(paths)
        for g in m.library.games() {
            guard g.installed else { lines.append("\(g.id) \(g.name): downloading"); continue }
            let s = GameSettings.load(g.id, paths)
            let d = m.decision(for: g, compat: compat[g.id], settings: s)
            var line = "\(g.id) \(g.name): \(d.renderer.title) (\(d.reason)); apis=\(d.apis.sorted().joined(separator: ","))"
            line += "; exe=\(d.mainExe?.lastPathComponent ?? "?")"
            if !shimmed.contains(g.id) { line += "; NOT SHIMMED" }
            if let last = m.lastRun(g.id) { line += "; last run exit=\(last.exitCode) \(last.seconds)s on \(last.renderer)" }
            if s != GameSettings() { line += "; custom settings" }
            lines.append(line)
        }

        section("shim.log (last 40 lines)")
        lines += tail(paths.rmgWin.appendingPathComponent("logs/shim.log"), 40)
        return lines.map(\.abbreviatingHome).joined(separator: "\n") + "\n"
    }

    static func tail(_ url: URL, _ n: Int) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return ["(none)"] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 64 << 10 ? size - (64 << 10) : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(n).map(String.init))
    }
}
