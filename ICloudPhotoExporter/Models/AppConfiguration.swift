import Foundation

struct AppConfiguration: Codable, Equatable {
    var startAtLogin: Bool
    var syncIntervalMinutes: Int
    var syncOnWiFiOnly: Bool
    var lastSyncAttemptAt: Date?
    var libraries: [LibraryConfiguration]

    static var defaultOutputRootPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("iCloud Exports", isDirectory: true)
            .path
    }

    static var `default`: AppConfiguration {
        AppConfiguration(
            startAtLogin: false,
            syncIntervalMinutes: 24 * 60,
            syncOnWiFiOnly: true,
            lastSyncAttemptAt: nil,
            libraries: [
                .default(index: 1, outputRootPath: defaultOutputRootPath),
            ]
        )
    }

    enum CodingKeys: String, CodingKey {
        case startAtLogin
        case syncIntervalMinutes
        case syncOnWiFiOnly
        case lastSyncAttemptAt
        case libraries
    }

    init(
        startAtLogin: Bool,
        syncIntervalMinutes: Int,
        syncOnWiFiOnly: Bool,
        lastSyncAttemptAt: Date?,
        libraries: [LibraryConfiguration]
    ) {
        self.startAtLogin = startAtLogin
        self.syncIntervalMinutes = syncIntervalMinutes
        self.syncOnWiFiOnly = syncOnWiFiOnly
        self.lastSyncAttemptAt = lastSyncAttemptAt
        self.libraries = libraries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startAtLogin = try container.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? false
        let loadedSyncInterval = try container.decodeIfPresent(Int.self, forKey: .syncIntervalMinutes) ?? (24 * 60)
        syncIntervalMinutes = loadedSyncInterval < 60 ? (24 * 60) : loadedSyncInterval
        syncOnWiFiOnly = try container.decodeIfPresent(Bool.self, forKey: .syncOnWiFiOnly) ?? true
        lastSyncAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncAttemptAt)
        libraries = try container.decodeIfPresent([LibraryConfiguration].self, forKey: .libraries) ?? []
    }
}
