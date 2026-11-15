import Foundation

/// Why an item landed in "Likely to delete" or "Likely to keep", so the UI can explain it.
public enum ReviewVerdict: Hashable, Sendable {
    public enum DeleteReason: Hashable, Sendable {
        /// Confidence reached the category's threshold for the chosen strictness.
        case confident(threshold: Double)
        /// "Screenshots older than N days are likely to delete".
        case oldScreenshot(days: Int)
    }

    public enum KeepReason: Hashable, Sendable {
        /// Favorite, shared or edited.
        case protected
        /// Confidence below the category's threshold for the chosen strictness.
        case belowThreshold(threshold: Double)
        /// "Always keep receipts newer than N months".
        case recentReceipt(months: Int)
    }

    case likelyDelete(DeleteReason)
    case likelyKeep(KeepReason)

    public var isLikelyDelete: Bool {
        if case .likelyDelete = self { return true }
        return false
    }
}

public struct ClassifiedItem: Identifiable, Hashable, Sendable {
    public let item: MediaItem
    public let classification: Classification
    public let verdict: ReviewVerdict
    /// Likely-to-delete items start selected unless pre-selection is off for the category;
    /// protected items never do.
    public let isPreselected: Bool

    public var id: MediaLocation { item.location }

    public init(item: MediaItem, classification: Classification, verdict: ReviewVerdict, isPreselected: Bool) {
        self.item = item
        self.classification = classification
        self.verdict = verdict
        self.isPreselected = isPreselected && !item.isProtected && verdict.isLikelyDelete
    }
}

/// Classified items, kept so reviews can be rebuilt when the user changes review preferences.
public struct ClassificationOutcome: Hashable, Sendable {
    public var items: [MediaItem]
    public var classifications: [String: [Classification]]

    public init(items: [MediaItem], classifications: [String: [Classification]]) {
        self.items = items
        self.classifications = classifications
    }

    public func reviews(preferences: ReviewPreferences, now: Date = Date()) -> [CategoryReview] {
        CategoryReview.build(items: items, classifications: classifications, preferences: preferences, now: now)
    }

    public func removing(_ locations: Set<MediaLocation>) -> ClassificationOutcome {
        let keys = Set(locations.map(\.indexKey))
        return ClassificationOutcome(
            items: items.filter { !locations.contains($0.location) },
            classifications: classifications.filter { !keys.contains($0.key) }
        )
    }
}

/// One cleanup category split into "Likely to delete" and "Likely to keep", heaviest first.
public struct CategoryReview: Identifiable, Hashable, Sendable {
    public let category: CleanupCategory
    public let likelyToDelete: [ClassifiedItem]
    public let likelyToKeep: [ClassifiedItem]

    public var id: CleanupCategory { category }
    public var likelyToDeleteBytes: Int64 { likelyToDelete.map(\.item).totalByteSize }
    public var itemCount: Int { likelyToDelete.count + likelyToKeep.count }
    public var preselectedItems: [MediaItem] { likelyToDelete.filter(\.isPreselected).map(\.item) }

    /// Decides one item's verdict. Protected items (favorites, shared, edited) are always
    /// "Likely to keep", whatever the confidence or rules.
    public static func verdict(
        for item: MediaItem,
        classification: Classification,
        preferences: ReviewPreferences,
        now: Date = Date()
    ) -> ReviewVerdict {
        if item.isProtected { return .likelyKeep(.protected) }
        let day: TimeInterval = 86_400
        let age = item.creationDate.map { now.timeIntervalSince($0) }

        if classification.category == .receipts, let months = preferences.keepReceiptsNewerThanMonths,
           let age, age < Double(months) * 30.44 * day {
            return .likelyKeep(.recentReceipt(months: months))
        }
        if classification.category == .screenshots, let days = preferences.screenshotsOlderThanDays,
           let age, age > Double(days) * day {
            return .likelyDelete(.oldScreenshot(days: days))
        }
        let threshold = preferences.threshold(for: classification.category)
        return classification.confidence >= threshold
            ? .likelyDelete(.confident(threshold: threshold))
            : .likelyKeep(.belowThreshold(threshold: threshold))
    }

    public static func build(
        items: [MediaItem],
        classifications: [String: [Classification]],
        preferences: ReviewPreferences = .default,
        now: Date = Date()
    ) -> [CategoryReview] {
        var buckets: [CleanupCategory: (delete: [ClassifiedItem], keep: [ClassifiedItem])] = [:]
        for item in items {
            for classification in classifications[item.location.indexKey] ?? [] {
                let verdict = verdict(for: item, classification: classification, preferences: preferences, now: now)
                let entry = ClassifiedItem(item: item, classification: classification, verdict: verdict,
                                           isPreselected: preferences.preselects(classification.category))
                if verdict.isLikelyDelete {
                    buckets[classification.category, default: ([], [])].delete.append(entry)
                } else {
                    buckets[classification.category, default: ([], [])].keep.append(entry)
                }
            }
        }

        func heaviestFirst(_ entries: [ClassifiedItem]) -> [ClassifiedItem] {
            let order = Dictionary(uniqueKeysWithValues: entries.map(\.item).sortedBySizeDescending().enumerated().map { ($1.location, $0) })
            return entries.sorted { order[$0.item.location]! < order[$1.item.location]! }
        }

        return CleanupCategory.allCases.compactMap { category in
            guard let bucket = buckets[category] else { return nil }
            return CategoryReview(category: category,
                                  likelyToDelete: heaviestFirst(bucket.delete),
                                  likelyToKeep: heaviestFirst(bucket.keep))
        }
    }
}
