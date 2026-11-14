import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import StorageCleanerCore
import UniformTypeIdentifiers
import XCTest
@testable import StorageCleaner

// Fixture folders are left in the temporary directory for the OS to clean up: the safety guard
// bans file-removal APIs in every source file, tests included.
final class DuplicateAnalysisTests: XCTestCase {
    private var store: MediaIndexStore!
    private var root: URL!

    override func setUpWithError() throws {
        store = MediaIndexStore(modelContainer: try IndexSchema.makeContainer(inMemory: true))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateAnalysisTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func indexFolder() async throws -> FolderRecord {
        let folder = try await store.addFolder(displayName: root.lastPathComponent,
                                               bookmark: try SecurityScopedBookmark.make(for: root))
        let result = try FolderScanner().scan(folder)
        try await IndexUpdater(store: store).apply(scanned: result.items, to: .folder(folder.id))
        return folder
    }

    func testFindsExactCopiesInAFolderWithoutChangingThem() async throws {
        let bytes = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        try bytes.write(to: root.appendingPathComponent("original.mov"))
        try bytes.write(to: root.appendingPathComponent("original copy.mov"))
        try Data(bytes.reversed()).write(to: root.appendingPathComponent("other.mov"))
        _ = try await indexFolder()

        let report = try await DuplicateAnalyzer(store: store, allowDownloads: false).run()

        let exact = report.groups.filter { $0.match == .exact }
        XCTAssertEqual(exact.count, 1)
        XCTAssertEqual(Set(exact.first?.items.compactMap(\.filename) ?? []), ["original.mov", "original copy.mov"])
        XCTAssertEqual(exact.first?.reclaimableBytes, 4_096)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("original copy.mov")), bytes)

        let cached = try await store.signatures()
        XCTAssertEqual(cached.values.compactMap(\.sha256).count, 3)
    }

    func testSecondRunReusesCachedHashes() async throws {
        let bytes = Data(repeating: 0x42, count: 2_048)
        try bytes.write(to: root.appendingPathComponent("a.mov"))
        try bytes.write(to: root.appendingPathComponent("b.mov"))
        _ = try await indexFolder()
        _ = try await DuplicateAnalyzer(store: store, allowDownloads: false).run()

        let steps = StepRecorder()
        let report = try await DuplicateAnalyzer(store: store, allowDownloads: false).run { step, _, _ in
            await steps.record(step)
        }

        let recorded = await steps.steps
        XCTAssertFalse(recorded.contains("Comparing same-size files"))
        XCTAssertEqual(report.groups.filter { $0.match == .exact }.count, 1)
    }

    func testFeaturePrintsRankResizedCopyCloserThanADifferentImage() throws {
        let scene = makeImage(width: 800, height: 600, seed: 1)
        let resized = try XCTUnwrap(resize(scene, width: 400, height: 300))
        let different = makeImage(width: 800, height: 600, seed: 9)

        let a: [Float], b: [Float], c: [Float]
        do {
            a = try FeaturePrinter.featurePrint(of: scene).vector
            b = try FeaturePrinter.featurePrint(of: resized).vector
            c = try FeaturePrinter.featurePrint(of: different).vector
        } catch {
            throw XCTSkip("Vision feature prints are unavailable on this machine: \(error)")
        }

        let near = try XCTUnwrap(FeatureVector.distance(a, b))
        let far = try XCTUnwrap(FeatureVector.distance(a, c))
        print("Feature print distances: resized copy \(near), different image \(far)")
        XCTAssertLessThan(near, far)
    }

    func testFrameHashOfHorizontalGradient() {
        let gradient = makeGradient(width: 90, height: 80)
        XCTAssertEqual(FrameHasher.dHash(of: gradient), UInt64.max)
    }

    func testAudioEnvelopeMatchesQuieterCopy() throws {
        let loud = root.appendingPathComponent("memo.wav")
        let quiet = root.appendingPathComponent("memo quiet.wav")
        try writeTone(to: loud, amplitude: 0.8)
        try writeTone(to: quiet, amplitude: 0.3)

        let a = try FileAnalysis.audioEnvelope(of: loud)
        let b = try FileAnalysis.audioEnvelope(of: quiet)

        XCTAssertEqual(a.duration, 4, accuracy: 0.01)
        XCTAssertEqual(a.envelope.count, 8)
        XCTAssertGreaterThan(AudioEnvelope.similarity(a.envelope, b.envelope), 0.95)
    }

    // MARK: Fixtures

    private func makeImage(width: Int, height: Int, seed: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var generator = seed
        func next() -> CGFloat {
            generator = (generator &* 1_103_515_245 &+ 12_345) & 0x7fff_ffff
            return CGFloat(generator % 1_000) / 1_000
        }
        context.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<12 {
            context.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
            let rect = CGRect(x: next() * CGFloat(width), y: next() * CGFloat(height),
                              width: next() * CGFloat(width) / 2, height: next() * CGFloat(height) / 2)
            if seed % 2 == 0 { context.fill(rect) } else { context.fillEllipse(in: rect) }
        }
        return context.makeImage()!
    }

    private func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    private func makeGradient(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { pixels[y * width + x] = UInt8(255 - x * 255 / (width - 1)) }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Four seconds of a tone whose loudness alternates every half second.
    private func writeTone(to url: URL, amplitude: Float) throws {
        let rate = 8_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = AVAudioFrameCount(rate * 4)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let level: Float = (i / 4_000) % 2 == 0 ? 1 : 0.25
            samples[i] = amplitude * level * sin(Float(i) * 2 * .pi * 440 / Float(rate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

private actor StepRecorder {
    private(set) var steps: [String] = []

    func record(_ step: String) {
        if steps.last != step { steps.append(step) }
    }
}
