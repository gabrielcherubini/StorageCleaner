import AVFoundation
import CoreGraphics
import Foundation
import Observation
import Photos
import StorageCleanerCore

/// Previews for the review grids and the viewer. Read-only. iCloud-only data is fetched only when
/// the user's "Download iCloud originals" setting allows it; otherwise a placeholder is shown.
@Observable
final class ThumbnailLoader: @unchecked Sendable {
    enum PreviewError: Error {
        /// The data is only in iCloud and downloads are off.
        case cloudOnly
        case unavailable
    }

    @ObservationIgnored private let store: MediaIndexStore
    @ObservationIgnored private let cache = NSCache<NSString, CGImage>()
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var access: FolderAccess?

    init(store: MediaIndexStore) {
        self.store = store
        cache.countLimit = 600
    }

    /// Call after folders change so new folder scopes are picked up.
    func resetAccess() {
        lock.withLock { access = nil }
    }

    func cachedThumbnail(for item: MediaItem, maxPixelSize: Int, allowDownloads: Bool) -> CGImage? {
        cache.object(forKey: cacheKey(item, maxPixelSize, allowDownloads))
            ?? (allowDownloads ? nil : cache.object(forKey: cacheKey(item, maxPixelSize, true)))
    }

    func thumbnail(for item: MediaItem, maxPixelSize: Int, allowDownloads: Bool) async -> CGImage? {
        try? await image(for: item, maxPixelSize: maxPixelSize, allowDownloads: allowDownloads)
    }

    /// A still image of the item (a frame for videos). Throws `PreviewError.cloudOnly` when the
    /// data is only in iCloud and downloads are off.
    func image(for item: MediaItem, maxPixelSize: Int, allowDownloads: Bool) async throws -> CGImage {
        if let cached = cachedThumbnail(for: item, maxPixelSize: maxPixelSize, allowDownloads: allowDownloads) {
            return cached
        }
        let image = try await load(item, maxPixelSize: maxPixelSize, allowDownloads: allowDownloads)
        cache.setObject(image, forKey: cacheKey(item, maxPixelSize, allowDownloads))
        return image
    }

    /// A player item for videos and audio. For iCloud Drive files the returned scope must be kept
    /// alive while the item plays.
    func playerItem(for item: MediaItem, allowDownloads: Bool) async throws -> (AVPlayerItem, SecurityScope?) {
        switch item.location {
        case let .photoLibrary(id):
            return (try await PhotoAnalysis(allowDownloads: allowDownloads).playerItem(of: id), nil)
        case let .file(url):
            let scope = await folderAccess()?.folderURL(for: item).map(SecurityScope.init)
            guard LocalFileGate.mayRead(url, allowDownloads: allowDownloads) else { throw PreviewError.cloudOnly }
            return (AVPlayerItem(url: url), scope)
        }
    }

    private func cacheKey(_ item: MediaItem, _ size: Int, _ allowDownloads: Bool) -> NSString {
        "\(item.location.indexKey)#\(size)#\(allowDownloads ? "d" : "l")" as NSString
    }

    private func folderAccess() async -> FolderAccess? {
        if let access = lock.withLock({ access }) { return access }
        guard let loaded = try? await FolderAccess.load(store: store) else { return nil }
        lock.withLock { access = loaded }
        return loaded
    }

    private func load(_ item: MediaItem, maxPixelSize: Int, allowDownloads: Bool) async throws -> CGImage {
        switch item.location {
        case let .photoLibrary(id):
            do {
                return try await PhotoAnalysis(allowDownloads: allowDownloads).thumbnail(of: id, maxPixelSize: CGFloat(maxPixelSize))
            } catch AnalysisError.cloudOnly {
                throw PreviewError.cloudOnly
            }
        case let .file(url):
            guard item.kind != .audio, let access = await folderAccess() else { throw PreviewError.unavailable }
            let image = try await access.withAccess(to: item) { () async throws -> CGImage? in
                guard LocalFileGate.mayRead(url, allowDownloads: allowDownloads) else { throw PreviewError.cloudOnly }
                if item.kind == .photo { return FileAnalysis.thumbnail(of: url, maxPixelSize: maxPixelSize)?.image }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
                let time = CMTime(seconds: min(1, (item.duration ?? 0) / 2), preferredTimescale: 600)
                return try await generator.image(at: time).image
            }
            guard let image else { throw PreviewError.unavailable }
            return image
        }
    }
}

/// Holds a folder's security scope open, for example while a video from that folder plays.
final class SecurityScope: @unchecked Sendable {
    private let url: URL
    private let didStart: Bool

    init(_ url: URL) {
        self.url = url
        didStart = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStart { url.stopAccessingSecurityScopedResource() }
    }
}

extension PhotoAnalysis {
    /// A streaming player item; network access follows `allowDownloads`.
    func playerItem(of localIdentifier: String) async throws -> AVPlayerItem {
        let asset = try asset(localIdentifier)
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = allowDownloads

        let result: (AVPlayerItem?, Bool) = await withCheckedContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, info in
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                continuation.resume(returning: (item, inCloud))
            }
        }
        if let item = result.0 { return item }
        throw result.1 ? ThumbnailLoader.PreviewError.cloudOnly : ThumbnailLoader.PreviewError.unavailable
    }
}
