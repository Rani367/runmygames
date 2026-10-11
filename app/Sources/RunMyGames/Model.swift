import AppKit
import Foundation
import RMGCore
import SwiftUI

/// Everything the window shows, loaded off the main thread in one pass.
struct LibrarySnapshot: Sendable {
    var checks: [Doctor.Check] = []
    var manager: Manager?
    var games: [Game] = []
    var decisions: [Int: RendererPolicy.Decision] = [:]
    var artwork: [Int: URL] = [:]
    var steamRunning = false
    var running: Set<Int> = []
    var hasSteamAccount = false
    var changeStamp = Date.distantPast
    var engineUpdate = false
    var engineDownloadSize: Int64?

    static func load(_ paths: Paths) -> LibrarySnapshot {
        var s = LibrarySnapshot()
        s.checks = Doctor.checks(paths)
        let installer = try? EngineInstaller(paths: paths)
        s.engineDownloadSize = installer?.manifest.engine.size
        guard let m = try? Manager(paths: paths) else { return s }
        s.manager = m
        s.engineUpdate = installer.map { !$0.upToDate } ?? false
        s.games = m.library.games()
        let compat = CompatDB.load(paths)
        for g in s.games {
            s.artwork[g.id] = m.library.artwork(g.id)
            if g.installed { s.decisions[g.id] = m.decision(for: g, compat: compat[g.id]) }
        }
        s.steamRunning = m.steam.isRunning
        s.running = s.steamRunning ? m.runningGameIDs() : []
        s.hasSteamAccount = m.hasSteamAccount
        s.changeStamp = m.library.changeStamp()
        return s
    }
}

@MainActor
final class AppModel: ObservableObject {
    struct Status: Equatable {
        var message: String
        var busy = false
        var progress: Double?
        var isError = false
        var log: URL?
    }

    @Published private(set) var games: [Game] = []
    @Published private(set) var decisions: [Int: RendererPolicy.Decision] = [:]
    @Published private(set) var artwork: [Int: URL] = [:]
    @Published private(set) var checks: [Doctor.Check] = []
    @Published private(set) var manager: Manager?
    @Published private(set) var steamRunning = false
    @Published private(set) var running: Set<Int> = []
    @Published private(set) var hasSteamAccount = false
    @Published private(set) var loaded = false
    @Published private(set) var engineUpdate = false
    @Published private(set) var engineDownloadSize: Int64?
    @Published var status: Status?
    @Published var setupLog = ""
    @Published var update: Updater.Release?
    @Published var confirmStopAll = false
    @Published var editing: Game?
    @Published var global: GlobalSettings {
        didSet { if global != oldValue { scheduleGlobalApply() } }
    }

    let paths = Paths.shared
    private var refreshGeneration = 0
    private var changeStamp = Date.distantPast
    private var pollTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var appliedGlobal: GlobalSettings
    private var launching: (id: Int, since: Date)?
    private var watching = false

    init() {
        let g = GlobalSettings.load(Paths.shared)
        global = g
        appliedGlobal = g
    }

    var busy: Bool { status?.busy == true }
    var ready: Bool { loaded && manager != nil && checks.filter(\.required).allSatisfy(\.ok) }
    func check(_ kind: Doctor.Kind) -> Doctor.Check? { checks.first { $0.kind == kind } }
    var d3dmetalInstalled: Bool { check(.d3dmetal)?.ok == true }

    // MARK: status line

    func show(_ message: String, busy: Bool = false, progress: Double? = nil, log: URL? = nil) {
        status = Status(message: message, busy: busy, progress: progress, log: log)
    }

    func showError(_ error: Error, log: URL? = nil) {
        status = Status(message: RMGError.message(for: error), isError: true, log: log)
    }

    /// Runs blocking work off the main thread with a status line; refreshes afterwards.
    func perform(_ label: String, log: URL? = nil, _ work: @escaping @Sendable () throws -> Void) {
        show(label, busy: true)
        Task.detached {
            do {
                try work()
                await MainActor.run { if self.status?.message == label { self.status = nil } }
            } catch {
                await MainActor.run { self.showError(error, log: log) }
            }
            await MainActor.run {
                if self.status?.busy == true { self.status?.busy = false }
                self.refresh()
            }
        }
    }

    /// Progress callback that hops to the main thread.
    nonisolated func reporter() -> @Sendable (String) -> Void {
        { msg in Task { @MainActor in self.status?.message = msg } }
    }

    // MARK: refresh + live updates

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let paths = paths
        Task.detached(priority: .userInitiated) {
            let snap = LibrarySnapshot.load(paths)
            await MainActor.run {
                guard generation == self.refreshGeneration else { return }
                self.apply(snap)
            }
        }
    }

    private func apply(_ s: LibrarySnapshot) {
        checks = s.checks
        manager = s.manager
        games = s.games
        decisions = s.decisions
        artwork = s.artwork
        steamRunning = s.steamRunning
        running = s.running
        hasSteamAccount = s.hasSteamAccount
        changeStamp = s.changeStamp
        engineUpdate = s.engineUpdate
        engineDownloadSize = s.engineDownloadSize
        loaded = true
    }

    /// Polls cheap state (Steam/game processes, library changes) while the app runs.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let active = NSApp.isActive
                try? await Task.sleep(for: .seconds(active ? 3 : 10))
                await self?.poll()
            }
        }
        Task {
            if let r = await Updater.checkIfDue(paths) { update = r }
        }
    }

    private func poll() async {
        guard let m = manager else { return }
        let (steam, running, stamp) = await Task.detached {
            let steam = m.steam.isRunning
            return (steam, steam ? m.runningGameIDs() : [], m.library.changeStamp())
        }.value
        steamRunning = steam
        self.running = running
        if let l = launching {
            if running.contains(l.id) {
                launching = nil
                if status?.busy == true { status = nil }
            } else if Date().timeIntervalSince(l.since) > 120 {
                launching = nil
                let name = games.first { $0.id == l.id }?.name ?? "The game"
                status = Status(message: "\(name) has not started yet. Open Steam to see what it is waiting for.")
            }
        }
        if stamp != changeStamp { refresh() }
    }

    // MARK: games

    func play(_ game: Game) {
        guard let m = manager, !busy else { return }
        show("Starting \(game.name)…", busy: true)
        let report = reporter()
        Task.detached {
            do {
                try m.launch(appID: game.id, progress: report)
                await MainActor.run {
                    self.launching = (game.id, Date())
                    self.show("Starting \(game.name)… Steam can take a moment.", busy: true)
                    self.startWatcher(m)
                }
            } catch {
                await MainActor.run { self.showError(error, log: m.steam.log) }
            }
        }
    }

    /// Closes an auto-started Steam after the game exits (one watcher at a time).
    private func startWatcher(_ m: Manager) {
        guard !watching else { return }
        watching = true
        Thread.detachNewThread {
            m.watch()
            Task { @MainActor in self.watching = false }
        }
    }

    func openSteam() {
        guard let m = manager else { return }
        perform("Opening Steam…", log: m.steam.log) { try m.openSteam() }
    }

    func stopAll() {
        guard let m = manager else { return }
        launching = nil
        perform("Stopping Steam and games…") { m.killAll() }
    }

    func createLauncher(_ game: Game) {
        let factory = LauncherFactory(paths: paths)
        let art = artwork[game.id]
        show("Adding \(game.name) to Launchpad…", busy: true)
        Task {
            do {
                let url = try await factory.create(for: game, artwork: art)
                status = Status(message: "Added \(game.name) to ~/Applications/RunMyGames.")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { showError(error) }
        }
    }

    func createAllLaunchers() {
        let factory = LauncherFactory(paths: paths)
        let installed = games.filter(\.installed)
        let art = artwork
        show("Adding games to Launchpad…", busy: true)
        Task {
            var failed = 0
            for g in installed {
                if (try? await factory.create(for: g, artwork: art[g.id])) == nil { failed += 1 }
            }
            factory.prune(keeping: Set(installed.map(\.id)))
            status = Status(message: "Added \(installed.count - failed) game(s) to ~/Applications/RunMyGames."
                + (failed > 0 ? " \(failed) failed." : ""), isError: failed > 0)
        }
    }

    func saveSettings(_ s: GameSettings, for game: Game) {
        guard let m = manager else { return }
        let paths = paths
        perform("Saving \(game.name) settings…") {
            try s.save(game.id, paths)
            try m.prepare(game)
        }
    }

    // MARK: global settings (applied as you change them)

    private func scheduleGlobalApply() {
        applyTask?.cancel()
        applyTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            applyGlobal()
        }
    }

    private func applyGlobal() {
        var g = global
        let before = appliedGlobal
        let paths = paths
        // Keep bookkeeping written by the update checker meanwhile.
        g.lastUpdateCheck = GlobalSettings.load(paths).lastUpdateCheck
        do { try g.save(paths) } catch { showError(error); return }
        appliedGlobal = g
        let saved = g
        guard let m = manager, m.prefix.exists, g.retinaMode != before.retinaMode || g.metalHUD != before.metalHUD
        else { return }
        perform("Applying settings…") {
            let g = saved
            if g.retinaMode != before.retinaMode {
                try m.engine.importRegistry(Prefix.defaultsRegistry(retina: g.retinaMode))
            }
            let compat = CompatDB.load(paths)
            for game in m.library.games().filter(\.installed) { _ = try? m.prepare(game, global: g, compatDB: compat) }
        }
    }

    // MARK: setup

    func installRosetta() {
        perform("Installing Rosetta 2 (macOS asks for your password)…") {
            let script = #"do shell script "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" with administrator privileges"#
            guard Shell.run("/usr/bin/osascript", ["-e", script]) == 0, Doctor.rosettaInstalled else {
                throw RMGError.failed("Rosetta 2 was not installed. You can also run: softwareupdate --install-rosetta --agree-to-license")
            }
        }
    }

    func downloadEngine() {
        guard !busy else { return }
        if steamRunning {
            status = Status(message: "Quit Steam and your games before updating the engine.", isError: true)
            return
        }
        show("Preparing download…", busy: true)
        let paths = paths
        Task.detached {
            do {
                let installer = try EngineInstaller(paths: paths)
                try await installer.install { step in
                    Task { @MainActor in
                        switch step {
                        case let .downloading(name, f): self.show("Downloading \(name)…", busy: true, progress: f)
                        case let .installing(name): self.show("Installing \(name)…", busy: true)
                        }
                    }
                }
                if let m = try? Manager(paths: paths) { try? m.prefix.installRendererPlaceholders() }
                await MainActor.run { self.status = nil }
            } catch {
                await MainActor.run { self.showError(error) }
            }
            await MainActor.run { self.refresh() }
        }
    }

    func runScript(_ name: String, args: [String] = [], label: String) {
        guard !busy else { return }
        show(label, busy: true)
        setupLog = ""
        let script = paths.engineScripts.appendingPathComponent(name)
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let reader = LogReader { chunk in Task { @MainActor in self.appendLog(chunk) } }
            pipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty {
                    h.readabilityHandler = nil // EOF: stop, or this fires in a loop
                    reader.finish()
                } else {
                    reader.feed(data)
                }
            }
            var started = true
            do { try p.run() } catch { started = false }
            if started { p.waitUntilExit() }
            let ok = started && p.terminationStatus == 0
            await MainActor.run {
                self.status = ok ? nil : Status(message: "\(label.replacingOccurrences(of: "…", with: "")) failed. See the log below.",
                                                isError: true)
                self.refresh()
            }
        }
    }

    private func appendLog(_ s: String) {
        setupLog += s
        // The view only needs the tail; a full engine build prints a lot.
        if setupLog.count > 200_000 { setupLog = String(setupLog.suffix(150_000)) }
    }

    func buildEngine() {
        runScript("install-engine.sh", label: "Building the Wine engine from source (about 45 minutes)…")
    }

    func importD3DMetal() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Game Porting Toolkit .dmg you downloaded from developer.apple.com"
        panel.allowedContentTypes = [.diskImage]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runScript("import-d3dmetal.sh", args: [url.path], label: "Importing D3DMetal…")
    }

    func installSteam() {
        guard let m = manager, !busy else { return }
        show("Preparing the Windows environment…", busy: true)
        let report = reporter()
        Task.detached {
            do {
                try m.prefix.create(progress: report)
                try await Redist.installMissing(engine: m.engine, progress: report)
                if !m.steam.installed { try await m.steam.install(progress: report) }
                await MainActor.run { self.status = nil }
            } catch {
                await MainActor.run { self.showError(error, log: m.paths.logs) }
            }
            await MainActor.run { self.refresh() }
        }
    }

    // MARK: help

    func copyDiagnostics(thenOpen url: URL? = nil) {
        let paths = paths
        show("Collecting diagnostics…", busy: true)
        Task.detached {
            let report = Diagnostics.report(paths)
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                self.status = Status(message: "Diagnostics copied to the clipboard." + (url == nil ? "" : " Paste them into the bug report."))
                if let url { NSWorkspace.shared.open(url) }
            }
        }
    }

    func openInTerminal(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        Task.detached { Shell.run("/usr/bin/osascript", ["-e", script]) }
    }
}

/// Turns pipe chunks into text without splitting UTF-8 sequences across chunks.
final class LogReader: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    private let emit: (String) -> Void

    init(_ emit: @escaping (String) -> Void) { self.emit = emit }

    func feed(_ data: Data) {
        let text: String? = lock.withLock {
            pending.append(data)
            // Hold back an incomplete trailing sequence (at most 3 bytes).
            var cut = pending.count
            for back in 1...min(3, pending.count) {
                let b = pending[pending.count - back]
                if b & 0xC0 == 0xC0 { // lead byte: is its sequence complete?
                    let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : 2
                    if back < need { cut = pending.count - back }
                    break
                }
                if b & 0x80 == 0 { break }
            }
            let chunk = pending.prefix(cut)
            pending.removeFirst(cut)
            return chunk.isEmpty ? nil : String(decoding: chunk, as: UTF8.self)
        }
        if let text { emit(text) }
    }

    func finish() {
        let rest: Data = lock.withLock {
            defer { pending.removeAll() }
            return pending
        }
        if !rest.isEmpty { emit(String(decoding: rest, as: UTF8.self)) }
    }
}
