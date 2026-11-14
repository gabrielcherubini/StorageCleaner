import AVFoundation
import Foundation
import StorageCleanerCore

/// Reads the signatures duplicate detection needs (reusing cached ones), then groups duplicates
/// with `DuplicateDetector`. It only reads media; iCloud-only data is read only when
/// `allowDownloads` is on.
struct DuplicateAnalyzer: Sendable {
    struct Report: Sendable {
        var groups: [DuplicateGroup]
        /// Items left out because their data is only in iCloud and downloads are off.
        var skippedCloudOnly: Int
        /// Items whose data could not be read.
        var failed: Int
    }

    typealias Progress = AnalysisRunner.Progress

    let store: MediaIndexStore
    let allowDownloads: Bool
    var options = DuplicateOptions.default

    func run(progress: Progress = { _, _, _ in }) async throws -> Report {
        var runner = try await AnalysisRunner.load(store: store, allowDownloads: allowDownloads)
        let items = runner.items
        let photos = PhotoAnalysis(allowDownloads: allowDownloads)

        func needs() -> SignatureNeeds {
            DuplicateDetector.signatureNeeds(items: items, signatures: runner.signatures,
                                             allowDownloads: allowDownloads, options: options)
        }

        let metadataNeeds = needs().metadata
        try await runner.process(metadataNeeds, step: "Reading video and audio details", progress: progress) { source, item, signature in
            guard case let .file(url) = source else { return signature }
            var signature = signature
            let metadata = await FileAnalysis.avMetadata(of: url)
            signature.duration = metadata.duration
            signature.pixelWidth = metadata.pixelWidth
            signature.pixelHeight = metadata.pixelHeight
            return signature
        }

        let pending = needs()
        try await runner.process(pending.sha256, step: "Comparing same-size files", progress: progress) { source, _, signature in
            var signature = signature
            switch source {
            case let .photo(id): signature.sha256 = try await photos.sha256(of: id)
            case let .file(url): signature.sha256 = try FileAnalysis.sha256(of: url)
            }
            return signature
        }

        try await runner.process(pending.featurePrint, step: "Looking for similar photos", progress: progress) { source, _, signature in
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
            let featurePrint = try FeaturePrinter.featurePrint(of: image)
            signature.featurePrint = featurePrint.vector
            signature.featurePrintRevision = featurePrint.revision
            return signature
        }

        try await runner.process(pending.frameHashes, step: "Looking for similar videos", progress: progress) { source, item, signature in
            var signature = signature
            let asset: AVAsset
            switch source {
            case let .photo(id): asset = try await photos.video(of: id)
            case let .file(url): asset = AVURLAsset(url: url)
            }
            let duration = item.duration ?? signature.duration ?? 0
            signature.frameHashes = try await FrameHasher.frameHashes(of: asset, duration: duration)
            return signature
        }

        try await runner.process(pending.audioEnvelope, step: "Looking for similar audio", progress: progress) { source, _, signature in
            guard case let .file(url) = source else { throw AnalysisError.unreadable }
            var signature = signature
            let result = try FileAnalysis.audioEnvelope(of: url)
            signature.audioEnvelope = result.envelope
            signature.duration = signature.duration ?? result.duration
            return signature
        }

        let skipped = runner.skippedCloudOnly(alsoSkipped: needs().skippedCloudOnly)
        return Report(
            groups: DuplicateDetector.detect(items: items, signatures: runner.signatures, options: options),
            skippedCloudOnly: skipped.count,
            failed: runner.failed.subtracting(skipped).count
        )
    }
}
