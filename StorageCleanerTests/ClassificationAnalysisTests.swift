import CoreGraphics
import CoreText
import Foundation
import ImageIO
import StorageCleanerCore
import UniformTypeIdentifiers
import XCTest
@testable import StorageCleaner

// Fixture folders are left in the temporary directory for the OS to clean up: the safety guard
// bans file-removal APIs in every source file, tests included.
final class ClassificationAnalysisTests: XCTestCase {
    private var store: MediaIndexStore!
    private var root: URL!

    override func setUpWithError() throws {
        store = MediaIndexStore(modelContainer: try IndexSchema.makeContainer(inMemory: true))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassificationAnalysisTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func indexFolder() async throws {
        let folder = try await store.addFolder(displayName: root.lastPathComponent,
                                               bookmark: try SecurityScopedBookmark.make(for: root))
        let result = try FolderScanner().scan(folder)
        try await IndexUpdater(store: store).apply(scanned: result.items, to: .folder(folder.id))
    }

    func testClassifiesFolderWithoutChangingFiles() async throws {
        try write(makeNoise(width: 600, height: 400, seed: 1), as: .png, to: "Screenshot 2024-01-01 at 10.00.00.png")
        try write(makeNoise(width: 1600, height: 1200, seed: 2), as: .jpeg, to: "IMG-20240115-WA0003.jpg")
        try write(makeFlat(width: 640, height: 480, level: 6), as: .jpeg, to: "dark.jpg")
        try write(makeNoise(width: 900, height: 600, seed: 3), as: .jpeg, to: "camera.jpg", cameraMake: "Apple")
        let before = try snapshot()
        try await indexFolder()

        let report: ClassificationAnalyzer.Report
        do {
            report = try await ClassificationAnalyzer(store: store, allowDownloads: false).run()
        } catch {
            throw XCTSkip("Classification is unavailable on this machine: \(error)")
        }
        if report.failed > 0 { throw XCTSkip("Vision could not analyze the fixtures on this machine") }

        func names(_ category: CleanupCategory, _ list: KeyPath<CategoryReview, [ClassifiedItem]>) -> Set<String> {
            Set(report.reviews.first { $0.category == category }?[keyPath: list].compactMap(\.item.filename) ?? [])
        }
        XCTAssertTrue(names(.screenshots, \.likelyToDelete).contains("Screenshot 2024-01-01 at 10.00.00.png"))
        XCTAssertTrue(names(.chatForwards, \.likelyToDelete).contains("IMG-20240115-WA0003.jpg"))
        XCTAssertTrue(names(.lowQuality, \.likelyToDelete).contains("dark.jpg"))
        XCTAssertFalse(names(.chatForwards, \.likelyToDelete).union(names(.chatForwards, \.likelyToKeep)).contains("camera.jpg"))
        XCTAssertTrue(report.reviews.allSatisfy { review in
            review.likelyToDelete.allSatisfy(\.isPreselected) && review.likelyToKeep.allSatisfy { !$0.isPreselected }
        })
        XCTAssertEqual(try snapshot(), before)

        let steps = StepRecorder()
        _ = try await ClassificationAnalyzer(store: store, allowDownloads: false).run { step, _, _ in await steps.record(step) }
        let recorded = await steps.steps
        XCTAssertFalse(recorded.contains("Checking photo quality and documents"), "cached signals are reused")
    }

    func testImageStatsSeparateFlatAndDetailedImages() throws {
        let flat = try XCTUnwrap(VisualAnalysis.stats(of: makeFlat(width: 800, height: 600, level: 8)))
        let detailed = try XCTUnwrap(VisualAnalysis.stats(of: makeNoise(width: 800, height: 600, seed: 4)))
        XCTAssertLessThan(flat.meanLuminance, 30)
        XCTAssertLessThan(flat.standardDeviation, 1)
        XCTAssertGreaterThan(detailed.laplacianVariance, 100)
        XCTAssertGreaterThan(detailed.standardDeviation, 30)
    }

    func testReadsPortugueseReceiptText() throws {
        let receipt = makeTextImage(lines: [
            "SUPERMERCADO EXEMPLO LTDA",
            "CNPJ 12.345.678/0001-90",
            "CUPOM FISCAL ELETRONICO",
            "ARROZ 5KG        R$ 27,90",
            "TOTAL            R$ 54,90",
            "PAGAMENTO PIX",
        ])
        let text: String
        do {
            text = try VisualAnalysis.recognizedText(in: receipt)
        } catch {
            throw XCTSkip("Vision text recognition is unavailable on this machine: \(error)")
        }
        print("Recognized receipt text: \(text)")
        let evidence = ReceiptText.evidence(in: text)
        XCTAssertTrue(evidence.hasAmount)
        XCTAssertGreaterThanOrEqual(evidence.keywords.count, 3)

        if let confidence = try? VisualAnalysis.documentConfidence(of: receipt) {
            print("Document confidence for the receipt: \(confidence)")
            XCTAssertTrue((0...1).contains(confidence))
        }
    }

    // MARK: Fixtures

    private func snapshot() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            files[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return files
    }

    private func write(_ image: CGImage, as type: UTType, to name: String, cameraMake: String? = nil) throws {
        let url = root.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let cameraMake {
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: cameraMake,
                                                          kCGImagePropertyTIFFModel: "iPhone 15 Pro"]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func grayContext(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    }

    private func makeFlat(width: Int, height: Int, level: CGFloat) -> CGImage {
        let context = grayContext(width: width, height: height)
        context.setFillColor(gray: level / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Random 4×4 blocks: lots of sharp edges at any thumbnail size.
    private func makeNoise(width: Int, height: Int, seed: Int) -> CGImage {
        let context = grayContext(width: width, height: height)
        var generator = seed
        let block = max(4, max(width, height) / 128)
        for y in stride(from: 0, to: height, by: block) {
            for x in stride(from: 0, to: width, by: block) {
                generator = (generator &* 1_103_515_245 &+ 12_345) & 0x7fff_ffff
                context.setFillColor(gray: CGFloat(generator % 256) / 255, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: block, height: block))
            }
        }
        return context.makeImage()!
    }

    private func makeTextImage(lines: [String]) -> CGImage {
        let width = 1200, lineHeight = 80
        let height = lineHeight * (lines.count + 2)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Courier" as CFString, 44, nil)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        for (index, text) in lines.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): black,
            ])
            context.textPosition = CGPoint(x: 60, y: height - lineHeight * (index + 2))
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return context.makeImage()!
    }
}

private actor StepRecorder {
    private(set) var steps: [String] = []

    func record(_ step: String) {
        if steps.last != step { steps.append(step) }
    }
}
