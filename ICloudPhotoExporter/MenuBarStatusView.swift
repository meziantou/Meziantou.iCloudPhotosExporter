import SwiftUI

struct MenuBarStatusView: View {
    @ObservedObject var viewModel: AppViewModel

    private var recentCopiedFiles: [String] {
        Array(viewModel.syncRecentCopiedFiles.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.isSyncing ? "Syncing…" : "Idle")
                .font(.headline)
            Text(viewModel.lastRunSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.isSyncing {
                if let currentLibrary = viewModel.syncCurrentLibraryName,
                   let currentFile = viewModel.syncCurrentFileName
                {
                    Text("Copying \(currentLibrary): \(currentFile)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !recentCopiedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recently copied")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        ForEach(Array(recentCopiedFiles.enumerated()), id: \.offset) { _, file in
                            Text(file)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if viewModel.canResetPhotosPermission {
                Button(viewModel.isResettingPhotosPermission ? "Resetting Photos Permission…" : "Reset Photos Permission") {
                    viewModel.resetPhotosPermission()
                }
                .disabled(viewModel.isResettingPhotosPermission)
            }

            if !viewModel.errorLogEntries.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Error log")
                        .font(.caption)
                        .fontWeight(.semibold)

                    ForEach(Array(viewModel.errorLogEntries.prefix(5))) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(3)
                        }
                    }

                    Button("Clear error log") {
                        viewModel.clearErrorLog()
                    }
                    .font(.caption)
                }
            }

            Divider()

            Button("Sync Now") {
                viewModel.runSyncNow()
            }
            .disabled(viewModel.isSyncing)

            Button(viewModel.isSchedulerPaused ? "Resume Scheduler" : "Pause Scheduler") {
                viewModel.setSchedulerPaused(!viewModel.isSchedulerPaused)
            }

            if #available(macOS 14.0, *) {
                SettingsLink {
                    Text("Settings…")
                }
            } else {
                Button("Settings…") {
                    viewModel.openSettings()
                }
            }

            Button("About iCloud Exporter") {
                viewModel.openAboutWindow()
            }

            Button(viewModel.isCheckingForUpdates ? "Checking for Updates…" : "Check for Updates") {
                viewModel.checkForUpdates()
            }
            .disabled(viewModel.isCheckingForUpdates)

            if let result = viewModel.updateCheckResult, result.isUpdateAvailable {
                Button("Update available: v\(result.latestVersion)") {
                    viewModel.openLatestRelease()
                }
                .foregroundStyle(.blue)
            }

            Divider()

            Button("Quit iCloud Exporter") {
                viewModel.quitApplication()
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}
