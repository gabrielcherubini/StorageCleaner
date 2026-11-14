import Foundation
import XCTest
@testable import StorageCleanerCore

final class DuplicateDetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func photo(
        _ id: String, bytes: Int64 = 1_000, size: (Int, Int)? = (4032, 3024), created: Date? = nil,
        favorite: Bool = false, edited: Bool = false, local: Bool? = nil, hints: Set<MediaSourceHint> = []
    ) -> MediaItem {
        MediaItem(
            location: .photoLibrary(localIdentifier: id), kind: .photo, byteSize: bytes,
            pixelWidth: size?.0, pixelHeight: size?.1, creationDate: created ?? t0,
            isFavorite: favorite, isEdited: edited, isLocallyAvailable: local, hints: hints
        )
    }

    private func file(_ name: String, kind: MediaKind, bytes: Int64, duration: TimeInterval? = nil,
                      created: Date? = nil, local: Bool? = true) -> MediaItem {
        MediaItem(location: .file(URL(fileURLWithPath: "/drive/\(name)")), kind: kind, byteSize: bytes,
                  filename: name, duration: duration, creationDate: created ?? t0, isLocallyAvailable: local)
    }

    private func signature(_ item: MediaItem, _ edit: (inout MediaSignatures) -> Void) -> (String, MediaSignatures) {
        var signature = MediaSignatures(for: item)
        edit(&signature)
        return (item.location.indexKey, signature)
    }

    // MARK: Keeper

    func testKeeperPrefersFavoriteThenResolutionThenOldest() {
        let older = photo("older", size: (1000, 1000), created: t0)
        let newer = photo("newer", size: (1000, 1000), created: t0.addingTimeInterval(10))
        let sharper = photo("sharper", size: (4000, 3000), created: t0.addingTimeInterval(20))
        let favorite = photo("favorite", size: (640, 480), created: t0.addingTimeInterval(30), favorite: true)

        XCTAssertEqual(KeeperPolicy.ordered([newer, older]).first, older)
        XCTAssertEqual(KeeperPolicy.ordered([older, sharper, newer]).first, sharper)
        XCTAssertEqual(KeeperPolicy.ordered([older, sharper, favorite]).first, favorite)
    }

    func testProtectedItemsAreNeverSuggestedForRemoval() throws {
        let keeper = photo("keeper", size: (4000, 3000))
        let edited = photo("edited", size: (100, 100), edited: true)
        let plain = photo("plain", size: (100, 100), created: t0.addingTimeInterval(5))

        let group = try XCTUnwrap(DuplicateGroup(match: .exact, items: [plain, edited, keeper], similarity: 1))

        XCTAssertEqual(group.keeper, keeper)
        XCTAssertEqual(group.suggestedForRemoval, [plain])
        XCTAssertEqual(group.reclaimableBytes, plain.byteSize)
    }

    func testGroupNeedsTwoDistinctItems() {
        let a = photo("a")
        XCTAssertNil(DuplicateGroup(match: .exact, items: [a, a], similarity: 1))
    }

    // MARK: Exact

    func testExactDuplicatesNeedSameSizeAndHash() {
        let a = file("a.mov", kind: .video, bytes: 5_000)
        let b = file("b.mov", kind: .video, bytes: 5_000)
        let c = file("c.mov", kind: .video, bytes: 5_000)
        let d = file("d.mov", kind: .video, bytes: 6_000)
        let signatures = Dictionary(uniqueKeysWithValues: [
            signature(a) { $0.sha256 = "aaa" },
            signature(b) { $0.sha256 = "aaa" },
            signature(c) { $0.sha256 = "ccc" },
            signature(d) { $0.sha256 = "aaa" },
        ])

        let groups = DuplicateDetector.detect(items: [a, b, c, d], signatures: signatures)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].match, .exact)
        XCTAssertEqual(Set(groups[0].items), [a, b])
        XCTAssertEqual(groups[0].reclaimableBytes, 5_000)
    }

    func testOnlySameSizeItemsAreHashed() {
        let a = file("a.jpg", kind: .photo, bytes: 10)
        let b = file("b.jpg", kind: .photo, bytes: 10)
        let c = file("c.jpg", kind: .photo, bytes: 11)
        let audioSameSize = file("d.m4a", kind: .audio, bytes: 10, duration: 3)

        let needs = DuplicateDetector.signatureNeeds(items: [a, b, c, audioSameSize], signatures: [:], allowDownloads: false)

        XCTAssertEqual(Set(needs.sha256), [a, b])
    }

    func testStaleSignaturesAreIgnored() {
        let a = file("a.jpg", kind: .photo, bytes: 10)
        var b = file("b.jpg", kind: .photo, bytes: 10)
        let signatures = Dictionary(uniqueKeysWithValues: [signature(a) { $0.sha256 = "x" }, signature(b) { $0.sha256 = "x" }])
        b.modificationDate = t0.addingTimeInterval(99)

        XCTAssertTrue(DuplicateDetector.detect(items: [a, b], signatures: signatures).isEmpty)
        XCTAssertEqual(DuplicateDetector.signatureNeeds(items: [a, b], signatures: signatures, allowDownloads: false).sha256, [b])
    }

    // MARK: iCloud-only items

    func testCloudOnlyItemsAreSkippedUnlessDownloadsAllowed() {
        let local = file("a.jpg", kind: .photo, bytes: 10, local: true)
        let cloudOnly = file("b.jpg", kind: .photo, bytes: 10, local: false)
        var placeholder = file(".c.jpg.icloud", kind: .photo, bytes: 10, local: false)
        placeholder.hints = [.iCloudPlaceholder]

        let offline = DuplicateDetector.signatureNeeds(items: [local, cloudOnly, placeholder], signatures: [:], allowDownloads: false)
        XCTAssertEqual(offline.sha256, [local])
        XCTAssertEqual(Set(offline.skippedCloudOnly), [cloudOnly, placeholder])

        let online = DuplicateDetector.signatureNeeds(items: [local, cloudOnly, placeholder], signatures: [:], allowDownloads: true)
        XCTAssertEqual(Set(online.sha256), [local, cloudOnly])
        XCTAssertEqual(online.skippedCloudOnly, [placeholder])
    }

    func testFilesWithoutDurationNeedMetadataFirst() {
        let clip = file("a.mov", kind: .video, bytes: 1, duration: nil)
        let other = file("b.mov", kind: .video, bytes: 2, duration: nil)
        let needs = DuplicateDetector.signatureNeeds(items: [clip, other], signatures: [:], allowDownloads: false)
        XCTAssertEqual(Set(needs.metadata), [clip, other])
        XCTAssertTrue(needs.frameHashes.isEmpty)

        let signatures = Dictionary(uniqueKeysWithValues: [signature(clip) { $0.duration = 30 }, signature(other) { $0.duration = 30.4 }])
        let next = DuplicateDetector.signatureNeeds(items: [clip, other], signatures: signatures, allowDownloads: false)
        XCTAssertTrue(next.metadata.isEmpty)
        XCTAssertEqual(Set(next.frameHashes.map(\.location)), [clip.location, other.location])
    }

    // MARK: Near duplicates

    func testSimilarPhotosWithinTimeWindowAndThreshold() {
        let a = photo("a", size: (4000, 3000), created: t0)
        let b = photo("b", size: (2000, 1500), created: t0.addingTimeInterval(4))
        let farInTime = photo("c", created: t0.addingTimeInterval(3 * 3600))
        let different = photo("d", created: t0.addingTimeInterval(8))
        let signatures = Dictionary(uniqueKeysWithValues: [
            signature(a) { $0.featurePrint = [0, 0]; $0.featurePrintRevision = 2 },
            signature(b) { $0.featurePrint = [0.1, 0]; $0.featurePrintRevision = 2 },
            signature(farInTime) { $0.featurePrint = [0, 0.05]; $0.featurePrintRevision = 2 },
            signature(different) { $0.featurePrint = [5, 5]; $0.featurePrintRevision = 2 },
        ])

        let groups = DuplicateDetector.detect(items: [a, b, farInTime, different], signatures: signatures)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].match, .similarPhoto)
        XCTAssertEqual(groups[0].items, [a, b])
        XCTAssertEqual(groups[0].similarity, 1 - 0.5 * 0.1 / 0.4, accuracy: 0.0001)
    }

    func testFeaturePrintsOnlyNeededForPhotosWithNeighbors() {
        let a = photo("a", created: t0)
        let b = photo("b", created: t0.addingTimeInterval(60))
        let lonely = photo("c", created: t0.addingTimeInterval(86_400))
        let needs = DuplicateDetector.signatureNeeds(items: [a, b, lonely], signatures: [:], allowDownloads: false)
        XCTAssertEqual(Set(needs.featurePrint), [a, b])
    }

    func testCompleteLinkagePreventsChaining() {
        let shots = (0..<3).map { photo("s\($0)", created: t0.addingTimeInterval(Double($0))) }
        let signatures = Dictionary(uniqueKeysWithValues: zip(shots, [Float(0), 0.3, 0.6]).map { item, x in
            signature(item) { $0.featurePrint = [x]; $0.featurePrintRevision = 2 }
        })

        let groups = DuplicateDetector.detect(items: shots, signatures: signatures)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].items.count, 2)
    }

    func testSimilarVideosByDurationAndFrameHashes() {
        let a = file("a.mov", kind: .video, bytes: 9_000, duration: 60)
        let b = file("b.mp4", kind: .video, bytes: 3_000, duration: 60.5)
        let c = file("c.mov", kind: .video, bytes: 3_000, duration: 60.2)
        let signatures = Dictionary(uniqueKeysWithValues: [
            signature(a) { $0.frameHashes = [0xFF00, 0x0F0F, 0xAAAA]; $0.pixelWidth = 3840; $0.pixelHeight = 2160 },
            signature(b) { $0.frameHashes = [0xFF01, 0x0F0F, 0xAAAB]; $0.pixelWidth = 1280; $0.pixelHeight = 720 },
            signature(c) { $0.frameHashes = [~0xFF00, ~0x0F0F, ~0xAAAA] },
        ])

        let groups = DuplicateDetector.detect(items: [a, b, c], signatures: signatures)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].match, .similarVideo)
        XCTAssertEqual(groups[0].keeper.location, a.location)
        XCTAssertEqual(groups[0].keeper.pixelWidth, 3840)
        XCTAssertEqual(groups[0].suggestedForRemoval.map(\.location), [b.location])
    }

    func testSimilarAudioByDurationAndEnvelope() {
        let curve: [Float] = [0.1, 0.8, 0.3, 0.9, 0.2, 0.7, 0.1, 0.6]
        let a = file("memo.m4a", kind: .audio, bytes: 800, duration: 4, created: t0)
        let b = file("memo copy.mp3", kind: .audio, bytes: 300, duration: 4.2, created: t0.addingTimeInterval(60))
        let c = file("other.m4a", kind: .audio, bytes: 800, duration: 4.1)
        let signatures = Dictionary(uniqueKeysWithValues: [
            signature(a) { $0.audioEnvelope = curve },
            signature(b) { $0.audioEnvelope = curve.map { $0 * 0.6 } },
            signature(c) { $0.audioEnvelope = curve.reversed() },
        ])

        let groups = DuplicateDetector.detect(items: [a, b, c], signatures: signatures)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].match, .similarAudio)
        XCTAssertEqual(groups[0].keeper.location, a.location)
    }

    func testExactCopiesAreNotRepeatedInNearGroups() {
        let a = photo("a", bytes: 500, created: t0)
        let b = photo("b", bytes: 500, created: t0.addingTimeInterval(1))
        let c = photo("c", bytes: 400, created: t0.addingTimeInterval(2))
        let signatures = Dictionary(uniqueKeysWithValues: [a, b, c].map { item in
            signature(item) {
                $0.sha256 = item.byteSize == 500 ? "same" : "other"
                $0.featurePrint = [0]
                $0.featurePrintRevision = 2
            }
        })

        let groups = DuplicateDetector.detect(items: [a, b, c], signatures: signatures)

        XCTAssertEqual(groups.map(\.match).sorted { $0.rawValue < $1.rawValue }, [.exact, .similarPhoto])
        let locations = groups.flatMap { $0.items.map(\.location) }
        XCTAssertEqual(locations.filter { $0 == b.location }.count, 1)
        let near = groups.first { $0.match == .similarPhoto }
        XCTAssertEqual(Set(near?.items.map(\.location) ?? []), [a.location, c.location])
    }
}
