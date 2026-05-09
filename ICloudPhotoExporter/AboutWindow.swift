import AppKit
import SwiftUI

@MainActor
final class AboutWindowController {
    private var windowController: NSWindowController?

    func show(appName: String, appVersion: String) {
        let view = AboutWindowView(
            appName: appName,
            appVersion: appVersion,
            repositoryURL: Self.repositoryURL,
            authorName: Self.authorName
        )

        if let window = windowController?.window,
           let hostingController = window.contentViewController as? NSHostingController<AboutWindowView>
        {
            hostingController.rootView = view
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "About \(appName)"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 420, height: 220))
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static let repositoryURL = URL(string: "https://github.com/meziantou/Meziantou.iCloudPhotosExporter")!
    private static let authorName = "Gérald Barré"
}

private struct AboutWindowView: View {
    let appName: String
    let appVersion: String
    let repositoryURL: URL
    let authorName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appName)
                .font(.title2)
                .fontWeight(.semibold)

            Text("Version \(appVersion)")
                .foregroundStyle(.secondary)

            Link(repositoryURL.absoluteString, destination: repositoryURL)

            Text("Author: \(authorName)")
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(20)
        .frame(width: 420, height: 220, alignment: .topLeading)
    }
}
