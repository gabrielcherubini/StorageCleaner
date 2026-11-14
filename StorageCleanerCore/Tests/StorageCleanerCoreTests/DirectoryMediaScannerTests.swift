import Foundation
import XCTest
@testable import StorageCleanerCore

// Fixture folders are left in the temporary directory for the OS to clean up: the safety guard
// bans file-removal APIs in every source file, tests included.
final class DirectoryMediaScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectoryMediaScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func write(_ relativePath: String, bytes: Int) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    private func filenames(_ files: [ScannedItem]) -> [String] {
        files.compactMap(\.item.filename).sorted()
    }

    func testFindsMediaByExtensionWithSizes() throws {
        try write("a.jpg", bytes: 300)
        try write("Trip/clip.MOV", bytes: 2_000)
        try write("Trip/Audio/memo.m4a", bytes: 50)
        try write("notes.txt", bytes: 10)
        try write("report.pdf", bytes: 10)

        let files = DirectoryMediaScanner().scanAll(root: root)

        XCTAssertEqual(filenames(files), ["a.jpg", "clip.MOV", "memo.m4a"])
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.item.filename!, $0) })
        XCTAssertEqual(byName["clip.MOV"]?.item.kind, .video)
        XCTAssertEqual(byName["clip.MOV"]?.item.byteSize, 2_000)
        XCTAssertEqual(byName["clip.MOV"]?.fingerprint.byteSize, 2_000)
        XCTAssertNotNil(byName["clip.MOV"]?.fingerprint.modificationDate)
        XCTAssertEqual(byName["memo.m4a"]?.item.kind, .audio)
        XCTAssertEqual(byName["a.jpg"]?.item.isLocallyAvailable, true)
    }

    func testSkipsHiddenFilesAndFolders() throws {
        try write(".DS_Store", bytes: 10)
        try write(".hidden.jpg", bytes: 10)
        try write(".cache/thumb.jpg", bytes: 10)
        try write("visible.png", bytes: 10)

        XCTAssertEqual(filenames(DirectoryMediaScanner().scanAll(root: root)), ["visible.png"])
    }

    func testICloudPlaceholderReportsRealNameAndSize() throws {
        let plist: [String: Any] = ["NSURLNameKey": "IMG_0001.HEIC", "NSURLFileSizeKey": 4_200_000]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: root.appendingPathComponent(".IMG_0001.HEIC.icloud"))

        let files = DirectoryMediaScanner().scanAll(root: root)

        XCTAssertEqual(files.count, 1)
        let item = try XCTUnwrap(files.first?.item)
        XCTAssertEqual(item.filename, "IMG_0001.HEIC")
        XCTAssertEqual(item.kind, .photo)
        XCTAssertEqual(item.byteSize, 4_200_000)
        XCTAssertEqual(item.isLocallyAvailable, false)
        XCTAssertEqual(item.hints, [.iCloudPlaceholder])
        guard case let .file(url) = item.location else { return XCTFail("expected a file location") }
        XCTAssertEqual(url.lastPathComponent, ".IMG_0001.HEIC.icloud")
    }

    func testPlaceholderNameParsing() {
        XCTAssertEqual(ICloudPlaceholder.realName(forPlaceholderName: ".clip.mov.icloud"), "clip.mov")
        XCTAssertNil(ICloudPlaceholder.realName(forPlaceholderName: "clip.mov.icloud"))
        XCTAssertNil(ICloudPlaceholder.realName(forPlaceholderName: ".icloud"))
        XCTAssertNil(ICloudPlaceholder.realName(forPlaceholderName: ".clip.mov"))
    }

    func testThrowingFromBodyStopsTheWalk() throws {
        for i in 0..<5 { try write("p\(i).jpg", bytes: 1) }
        struct Stop: Error {}
        var seen = 0
        XCTAssertThrowsError(try DirectoryMediaScanner().scan(root: root) { _ in
            seen += 1
            if seen == 2 { throw Stop() }
        })
        XCTAssertEqual(seen, 2)
    }

    func testDoesNotModifyScannedFiles() throws {
        try write("keep.jpg", bytes: 123)
        let url = root.appendingPathComponent("keep.jpg")
        let before = try FileManager.default.attributesOfItem(atPath: url.path)

        _ = DirectoryMediaScanner().scanAll(root: root)

        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(before[.size] as? Int, after[.size] as? Int)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(try Data(contentsOf: url), Data(repeating: 0xAB, count: 123))
    }

    func testRescanFeedsReconciler() throws {
        try write("a.jpg", bytes: 10)
        try write("b.jpg", bytes: 10)
        let first = DirectoryMediaScanner().scanAll(root: root)
        let existing = Dictionary(uniqueKeysWithValues: first.map { ($0.indexKey, $0.fingerprint) })

        try write("c.jpg", bytes: 10)
        try write("b.jpg", bytes: 99)
        let second = DirectoryMediaScanner().scanAll(root: root)
        let current = Dictionary(uniqueKeysWithValues: second.map { ($0.indexKey, $0.fingerprint) })

        let plan = IndexReconciler.plan(existing: existing, current: current)
        let names = { (keys: [String]) in keys.compactMap { MediaLocation(indexKey: $0) }.map { location -> String in
            guard case let .file(url) = location else { return "" }
            return url.lastPathComponent
        } }
        XCTAssertEqual(names(plan.added), ["c.jpg"])
        XCTAssertEqual(names(plan.changed), ["b.jpg"])
        XCTAssertEqual(names(plan.unchanged), ["a.jpg"])
    }
}
