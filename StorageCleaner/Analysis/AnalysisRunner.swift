import Foundation
import StorageCleanerCore

/// Shared loop for analysis passes: reads one signal per item (inside the item's folder security
/// scope), keeps the cached signatures up to date and records what could not be read. It only
/// reads media; iCloud Drive files that are not downloaded are only opened when `allowDownloads`.
struct AnalysisRunner {
    enum Source {
        case photo(String)
        case file(URL)
    }

    typealias Progress = @Sendable (_ step: String, _ done: Int, _ total: Int) async -> Void

    let store: MediaIndexStore
    let allowDownloads: Bool
    let items: [MediaItem]
    private(set) var signatures: [String: MediaSignatures]
    private(set) var cloudOnly = Set<String>()
    private(set) var failed = Set<String>()
    let folderAccess: FolderAccess

    static func load(store: MediaIndexStore, allowDownloads: Bool) async throws -> AnalysisRunner {
        let scoped = try await store.scopedItems()
        return AnalysisRunner(
            store: store,
            allowDownloads: allowDownloads,
            items: scoped.map(\.item),
            signatures: try await store.signatures(),
            folderAccess: try await FolderAccess.load(store: store, scoped: scoped)
        )
    }

    private init(store: MediaIndexStore, allowDownloads: Bool, items: [MediaItem], signatures: [String: MediaSignatures],
                 folderAccess: FolderAccess) {
        self.store = store
        self.allowDownloads = allowDownloads
        self.items = items
        self.signatures = signatures
        self.folderAccess = folderAccess
    }

    /// Items that were not counted as failed because their data is only in iCloud.
    func skippedCloudOnly(alsoSkipped: [MediaItem]) -> Set<String> {
        Set(alsoSkipped.map(\.location.indexKey)).union(cloudOnly)
    }

    mutating func process(
        _ pending: [MediaItem],
        step: String,
        progress: Progress,
        read: (Source, MediaItem, MediaSignatures) async throws -> MediaSignatures
    ) async throws {
        guard !pending.isEmpty else { return }
        var unsaved: [String: MediaSignatures] = [:]
        await progress(step, 0, pending.count)

        for (index, item) in pending.enumerated() {
            try Task.checkCancellation()
            let key = item.location.indexKey
            let current = signatures[key].flatMap { $0.isValid(for: item) ? $0 : nil } ?? MediaSignatures(for: item)
            do {
                let updated: MediaSignatures
                switch item.location {
                case let .photoLibrary(id):
                    updated = try await read(.photo(id), item, current)
                case let .file(url):
                    guard LocalFileGate.mayRead(url, allowDownloads: allowDownloads) else { throw AnalysisError.cloudOnly }
                    updated = try await folderAccess.withAccess(to: item) {
                        try await read(.file(url), item, current)
                    }
                }
                signatures[key] = updated
                unsaved[key] = updated
            } catch is CancellationError {
                try await store.saveSignatures(unsaved)
                throw CancellationError()
            } catch AnalysisError.cloudOnly {
                cloudOnly.insert(key)
            } catch {
                failed.insert(key)
            }

            if unsaved.count >= 200 {
                try await store.saveSignatures(unsaved)
                unsaved.removeAll()
            }
            if index % 10 == 0 { await progress(step, index, pending.count) }
        }
        try await store.saveSignatures(unsaved)
        await progress(step, pending.count, pending.count)
    }
}

/// The security scope of the picked folder each iCloud Drive item was scanned from. Reading a
/// file (analysis) or moving it to the Trash (`TrashService`) happens inside that scope; on macOS
/// the sandbox refuses both outside it.
struct FolderAccess: FileAccessScoping {
    private let scopeByKey: [String: IndexScope]
    private let folderURLs: [UUID: URL]

    init(scopeByKey: [String: IndexScope], folderURLs: [UUID: URL]) {
        self.scopeByKey = scopeByKey
        self.folderURLs = folderURLs
    }

    static func load(store: MediaIndexStore, scoped: [ScopedItem]? = nil) async throws -> FolderAccess {
        let items: [ScopedItem]
        if let scoped { items = scoped } else { items = try await store.scopedItems() }
        var folderURLs: [UUID: URL] = [:]
        for folder in try await store.folders() {
            if let resolved = try? SecurityScopedBookmark.resolve(folder.bookmark) {
                folderURLs[folder.id] = resolved.url
            }
        }
        return FolderAccess(
            scopeByKey: Dictionary(items.map { ($0.item.location.indexKey, $0.scope) }, uniquingKeysWith: { first, _ in first }),
            folderURLs: folderURLs
        )
    }

    private func folderURL(for item: MediaItem) -> URL? {
        guard case let .folder(id)? = scopeByKey[item.location.indexKey] else { return nil }
        return folderURLs[id]
    }

    func withAccess<T>(to item: MediaItem, _ body: () throws -> T) rethrows -> T {
        guard let url = folderURL(for: item) else { return try body() }
        return try SecurityScopedBookmark.withAccess(to: url, body)
    }

    func withAccess<T>(to item: MediaItem, _ body: () async throws -> T) async rethrows -> T {
        guard let url = folderURL(for: item) else { return try await body() }
        return try await SecurityScopedBookmark.withAccess(to: url, body)
    }
}
