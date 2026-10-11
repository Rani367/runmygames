import Foundation

/// `key=value` handling for `rmg set` and `rmg config` (kept here so it is unit-tested).
public enum CLIParsing {
    public static func flag(_ v: String) -> Bool? {
        switch v.lowercased() {
        case "on", "yes", "true", "1": return true
        case "off", "no", "false", "0": return false
        default: return nil
        }
    }

    /// on/off, or default/auto to follow the global setting.
    static func triState(_ key: String, _ v: String) throws -> Bool? {
        if ["default", "auto", ""].contains(v.lowercased()) { return nil }
        guard let b = flag(v) else { throw RMGError.failed("\(key) must be on, off or default (got \"\(v)\")") }
        return b
    }

    static func split(_ kv: String) throws -> (String, String) {
        let parts = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else { throw RMGError.failed("expected key=value, got \"\(kv)\"") }
        return (parts[0], parts[1])
    }

    public static func applyGameSetting(_ kv: String, to s: inout GameSettings) throws {
        let (key, v) = try split(kv)
        switch key.lowercased() {
        case "renderer":
            if v.lowercased() == "auto" { s.resetRenderer() }
            else if let r = Renderer(rawValue: v.lowercased()) { s.renderer = r }
            else { throw RMGError.failed("renderer must be auto, dxmt, d3dmetal or wined3d") }
        case "hud": s.metalHUD = try triState("hud", v)
        case "metalfx": s.metalFX = try triState("metalfx", v)
        case "retina": s.retinaMode = try triState("retina", v)
        case "args": s.args = v.isEmpty ? nil : v
        default:
            guard key.hasPrefix("env.") else {
                throw RMGError.failed("unknown setting \"\(key)\" (renderer, hud, metalfx, retina, args, env.NAME)")
            }
            let name = String(key.dropFirst(4))
            guard EnvFile.isValidKey(name) else { throw RMGError.failed("\"\(name)\" is not a valid environment variable name") }
            var env = s.env ?? [:]
            env[name] = v.isEmpty ? nil : v
            s.env = env.isEmpty ? nil : env
        }
    }

    public static func applyGlobalSetting(_ kv: String, to g: inout GlobalSettings) throws {
        let (key, v) = try split(kv)
        if key == "idle" {
            guard let n = Int(v), (0...3600).contains(n) else { throw RMGError.failed("idle must be seconds between 0 and 3600") }
            g.idleSeconds = n
            return
        }
        guard let b = flag(v) else { throw RMGError.failed("\(key) must be on or off (got \"\(v)\")") }
        switch key {
        case "hud": g.metalHUD = b
        case "retina": g.retinaMode = b
        case "msync": g.msync = b
        case "quit-steam": g.quitSteamWhenIdle = b
        case "updates": g.checkForUpdates = b
        default: throw RMGError.failed("unknown setting \"\(key)\" (hud, retina, msync, quit-steam, idle, updates)")
        }
    }

    public static func describe(_ g: GlobalSettings) -> [String] {
        func onOff(_ b: Bool) -> String { b ? "on" : "off" }
        return ["hud=\(onOff(g.metalHUD))", "retina=\(onOff(g.retinaMode))", "msync=\(onOff(g.msync))",
                "quit-steam=\(onOff(g.quitSteamWhenIdle))", "idle=\(g.idleSeconds)", "updates=\(onOff(g.checkForUpdates))"]
    }

    public static func describe(_ s: GameSettings) -> [String] {
        func tri(_ b: Bool?) -> String { b.map { $0 ? "on" : "off" } ?? "default" }
        var out = ["renderer=\(s.renderer?.rawValue ?? "auto")", "hud=\(tri(s.metalHUD))", "metalfx=\(tri(s.metalFX))",
                   "retina=\(tri(s.retinaMode))"]
        if let a = s.args { out.append("args=\(a)") }
        for (k, v) in (s.env ?? [:]).sorted(by: { $0.key < $1.key }) { out.append("env.\(k)=\(v)") }
        if let f = s.autoFallback { out.append("(automatic choice switched to \(f.rawValue) after a crash)") }
        return out
    }
}
