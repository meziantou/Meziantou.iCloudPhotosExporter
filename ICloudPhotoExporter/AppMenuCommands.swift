import SwiftUI

struct AppMenuCommands: Commands {
    @ObservedObject var viewModel: AppViewModel

    var body: some Commands {
        CommandMenu("Exporter") {
            Button("About iCloud Exporter") {
                viewModel.openAboutWindow()
            }

            Divider()

            Button("Sync Now") {
                viewModel.runSyncNow()
            }
            .keyboardShortcut("r")

            if #available(macOS 14.0, *) {
                SettingsLink {
                    Text("Open Settings")
                }
                    .keyboardShortcut(",", modifiers: .command)
            } else {
                Button("Open Settings") {
                    viewModel.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            Button(viewModel.isCheckingForUpdates ? "Checking for Updates…" : "Check for Updates") {
                viewModel.checkForUpdates()
            }
            .disabled(viewModel.isCheckingForUpdates)

            Divider()

            Button(viewModel.isSchedulerPaused ? "Resume Scheduler" : "Pause Scheduler") {
                viewModel.setSchedulerPaused(!viewModel.isSchedulerPaused)
            }

            Divider()

            Button("Quit iCloud Exporter") {
                viewModel.quitApplication()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
