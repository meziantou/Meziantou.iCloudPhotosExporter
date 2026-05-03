import SwiftUI

@main
struct ICloudPhotoExporterApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarStatusView(viewModel: viewModel)
        } label: {
            Label(viewModel.menuBarTitle, systemImage: viewModel.menuBarSymbolName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(viewModel: viewModel)
        }
        .commands {
            AppMenuCommands(viewModel: viewModel)
        }
    }
}
