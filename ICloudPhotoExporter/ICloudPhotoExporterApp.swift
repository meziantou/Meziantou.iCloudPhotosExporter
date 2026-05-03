import SwiftUI

@main
struct ICloudPhotoExporterApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarStatusView(viewModel: viewModel)
        } label: {
            Label("iCloud Exporter", systemImage: "photo.on.rectangle.angled")
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
