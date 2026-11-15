import Foundation
import StorageCleanerCore
import XCTest
@testable import StorageCleaner

final class TrashServiceTests: XCTestCase {
    private let photoA = MediaItem(location: .photoLibrary(localIdentifier: "A"), kind: .photo, byteSize: 100)
    private let photoB = MediaItem(location: .photoLibrary(localIdentifier: "B"), kind: .photo, byteSize: 200)
    private let clip = MediaItem(
        location: .file(URL(fileURLWithPath: "/tmp/clip.mov")),
        kind: .video,
        byteSize: 1_000
    )

    func testRoutesPhotosToRecentlyDeletedAndFilesToTrash() async throws {
        let photos = FakePhotoLibrary()
        let files = FakeFiles()
        let service = TrashService(photoLibrary: photos, files: files)
        let plan = TrashPlan(items: [photoA, clip, photoB])

        let result = await service.moveToTrash(try plan.confirm(plan.summary))

        XCTAssertEqual(photos.requests, [["A", "B"]])
        XCTAssertEqual(files.trashed, [URL(fileURLWithPath: "/tmp/clip.mov")])
        XCTAssertEqual(result.moved.count, 3)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.movedBytes, 1_300)
    }

    func testMissingAssetsAreReportedAsFailures() async throws {
        let photos = FakePhotoLibrary(missing: ["B"])
        let service = TrashService(photoLibrary: photos, files: FakeFiles())
        let plan = TrashPlan(items: [photoA, photoB])

        let result = await service.moveToTrash(try plan.confirm(plan.summary))

        XCTAssertEqual(result.moved.map(\.item), [photoA])
        XCTAssertEqual(result.failures.map(\.item), [photoB])
        XCTAssertEqual(result.failures.first?.reason, .notFound)
    }

    func testDeclinedSystemPromptMovesNothing() async throws {
        let photos = FakePhotoLibrary(shouldThrow: true)
        let service = TrashService(photoLibrary: photos, files: FakeFiles())
        let plan = TrashPlan(items: [photoA, photoB])

        let result = await service.moveToTrash(try plan.confirm(plan.summary))

        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.failures.count, 2)
    }

    func testFileFailureDoesNotStopOtherItems() async throws {
        let other = MediaItem(location: .file(URL(fileURLWithPath: "/tmp/other.mp3")), kind: .audio, byteSize: 5)
        let files = FakeFiles(failing: [URL(fileURLWithPath: "/tmp/clip.mov")])
        let service = TrashService(photoLibrary: FakePhotoLibrary(), files: files)
        let plan = TrashPlan(items: [clip, other])

        let result = await service.moveToTrash(try plan.confirm(plan.summary))

        XCTAssertEqual(result.moved.map(\.item), [other])
        XCTAssertEqual(result.failures.map(\.item), [clip])
    }

    func testFilesAreTrashedInsideTheirFolderScope() async throws {
        let files = FakeFiles()
        let scope = RecordingScope(files: files)
        let service = TrashService(photoLibrary: FakePhotoLibrary(), files: files)
        let plan = TrashPlan(items: [clip, photoA])

        let result = await service.moveToTrash(try plan.confirm(plan.summary), fileAccess: scope)

        XCTAssertEqual(result.moved.count, 2)
        XCTAssertEqual(scope.scopedItems, [clip], "only files need a folder scope")
        XCTAssertEqual(scope.trashedWhileInScope, [URL(fileURLWithPath: "/tmp/clip.mov")])
    }
}

/// Records which items were trashed while their scope was open.
final class RecordingScope: FileAccessScoping, @unchecked Sendable {
    private let lock = NSLock()
    private let files: FakeFiles
    private var _scopedItems: [MediaItem] = []
    private var _trashedWhileInScope: [URL] = []

    init(files: FakeFiles) { self.files = files }

    var scopedItems: [MediaItem] { lock.withLock { _scopedItems } }
    var trashedWhileInScope: [URL] { lock.withLock { _trashedWhileInScope } }

    func withAccess<T>(to item: MediaItem, _ body: () throws -> T) rethrows -> T {
        lock.withLock { _scopedItems.append(item) }
        let before = files.trashed.count
        let result = try body()
        let added = files.trashed.dropFirst(before)
        lock.withLock { _trashedWhileInScope += added }
        return result
    }
}

private struct FakeError: Error {}

final class FakePhotoLibrary: PhotoLibraryTrashing, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [[String]] = []
    private let missing: Set<String>
    private let shouldThrow: Bool

    init(missing: Set<String> = [], shouldThrow: Bool = false) {
        self.missing = missing
        self.shouldThrow = shouldThrow
    }

    var requests: [[String]] { lock.withLock { _requests } }

    func moveToRecentlyDeleted(localIdentifiers: [String]) async throws -> Set<String> {
        lock.withLock { _requests.append(localIdentifiers) }
        if shouldThrow { throw FakeError() }
        return missing.intersection(localIdentifiers)
    }
}

final class FakeFiles: FileTrashing, @unchecked Sendable {
    private let lock = NSLock()
    private var _trashed: [URL] = []
    private let failing: Set<URL>

    init(failing: Set<URL> = []) {
        self.failing = failing
    }

    var trashed: [URL] { lock.withLock { _trashed } }

    func moveToTrash(_ url: URL) throws -> URL? {
        if failing.contains(url) { throw FakeError() }
        lock.withLock { _trashed.append(url) }
        return URL(fileURLWithPath: "/Trash").appendingPathComponent(url.lastPathComponent)
    }
}
