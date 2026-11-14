import Foundation
import StorageCleanerCore
import SwiftData
import XCTest
@testable import StorageCleaner

final class MediaIndexTests: XCTestCase {
    private var store: MediaIndexStore!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        store = MediaIndexStore(modelContainer: try IndexSchema.makeContainer(inMemory: true))
    }

    private func photo(_ id: String, bytes: Int64, modified: Date, favorite: Bool = false) -> ScannedItem {
        ScannedItem(
            item: MediaItem(
                location: .photoLibrary(localIdentifier: id),
                kind: .photo,
                byteSize: bytes,
                modificationDate: modified,
                isFavorite: favorite
            ),
            fingerprint: ScanFingerprint(modificationDate: modified)
        )
    }

    private func key(_ id: String) -> String {
        MediaLocation.photoLibrary(localIdentifier: id).indexKey
    }

    func testUpsertAndSummaryHeaviestFirst() async throws {
        try await store.upsert([
            photo("a", bytes: 10, modified: t0),
            photo("b", bytes: 300_000_000, modified: t0),
            photo("c", bytes: 2_000, modified: t0, favorite: true),
        ], in: .photoLibrary)

        let summary = try await store.summary()

        XCTAssertEqual(summary.itemCount, 3)
        XCTAssertEqual(summary.totalBytes, 300_002_010)
        XCTAssertEqual(summary.heaviest.map(\.location.indexKey), [key("b"), key("c"), key("a")])
        XCTAssertEqual(summary.potentialSavings.bytes(in: .largeFiles), 300_000_000)
        let favorite = try await store.item(forKey: key("c"))
        XCTAssertEqual(favorite?.isFavorite, true)
    }

    func testIncrementalRescanOnlyRereadsNewAndChangedItems() async throws {
        let updater = IndexUpdater(store: store, batchSize: 2)
        let first: [String: ScannedItem] = [
            key("keep"): photo("keep", bytes: 1, modified: t0),
            key("edit"): photo("edit", bytes: 2, modified: t0),
            key("gone"): photo("gone", bytes: 3, modified: t0),
        ]
        try await updater.apply(scanned: Array(first.values), to: .photoLibrary)

        let requested = Recorder()
        let later = t0.addingTimeInterval(60)
        let second: [String: ScannedItem] = [
            key("keep"): photo("keep", bytes: 1, modified: t0),
            key("edit"): photo("edit", bytes: 20, modified: later),
            key("new"): photo("new", bytes: 4, modified: t0),
        ]
        let plan = try await updater.apply(
            current: second.mapValues(\.fingerprint),
            to: .photoLibrary,
            details: { keys in
                await requested.append(keys)
                return keys.compactMap { second[$0] }
            }
        )

        let requestedKeys = await requested.all.sorted()
        XCTAssertEqual(requestedKeys, [key("edit"), key("new")])
        XCTAssertEqual(plan.removed, [key("gone")])
        let summary = try await store.summary()
        XCTAssertEqual(summary.itemCount, 3)
        XCTAssertEqual(summary.totalBytes, 1 + 20 + 4)
        let gone = try await store.item(forKey: key("gone"))
        XCTAssertNil(gone)
    }

    func testScopesAreIsolated() async throws {
        let updater = IndexUpdater(store: store)
        try await updater.apply(scanned: [photo("p", bytes: 5, modified: t0)], to: .photoLibrary)

        let folderID = UUID()
        let file = ScannedItem(
            item: MediaItem(location: .file(URL(fileURLWithPath: "/drive/clip.mov")), kind: .video, byteSize: 7),
            fingerprint: ScanFingerprint(byteSize: 7, modificationDate: t0)
        )
        try await updater.apply(scanned: [file], to: .folder(folderID))
        try await updater.apply(scanned: [], to: .folder(folderID))

        let count = try await store.itemCount()
        XCTAssertEqual(count, 1)
        let photoRow = try await store.item(forKey: key("p"))
        XCTAssertNotNil(photoRow)
    }

    func testForgetFolderDropsOnlyItsRows() async throws {
        let folder = try await store.addFolder(displayName: "iCloud Drive", bookmark: Data([1, 2, 3]))
        let file = ScannedItem(
            item: MediaItem(location: .file(URL(fileURLWithPath: "/drive/a.jpg")), kind: .photo, byteSize: 1),
            fingerprint: ScanFingerprint(byteSize: 1)
        )
        try await store.upsert([file], in: .folder(folder.id))
        try await store.upsert([photo("p", bytes: 2, modified: t0)], in: .photoLibrary)

        try await store.forgetFolder(id: folder.id)

        let folders = try await store.folders()
        let count = try await store.itemCount()
        XCTAssertTrue(folders.isEmpty)
        XCTAssertEqual(count, 1)
    }

    func testFolderScanThroughBookmark() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderScanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(count: 1_234).write(to: root.appendingPathComponent("clip.mov"))
        try Data(count: 10).write(to: root.appendingPathComponent("notes.txt"))

        let bookmark = try SecurityScopedBookmark.make(for: root)
        let folder = try await store.addFolder(displayName: root.lastPathComponent, bookmark: bookmark)
        let result = try FolderScanner().scan(folder)

        XCTAssertEqual(result.items.map(\.item.filename), ["clip.mov"])
        XCTAssertEqual(result.items.first?.item.byteSize, 1_234)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("clip.mov").path))
    }
}

private actor Recorder {
    private(set) var all: [String] = []

    func append(_ keys: [String]) {
        all += keys
    }
}
