import Foundation
import Photos
import StorageCleanerCore

enum PhotoLibraryAccess: Equatable, Sendable {
    case notDetermined
    case full
    case limited
    case denied

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized: self = .full
        case .limited: self = .limited
        case .notDetermined: self = .notDetermined
        default: self = .denied
        }
    }

    var canScan: Bool { self == .full || self == .limited }
}

/// Reads the photo library. Strictly read-only: it only fetches assets and their resource
/// metadata, never requests image or video data, so nothing is downloaded from iCloud.
struct PhotoLibraryScanner: Sendable {
    static var access: PhotoLibraryAccess {
        PhotoLibraryAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Asks for read-write access because moving items to Recently Deleted later requires it.
    static func requestAccess() async -> PhotoLibraryAccess {
        PhotoLibraryAccess(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    private static func fetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        return options
    }

    /// Cheap pass over every asset: index key and modification date, without touching resources.
    func fingerprints() throws -> [String: ScanFingerprint] {
        let assets = PHAsset.fetchAssets(with: Self.fetchOptions())
        var result: [String: ScanFingerprint] = [:]
        result.reserveCapacity(assets.count)
        var cancelled = false
        assets.enumerateObjects { asset, index, stop in
            if index % 1_000 == 0, Task.isCancelled {
                cancelled = true
                stop.pointee = true
                return
            }
            let key = MediaLocation.photoLibrary(localIdentifier: asset.localIdentifier).indexKey
            result[key] = Self.fingerprint(for: asset)
        }
        if cancelled { throw CancellationError() }
        return result
    }

    /// Full details, including resource sizes, for the given index keys.
    func details(forIndexKeys keys: [String]) -> [ScannedItem] {
        let identifiers = keys.compactMap { key -> String? in
            guard case let .photoLibrary(id)? = MediaLocation(indexKey: key) else { return nil }
            return id
        }
        guard !identifiers.isEmpty else { return [] }

        let options = Self.fetchOptions()
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: options)
        var items: [ScannedItem] = []
        items.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            if let item = Self.item(for: asset) {
                items.append(ScannedItem(item: item, fingerprint: Self.fingerprint(for: asset)))
            }
        }
        return items
    }

    private static func fingerprint(for asset: PHAsset) -> ScanFingerprint {
        ScanFingerprint(byteSize: nil, modificationDate: asset.modificationDate ?? asset.creationDate)
    }

    private static func item(for asset: PHAsset) -> MediaItem? {
        let kind: MediaKind
        switch asset.mediaType {
        case .image: kind = .photo
        case .video: kind = .video
        case .audio: kind = .audio
        default: return nil
        }

        let resources = PHAssetResource.assetResources(for: asset)
        let primary = resources.first { [.photo, .video, .audio].contains($0.type) } ?? resources.first

        return MediaItem(
            location: .photoLibrary(localIdentifier: asset.localIdentifier),
            kind: kind,
            byteSize: resources.reduce(0) { $0 + fileSize(of: $1) },
            filename: primary?.originalFilename,
            pixelWidth: asset.pixelWidth > 0 ? asset.pixelWidth : nil,
            pixelHeight: asset.pixelHeight > 0 ? asset.pixelHeight : nil,
            duration: asset.mediaType == .image ? nil : asset.duration,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            isFavorite: asset.isFavorite,
            isInSharedAlbum: asset.sourceType.contains(.typeCloudShared),
            isEdited: asset.hasAdjustments,
            hints: hints(for: asset)
        )
    }

    /// PhotoKit has no public size API; `fileSize` is the long-standing key-value accessor for it.
    private static func fileSize(of resource: PHAssetResource) -> Int64 {
        (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
    }

    private static func hints(for asset: PHAsset) -> Set<MediaSourceHint> {
        var hints: Set<MediaSourceHint> = []
        if asset.sourceType.contains(.typeUserLibrary) { hints.insert(.userLibrary) }
        if asset.sourceType.contains(.typeCloudShared) { hints.insert(.cloudShared) }
        if asset.sourceType.contains(.typeiTunesSynced) { hints.insert(.iTunesSynced) }

        let subtypes = asset.mediaSubtypes
        if subtypes.contains(.photoScreenshot) { hints.insert(.screenshot) }
        if subtypes.contains(.videoScreenRecording) { hints.insert(.screenRecording) }
        if subtypes.contains(.photoLive) { hints.insert(.livePhoto) }
        if subtypes.contains(.photoPanorama) { hints.insert(.panorama) }
        if subtypes.contains(.photoHDR) { hints.insert(.hdr) }
        if subtypes.contains(.photoDepthEffect) { hints.insert(.depthEffect) }
        if subtypes.contains(.videoHighFrameRate) { hints.insert(.highFrameRate) }
        if subtypes.contains(.videoTimelapse) { hints.insert(.timelapse) }
        if asset.burstIdentifier != nil { hints.insert(.burst) }
        return hints
    }
}
