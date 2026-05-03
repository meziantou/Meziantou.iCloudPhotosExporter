import AppKit
import Foundation
import Network
import OSLog

struct SyncErrorLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var configuration: AppConfiguration = .default
    @Published var isSyncing: Bool = false
    @Published var isSchedulerPaused: Bool = false
    @Published var lastRunSummary: String = "Idle"
    @Published var errorMessage: String?
    @Published var errorLogEntries: [SyncErrorLogEntry] = []
    @Published var sharedAlbums: [SharedAlbumSummary] = []
    @Published var isLoadingSharedAlbums: Bool = false

    private let configurationStore = ConfigurationStore()
    private let loginItemService = LoginItemService()
    private let exportScheduler = ExportScheduler()
    private let sharedAlbumsPhotoLibraryService = PhotoLibraryService()
    private let networkStatusService = NetworkStatusService()
    private let exportEngine = ExportEngine(
        photoLibraryService: PhotoLibraryService(),
        manifestStore: ExportManifestStore()
    )
    private let logger = Logger(subsystem: "com.meziantou.icloudphotoexporter", category: "AppViewModel")

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
            refreshSharedAlbums()
            runMissedScheduledSyncOnStartupIfNeeded()
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
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func clearErrorLog() {
        errorLogEntries = []
        errorMessage = nil
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

    private func configureScheduler() {
        exportScheduler.configure(intervalMinutes: configuration.syncIntervalMinutes) { [weak self] in
            self?.runSyncNow()
        }
        exportScheduler.setPaused(isSchedulerPaused)
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

        var totalExported = 0
        var totalSkipped = 0
        var failedLibraryErrors: [String] = []

        for library in enabledLibraries {
            do {
                let result = try await exportEngine.synchronize(library: library)
                totalExported += result.exportedCount
                totalSkipped += result.skippedCount
            } catch {
                let detail = "Sync failed for \(library.name): \(error.localizedDescription)"
                failedLibraryErrors.append(detail)
                appendErrorLog(detail)
                logger.error("Sync failed for \(library.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
