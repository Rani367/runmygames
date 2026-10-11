import AppKit
import RMGCore
import SwiftUI

@main
struct RunMyGamesApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("RunMyGames") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear { model.refresh() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Steam") { model.openSteam() }.keyboardShortcut("o")
                Button("Refresh Library") { model.refresh() }.keyboardShortcut("r")
            }
        }
        Settings {
            GlobalSettingsView().environmentObject(model).frame(width: 440)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.ready && model.manager != nil {
                LibraryView()
            } else {
                SetupView()
            }
            if let status = model.status {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(status).font(.callout).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    if !model.busy { Button("Dismiss") { model.status = nil }.buttonStyle(.borderless) }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.bar)
            }
        }
    }
}

// MARK: - Library

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Game?
    @State private var query = ""

    var visible: [Game] {
        query.isEmpty ? model.games : model.games.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if model.games.isEmpty {
                ContentUnavailableView {
                    Label("No games yet", systemImage: "gamecontroller")
                } description: {
                    Text("Open Steam, log in and install your Windows games. They show up here automatically.")
                } actions: {
                    Button("Open Steam") { model.openSteam() }.buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18)], spacing: 22) {
                        ForEach(visible) { game in
                            GameCard(game: game, decision: model.decisions[game.id])
                                .onTapGesture(count: 2) { if game.installed { model.play(game) } }
                                .contextMenu {
                                    Button("Play") { model.play(game) }.disabled(!game.installed)
                                    Button("Game Settings…") { editing = game }
                                    Button("Add to Applications / Launchpad") { model.createLauncher(game) }
                                    Divider()
                                    Button("Show Files in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([game.installDir])
                                    }
                                }
                                .popover(isPresented: Binding(get: { editing == game }, set: { if !$0 { editing = nil } })) {
                                    GameSettingsView(game: game, decision: model.decisions[game.id]).environmentObject(model)
                                }
                        }
                    }
                    .padding(20)
                }
                .searchable(text: $query, placement: .toolbar)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { model.createAllLaunchers() } label: { Label("Add All to Launchpad", systemImage: "square.grid.3x3") }
                    .help("Create a Mac app for every installed game in ~/Applications/RunMyGames")
                Button { model.openSteam() } label: { Label("Steam", systemImage: "cart") }
                    .help("Open the Steam store and library (install games, log in)")
                Button { model.stopAll() } label: { Label("Stop All", systemImage: "stop.circle") }
                    .help("Force-quit Steam and every running game")
            }
        }
        .navigationTitle("RunMyGames")
        .navigationSubtitle(model.steamRunning ? "Steam running" : "\(model.games.count) games")
    }
}

struct GameCard: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    let decision: RendererPolicy.Decision?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Artwork(id: game.id, local: model.manager?.library.artwork(game.id))
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        if hover && game.installed {
                            ZStack {
                                Color.black.opacity(0.35)
                                Button { model.play(game) } label: {
                                    Label("Play", systemImage: "play.fill").font(.headline).padding(.horizontal, 6)
                                }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .shadow(radius: hover ? 8 : 3, y: 2)
                if let d = decision {
                    Text(d.renderer.title)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6)
                        .help(d.reason)
                }
            }
            Text(game.name).font(.callout.weight(.medium)).lineLimit(1)
            Text(game.installed ? ByteCountFormatter.string(fromByteCount: game.sizeOnDisk, countStyle: .file) : "Downloading…")
                .font(.caption).foregroundStyle(.secondary)
        }
        .scaleEffect(hover ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        .opacity(game.installed ? 1 : 0.55)
    }
}

struct Artwork: View {
    let id: Int
    let local: URL?

    var body: some View {
        if let local, let img = NSImage(contentsOf: local) {
            Image(nsImage: img).resizable().scaledToFill()
        } else {
            AsyncImage(url: SteamLibrary.artworkCDN(id)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: [.indigo, .purple], startPoint: .top, endPoint: .bottom)
                        Image(systemName: "gamecontroller.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
    }
}

// MARK: - Per-game settings

struct GameSettingsView: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    let decision: RendererPolicy.Decision?
    @State private var s: GameSettings
    @State private var envText: String

    init(game: Game, decision: RendererPolicy.Decision?) {
        self.game = game
        self.decision = decision
        let loaded = GameSettings.load(game.id)
        _s = State(initialValue: loaded)
        _envText = State(initialValue: (loaded.env ?? [:]).sorted { $0.key < $1.key }.map { "\($0)=\($1)" }.joined(separator: "\n"))
    }

    func tri(_ b: Binding<Bool?>) -> Binding<Int> {
        Binding(get: { b.wrappedValue.map { $0 ? 1 : 2 } ?? 0 },
                set: { b.wrappedValue = $0 == 0 ? nil : $0 == 1 })
    }

    var body: some View {
        Form {
            Section {
                Picker("Graphics", selection: $s.renderer) {
                    Text("Automatic").tag(Renderer?.none)
                    ForEach(Renderer.allCases, id: \.self) { r in
                        Text(r.title + (r == .d3dmetal && !model.d3dmetalInstalled ? " (not installed)" : "")).tag(Renderer?.some(r))
                    }
                }
                if s.renderer == nil, let d = decision {
                    Text("Automatic picks **\(d.renderer.title)**: \(d.reason)" +
                         (d.apis.isEmpty ? "" : ". Detected: \(d.apis.sorted().joined(separator: ", "))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Performance HUD", selection: tri($s.metalHUD)) {
                    Text("Default").tag(0); Text("On").tag(1); Text("Off").tag(2)
                }
                Toggle("MetalFX upscaling (DLSS → MetalFX)", isOn: Binding(get: { s.metalFX ?? false }, set: { s.metalFX = $0 }))
                Picker("Retina resolution", selection: tri($s.retinaMode)) {
                    Text("Default").tag(0); Text("On").tag(1); Text("Off").tag(2)
                }
            }
            Section("Advanced") {
                TextField("Launch arguments", text: Binding(get: { s.args ?? "" }, set: { s.args = $0.isEmpty ? nil : $0 }),
                          prompt: Text("-dx11 -skipintro"))
                VStack(alignment: .leading) {
                    Text("Environment (NAME=value per line)").font(.caption)
                    TextEditor(text: $envText).font(.system(.caption, design: .monospaced)).frame(height: 54)
                }
            }
            HStack {
                Spacer()
                Button("Save") {
                    var env: [String: String] = [:]
                    for line in envText.split(separator: "\n") {
                        let p = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                        if p.count == 2, !p[0].isEmpty { env[p[0]] = p[1] }
                    }
                    s.env = env.isEmpty ? nil : env
                    if s.renderer != nil { s.autoFallback = nil }
                    model.saveSettings(s, for: game)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
    }
}

// MARK: - Global settings

struct GlobalSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Show Metal performance HUD in games", isOn: $model.global.metalHUD)
            Toggle("Retina resolution (sharper, slower)", isOn: $model.global.retinaMode)
            Toggle("MSync (faster multithreading)", isOn: $model.global.msync)
            Toggle("Close Steam after the last game exits", isOn: $model.global.quitSteamWhenIdle)
            HStack {
                Spacer()
                Button("Apply") { model.saveGlobal() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up RunMyGames").font(.largeTitle.bold())
                Text("Free, open-source Windows game compatibility for your Mac. Do these steps once.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.checks) { c in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: c.ok ? "checkmark.circle.fill" : (c.required ? "circle" : "circle.dashed"))
                            .foregroundStyle(c.ok ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(c.name).fontWeight(.medium)
                            Text(c.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                let engineOK = model.checks.first { $0.name == "Wine engine" }?.ok == true
                    && model.checks.first { $0.name.hasPrefix("DXMT") }?.ok == true
                Button("1. Build Engine") { model.buildEngine() }.disabled(model.busy || engineOK)
                Button("2. Install Steam") { model.installSteam() }.disabled(model.busy || !engineOK)
                Button("Import D3DMetal… (optional, for DirectX 12)") { model.importD3DMetal() }.disabled(model.busy)
                Link("Get the Game Porting Toolkit",
                     destination: URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!)
                    .font(.caption)
            }
            if !model.log.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.log).font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).id("end")
                    }
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: model.log) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            Spacer()
        }
        .padding(28)
    }
}
