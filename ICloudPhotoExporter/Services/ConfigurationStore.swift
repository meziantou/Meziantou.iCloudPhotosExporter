import Foundation

actor ConfigurationStore {
    private let configurationURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let rootDirectory = appSupportDirectory.appendingPathComponent("ICloudPhotoExporter", isDirectory: true)
        self.configurationURL = rootDirectory.appendingPathComponent("configuration.json", isDirectory: false)

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> AppConfiguration {
        guard fileManager.fileExists(atPath: configurationURL.path) else {
            return .default
        }

        let data = try Data(contentsOf: configurationURL)
        return try decoder.decode(AppConfiguration.self, from: data)
    }

    func save(_ configuration: AppConfiguration) throws {
        try ensureDirectoryExists()
        let data = try encoder.encode(configuration)
        try data.write(to: configurationURL, options: .atomic)
    }

    private func ensureDirectoryExists() throws {
        let directoryURL = configurationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}
