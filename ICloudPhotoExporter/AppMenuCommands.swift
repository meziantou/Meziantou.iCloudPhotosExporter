import SwiftUI

struct AppMenuCommands: Commands {
    @ObservedObject var viewModel: AppViewModel

    var body: some Commands {
        CommandMenu("Exporter") {
            Button("Sync Now") {
                viewModel.runSyncNow()
            }
            .keyboardShortcut("r")

            Button("Open Settings") {
                viewModel.openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

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
