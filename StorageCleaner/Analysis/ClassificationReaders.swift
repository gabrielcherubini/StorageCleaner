import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Photos
import StorageCleanerCore
import Vision

// Readers for the classifier signals. Like the duplicate readers, they only read media data and
// follow the caller's `allowDownloads` for iCloud-only data.

enum CameraMetadata {
    /// Whether image properties name the camera that took the photo. Messaging apps strip this
    /// when they recompress media.
    static func isPresent(in properties: [CFString: Any]) -> Bool {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let make = tiff?[kCGImagePropertyTIFFMake] as? String
        let model = tiff?[kCGImagePropertyTIFFModel] as? String
        let lens = exif?[kCGImagePropertyExifLensModel] as? String
        return [make, model, lens].contains { !($0 ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func isPresent(inFile url: URL) throws -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw AnalysisError.unreadable }
        return isPresent(in: properties)
    }

    static func isPresent(inPrefix data: Data, isComplete: Bool) throws -> Bool {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, isComplete)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw AnalysisError.unreadable
        }
        return isPresent(in: properties)
    }
}

enum VisualAnalysis {
    static let statsSize = 256
    static let textImageSize = 1600

    /// Draws the image into a small grayscale buffer (keeping its aspect ratio) and measures it.
    static func stats(of image: CGImage) -> ImageStats? {
        let scale = min(1, Double(statsSize) / Double(max(image.width, image.height)))
        let width = max(3, Int((Double(image.width) * scale).rounded()))
        let height = max(3, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? ImageStatistics.compute(luminance: pixels, width: width, height: height) : nil
    }

    /// Confidence that the image shows a document (paper, receipt, card); 0 when none was found.
    static func documentConfidence(of image: CGImage) throws -> Double {
        let request = VNDetectDocumentSegmentationRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return Double(request.results?.first?.confidence ?? 0)
    }

    static let textLanguages = ["pt-BR", "en-US"]
    static let maxTextLength = 4_000

    /// `accurate` is for detected documents; paper-like photos get the much cheaper fast pass.
    static func recognizedText(in image: CGImage, accurate: Bool = true) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let languages = textLanguages.filter { supported.contains($0) }
        if !languages.isEmpty { request.recognitionLanguages = languages }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return String(lines.joined(separator: "\n").prefix(maxTextLength))
    }

    /// Mean Hamming distance between consecutive frame hashes; low values mean a still video.
    static func motion(of hashes: [UInt64]) -> Double? {
        guard hashes.count >= 2 else { return nil }
        let distances = zip(hashes, hashes.dropFirst()).map { PerceptualHash.hammingDistance($0, $1) }
        return Double(distances.reduce(0, +)) / Double(distances.count)
    }

    static func peakLevel(of envelope: [Float]) -> Double {
        Double(envelope.max() ?? 0)
    }
}

extension PhotoAnalysis {
    /// Reads only the start of the original photo, where the image properties live.
    func hasCameraMetadata(_ localIdentifier: String, prefixLength: Int = 1 << 20) async throws -> Bool {
        let resources = PHAssetResource.assetResources(for: try asset(localIdentifier))
        guard let resource = resources.first(where: { $0.type == .photo }) ?? resources.first else {
            throw AnalysisError.unreadable
        }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowDownloads

        let state = PrefixState(limit: prefixLength)
        let manager = PHAssetResourceManager.default()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let requestID = manager.requestData(for: resource, options: options) { data in
                    if state.append(data), let id = state.requestID {
                        manager.cancelDataRequest(id)
                    }
                } completionHandler: { error in
                    if let error, !state.isFull {
                        continuation.resume(throwing: Self.mapped(error))
                    } else {
                        continuation.resume()
                    }
                }
                state.requestID = requestID
            }
        } onCancel: {
            if let id = state.requestID { manager.cancelDataRequest(id) }
        }
        try Task.checkCancellation()
        return try CameraMetadata.isPresent(inPrefix: state.data, isComplete: !state.isFull)
    }
}

private final class PrefixState: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var _data = Data()
    private var _requestID: PHAssetResourceDataRequestID?

    init(limit: Int) { self.limit = limit }

    var requestID: PHAssetResourceDataRequestID? {
        get { lock.withLock { _requestID } }
        set { lock.withLock { _requestID = newValue } }
    }

    var data: Data { lock.withLock { _data } }
    var isFull: Bool { lock.withLock { _data.count >= limit } }

    /// Returns true once enough data has arrived.
    func append(_ chunk: Data) -> Bool {
        lock.withLock {
            if _data.count < limit { _data.append(chunk) }
            return _data.count >= limit
        }
    }
}
