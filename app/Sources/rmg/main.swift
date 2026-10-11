import Foundation
import RMGCore

let usage = """
rmg — RunMyGames: run Windows Steam games on macOS

USAGE
  rmg setup                    Create the Windows prefix and install Steam
  rmg steam                    Open the Steam window (log in, install games)
  rmg games                    List installed games and their renderer
  rmg launch <appid> [--watch] Launch a game (--watch: close Steam when you quit)
  rmg sync                     Re-apply settings to all games (Steam must be closed)
  rmg launchers                Create Launchpad/Dock apps for all installed games
  rmg set <appid> key=value…   renderer=auto|dxmt|d3dmetal|wined3d  hud=on|off|default
                               metalfx=on|off  retina=on|off|default  args="…"  env.NAME=value
  rmg config key=value…        hud=on|off  retina=on|off  msync=on|off  quit-steam=on|off
  rmg doctor                   Check that everything is installed correctly
  rmg redist [--force]         Install the Visual C++ runtimes games need
  rmg kill                     Force-quit Steam and all games
  rmg wine <args…>             Run a program in the prefix (e.g. rmg wine winecfg)
  rmg uninstall-shim           Remove RunMyGames launch options from Steam
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("error: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func say(_ s: String) { print(s); fflush(stdout) }

func manager() -> Manager {
    do { return try Manager() } catch { fail("\(error)") }
}

func flag(_ v: String) -> Bool? {
    switch v.lowercased() {
    case "on", "yes", "true", "1": return true
    case "off", "no", "false", "0": return false
    default: return nil
    }
}

/// Runs async work from the synchronous CLI.
func blocking(_ body: @escaping @Sendable () async throws -> Void) {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var err: Error?
    Task { do { try await body() } catch { err = error }; sem.signal() }
    sem.wait()
    if let err { fail("\(err)") }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { say(usage); exit(0) }
args.removeFirst()

do {
    switch cmd {
    case "setup":
        let m = manager()
        try m.prefix.create(progress: say)
        blocking { try await Redist.installMissing(engine: m.engine, progress: say) }
        if !m.steam.installed { blocking { try await m.steam.install(progress: say) } }
        say("✓ Ready. Next: `rmg steam` to log in and install games.")

    case "steam":
        try manager().openSteam()
        say("Steam is starting…")

    case "games":
        let m = manager()
        let shimmed = m.shimmedAppIDs()
        let games = m.library.games()
        if games.isEmpty { say("No games installed yet. Use `rmg steam` to install some.") }
        for g in games {
            let d = m.policy.decide(game: g, settings: GameSettings.load(g.id), compat: CompatDB.load()[g.id])
            let state = g.installed ? (shimmed.contains(g.id) ? "" : "  (run `rmg sync` with Steam closed)") : "  [downloading]"
            say(String(format: "%8d  %-40@ %-9@ %@%@", g.id, g.name as NSString, d.renderer.title as NSString,
                       d.reason as NSString, state as NSString))
        }

    case "launch":
        guard let id = args.first.flatMap(Int.init) else { fail("usage: rmg launch <appid>") }
        let m = manager()
        try m.launch(appID: id, progress: say)
        if args.contains("--watch") { m.watch() }

    case "sync":
        let m = manager()
        if m.steam.isRunning { fail("Steam is running. Quit it first (or `rmg kill`).") }
        let games = try m.sync()
        say("✓ \(games.count) game(s) configured.")

    case "launchers":
        let m = manager()
        let factory = LauncherFactory(paths: m.paths)
        for g in m.library.games().filter(\.installed) {
            blocking {
                let url = try await factory.create(for: g, artwork: m.library.artwork(g.id))
                say("✓ \(url.path)")
            }
        }

    case "set":
        guard let id = args.first.flatMap(Int.init) else { fail("usage: rmg set <appid> key=value…") }
        var s = GameSettings.load(id)
        for kv in args.dropFirst() {
            let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { fail("expected key=value, got \(kv)") }
            let (k, v) = (parts[0].lowercased(), parts[1])
            switch k {
            case "renderer":
                if v == "auto" { s.renderer = nil; s.autoFallback = nil }
                else if let r = Renderer(rawValue: v.lowercased()) { s.renderer = r }
                else { fail("renderer must be auto, dxmt, d3dmetal or wined3d") }
            case "hud": s.metalHUD = flag(v)
            case "metalfx": s.metalFX = flag(v)
            case "retina": s.retinaMode = flag(v)
            case "args": s.args = v.isEmpty ? nil : v
            default:
                if parts[0].hasPrefix("env.") {
                    var env = s.env ?? [:]
                    env[String(parts[0].dropFirst(4))] = v.isEmpty ? nil : v
                    s.env = env.isEmpty ? nil : env
                } else { fail("unknown setting \(k)") }
            }
        }
        try s.save(id)
        let m = manager()
        if let g = m.library.game(id) {
            let d = try m.prepare(g)
            say("✓ \(g.name): \(d.renderer.title) (\(d.reason))")
        } else { say("✓ saved") }

    case "config":
        var g = GlobalSettings.load()
        for kv in args {
            let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2, let b = flag(p[1]) else { fail("expected key=on|off, got \(kv)") }
            switch p[0] {
            case "hud": g.metalHUD = b
            case "retina": g.retinaMode = b
            case "msync": g.msync = b
            case "quit-steam": g.quitSteamWhenIdle = b
            default: fail("unknown setting \(p[0])")
            }
        }
        try g.save()
        if let m = try? Manager(), m.prefix.exists, args.contains(where: { $0.hasPrefix("retina=") }) {
            try m.engine.importRegistry(Prefix.defaultsRegistry(retina: g.retinaMode))
        }
        say("✓ saved")

    case "doctor":
        Doctor.run(say)

    case "redist":
        let m = manager()
        let force = args.contains("--force")
        blocking { try await Redist.installMissing(engine: m.engine, force: force, progress: say) }
        say("✓ runtimes installed")

    case "kill":
        manager().killAll()
        say("✓ stopped")

    case "wine":
        let p = try manager().engine.run(args, wait: true)
        exit(p.terminationStatus)

    case "uninstall-shim":
        let m = manager()
        if m.steam.isRunning { fail("Quit Steam first.") }
        try LaunchOptions.inject(appIDs: Array(m.shimmedAppIDs()), paths: m.paths, remove: true)
        say("✓ removed")

    case "_make-app-icon": // build-time helper used by the Makefile
        guard let out = args.first else { fail("usage: rmg _make-app-icon <out.icns>") }
        guard let png = AppIcon.png(), let icns = IconMaker.icns(from: png) else { fail("icon rendering failed") }
        try icns.write(to: URL(fileURLWithPath: out))

    case "help", "-h", "--help":
        say(usage)

    default:
        fail("unknown command \(cmd)\n\n\(usage)")
    }
} catch {
    fail("\(error)")
}
