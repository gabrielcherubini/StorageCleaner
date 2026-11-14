import Foundation
import Photos
import StorageCleanerCore

/// The only place in the app allowed to remove user media.
///
/// It can only *move* items: photos go to Recently Deleted (kept 30 days, and the OS shows its own
/// confirmation dialog) and files go to the Trash. It never deletes permanently, and it only accepts
/// a `ConfirmedTrashPlan`, which can only be produced after the user confirms the count and size.
/// `scripts/check-no-permanent-delete.sh` enforces in CI that no other file touches these APIs.
final class TrashService: Sendable {
    private let photoLibrary: any PhotoLibraryTrashing
    private let files: any FileTrashing

    init(
        photoLibrary: any PhotoLibraryTrashing = SystemPhotoLibraryTrasher(),
        files: any FileTrashing = SystemFileTrasher()
    ) {
        self.photoLibrary = photoLibrary
        self.files = files
    }

    func moveToTrash(_ confirmed: ConfirmedTrashPlan) async -> TrashResult {
        var result = TrashResult()
        let plan = confirmed.plan

        let photoItems = plan.photoLibraryItems
        if !photoItems.isEmpty {
            let identifiers = photoItems.compactMap(\.photoLibraryIdentifier)
            do {
                let missing = try await photoLibrary.moveToRecentlyDeleted(localIdentifiers: identifiers)
                for item in photoItems {
                    if let id = item.photoLibraryIdentifier, missing.contains(id) {
                        result.failures.append(.init(item: item, reason: .notFound))
                    } else {
                        result.moved.append(.init(item: item, destination: .recentlyDeleted))
                    }
                }
            } catch {
                result.failures += photoItems.map { .init(item: $0, reason: .systemError(String(describing: error))) }
            }
        }

        for item in plan.fileItems {
            guard case let .file(url) = item.location else { continue }
            do {
                let trashedURL = try files.moveToTrash(url)
                result.moved.append(.init(item: item, destination: .trash(trashedURL)))
            } catch {
                result.failures.append(.init(item: item, reason: .systemError(String(describing: error))))
            }
        }

        return result
    }
}

struct TrashResult: Sendable {
    enum Destination: Equatable, Sendable {
        case recentlyDeleted
        case trash(URL?)
    }

    enum FailureReason: Equatable, Sendable {
        case notFound
        case systemError(String)
    }

    struct Moved: Sendable {
        let item: MediaItem
        let destination: Destination
    }

    struct Failure: Sendable {
        let item: MediaItem
        let reason: FailureReason
    }

    var moved: [Moved] = []
    var failures: [Failure] = []

    var movedBytes: Int64 { moved.map(\.item).totalByteSize }
}

protocol PhotoLibraryTrashing: Sendable {
    /// Moves the assets to Recently Deleted. Returns identifiers that no longer exist in the library.
    /// Throws if the user declines the system confirmation or the change fails.
    func moveToRecentlyDeleted(localIdentifiers: [String]) async throws -> Set<String>
}

protocol FileTrashing: Sendable {
    /// Moves the file to the Trash and returns its new location when the system reports one.
    func moveToTrash(_ url: URL) throws -> URL?
}

struct SystemPhotoLibraryTrasher: PhotoLibraryTrashing {
    func moveToRecentlyDeleted(localIdentifiers: [String]) async throws -> Set<String> {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var found = Set<String>()
        assets.enumerateObjects { asset, _, _ in found.insert(asset.localIdentifier) }
        let missing = Set(localIdentifiers).subtracting(found)
        guard !found.isEmpty else { return missing }

        let existing = Array(found)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: existing, options: nil))
        }
        return missing
    }
}

struct SystemFileTrasher: FileTrashing {
    func moveToTrash(_ url: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }
}

private extension MediaItem {
    var photoLibraryIdentifier: String? {
        if case let .photoLibrary(localIdentifier) = location { return localIdentifier }
        return nil
    }
}
