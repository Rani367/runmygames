import AppKit
import RMGCore
import SwiftUI

@main
struct RunMyGamesApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("RunMyGames", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 780, minHeight: 540)
                .onAppear {
                    model.refresh()
                    model.startPolling()
                    DevSnapshot.scheduleIfRequested(model)
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About RunMyGames") { showAbout() }
            }
            CommandGroup(after: .newItem) {
                Button("Open Steam") { model.openSteam() }
                    .keyboardShortcut("o")
                    .disabled(!model.ready)
                Button("Refresh Library") { model.refresh() }
                    .keyboardShortcut("r")
            }
            CommandMenu("Games") {
                Button("Add All to Launchpad") { model.createAllLaunchers() }
                    .disabled(!model.ready || model.games.isEmpty)
                Divider()
                Button("Stop All Games and Steam…") { model.confirmStopAll = true }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .disabled(!model.ready)
            }
            CommandGroup(replacing: .help) {
                Button("RunMyGames Help") { NSWorkspace.shared.open(Project.homepage) }
                Button("Compatibility List") { NSWorkspace.shared.open(Project.compatList) }
                Divider()
                Button("Copy Diagnostics") { model.copyDiagnostics() }
                Button("Report a Bug…") { model.copyDiagnostics(thenOpen: Project.issues) }
                Button("Show Logs in Finder") { NSWorkspace.shared.open(model.paths.logs) }
            }
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }

    private func showAbout() {
        let paths = Paths.shared
        let engine = (try? Engine(paths: paths)).map(Doctor.engineDescription) ?? "not installed"
        func version(_ u: URL) -> String {
            (try? String(contentsOf: u.appendingPathComponent("VERSION"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "not installed"
        }
        let credits = """
        Engine: \(engine)
        DXMT: \(version(paths.dxmt)) · D3DMetal: \(version(paths.d3dmetal))

        Free and open source (MIT). Built on Wine (LGPL) from CodeWeavers' CrossOver source release, \
        DXMT, MoltenVK and Apple's D3DMetal. Not affiliated with Valve, CodeWeavers or Apple.
        """
        let text = NSMutableAttributedString(string: credits, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        text.append(NSAttributedString(string: "\n\(Project.homepage.absoluteString)", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .link: Project.homepage,
        ]))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: text,
            .applicationVersion: Version.current,
            .version: "",
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.ready {
                LibraryView()
            } else {
                OnboardingView()
            }
            if let status = model.status { StatusBar(status: status) }
        }
        .confirmationDialog("Stop all games and Steam?", isPresented: $model.confirmStopAll) {
            Button("Stop All", role: .destructive) { model.stopAll() }
        } message: {
            Text("Running games are closed immediately. Unsaved progress is lost.")
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    let status: AppModel.Status

    var body: some View {
        HStack(spacing: 10) {
            if status.isError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let p = status.progress {
                ProgressView(value: p).frame(width: 120)
            } else if status.busy {
                ProgressView().controlSize(.small)
            }
            Text(status.message)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer()
            if let log = status.log {
                Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                    .buttonStyle(.borderless)
            }
            if !status.busy {
                Button { model.status = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Developer aid: `RMG_SNAPSHOT=/path/shot.png` renders the main window to a PNG a few
/// seconds after launch (README screenshots, visual checks without screen-recording access).
/// `RMG_SNAPSHOT_QUIT=1` quits afterwards; `RMG_SNAPSHOT_EDIT=<appid>` shows that game's settings.
enum DevSnapshot {
    @MainActor static func scheduleIfRequested(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["RMG_SNAPSHOT"] else { return }
        let delay = Double(env["RMG_SNAPSHOT_DELAY"] ?? "") ?? 4
        if let id = env["RMG_SNAPSHOT_EDIT"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / 2) {
                model.editing = model.games.first { $0.id == id }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  case let window = main.attachedSheet ?? main,
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            if env["RMG_SNAPSHOT_QUIT"] == "1" { exit(0) } // terminate() waits for open sheets
        }
    }
}
