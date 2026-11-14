import Foundation

public struct ClassifiedItem: Identifiable, Hashable, Sendable {
    public let item: MediaItem
    public let classification: Classification
    /// Only items in "Likely to delete" start selected; protected items never do.
    public let isPreselected: Bool

    public var id: MediaLocation { item.location }
}

/// One cleanup category split into "Likely to delete" and "Likely to keep", heaviest first.
public struct CategoryReview: Identifiable, Hashable, Sendable {
    public let category: CleanupCategory
    public let likelyToDelete: [ClassifiedItem]
    public let likelyToKeep: [ClassifiedItem]

    public var id: CleanupCategory { category }
    public var likelyToDeleteBytes: Int64 { likelyToDelete.map(\.item).totalByteSize }
    public var itemCount: Int { likelyToDelete.count + likelyToKeep.count }

    /// Protected items (favorites, shared, edited) always land in "Likely to keep", whatever the
    /// confidence, so they are never pre-selected.
    public static func build(
        items: [MediaItem],
        classifications: [String: [Classification]],
        options: ClassifierOptions = .default
    ) -> [CategoryReview] {
        var buckets: [CleanupCategory: (delete: [ClassifiedItem], keep: [ClassifiedItem])] = [:]
        for item in items {
            for classification in classifications[item.location.indexKey] ?? [] {
                let likelyDelete = !item.isProtected
                    && classification.confidence >= options.deleteThreshold(for: classification.category)
                let entry = ClassifiedItem(item: item, classification: classification, isPreselected: likelyDelete)
                if likelyDelete {
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
