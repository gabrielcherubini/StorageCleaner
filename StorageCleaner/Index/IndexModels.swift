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

    init?(rawValue: String) {
        if rawValue == "photos" {
            self = .photoLibrary
        } else if rawValue.hasPrefix("folder:"), let id = UUID(uuidString: String(rawValue.dropFirst("folder:".count))) {
            self = .folder(id)
        } else {
            return nil
        }
    }
}

struct ScopedItem: Sendable {
    let item: MediaItem
    let scope: IndexScope
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

/// Cached analysis results (hashes, feature prints, ...) for one item, keyed like `IndexedMedia`.
@Model
final class CachedSignature {
    @Attribute(.unique) var key: String
    var sourceByteSize: Int64
    var sourceModificationDate: Date?
    var sha256: String?
    var featurePrint: Data?
    var featurePrintRevision: Int?
    var frameHashes: Data?
    var audioEnvelope: Data?
    var duration: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// JSON-encoded `ClassificationSignals`.
    var classification: Data?

    init(key: String, signatures: MediaSignatures) {
        self.key = key
        sourceByteSize = signatures.sourceByteSize
        update(from: signatures)
    }

    func update(from signatures: MediaSignatures) {
        sourceByteSize = signatures.sourceByteSize
        sourceModificationDate = signatures.sourceModificationDate
        sha256 = signatures.sha256
        featurePrint = signatures.featurePrint.map(BinaryPacking.data(from:))
        featurePrintRevision = signatures.featurePrintRevision
        frameHashes = signatures.frameHashes.map(BinaryPacking.data(from:))
        audioEnvelope = signatures.audioEnvelope.map(BinaryPacking.data(from:))
        duration = signatures.duration
        pixelWidth = signatures.pixelWidth
        pixelHeight = signatures.pixelHeight
        classification = signatures.classification.flatMap { try? JSONEncoder().encode($0) }
    }

    var signatures: MediaSignatures {
        var result = MediaSignatures(sourceByteSize: sourceByteSize, sourceModificationDate: sourceModificationDate)
        result.sha256 = sha256
        result.featurePrint = featurePrint.map(BinaryPacking.floats(from:))
        result.featurePrintRevision = featurePrintRevision
        result.frameHashes = frameHashes.map(BinaryPacking.uint64s(from:))
        result.audioEnvelope = audioEnvelope.map(BinaryPacking.floats(from:))
        result.duration = duration
        result.pixelWidth = pixelWidth
        result.pixelHeight = pixelHeight
        result.classification = classification.flatMap { try? JSONDecoder().decode(ClassificationSignals.self, from: $0) }
        return result
    }
}

struct FolderRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    let displayName: String
    let bookmark: Data
    let lastScannedAt: Date?
}

enum IndexSchema {
    static let models: [any PersistentModel.Type] = [IndexedMedia.self, ScanFolder.self, CachedSignature.self]

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: Schema(models), configurations: configuration)
    }
}
