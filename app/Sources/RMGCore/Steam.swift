import Foundation

/// Controls the Windows Steam client inside the prefix.
public struct Steam: Sendable {
    public let engine: Engine
    public var paths: Paths { engine.paths }

    public init(engine: Engine) { self.engine = engine }

    public static let installerURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    public var installed: Bool { paths.steamExe.exists }

    /// True while any steam.exe process of our prefix is alive.
    public var isRunning: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", #"[Ss]team\.exe"#]
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0 && wineserverAlive
    }

    var wineserverAlive: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // Wine starts it as ".../lib/wine/../../bin/wineserver", so match the engine root, not the exact path.
        p.arguments = ["-f", NSRegularExpression.escapedPattern(for: engine.root.path) + ".*wineserver"]
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    public var log: URL { paths.logs.appendingPathComponent("steam.log") }

    /// The client (steamui.dll) has been downloaded by the bootstrapper.
    public var clientInstalled: Bool { paths.steamDir.appendingPathComponent("steamui.dll").exists }

    var cefDir: URL { paths.steamDir.appendingPathComponent("bin/cef/cef.win64") }

    /// Steam's UI (steamwebhelper/CEF) renders black under Wine unless it runs without
    /// Chromium's sandbox and GPU process. Steam doesn't forward switches to the helper,
    /// so RunMyGames swaps in a tiny wrapper (shim/webhelper.c) that adds them. Steam
    /// updates restore Valve's helper; this re-applies the wrapper before every start.
    public func installWebhelperWrapper() throws {
        let fm = FileManager.default
        let helper = cefDir.appendingPathComponent("steamwebhelper.exe")
        let real = cefDir.appendingPathComponent("steamwebhelper_real.exe")
        let wrapper = paths.bundledWebhelper
        guard helper.exists, wrapper.exists else { return }
        if fm.contentsEqual(atPath: helper.path, andPath: wrapper.path) { return }
        // helper is Valve's (fresh install or after an update): keep it as the real one.
        try? fm.removeItem(at: real)
        try fm.moveItem(at: helper, to: real)
        try fm.copyItem(at: wrapper, to: helper)
    }

    /// Steam command line flags. -noverifyfiles keeps the bootstrapper's size check from
    /// "repairing" the webhelper wrapper; it must not be used before the first client download.
    public var defaultArgs: [String] { clientInstalled ? ["-noverifyfiles"] : [] }

    public func install(progress: (String) -> Void = { _ in }) async throws {
        let setup = paths.driveC.appendingPathComponent("rmg/SteamSetup.exe")
        try FileManager.default.createDirectory(at: setup.deletingLastPathComponent(), withIntermediateDirectories: true)
        progress("Downloading Steam installer…")
        let (tmp, _) = try await URLSession.shared.download(from: Self.installerURL)
        try? FileManager.default.removeItem(at: setup)
        try FileManager.default.moveItem(at: tmp, to: setup)
        progress("Installing Steam…")
        try engine.run([setup.path, "/S"], log: paths.logs.appendingPathComponent("steam-install.log"))
        engine.wineserver("-w")
        guard installed else { throw RMGError.failed("Steam installer finished but steam.exe is missing (see logs).") }
    }

    /// Starts Steam (minimized to tray unless `showWindow`). Extra args are passed to steam.exe.
    public func start(showWindow: Bool = false, extra: [String] = []) throws {
        guard installed else { throw RMGError.noSteam }
        try installWebhelperWrapper()
        var args = [paths.steamExe.path] + defaultArgs + GlobalSettings.load(paths).steamArgs
        if !showWindow { args.append("-silent") }
        args += extra
        try engine.run(args, wait: false, log: log, cwd: paths.steamDir)
    }

    /// Asks a running Steam to launch a game (also works while Steam is still starting).
    public func launch(appID: Int) throws {
        try engine.run([paths.steamExe.path, "-applaunch", "\(appID)"], wait: false, log: log, cwd: paths.steamDir)
    }

    public func open(_ steamURL: String) throws {
        try engine.run([paths.steamExe.path, steamURL], wait: false, log: log, cwd: paths.steamDir)
    }

    /// Clean shutdown; kills the whole prefix if Steam does not exit in time.
    public func stop(timeout: TimeInterval = 30) {
        guard isRunning else { return }
        _ = try? engine.run([paths.steamExe.path, "-shutdown"], wait: false, cwd: paths.steamDir)
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        if isRunning { engine.wineserver("-k") }
    }
}
