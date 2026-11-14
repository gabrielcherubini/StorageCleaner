import Foundation
import XCTest
@testable import StorageCleanerCore

final class LibrarySummaryTests: XCTestCase {
    private let mb: Int64 = 1_000_000

    func testTotalsByKindAndHeaviestFirst() {
        let items = [
            MediaItem.fixture("p1", bytes: 3 * mb),
            MediaItem(location: .photoLibrary(localIdentifier: "v1"), kind: .video, byteSize: 400 * mb),
            MediaItem(location: .photoLibrary(localIdentifier: "a1"), kind: .audio, byteSize: 1 * mb),
            MediaItem.fixture("p2", bytes: 5 * mb),
        ]

        let summary = LibrarySummary(items: items, heaviestLimit: 2)

        XCTAssertEqual(summary.itemCount, 4)
        XCTAssertEqual(summary.totalBytes, 409 * mb)
        XCTAssertEqual(summary.count(of: .photo), 2)
        XCTAssertEqual(summary.bytes(of: .photo), 8 * mb)
        XCTAssertEqual(summary.bytes(of: .video), 400 * mb)
        XCTAssertEqual(summary.heaviest.map(\.location.indexKey), ["photo:v1", "photo:p2"])
    }

    func testLargeFilesCountTowardSavingsButProtectedNeverDo() {
        let items = [
            MediaItem.fixture("big", bytes: 80 * mb),
            MediaItem.fixture("bigFavorite", bytes: 90 * mb, favorite: true),
            MediaItem.fixture("small", bytes: 2 * mb),
        ]

        let savings = LibrarySummary(items: items).potentialSavings

        XCTAssertEqual(savings.bytes(in: .largeFiles), 80 * mb)
        XCTAssertEqual(savings.count(in: .largeFiles), 1)
        XCTAssertEqual(savings.totalBytes, 80 * mb)
    }

    func testTallyCountsAnItemOnceAcrossCategories() {
        var tally = SavingsTally()
        let entry = SummaryEntry(key: "x", kind: .video, byteSize: 100, isProtected: false)

        XCTAssertTrue(tally.add(entry, to: .largeFiles))
        XCTAssertTrue(tally.add(entry, to: .duplicates))
        XCTAssertFalse(tally.add(entry, to: .duplicates))

        XCTAssertEqual(tally.bytes(in: .largeFiles), 100)
        XCTAssertEqual(tally.bytes(in: .duplicates), 100)
        XCTAssertEqual(tally.totalBytes, 100)
        XCTAssertEqual(tally.totalCount, 1)
    }

    func testTallyIgnoresProtected() {
        var tally = SavingsTally()
        XCTAssertFalse(tally.add(.init(key: "f", kind: .photo, byteSize: 5, isProtected: true), to: .screenshots))
        XCTAssertEqual(tally.totalBytes, 0)
    }

    func testAddingDuplicateSavingsCountsOverlapOnce() {
        let big = MediaItem.fixture("big", bytes: 80 * mb)
        let copy = MediaItem.fixture("copy", bytes: 3 * mb)
        var summary = LibrarySummary(items: [big, copy])

        summary.addSavings([big, copy], to: .duplicates)

        XCTAssertEqual(summary.potentialSavings.bytes(in: .duplicates), 83 * mb)
        XCTAssertEqual(summary.potentialSavings.totalBytes, 83 * mb)
    }

    func testEmpty() {
        XCTAssertEqual(LibrarySummary.empty.itemCount, 0)
        XCTAssertEqual(LibrarySummary.empty.potentialSavings.totalBytes, 0)
        XCTAssertTrue(LibrarySummary.empty.heaviest.isEmpty)
    }
}
