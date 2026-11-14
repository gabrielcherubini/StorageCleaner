import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Photos
import StorageCleanerCore
import Vision

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Everything here only reads media data. Whether iCloud-only data may be downloaded is decided by
// the caller's `allowDownloads`, which defaults to off in the UI.

enum AnalysisError: Error {
    /// The data is only in iCloud and downloads are not allowed.
    case cloudOnly
    case unreadable
}

enum LocalFileGate {
    /// Checked right before reading: opening an iCloud Drive file that is not downloaded makes the
    /// system download it, so that only happens when the user allowed downloads.
    static func mayRead(_ url: URL, allowDownloads: Bool) -> Bool {
        if allowDownloads { return true }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true {
            return values?.ubiquitousItemDownloadingStatus != .notDownloaded
        }
        return true
    }
}

enum FileAnalysis {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256Hasher()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(chunk)
        }
        return hasher.finalize()
    }

    struct Thumbnail {
        let image: CGImage
        let pixelWidth: Int?
        let pixelHeight: Int?
    }

    static func thumbnail(of url: URL, maxPixelSize: Int = 512) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Thumbnail(
            image: image,
            pixelWidth: properties?[kCGImagePropertyPixelWidth] as? Int,
            pixelHeight: properties?[kCGImagePropertyPixelHeight] as? Int
        )
    }

    struct AVMetadata {
        let duration: Double?
        let pixelWidth: Int?
        let pixelHeight: Int?
    }

    static func avMetadata(of url: URL) async -> AVMetadata {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration))?.seconds
        var width: Int?, height: Int?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let geometry = try? await track.load(.naturalSize, .preferredTransform) {
            let rect = CGRect(origin: .zero, size: geometry.0).applying(geometry.1)
            width = Int(abs(rect.width).rounded())
            height = Int(abs(rect.height).rounded())
        }
        let duration = seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return AVMetadata(duration: duration, pixelWidth: width, pixelHeight: height)
    }

    /// Loudness curve of the first `maxSeconds` of the file, plus the full duration.
    static func audioEnvelope(of url: URL, maxSeconds: Double = 120) throws -> (envelope: [Float], duration: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        let frameCount = AVAudioFrameCount(min(Double(file.length), rate * maxSeconds))
        guard rate > 0, frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { throw AnalysisError.unreadable }
        try file.read(into: buffer, frameCount: frameCount)
        guard let channels = buffer.floatChannelData else { throw AnalysisError.unreadable }

        let frames = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for i in 0..<frames { mono[i] += samples[i] / Float(channelCount) }
        }
        return (AudioEnvelope.make(samples: mono, sampleRate: rate), Double(file.length) / rate)
    }
}

enum FeaturePrinter {
    static func featurePrint(of image: CGImage) throws -> (vector: [Float], revision: Int) {
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let observation = request.results?.first else { throw AnalysisError.unreadable }

        let count = observation.elementCount
        let vector: [Float]
        switch observation.elementType {
        case .float:
            vector = observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
        case .double:
            vector = observation.data.withUnsafeBytes { $0.bindMemory(to: Double.self).prefix(count).map(Float.init) }
        default:
            throw AnalysisError.unreadable
        }
        return (vector, request.revision)
    }
}

enum FrameHasher {
    static func dHash(of image: CGImage) -> UInt64? {
        var pixels = [UInt8](repeating: 0, count: PerceptualHash.width * PerceptualHash.height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: PerceptualHash.width, height: PerceptualHash.height,
                bitsPerComponent: 8, bytesPerRow: PerceptualHash.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: PerceptualHash.width, height: PerceptualHash.height))
            return true
        }
        return drawn ? PerceptualHash.dHash(luminance: pixels) : nil
    }

    /// Hashes of frames at 10%, 50% and 90% of the video.
    static func frameHashes(of asset: AVAsset, duration: Double) async throws -> [UInt64] {
        try await hashes(of: frames(of: asset, duration: duration))
    }

    static func hashes(of frames: [CGImage]) throws -> [UInt64] {
        try frames.map { frame in
            guard let hash = dHash(of: frame) else { throw AnalysisError.unreadable }
            return hash
        }
    }

    /// Small frames at 10%, 50% and 90% of the video.
    static func frames(of asset: AVAsset, duration: Double) async throws -> [CGImage] {
        guard duration > 0 else { throw AnalysisError.unreadable }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        let tolerance = CMTime(seconds: min(0.5, duration / 20), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var frames: [CGImage] = []
        for fraction in [0.1, 0.5, 0.9] {
            try Task.checkCancellation()
            let (image, _) = try await generator.image(at: CMTime(seconds: duration * fraction, preferredTimescale: 600))
            frames.append(image)
        }
        return frames
    }
}

/// Reads photo library data. Network access (iCloud downloads) follows `allowDownloads`.
struct PhotoAnalysis: Sendable {
    let allowDownloads: Bool

    func asset(_ localIdentifier: String) throws -> PHAsset {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            throw AnalysisError.unreadable
        }
        return asset
    }

    /// SHA-256 of the asset's original photo, video or audio resource.
    func sha256(of localIdentifier: String) async throws -> String {
        let resources = PHAssetResource.assetResources(for: try asset(localIdentifier))
        guard let resource = resources.first(where: { [.photo, .video, .audio].contains($0.type) }) ?? resources.first else {
            throw AnalysisError.unreadable
        }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowDownloads

        let state = HashingState()
        let manager = PHAssetResourceManager.default()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let requestID = manager.requestData(for: resource, options: options) { data in
                    state.update(data)
                } completionHandler: { error in
                    if let error {
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
        return state.finalize()
    }

    /// A small rendition for feature prints. Without downloads PhotoKit returns the best local
    /// version, which is normally present even for iCloud-optimized libraries.
    func thumbnail(of localIdentifier: String, maxPixelSize: CGFloat = 512) async throws -> CGImage {
        let asset = try asset(localIdentifier)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowDownloads

        let result: (CGImage?, Bool) = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: maxPixelSize, height: maxPixelSize),
                contentMode: .aspectFit, options: options
            ) { image, info in
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                continuation.resume(returning: (image?.cgImageValue, inCloud))
            }
        }
        if let image = result.0 { return image }
        throw result.1 ? AnalysisError.cloudOnly : AnalysisError.unreadable
    }

    func video(of localIdentifier: String) async throws -> AVAsset {
        let asset = try asset(localIdentifier)
        let options = PHVideoRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = allowDownloads

        let result: (AVAsset?, Bool) = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                continuation.resume(returning: (avAsset, inCloud))
            }
        }
        if let avAsset = result.0 { return avAsset }
        throw result.1 ? AnalysisError.cloudOnly : AnalysisError.unreadable
    }

    static func mapped(_ error: Error) -> Error {
        if let photosError = error as? PHPhotosError, photosError.code == .networkAccessRequired {
            return AnalysisError.cloudOnly
        }
        return error
    }
}

private final class HashingState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasher = SHA256Hasher()
    private var _requestID: PHAssetResourceDataRequestID?

    var requestID: PHAssetResourceDataRequestID? {
        get { lock.withLock { _requestID } }
        set { lock.withLock { _requestID = newValue } }
    }

    func update(_ data: Data) {
        lock.withLock { hasher.update(data) }
    }

    func finalize() -> String {
        lock.withLock { hasher.finalize() }
    }
}

#if os(macOS)
extension NSImage {
    var cgImageValue: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}
#else
extension UIImage {
    var cgImageValue: CGImage? { cgImage }
}
#endif
