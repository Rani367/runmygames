import AppKit
import RMGCore
import SwiftUI

struct GameSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let game: Game
    @State private var s: GameSettings
    @State private var envText: String
    private let compat: CompatEntry?
    private let lastRun: Manager.LastRun?

    init(game: Game) {
        self.game = game
        let loaded = GameSettings.load(game.id)
        _s = State(initialValue: loaded)
        _envText = State(initialValue: (loaded.env ?? [:]).sorted { $0.key < $1.key }.map { "\($0)=\($1)" }.joined(separator: "\n"))
        compat = CompatDB.load()[game.id]
        lastRun = (try? Manager())?.lastRun(game.id)
    }

    var decision: RendererPolicy.Decision? { model.decisions[game.id] }
    /// The renderer that will actually be used with the settings as edited.
    var effective: Renderer? { s.renderer ?? decision?.renderer }

    func tri(_ b: Binding<Bool?>) -> Binding<Int> {
        Binding(get: { b.wrappedValue.map { $0 ? 1 : 2 } ?? 0 },
                set: { b.wrappedValue = $0 == 0 ? nil : $0 == 1 })
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Graphics", selection: $s.renderer) {
                        Text("Automatic").tag(Renderer?.none)
                        Divider()
                        ForEach(Renderer.allCases, id: \.self) { r in
                            Text(r.title + (r == .d3dmetal && !model.d3dmetalInstalled ? " (not installed)" : ""))
                                .tag(Renderer?.some(r))
                        }
                    }
                    if s.renderer == nil, let d = decision {
                        Text("Automatic uses **\(d.renderer.title)**: \(d.reason).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Performance HUD", selection: tri($s.metalHUD)) {
                        Text("Default (\(model.global.metalHUD ? "on" : "off"))").tag(0)
                        Text("On").tag(1)
                        Text("Off").tag(2)
                    }
                    Toggle("MetalFX upscaling (DLSS → MetalFX)",
                           isOn: Binding(get: { s.metalFX ?? false }, set: { s.metalFX = $0 ? true : nil }))
                        .disabled(effective == .wined3d)
                        .help(effective == .wined3d ? "Only available with DXMT and D3DMetal." : "")
                    Picker("Retina resolution", selection: tri($s.retinaMode)) {
                        Text("Default (\(model.global.retinaMode ? "on" : "off"))").tag(0)
                        Text("On").tag(1)
                        Text("Off").tag(2)
                    }
                } header: {
                    Text(game.name).font(.headline)
                }

                Section("Advanced") {
                    TextField("Launch arguments", text: Binding(get: { s.args ?? "" }, set: { s.args = $0.isEmpty ? nil : $0 }),
                              prompt: Text("-skipintro -windowed"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Environment variables, one NAME=value per line").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $envText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 60)
                            .scrollContentBackground(.hidden)
                    }
                }

                Section("Details") {
                    LabeledContent("Steam app", value: "\(game.id)")
                    if let exe = decision?.mainExe {
                        LabeledContent("Executable") {
                            Button(exe.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([exe]) }
                                .buttonStyle(.link)
                        }
                    }
                    if let apis = decision?.apis, !apis.isEmpty {
                        LabeledContent("Detected graphics", value: apis.sorted().joined(separator: ", "))
                    }
                    if let note = compat?.notes { LabeledContent("Compatibility note", value: note) }
                    if let f = s.autoFallback, s.renderer == nil {
                        LabeledContent("Automatic switch", value: "Using \(f.title) after a crash on start")
                    }
                    if let r = lastRun {
                        LabeledContent("Last run", value: lastRunText(r))
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Reset to Automatic") {
                    s = GameSettings()
                    envText = ""
                }
                .disabled(s == GameSettings() && envText.isEmpty)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 600)
    }

    func lastRunText(_ r: Manager.LastRun) -> String {
        let duration = Duration.seconds(r.seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
        let renderer = Renderer(rawValue: r.renderer)?.title ?? r.renderer
        let when = r.date.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""
        return (r.exitCode == 0 ? "Played \(duration)" : "Exited with error \(r.exitCode) after \(duration)") + " on \(renderer)\(when)"
    }

    func save() {
        var env: [String: String] = [:]
        for line in envText.split(whereSeparator: \.isNewline) {
            let p = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if p.count == 2, EnvFile.isValidKey(p[0]) { env[p[0]] = p[1] }
        }
        var out = s
        out.env = env.isEmpty ? nil : env
        if out.renderer != nil { out.autoFallback = nil }
        if out.renderer == nil, GameSettings.load(game.id).renderer != nil { out.resetRenderer() }
        model.saveSettings(out, for: game)
        dismiss()
    }
}
