import SwiftUI

struct MenuBarStatusView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.isSyncing ? "Syncing…" : "Idle")
                .font(.headline)
            Text(viewModel.lastRunSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
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
        }
        .padding(12)
        .frame(width: 320)
    }
}
