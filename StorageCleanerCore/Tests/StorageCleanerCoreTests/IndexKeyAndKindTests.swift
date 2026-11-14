import Foundation
import XCTest
@testable import StorageCleanerCore

final class IndexKeyAndKindTests: XCTestCase {
    func testIndexKeyRoundTrip() {
        let locations: [MediaLocation] = [
            .photoLibrary(localIdentifier: "ABC-123/L0/001"),
            .file(URL(fileURLWithPath: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Trip/clip 1.mov")),
        ]
        for location in locations {
            XCTAssertEqual(MediaLocation(indexKey: location.indexKey), location)
        }
    }

    func testIndexKeyIsStandardized() {
        let a = MediaLocation.file(URL(fileURLWithPath: "/tmp/x/../y/a.jpg"))
        let b = MediaLocation.file(URL(fileURLWithPath: "/tmp/y/a.jpg"))
        XCTAssertEqual(a.indexKey, b.indexKey)
    }

    func testInvalidIndexKeys() {
        XCTAssertNil(MediaLocation(indexKey: "photo:"))
        XCTAssertNil(MediaLocation(indexKey: "file:relative/path"))
        XCTAssertNil(MediaLocation(indexKey: "gdrive:123"))
    }

    func testKindFromExtension() {
        XCTAssertEqual(MediaKind(fileExtension: "HEIC"), .photo)
        XCTAssertEqual(MediaKind(fileExtension: "dng"), .photo)
        XCTAssertEqual(MediaKind(fileExtension: "MOV"), .video)
        XCTAssertEqual(MediaKind(fileExtension: "m4a"), .audio)
        XCTAssertEqual(MediaKind(fileExtension: "flac"), .audio)
        XCTAssertNil(MediaKind(fileExtension: "pdf"))
        XCTAssertNil(MediaKind(fileExtension: ""))
    }
}
