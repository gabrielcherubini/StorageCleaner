import Foundation
import StorageCleanerCore

/// Scans a bookmarked folder (normally iCloud Drive) with read-only access to listings and metadata.
struct FolderScanner: Sendable {
    struct Result: Sendable {
        let items: [ScannedItem]
        /// A refreshed bookmark to persist when the stored one went stale.
        let refreshedBookmark: Data?
    }

    enum Failure: LocalizedError {
        case unreachable(String)

        var errorDescription: String? {
            switch self {
            case let .unreachable(name):
                return "Can't open “\(name)”. Pick the folder again to restore access."
            }
        }
    }

    func scan(_ folder: FolderRecord, progress: @Sendable (Int) -> Void = { _ in }) throws -> Result {
        let resolved: SecurityScopedBookmark.Resolved
        do {
            resolved = try SecurityScopedBookmark.resolve(folder.bookmark)
        } catch {
            throw Failure.unreachable(folder.displayName)
        }

        return try SecurityScopedBookmark.withAccess(to: resolved.url) {
            guard (try? resolved.url.checkResourceIsReachable()) == true else {
                throw Failure.unreachable(folder.displayName)
            }
            var refreshed: Data?
            if resolved.isStale {
                refreshed = try? SecurityScopedBookmark.make(for: resolved.url)
            }

            var items: [ScannedItem] = []
            try DirectoryMediaScanner().scan(root: resolved.url) { item in
                items.append(item)
                if items.count % 500 == 0 {
                    try Task.checkCancellation()
                    progress(items.count)
                }
            }
            progress(items.count)
            return Result(items: items, refreshedBookmark: refreshed)
        }
    }
}
