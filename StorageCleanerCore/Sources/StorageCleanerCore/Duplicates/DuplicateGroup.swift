import Foundation

/// Analysis results for one item, cached between runs. Every value comes from reading the item's
/// data; none of it changes the item.
public struct MediaSignatures: Codable, Hashable, Sendable {
    /// The item's size and modification date when the signatures were taken. If either changes,
    /// the signatures are stale.
    public var sourceByteSize: Int64
    public var sourceModificationDate: Date?

    public var sha256: String?
    public var featurePrint: [Float]?
    public var featurePrintRevision: Int?
    public var frameHashes: [UInt64]?
    public var audioEnvelope: [Float]?
    /// Metadata read during analysis for files whose scan could not include it.
    public var duration: TimeInterval?
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(sourceByteSize: Int64, sourceModificationDate: Date?) {
        self.sourceByteSize = sourceByteSize
        self.sourceModificationDate = sourceModificationDate
    }

    public init(for item: MediaItem) {
        self.init(sourceByteSize: item.byteSize, sourceModificationDate: item.modificationDate)
    }

    public func isValid(for item: MediaItem) -> Bool {
        ScanFingerprint(byteSize: sourceByteSize, modificationDate: sourceModificationDate)
            .matches(ScanFingerprint(byteSize: item.byteSize, modificationDate: item.modificationDate))
    }
}

/// Picks which copy to keep: favorites first, then the highest resolution, then the oldest.
/// Remaining ties go to the larger file (higher bitrate), then to a stable key order.
public enum KeeperPolicy {
    public static func isBetterKeeper(_ a: MediaItem, than b: MediaItem) -> Bool {
        if a.isFavorite != b.isFavorite { return a.isFavorite }
        let pixelsA = a.pixelCount ?? 0, pixelsB = b.pixelCount ?? 0
        if pixelsA != pixelsB { return pixelsA > pixelsB }
        let dateA = a.creationDate ?? .distantFuture, dateB = b.creationDate ?? .distantFuture
        if dateA != dateB { return dateA < dateB }
        if a.byteSize != b.byteSize { return a.byteSize > b.byteSize }
        return a.location.indexKey < b.location.indexKey
    }

    /// Keeper first, then the rest in the same preference order.
    public static func ordered(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted(by: isBetterKeeper)
    }
}

public struct DuplicateGroup: Identifiable, Hashable, Codable, Sendable {
    public enum Match: String, Codable, Sendable {
        /// Byte-for-byte identical (same size and SHA-256).
        case exact
        case similarPhoto
        case similarVideo
        case similarAudio
    }

    public let match: Match
    /// Suggested keeper first.
    public let items: [MediaItem]
    /// 1.0 for exact copies; near duplicates range from about 0.5 (at the match threshold) to 1.0.
    public let similarity: Double

    public init?(match: Match, items: [MediaItem], similarity: Double) {
        var seen = Set<MediaLocation>()
        let unique = items.filter { seen.insert($0.location).inserted }
        guard unique.count >= 2 else { return nil }
        self.match = match
        self.items = KeeperPolicy.ordered(unique)
        self.similarity = min(1, max(0, similarity))
    }

    public var id: String { "\(match.rawValue):\(keeper.location.indexKey)" }
    public var keeper: MediaItem { items[0] }

    /// Other copies that may be suggested for removal. Protected items (favorites, shared, edited)
    /// are never suggested, even when they are not the keeper.
    public var suggestedForRemoval: [MediaItem] {
        items.dropFirst().filter { !$0.isProtected }
    }

    public var reclaimableBytes: Int64 { suggestedForRemoval.totalByteSize }
}
