import Foundation

enum LibraryAssetSource: String, Codable, CaseIterable, Identifiable {
    case mainLibrary
    case sharedAlbums

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mainLibrary:
            return "Main library"
        case .sharedAlbums:
            return "Shared albums"
        }
    }
}

enum InitialSyncMode: String, Codable, CaseIterable, Identifiable {
    case fullHistory
    case fromDate
    case newOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullHistory:
            return "Full history"
        case .fromDate:
            return "From date"
        case .newOnly:
            return "From latest photo"
        }
    }
}

struct LibraryConfiguration: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var assetSource: LibraryAssetSource
    var selectedSharedAlbumIDs: [String]
    var outputFolderPath: String
    var fileNameFormat: String
    var initialSyncMode: InitialSyncMode
    var initialSyncDate: Date?
    var isEnabled: Bool

    static let defaultFileNameFormat = "{yyyy}{MM}{dd}_{HH}{mm}{ss}_{ID}{ext}"

    init(
        id: UUID = UUID(),
        name: String,
        assetSource: LibraryAssetSource = .mainLibrary,
        selectedSharedAlbumIDs: [String] = [],
        outputFolderPath: String,
        fileNameFormat: String = defaultFileNameFormat,
        initialSyncMode: InitialSyncMode = .newOnly,
        initialSyncDate: Date? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.assetSource = assetSource
        self.selectedSharedAlbumIDs = selectedSharedAlbumIDs
        self.outputFolderPath = outputFolderPath
        self.fileNameFormat = fileNameFormat
        self.initialSyncMode = initialSyncMode
        self.initialSyncDate = initialSyncDate
        self.isEnabled = isEnabled
    }

    var outputFolderURL: URL {
        URL(fileURLWithPath: outputFolderPath, isDirectory: true)
    }

    static func `default`(index: Int, outputRootPath: String) -> LibraryConfiguration {
        LibraryConfiguration(
            name: "Library \(index)",
            assetSource: .mainLibrary,
            selectedSharedAlbumIDs: [],
            outputFolderPath: outputRootPath,
            initialSyncMode: .newOnly
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case assetSource
        case selectedSharedAlbumIDs
        case outputFolderPath
        case fileNameFormat
        case initialSyncMode
        case initialSyncDate
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        assetSource = try container.decodeIfPresent(LibraryAssetSource.self, forKey: .assetSource) ?? .mainLibrary
        selectedSharedAlbumIDs = try container.decodeIfPresent([String].self, forKey: .selectedSharedAlbumIDs) ?? []
        outputFolderPath = try container.decode(String.self, forKey: .outputFolderPath)
        fileNameFormat = try container.decodeIfPresent(String.self, forKey: .fileNameFormat) ?? LibraryConfiguration.defaultFileNameFormat
        initialSyncMode = try container.decodeIfPresent(InitialSyncMode.self, forKey: .initialSyncMode) ?? .newOnly
        initialSyncDate = try container.decodeIfPresent(Date.self, forKey: .initialSyncDate)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}
