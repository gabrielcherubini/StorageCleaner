import Foundation
import XCTest
@testable import StorageCleanerCore

final class MediaItemTests: XCTestCase {
    func testSortsHeaviestFirstThenOldest() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let items = [
            MediaItem.fixture("small", bytes: 10),
            MediaItem.fixture("bigNew", bytes: 500, created: newer),
            MediaItem.fixture("bigOld", bytes: 500, created: older),
            MediaItem.fixture("medium", bytes: 100),
        ]

        let ids = items.sortedBySizeDescending().map(\.location)

        XCTAssertEqual(ids, [
            .photoLibrary(localIdentifier: "bigOld"),
            .photoLibrary(localIdentifier: "bigNew"),
            .photoLibrary(localIdentifier: "medium"),
            .photoLibrary(localIdentifier: "small"),
        ])
    }

    func testTotalByteSize() {
        let items = [MediaItem.fixture("a", bytes: 3), .fixture("b", bytes: 4)]
        XCTAssertEqual(items.totalByteSize, 7)
        XCTAssertEqual([MediaItem]().totalByteSize, 0)
    }

    func testProtectedItems() {
        XCTAssertFalse(MediaItem.fixture("plain", bytes: 1).isProtected)
        XCTAssertTrue(MediaItem.fixture("fav", bytes: 1, favorite: true).isProtected)
        XCTAssertTrue(MediaItem.fixture("shared", bytes: 1, shared: true).isProtected)
        XCTAssertTrue(MediaItem.fixture("edited", bytes: 1, edited: true).isProtected)
    }

    func testPixelCount() {
        var item = MediaItem.fixture("p", bytes: 1)
        XCTAssertNil(item.pixelCount)
        item.pixelWidth = 4032
        item.pixelHeight = 3024
        XCTAssertEqual(item.pixelCount, 12_192_768)
    }

    func testCodableRoundTrip() throws {
        let items = [
            MediaItem.fixture("photo", bytes: 42, created: Date(timeIntervalSince1970: 0)),
            MediaItem(
                location: .file(URL(fileURLWithPath: "/tmp/Voice Memo.m4a")),
                kind: .audio,
                byteSize: 9,
                duration: 2.5
            ),
        ]
        let data = try JSONEncoder().encode(items)
        XCTAssertEqual(try JSONDecoder().decode([MediaItem].self, from: data), items)
    }
}

extension MediaItem {
    static func fixture(
        _ id: String,
        bytes: Int64,
        created: Date? = nil,
        favorite: Bool = false,
        shared: Bool = false,
        edited: Bool = false
    ) -> MediaItem {
        MediaItem(
            location: .photoLibrary(localIdentifier: id),
            kind: .photo,
            byteSize: bytes,
            creationDate: created,
            isFavorite: favorite,
            isInSharedAlbum: shared,
            isEdited: edited
        )
    }
}
