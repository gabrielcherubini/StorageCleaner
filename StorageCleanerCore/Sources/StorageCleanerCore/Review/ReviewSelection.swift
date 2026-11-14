import Foundation

/// Which items the user has picked for the confirm sheet in one review screen.
///
/// Protected items (favorites, shared, edited) are never selected by the starting suggestion or by
/// bulk selection; the only way to select one is an explicit per-item toggle.
public struct ReviewSelection: Equatable, Sendable {
    public private(set) var selected: Set<MediaLocation>

    public init(preselected: some Sequence<MediaItem> = [MediaItem]()) {
        selected = Set(preselected.filter { !$0.isProtected }.map(\.location))
    }

    public func isSelected(_ item: MediaItem) -> Bool { selected.contains(item.location) }

    public var count: Int { selected.count }

    /// Per-item override in either direction, including protected items.
    public mutating func toggle(_ item: MediaItem) {
        if selected.remove(item.location) == nil { selected.insert(item.location) }
    }

    /// Selects every unprotected item and returns how many protected items were left out.
    @discardableResult
    public mutating func selectAll(_ items: some Sequence<MediaItem>) -> Int {
        var skipped = 0
        for item in items {
            if item.isProtected { skipped += 1 } else { selected.insert(item.location) }
        }
        return skipped
    }

    public mutating func deselectAll(_ items: some Sequence<MediaItem>) {
        for item in items { selected.remove(item.location) }
    }

    public mutating func deselect(_ locations: some Sequence<MediaLocation>) {
        selected.subtract(locations)
    }

    /// The selected items among `items`, in order; what the confirm sheet shows.
    public func plan(from items: [MediaItem]) -> TrashPlan {
        TrashPlan(items: items.filter(isSelected))
    }
}

public struct ReviewFilter: Equatable, Sendable {
    public enum SizeBucket: String, CaseIterable, Sendable {
        case any, atLeast1MB, atLeast10MB, atLeast50MB, atLeast100MB, atLeast1GB

        public var minimumBytes: Int64 {
            switch self {
            case .any: return 0
            case .atLeast1MB: return 1_000_000
            case .atLeast10MB: return 10_000_000
            case .atLeast50MB: return 50_000_000
            case .atLeast100MB: return 100_000_000
            case .atLeast1GB: return 1_000_000_000
            }
        }
    }

    public enum DateBucket: String, CaseIterable, Sendable {
        case any, lastMonth, lastYear, olderThanOneYear, olderThanThreeYears
    }

    public enum Sort: String, CaseIterable, Sendable {
        case largestFirst, newestFirst, oldestFirst
    }

    public var size: SizeBucket = .any
    public var date: DateBucket = .any
    public var kinds: Set<MediaKind> = Set(MediaKind.allCases)
    public var sort: Sort = .largestFirst

    public init() {}

    public var isActive: Bool { size != .any || date != .any || kinds.count != MediaKind.allCases.count }

    /// Items without a creation date only pass when no date filter is set.
    public func includes(_ item: MediaItem, now: Date = Date()) -> Bool {
        guard item.byteSize >= size.minimumBytes, kinds.contains(item.kind) else { return false }
        let day: TimeInterval = 86_400
        switch date {
        case .any: return true
        case .lastMonth: return item.creationDate.map { now.timeIntervalSince($0) <= 30 * day } ?? false
        case .lastYear: return item.creationDate.map { now.timeIntervalSince($0) <= 365 * day } ?? false
        case .olderThanOneYear: return item.creationDate.map { now.timeIntervalSince($0) > 365 * day } ?? false
        case .olderThanThreeYears: return item.creationDate.map { now.timeIntervalSince($0) > 3 * 365 * day } ?? false
        }
    }

    public func apply<Element>(to elements: [Element], item: (Element) -> MediaItem, now: Date = Date()) -> [Element] {
        let kept = elements.filter { includes(item($0), now: now) }
        switch sort {
        case .largestFirst:
            return kept.enumerated().sorted { a, b in
                let (x, y) = (item(a.element), item(b.element))
                return x.byteSize != y.byteSize ? x.byteSize > y.byteSize : a.offset < b.offset
            }.map(\.element)
        case .newestFirst, .oldestFirst:
            let newest = sort == .newestFirst
            return kept.enumerated().sorted { a, b in
                let (x, y) = (item(a.element).creationDate, item(b.element).creationDate)
                switch (x, y) {
                case let (x?, y?) where x != y: return newest ? x > y : x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.offset < b.offset
                }
            }.map(\.element)
        }
    }

    public func apply(to items: [MediaItem], now: Date = Date()) -> [MediaItem] {
        apply(to: items, item: { $0 }, now: now)
    }
}
