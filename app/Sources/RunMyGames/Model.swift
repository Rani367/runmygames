import AppKit
import Foundation
import RMGCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var games: [Game] = []
    @Published var decisions: [Int: RendererPolicy.Decision] = [:]
    @Published var checks: [Doctor.Check] = []
    @Published var status: String?
    @Published var busy = false
    @Published var steamRunning = false
    @Published var log = ""
    @Published var global = GlobalSettings.load()

    let paths = Paths.shared

    var manager: Manager? { try? Manager(paths: paths) }
    var ready: Bool { checks.filter(\.required).allSatisfy(\.ok) }
    var d3dmetalInstalled: Bool { checks.first { $0.name.hasPrefix("D3DMetal") }?.ok == true }

    func refresh() {
        checks = Doctor.checks(paths)
        guard let m = manager else { games = []; return }
        let compat = CompatDB.load(paths)
        let list = m.library.games()
        let policy = m.policy
        Task.detached {
            var d: [Int: RendererPolicy.Decision] = [:]
            for g in list where g.installed {
                d[g.id] = policy.decide(game: g, settings: GameSettings.load(g.id), compat: compat[g.id])
            }
            let running = m.steam.isRunning
            let decisions = d
            await MainActor.run {
                self.games = list
                self.decisions = decisions
                self.steamRunning = running
            }
        }
    }

    /// Runs blocking work off the main thread with a status line.
    func perform(_ label: String, _ work: @escaping @Sendable () throws -> Void) {
        busy = true
        status = label
        Task.detached {
            do {
                try work()
                await MainActor.run { self.status = nil }
            } catch {
                await MainActor.run { self.status = "\(error)" }
            }
            await MainActor.run { self.busy = false; self.refresh() }
        }
    }

    func play(_ game: Game) {
        guard let m = manager else { return }
        perform("Starting \(game.name)…") {
            try m.launch(appID: game.id) { msg in Task { @MainActor in self.status = msg } }
            // Keep watching in the background so Steam can close itself afterwards.
            Thread.detachNewThread { m.watch() }
            Thread.sleep(forTimeInterval: 3)
        }
    }

    func openSteam() {
        guard let m = manager else { return }
        perform("Opening Steam…") { try m.openSteam(); Thread.sleep(forTimeInterval: 2) }
    }

    func stopAll() {
        guard let m = manager else { return }
        perform("Stopping Steam and games…") { m.killAll() }
    }

    func createLauncher(_ game: Game) {
        guard let m = manager else { return }
        status = "Creating launcher…"
        Task {
            do {
                let url = try await LauncherFactory(paths: paths).create(for: game, artwork: m.library.artwork(game.id))
                status = nil
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { status = "\(error)" }
        }
    }

    func createAllLaunchers() {
        guard let m = manager else { return }
        status = "Creating launchers…"
        let installed = games.filter(\.installed)
        Task {
            for g in installed { _ = try? await LauncherFactory(paths: paths).create(for: g, artwork: m.library.artwork(g.id)) }
            status = "Added \(installed.count) game(s) to ~/Applications/RunMyGames"
        }
    }

    func saveSettings(_ s: GameSettings, for game: Game) {
        guard let m = manager else { return }
        perform("Saving…") {
            try s.save(game.id, m.paths)
            try m.prepare(game)
        }
    }

    func saveGlobal() {
        let g = global
        try? g.save(paths)
        guard let m = manager, m.prefix.exists else { return }
        perform("Applying…") {
            try m.engine.importRegistry(Prefix.defaultsRegistry(retina: g.retinaMode))
            for game in m.library.games().filter(\.installed) { _ = try? m.prepare(game, global: g) }
        }
    }

    // MARK: setup

    func runScript(_ name: String, args: [String] = [], label: String) {
        busy = true
        status = label
        log = ""
        let script = paths.engineScripts.appendingPathComponent(name)
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { h in
                let s = String(decoding: h.availableData, as: UTF8.self)
                Task { @MainActor in self.log += s }
            }
            do { try p.run(); p.waitUntilExit() } catch {}
            pipe.fileHandleForReading.readabilityHandler = nil
            let ok = p.terminationStatus == 0
            await MainActor.run {
                self.busy = false
                self.status = ok ? nil : "\(label.replacingOccurrences(of: "…", with: "")) failed — see log"
                self.refresh()
            }
        }
    }

    func buildEngine() {
        runScript("install-engine.sh", label: "Building the Wine engine (20–40 min the first time)…")
    }

    func importD3DMetal() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Game Porting Toolkit .dmg downloaded from developer.apple.com"
        panel.allowedContentTypes = [.diskImage]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runScript("import-d3dmetal.sh", args: [url.path], label: "Importing D3DMetal…")
    }

    func installSteam() {
        guard let m = manager else { return }
        busy = true
        status = "Preparing Windows environment…"
        Task.detached {
            do {
                try m.prefix.create { msg in Task { @MainActor in self.status = msg } }
                try await Redist.installMissing(engine: m.engine) { msg in Task { @MainActor in self.status = msg } }
                if !m.steam.installed {
                    try await m.steam.install { msg in Task { @MainActor in self.status = msg } }
                }
                await MainActor.run { self.status = nil }
            } catch {
                await MainActor.run { self.status = "\(error)" }
            }
            await MainActor.run { self.busy = false; self.refresh() }
        }
    }
}
