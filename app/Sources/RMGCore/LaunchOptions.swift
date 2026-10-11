import Foundation

/// Puts `"C:\rmg\rmgshim.exe" %command%` in front of each game's Steam launch
/// options (Steam > game > Properties > Launch Options), keeping anything the user
/// typed there. Steam rewrites localconfig.vdf on exit, so only call this while
/// the Windows Steam client is not running.
public enum LaunchOptions {
    public static let shimPrefix = "\"\(Paths.shimWindowsPath)\" %command%"

    /// Returns the launch option string with the shim applied (idempotent).
    public static func wrap(_ existing: String) -> String {
        let s = existing.trimmingCharacters(in: .whitespaces)
        if s.contains(Paths.shimWindowsPath) { return s }
        if s.isEmpty { return shimPrefix }
        if s.contains("%command%") {
            // e.g. "SOMEVAR=1 %command% -dx11" -> keep both sides around the shim
            return s.replacingOccurrences(of: "%command%", with: shimPrefix, options: [], range: s.range(of: "%command%"))
        }
        return shimPrefix + " " + s // plain arguments for the game
    }

    /// Removes the shim again (used by `rmg uninstall`).
    public static func unwrap(_ existing: String) -> String {
        let s = existing.replacingOccurrences(of: shimPrefix, with: "%command%").trimmingCharacters(in: .whitespaces)
        return s == "%command%" ? "" : s
    }

    /// Applies the shim for the given app ids to every Steam account's localconfig.vdf.
    /// Returns the number of files changed.
    @discardableResult
    public static func inject(appIDs: [Int], paths: Paths = .shared, remove: Bool = false) throws -> Int {
        let userdata = paths.steamDir.appendingPathComponent("userdata")
        let users = (try? FileManager.default.contentsOfDirectory(atPath: userdata.path)) ?? []
        var changed = 0
        for user in users where Int(user) != nil && user != "0" {
            let url = userdata.appendingPathComponent("\(user)/config/localconfig.vdf")
            // An unreadable file for one account must not block the others.
            guard let text = try? String(contentsOf: url, encoding: .utf8), var vdf = try? VDF.parse(text) else { continue }
            if try apply(to: &vdf, appIDs: appIDs, remove: remove) {
                try? FileManager.default.removeItem(at: url.appendingPathExtension("rmg-backup"))
                try FileManager.default.copyItem(at: url, to: url.appendingPathExtension("rmg-backup"))
                try vdf.serialized().write(to: url, atomically: true, encoding: .utf8)
                changed += 1
            }
        }
        return changed
    }

    /// Pure transformation on a parsed localconfig.vdf (unit-tested).
    public static func apply(to vdf: inout VDF, appIDs: [Int], remove: Bool = false) throws -> Bool {
        // Steam has used both "apps" and "Apps" over the years; set() keeps the existing spelling.
        let appsKey = vdf[path: "UserLocalConfigStore", "Software", "Valve", "Steam"]?
            .entries.first { $0.key.caseInsensitiveCompare("apps") == .orderedSame }?.key ?? "apps"
        let base = ["UserLocalConfigStore", "Software", "Valve", "Steam", appsKey]
        var changed = false
        for id in appIDs {
            let current = vdf[path: "UserLocalConfigStore", "Software", "Valve", "Steam", appsKey, "\(id)", "LaunchOptions"]?
                .string ?? ""
            let updated = remove ? unwrap(current) : wrap(current)
            if updated != current {
                vdf.set(base + ["\(id)", "LaunchOptions"], .string(updated))
                changed = true
            }
        }
        return changed
    }
}
