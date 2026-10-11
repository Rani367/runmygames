import Foundation

/// Health checks for `rmg doctor` and the app's setup screen.
public enum Doctor {
    public enum Kind: String, Sendable {
        case rosetta, engine, dxmt, d3dmetal, prefix, shim, steam
    }

    public struct Check: Identifiable, Sendable {
        public var id: String { kind.rawValue }
        public let kind: Kind
        public let name: String
        public let ok: Bool
        public let detail: String
        public let required: Bool
    }

    public static var rosettaInstalled: Bool { Shell.run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"]) == 0 }

    public static func engineDescription(_ e: Engine) -> String {
        let v = e.version
        if e.root.lastPathComponent.hasPrefix("wine-cx-") {
            let build = (try? String(contentsOf: e.root.appendingPathComponent("RMG_ENGINE_BUILD"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "CrossOver \(v) open-source Wine" + (build.map { " (build \($0))" } ?? " (built from source)")
        }
        return "Wine \(v)"
    }

    public static func checks(_ paths: Paths = .shared) -> [Check] {
        var out: [Check] = []
        let rosetta = rosettaInstalled
        out.append(Check(kind: .rosetta, name: "Rosetta 2", ok: rosetta,
                         detail: rosetta ? "installed" : "needed to run Windows games: softwareupdate --install-rosetta --agree-to-license",
                         required: true))

        let engine = try? Engine(paths: paths)
        out.append(Check(kind: .engine, name: "Wine engine", ok: engine != nil,
                         detail: engine.map(engineDescription) ?? "not installed: `rmg engine install`, or Download in RunMyGames.app",
                         required: true))
        func version(_ u: URL) -> String {
            (try? String(contentsOf: u.appendingPathComponent("VERSION"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown version"
        }
        let dxmt = paths.dxmt.appendingPathComponent("x86_64-windows/d3d11.dll").exists
        out.append(Check(kind: .dxmt, name: "DXMT (DirectX 10/11)", ok: dxmt,
                         detail: dxmt ? version(paths.dxmt) : "not installed: `rmg engine install`, or Download in RunMyGames.app",
                         required: true))
        let d3dmetal = paths.d3dmetal.appendingPathComponent("external/libd3dshared.dylib").exists
        out.append(Check(kind: .d3dmetal, name: "D3DMetal (DirectX 11/12)", ok: d3dmetal,
                         detail: d3dmetal ? version(paths.d3dmetal)
                             : "optional, for DirectX 12 games: get Apple's Game Porting Toolkit, then `rmg d3dmetal <dmg>`",
                         required: false))
        let prefixOK = paths.prefix.appendingPathComponent("system.reg").exists
        out.append(Check(kind: .prefix, name: "Windows environment", ok: prefixOK,
                         detail: prefixOK ? paths.prefix.path.abbreviatingHome : "not created yet: `rmg setup`",
                         required: true))
        out.append(Check(kind: .shim, name: "Game launcher shim", ok: paths.shim.exists,
                         detail: paths.shim.exists ? "installed" : "not installed yet: `rmg setup`", required: true))
        out.append(Check(kind: .steam, name: "Windows Steam", ok: paths.steamExe.exists,
                         detail: paths.steamExe.exists ? "installed" : "not installed yet: `rmg setup`", required: true))
        return out
    }

    /// Extra prerequisites for building the engine from source instead of downloading it.
    public static func buildChecks() -> [Check] {
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains { FileManager.default.isExecutableFile(atPath: $0) }
        let clt = Shell.run("/usr/bin/xcode-select", ["-p"]) == 0
        return [
            Check(kind: .engine, name: "Homebrew", ok: brew, detail: brew ? "installed" : "https://brew.sh", required: true),
            Check(kind: .engine, name: "Xcode Command Line Tools", ok: clt,
                  detail: clt ? "installed" : "xcode-select --install", required: true),
        ]
    }

    public static func line(_ c: Check) -> String {
        "\(c.ok ? "✓" : (c.required ? "✗" : "–")) \(c.name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(c.detail)"
    }

    public static func run(_ say: (String) -> Void) {
        for c in checks() { say(line(c)) }
    }
}

extension String {
    /// "/Users/me/Library/…" -> "~/Library/…" (shorter, and keeps user names out of shared reports).
    public var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}
