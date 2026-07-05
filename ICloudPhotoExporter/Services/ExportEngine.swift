import Foundation
import OSLog
import Photos
import UniformTypeIdentifiers

struct LibrarySyncResult: Sendable {
    let libraryID: UUID
    let libraryName: String
    let exportedCount: Int
    let skippedCount: Int
}

enum ExportProgressState: Sendable {
    case copying
    case copied
}

struct ExportProgressUpdate: Sendable {
    let libraryID: UUID
    let libraryName: String
    let fileName: String
    let destinationPath: String
    let state: ExportProgressState
}

private struct AssetExportWorkItem: Sendable {
    let localIdentifier: String
    let existingRecord: ExportedAssetRecord?
}

private struct AssetExportOutcome: Sendable {
    let localIdentifier: String
    let exportedRecord: ExportedAssetRecord?
    let exportedCount: Int
    let skippedCount: Int
}

private struct AssetBatchOutcome: Sendable {
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

final class ExportEngine: @unchecked Sendable {
    private let photoLibraryService: PhotoLibraryService
    private let manifestStore: ExportManifestStore
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.meziantou.icloudphotosexporter", category: "ExportEngine")
    private let maxConcurrentAssetTasks: Int

    init(
        photoLibraryService: PhotoLibraryService,
        manifestStore: ExportManifestStore,
        fileManager: FileManager = .default,
        maxConcurrentAssetTasks: Int? = nil
    ) {
        self.photoLibraryService = photoLibraryService
        self.manifestStore = manifestStore
        self.fileManager = fileManager
        let defaultLimit = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 6))
        if let maxConcurrentAssetTasks {
            self.maxConcurrentAssetTasks = max(1, maxConcurrentAssetTasks)
        } else {
            self.maxConcurrentAssetTasks = defaultLimit
        }
    }

    func synchronize(
        library: LibraryConfiguration,
        progress: ((ExportProgressUpdate) async -> Void)? = nil
    ) async throws -> LibrarySyncResult {
        try await photoLibraryService.ensureAuthorized()
        try validateRootFolderExists(library.outputFolderURL)

        let selectedSharedAlbumIDs = Set(library.selectedSharedAlbumIDs)
        let assets = photoLibraryService.fetchAssetsSortedByCreationDate(
            source: library.assetSource,
            selectedSharedAlbumIDs: selectedSharedAlbumIDs
        )
        let manifest = try await manifestStore.loadManifest()
        var libraryManifest = manifest.libraryManifest(for: library.id)

        let baselineDate = resolveBaselineDate(
            assets: assets,
            library: library,
            libraryManifest: &libraryManifest
        )

        if !library.exportAdjustmentData {
            libraryManifest.adjustmentDataMigrationCompleted = false
        }

        try await manifestStore.saveLibraryManifest(libraryManifest, for: library.id)

        let adjustmentMigrationOutcome = try await migrateMissingAdjustmentDataIfNeeded(
            assets: assets,
            library: library,
            libraryManifest: &libraryManifest,
            progress: progress
        )

        let workItems = assets.compactMap { asset -> AssetExportWorkItem? in
            guard shouldProcess(asset: asset, baselineDate: baselineDate) else {
                return nil
            }

            return AssetExportWorkItem(
                localIdentifier: asset.localIdentifier,
                existingRecord: libraryManifest.exportedAssets[asset.localIdentifier]
            )
        }

        let concurrencyLimit = min(maxConcurrentAssetTasks, max(1, workItems.count))
        let destinationPathCoordinator = DestinationPathCoordinator(fileManager: fileManager)
        let assetBatchOutcome = try await synchronizeAssets(
            workItems: workItems,
            library: library,
            destinationPathCoordinator: destinationPathCoordinator,
            concurrencyLimit: concurrencyLimit,
            progress: progress,
            recordExport: { localIdentifier, exportedRecord in
                libraryManifest.exportedAssets[localIdentifier] = exportedRecord
                try await self.manifestStore.saveLibraryManifest(libraryManifest, for: library.id)
            }
        )

        return LibrarySyncResult(
            libraryID: library.id,
            libraryName: library.name,
            exportedCount: adjustmentMigrationOutcome.exportedCount + assetBatchOutcome.exportedCount,
            skippedCount: adjustmentMigrationOutcome.skippedCount + assetBatchOutcome.skippedCount
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

    private func migrateMissingAdjustmentDataIfNeeded(
        assets: [PHAsset],
        library: LibraryConfiguration,
        libraryManifest: inout LibraryExportManifest,
        progress: ((ExportProgressUpdate) async -> Void)?
    ) async throws -> AssetBatchOutcome {
        guard library.exportAdjustmentData else {
            return AssetBatchOutcome(exportedCount: 0, skippedCount: 0)
        }

        guard !libraryManifest.adjustmentDataMigrationCompleted else {
            return AssetBatchOutcome(exportedCount: 0, skippedCount: 0)
        }

        guard !libraryManifest.exportedAssets.isEmpty else {
            libraryManifest.adjustmentDataMigrationCompleted = true
            try await manifestStore.saveLibraryManifest(libraryManifest, for: library.id)
            return AssetBatchOutcome(exportedCount: 0, skippedCount: 0)
        }

        let destinationPathCoordinator = DestinationPathCoordinator(fileManager: fileManager)
        var exportedAssetCount = 0

        for asset in assets {
            guard let existingRecord = libraryManifest.exportedAssets[asset.localIdentifier] else {
                continue
            }

            let adjustmentResources = photoLibraryService.adjustmentDataResources(for: asset)
            guard !adjustmentResources.isEmpty else {
                continue
            }

            let mediaResources = photoLibraryService.preferredResources(
                for: asset,
                includeAdjustmentData: false
            )
            guard !mediaResources.isEmpty else {
                logger.debug("Skipping adjustment data migration for asset \(asset.localIdentifier, privacy: .public): original media resource is missing")
                continue
            }

            var updatedRecord = normalizedRecordForAdjustmentDataMigration(
                existingRecord,
                mediaResources: mediaResources
            )
            let originalRecord = updatedRecord

            guard let primaryMediaOutputPath = firstExistingMediaOutputPath(in: updatedRecord) else {
                logger.debug("Skipping adjustment data migration for asset \(asset.localIdentifier, privacy: .public): original media file is missing")
                continue
            }

            let primaryMediaURL = URL(fileURLWithPath: primaryMediaOutputPath, isDirectory: false)
            var exportedAdjustmentForAsset = false

            for adjustmentResource in adjustmentResources {
                let adjustmentResourceKey = resourceKey(for: adjustmentResource)
                if let existingAdjustmentPath = preferredExistingPath(
                    for: adjustmentResourceKey,
                    existingRecord: updatedRecord
                ), fileManager.fileExists(atPath: existingAdjustmentPath) {
                    continue
                }

                let destinationURL = try await destinationURL(
                    for: asset,
                    resource: adjustmentResource,
                    rootDirectory: library.outputFolderURL,
                    fileNameFormat: library.fileNameFormat,
                    sidecarBaseURL: primaryMediaURL,
                    preferredExistingPath: preferredExistingPath(
                        for: adjustmentResourceKey,
                        existingRecord: updatedRecord
                    ),
                    destinationPathCoordinator: destinationPathCoordinator
                )

                guard !fileManager.fileExists(atPath: destinationURL.path) else {
                    recordResourceOutput(
                        resourceKey: adjustmentResourceKey,
                        outputPath: destinationURL.path,
                        in: &updatedRecord
                    )
                    continue
                }

                do {
                    if let progress {
                        await progress(
                            ExportProgressUpdate(
                                libraryID: library.id,
                                libraryName: library.name,
                                fileName: destinationURL.lastPathComponent,
                                destinationPath: destinationURL.path,
                                state: .copying
                            )
                        )
                    }

                    logger.info("Exporting adjustment data: \(destinationURL.lastPathComponent, privacy: .public)")
                    try await writeAssetResource(adjustmentResource, destinationURL: destinationURL)
                    updateFileDates(for: asset, destinationURL: destinationURL)
                    recordResourceOutput(
                        resourceKey: adjustmentResourceKey,
                        outputPath: destinationURL.path,
                        in: &updatedRecord
                    )
                    exportedAdjustmentForAsset = true

                    if let progress {
                        await progress(
                            ExportProgressUpdate(
                                libraryID: library.id,
                                libraryName: library.name,
                                fileName: destinationURL.lastPathComponent,
                                destinationPath: destinationURL.path,
                                state: .copied
                            )
                        )
                    }
                } catch {
                    await destinationPathCoordinator.release(path: destinationURL.path)
                    throw error
                }
            }

            if updatedRecord.resourceKeys != originalRecord.resourceKeys ||
                updatedRecord.outputPaths != originalRecord.outputPaths
            {
                libraryManifest.exportedAssets[asset.localIdentifier] = updatedRecord
                try await manifestStore.saveLibraryManifest(libraryManifest, for: library.id)
            }

            if exportedAdjustmentForAsset {
                exportedAssetCount += 1
            }
        }

        libraryManifest.adjustmentDataMigrationCompleted = true
        try await manifestStore.saveLibraryManifest(libraryManifest, for: library.id)

        return AssetBatchOutcome(exportedCount: exportedAssetCount, skippedCount: 0)
    }

    private func synchronizeAssets(
        workItems: [AssetExportWorkItem],
        library: LibraryConfiguration,
        destinationPathCoordinator: DestinationPathCoordinator,
        concurrencyLimit: Int,
        progress: ((ExportProgressUpdate) async -> Void)?,
        recordExport: (_ localIdentifier: String, _ exportedRecord: ExportedAssetRecord) async throws -> Void
    ) async throws -> AssetBatchOutcome {
        guard !workItems.isEmpty else {
            return AssetBatchOutcome(exportedCount: 0, skippedCount: 0)
        }

        var exportedCount = 0
        var skippedCount = 0

        var nextWorkItemIndex = 0
        let initialTaskCount = min(concurrencyLimit, workItems.count)

        try await withThrowingTaskGroup(of: AssetExportOutcome.self) { group in
            for _ in 0 ..< initialTaskCount {
                let workItem = workItems[nextWorkItemIndex]
                nextWorkItemIndex += 1
                group.addTask { [self] in
                    try await exportAsset(
                        workItem: workItem,
                        library: library,
                        destinationPathCoordinator: destinationPathCoordinator,
                        progress: progress
                    )
                }
            }

            while let outcome = try await group.next() {
                exportedCount += outcome.exportedCount
                skippedCount += outcome.skippedCount

                if let exportedRecord = outcome.exportedRecord {
                    try await recordExport(outcome.localIdentifier, exportedRecord)
                }

                if nextWorkItemIndex < workItems.count {
                    let workItem = workItems[nextWorkItemIndex]
                    nextWorkItemIndex += 1
                    group.addTask { [self] in
                        try await exportAsset(
                            workItem: workItem,
                            library: library,
                            destinationPathCoordinator: destinationPathCoordinator,
                            progress: progress
                        )
                    }
                }
            }
        }

        return AssetBatchOutcome(
            exportedCount: exportedCount,
            skippedCount: skippedCount
        )
    }

    private func exportAsset(
        workItem: AssetExportWorkItem,
        library: LibraryConfiguration,
        destinationPathCoordinator: DestinationPathCoordinator,
        progress: ((ExportProgressUpdate) async -> Void)?
    ) async throws -> AssetExportOutcome {
        guard let asset = photoLibraryService.fetchAsset(localIdentifier: workItem.localIdentifier) else {
            logger.warning("Skipping asset \(workItem.localIdentifier, privacy: .public): asset unavailable")
            return AssetExportOutcome(
                localIdentifier: workItem.localIdentifier,
                exportedRecord: nil,
                exportedCount: 0,
                skippedCount: 1
            )
        }

        let effectiveModificationDate = asset.modificationDate ?? asset.creationDate
        let resources = photoLibraryService.preferredResources(
            for: asset,
            includeAdjustmentData: library.exportAdjustmentData
        )
        guard !resources.isEmpty else {
            logger.warning("Skipping asset \(asset.localIdentifier, privacy: .public): no exportable resource")
            return AssetExportOutcome(
                localIdentifier: workItem.localIdentifier,
                exportedRecord: nil,
                exportedCount: 0,
                skippedCount: 1
            )
        }

        let resourceKeys = resources.map(resourceKey(for:))
        if shouldSkipExport(
            existingRecord: workItem.existingRecord,
            effectiveModificationDate: effectiveModificationDate,
            resourceKeys: resourceKeys
        ) {
            return AssetExportOutcome(
                localIdentifier: workItem.localIdentifier,
                exportedRecord: nil,
                exportedCount: 0,
                skippedCount: 1
            )
        }

        var outputPaths: [String] = []
        var exportedResourceKeys: [String] = []
        outputPaths.reserveCapacity(resources.count)
        exportedResourceKeys.reserveCapacity(resources.count)
        var primaryMediaDestinationURL: URL?

        for (index, resource) in resources.enumerated() {
            let destinationURL = try await destinationURL(
                for: asset,
                resource: resource,
                rootDirectory: library.outputFolderURL,
                fileNameFormat: library.fileNameFormat,
                sidecarBaseURL: isAdjustmentDataResource(resource) ? primaryMediaDestinationURL : nil,
                preferredExistingPath: preferredExistingPath(
                    for: resourceKeys[index],
                    existingRecord: workItem.existingRecord
                ),
                destinationPathCoordinator: destinationPathCoordinator
            )

            do {
                if let progress {
                    await progress(
                        ExportProgressUpdate(
                            libraryID: library.id,
                            libraryName: library.name,
                            fileName: destinationURL.lastPathComponent,
                            destinationPath: destinationURL.path,
                            state: .copying
                        )
                    )
                }

                if isAdjustmentDataResource(resource) {
                    logger.info("Exporting adjustment data: \(destinationURL.lastPathComponent, privacy: .public)")
                }

                try await writeAssetResource(resource, destinationURL: destinationURL)
                updateFileDates(for: asset, destinationURL: destinationURL)
                outputPaths.append(destinationURL.path)
                exportedResourceKeys.append(resourceKeys[index])
                if !isAdjustmentDataResource(resource), primaryMediaDestinationURL == nil {
                    primaryMediaDestinationURL = destinationURL
                }

                if let progress {
                    await progress(
                        ExportProgressUpdate(
                            libraryID: library.id,
                            libraryName: library.name,
                            fileName: destinationURL.lastPathComponent,
                            destinationPath: destinationURL.path,
                            state: .copied
                        )
                    )
                }
            } catch {
                await destinationPathCoordinator.release(path: destinationURL.path)

                if canSkipResourceFailure(error, for: resource) {
                    logger.warning("Skipping optional resource \(resource.originalFilename, privacy: .public) for asset \(asset.localIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }

                throw error
            }
        }

        guard !outputPaths.isEmpty else {
            return AssetExportOutcome(
                localIdentifier: workItem.localIdentifier,
                exportedRecord: nil,
                exportedCount: 0,
                skippedCount: 1
            )
        }

        return AssetExportOutcome(
            localIdentifier: workItem.localIdentifier,
            exportedRecord: ExportedAssetRecord(
                modificationDate: effectiveModificationDate,
                resourceKeys: exportedResourceKeys,
                outputPaths: outputPaths
            ),
            exportedCount: 1,
            skippedCount: 0
        )
    }

    private func resourceKey(for resource: PHAssetResource) -> String {
        "\(resource.type.rawValue)|\(resource.originalFilename)"
    }

    private func isAdjustmentDataResource(_ resource: PHAssetResource) -> Bool {
        resource.type == .adjustmentData
    }

    private func isAdjustmentDataResourceKey(_ resourceKey: String) -> Bool {
        resourceKey.hasPrefix("\(PHAssetResourceType.adjustmentData.rawValue)|")
    }

    private func shouldSkipExport(
        existingRecord: ExportedAssetRecord?,
        effectiveModificationDate: Date?,
        resourceKeys: [String]
    ) -> Bool {
        guard let existingRecord else {
            return false
        }

        guard areModificationDatesEquivalent(existingRecord.modificationDate, effectiveModificationDate) else {
            return false
        }

        guard let outputPaths = existingOutputPaths(
            for: resourceKeys,
            in: existingRecord
        ), !outputPaths.isEmpty else {
            return false
        }

        return outputPaths.allSatisfy { outputPath in
            fileManager.fileExists(atPath: outputPath)
        }
    }

    private func areModificationDatesEquivalent(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhsDate?, rhsDate?):
            // Older manifests persisted dates with second precision.
            return abs(lhsDate.timeIntervalSince(rhsDate)) < 1
        default:
            return false
        }
    }

    private func existingOutputPaths(for resourceKeys: [String], in existingRecord: ExportedAssetRecord) -> [String]? {
        if existingRecord.resourceKeys.isEmpty {
            guard resourceKeys.count == 1 && existingRecord.outputPaths.count == 1 else {
                return nil
            }

            return existingRecord.outputPaths
        }

        var outputPaths: [String] = []
        outputPaths.reserveCapacity(resourceKeys.count)

        for resourceKey in resourceKeys {
            guard let index = existingRecord.resourceKeys.firstIndex(of: resourceKey),
                  existingRecord.outputPaths.indices.contains(index)
            else {
                return nil
            }

            outputPaths.append(existingRecord.outputPaths[index])
        }

        return outputPaths
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

    private func normalizedRecordForAdjustmentDataMigration(
        _ existingRecord: ExportedAssetRecord,
        mediaResources: [PHAssetResource]
    ) -> ExportedAssetRecord {
        guard existingRecord.resourceKeys.isEmpty else {
            return existingRecord
        }

        var normalizedRecord = existingRecord
        let mediaResourceKeys = mediaResources.map(resourceKey(for:))
        let mappedResourceCount = min(mediaResourceKeys.count, normalizedRecord.outputPaths.count)
        normalizedRecord.resourceKeys = Array(mediaResourceKeys.prefix(mappedResourceCount))
        return normalizedRecord
    }

    private func firstExistingMediaOutputPath(in existingRecord: ExportedAssetRecord) -> String? {
        if existingRecord.resourceKeys.isEmpty {
            return existingRecord.outputPaths.first { outputPath in
                fileManager.fileExists(atPath: outputPath)
            }
        }

        for (index, resourceKey) in existingRecord.resourceKeys.enumerated()
            where !isAdjustmentDataResourceKey(resourceKey) && existingRecord.outputPaths.indices.contains(index)
        {
            let outputPath = existingRecord.outputPaths[index]
            if fileManager.fileExists(atPath: outputPath) {
                return outputPath
            }
        }

        return nil
    }

    private func recordResourceOutput(
        resourceKey: String,
        outputPath: String,
        in exportedRecord: inout ExportedAssetRecord
    ) {
        if let index = exportedRecord.resourceKeys.firstIndex(of: resourceKey),
           exportedRecord.outputPaths.indices.contains(index)
        {
            exportedRecord.outputPaths[index] = outputPath
            return
        }

        exportedRecord.resourceKeys.append(resourceKey)
        exportedRecord.outputPaths.append(outputPath)
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
        fileNameFormat: String,
        sidecarBaseURL: URL?,
        preferredExistingPath: String?,
        destinationPathCoordinator: DestinationPathCoordinator
    ) async throws -> URL {
        let directoryURL = sidecarBaseURL?.deletingLastPathComponent() ??
            exportDirectory(for: asset, rootDirectory: rootDirectory)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let originalFilename = resource.originalFilename
        let sanitizedFilename = applyFileNameFormat(
            fileNameFormat,
            asset: asset,
            originalFilename: originalFilename,
            uti: resource.uniformTypeIdentifier
        )
        let destinationFilename: String
        if let sidecarBaseURL {
            destinationFilename = sidecarFilename(
                from: sanitizedFilename,
                sidecarBaseURL: sidecarBaseURL
            )
        } else {
            destinationFilename = sanitizedFilename
        }

        return await destinationPathCoordinator.reserveAvailableURL(
            directoryURL: directoryURL,
            filename: destinationFilename,
            preferredExistingPath: preferredExistingPath
        )
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

    private func sidecarFilename(from sanitizedFilename: String, sidecarBaseURL: URL) -> String {
        let sidecarExtension = (sanitizedFilename as NSString).pathExtension
        guard !sidecarExtension.isEmpty else {
            return sanitizedFilename
        }

        return "\(sidecarBaseURL.deletingPathExtension().lastPathComponent).\(sidecarExtension)"
    }

    private func applyFileNameFormat(
        _ format: String,
        asset: PHAsset,
        originalFilename: String,
        uti: String?
    ) -> String {
        let nsFilename = originalFilename as NSString
        let nameBase = nsFilename.deletingPathExtension
        var ext = nsFilename.pathExtension

        if ext.isEmpty,
           let uti,
           let utType = UTType(uti),
           let resolvedExtension = utType.preferredFilenameExtension
        {
            ext = resolvedExtension
        }

        let extWithDot = ext.isEmpty ? "" : ".\(ext)"

        let date = asset.creationDate ?? asset.modificationDate ?? Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )

        var result = format
        result = result.replacingOccurrences(of: "{yyyy}", with: String(format: "%04d", components.year ?? 0))
        result = result.replacingOccurrences(of: "{MM}",   with: String(format: "%02d", components.month ?? 0))
        result = result.replacingOccurrences(of: "{dd}",   with: String(format: "%02d", components.day ?? 0))
        result = result.replacingOccurrences(of: "{HH}",   with: String(format: "%02d", components.hour ?? 0))
        result = result.replacingOccurrences(of: "{mm}",   with: String(format: "%02d", components.minute ?? 0))
        result = result.replacingOccurrences(of: "{ss}",   with: String(format: "%02d", components.second ?? 0))
        result = result.replacingOccurrences(of: "{ID}",   with: nameBase)
        result = result.replacingOccurrences(of: "{ext}",  with: extWithDot)

        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleanedScalars = result.unicodeScalars.map { scalar -> UnicodeScalar in
            invalidCharacters.contains(scalar) ? UnicodeScalar(45)! : scalar  // 45 = '-'
        }
        result = String(String.UnicodeScalarView(cleanedScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return result.isEmpty ? "asset" : result
    }

    private func writeAssetResource(_ resource: PHAssetResource, destinationURL: URL) async throws {
        let destinationDirectoryURL = destinationURL.deletingLastPathComponent()
        let temporaryFilename = ".\(destinationURL.lastPathComponent).icloudphotosexporter.tmp.\(UUID().uuidString)"
        let temporaryURL = destinationDirectoryURL.appendingPathComponent(temporaryFilename, isDirectory: false)

        do {
            try await photoLibraryService.writeResourceData(resource, to: temporaryURL)

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL, backupItemName: nil, options: [])
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            let writeError = error

            if fileManager.fileExists(atPath: temporaryURL.path) {
                do {
                    try fileManager.removeItem(at: temporaryURL)
                } catch {
                    logger.warning("Could not remove temporary export file \(temporaryURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }

            throw writeError
        }
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

private actor DestinationPathCoordinator {
    private var reservedPaths: Set<String> = []
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func reserveAvailableURL(
        directoryURL: URL,
        filename: String,
        preferredExistingPath: String?
    ) -> URL {
        let preferredURL = directoryURL.appendingPathComponent(filename, isDirectory: false)

        if let preferredExistingPath,
           preferredExistingPath == preferredURL.path
        {
            if reservePreferredPath(preferredURL.path) {
                return preferredURL
            }
        } else if reservePreferredPath(preferredURL.path) {
            return preferredURL
        }

        let filenameBase = (filename as NSString).deletingPathExtension
        let filenameExtension = (filename as NSString).pathExtension
        var index = 1

        while true {
            let candidateName: String
            if filenameExtension.isEmpty {
                candidateName = "\(filenameBase)-\(index)"
            } else {
                candidateName = "\(filenameBase)-\(index).\(filenameExtension)"
            }

            let candidateURL = directoryURL.appendingPathComponent(candidateName, isDirectory: false)
            if reserveIfAvailable(candidateURL.path) {
                return candidateURL
            }

            index += 1
        }
    }

    func release(path: String) {
        reservedPaths.remove(path)
    }

    private func reservePreferredPath(_ path: String) -> Bool {
        guard !reservedPaths.contains(path) else {
            return false
        }

        reservedPaths.insert(path)
        return true
    }

    private func reserveIfAvailable(_ path: String) -> Bool {
        guard !reservedPaths.contains(path) else {
            return false
        }

        guard !fileManager.fileExists(atPath: path) else {
            return false
        }

        reservedPaths.insert(path)
        return true
    }
}
