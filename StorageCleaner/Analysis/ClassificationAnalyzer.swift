import AVFoundation
import Foundation
import StorageCleanerCore

/// Reads the classifier signals (reusing cached ones), then sorts items into cleanup categories
/// with `MediaClassifier`. It only reads media; iCloud-only data is read only when
/// `allowDownloads` is on.
struct ClassificationAnalyzer: Sendable {
    struct Report: Sendable {
        var reviews: [CategoryReview]
        /// Items left out because their data is only in iCloud and downloads are off.
        var skippedCloudOnly: Int
        /// Items whose data could not be read.
        var failed: Int
    }

    typealias Progress = AnalysisRunner.Progress

    let store: MediaIndexStore
    let allowDownloads: Bool
    var options = ClassifierOptions.default

    func run(progress: Progress = { _, _, _ in }) async throws -> Report {
        var runner = try await AnalysisRunner.load(store: store, allowDownloads: allowDownloads)
        let items = runner.items
        let photos = PhotoAnalysis(allowDownloads: allowDownloads)

        func needs() -> ClassificationNeeds {
            MediaClassifier.needs(items: items, signatures: runner.signatures,
                                  allowDownloads: allowDownloads, options: options)
        }

        let metadataNeeds = needs().metadata
        try await runner.process(metadataNeeds, step: "Reading video and audio details", progress: progress) { source, _, signature in
            guard case let .file(url) = source else { return signature }
            var signature = signature
            let metadata = await FileAnalysis.avMetadata(of: url)
            signature.duration = metadata.duration
            signature.pixelWidth = metadata.pixelWidth
            signature.pixelHeight = metadata.pixelHeight
            return signature
        }

        let pending = needs()
        try await runner.process(pending.cameraMetadata, step: "Looking for chat and app forwards", progress: progress) { source, _, signature in
            var signature = signature
            switch source {
            case let .photo(id): signature.classificationSignals.hasCameraMetadata = try await photos.hasCameraMetadata(id)
            case let .file(url): signature.classificationSignals.hasCameraMetadata = try CameraMetadata.isPresent(inFile: url)
            }
            return signature
        }

        try await runner.process(pending.visual, step: "Checking photo quality and documents", progress: progress) { source, _, signature in
            var signature = signature
            let image: CGImage
            switch source {
            case let .photo(id):
                image = try await photos.thumbnail(of: id)
            case let .file(url):
                guard let thumbnail = FileAnalysis.thumbnail(of: url) else { throw AnalysisError.unreadable }
                image = thumbnail.image
                signature.pixelWidth = thumbnail.pixelWidth
                signature.pixelHeight = thumbnail.pixelHeight
            }
            guard let stats = VisualAnalysis.stats(of: image) else { throw AnalysisError.unreadable }
            signature.classificationSignals.imageStats = stats
            signature.classificationSignals.documentConfidence = try VisualAnalysis.documentConfidence(of: image)
            return signature
        }

        // Text is only read for photos the visual pass found to be documents.
        let textNeeds = needs().text
        try await runner.process(textNeeds, step: "Reading text in documents", progress: progress) { source, _, signature in
            var signature = signature
            let image: CGImage
            switch source {
            case let .photo(id):
                image = try await photos.thumbnail(of: id, maxPixelSize: CGFloat(VisualAnalysis.textImageSize))
            case let .file(url):
                guard let thumbnail = FileAnalysis.thumbnail(of: url, maxPixelSize: VisualAnalysis.textImageSize)
                else { throw AnalysisError.unreadable }
                image = thumbnail.image
            }
            signature.classificationSignals.recognizedText = try VisualAnalysis.recognizedText(in: image)
            return signature
        }

        try await runner.process(pending.videoFrames, step: "Checking short videos", progress: progress) { source, item, signature in
            var signature = signature
            let asset: AVAsset
            switch source {
            case let .photo(id): asset = try await photos.video(of: id)
            case let .file(url): asset = AVURLAsset(url: url)
            }
            let frames = try await FrameHasher.frames(of: asset, duration: item.duration ?? signature.duration ?? 0)
            let hashes = try FrameHasher.hashes(of: frames)
            signature.frameHashes = hashes
            signature.classificationSignals.motion = VisualAnalysis.motion(of: hashes)
            signature.classificationSignals.imageStats = VisualAnalysis.stats(of: frames[frames.count / 2])
            return signature
        }

        try await runner.process(pending.audioLevel, step: "Checking short audio", progress: progress) { source, _, signature in
            guard case let .file(url) = source else { throw AnalysisError.unreadable }
            var signature = signature
            let result = try FileAnalysis.audioEnvelope(of: url)
            signature.audioEnvelope = result.envelope
            signature.duration = signature.duration ?? result.duration
            signature.classificationSignals.peakLevel = VisualAnalysis.peakLevel(of: result.envelope)
            return signature
        }

        let skipped = runner.skippedCloudOnly(alsoSkipped: needs().skippedCloudOnly)
        return Report(
            reviews: MediaClassifier.review(items: items, signatures: runner.signatures, options: options),
            skippedCloudOnly: skipped.count,
            failed: runner.failed.subtracting(skipped).count
        )
    }
}
