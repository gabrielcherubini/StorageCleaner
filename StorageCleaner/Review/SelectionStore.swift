import Observation
import StorageCleanerCore
import SwiftUI

/// A review screen's selection, held outside the screen's own state so that toggling one item
/// re-renders only the views that read it (tiles, the selection bar), never the grid or the
/// scroll view around them.
///
/// The suggestion (`seed`) can arrive or change after the screen appears, for example when an
/// analysis finishes or review preferences change. Items the user has toggled keep the user's
/// choice; everything else follows the latest suggestion.
@MainActor
@Observable
final class SelectionStore {
    private(set) var selection = ReviewSelection()

    @ObservationIgnored private var suggested: Set<MediaLocation> = []
    @ObservationIgnored private var touched: Set<MediaLocation> = []

    func isSelected(_ item: MediaItem) -> Bool { selection.isSelected(item) }

    /// Applies the current pre-selection. Protected items are never selected by it.
    func seed(_ preselected: [MediaItem]) {
        let items = preselected.filter { !$0.isProtected && !touched.contains($0.location) }
        let next = Set(items.map(\.location))
        let dropped = suggested.subtracting(next).subtracting(touched)
        var updated = selection
        updated.deselect(dropped)
        updated.selectAll(items)
        suggested = next
        if updated != selection { selection = updated }
    }

    func toggle(_ item: MediaItem) {
        touched.insert(item.location)
        selection.toggle(item)
    }

    @discardableResult
    func selectAll(_ items: [MediaItem]) -> Int {
        touched.formUnion(items.map(\.location))
        return selection.selectAll(items)
    }

    func deselectAll(_ items: [MediaItem]) {
        touched.formUnion(items.map(\.location))
        selection.deselectAll(items)
    }

    func deselect(_ locations: Set<MediaLocation>) {
        selection.deselect(locations)
    }

    /// For editors that work on a whole `ReviewSelection` (viewer, compare view).
    var binding: Binding<ReviewSelection> {
        Binding(
            get: { self.selection },
            set: { updated in
                self.touched.formUnion(updated.selected.symmetricDifference(self.selection.selected))
                self.selection = updated
            }
        )
    }
}
