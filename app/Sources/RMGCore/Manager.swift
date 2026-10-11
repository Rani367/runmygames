import Foundation

/// High-level operations shared by the CLI and the app.
public struct Manager: Sendable {
    public let engine: Engine
    public let paths: Paths
    public let steam: Steam
    public let prefix: Prefix
    public let library: SteamLibrary
    public let policy: RendererPolicy
    public let scans: ScanCache

    public init(paths: Paths = .shared) throws {
        engine = try Engine(paths: paths)
        self.paths = paths
        steam = Steam(engine: engine)
        prefix = Prefix(engine: engine)
        library = SteamLibrary(paths: paths)
        policy = RendererPolicy(engine: engine)
        scans = ScanCache(paths: paths)
    }

    // MARK: per-game preparation

    public struct LastRun: Equatable, Sendable {
        public var exitCode: Int64
        public var seconds: Int
        public var renderer: String
        public var date: Date?

        /// Exited with an error before the game could plausibly have reached its menu.
        public var crashedOnStart: Bool { exitCode != 0 && seconds < 15 }
    }

    /// Written by rmgshim.exe when a game exits: "exit=<code> seconds=<n> renderer=<name>".
    public func lastRun(_ id: Int) -> LastRun? {
        let url = paths.gameEnvDir.appendingPathComponent("\(id).last")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var run = Self.parseLastRun(s)
        run?.date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return run
    }

    static func parseLastRun(_ s: String) -> LastRun? {
        var kv: [String: String] = [:]
        for part in s.split(whereSeparator: \.isWhitespace) {
            let p = part.split(separator: "=", maxSplits: 1)
            if p.count == 2 { kv[String(p[0])] = String(p[1]) }
        }
        guard let code = kv["exit"].flatMap({ Int64($0) }), let secs = kv["seconds"].flatMap(Int.init) else { return nil }
        return LastRun(exitCode: code, seconds: secs, renderer: kv["renderer"] ?? "")
    }

    /// The renderer decision for display (cached scan, no side effects).
    public func decision(for game: Game, compat: CompatEntry? = nil, settings: GameSettings? = nil) -> RendererPolicy.Decision {
        policy.decide(game: game, settings: settings ?? GameSettings.load(game.id, paths),
                      compat: compat ?? CompatDB.load(paths)[game.id], scan: scans.scan(game))
    }

    /// When the automatically chosen renderer crashed on start, picks the next one not yet tried.
    /// Returns the updated settings, or nil to keep the current choice. Each renderer is tried at
    /// most once, so a game that crashes everywhere does not flip between renderers forever.
    static func autoFallback(settings: GameSettings, compat: CompatEntry?, current: Renderer,
                             lastRun: LastRun?, candidates: [Renderer]) -> GameSettings? {
        guard settings.renderer == nil, compat?.renderer == nil, let last = lastRun, last.crashedOnStart,
              last.renderer == current.rawValue else { return nil }
        var tried = settings.triedRenderers ?? []
        if !tried.contains(current) { tried.append(current) }
        var s = settings
        s.triedRenderers = tried
        guard let next = candidates.first(where: { !tried.contains($0) }) else { return s }
        s.autoFallback = next
        return s
    }

    /// Decides the renderer and writes C:\rmg\games\<id>.env for the shim.
    @discardableResult
    public func prepare(_ game: Game, global: GlobalSettings? = nil, compatDB: [Int: CompatEntry]? = nil) throws
        -> RendererPolicy.Decision {
        let global = global ?? GlobalSettings.load(paths)
        let compat = (compatDB ?? CompatDB.load(paths))[game.id]
        var settings = GameSettings.load(game.id, paths)
        let scan = scans.scan(game)
        var decision = policy.decide(game: game, settings: settings, compat: compat, scan: scan)

        if let updated = Self.autoFallback(settings: settings, compat: compat, current: decision.renderer,
                                           lastRun: lastRun(game.id), candidates: policy.fallbacks(after: decision.renderer)) {
            let from = decision.renderer
            settings = updated
            try settings.save(game.id, paths)
            // Consumed: the next crash report is about the new renderer.
            try? FileManager.default.removeItem(at: paths.gameEnvDir.appendingPathComponent("\(game.id).last"))
            decision = policy.decide(game: game, settings: settings, compat: compat, scan: scan)
            if decision.renderer != from { decision.switchedFrom = from }
        }

        var env = policy.environment(for: decision, settings: settings, global: global, compat: compat)
        env["RMG_RENDERER"] = decision.renderer.rawValue
        try FileManager.default.createDirectory(at: paths.gameEnvDir, withIntermediateDirectories: true)
        let body = EnvFile.render(env, header: ["Generated by RunMyGames \(Version.current); change game settings in the app or with `rmg set` instead.",
                                                "\(game.name): \(decision.renderer.title) (\(decision.reason))"])
        let url = paths.gameEnvDir.appendingPathComponent("\(game.id).env")
        if (try? String(contentsOf: url, encoding: .utf8)) != body {
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        try applyRetina(settings.retinaMode, exe: decision.mainExe?.lastPathComponent, appID: game.id)
        return decision
    }

    // MARK: Retina (per executable, in the registry)

    public struct RetinaState: Codable, Equatable, Sendable {
        public var exe: String
        public var on: Bool
    }

    public enum RetinaOp: Equatable, Sendable {
        case set(exe: String, on: Bool)
        case remove(exe: String)
    }

    /// Registry changes needed to go from what was applied last time to what the settings ask for.
    static func retinaOps(desired: Bool?, exe: String?, applied: RetinaState?) -> [RetinaOp] {
        var ops: [RetinaOp] = []
        let target = zip2(exe, desired).map { RetinaState(exe: $0, on: $1) }
        if target == applied { return [] }
        if let a = applied, a.exe != target?.exe { ops.append(.remove(exe: a.exe)) }
        if let t = target { ops.append(.set(exe: t.exe, on: t.on)) }
        return ops
    }

    private func applyRetina(_ desired: Bool?, exe: String?, appID: Int) throws {
        let stateURL = paths.gameSettingsDir.appendingPathComponent("\(appID).retina.json")
        let applied = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(RetinaState.self, from: $0) }
        let ops = Self.retinaOps(desired: desired, exe: exe, applied: applied)
        guard !ops.isEmpty else { return }
        // A missing exe (game not found) keeps the old state on disk until it can be applied.
        if exe == nil, desired != nil { return }
        try prefix.applyRetina(ops)
        if let exe, let desired {
            try JSON.encode(RetinaState(exe: exe, on: desired)).write(to: stateURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: stateURL)
        }
    }

    // MARK: Steam integration

    /// App ids whose Steam launch options already route through the shim.
    public func shimmedAppIDs() -> Set<Int> {
        let userdata = paths.steamDir.appendingPathComponent("userdata")
        var ids = Set<Int>()
        for user in (try? FileManager.default.contentsOfDirectory(atPath: userdata.path)) ?? [] {
            let url = userdata.appendingPathComponent("\(user)/config/localconfig.vdf")
            guard let t = try? String(contentsOf: url, encoding: .utf8), let vdf = try? VDF.parse(t),
                  let apps = vdf[path: "UserLocalConfigStore", "Software", "Valve", "Steam"]?.entries
                    .first(where: { $0.key.caseInsensitiveCompare("apps") == .orderedSame })?.value else { continue }
            for (k, v) in apps.entries where v["LaunchOptions"]?.string?.contains(Paths.shimWindowsPath) == true {
                if let id = Int(k) { ids.insert(id) }
            }
        }
        return ids
    }

    public var hasSteamAccount: Bool {
        let userdata = paths.steamDir.appendingPathComponent("userdata")
        return ((try? FileManager.default.contentsOfDirectory(atPath: userdata.path)) ?? []).contains { Int($0) ?? 0 > 0 }
    }

    /// Writes env files for every installed game and, if Steam is stopped, routes them through the shim.
    @discardableResult
    public func sync() throws -> [Game] {
        try prefix.installShim()
        let games = library.games().filter(\.installed)
        let global = GlobalSettings.load(paths)
        let compat = CompatDB.load(paths)
        for g in games { _ = try? prepare(g, global: global, compatDB: compat) }
        if !steam.isRunning { try LaunchOptions.inject(appIDs: games.map(\.id), paths: paths) }
        return games
    }

    private var autostartMarker: URL { paths.home.appendingPathComponent(".steam-autostarted") }

    /// The one-click path used by launchers: make sure everything is wired up, then play.
    public func launch(appID: Int, progress: (String) -> Void = { _ in }) throws {
        guard steam.installed else { throw RMGError.noSteam }
        try prefix.installShim()
        if let game = library.game(appID) {
            let d = try prepare(game)
            if let from = d.switchedFrom {
                progress("\(game.name) crashed on start with \(from.title) last time; trying \(d.renderer.title).")
            }
            progress("\(game.name): \(d.renderer.title) — \(d.reason)")
        }
        if steam.isRunning {
            let shimmed = shimmedAppIDs().contains(appID)
            if shimmed || !hasSteamAccount {
                try steam.launch(appID: appID)
                return
            }
            // Newly installed game: Steam must be closed to update its launch options. Never
            // restart it under another running game; this one then starts without our settings.
            if gameRunning {
                progress("Another game is running, so this one starts without RunMyGames settings. Quit the other game first for the full setup.")
                try steam.launch(appID: appID)
                return
            }
            progress("Restarting Steam once to enable RunMyGames for this game…")
            steam.stop()
        }
        try prefix.upgradeIfNeeded(progress: progress)
        try sync()
        try? Data().write(to: autostartMarker)
        try steam.start(extra: ["-applaunch", "\(appID)"])
    }

    /// Is any game (shim) process alive?
    public var gameRunning: Bool {
        Shell.run("/usr/bin/pgrep", ["-f", #"rmgshim\.exe"#]) == 0
    }

    /// App ids of games running right now. The shim keeps C:\rmg\games\<id>.running while its
    /// game is up; leftovers from a force-quit are ignored (and cleaned) once no shim is alive.
    public func runningGameIDs() -> Set<Int> {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: paths.gameEnvDir.path)) ?? []).filter { $0.hasSuffix(".running") }
        guard !files.isEmpty else { return [] }
        guard gameRunning else {
            for f in files { try? fm.removeItem(at: paths.gameEnvDir.appendingPathComponent(f)) }
            return []
        }
        return Set(files.compactMap { Int($0.dropLast(".running".count)) })
    }

    /// Waits for the game to start and exit, then closes an auto-started Steam after the idle period.
    public func watch(startTimeout: TimeInterval = 300, startupGrace: TimeInterval = 20) {
        let global = GlobalSettings.load(paths)
        var waitingSince = Date()
        while true {
            // Steam (and its wineserver) can take a moment to show up after `start`.
            while !gameRunning {
                let waited = Date().timeIntervalSince(waitingSince)
                if waited > startTimeout { return }
                if waited > startupGrace, !steam.isRunning { return }
                Thread.sleep(forTimeInterval: 2)
            }
            while gameRunning { Thread.sleep(forTimeInterval: 3) }
            guard global.quitSteamWhenIdle, autostartMarker.exists else { return }
            let idleStart = Date()
            var relaunched = false
            while Date().timeIntervalSince(idleStart) < TimeInterval(global.idleSeconds) {
                if gameRunning { relaunched = true; break }
                if !steam.isRunning { return }
                Thread.sleep(forTimeInterval: 3)
            }
            if relaunched { waitingSince = Date(); continue }
            // The user may have opened the Steam window meanwhile (marker removed): leave it running.
            guard autostartMarker.exists, !gameRunning else { return }
            try? FileManager.default.removeItem(at: autostartMarker)
            steam.stop()
            return
        }
    }

    /// Opens the Steam window (user-initiated, never auto-closed).
    public func openSteam() throws {
        try? FileManager.default.removeItem(at: autostartMarker)
        if steam.isRunning { try steam.open("steam://open/main"); return }
        try prefix.upgradeIfNeeded()
        try sync()
        try steam.start(showWindow: true)
    }

    public func killAll() {
        try? FileManager.default.removeItem(at: autostartMarker)
        engine.wineserver("-k")
    }
}

/// The KEY=VALUE file rmgshim.exe reads. One variable per line, so keys are restricted to
/// environment-variable characters and line breaks in values become spaces.
public enum EnvFile {
    public static func isValidKey(_ k: String) -> Bool {
        guard let first = k.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return k.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    public static func sanitize(_ v: String) -> String {
        v.components(separatedBy: .newlines).joined(separator: " ")
    }

    public static func render(_ env: [String: String], header: [String]) -> String {
        let head = header.map { "# " + sanitize($0) }
        let body = env.keys.sorted().filter(isValidKey).map { "\($0)=\(sanitize(env[$0]!))" }
        return (head + body).joined(separator: "\n") + "\n"
    }
}

private func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
