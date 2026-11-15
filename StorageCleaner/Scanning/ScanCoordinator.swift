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
        var detail: String?
    }

    private static let allowDownloadsKey = "allowICloudDownloadsForAnalysis"
    private static let decisionLogKey = "keepDecisionLog"
    private static let reviewPreferencesKey = "reviewPreferences"

    private(set) var progress: Progress?
    private(set) var summary: LibrarySummary = .empty
    private(set) var folders: [FolderRecord] = []
    private(set) var photoAccess: PhotoLibraryAccess = PhotoLibraryScanner.access
    private(set) var errors: [String] = []
    private(set) var lastScanDate: Date?
    /// Results of the last duplicate analysis; cleared when a rescan may have changed the library.
    private(set) var duplicates: DuplicateAnalyzer.Report?
    /// Results of the last category analysis; cleared like `duplicates`.
    private(set) var classifications: ClassificationAnalyzer.Report?

    /// Off by default: analysis then skips anything whose data is only in iCloud.
    private(set) var allowICloudDownloads: Bool = UserDefaults.standard.bool(forKey: ScanCoordinator.allowDownloadsKey)

    func setAllowICloudDownloads(_ allowed: Bool) {
        allowICloudDownloads = allowed
        UserDefaults.standard.set(allowed, forKey: Self.allowDownloadsKey)
    }

    /// Off by default: when on, each confirmed trash action is appended to a local JSON file.
    private(set) var keepsDecisionLog: Bool = UserDefaults.standard.bool(forKey: ScanCoordinator.decisionLogKey)

    func setKeepsDecisionLog(_ enabled: Bool) {
        keepsDecisionLog = enabled
        UserDefaults.standard.set(enabled, forKey: Self.decisionLogKey)
    }

    /// Strictness, pre-selection and rules for the category reviews.
    private(set) var reviewPreferences: ReviewPreferences = ScanCoordinator.storedReviewPreferences()

    func setReviewPreferences(_ preferences: ReviewPreferences) {
        guard preferences != reviewPreferences else { return }
        reviewPreferences = preferences
        UserDefaults.standard.set(try? JSONEncoder().encode(preferences), forKey: Self.reviewPreferencesKey)
        if var report = classifications {
            report.reviews = report.outcome.reviews(preferences: preferences)
            classifications = report
            Task { await refreshSummary() }
        }
    }

    private static func storedReviewPreferences() -> ReviewPreferences {
        UserDefaults.standard.data(forKey: reviewPreferencesKey)
            .flatMap { try? JSONDecoder().decode(ReviewPreferences.self, from: $0) } ?? .default
    }

    @ObservationIgnored let store: MediaIndexStore
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
        start(invalidatesDuplicates: true) { coordinator in
            try await coordinator.scanPhotos()
            for folder in coordinator.folders {
                try await coordinator.scanFolderRecordingErrors(folder)
            }
        }
    }

    func scanPhotosOnly() {
        start(invalidatesDuplicates: true) { try await $0.scanPhotos() }
    }

    func scan(folder: FolderRecord) {
        start(invalidatesDuplicates: true) { try await $0.scanFolderRecordingErrors(folder) }
    }

    func findDuplicates() {
        start { try await $0.runDuplicateAnalysis() }
    }

    func analyzeCategories() {
        start { try await $0.runClassification() }
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
            duplicates = nil
            classifications = nil
            await refreshSummary()
        } catch {
            errors.append(error.localizedDescription)
        }
    }

    func dismissErrors() {
        errors.removeAll()
    }

    func report(error message: String) {
        errors.append(message)
    }

    /// Items over the large-file threshold, heaviest first.
    func largeFiles() async -> [MediaItem] {
        (try? await store.largeItems(minimumBytes: LibrarySummary.defaultLargeFileThreshold)) ?? []
    }

    /// The heaviest indexed items, for the "Heaviest items" review screen.
    func heaviestItems(limit: Int = 500) async -> [MediaItem] {
        (try? await store.heaviestItems(limit: limit)) ?? []
    }

    #if DEBUG
    /// Sample results for screenshots and previews (`-demo` launch argument).
    func showDemoResults(duplicates: DuplicateAnalyzer.Report, classifications: ClassificationAnalyzer.Report) async {
        self.duplicates = duplicates
        self.classifications = classifications
        photoAccess = .full
        await refreshSummary()
    }
    #endif

    /// Drops items that were moved to Recently Deleted / Trash from the current results. Their
    /// index rows are already gone; the next scan confirms it.
    func removeTrashed(_ locations: Set<MediaLocation>) async {
        guard !locations.isEmpty else { return }
        duplicates?.groups = duplicates?.groups.compactMap { $0.removing(locations) } ?? []
        if var report = classifications {
            report.outcome = report.outcome.removing(locations)
            report.reviews = report.reviews.compactMap { $0.removing(locations) }
            classifications = report
        }
        await refreshSummary()
    }

    // MARK: Scanning

    private func start(
        invalidatesDuplicates: Bool = false,
        _ work: @escaping @MainActor (ScanCoordinator) async throws -> Void
    ) {
        guard task == nil else { return }
        errors.removeAll()
        if invalidatesDuplicates {
            duplicates = nil
            classifications = nil
        }
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

    private func runDuplicateAnalysis() async throws {
        let source = "Duplicates"
        progress = Progress(source: source, done: 0, total: nil)
        let analyzer = DuplicateAnalyzer(store: store, allowDownloads: allowICloudDownloads)
        duplicates = try await analyzer.run { step, done, total in
            await self.report(source: source, done: done, total: total, detail: step, refreshSummary: false)
        }
    }

    private func runClassification() async throws {
        let source = "Categories"
        progress = Progress(source: source, done: 0, total: nil)
        let analyzer = ClassificationAnalyzer(store: store, allowDownloads: allowICloudDownloads,
                                              preferences: reviewPreferences)
        classifications = try await analyzer.run { step, done, total in
            await self.report(source: source, done: done, total: total, detail: step, refreshSummary: false)
        }
    }

    private func report(source: String, done: Int, total: Int?, detail: String? = nil, refreshSummary: Bool = true) async {
        guard task != nil, progress?.source == source else { return }
        progress = Progress(source: source, done: done, total: total, detail: detail)
        if refreshSummary, Date().timeIntervalSince(lastSummaryRefresh) > 1 {
            await self.refreshSummary()
        }
    }

    private func refreshSummary() async {
        lastSummaryRefresh = Date()
        if var summary = try? await store.summary() {
            if let duplicates {
                summary.addSavings(duplicates.groups.flatMap(\.suggestedForRemoval), to: .duplicates)
            }
            for review in classifications?.reviews ?? [] {
                summary.addSavings(review.likelyToDelete.map(\.item), to: review.category)
            }
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
