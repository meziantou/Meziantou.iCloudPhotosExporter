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
            return "Photo library access was denied. Enable access in System Settings."
        case .restricted:
            return "Photo library access is restricted on this Mac."
        case .unableToCreateTemporaryFile:
            return "Could not create a temporary export file."
        }
    }
}

final class PhotoLibraryService {
    func ensureAuthorized() async throws {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch currentStatus {
        case .authorized, .limited:
            return
        case .notDetermined:
            let requested = await requestAuthorization()
            switch requested {
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
        case .denied:
            throw PhotoLibraryError.denied
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
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
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
