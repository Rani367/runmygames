import AppKit
import RMGCore
import SwiftUI

/// First-run setup: three steps, each with its state and one button.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAdvanced = false
    @State private var buildChecks: [Doctor.Check] = []

    var rosettaOK: Bool { model.check(.rosetta)?.ok == true }
    var engineOK: Bool { model.check(.engine)?.ok == true && model.check(.dxmt)?.ok == true }
    var steamOK: Bool { [.prefix, .shim, .steam].allSatisfy { model.check($0)?.ok == true } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                VStack(spacing: 12) {
                    StepRow(number: 1, title: "Rosetta 2",
                            detail: "Apple's translator for Intel code, which Windows games need.",
                            done: rosettaOK, current: !rosettaOK) {
                        Button("Install Rosetta…") { model.installRosetta() }
                    }
                    StepRow(number: 2, title: "Game engine",
                            detail: "Wine (from CodeWeavers' open-source CrossOver release) and DXMT, which turns DirectX into Metal."
                                + sizeText,
                            done: engineOK, current: rosettaOK && !engineOK) {
                        Button("Download") { model.downloadEngine() }
                    }
                    StepRow(number: 3, title: "Windows and Steam",
                            detail: "Creates a private Windows environment and installs the Steam client and Visual C++ runtimes. "
                                + "Takes a few minutes.",
                            done: steamOK, current: rosettaOK && engineOK && !steamOK) {
                        Button("Install Steam") { model.installSteam() }
                    }
                }
                d3dmetalCard
                advanced
                if !model.setupLog.isEmpty { LogView(text: model.setupLog) }
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("RunMyGames")
    }

    var sizeText: String {
        guard let size = model.engineDownloadSize, size > 0 else { return "" }
        return " About \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) to download."
    }

    var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to RunMyGames").font(.largeTitle.bold())
                Text("Play your Windows Steam games on this Mac. Free and open source. Set it up once:")
                    .foregroundStyle(.secondary)
            }
        }
    }

    var d3dmetalCard: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.d3dmetalInstalled ? "checkmark.circle.fill" : "sparkles")
                    .font(.title2)
                    .foregroundStyle(model.d3dmetalInstalled ? .green : .accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Optional: DirectX 12 games").font(.headline)
                    Text(model.d3dmetalInstalled
                         ? "D3DMetal is installed. DirectX 12 games use it automatically."
                         : "Apple's D3DMetal runs DirectX 12 games, but its license does not allow sharing it. "
                            + "Download the free Game Porting Toolkit from Apple (you need an Apple Account), then import the .dmg here.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.d3dmetalInstalled {
                        HStack {
                            Link("Get the Game Porting Toolkit", destination: Project.gptk)
                            Spacer()
                            Button("Import D3DMetal…") { model.importD3DMetal() }.disabled(model.busy || !engineOK)
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .padding(6)
        }
    }

    var advanced: some View {
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Instead of downloading the engine, you can build it from source on this Mac. "
                     + "This takes about 45 minutes and needs Homebrew and the Xcode Command Line Tools.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(buildChecks, id: \.name) { c in
                    Label("\(c.name): \(c.detail)", systemImage: c.ok ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(c.ok ? Color.secondary : Color.orange)
                        .textSelection(.enabled)
                }
                Button("Build Engine from Source") { model.buildEngine() }
                    .disabled(model.busy || !rosettaOK || buildChecks.isEmpty || !buildChecks.allSatisfy(\.ok))
            }
            .padding(.top, 6)
        }
        .task(id: showAdvanced) {
            guard showAdvanced else { return }
            buildChecks = await Task.detached { Doctor.buildChecks() }.value
        }
    }
}

struct StepRow<Action: View>: View {
    @EnvironmentObject var model: AppModel
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    let current: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : current ? Color.accentColor : Color.secondary.opacity(0.25))
                if done {
                    Image(systemName: "checkmark").font(.body.bold()).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.body.bold()).foregroundStyle(current ? .white : .secondary)
                }
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if done {
                Text("Done").foregroundStyle(.secondary)
            } else if current {
                action()
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.busy)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(current ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.15)))
        .opacity(done || current ? 1 : 0.6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number): \(title), \(done ? "done" : current ? "next" : "waiting")")
    }
}

struct LogView: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Color.clear.frame(height: 1).id("end")
            }
            .frame(height: 220)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}
