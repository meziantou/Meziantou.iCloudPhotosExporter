import AppKit
import Foundation
import Photos

struct SharedAlbumSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let estimatedAssetCount: Int
}

enum PhotoLibraryError: LocalizedError {
    case unauthorized
    case denied
    case restricted
    case unableToCreateTemporaryFile

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Photo library access is not granted."
        case .denied:
            return """
            Photo library access was denied.

            If this started after signing changes, reset Photos permission in Terminal:
            \(PhotoLibraryService.photosPermissionResetCommand())

            Then retry sync or refresh shared albums to show the permission prompt again.
            If the prompt still does not appear, reopen the app and try once more.
            """
        case .restricted:
            return "Photo library access is restricted on this Mac."
        case .unableToCreateTemporaryFile:
            return "Could not create a temporary export file."
        }
    }
}

final class PhotoLibraryService {
    static func photosPermissionBundleIdentifier() -> String {
        let bundleID = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bundleID, !bundleID.isEmpty {
            return bundleID
        }

        return "com.meziantou.icloudphotoexporter"
    }

    static func photosPermissionResetCommand() -> String {
        "tccutil reset Photos \(photosPermissionBundleIdentifier())"
    }

    func ensureAuthorized() async throws {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch currentStatus {
        case .authorized, .limited:
            return
        case .notDetermined:
            try evaluateAuthorizationStatus(await requestAuthorization())
        case .denied:
            // After `tccutil reset`, PhotoKit may still report `.denied` in-process until
            // authorization is requested again.
            try evaluateAuthorizationStatus(await requestAuthorization())
        case .restricted:
            throw PhotoLibraryError.restricted
        @unknown default:
            throw PhotoLibraryError.unauthorized
        }
    }

    func fetchAssetsSortedByCreationDate(source: LibraryAssetSource, selectedSharedAlbumIDs: Set<String>) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: true),
            NSSortDescriptor(key: "modificationDate", ascending: true),
        ]
        options.includeAllBurstAssets = false
        options.includeHiddenAssets = false

        var assets: [PHAsset] = []

        switch source {
        case .mainLibrary:
            let result = PHAsset.fetchAssets(with: options)
            assets.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                assets.append(asset)
            }
        case .sharedAlbums:
            var uniqueAssets: [String: PHAsset] = [:]
            let sharedCollections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
            sharedCollections.enumerateObjects { collection, _, _ in
                if !selectedSharedAlbumIDs.isEmpty, !selectedSharedAlbumIDs.contains(collection.localIdentifier) {
                    return
                }

                let result = PHAsset.fetchAssets(in: collection, options: options)
                result.enumerateObjects { asset, _, _ in
                    uniqueAssets[asset.localIdentifier] = asset
                }
            }

            assets = Array(uniqueAssets.values)
            assets.sort { left, right in
                let leftDate = left.creationDate ?? left.modificationDate ?? .distantPast
                let rightDate = right.creationDate ?? right.modificationDate ?? .distantPast
                if leftDate == rightDate {
                    return left.localIdentifier < right.localIdentifier
                }
                return leftDate < rightDate
            }
        }

        return assets
    }

    func fetchSharedAlbums() -> [SharedAlbumSummary] {
        var albums: [SharedAlbumSummary] = []
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)

        collections.enumerateObjects { collection, _, _ in
            let title = Self.normalizedTitle(for: collection)
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            albums.append(
                SharedAlbumSummary(
                    id: collection.localIdentifier,
                    title: title,
                    estimatedAssetCount: count
                )
            )
        }

        return albums.sorted { left, right in
            left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    func fetchAsset(localIdentifier: String) -> PHAsset? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        return result.firstObject
    }

    func preferredResources(for asset: PHAsset) -> [PHAssetResource] {
        let resources = PHAssetResource.assetResources(for: asset)
        var selected: [PHAssetResource] = []

        switch asset.mediaType {
        case .image:
            if let primaryPhoto = firstResource(in: resources, types: [.photo, .fullSizePhoto, .alternatePhoto]) {
                selected.append(primaryPhoto)
            }

            if let pairedVideo = firstResource(in: resources, types: [.pairedVideo]),
               !selected.contains(where: { $0 === pairedVideo })
            {
                selected.append(pairedVideo)
            }
        case .video:
            if let primaryVideo = firstResource(in: resources, types: [.video, .fullSizeVideo]) {
                selected.append(primaryVideo)
            }
        default:
            if let primary = firstResource(in: resources, types: [.photo, .video, .fullSizePhoto, .fullSizeVideo, .pairedVideo]) {
                selected.append(primary)
            }
        }

        if selected.isEmpty,
           let fallback = resources.first(where: { $0.type != .adjustmentData })
        {
            selected.append(fallback)
        }

        return selected
    }

    func writeResourceData(_ resource: PHAssetResource, to destinationURL: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destinationURL, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status)
                }
            }
        }
    }

    private func evaluateAuthorizationStatus(_ status: PHAuthorizationStatus) throws {
        switch status {
        case .authorized, .limited:
            return
        case .denied:
            throw PhotoLibraryError.denied
        case .restricted:
            throw PhotoLibraryError.restricted
        case .notDetermined:
            throw PhotoLibraryError.unauthorized
        @unknown default:
            throw PhotoLibraryError.unauthorized
        }
    }

    private static func normalizedTitle(for collection: PHAssetCollection) -> String {
        let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Untitled shared album" : title
    }

    private func firstResource(in resources: [PHAssetResource], types: [PHAssetResourceType]) -> PHAssetResource? {
        for type in types {
            if let resource = resources.first(where: { $0.type == type }) {
                return resource
            }
        }

        return nil
    }
}
