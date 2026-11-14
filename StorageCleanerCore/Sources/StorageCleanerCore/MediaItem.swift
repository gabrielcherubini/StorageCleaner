import Foundation

public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case photo
    case video
    case audio
}

/// Where an item lives. This is also its stable identity across rescans.
public enum MediaLocation: Hashable, Codable, Sendable {
    /// An asset in the iCloud Photos library, identified by `PHAsset.localIdentifier`.
    case photoLibrary(localIdentifier: String)
    /// A file inside the iCloud Drive folder (or a user-picked folder on iOS).
    case file(URL)
}

public struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    public var id: MediaLocation { location }

    public let location: MediaLocation
    public var kind: MediaKind
    public var byteSize: Int64
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var duration: TimeInterval?
    public var creationDate: Date?
    public var isFavorite: Bool
    public var isInSharedAlbum: Bool
    public var isEdited: Bool

    public init(
        location: MediaLocation,
        kind: MediaKind,
        byteSize: Int64,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        duration: TimeInterval? = nil,
        creationDate: Date? = nil,
        isFavorite: Bool = false,
        isInSharedAlbum: Bool = false,
        isEdited: Bool = false
    ) {
        self.location = location
        self.kind = kind
        self.byteSize = byteSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.creationDate = creationDate
        self.isFavorite = isFavorite
        self.isInSharedAlbum = isInSharedAlbum
        self.isEdited = isEdited
    }

    /// Items the user has signalled they care about. These must never be pre-selected for removal.
    public var isProtected: Bool {
        isFavorite || isInSharedAlbum || isEdited
    }

    public var pixelCount: Int? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return pixelWidth * pixelHeight
    }
}

extension Sequence where Element == MediaItem {
    /// Heaviest first; ties broken by oldest first so ordering is stable across rescans.
    public func sortedBySizeDescending() -> [MediaItem] {
        sorted { lhs, rhs in
            if lhs.byteSize != rhs.byteSize { return lhs.byteSize > rhs.byteSize }
            return (lhs.creationDate ?? .distantFuture) < (rhs.creationDate ?? .distantFuture)
        }
    }

    public var totalByteSize: Int64 {
        reduce(0) { $0 + $1.byteSize }
    }
}
