import AppKit
import RMGCore
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var selection: Int?
    @State private var gridWidth: CGFloat = 800
    @FocusState private var gridFocused: Bool

    static let cardMin: CGFloat = 160, spacing: CGFloat = 18, padding: CGFloat = 20

    private func matches(_ g: Game) -> Bool { query.isEmpty || g.name.localizedCaseInsensitiveContains(query) }
    var installed: [Game] { model.games.filter { $0.installed && matches($0) } }
    var downloading: [Game] { model.games.filter { !$0.installed && matches($0) } }

    /// Same arithmetic as the adaptive grid, so arrow keys move by whole rows.
    var columns: Int {
        max(1, Int((gridWidth - 2 * Self.padding + Self.spacing) / (Self.cardMin + Self.spacing)))
    }

    var body: some View {
        VStack(spacing: 0) {
            Banners()
            if model.games.isEmpty {
                EmptyLibrary()
            } else {
                grid
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.openSteam() } label: { Label("Steam", systemImage: "cart") }
                    .help("Open Steam to log in, buy and install games")
                Button { model.createAllLaunchers() } label: { Label("Add All to Launchpad", systemImage: "square.grid.3x3") }
                    .help("Create a Mac app for every installed game in ~/Applications/RunMyGames")
                    .disabled(model.games.isEmpty)
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh the library")
                Button { model.confirmStopAll = true } label: { Label("Stop All", systemImage: "stop.circle") }
                    .help("Force-quit Steam and every running game")
                    .disabled(!model.steamRunning)
            }
        }
        .navigationTitle("RunMyGames")
        .navigationSubtitle(subtitle)
        .sheet(item: $model.editing) { game in
            GameSettingsView(game: game).environmentObject(model)
        }
    }

    var subtitle: String {
        let n = model.games.filter(\.installed).count
        let count = n == 1 ? "1 game" : "\(n) games"
        if let id = model.running.first, let g = model.games.first(where: { $0.id == id }) { return "Playing \(g.name)" }
        return model.steamRunning ? "\(count) · Steam running" : count
    }

    var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if installed.isEmpty && !query.isEmpty {
                    Text("No games match “\(query)”.").foregroundStyle(.secondary).padding(.top, 40)
                        .frame(maxWidth: .infinity)
                }
                cards(installed)
                if !downloading.isEmpty {
                    Text("Downloading").font(.headline).foregroundStyle(.secondary).padding(.top, 8)
                    cards(downloading)
                }
            }
            .padding(Self.padding)
            .background(GeometryReader { p in
                Color.clear.onAppear { gridWidth = p.size.width }.onChange(of: p.size.width) { gridWidth = p.size.width }
            })
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search games")
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onKeyPress(.return) { playSelection() }
        .onKeyPress(.space) { playSelection() }
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-columns) }
        .onKeyPress(.downArrow) { move(columns) }
        .onAppear { gridFocused = true }
    }

    func cards(_ list: [Game]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cardMin, maximum: 200), spacing: Self.spacing)],
                  alignment: .leading, spacing: 22) {
            ForEach(list) { game in
                GameCard(game: game, decision: model.decisions[game.id], artwork: model.artwork[game.id],
                         running: model.running.contains(game.id), selected: selection == game.id)
                    .onTapGesture(count: 2) { if game.installed { model.play(game) } }
                    .simultaneousGesture(TapGesture().onEnded {
                        selection = game.id
                        gridFocused = true
                    })
                    .contextMenu { menu(for: game) }
            }
        }
    }

    @ViewBuilder
    func menu(for game: Game) -> some View {
        Button("Play") { model.play(game) }.disabled(!game.installed || model.running.contains(game.id))
        Button("Game Settings…") { model.editing = game }.disabled(!game.installed)
        Button("Add to Launchpad") { model.createLauncher(game) }.disabled(!game.installed)
        Divider()
        Button("Show Files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.installDir]) }
        Button("View in Steam Store") {
            NSWorkspace.shared.open(URL(string: "https://store.steampowered.com/app/\(game.id)")!)
        }
    }

    func playSelection() -> KeyPress.Result {
        guard let id = selection, let g = installed.first(where: { $0.id == id }) else { return .ignored }
        model.play(g)
        return .handled
    }

    func move(_ delta: Int) -> KeyPress.Result {
        let list = installed + downloading
        guard !list.isEmpty else { return .ignored }
        let i = selection.flatMap { id in list.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : list.count)
        selection = list[min(max(i + delta, 0), list.count - 1)].id
        return .handled
    }
}

struct GameCard: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    let decision: RendererPolicy.Decision?
    let artwork: URL?
    let running: Bool
    let selected: Bool
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(id: game.id, name: game.name, local: artwork)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay { overlay }
                .overlay(alignment: .bottomTrailing) { badge }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0)
                }
                .shadow(color: .black.opacity(0.25), radius: hover ? 8 : 3, y: 2)
            Text(game.name).font(.callout.weight(.medium)).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(running ? .green : .secondary)
        }
        .scaleEffect(hover ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        .opacity(game.installed ? 1 : 0.55)
        .help(decision.map { "\($0.renderer.title): \($0.reason)" } ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.name)
        .accessibilityValue(subtitle)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if game.installed { model.play(game) } }
        .accessibilityAction(named: "Game Settings") { model.editing = game }
    }

    var subtitle: String {
        if running { return "Playing" }
        guard game.installed else { return "Downloading…" }
        return ByteCountFormatter.string(fromByteCount: game.sizeOnDisk, countStyle: .file)
    }

    @ViewBuilder var overlay: some View {
        if hover && game.installed && !running {
            ZStack {
                Color.black.opacity(0.35)
                VStack(spacing: 10) {
                    Button { model.play(game) } label: {
                        Label("Play", systemImage: "play.fill").font(.headline).padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.busy)
                    Button { model.editing = game } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    @ViewBuilder var badge: some View {
        if running {
            Label("Playing", systemImage: "play.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.green, in: Capsule())
                .padding(6)
        } else if let d = decision {
            Text(d.renderer.title)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(6)
        }
    }
}

struct ArtworkView: View {
    let id: Int
    let name: String
    let local: URL?
    @State private var image: NSImage?

    /// Overlays never change layout, so whatever the image's shape, the card keeps its own.
    var body: some View {
        Color.clear
            .overlay { placeholder }
            .overlay {
                if let image {
                    art(image).transition(.opacity)
                }
            }
            .clipped()
            .task(id: local) {
                let img = await ImageCache.shared.artwork(id: id, local: local)
                withAnimation(.easeIn(duration: 0.15)) { image = img }
            }
    }

    /// Portrait capsules fill the card; wide header art sits centered on a blurred copy of itself.
    @ViewBuilder func art(_ image: NSImage) -> some View {
        if image.size.width > image.size.height {
            ZStack {
                Image(nsImage: image).resizable().scaledToFill().blur(radius: 18).opacity(0.7)
                Image(nsImage: image).resizable().scaledToFit()
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            }
        } else {
            Image(nsImage: image).resizable().scaledToFill()
        }
    }

    /// A stable color per game, with its name, until (or unless) artwork loads.
    var placeholder: some View {
        let hue = Double((id &* 2_654_435_761) % 360) / 360
        return ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.55),
                                    Color(hue: hue + 0.08, saturation: 0.65, brightness: 0.3)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 10) {
                Image(systemName: "gamecontroller.fill").font(.title).foregroundStyle(.white.opacity(0.6))
                Text(name).font(.headline).foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 10)
            }
        }
    }
}

struct EmptyLibrary: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label(model.hasSteamAccount ? "No games yet" : "Sign in to Steam", systemImage: "gamecontroller")
        } description: {
            Text(model.hasSteamAccount
                 ? "Install your Windows games in Steam. They show up here as they download."
                 : "RunMyGames is ready. Open Steam, sign in, and install your Windows games. They show up here automatically.")
        } actions: {
            Button(model.hasSteamAccount ? "Open Steam" : "Open Steam and Sign In") { model.openSteam() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.busy)
        }
    }
}

/// Update notices above the library.
struct Banners: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let r = model.update {
                banner(icon: "arrow.down.circle.fill", text: "RunMyGames \(r.version) is available.") {
                    Button("Release Notes") { NSWorkspace.shared.open(r.url) }
                    Button("Update") { model.openInTerminal(Project.installCommand) }
                        .buttonStyle(.borderedProminent)
                    Button { model.update = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                }
            }
            if model.engineUpdate {
                banner(icon: "cpu", text: "A Wine engine update is available.") {
                    Button("Update Engine") { model.downloadEngine() }
                        .disabled(model.busy)
                        .help(model.steamRunning ? "Quit Steam first" : "")
                }
            }
        }
    }

    func banner<Actions: View>(icon: String, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tint)
            Text(text)
            Spacer()
            actions()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}
