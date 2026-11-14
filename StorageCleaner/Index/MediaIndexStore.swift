import Foundation
import StorageCleanerCore
import SwiftData

/// Background access to the SwiftData index. Everything crossing the actor boundary is a Sendable
/// value type; `@Model` objects never leave the actor.
@ModelActor
actor MediaIndexStore {
    // MARK: Items

    func fingerprints(in scope: IndexScope) throws -> [String: ScanFingerprint] {
        let scopeValue = scope.rawValue
        var descriptor = FetchDescriptor<IndexedMedia>(predicate: #Predicate { $0.scope == scopeValue })
        descriptor.propertiesToFetch = [\.key, \.fingerprintSize, \.fingerprintDate]
        let rows = try modelContext.fetch(descriptor)
        return Dictionary(rows.map { ($0.key, $0.fingerprint) }, uniquingKeysWith: { first, _ in first })
    }

    func upsert(_ scanned: [ScannedItem], in scope: IndexScope, at date: Date = Date()) throws {
        guard !scanned.isEmpty else { return }
        let keys = scanned.map(\.indexKey)
        let existing = try modelContext.fetch(FetchDescriptor<IndexedMedia>(predicate: #Predicate { keys.contains($0.key) }))
        let encoder = JSONEncoder()
        var byKey = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        for entry in scanned {
            let payload = try encoder.encode(entry.item)
            if let row = byKey[entry.indexKey] {
                row.scope = scope.rawValue
                row.kindRaw = entry.item.kind.rawValue
                row.byteSize = entry.item.byteSize
                row.isProtected = entry.item.isProtected
                row.fingerprintSize = entry.fingerprint.byteSize
                row.fingerprintDate = entry.fingerprint.modificationDate
                row.indexedAt = date
                row.payload = payload
            } else {
                let row = IndexedMedia(
                    key: entry.indexKey,
                    scope: scope.rawValue,
                    kindRaw: entry.item.kind.rawValue,
                    byteSize: entry.item.byteSize,
                    isProtected: entry.item.isProtected,
                    fingerprintSize: entry.fingerprint.byteSize,
                    fingerprintDate: entry.fingerprint.modificationDate,
                    indexedAt: date,
                    payload: payload
                )
                modelContext.insert(row)
                byKey[entry.indexKey] = row
            }
        }
        try modelContext.save()
    }

    /// Drops index rows only. The media itself is never touched.
    func dropRows(forKeys keys: [String]) throws {
        guard !keys.isEmpty else { return }
        for chunk in keys.chunked(into: 500) {
            let rows = try modelContext.fetch(FetchDescriptor<IndexedMedia>(predicate: #Predicate { chunk.contains($0.key) }))
            for row in rows { modelContext.delete(row) }
            let cached = try modelContext.fetch(FetchDescriptor<CachedSignature>(predicate: #Predicate { chunk.contains($0.key) }))
            for row in cached { modelContext.delete(row) }
        }
        try modelContext.save()
    }

    /// Drops every index row for a scope, for example when the user stops scanning a folder.
    func dropRows(in scope: IndexScope) throws {
        let scopeValue = scope.rawValue
        let rows = try modelContext.fetch(FetchDescriptor<IndexedMedia>(predicate: #Predicate { $0.scope == scopeValue }))
        for row in rows { modelContext.delete(row) }
        try modelContext.save()
    }

    /// Every indexed item with the scope it was scanned in.
    func scopedItems() throws -> [ScopedItem] {
        let decoder = JSONDecoder()
        return try modelContext.fetch(FetchDescriptor<IndexedMedia>()).compactMap { row in
            guard let scope = IndexScope(rawValue: row.scope),
                  let item = try? decoder.decode(MediaItem.self, from: row.payload) else { return nil }
            return ScopedItem(item: item, scope: scope)
        }
    }

    func item(forKey key: String) throws -> MediaItem? {
        var descriptor = FetchDescriptor<IndexedMedia>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map { try JSONDecoder().decode(MediaItem.self, from: $0.payload) }
    }

    func itemCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<IndexedMedia>())
    }

    // MARK: Summary

    /// Heaviest first, across every scope.
    func heaviestItems(limit: Int, offset: Int = 0) throws -> [MediaItem] {
        var descriptor = FetchDescriptor<IndexedMedia>(sortBy: [SortDescriptor(\.byteSize, order: .reverse)])
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        let decoder = JSONDecoder()
        return try modelContext.fetch(descriptor).compactMap { try? decoder.decode(MediaItem.self, from: $0.payload) }
    }

    func summary(heaviestLimit: Int = 50) throws -> LibrarySummary {
        var descriptor = FetchDescriptor<IndexedMedia>()
        descriptor.propertiesToFetch = [\.key, \.kindRaw, \.byteSize, \.isProtected]
        let entries = try modelContext.fetch(descriptor).compactMap { row -> SummaryEntry? in
            guard let kind = MediaKind(rawValue: row.kindRaw) else { return nil }
            return SummaryEntry(key: row.key, kind: kind, byteSize: row.byteSize, isProtected: row.isProtected)
        }
        return LibrarySummary(entries: entries, heaviest: try heaviestItems(limit: heaviestLimit))
    }

    // MARK: Analysis cache

    func signatures() throws -> [String: MediaSignatures] {
        let rows = try modelContext.fetch(FetchDescriptor<CachedSignature>())
        return Dictionary(rows.map { ($0.key, $0.signatures) }, uniquingKeysWith: { first, _ in first })
    }

    func saveSignatures(_ signatures: [String: MediaSignatures]) throws {
        guard !signatures.isEmpty else { return }
        let keys = Array(signatures.keys)
        let existing = try modelContext.fetch(FetchDescriptor<CachedSignature>(predicate: #Predicate { keys.contains($0.key) }))
        var byKey = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, value) in signatures {
            if let row = byKey[key] {
                row.update(from: value)
            } else {
                let row = CachedSignature(key: key, signatures: value)
                modelContext.insert(row)
                byKey[key] = row
            }
        }
        try modelContext.save()
    }

    // MARK: Folders

    func folders() throws -> [FolderRecord] {
        try modelContext.fetch(FetchDescriptor<ScanFolder>(sortBy: [SortDescriptor(\.addedAt)])).map(\.record)
    }

    func addFolder(displayName: String, bookmark: Data) throws -> FolderRecord {
        let folder = ScanFolder(displayName: displayName, bookmark: bookmark)
        modelContext.insert(folder)
        try modelContext.save()
        return folder.record
    }

    func updateFolder(id: UUID, bookmark: Data? = nil, lastScannedAt: Date? = nil) throws {
        guard let folder = try folder(id: id) else { return }
        if let bookmark { folder.bookmark = bookmark }
        if let lastScannedAt { folder.lastScannedAt = lastScannedAt }
        try modelContext.save()
    }

    /// Forgets the folder and its index rows. Files in the folder are not touched.
    func forgetFolder(id: UUID) throws {
        try dropRows(in: .folder(id))
        if let folder = try folder(id: id) {
            modelContext.delete(folder)
            try modelContext.save()
        }
    }

    private func folder(id: UUID) throws -> ScanFolder? {
        var descriptor = FetchDescriptor<ScanFolder>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

private extension ScanFolder {
    var record: FolderRecord {
        FolderRecord(id: id, displayName: displayName, bookmark: bookmark, lastScannedAt: lastScannedAt)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
