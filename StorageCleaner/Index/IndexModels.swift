import Foundation
import StorageCleanerCore
import SwiftData

/// What a scan covers. Reconciliation (and dropping rows for items that disappeared) is always
/// limited to one scope, so scanning a folder never touches photo rows and vice versa.
enum IndexScope: Hashable, Sendable {
    case photoLibrary
    case folder(UUID)

    var rawValue: String {
        switch self {
        case .photoLibrary: return "photos"
        case let .folder(id): return "folder:\(id.uuidString)"
        }
    }
}

/// One media item in the local index. This is a cache of scan results only; changing or dropping a
/// row never affects the item itself.
@Model
final class IndexedMedia {
    @Attribute(.unique) var key: String
    var scope: String
    var kindRaw: String
    var byteSize: Int64
    var isProtected: Bool
    var fingerprintSize: Int64?
    var fingerprintDate: Date?
    var indexedAt: Date
    /// JSON-encoded `MediaItem`.
    var payload: Data

    init(key: String, scope: String, kindRaw: String, byteSize: Int64, isProtected: Bool,
         fingerprintSize: Int64?, fingerprintDate: Date?, indexedAt: Date, payload: Data) {
        self.key = key
        self.scope = scope
        self.kindRaw = kindRaw
        self.byteSize = byteSize
        self.isProtected = isProtected
        self.fingerprintSize = fingerprintSize
        self.fingerprintDate = fingerprintDate
        self.indexedAt = indexedAt
        self.payload = payload
    }

    var fingerprint: ScanFingerprint {
        ScanFingerprint(byteSize: fingerprintSize, modificationDate: fingerprintDate)
    }
}

/// A folder the user picked for scanning, kept as a security-scoped bookmark.
@Model
final class ScanFolder {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var bookmark: Data
    var addedAt: Date
    var lastScannedAt: Date?

    init(id: UUID = UUID(), displayName: String, bookmark: Data, addedAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.bookmark = bookmark
        self.addedAt = addedAt
    }
}

struct FolderRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    let displayName: String
    let bookmark: Data
    let lastScannedAt: Date?
}

enum IndexSchema {
    static let models: [any PersistentModel.Type] = [IndexedMedia.self, ScanFolder.self]

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: Schema(models), configurations: configuration)
    }
}
