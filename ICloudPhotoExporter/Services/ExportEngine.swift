import Foundation
import OSLog
import Photos
import UniformTypeIdentifiers

struct LibrarySyncResult {
    let libraryID: UUID
    let libraryName: String
    let exportedCount: Int
    let skippedCount: Int
}

enum ExportEngineError: LocalizedError {
    case destinationRootMissing(String)
    case destinationRootNotDirectory(String)

    var errorDescription: String? {
        switch self {
        case let .destinationRootMissing(path):
            return "Export folder does not exist: \(path)"
        case let .destinationRootNotDirectory(path):
            return "Export folder is not a directory: \(path)"
        }
    }
}

final class ExportEngine {
    private let photoLibraryService: PhotoLibraryService
    private let manifestStore: ExportManifestStore
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.meziantou.icloudphotoexporter", category: "ExportEngine")

    init(
        photoLibraryService: PhotoLibraryService,
        manifestStore: ExportManifestStore,
        fileManager: FileManager = .default
    ) {
        self.photoLibraryService = photoLibraryService
        self.manifestStore = manifestStore
        self.fileManager = fileManager
    }

    func synchronize(library: LibraryConfiguration) async throws -> LibrarySyncResult {
        try await photoLibraryService.ensureAuthorized()
        try validateRootFolderExists(library.outputFolderURL)

        let selectedSharedAlbumIDs = Set(library.selectedSharedAlbumIDs)
        let assets = photoLibraryService.fetchAssetsSortedByCreationDate(
            source: library.assetSource,
            selectedSharedAlbumIDs: selectedSharedAlbumIDs
        )
        var manifest = try await manifestStore.loadManifest()
        var libraryManifest = manifest.libraryManifest(for: library.id)

        let baselineDate = resolveBaselineDate(
            assets: assets,
            library: library,
            libraryManifest: &libraryManifest
        )

        var exportedCount = 0
        var skippedCount = 0

        for asset in assets {
            guard shouldProcess(asset: asset, baselineDate: baselineDate) else {
                continue
            }

            let effectiveModificationDate = asset.modificationDate ?? asset.creationDate
            let resources = photoLibraryService.preferredResources(for: asset)
            guard !resources.isEmpty else {
                logger.warning("Skipping asset \(asset.localIdentifier, privacy: .public): no exportable resource")
                skippedCount += 1
                continue
            }

            let resourceKeys = resources.map(resourceKey(for:))
            let existingRecord = libraryManifest.exportedAssets[asset.localIdentifier]

            if shouldSkipExport(
                existingRecord: existingRecord,
                effectiveModificationDate: effectiveModificationDate,
                resourceKeys: resourceKeys
            ) {
                skippedCount += 1
                continue
            }

            var outputPaths: [String] = []
            var exportedResourceKeys: [String] = []
            outputPaths.reserveCapacity(resources.count)
            exportedResourceKeys.reserveCapacity(resources.count)

            for (index, resource) in resources.enumerated() {
                let destinationURL = try destinationURL(
                    for: asset,
                    resource: resource,
                    rootDirectory: library.outputFolderURL,
                    preferredExistingPath: preferredExistingPath(
                        for: resourceKeys[index],
                        existingRecord: existingRecord
                    )
                )

                do {
                    try await writeAssetResource(resource, destinationURL: destinationURL)
                    updateFileDates(for: asset, destinationURL: destinationURL)
                    outputPaths.append(destinationURL.path)
                    exportedResourceKeys.append(resourceKeys[index])
                } catch {
                    if canSkipResourceFailure(error, for: resource) {
                        logger.warning("Skipping optional resource \(resource.originalFilename, privacy: .public) for asset \(asset.localIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        continue
                    }

                    throw error
                }
            }

            guard !outputPaths.isEmpty else {
                skippedCount += 1
                continue
            }

            libraryManifest.exportedAssets[asset.localIdentifier] = ExportedAssetRecord(
                modificationDate: effectiveModificationDate,
                resourceKeys: exportedResourceKeys,
                outputPaths: outputPaths
            )
            exportedCount += 1
        }

        manifest.setLibraryManifest(libraryManifest, for: library.id)
        try await manifestStore.saveManifest(manifest)

        return LibrarySyncResult(
            libraryID: library.id,
            libraryName: library.name,
            exportedCount: exportedCount,
            skippedCount: skippedCount
        )
    }

    private func resolveBaselineDate(
        assets: [PHAsset],
        library: LibraryConfiguration,
        libraryManifest: inout LibraryExportManifest
    ) -> Date? {
        let normalizedSelectedAlbums = library.assetSource == .sharedAlbums
            ? library.selectedSharedAlbumIDs.sorted()
            : []

        if let source = libraryManifest.source, source != library.assetSource {
            libraryManifest = .empty
        } else if (libraryManifest.selectedSharedAlbumIDs ?? []) != normalizedSelectedAlbums {
            libraryManifest = .empty
        }

        libraryManifest.source = library.assetSource
        libraryManifest.selectedSharedAlbumIDs = normalizedSelectedAlbums

        if let baselineDate = libraryManifest.baselineDate {
            return baselineDate
        }

        switch library.initialSyncMode {
        case .fullHistory:
            return nil
        case .fromDate:
            let baselineDate = library.initialSyncDate ?? .now
            libraryManifest.baselineDate = baselineDate
            return baselineDate
        case .newOnly:
            let latestDate = assets
                .compactMap { $0.creationDate ?? $0.modificationDate }
                .max()
            libraryManifest.baselineDate = latestDate
            return latestDate
        }
    }

    private func shouldProcess(asset: PHAsset, baselineDate: Date?) -> Bool {
        guard let baselineDate else {
            return true
        }

        guard let assetDate = asset.creationDate ?? asset.modificationDate else {
            return false
        }

        return assetDate >= baselineDate
    }

    private func resourceKey(for resource: PHAssetResource) -> String {
        "\(resource.type.rawValue)|\(resource.originalFilename)"
    }

    private func shouldSkipExport(
        existingRecord: ExportedAssetRecord?,
        effectiveModificationDate: Date?,
        resourceKeys: [String]
    ) -> Bool {
        guard let existingRecord else {
            return false
        }

        guard existingRecord.modificationDate == effectiveModificationDate else {
            return false
        }

        guard isExistingRecordCompatible(existingRecord, resourceKeys: resourceKeys) else {
            return false
        }

        guard !existingRecord.outputPaths.isEmpty else {
            return false
        }

        return existingRecord.outputPaths.allSatisfy { outputPath in
            fileManager.fileExists(atPath: outputPath)
        }
    }

    private func isExistingRecordCompatible(_ existingRecord: ExportedAssetRecord, resourceKeys: [String]) -> Bool {
        if existingRecord.resourceKeys.isEmpty {
            return resourceKeys.count == 1 && existingRecord.outputPaths.count == 1
        }

        return existingRecord.resourceKeys == resourceKeys &&
            existingRecord.outputPaths.count == resourceKeys.count
    }

    private func preferredExistingPath(for resourceKey: String, existingRecord: ExportedAssetRecord?) -> String? {
        guard let existingRecord else {
            return nil
        }

        if existingRecord.resourceKeys.isEmpty {
            return existingRecord.outputPaths.first
        }

        guard let index = existingRecord.resourceKeys.firstIndex(of: resourceKey),
              existingRecord.outputPaths.indices.contains(index)
        else {
            return nil
        }

        return existingRecord.outputPaths[index]
    }

    private func canSkipResourceFailure(_ error: Error, for resource: PHAssetResource) -> Bool {
        guard resource.type == .pairedVideo else {
            return false
        }

        let nsError = error as NSError
        guard nsError.domain == "PHPhotosErrorDomain" else {
            return false
        }

        return nsError.code == 3164
    }

    private func destinationURL(
        for asset: PHAsset,
        resource: PHAssetResource,
        rootDirectory: URL,
        preferredExistingPath: String?
    ) throws -> URL {
        let directoryURL = exportDirectory(for: asset, rootDirectory: rootDirectory)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let originalFilename = resource.originalFilename
        let sanitizedFilename = sanitizeFilename(originalFilename, uti: resource.uniformTypeIdentifier)
        let preferredURL = directoryURL.appendingPathComponent(sanitizedFilename, isDirectory: false)

        if let preferredExistingPath,
           preferredExistingPath == preferredURL.path
        {
            return preferredURL
        }

        if !fileManager.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        let filenameBase = (sanitizedFilename as NSString).deletingPathExtension
        let filenameExtension = (sanitizedFilename as NSString).pathExtension
        var index = 1

        while true {
            let candidateName: String
            if filenameExtension.isEmpty {
                candidateName = "\(filenameBase)-\(index)"
            } else {
                candidateName = "\(filenameBase)-\(index).\(filenameExtension)"
            }

            let candidateURL = directoryURL.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }

            index += 1
        }
    }

    private func validateRootFolderExists(_ rootDirectory: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: rootDirectory.path, isDirectory: &isDirectory)

        guard exists else {
            throw ExportEngineError.destinationRootMissing(rootDirectory.path)
        }

        guard isDirectory.boolValue else {
            throw ExportEngineError.destinationRootNotDirectory(rootDirectory.path)
        }
    }

    private func exportDirectory(for asset: PHAsset, rootDirectory: URL) -> URL {
        guard let date = asset.creationDate ?? asset.modificationDate else {
            return rootDirectory.appendingPathComponent("Unknown", isDirectory: true)
        }

        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0

        return rootDirectory
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
    }

    private func sanitizeFilename(_ originalFilename: String, uti: String?) -> String {
        let nsFilename = originalFilename as NSString
        var name = nsFilename.deletingPathExtension
        var ext = nsFilename.pathExtension

        if ext.isEmpty,
           let uti,
           let utType = UTType(uti),
           let resolvedExtension = utType.preferredFilenameExtension
        {
            ext = resolvedExtension
        }

        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleanedScalars = name.unicodeScalars.map { scalar -> UnicodeScalar in
            if invalidCharacters.contains(scalar) {
                return "-"
            }
            return scalar
        }
        name = String(String.UnicodeScalarView(cleanedScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if name.isEmpty {
            name = "asset"
        }

        if ext.isEmpty {
            return name
        }

        return "\(name).\(ext)"
    }

    private func writeAssetResource(_ resource: PHAssetResource, destinationURL: URL) async throws {
        let temporaryFilename = UUID().uuidString
        let temporaryURL = fileManager.temporaryDirectory.appendingPathComponent(temporaryFilename, isDirectory: false)

        try await photoLibraryService.writeResourceData(resource, to: temporaryURL)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    private func updateFileDates(for asset: PHAsset, destinationURL: URL) {
        var attributes: [FileAttributeKey: Any] = [:]

        if let creationDate = asset.creationDate {
            attributes[.creationDate] = creationDate
        }

        if let modificationDate = asset.modificationDate {
            attributes[.modificationDate] = modificationDate
        }

        guard !attributes.isEmpty else {
            return
        }

        do {
            try fileManager.setAttributes(attributes, ofItemAtPath: destinationURL.path)
        } catch {
            logger.warning("Could not set file dates for \(destinationURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
