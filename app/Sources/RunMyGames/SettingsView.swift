import AppKit
import RMGCore
import SwiftUI

/// RunMyGames > Settings. Changes apply as you make them.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var checking = false
    @State private var updateMessage: String?

    var body: some View {
        Form {
            Section("Games") {
                Toggle("Show the Metal performance HUD", isOn: $model.global.metalHUD)
                Toggle("Retina resolution (sharper, slower)", isOn: $model.global.retinaMode)
                Toggle("MSync (faster multithreading)", isOn: $model.global.msync)
                    .help("Takes effect the next time Steam starts.")
            }
            Section("Steam") {
                Toggle("Quit Steam after you finish playing", isOn: $model.global.quitSteamWhenIdle)
                if model.global.quitSteamWhenIdle {
                    Stepper(value: $model.global.idleSeconds, in: 0...3600, step: 30) {
                        LabeledContent("Wait before quitting", value: idleText)
                    }
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $model.global.checkForUpdates)
                HStack {
                    Text("RunMyGames \(Version.current)")
                    Spacer()
                    if checking { ProgressView().controlSize(.small) }
                    Button("Check Now") { checkNow() }.disabled(checking)
                }
                if let updateMessage { Text(updateMessage).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Troubleshooting") {
                HStack {
                    Button("Open Logs") { NSWorkspace.shared.open(model.paths.logs) }
                    Button("Show Data Folder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.home]) }
                    Spacer()
                    Button("Copy Diagnostics") { model.copyDiagnostics() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    var idleText: String {
        let s = model.global.idleSeconds
        return s == 0 ? "No wait" : Duration.seconds(s).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }

    func checkNow() {
        checking = true
        updateMessage = nil
        Task {
            let r = await Updater.check()
            checking = false
            if let r {
                model.update = r
                updateMessage = "Version \(r.version) is available. Use the Update button in the main window."
            } else {
                updateMessage = "You're up to date (or GitHub could not be reached)."
            }
        }
    }
}
