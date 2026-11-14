import Foundation
import StorageCleanerCore
import XCTest
@testable import StorageCleaner

// Fixture folders are left in the temporary directory for the OS to clean up: the safety guard
// bans file-removal APIs in every source file, tests included.
@MainActor
final class TrashCoordinatorTests: XCTestCase {
    private var root: URL!
    private var scanner: ScanCoordinator!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scanner = ScanCoordinator(container: try IndexSchema.makeContainer(inMemory: true))
    }

    private func indexFolder(files names: [String]) async throws -> [MediaItem] {
        for (index, name) in names.enumerated() {
            try Data(repeating: UInt8(index), count: 1_000 * (index + 1)).write(to: root.appendingPathComponent(name))
        }
        let store = scanner.store
        let folder = try await store.addFolder(displayName: root.lastPathComponent,
                                               bookmark: try SecurityScopedBookmark.make(for: root))
        let result = try FolderScanner().scan(folder)
        try await IndexUpdater(store: store).apply(scanned: result.items, to: .folder(folder.id))
        return result.items.map(\.item).sorted { ($0.filename ?? "") < ($1.filename ?? "") }
    }

    func testMovesConfirmedFilesDropsThemFromTheIndexAndLogsDecisions() async throws {
        let items = try await indexFolder(files: ["a.mov", "b.mov", "c.mov"])
        let files = FakeFiles()
        let log = DecisionLogStore(url: root.appendingPathComponent("log/decision-log.json"))
        let trash = TrashCoordinator(scanner: scanner,
                                     service: TrashService(photoLibrary: FakePhotoLibrary(), files: files),
                                     log: log)
        scanner.setKeepsDecisionLog(true)
        defer { scanner.setKeepsDecisionLog(false) }

        let plan = TrashPlan(items: [items[0], items[2]])
        let reasons = [items[0].location: DecisionReason.largeFile]
        let result = await trash.moveToTrash(plan, confirmation: plan.summary, reasons: reasons)
        let outcome = try XCTUnwrap(result)

        XCTAssertEqual(outcome.result.moved.map(\.item), [items[0], items[2]])
        XCTAssertEqual(outcome.trashCount, 2)
        XCTAssertEqual(files.trashed.map(\.lastPathComponent), ["a.mov", "c.mov"])
        let remaining = try await scanner.store.scopedItems().map(\.item.filename)
        XCTAssertEqual(remaining, ["b.mov"])

        let entries = try log.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].confirmedCount, 2)
        XCTAssertEqual(entries[0].items.map(\.destination), [.trash, .trash])
        XCTAssertEqual(entries[0].items.first?.reason, .largeFile)
        XCTAssertEqual(outcome.logURL, log.url)
    }

    func testMismatchedConfirmationMovesNothing() async throws {
        let items = try await indexFolder(files: ["a.mov", "b.mov"])
        let files = FakeFiles()
        let trash = TrashCoordinator(scanner: scanner,
                                     service: TrashService(photoLibrary: FakePhotoLibrary(), files: files),
                                     log: DecisionLogStore(url: root.appendingPathComponent("log.json")))
        let plan = TrashPlan(items: items)
        let stale = TrashConfirmation(acknowledgedItemCount: 1, acknowledgedTotalBytes: items[0].byteSize)

        let outcome = await trash.moveToTrash(plan, confirmation: stale, reasons: [:])

        XCTAssertNil(outcome)
        XCTAssertTrue(files.trashed.isEmpty)
        let count = try await scanner.store.itemCount()
        XCTAssertEqual(count, 2)
        XCTAssertFalse(scanner.errors.isEmpty)
    }

    func testDecisionLogIsOffByDefault() async throws {
        let items = try await indexFolder(files: ["a.mov"])
        let log = DecisionLogStore(url: root.appendingPathComponent("off/decision-log.json"))
        scanner.setKeepsDecisionLog(false)
        let trash = TrashCoordinator(scanner: scanner,
                                     service: TrashService(photoLibrary: FakePhotoLibrary(), files: FakeFiles()),
                                     log: log)
        let plan = TrashPlan(items: items)

        let outcome = await trash.moveToTrash(plan, confirmation: plan.summary, reasons: [:])

        XCTAssertNil(outcome?.logURL)
        XCTAssertEqual(try log.entries(), [])
    }

    func testFolderAccessCoversIndexedFiles() async throws {
        let items = try await indexFolder(files: ["a.mov"])
        let access = try await FolderAccess.load(store: scanner.store)
        var ran = false
        await access.withAccess(to: items[0]) { ran = true }
        XCTAssertTrue(ran)
    }
}
