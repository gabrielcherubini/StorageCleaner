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

    typealias Progress = @Sendable (_ step: String, _ done: Int, _ total: Int) async -> Void

    let store: MediaIndexStore
    let allowDownloads: Bool
    var options = DuplicateOptions.default

    private enum Source {
        case photo(String)
        case file(URL)
    }

    private struct RunState {
        var signatures: [String: MediaSignatures]
        var cloudOnly = Set<String>()
        var failed = Set<String>()
    }

    func run(progress: Progress = { _, _, _ in }) async throws -> Report {
        let scoped = try await store.scopedItems()
        let items = scoped.map(\.item)
        let scopeByKey = Dictionary(scoped.map { ($0.item.location.indexKey, $0.scope) }, uniquingKeysWith: { first, _ in first })
        let folderURLs = try await resolvedFolderURLs()
        var state = RunState(signatures: try await store.signatures())
        let photos = PhotoAnalysis(allowDownloads: allowDownloads)

        func needs() -> SignatureNeeds {
            DuplicateDetector.signatureNeeds(items: items, signatures: state.signatures,
                                             allowDownloads: allowDownloads, options: options)
        }

        try await process(needs().metadata, step: "Reading video and audio details", state: &state,
                          scopeByKey: scopeByKey, folderURLs: folderURLs, progress: progress) { source, item, signature in
            guard case let .file(url) = source else { return signature }
            var signature = signature
            let metadata = await FileAnalysis.avMetadata(of: url)
            signature.duration = metadata.duration
            signature.pixelWidth = metadata.pixelWidth
            signature.pixelHeight = metadata.pixelHeight
            return signature
        }

        let pending = needs()
        try await process(pending.sha256, step: "Comparing same-size files", state: &state,
                          scopeByKey: scopeByKey, folderURLs: folderURLs, progress: progress) { source, _, signature in
            var signature = signature
            switch source {
            case let .photo(id): signature.sha256 = try await photos.sha256(of: id)
            case let .file(url): signature.sha256 = try FileAnalysis.sha256(of: url)
            }
            return signature
        }

        try await process(pending.featurePrint, step: "Looking for similar photos", state: &state,
                          scopeByKey: scopeByKey, folderURLs: folderURLs, progress: progress) { source, _, signature in
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

        try await process(pending.frameHashes, step: "Looking for similar videos", state: &state,
                          scopeByKey: scopeByKey, folderURLs: folderURLs, progress: progress) { source, item, signature in
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

        try await process(pending.audioEnvelope, step: "Looking for similar audio", state: &state,
                          scopeByKey: scopeByKey, folderURLs: folderURLs, progress: progress) { source, _, signature in
            guard case let .file(url) = source else { throw AnalysisError.unreadable }
            var signature = signature
            let result = try FileAnalysis.audioEnvelope(of: url)
            signature.audioEnvelope = result.envelope
            signature.duration = signature.duration ?? result.duration
            return signature
        }

        let skipped = Set(needs().skippedCloudOnly.map(\.location.indexKey)).union(state.cloudOnly)
        return Report(
            groups: DuplicateDetector.detect(items: items, signatures: state.signatures, options: options),
            skippedCloudOnly: skipped.count,
            failed: state.failed.subtracting(skipped).count
        )
    }

    private func process(
        _ items: [MediaItem],
        step: String,
        state: inout RunState,
        scopeByKey: [String: IndexScope],
        folderURLs: [UUID: URL],
        progress: Progress,
        read: (Source, MediaItem, MediaSignatures) async throws -> MediaSignatures
    ) async throws {
        guard !items.isEmpty else { return }
        var unsaved: [String: MediaSignatures] = [:]
        await progress(step, 0, items.count)

        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let key = item.location.indexKey
            let current = state.signatures[key].flatMap { $0.isValid(for: item) ? $0 : nil } ?? MediaSignatures(for: item)
            do {
                let updated: MediaSignatures
                switch item.location {
                case let .photoLibrary(id):
                    updated = try await read(.photo(id), item, current)
                case let .file(url):
                    guard LocalFileGate.mayRead(url, allowDownloads: allowDownloads) else { throw AnalysisError.cloudOnly }
                    if case let .folder(id)? = scopeByKey[key], let folderURL = folderURLs[id] {
                        updated = try await SecurityScopedBookmark.withAccess(to: folderURL) {
                            try await read(.file(url), item, current)
                        }
                    } else {
                        updated = try await read(.file(url), item, current)
                    }
                }
                state.signatures[key] = updated
                unsaved[key] = updated
            } catch is CancellationError {
                try await store.saveSignatures(unsaved)
                throw CancellationError()
            } catch AnalysisError.cloudOnly {
                state.cloudOnly.insert(key)
            } catch {
                state.failed.insert(key)
            }

            if unsaved.count >= 200 {
                try await store.saveSignatures(unsaved)
                unsaved.removeAll()
            }
            if index % 10 == 0 { await progress(step, index, items.count) }
        }
        try await store.saveSignatures(unsaved)
        await progress(step, items.count, items.count)
    }

    private func resolvedFolderURLs() async throws -> [UUID: URL] {
        var urls: [UUID: URL] = [:]
        for folder in try await store.folders() {
            if let resolved = try? SecurityScopedBookmark.resolve(folder.bookmark) {
                urls[folder.id] = resolved.url
            }
        }
        return urls
    }
}
