import Foundation

/// Health checks for `rmg doctor` and the app's setup screen.
public enum Doctor {
    public struct Check: Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public let ok: Bool
        public let detail: String
        public let required: Bool
    }

    public static func checks(_ paths: Paths = .shared) -> [Check] {
        var out: [Check] = []
        let rosetta = Process()
        rosetta.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        rosetta.arguments = ["-x86_64", "/usr/bin/true"]
        rosetta.standardError = FileHandle.nullDevice
        try? rosetta.run(); rosetta.waitUntilExit()
        out.append(Check(name: "Rosetta 2", ok: rosetta.terminationStatus == 0,
                         detail: rosetta.terminationStatus == 0 ? "installed" : "softwareupdate --install-rosetta",
                         required: true))

        let engine = try? Engine(paths: paths)
        out.append(Check(name: "Wine engine", ok: engine != nil,
                         detail: engine.map { "CrossOver-source Wine \($0.version)" } ?? "run engine/build-wine.sh",
                         required: true))
        func version(_ u: URL) -> String {
            (try? String(contentsOf: u.appendingPathComponent("VERSION"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        }
        out.append(Check(name: "DXMT (DirectX 10/11)", ok: engine?.dxmtAvailable == true,
                         detail: engine?.dxmtAvailable == true ? version(paths.dxmt) : "run engine/fetch-dxmt.sh",
                         required: true))
        out.append(Check(name: "D3DMetal (DirectX 11/12)", ok: engine?.d3dmetalAvailable == true,
                         detail: engine?.d3dmetalAvailable == true ? version(paths.d3dmetal)
                             : "optional: download the Game Porting Toolkit from developer.apple.com, then import it",
                         required: false))
        let prefixOK = paths.prefix.appendingPathComponent("system.reg").exists
        out.append(Check(name: "Windows prefix", ok: prefixOK, detail: prefixOK ? paths.prefix.path : "rmg setup",
                         required: true))
        out.append(Check(name: "Shim", ok: paths.shim.exists, detail: paths.shim.exists ? "installed" : "rmg setup",
                         required: true))
        out.append(Check(name: "Windows Steam", ok: paths.steamExe.exists,
                         detail: paths.steamExe.exists ? "installed" : "rmg setup", required: true))
        return out
    }

    public static func run(_ say: (String) -> Void) {
        for c in checks() {
            say("\(c.ok ? "✓" : (c.required ? "✗" : "–")) \(c.name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(c.detail)")
        }
    }
}
