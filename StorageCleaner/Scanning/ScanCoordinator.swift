import Foundation
import Observation
import StorageCleanerCore
import SwiftData

/// Runs scans and publishes progress, the heaviest items and potential-savings totals to the UI.
@MainActor
@Observable
final class ScanCoordinator {
    struct Progress: Equatable {
        var source: String
        var done: Int
        var total: Int?
    }

    private(set) var progress: Progress?
    private(set) var summary: LibrarySummary = .empty
    private(set) var folders: [FolderRecord] = []
    private(set) var photoAccess: PhotoLibraryAccess = PhotoLibraryScanner.access
    private(set) var errors: [String] = []
    private(set) var lastScanDate: Date?

    @ObservationIgnored private let store: MediaIndexStore
    @ObservationIgnored private let updater: IndexUpdater
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastSummaryRefresh = Date.distantPast

    var isScanning: Bool { task != nil }

    init(container: ModelContainer) {
        store = MediaIndexStore(modelContainer: container)
        updater = IndexUpdater(store: store)
    }

    func load() async {
        folders = (try? await store.folders()) ?? []
        photoAccess = PhotoLibraryScanner.access
        await refreshSummary()
    }

    // MARK: Actions

    func scanEverything() {
        start { coordinator in
            try await coordinator.scanPhotos()
            for folder in coordinator.folders {
                try await coordinator.scanFolderRecordingErrors(folder)
            }
        }
    }

    func scanPhotosOnly() {
        start { try await $0.scanPhotos() }
    }

    func scan(folder: FolderRecord) {
        start { try await $0.scanFolderRecordingErrors(folder) }
    }

    func cancel() {
        task?.cancel()
    }

    func requestPhotoAccess() async {
        photoAccess = await PhotoLibraryScanner.requestAccess()
    }

    /// Adds a folder returned by the folder picker and scans it.
    func addFolder(at url: URL) async {
        do {
            let path = url.standardizedFileURL.path
            let alreadyAdded = folders.contains { folder in
                (try? SecurityScopedBookmark.resolve(folder.bookmark))?.url.standardizedFileURL.path == path
            }
            guard !alreadyAdded else { return }

            let bookmark = try SecurityScopedBookmark.make(for: url)
            let record = try await store.addFolder(displayName: url.lastPathComponent, bookmark: bookmark)
            folders.append(record)
            scan(folder: record)
        } catch {
            errors.append("Couldn't add “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }
    }

    /// Stops tracking a folder and drops its rows from the index. Files are not touched.
    func forget(folder: FolderRecord) async {
        guard !isScanning else { return }
        do {
            try await store.forgetFolder(id: folder.id)
            folders.removeAll { $0.id == folder.id }
            await refreshSummary()
        } catch {
            errors.append(error.localizedDescription)
        }
    }

    func dismissErrors() {
        errors.removeAll()
    }

    // MARK: Scanning

    private func start(_ work: @escaping @MainActor (ScanCoordinator) async throws -> Void) {
        guard task == nil else { return }
        errors.removeAll()
        task = Task {
            do {
                try await work(self)
                lastScanDate = Date()
            } catch is CancellationError {
            } catch {
                errors.append(error.localizedDescription)
            }
            progress = nil
            task = nil
            await refreshSummary()
        }
    }

    private func scanPhotos() async throws {
        if photoAccess == .notDetermined {
            photoAccess = await PhotoLibraryScanner.requestAccess()
        }
        guard photoAccess.canScan else { return }

        let source = "Photos"
        progress = Progress(source: source, done: 0, total: nil)
        let current = try await Self.photoFingerprints()
        try await updater.apply(
            current: current,
            to: .photoLibrary,
            details: { keys in await Self.photoDetails(keys) },
            progress: { done, total in await self.report(source: source, done: done, total: total) }
        )
    }

    private func scanFolderRecordingErrors(_ folder: FolderRecord) async throws {
        do {
            try await scanFolder(folder)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            errors.append(error.localizedDescription)
        }
    }

    private func scanFolder(_ folder: FolderRecord) async throws {
        let source = folder.displayName
        progress = Progress(source: source, done: 0, total: nil)
        let result = try await Self.scanFiles(in: folder) { found in
            Task { @MainActor in await self.report(source: source, done: found, total: nil, refreshSummary: false) }
        }
        if let bookmark = result.refreshedBookmark {
            try await store.updateFolder(id: folder.id, bookmark: bookmark)
        }
        try await updater.apply(
            scanned: result.items,
            to: .folder(folder.id),
            progress: { done, total in await self.report(source: source, done: done, total: total) }
        )
        try await store.updateFolder(id: folder.id, lastScannedAt: Date())
        folders = (try? await store.folders()) ?? folders
    }

    private func report(source: String, done: Int, total: Int?, refreshSummary: Bool = true) async {
        guard task != nil, progress?.source == source else { return }
        progress = Progress(source: source, done: done, total: total)
        if refreshSummary, Date().timeIntervalSince(lastSummaryRefresh) > 1 {
            await self.refreshSummary()
        }
    }

    private func refreshSummary() async {
        lastSummaryRefresh = Date()
        if let summary = try? await store.summary() {
            self.summary = summary
        }
    }

    // Blocking PhotoKit and file-system work runs off the main actor and inherits cancellation.

    nonisolated private static func photoFingerprints() async throws -> [String: ScanFingerprint] {
        try PhotoLibraryScanner().fingerprints()
    }

    nonisolated private static func photoDetails(_ keys: [String]) async -> [ScannedItem] {
        PhotoLibraryScanner().details(forIndexKeys: keys)
    }

    nonisolated private static func scanFiles(
        in folder: FolderRecord,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> FolderScanner.Result {
        try FolderScanner().scan(folder, progress: progress)
    }
}
