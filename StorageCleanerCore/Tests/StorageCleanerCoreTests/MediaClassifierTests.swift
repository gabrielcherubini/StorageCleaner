import Foundation
import XCTest
@testable import StorageCleanerCore

final class MediaClassifierTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let sharp = ImageStats(meanLuminance: 120, standardDeviation: 50, darkFraction: 0.02,
                                   brightFraction: 0.02, laplacianVariance: 400, edgeDensity: 0.15)

    private func photo(_ id: String, name: String? = nil, size: (Int, Int) = (4032, 3024), created: Date? = nil,
                       favorite: Bool = false, hints: Set<MediaSourceHint> = [], bytes: Int64 = 1_000) -> MediaItem {
        MediaItem(location: .photoLibrary(localIdentifier: id), kind: .photo, byteSize: bytes, filename: name,
                  pixelWidth: size.0, pixelHeight: size.1, creationDate: created ?? t0, isFavorite: favorite, hints: hints)
    }

    private func signals(_ item: MediaItem, _ edit: (inout ClassificationSignals) -> Void) -> (String, MediaSignatures) {
        var signature = MediaSignatures(for: item)
        var values = ClassificationSignals()
        edit(&values)
        signature.classification = values
        return (item.location.indexKey, signature)
    }

    private func classify(_ items: [MediaItem], _ signatures: [(String, MediaSignatures)] = []) -> [String: [Classification]] {
        MediaClassifier.classify(items: items, signatures: Dictionary(uniqueKeysWithValues: signatures))
    }

    private func classification(_ result: [String: [Classification]], _ item: MediaItem,
                                _ category: CleanupCategory) -> Classification? {
        result[item.location.indexKey]?.first { $0.category == category }
    }

    // MARK: Forwards

    func testWhatsAppFilenameWithoutCameraMetadataIsAConfidentForward() throws {
        let item = photo("w", name: "IMG-20240115-WA0003.jpg", size: (1600, 1200))
        let result = classify([item], [signals(item) { $0.hasCameraMetadata = false; $0.imageStats = sharp; $0.documentConfidence = 0 }])

        let forward = try XCTUnwrap(classification(result, item, .chatForwards))
        XCTAssertGreaterThan(forward.confidence, 0.9)
        XCTAssertEqual(Set(forward.reasons), [.messagingFilename, .noCameraMetadata, .messagingResolution])
    }

    func testCameraPhotoIsNotAForward() {
        let item = photo("c", name: "IMG_1234.HEIC", size: (1600, 1200))
        let result = classify([item], [signals(item) { $0.hasCameraMetadata = true; $0.imageStats = sharp; $0.documentConfidence = 0 }])
        XCTAssertNil(result[item.location.indexKey])
    }

    func testResolutionAloneIsNotEnough() {
        let item = photo("r", name: "IMG_0001.JPG", size: (1600, 1200))
        XCTAssertNil(classification(classify([item]), item, .chatForwards))
    }

    func testBurstOfSavesWithoutCameraMetadataAddsEvidence() throws {
        let saved = (0..<3).map { photo("b\($0)", size: (1280, 960), created: t0.addingTimeInterval(Double($0) * 2)) }
        let lone = photo("lone", size: (1280, 960), created: t0.addingTimeInterval(3_600))
        let all = saved + [lone]
        let result = classify(all, all.map { item in signals(item) { $0.hasCameraMetadata = false } })

        XCTAssertTrue(try XCTUnwrap(classification(result, saved[1], .chatForwards)).reasons.contains(.rapidSaveBurst))
        XCTAssertFalse(try XCTUnwrap(classification(result, lone, .chatForwards)).reasons.contains(.rapidSaveBurst))
    }

    // MARK: Screenshots

    func testScreenshotFlagAndScreenSize() throws {
        let flagged = photo("s", size: (1179, 2556), hints: [.screenshot])
        let pngAtScreenSize = photo("p", name: "IMG_0042.PNG", size: (1179, 2556))
        let result = classify([flagged, pngAtScreenSize], [signals(pngAtScreenSize) { $0.hasCameraMetadata = false }])

        XCTAssertGreaterThan(try XCTUnwrap(classification(result, flagged, .screenshots)).confidence, 0.98)
        let png = try XCTUnwrap(classification(result, pngAtScreenSize, .screenshots))
        XCTAssertEqual(png.reasons, [.screenSize])
        XCTAssertLessThan(png.confidence, ClassifierOptions.default.deleteThreshold(for: .screenshots))
    }

    func testScreenRecordingVideo() throws {
        let video = MediaItem(location: .photoLibrary(localIdentifier: "rec"), kind: .video, byteSize: 9, duration: 40,
                              hints: [.screenRecording])
        XCTAssertNotNil(classification(classify([video]), video, .screenshots))
        XCTAssertNil(classification(classify([video]), video, .lowQuality))
    }

    // MARK: Receipts

    func testReceiptFromDocumentAndText() throws {
        let item = photo("r")
        let result = classify([item], [signals(item) {
            $0.documentConfidence = 0.9
            $0.imageStats = ImageStats(meanLuminance: 235, standardDeviation: 40, darkFraction: 0.05,
                                       brightFraction: 0.85, laplacianVariance: 20, edgeDensity: 0.1)
            $0.recognizedText = "CNPJ 12.345.678/0001-90 NOTA FISCAL TOTAL R$ 54,90 PIX"
        }])

        let receipt = try XCTUnwrap(classification(result, item, .receipts))
        XCTAssertGreaterThan(receipt.confidence, 0.85)
        XCTAssertTrue(receipt.reasons.contains(.taxID))
        XCTAssertNil(classification(result, item, .lowQuality), "a bright, flat document is not a bad photo")
    }

    func testDocumentWithoutTextIsOnlyAWeakReceipt() throws {
        let item = photo("d")
        let result = classify([item], [signals(item) { $0.documentConfidence = 1; $0.imageStats = sharp }])
        let document = try XCTUnwrap(classification(result, item, .receipts))
        XCTAssertEqual(document.reasons, [.documentDetected])
        XCTAssertLessThan(document.confidence, ClassifierOptions.default.deleteThreshold(for: .receipts))
    }

    // MARK: Low quality

    func testBlurryDarkAndPocketShots() throws {
        let blurry = photo("blur"), dark = photo("dark"), pocket = photo("pocket"), good = photo("good")
        let result = classify([blurry, dark, pocket, good], [
            signals(blurry) { $0.imageStats = ImageStats(meanLuminance: 110, standardDeviation: 35, darkFraction: 0,
                                                         brightFraction: 0, laplacianVariance: 8, edgeDensity: 0.03) },
            signals(dark) { $0.imageStats = ImageStats(meanLuminance: 12, standardDeviation: 14, darkFraction: 0.9,
                                                       brightFraction: 0, laplacianVariance: 90, edgeDensity: 0.03) },
            signals(pocket) { $0.imageStats = ImageStats(meanLuminance: 40, standardDeviation: 6, darkFraction: 0.3,
                                                         brightFraction: 0, laplacianVariance: 3, edgeDensity: 0.005) },
            signals(good) { $0.imageStats = sharp; $0.documentConfidence = 0 },
        ])

        XCTAssertEqual(try XCTUnwrap(classification(result, blurry, .lowQuality)).reasons, [.blurry])
        XCTAssertEqual(try XCTUnwrap(classification(result, dark, .lowQuality)).reasons, [.tooDark])
        XCTAssertEqual(try XCTUnwrap(classification(result, pocket, .lowQuality)).reasons, [.lowDetail])
        XCTAssertNil(result[good.location.indexKey])
    }

    func testShortStillVideoAndShortSilentAudio() throws {
        let clip = MediaItem(location: .file(URL(fileURLWithPath: "/d/clip.mov")), kind: .video, byteSize: 5, duration: 1.2)
        let memo = MediaItem(location: .file(URL(fileURLWithPath: "/d/memo.m4a")), kind: .audio, byteSize: 5, duration: 1.5)
        let song = MediaItem(location: .file(URL(fileURLWithPath: "/d/song.mp3")), kind: .audio, byteSize: 5, duration: 200)
        let result = classify([clip, memo, song], [
            signals(clip) { $0.motion = 1; $0.imageStats = ImageStats(meanLuminance: 15, standardDeviation: 20,
                                                                       darkFraction: 0.9, brightFraction: 0,
                                                                       laplacianVariance: 50, edgeDensity: 0.05) },
            signals(memo) { $0.peakLevel = 0.002 },
        ])

        let video = try XCTUnwrap(classification(result, clip, .lowQuality))
        XCTAssertEqual(Set(video.reasons), [.shortVideo, .lowMotion, .tooDark])
        XCTAssertGreaterThan(video.confidence, 0.8)
        let audio = try XCTUnwrap(classification(result, memo, .lowQuality))
        XCTAssertEqual(Set(audio.reasons), [.shortAudio, .nearSilent])
        XCTAssertNil(result[song.location.indexKey])
    }

    // MARK: Review split

    func testReviewSplitNeverPreselectsProtectedItems() throws {
        let screenshot = photo("s", hints: [.screenshot], bytes: 10)
        let favoriteScreenshot = photo("f", favorite: true, hints: [.screenshot], bytes: 20)
        let maybe = photo("m", name: "IMG_0042.PNG", size: (1179, 2556), bytes: 30)
        let items = [screenshot, favoriteScreenshot, maybe]
        let result = classify(items, [signals(maybe) { $0.hasCameraMetadata = false }])

        let review = try XCTUnwrap(CategoryReview.build(items: items, classifications: result).first { $0.category == .screenshots })

        XCTAssertEqual(review.likelyToDelete.map(\.item), [screenshot])
        XCTAssertTrue(review.likelyToDelete.allSatisfy(\.isPreselected))
        XCTAssertEqual(review.likelyToKeep.map(\.item), [maybe, favoriteScreenshot])
        XCTAssertTrue(review.likelyToKeep.allSatisfy { !$0.isPreselected })
        XCTAssertEqual(review.likelyToDeleteBytes, 10)
    }

    // MARK: Needs

    func testNeedsSkipFlaggedScreenshotsAndLargeCameraPhotosForMetadata() {
        let camera = photo("cam", size: (4032, 3024))
        let small = photo("small", size: (1280, 960))
        let screenshot = photo("shot", hints: [.screenshot])
        let needs = MediaClassifier.needs(items: [camera, small, screenshot], signatures: [:], allowDownloads: false)

        XCTAssertEqual(needs.cameraMetadata, [small])
        XCTAssertEqual(Set(needs.visual), [camera, small])
        XCTAssertTrue(needs.text.isEmpty)
    }

    func testTextIsOnlyReadForLikelyDocuments() {
        let doc = photo("doc"), scene = photo("scene")
        let signatures = Dictionary(uniqueKeysWithValues: [
            signals(doc) { $0.imageStats = sharp; $0.documentConfidence = 0.8 },
            signals(scene) { $0.imageStats = sharp; $0.documentConfidence = 0.1 },
        ])
        let needs = MediaClassifier.needs(items: [doc, scene], signatures: signatures, allowDownloads: false)
        XCTAssertEqual(needs.text, [doc])
        XCTAssertTrue(needs.visual.isEmpty)
    }

    func testNeedsRespectCloudOnlyAndShortMediaLimits() {
        var cloudOnly = photo("cloud", size: (4032, 3024))
        cloudOnly.isLocallyAvailable = false
        let shortClip = MediaItem(location: .file(URL(fileURLWithPath: "/d/a.mov")), kind: .video, byteSize: 1, duration: 2,
                                  isLocallyAvailable: true)
        let longClip = MediaItem(location: .file(URL(fileURLWithPath: "/d/b.mov")), kind: .video, byteSize: 1, duration: 60,
                                 isLocallyAvailable: true)
        let unknownAudio = MediaItem(location: .file(URL(fileURLWithPath: "/d/c.m4a")), kind: .audio, byteSize: 1,
                                     isLocallyAvailable: true)

        let needs = MediaClassifier.needs(items: [cloudOnly, shortClip, longClip, unknownAudio], signatures: [:], allowDownloads: false)

        XCTAssertEqual(needs.skippedCloudOnly, [cloudOnly])
        XCTAssertEqual(needs.videoFrames, [shortClip])
        XCTAssertEqual(needs.metadata, [unknownAudio])
        XCTAssertTrue(MediaClassifier.needs(items: [cloudOnly], signatures: [:], allowDownloads: true).skippedCloudOnly.isEmpty)
    }
}
