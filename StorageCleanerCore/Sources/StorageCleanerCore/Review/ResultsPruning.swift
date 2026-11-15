import Foundation

// After items move to Recently Deleted / Trash, the current analysis results drop them so the
// review screens never offer the same item twice.

extension DuplicateGroup {
    /// The group without `locations`, or `nil` when fewer than two items remain. The keeper
    /// policy is re-applied to what is left.
    public func removing(_ locations: Set<MediaLocation>) -> DuplicateGroup? {
        DuplicateGroup(match: match, items: items.filter { !locations.contains($0.location) }, similarity: similarity)
    }
}

extension CategoryReview {
    public func removing(_ locations: Set<MediaLocation>) -> CategoryReview? {
        let delete = likelyToDelete.filter { !locations.contains($0.item.location) }
        let keep = likelyToKeep.filter { !locations.contains($0.item.location) }
        guard !delete.isEmpty || !keep.isEmpty else { return nil }
        return CategoryReview(category: category, likelyToDelete: delete, likelyToKeep: keep)
    }
}

extension DuplicateGroup {
    /// True when the selection would move every copy in the group, leaving none behind.
    public func selectsEveryCopy(_ selection: ReviewSelection) -> Bool {
        items.allSatisfy(selection.isSelected)
    }
}
