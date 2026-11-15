#if DEBUG
import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import StorageCleanerCore
import UniformTypeIdentifiers

/// Sample library for screenshots and UI checks, enabled with the `-demo` launch argument in
/// Debug builds only. It indexes generated files in the app's temporary folder (in an in-memory
/// index) and never touches the user's media. `-demoScreen <name>` opens a screen directly:
/// `grid`, `videos`, `duplicates`, `viewer`, `confirm` or `rules`.
enum DemoMode {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    static var screen: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard isActive, let index = arguments.firstIndex(of: "-demoScreen"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    static var initialRoute: ReviewRoute? {
        switch screen {
        case "grid", "confirm": return .category(.screenshots)
        case "videos": return .category(.lowQuality)
        case "viewer": return .category(.chatForwards)
        case "duplicates": return .duplicates
        case "rules": return .rules
        default: return nil
        }
    }

    // MARK: Sample library

    private struct Sample {
        let name: String
        let kind: MediaKind
        let width: Int
        let height: Int
        let megabytes: Double
        var daysAgo: Double = 30
        var duration: Double?
        var favorite = false
        var style: Style = .photo(hue: 0.58)

        enum Style {
            case photo(hue: Double)
            case screenshot
            case receipt
            case dark
        }
    }

    private static let samples: [Sample] = [
        Sample(name: "IMG_4021.HEIC", kind: .photo, width: 3024, height: 4032, megabytes: 3.1, daysAgo: 400, style: .photo(hue: 0.58)),
        Sample(name: "IMG_4022.HEIC", kind: .photo, width: 4032, height: 3024, megabytes: 2.9, daysAgo: 400, favorite: true, style: .photo(hue: 0.08)),
        Sample(name: "IMG_4022 copy.HEIC", kind: .photo, width: 4032, height: 3024, megabytes: 2.9, daysAgo: 12, style: .photo(hue: 0.08)),
        Sample(name: "Panorama_0193.JPG", kind: .photo, width: 8000, height: 2000, megabytes: 9.4, daysAgo: 700, style: .photo(hue: 0.36)),
        Sample(name: "Screenshot 2026-10-02 at 09.14.22.png", kind: .photo, width: 1179, height: 2556, megabytes: 1.4, daysAgo: 43, style: .screenshot),
        Sample(name: "Screenshot 2026-10-11 at 18.40.03.png", kind: .photo, width: 1179, height: 2556, megabytes: 1.1, daysAgo: 34, style: .screenshot),
        Sample(name: "Screenshot 2026-11-01 at 12.02.51.png", kind: .photo, width: 2556, height: 1179, megabytes: 1.6, daysAgo: 13, style: .screenshot),
        Sample(name: "Captura de Tela 2026-09-20.png", kind: .photo, width: 1179, height: 2556, megabytes: 0.9, daysAgo: 55, favorite: true, style: .screenshot),
        Sample(name: "IMG-20261003-WA0012.jpg", kind: .photo, width: 1200, height: 1600, megabytes: 0.3, daysAgo: 42, style: .photo(hue: 0.95)),
        Sample(name: "IMG-20261003-WA0013.jpg", kind: .photo, width: 1600, height: 1200, megabytes: 0.3, daysAgo: 42, style: .photo(hue: 0.12)),
        Sample(name: "WhatsApp Image 2026-10-19 at 21.03.11.jpeg", kind: .photo, width: 1600, height: 900, megabytes: 0.2, daysAgo: 26, style: .photo(hue: 0.75)),
        Sample(name: "receipt-mercado.jpg", kind: .photo, width: 1500, height: 2000, megabytes: 1.2, daysAgo: 20, style: .receipt),
        Sample(name: "IMG_4110.HEIC", kind: .photo, width: 3024, height: 4032, megabytes: 2.6, daysAgo: 200, style: .receipt),
        Sample(name: "IMG_4100.HEIC", kind: .photo, width: 4032, height: 3024, megabytes: 2.2, daysAgo: 9, style: .dark),
        Sample(name: "IMG_4102.MOV", kind: .video, width: 1080, height: 1920, megabytes: 6.8, daysAgo: 9, duration: 1.4, style: .dark),
        Sample(name: "IMG_4107.MOV", kind: .video, width: 1920, height: 1080, megabytes: 8.1, daysAgo: 8, duration: 2.1, style: .photo(hue: 0.5)),
        Sample(name: "IMG_3988.MOV", kind: .video, width: 3840, height: 2160, megabytes: 412, daysAgo: 300, duration: 95, style: .photo(hue: 0.62)),
        Sample(name: "IMG_3990.MOV", kind: .video, width: 2160, height: 3840, megabytes: 286, daysAgo: 290, duration: 64, style: .photo(hue: 0.3)),
    ]

    static func populate(_ scanner: ScanCoordinator) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StorageCleanerDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()

        var items: [String: MediaItem] = [:]
        var scanned: [ScannedItem] = []
        for sample in samples {
            let url = folder.appendingPathComponent(sample.name)
            if !FileManager.default.fileExists(atPath: url.path) {
                await render(sample, to: url)
            }
            let item = MediaItem(
                location: .file(url), kind: sample.kind, byteSize: Int64(sample.megabytes * 1_000_000),
                filename: sample.name, pixelWidth: sample.width, pixelHeight: sample.height, duration: sample.duration,
                creationDate: now.addingTimeInterval(-sample.daysAgo * 86_400), isFavorite: sample.favorite,
                isLocallyAvailable: true
            )
            items[sample.name] = item
            scanned.append(ScannedItem(item: item, fingerprint: ScanFingerprint(byteSize: item.byteSize)))
        }
        try? await scanner.store.upsert(scanned, in: .folder(UUID()))

        func classified(_ category: CleanupCategory, _ confidence: Double, _ reasons: [ClassificationReason]) -> [Classification] {
            [Classification(category: category, confidence: confidence, reasons: reasons)]
        }
        var classifications: [String: [Classification]] = [:]
        func add(_ name: String, _ list: [Classification]) {
            if let item = items[name] { classifications[item.location.indexKey, default: []] += list }
        }
        for name in samples.map(\.name) where name.hasPrefix("Screenshot") || name.hasPrefix("Captura") {
            add(name, classified(.screenshots, 0.97, [.screenshotFilename, .screenSize]))
        }
        add("IMG-20261003-WA0012.jpg", classified(.chatForwards, 0.94, [.messagingFilename, .noCameraMetadata]))
        add("IMG-20261003-WA0013.jpg", classified(.chatForwards, 0.94, [.messagingFilename, .noCameraMetadata]))
        add("WhatsApp Image 2026-10-19 at 21.03.11.jpeg", classified(.chatForwards, 0.91, [.messagingFilename]))
        add("IMG_4021.HEIC", classified(.chatForwards, 0.4, [.noCameraMetadata]))
        add("receipt-mercado.jpg", classified(.receipts, 0.93, [.receiptKeywords, .moneyAmount, .taxID]))
        add("IMG_4110.HEIC", classified(.receipts, 0.72, [.documentDetected, .receiptKeywords]))
        add("IMG_4100.HEIC", classified(.lowQuality, 0.88, [.tooDark, .lowDetail]))
        add("IMG_4102.MOV", classified(.lowQuality, 0.86, [.shortVideo, .lowMotion, .tooDark]))
        add("IMG_4107.MOV", classified(.lowQuality, 0.62, [.shortVideo]))
        add("Panorama_0193.JPG", classified(.lowQuality, 0.45, [.blurry]))

        let outcome = ClassificationOutcome(items: items.values.filter { classifications[$0.location.indexKey] != nil },
                                            classifications: classifications)
        let groups = [
            DuplicateGroup(match: .exact, items: [items["IMG_4022.HEIC"], items["IMG_4022 copy.HEIC"]].compactMap { $0 }, similarity: 1),
            DuplicateGroup(match: .similarVideo, items: [items["IMG_4102.MOV"], items["IMG_4107.MOV"]].compactMap { $0 }, similarity: 0.8),
        ].compactMap { $0 }

        await scanner.showDemoResults(
            duplicates: DuplicateAnalyzer.Report(groups: groups, skippedCloudOnly: 0, failed: 0),
            classifications: ClassificationAnalyzer.Report(outcome: outcome,
                                                          reviews: outcome.reviews(preferences: scanner.reviewPreferences),
                                                          skippedCloudOnly: 0, failed: 0)
        )
    }

    // MARK: Rendering

    private static func render(_ sample: Sample, to url: URL) async {
        // Previews only need a small rendition with the right aspect ratio.
        let scale = 640.0 / Double(max(sample.width, sample.height))
        let width = max(16, Int(Double(sample.width) * scale)) & ~1
        let height = max(16, Int(Double(sample.height) * scale)) & ~1
        guard let image = drawImage(sample.style, width: width, height: height) else { return }
        switch sample.kind {
        case .photo:
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        case .video:
            await writeVideo(of: image, to: url)
        case .audio:
            break
        }
    }

    private static func drawImage(_ style: Sample.Style, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        func hsb(_ hue: Double, _ s: Double, _ b: Double) -> CGColor {
            let i = Int(hue * 6) % 6, f = hue * 6 - Double(Int(hue * 6))
            let p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
            let (r, g, bl): (Double, Double, Double) = [(b, t, p), (q, b, p), (p, b, t), (p, q, b), (t, p, b), (b, p, q)][i]
            return CGColor(red: r, green: g, blue: bl, alpha: 1)
        }
        switch style {
        case let .photo(hue):
            let colors = [hsb(hue, 0.45, 0.95), hsb((hue + 0.08).truncatingRemainder(dividingBy: 1), 0.6, 0.55)] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
            context.setFillColor(hsb(hue, 0.5, 0.3))
            context.move(to: CGPoint(x: 0, y: 0))
            context.addLine(to: CGPoint(x: 0, y: h * 0.35))
            context.addLine(to: CGPoint(x: w * 0.35, y: h * 0.55))
            context.addLine(to: CGPoint(x: w * 0.6, y: h * 0.38))
            context.addLine(to: CGPoint(x: w * 0.8, y: h * 0.5))
            context.addLine(to: CGPoint(x: w, y: h * 0.3))
            context.addLine(to: CGPoint(x: w, y: 0))
            context.fillPath()
            context.setFillColor(CGColor(red: 1, green: 0.97, blue: 0.9, alpha: 0.9))
            let r = min(w, h) * 0.08
            context.fillEllipse(in: CGRect(x: w * 0.72 - r, y: h * 0.78 - r, width: r * 2, height: r * 2))
        case .screenshot:
            context.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.setFillColor(CGColor(red: 0.11, green: 0.42, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: h * 0.9, width: w, height: h * 0.1))
            context.setFillColor(CGColor(red: 0.82, green: 0.83, blue: 0.86, alpha: 1))
            var y = h * 0.82
            while y > h * 0.08 {
                context.fill(CGRect(x: w * 0.06, y: y, width: w * 0.88 * (0.5 + 0.5 * abs(sin(y))), height: h * 0.022))
                y -= h * 0.06
            }
        case .receipt:
            context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.96, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let font = CTFontCreateWithName("Courier" as CFString, w * 0.05, nil)
            let lines = ["SUPERMERCADO EXEMPLO", "CNPJ 12.345.678/0001-90", "CUPOM FISCAL", "", "ARROZ 5KG    R$ 27,90",
                         "FEIJAO 1KG   R$ 8,49", "CAFE 500G    R$ 18,90", "", "TOTAL        R$ 55,29", "PAGAMENTO PIX"]
            for (index, line) in lines.enumerated() {
                let text = NSAttributedString(string: line, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1),
                ])
                context.textPosition = CGPoint(x: w * 0.08, y: h * 0.88 - CGFloat(index) * w * 0.085)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
        case .dark:
            context.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.setFillColor(CGColor(red: 0.1, green: 0.09, blue: 0.08, alpha: 1))
            context.fillEllipse(in: CGRect(x: w * 0.2, y: h * 0.2, width: w * 0.5, height: h * 0.4))
        }
        return context.makeImage()
    }

    /// A one-second clip of the still image, so video tiles have real, correctly oriented frames.
    private static func writeVideo(of image: CGImage, to url: URL) async {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: image.width, AVVideoHeightKey: image.height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: image.width, kCVPixelBufferHeightKey as String: image.height,
        ])
        guard writer.canAdd(input) else { return }
        writer.add(input)
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 5_000_000) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                                       bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
#endif
