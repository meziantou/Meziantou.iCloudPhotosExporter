import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var selectedLibraryID: UUID?

    private var selectedLibraryBinding: Binding<LibraryConfiguration>? {
        guard let selectedLibraryID,
              let index = viewModel.configuration.libraries.firstIndex(where: { $0.id == selectedLibraryID })
        else {
            return nil
        }

        return $viewModel.configuration.libraries[index]
    }

    var body: some View {
        VStack(spacing: 16) {
            Form {
                Section("General") {
                    Toggle("Start at login", isOn: $viewModel.configuration.startAtLogin)
                    Toggle("Sync on Wi-Fi only", isOn: $viewModel.configuration.syncOnWiFiOnly)
                    Stepper(value: $viewModel.configuration.syncIntervalMinutes, in: 60 ... 10080, step: 60) {
                        Text("Sync every \(syncIntervalDescription(minutes: viewModel.configuration.syncIntervalMinutes))")
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Libraries")
                            .font(.headline)
                        Spacer()
                        Button("Add") {
                            selectedLibraryID = viewModel.addLibrary()
                        }
                        Button("Remove") {
                            selectedLibraryID = viewModel.removeLibrary(withID: selectedLibraryID)
                        }
                        .disabled(selectedLibraryID == nil)
                    }

                    List(selection: $selectedLibraryID) {
                        ForEach(viewModel.configuration.libraries) { library in
                            Text(library.name).tag(Optional(library.id))
                        }
                    }
                    .frame(minWidth: 220, minHeight: 260)
                }

                if let selectedLibraryBinding {
                    LibraryEditorView(
                        library: selectedLibraryBinding,
                        sharedAlbums: viewModel.sharedAlbums,
                        isLoadingSharedAlbums: viewModel.isLoadingSharedAlbums,
                        refreshSharedAlbums: {
                            viewModel.refreshSharedAlbums()
                        },
                        chooseOutputFolder: {
                            viewModel.chooseOutputFolder(for: selectedLibraryBinding.wrappedValue.id)
                        }
                    )
                } else {
                    VStack(alignment: .leading) {
                        Text("Select a library to edit settings.")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }

            HStack {
                Button("Sync now") {
                    viewModel.runSyncNow()
                }
                .disabled(viewModel.isSyncing)

                Button(viewModel.isSchedulerPaused ? "Resume scheduler" : "Pause scheduler") {
                    viewModel.setSchedulerPaused(!viewModel.isSchedulerPaused)
                }

                Spacer()
                Text(viewModel.lastRunSummary)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if viewModel.canResetPhotosPermission {
                VStack(alignment: .leading, spacing: 4) {
                    Button(viewModel.isResettingPhotosPermission ? "Resetting Photos Permission…" : "Reset Photos Permission") {
                        viewModel.resetPhotosPermission()
                    }
                    .disabled(viewModel.isResettingPhotosPermission)

                    Text("Runs: \(viewModel.photosPermissionResetCommand)")
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 12) {
                Text("Version \(viewModel.currentAppVersion)")
                    .foregroundStyle(.secondary)
                    .font(.footnote)

                Button(viewModel.isCheckingForUpdates ? "Checking…" : "Check for Updates") {
                    viewModel.checkForUpdates()
                }
                .disabled(viewModel.isCheckingForUpdates)
                .font(.footnote)

                if let result = viewModel.updateCheckResult {
                    if result.isUpdateAvailable {
                        Button("Version \(result.latestVersion) available — Open release page") {
                            viewModel.openLatestRelease()
                        }
                        .foregroundStyle(.blue)
                        .font(.footnote)
                    } else {
                        Text("App is up to date")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }

                if let updateError = viewModel.updateCheckError {
                    Text(updateError)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }

                Spacer()
            }
        }
        .padding(16)
        .frame(minWidth: 840, minHeight: 560)
        .onAppear {
            if selectedLibraryID == nil {
                selectedLibraryID = viewModel.configuration.libraries.first?.id
            }
            viewModel.refreshSharedAlbums()
        }
        .onChange(of: viewModel.configuration.libraries.map(\.id)) { libraryIDs in
            guard !libraryIDs.isEmpty else {
                selectedLibraryID = nil
                return
            }

            guard let currentSelection = selectedLibraryID else {
                selectedLibraryID = libraryIDs.first
                return
            }

            if !libraryIDs.contains(currentSelection) {
                selectedLibraryID = libraryIDs.first
            }
        }
        .onChange(of: viewModel.configuration) { _ in
            viewModel.configurationDidChange()
        }
    }
}

private func syncIntervalDescription(minutes: Int) -> String {
    if minutes % (24 * 60) == 0 {
        let days = minutes / (24 * 60)
        return days == 1 ? "day" : "\(days) days"
    }

    if minutes % 60 == 0 {
        let hours = minutes / 60
        return hours == 1 ? "hour" : "\(hours) hours"
    }

    return "\(minutes) minutes"
}

private struct LibraryEditorView: View {
    @Binding var library: LibraryConfiguration
    let sharedAlbums: [SharedAlbumSummary]
    let isLoadingSharedAlbums: Bool
    let refreshSharedAlbums: () -> Void
    let chooseOutputFolder: () -> Void

    var body: some View {
        Form {
            TextField("Library name", text: $library.name)

            Toggle("Enabled", isOn: $library.isEnabled)

            Toggle("Export Apple Photos adjustments (.AAE)", isOn: $library.exportAdjustmentData)

            HStack {
                TextField("Output folder", text: $library.outputFolderPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") {
                    chooseOutputFolder()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("File name format", text: $library.fileNameFormat)
                    .textFieldStyle(.roundedBorder)
                Text("Placeholders: {yyyy} {MM} {dd} {HH} {mm} {ss} {ID} {ext}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Example: {yyyy}{MM}{dd}_{HH}{mm}{ss}_{ID}{ext}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Photo source", selection: $library.assetSource) {
                ForEach(LibraryAssetSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }

            if library.assetSource == .sharedAlbums {
                let exportAllSharedAlbumsBinding = Binding(
                    get: { library.selectedSharedAlbumIDs.isEmpty },
                    set: { exportAll in
                        if exportAll {
                            library.selectedSharedAlbumIDs = []
                        } else if library.selectedSharedAlbumIDs.isEmpty {
                            library.selectedSharedAlbumIDs = sharedAlbums.first.map(\.id).map { [$0] } ?? []
                        }
                    }
                )

                Toggle("Export all shared albums", isOn: exportAllSharedAlbumsBinding)

                if !library.selectedSharedAlbumIDs.isEmpty {
                    if isLoadingSharedAlbums {
                        ProgressView("Loading shared albums…")
                    } else if sharedAlbums.isEmpty {
                        Text("No shared albums were found.")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(sharedAlbums) { album in
                            let isSelectedBinding = Binding(
                                get: { library.selectedSharedAlbumIDs.contains(album.id) },
                                set: { isSelected in
                                    if isSelected {
                                        if !library.selectedSharedAlbumIDs.contains(album.id) {
                                            library.selectedSharedAlbumIDs.append(album.id)
                                        }
                                    } else {
                                        library.selectedSharedAlbumIDs.removeAll { $0 == album.id }
                                    }
                                }
                            )

                            Toggle(
                                "\(album.title) (\(album.estimatedAssetCount))",
                                isOn: isSelectedBinding
                            )
                        }
                    }
                }

                Button("Refresh shared albums") {
                    refreshSharedAlbums()
                }
            }

            Picker("Initial sync", selection: $library.initialSyncMode) {
                ForEach(InitialSyncMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            if library.initialSyncMode == .fromDate {
                DatePicker(
                    "Start date",
                    selection: Binding(
                        get: { library.initialSyncDate ?? .now },
                        set: { library.initialSyncDate = $0 }
                    ),
                    displayedComponents: [.date]
                )
            }

            Text("For shared albums, you can export all albums or choose specific albums.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("`From latest photo` avoids a full historical export for new users.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
