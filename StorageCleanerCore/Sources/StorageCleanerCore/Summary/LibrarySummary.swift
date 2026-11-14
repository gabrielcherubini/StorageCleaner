import Foundation

public enum CleanupCategory: String, Codable, Sendable, CaseIterable {
    case largeFiles
    case duplicates
    case chatForwards
    case screenshots
    case receipts
    case lowQuality
}

/// The few columns needed to total up the index without decoding every item.
public struct SummaryEntry: Hashable, Sendable {
    public var key: String
    public var kind: MediaKind
    public var byteSize: Int64
    public var isProtected: Bool

    public init(key: String, kind: MediaKind, byteSize: Int64, isProtected: Bool) {
        self.key = key
        self.kind = kind
        self.byteSize = byteSize
        self.isProtected = isProtected
    }

    public init(_ item: MediaItem) {
        self.init(key: item.location.indexKey, kind: item.kind, byteSize: item.byteSize, isProtected: item.isProtected)
    }
}

/// Running "potential savings" per category. An item counts once overall even if it lands in
/// several categories, and protected items (favorites, shared, edited) never count.
public struct SavingsTally: Equatable, Sendable {
    public private(set) var bytesByCategory: [CleanupCategory: Int64] = [:]
    public private(set) var countByCategory: [CleanupCategory: Int] = [:]
    public private(set) var totalBytes: Int64 = 0
    public private(set) var totalCount: Int = 0

    private var members: [CleanupCategory: Set<String>] = [:]
    private var counted: Set<String> = []

    public init() {}

    /// Returns `false` if the entry was ignored (protected, or already in this category).
    @discardableResult
    public mutating func add(_ entry: SummaryEntry, to category: CleanupCategory) -> Bool {
        guard !entry.isProtected else { return false }
        guard members[category, default: []].insert(entry.key).inserted else { return false }
        bytesByCategory[category, default: 0] += entry.byteSize
        countByCategory[category, default: 0] += 1
        if counted.insert(entry.key).inserted {
            totalBytes += entry.byteSize
            totalCount += 1
        }
        return true
    }

    public func bytes(in category: CleanupCategory) -> Int64 { bytesByCategory[category] ?? 0 }
    public func count(in category: CleanupCategory) -> Int { countByCategory[category] ?? 0 }
}

public struct LibrarySummary: Equatable, Sendable {
    public static let defaultLargeFileThreshold: Int64 = 50 * 1_000_000

    public private(set) var itemCount = 0
    public private(set) var totalBytes: Int64 = 0
    public private(set) var countByKind: [MediaKind: Int] = [:]
    public private(set) var bytesByKind: [MediaKind: Int64] = [:]
    public private(set) var potentialSavings = SavingsTally()
    /// Heaviest items first.
    public var heaviest: [MediaItem]

    public static let empty = LibrarySummary(entries: [], heaviest: [])

    public init(
        entries: some Sequence<SummaryEntry>,
        heaviest: [MediaItem],
        largeFileThreshold: Int64 = LibrarySummary.defaultLargeFileThreshold
    ) {
        self.heaviest = heaviest.sortedBySizeDescending()
        for entry in entries {
            itemCount += 1
            totalBytes += entry.byteSize
            countByKind[entry.kind, default: 0] += 1
            bytesByKind[entry.kind, default: 0] += entry.byteSize
            if entry.byteSize >= largeFileThreshold {
                potentialSavings.add(entry, to: .largeFiles)
            }
        }
    }

    public init(
        items: some Sequence<MediaItem>,
        heaviestLimit: Int = 50,
        largeFileThreshold: Int64 = LibrarySummary.defaultLargeFileThreshold
    ) {
        let all = Array(items)
        self.init(
            entries: all.map(SummaryEntry.init),
            heaviest: Array(all.sortedBySizeDescending().prefix(heaviestLimit)),
            largeFileThreshold: largeFileThreshold
        )
    }

    /// Adds analyzer results (for example items suggested in duplicate groups) to the savings total.
    public mutating func addSavings(_ items: some Sequence<MediaItem>, to category: CleanupCategory) {
        for item in items {
            potentialSavings.add(SummaryEntry(item), to: category)
        }
    }

    public func count(of kind: MediaKind) -> Int { countByKind[kind] ?? 0 }
    public func bytes(of kind: MediaKind) -> Int64 { bytesByKind[kind] ?? 0 }
}
