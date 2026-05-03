import Foundation

actor ExportManifestStore {
    private let manifestURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let rootDirectory = appSupportDirectory.appendingPathComponent("ICloudPhotoExporter", isDirectory: true)
        self.manifestURL = rootDirectory.appendingPathComponent("manifest.json", isDirectory: false)

        let preciseDateFormatter = ISO8601DateFormatter()
        preciseDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let legacyDateFormatter = ISO8601DateFormatter()
        legacyDateFormatter.formatOptions = [.withInternetDateTime]

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(preciseDateFormatter.string(from: date))
        }

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = preciseDateFormatter.date(from: value) ?? legacyDateFormatter.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
    }

    func loadManifest() throws -> ExportManifest {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return .empty
        }

        let data = try Data(contentsOf: manifestURL)
        return try decoder.decode(ExportManifest.self, from: data)
    }

    func saveManifest(_ manifest: ExportManifest) throws {
        try ensureDirectoryExists()
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    func saveLibraryManifest(_ libraryManifest: LibraryExportManifest, for libraryID: UUID) throws {
        var manifest = try loadManifest()
        manifest.setLibraryManifest(libraryManifest, for: libraryID)
        try saveManifest(manifest)
    }

    private func ensureDirectoryExists() throws {
        let directoryURL = manifestURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}
