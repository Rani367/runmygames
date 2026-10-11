import AppKit
import Foundation
import RMGCore

let usage = """
rmg \(Version.current) — RunMyGames: run Windows Steam games on macOS

GETTING STARTED
  rmg setup                    Download the engine, create the Windows environment, install Steam
  rmg steam                    Open the Steam window (log in, install games)
  rmg launchers                Add every installed game to Launchpad (~/Applications/RunMyGames)

PLAYING
  rmg games                    List installed games and the graphics layer each one uses
  rmg launch <appid> [--watch] Play a game (--watch: close Steam again when you quit)
  rmg kill                     Force-quit Steam and all games

SETTINGS
  rmg set <appid> [key=value…] Show or change a game's settings:
                                 renderer=auto|dxmt|d3dmetal|wined3d   hud=on|off|default
                                 metalfx=on|off|default   retina=on|off|default
                                 args="-skipintro"   env.NAME=value (empty value removes it)
  rmg config [key=value…]      Show or change global settings:
                                 hud, retina, msync, quit-steam, updates (on|off), idle=<seconds>
  rmg sync                     Re-apply settings to all games (Steam must be closed)

MAINTENANCE
  rmg doctor                   Check that everything is installed correctly
  rmg diagnose                 Print a report to attach to bug reports
  rmg engine [status|install|build]
                               Engine status, download it (install [--from <tarball>] [--force]),
                               or build it from source (needs Homebrew and Xcode, ~45 min)
  rmg d3dmetal <gptk.dmg>      Import Apple's D3DMetal (DirectX 12) from the Game Porting Toolkit
  rmg redist [--force]         Install the Visual C++ runtimes games need
  rmg update                   Update RunMyGames to the latest release
  rmg wine <args…>             Run a program in the Windows environment (e.g. rmg wine winecfg)
  rmg uninstall [--all] [--yes]
                               Remove the app, CLI and launchers (--all: also Steam, games, engine)
  rmg --version
"""

var guiMode = false

/// Launchers run `rmg` without a terminal, so in --gui mode messages also go to a log and
/// errors to a dialog instead of a stderr nobody sees.
let launchLog = Paths.shared.logs.appendingPathComponent("launch.log")

func logLaunch(_ s: String) {
    guard guiMode else { return }
    try? FileManager.default.createDirectory(at: launchLog.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let h = try? FileHandle(forWritingTo: launchLog) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    } else {
        try? line.write(to: launchLog, atomically: true, encoding: .utf8)
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + msg + "\n").utf8))
    if guiMode {
        logLaunch("error: \(msg)")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The game could not be started"
        alert.informativeText = msg
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open RunMyGames")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/RunMyGames.app"))
        }
    }
    exit(1)
}

func say(_ s: String) {
    print(s)
    fflush(stdout)
    logLaunch(s)
}

func manager() -> Manager {
    do { return try Manager() } catch { fail(RMGError.message(for: error)) }
}

/// Runs async work from the synchronous CLI.
func blocking(_ body: @escaping @Sendable () async throws -> Void) {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var err: Error?
    Task {
        do { try await body() } catch { err = error }
        sem.signal()
    }
    sem.wait()
    if let err { fail(RMGError.message(for: err)) }
}

/// A one-line progress bar that redraws in place on a terminal.
final class ProgressLine: @unchecked Sendable {
    private let lock = NSLock()
    private var label = ""
    private let tty = isatty(STDOUT_FILENO) != 0

    func update(_ step: EngineInstaller.Step) {
        lock.withLock {
            switch step {
            case let .downloading(name, f):
                let text = "Downloading \(name)… " + (f.map { "\(Int($0 * 100))%" } ?? "")
                if tty { print("\r\u{1B}[K" + text, terminator: "") } else if label != name { print(text) }
                label = name
            case let .installing(name):
                if tty { print("\r\u{1B}[K", terminator: "") }
                print("Installing \(name)…")
                label = ""
            }
            fflush(stdout)
        }
    }
}

func installEngine(from local: URL? = nil, force: Bool = false) {
    let installer: EngineInstaller
    do { installer = try EngineInstaller() } catch { fail(RMGError.message(for: error)) }
    if let m = try? Manager(), m.steam.isRunning || m.gameRunning {
        fail("Quit Steam and your games first (or `rmg kill`): the engine is in use.")
    }
    let bar = ProgressLine()
    blocking { try await installer.install(localEngine: local, force: force, progress: { bar.update($0) }) }
    if let m = try? Manager() { try? m.prefix.installRendererPlaceholders() }
    say("✓ Engine ready.")
}

func runScript(_ name: String, _ args: [String] = []) -> Int32 {
    let script = Paths.shared.engineScripts.appendingPathComponent(name)
    guard script.exists else { fail("\(name) is missing from \(Paths.shared.engineScripts.path)") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script.path] + args
    do { try p.run() } catch { fail(RMGError.message(for: error)) }
    p.waitUntilExit()
    return p.terminationStatus
}

func confirm(_ question: String) -> Bool {
    print(question + " [y/N] ", terminator: "")
    fflush(stdout)
    return ["y", "yes"].contains(readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? "")
}

extension URL {
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { say(usage); exit(0) }
args.removeFirst()

do {
    switch cmd {
    case "setup":
        if !Doctor.rosettaInstalled {
            fail("Rosetta 2 is required. Install it with: softwareupdate --install-rosetta --agree-to-license")
        }
        if (try? EngineInstaller())?.upToDate != true || (try? Engine()) == nil { installEngine() }
        let m = manager()
        try m.prefix.create(progress: say)
        blocking { try await Redist.installMissing(engine: m.engine, progress: { say($0) }) }
        if !m.steam.installed { blocking { try await m.steam.install(progress: { say($0) }) } }
        say("✓ Ready. Next: `rmg steam` to log in and install games.")

    case "steam":
        try manager().openSteam()
        say("Steam is starting…")

    case "games":
        let m = manager()
        let shimmed = m.shimmedAppIDs()
        let compat = CompatDB.load()
        let games = m.library.games()
        if games.isEmpty { say("No games installed yet. Use `rmg steam` to install some.") }
        for g in games {
            guard g.installed else {
                say(String(format: "%8d  %-40@ [downloading]", g.id, g.name as NSString))
                continue
            }
            let d = m.decision(for: g, compat: compat[g.id])
            let state = shimmed.contains(g.id) ? "" : "  (run `rmg sync` with Steam closed)"
            say(String(format: "%8d  %-40@ %-9@ %@%@", g.id, g.name as NSString, d.renderer.title as NSString,
                       d.reason as NSString, state as NSString))
        }

    case "launch":
        guiMode = args.contains("--gui")
        guard let id = args.first.flatMap(Int.init) else { fail("usage: rmg launch <appid> [--watch]") }
        if guiMode { logLaunch("launch \(id)") }
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
        let installed = m.library.games().filter(\.installed)
        for g in installed {
            blocking {
                let url = try await factory.create(for: g, artwork: m.library.artwork(g.id))
                say("✓ \(url.path.abbreviatingHome)")
            }
        }
        for name in factory.prune(keeping: Set(installed.map(\.id))) { say("– removed \(name) (no longer installed)") }
        if installed.isEmpty { say("No installed games yet.") }

    case "set":
        guard let id = args.first.flatMap(Int.init) else { fail("usage: rmg set <appid> [key=value…]") }
        var s = GameSettings.load(id)
        let changes = Array(args.dropFirst())
        for kv in changes { try CLIParsing.applyGameSetting(kv, to: &s) }
        if !changes.isEmpty { try s.save(id) }
        let m = manager()
        if let g = m.library.game(id) {
            if changes.isEmpty {
                say("\(g.name) (\(g.id))")
                for l in CLIParsing.describe(s) { say("  " + l) }
                let d = m.decision(for: g, settings: s)
                say("  → \(d.renderer.title): \(d.reason)")
            } else {
                let d = try m.prepare(g)
                say("✓ \(g.name): \(d.renderer.title) (\(d.reason))")
            }
        } else {
            if changes.isEmpty { for l in CLIParsing.describe(s) { say(l) } } else { say("✓ saved") }
        }

    case "config":
        var g = GlobalSettings.load()
        guard !args.isEmpty else {
            for l in CLIParsing.describe(g) { say(l) }
            exit(0)
        }
        let before = g
        for kv in args { try CLIParsing.applyGlobalSetting(kv, to: &g) }
        try g.save()
        if let m = try? Manager(), m.prefix.exists {
            if g.retinaMode != before.retinaMode {
                try m.engine.importRegistry(Prefix.defaultsRegistry(retina: g.retinaMode))
            }
            if g.metalHUD != before.metalHUD {
                let compat = CompatDB.load()
                for game in m.library.games().filter(\.installed) { _ = try? m.prepare(game, global: g, compatDB: compat) }
            }
        }
        say("✓ saved")

    case "doctor":
        Doctor.run(say)
        if let i = try? EngineInstaller(), (try? Engine()) != nil, !i.upToDate {
            say("  An engine update is available: `rmg engine install`")
        }

    case "diagnose":
        print(Diagnostics.report(), terminator: "")

    case "engine":
        switch args.first ?? "status" {
        case "status":
            let installer = try EngineInstaller()
            if let e = try? Engine() { say("Engine: \(Doctor.engineDescription(e)) at \(e.root.path.abbreviatingHome)") }
            else { say("Engine: not installed") }
            say("DXMT: \(installer.installedDXMT ?? "not installed")")
            say("Latest: engine build \(installer.manifest.engine.build), DXMT \(installer.manifest.dxmt.version)")
            say(installer.upToDate ? "✓ Up to date." : "Run `rmg engine install` to update.")
        case "install", "update":
            var local: URL?
            if let i = args.firstIndex(of: "--from") {
                guard i + 1 < args.count else { fail("usage: rmg engine install --from <engine.tar.xz>") }
                local = URL(fileURLWithPath: args[i + 1])
            }
            installEngine(from: local, force: args.contains("--force"))
        case "build":
            for c in Doctor.buildChecks() where !c.ok { fail("\(c.name) is required to build from source: \(c.detail)") }
            say("Building the engine from source. This takes about 45 minutes the first time.")
            exit(runScript("install-engine.sh"))
        default:
            fail("usage: rmg engine [status|install|build]")
        }

    case "d3dmetal":
        exit(runScript("import-d3dmetal.sh", args.prefix(1).map { $0 }))

    case "redist":
        let m = manager()
        let force = args.contains("--force")
        blocking { try await Redist.installMissing(engine: m.engine, force: force, progress: { say($0) }) }
        say("✓ runtimes installed")

    case "kill":
        manager().killAll()
        say("✓ stopped")

    case "wine":
        let p = try manager().engine.run(args, wait: true, inheritOutput: true)
        exit(p.terminationStatus)

    case "update":
        say("Updating with: \(Project.installCommand)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", Project.installCommand]
        try p.run()
        p.waitUntilExit()
        exit(p.terminationStatus)

    case "uninstall":
        let all = args.contains("--all")
        let u = Uninstaller()
        let targets = u.targets(all: all)
        say("This removes:")
        for t in targets { say("  " + t.path.abbreviatingHome) }
        if all { say("including the Windows environment, Steam and every installed game.") }
        guard args.contains("--yes") || confirm("Continue?") else { say("Cancelled."); exit(1) }
        u.run(all: all, say: say)

    case "uninstall-shim":
        let m = manager()
        if m.steam.isRunning { fail("Quit Steam first.") }
        try LaunchOptions.inject(appIDs: Array(m.shimmedAppIDs()), paths: m.paths, remove: true)
        say("✓ removed")

    case "_make-app-icon": // build-time helper used by the Makefile
        guard let out = args.first else { fail("usage: rmg _make-app-icon <out.icns>") }
        guard let png = AppIcon.png(), let icns = IconMaker.icns(from: png) else { fail("icon rendering failed") }
        try icns.write(to: URL(fileURLWithPath: out))

    case "_validate-compat": // CI helper
        let file = URL(fileURLWithPath: args.first ?? "compat/games.json")
        let db = try CompatDB.parse(Data(contentsOf: file))
        say("✓ \(db.count) entries")

    case "--version", "-v", "version":
        say(Version.current)

    case "help", "-h", "--help":
        say(usage)

    default:
        fail("unknown command \"\(cmd)\". Run `rmg help` for the list of commands.")
    }
} catch {
    fail(RMGError.message(for: error))
}
