import AppKit
import Foundation
import Network
import OSLog
import Photos

struct SyncErrorLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

private enum PhotosPermissionResetError: LocalizedError {
    case commandUnavailable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandUnavailable:
            return "Could not run tccutil to reset Photos permission."
        case let .commandFailed(detail):
            return "Failed to reset Photos permission: \(detail)"
        }
    }
}

private struct LibrarySyncOutcome: Sendable {
    let result: LibrarySyncResult?
    let errorDetail: String?
}

@MainActor
final class AppViewModel: ObservableObject {
    private enum UpdateCheckTrigger {
        case manual
        case startup
        case scheduled
    }

    @Published var configuration: AppConfiguration = .default
    @Published var isSyncing: Bool = false
    @Published var isSchedulerPaused: Bool = false
    @Published var lastRunSummary: String = "Idle"
    @Published var errorMessage: String?
    @Published var errorLogEntries: [SyncErrorLogEntry] = []
    @Published var sharedAlbums: [SharedAlbumSummary] = []
    @Published var isLoadingSharedAlbums: Bool = false
    @Published var isCheckingForUpdates: Bool = false
    @Published var updateCheckResult: UpdateCheckResult?
    @Published var updateCheckError: String?
    @Published var syncCopiedFileCount: Int = 0
    @Published var syncCurrentFileName: String?
    @Published var syncCurrentLibraryName: String?
    @Published var syncRecentCopiedFiles: [String] = []
    @Published var isResettingPhotosPermission: Bool = false

    var currentAppVersion: String {
        updateCheckService.currentVersionString
    }

    var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "iCloud Exporter"
    }

    var menuBarTitle: String {
        if isSyncing {
            return "Sync \(syncCopiedFileCount)"
        }

        return "iCloud Exporter"
    }

    private var hasPhotoLibraryAccess: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    var canResetPhotosPermission: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .denied
    }

    var photosPermissionResetCommand: String {
        PhotoLibraryService.photosPermissionResetCommand()
    }

    private let configurationStore = ConfigurationStore()
    private let loginItemService = LoginItemService()
    private let exportScheduler = ExportScheduler()
    private let sharedAlbumsPhotoLibraryService = PhotoLibraryService()
    private let networkStatusService = NetworkStatusService()
    private let updateCheckService = UpdateCheckService()
    private let aboutWindowController = AboutWindowController()
    private let exportEngine = ExportEngine(
        photoLibraryService: PhotoLibraryService(),
        manifestStore: ExportManifestStore()
    )
    private let logger = Logger(subsystem: "com.meziantou.icloudphotoexporter", category: "AppViewModel")
    private static let automaticUpdateCheckIntervalNanoseconds: UInt64 = 86_400_000_000_000
    private var automaticUpdateCheckTask: Task<Void, Never>?

    private var didLoadConfiguration = false
    private var lastAppliedStartAtLogin: Bool?

    var hasErrorIndicator: Bool {
        errorMessage != nil || !errorLogEntries.isEmpty
    }

    var menuBarSymbolName: String {
        if isSyncing {
            return "arrow.triangle.2.circlepath.circle.fill"
        }

        if hasErrorIndicator {
            return "exclamationmark.triangle.fill"
        }

        return "photo.on.rectangle.angled"
    }

    init() {
        Task { [weak self] in
            await self?.loadConfiguration()
        }
    }

    deinit {
        automaticUpdateCheckTask?.cancel()
    }

    func loadConfiguration() async {
        do {
            var loadedConfiguration = try await configurationStore.load()
            if loadedConfiguration.libraries.isEmpty {
                loadedConfiguration.libraries = [
                    .default(index: 1, outputRootPath: AppConfiguration.defaultOutputRootPath),
                ]
            }

            configuration = loadedConfiguration
            didLoadConfiguration = true

            try applyLoginItemSetting(force: true)
            configureScheduler()
            // Only refresh at startup if permission is already granted; otherwise the
            // system dialog would appear unexpectedly before the user does anything.
            // The Settings view's onAppear and the sync engine each request authorization
            // at the right moment.
            if hasPhotoLibraryAccess {
                refreshSharedAlbums()
            }
            runMissedScheduledSyncOnStartupIfNeeded()
            startAutomaticUpdateChecks()
        } catch {
            errorMessage = error.localizedDescription
            appendErrorLog("Configuration load failed: \(error.localizedDescription)")
            logger.error("Failed loading configuration: \(error.localizedDescription, privacy: .public)")
        }
    }

    func configurationDidChange() {
        guard didLoadConfiguration else {
            return
        }

        let configurationSnapshot = configuration

        persistConfiguration(configurationSnapshot)

        do {
            try applyLoginItemSetting(force: false)
        } catch {
            Task { @MainActor in
                self.errorMessage = error.localizedDescription
                self.appendErrorLog("Start at login update failed: \(error.localizedDescription)")
            }
        }

        configureScheduler()
    }

    @discardableResult
    func addLibrary() -> UUID {
        let nextIndex = configuration.libraries.count + 1
        let newLibrary = LibraryConfiguration.default(
            index: nextIndex,
            outputRootPath: AppConfiguration.defaultOutputRootPath
        )
        configuration.libraries.append(newLibrary)
        configurationDidChange()
        return newLibrary.id
    }

    func removeLibrary(withID libraryID: UUID?) -> UUID? {
        guard let libraryID,
              let index = configuration.libraries.firstIndex(where: { $0.id == libraryID })
        else {
            return configuration.libraries.first?.id
        }

        configuration.libraries.remove(at: index)

        let nextSelectedLibraryID: UUID?
        if configuration.libraries.indices.contains(index) {
            nextSelectedLibraryID = configuration.libraries[index].id
        } else {
            nextSelectedLibraryID = configuration.libraries.last?.id
        }

        configurationDidChange()
        return nextSelectedLibraryID
    }

    func chooseOutputFolder(for libraryID: UUID) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose the export folder for this library."

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        guard let index = configuration.libraries.firstIndex(where: { $0.id == libraryID }) else {
            return
        }

        configuration.libraries[index].outputFolderPath = selectedURL.path
        configurationDidChange()
    }

    func runSyncNow() {
        guard !isSyncing else {
            return
        }

        Task { [weak self] in
            await self?.runSyncNowCore()
        }
    }

    func setSchedulerPaused(_ paused: Bool) {
        isSchedulerPaused = paused
        exportScheduler.setPaused(paused)
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            return
        }

        _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }

    func openAboutWindow() {
        aboutWindowController.show(appName: appDisplayName, appVersion: currentAppVersion)
    }

    func quitApplication() {
        NSApp.terminate(nil)
    }

    func clearErrorLog() {
        errorLogEntries = []
        errorMessage = nil
    }

    func checkForUpdates() {
        Task { [weak self] in
            guard let self else { return }
            await self.performUpdateCheck(trigger: .manual)
        }
    }

    func openLatestRelease() {
        if let url = updateCheckResult?.releaseURL {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshSharedAlbums() {
        guard !isLoadingSharedAlbums else {
            return
        }

        isLoadingSharedAlbums = true

        Task { [sharedAlbumsPhotoLibraryService] in
            do {
                try await sharedAlbumsPhotoLibraryService.ensureAuthorized()
                let albums = sharedAlbumsPhotoLibraryService.fetchSharedAlbums()
                await MainActor.run {
                    self.sharedAlbums = albums
                    self.isLoadingSharedAlbums = false
                }
            } catch {
                await MainActor.run {
                    self.sharedAlbums = []
                    self.errorMessage = error.localizedDescription
                    self.appendErrorLog("Loading shared albums failed: \(error.localizedDescription)")
                    self.isLoadingSharedAlbums = false
                }
            }
        }
    }

    func resetPhotosPermission() {
        guard !isResettingPhotosPermission else {
            return
        }

        Task { [weak self] in
            await self?.resetPhotosPermissionCore()
        }
    }

    private func configureScheduler() {
        exportScheduler.configure(intervalMinutes: configuration.syncIntervalMinutes) { [weak self] in
            self?.runSyncNow()
        }
        exportScheduler.setPaused(isSchedulerPaused)
    }

    private func startAutomaticUpdateChecks() {
        automaticUpdateCheckTask?.cancel()
        automaticUpdateCheckTask = Task { [weak self] in
            guard let self else {
                return
            }

            await self.performUpdateCheck(trigger: .startup)

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.automaticUpdateCheckIntervalNanoseconds)
                } catch {
                    return
                }

                if Task.isCancelled {
                    return
                }

                await self.performUpdateCheck(trigger: .scheduled)
            }
        }
    }

    private func performUpdateCheck(trigger: UpdateCheckTrigger) async {
        guard !isCheckingForUpdates else {
            return
        }

        isCheckingForUpdates = true
        if trigger == .manual {
            updateCheckError = nil
        }

        defer {
            isCheckingForUpdates = false
        }

        do {
            let result = try await updateCheckService.checkForUpdates()
            updateCheckResult = result
            updateCheckError = nil

            if result.isUpdateAvailable {
                suggestOpeningReleasePage(for: result)
            }
        } catch {
            if trigger == .manual {
                updateCheckError = error.localizedDescription
            } else {
                logger.error("Automatic update check failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func suggestOpeningReleasePage(for result: UpdateCheckResult) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Update Available"
        alert.informativeText = """
        Version \(result.latestVersion) is available (current: \(result.currentVersion)).
        Do you want to open the GitHub release page?
        """
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(result.releaseURL)
        }
    }

    private func runSyncNowCore() async {
        let enabledLibraries = configuration.libraries.filter { library in
            library.isEnabled && !library.outputFolderPath.isEmpty
        }

        guard !enabledLibraries.isEmpty else {
            lastRunSummary = "No enabled library configuration."
            return
        }

        if !networkStatusService.canSync(syncOnWiFiOnly: configuration.syncOnWiFiOnly) {
            lastRunSummary = configuration.syncOnWiFiOnly
                ? "Skipped sync: waiting for non-cellular network."
                : "Skipped sync: network is offline."
            return
        }

        isSyncing = true
        errorMessage = nil
        syncCopiedFileCount = 0
        syncCurrentFileName = nil
        syncCurrentLibraryName = nil
        syncRecentCopiedFiles = []
        lastRunSummary = "Syncing…"

        let exportEngine = self.exportEngine
        let outcomes = await withTaskGroup(of: LibrarySyncOutcome.self, returning: [LibrarySyncOutcome].self) { group in
            for library in enabledLibraries {
                group.addTask {
                    do {
                        let result = try await exportEngine.synchronize(library: library) { update in
                            await MainActor.run { [weak self] in
                                self?.recordSyncProgress(update)
                            }
                        }

                        return LibrarySyncOutcome(result: result, errorDetail: nil)
                    } catch {
                        let detail = "Sync failed for \(library.name): \(error.localizedDescription)"
                        return LibrarySyncOutcome(result: nil, errorDetail: detail)
                    }
                }
            }

            var outcomes: [LibrarySyncOutcome] = []
            outcomes.reserveCapacity(enabledLibraries.count)
            for await outcome in group {
                outcomes.append(outcome)
            }

            return outcomes
        }

        var totalExported = 0
        var totalSkipped = 0
        var failedLibraryErrors: [String] = []

        for outcome in outcomes {
            if let result = outcome.result {
                totalExported += result.exportedCount
                totalSkipped += result.skippedCount
            }

            if let errorDetail = outcome.errorDetail {
                failedLibraryErrors.append(errorDetail)
                appendErrorLog(errorDetail)
                logger.error("\(errorDetail, privacy: .public)")
            }
        }

        isSyncing = false
        configuration.lastSyncAttemptAt = .now
        persistConfiguration(configuration)

        if failedLibraryErrors.isEmpty {
            lastRunSummary = "Exported \(totalExported), skipped \(totalSkipped)."
            return
        }

        errorMessage = failedLibraryErrors.first
        lastRunSummary = "Exported \(totalExported), skipped \(totalSkipped), failures \(failedLibraryErrors.count)."
    }

    private func applyLoginItemSetting(force: Bool) throws {
        let desiredValue = configuration.startAtLogin
        if !force, lastAppliedStartAtLogin == desiredValue {
            return
        }

        try loginItemService.setEnabled(desiredValue)
        lastAppliedStartAtLogin = desiredValue
    }

    private func runMissedScheduledSyncOnStartupIfNeeded() {
        guard !isSchedulerPaused else {
            return
        }

        // Do not trigger startup sync until permission is already granted.
        // After a TCC reset, the first authorization request should come from a
        // user-initiated action (Sync now / Refresh shared albums), otherwise
        // the prompt may not appear and access can immediately fall back to denied.
        guard hasPhotoLibraryAccess else {
            return
        }

        let intervalInSeconds = TimeInterval(max(1, configuration.syncIntervalMinutes) * 60)
        guard let lastSyncAttemptAt = configuration.lastSyncAttemptAt else {
            runSyncNow()
            return
        }

        if Date().timeIntervalSince(lastSyncAttemptAt) >= intervalInSeconds {
            runSyncNow()
        }
    }

    private func persistConfiguration(_ snapshot: AppConfiguration) {
        Task { [snapshot] in
            do {
                try await configurationStore.save(snapshot)
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.appendErrorLog("Saving configuration failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func appendErrorLog(_ message: String) {
        errorLogEntries.insert(SyncErrorLogEntry(timestamp: .now, message: message), at: 0)
        if errorLogEntries.count > 100 {
            errorLogEntries.removeLast(errorLogEntries.count - 100)
        }
    }

    private func resetPhotosPermissionCore() async {
        isResettingPhotosPermission = true
        defer { isResettingPhotosPermission = false }

        let bundleIdentifier = PhotoLibraryService.photosPermissionBundleIdentifier()

        do {
            try await Self.executePhotosPermissionReset(bundleIdentifier: bundleIdentifier)
            errorMessage = nil
            lastRunSummary = "Photos permission reset. Retry sync; reopen the app if the prompt still does not appear."
            refreshSharedAlbums()
        } catch {
            errorMessage = error.localizedDescription
            appendErrorLog("Resetting Photos permission failed: \(error.localizedDescription)")
        }
    }

    nonisolated private static func executePhotosPermissionReset(bundleIdentifier: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "Photos", bundleIdentifier]

            let errorPipe = Pipe()
            process.standardOutput = Pipe()
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                throw PhotosPermissionResetError.commandUnavailable
            }

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail: String
                if let errorOutput, !errorOutput.isEmpty {
                    detail = errorOutput
                } else {
                    detail = "tccutil exited with status \(process.terminationStatus)."
                }

                throw PhotosPermissionResetError.commandFailed(detail)
            }
        }.value
    }

    private func recordSyncProgress(_ update: ExportProgressUpdate) {
        syncCurrentLibraryName = update.libraryName
        syncCurrentFileName = update.fileName

        switch update.state {
        case .copying:
            break
        case .copied:
            syncCopiedFileCount += 1
            syncRecentCopiedFiles.insert("\(update.libraryName): \(update.fileName)", at: 0)
            if syncRecentCopiedFiles.count > 8 {
                syncRecentCopiedFiles.removeLast(syncRecentCopiedFiles.count - 8)
            }
        }

        if syncCopiedFileCount == 1 {
            lastRunSummary = "Syncing… copied 1 file."
        } else {
            lastRunSummary = "Syncing… copied \(syncCopiedFileCount) files."
        }
    }
}

private final class NetworkStatusService {
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.meziantou.icloudphotoexporter.network-monitor")
    private let lock = NSLock()
    private var latestPath: NWPath?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else {
                return
            }

            self.lock.lock()
            self.latestPath = path
            self.lock.unlock()
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
    }

    func canSync(syncOnWiFiOnly: Bool) -> Bool {
        let currentPath = pathSnapshot()
        guard let currentPath, currentPath.status == .satisfied else {
            return false
        }

        if !syncOnWiFiOnly {
            return true
        }

        return !currentPath.usesInterfaceType(.cellular)
    }

    private func pathSnapshot() -> NWPath? {
        lock.lock()
        defer { lock.unlock() }
        return latestPath ?? monitor.currentPath
    }
}
