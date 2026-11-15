import AVFoundation
import CoreGraphics
import Foundation
import Observation
import StorageCleanerCore

/// Small previews for the review grids. Read-only, and never downloads: items whose data is only
/// in iCloud show a placeholder instead.
@Observable
final class ThumbnailLoader: @unchecked Sendable {
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

    func thumbnail(for item: MediaItem, maxPixelSize: Int) async -> CGImage? {
        let key = "\(item.location.indexKey)#\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = await load(item, maxPixelSize: maxPixelSize) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private func folderAccess() async -> FolderAccess? {
        if let access = lock.withLock({ access }) { return access }
        guard let loaded = try? await FolderAccess.load(store: store) else { return nil }
        lock.withLock { access = loaded }
        return loaded
    }

    private func load(_ item: MediaItem, maxPixelSize: Int) async -> CGImage? {
        switch item.location {
        case let .photoLibrary(id):
            return try? await PhotoAnalysis(allowDownloads: false).thumbnail(of: id, maxPixelSize: CGFloat(maxPixelSize))
        case let .file(url):
            guard item.kind != .audio, let access = await folderAccess() else { return nil }
            return try? await access.withAccess(to: item) { () async throws -> CGImage? in
                guard LocalFileGate.mayRead(url, allowDownloads: false) else { return nil }
                if item.kind == .photo { return FileAnalysis.thumbnail(of: url, maxPixelSize: maxPixelSize)?.image }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
                let time = CMTime(seconds: min(1, (item.duration ?? 0) / 2), preferredTimescale: 600)
                return try await generator.image(at: time).image
            }
        }
    }
}
