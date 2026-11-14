import Foundation
import XCTest
@testable import StorageCleanerCore

final class ClassifierHeuristicsTests: XCTestCase {
    // MARK: Image statistics

    private func image(width: Int = 32, height: Int = 32, _ pixel: (Int, Int) -> UInt8) -> [UInt8] {
        (0..<height).flatMap { y in (0..<width).map { x in pixel(x, y) } }
    }

    func testImageStatsForFlatDarkImage() throws {
        let stats = try XCTUnwrap(ImageStatistics.compute(luminance: image { _, _ in 5 }, width: 32, height: 32))
        XCTAssertEqual(stats.meanLuminance, 5)
        XCTAssertEqual(stats.standardDeviation, 0)
        XCTAssertEqual(stats.darkFraction, 1)
        XCTAssertEqual(stats.laplacianVariance, 0)
        XCTAssertEqual(stats.edgeDensity, 0)
    }

    func testSharpImageHasHigherLaplacianVarianceThanBlurredOne() throws {
        let checker = image { x, y in (x / 2 + y / 2) % 2 == 0 ? 20 : 235 }
        let smooth = image { x, _ in UInt8(100 + x) }
        let sharp = try XCTUnwrap(ImageStatistics.compute(luminance: checker, width: 32, height: 32))
        let blurred = try XCTUnwrap(ImageStatistics.compute(luminance: smooth, width: 32, height: 32))
        XCTAssertGreaterThan(sharp.laplacianVariance, 1_000)
        XCTAssertLessThan(blurred.laplacianVariance, 1)
        XCTAssertGreaterThan(sharp.edgeDensity, 0.3)
    }

    func testImageStatsRejectsBadInput() {
        XCTAssertNil(ImageStatistics.compute(luminance: [1, 2, 3], width: 3, height: 3))
        XCTAssertNil(ImageStatistics.compute(luminance: [1, 2, 3, 4], width: 2, height: 2))
    }

    // MARK: Receipt text

    func testBrazilianReceipt() {
        let text = """
        SUPERMERCADO BOM PREÇO LTDA
        CNPJ: 12.345.678/0001-90
        CUPOM FISCAL ELETRÔNICO - SAT
        QTD  DESCRIÇÃO        VALOR
        1    ARROZ 5KG        R$ 27,90
        TOTAL R$ 1.027,90
        FORMA DE PAGAMENTO: CARTÃO DE CRÉDITO
        """
        let evidence = ReceiptText.evidence(in: text)
        XCTAssertTrue(evidence.hasTaxID)
        XCTAssertTrue(evidence.hasAmount)
        XCTAssertTrue(evidence.keywords.contains("cupom fiscal"))
        XCTAssertTrue(evidence.keywords.contains("cartao"))
        XCTAssertTrue(evidence.keywords.contains("credito"))
        XCTAssertGreaterThan(evidence.score, 0.9)
    }

    func testEnglishInvoice() {
        let evidence = ReceiptText.evidence(in: "INVOICE #123\nSubtotal $40.00\nTax $3.20\nTotal $43.20")
        XCTAssertTrue(evidence.hasAmount)
        XCTAssertFalse(evidence.hasTaxID)
        XCTAssertTrue(evidence.keywords.contains("invoice"))
        XCTAssertTrue(evidence.keywords.contains("subtotal"))
    }

    func testOrdinaryTextIsNotAReceipt() {
        let evidence = ReceiptText.evidence(in: "Happy birthday! See you at the beach on Saturday")
        XCTAssertTrue(evidence.keywords.isEmpty)
        XCTAssertFalse(evidence.hasAmount)
        XCTAssertLessThan(evidence.score, 0.1)
    }

    func testKeywordsMatchWholeWordsOnly() {
        XCTAssertFalse(ReceiptText.evidence(in: "totally taxonomy").keywords.contains("total"))
        XCTAssertFalse(ReceiptText.evidence(in: "totally taxonomy").keywords.contains("tax"))
    }

    // MARK: Filenames and sizes

    func testMessagingFilenames() {
        for name in ["IMG-20240115-WA0003.jpg", "VID-20231201-WA0010.mp4", "PTT-20240101-WA0001.opus",
                     "WhatsApp Image 2024-01-15 at 10.22.31.jpeg", "photo_2024-02-03_18-04-55.jpg",
                     "signal-2024-03-01-120000.jpg", "received_1234567890123.jpeg", "FB_IMG_1700000000000.jpg"] {
            XCTAssertTrue(FilenameHints.looksLikeMessagingApp(name), name)
        }
        for name in ["IMG_1234.HEIC", "DSC00012.ARW", "vacation.jpg", nil] as [String?] {
            XCTAssertFalse(FilenameHints.looksLikeMessagingApp(name), name ?? "nil")
        }
    }

    func testScreenshotFilenames() {
        XCTAssertTrue(FilenameHints.looksLikeScreenshot("Screenshot 2024-01-01 at 10.00.00.png"))
        XCTAssertTrue(FilenameHints.looksLikeScreenshot("Screen Shot 2019-05-01 at 9.41.02 AM.png"))
        XCTAssertTrue(FilenameHints.looksLikeScreenshot("Captura de Tela 2024-01-01 às 10.00.00.png"))
        XCTAssertTrue(FilenameHints.looksLikeScreenRecording("Gravação de Tela 2024-01-01 às 10.00.00.mov"))
        XCTAssertTrue(FilenameHints.looksLikeScreenRecording("Screen Recording 2024-01-01 at 10.00.00.mov"))
        XCTAssertFalse(FilenameHints.looksLikeScreenshot("IMG_0001.PNG"))
    }

    func testScreenAndMessagingSizes() {
        XCTAssertTrue(ScreenSizes.isScreenSize(width: 1179, height: 2556))
        XCTAssertTrue(ScreenSizes.isScreenSize(width: 2556, height: 1179))
        XCTAssertFalse(ScreenSizes.isScreenSize(width: 4032, height: 3024))
        XCTAssertTrue(ScreenSizes.isMessagingSize(width: 1600, height: 1200))
        XCTAssertFalse(ScreenSizes.isMessagingSize(width: 4032, height: 3024))
        XCTAssertFalse(ScreenSizes.isMessagingSize(width: nil, height: 100))
    }
}
