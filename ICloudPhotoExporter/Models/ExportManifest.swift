import Foundation

struct ExportManifest: Codable {
    var libraries: [String: LibraryExportManifest]

    static let empty = ExportManifest(libraries: [:])

    func libraryManifest(for libraryID: UUID) -> LibraryExportManifest {
        libraries[libraryID.uuidString] ?? .empty
    }

    mutating func setLibraryManifest(_ libraryManifest: LibraryExportManifest, for libraryID: UUID) {
        libraries[libraryID.uuidString] = libraryManifest
    }
}

struct LibraryExportManifest: Codable {
    var source: LibraryAssetSource?
    var selectedSharedAlbumIDs: [String]?
    var baselineDate: Date?
    var exportedAssets: [String: ExportedAssetRecord]

    static let empty = LibraryExportManifest(
        source: nil,
        selectedSharedAlbumIDs: nil,
        baselineDate: nil,
        exportedAssets: [:]
    )
}

struct ExportedAssetRecord: Codable {
    var modificationDate: Date?
    var resourceKeys: [String]
    var outputPaths: [String]

    enum CodingKeys: String, CodingKey {
        case modificationDate
        case resourceKeys
        case outputPaths
        case outputPath
    }

    init(
        modificationDate: Date?,
        resourceKeys: [String],
        outputPaths: [String]
    ) {
        self.modificationDate = modificationDate
        self.resourceKeys = resourceKeys
        self.outputPaths = outputPaths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modificationDate = try container.decodeIfPresent(Date.self, forKey: .modificationDate)
        resourceKeys = try container.decodeIfPresent([String].self, forKey: .resourceKeys) ?? []
        if let outputPaths = try container.decodeIfPresent([String].self, forKey: .outputPaths) {
            self.outputPaths = outputPaths
        } else if let legacyOutputPath = try container.decodeIfPresent(String.self, forKey: .outputPath) {
            outputPaths = [legacyOutputPath]
        } else {
            outputPaths = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(modificationDate, forKey: .modificationDate)
        try container.encode(resourceKeys, forKey: .resourceKeys)
        try container.encode(outputPaths, forKey: .outputPaths)
    }
}
