import Foundation

/// A proposed set of items to move to Recently Deleted / Trash, as shown on the final confirm sheet.
///
/// A plan does nothing on its own. It must be turned into a `ConfirmedTrashPlan` with a
/// `TrashConfirmation` that echoes exactly what the user saw, and only `TrashService` in the app
/// accepts a `ConfirmedTrashPlan`.
public struct TrashPlan: Equatable, Sendable {
    public let items: [MediaItem]

    /// Duplicate locations are dropped, keeping the first occurrence.
    public init(items: [MediaItem]) {
        var seen = Set<MediaLocation>()
        self.items = items.filter { seen.insert($0.location).inserted }
    }

    public var itemCount: Int { items.count }
    public var totalBytes: Int64 { items.totalByteSize }
    public var isEmpty: Bool { items.isEmpty }

    public var photoLibraryItems: [MediaItem] {
        items.filter { if case .photoLibrary = $0.location { return true } else { return false } }
    }

    public var fileItems: [MediaItem] {
        items.filter { if case .file = $0.location { return true } else { return false } }
    }

    /// What the confirm sheet must display; feed it back into `confirm(_:)` once the user agrees.
    public var summary: TrashConfirmation {
        TrashConfirmation(acknowledgedItemCount: itemCount, acknowledgedTotalBytes: totalBytes)
    }

    public func confirm(_ confirmation: TrashConfirmation) throws -> ConfirmedTrashPlan {
        guard !isEmpty else { throw TrashPlanError.emptyPlan }
        guard confirmation.acknowledgedItemCount == itemCount,
              confirmation.acknowledgedTotalBytes == totalBytes
        else {
            throw TrashPlanError.confirmationMismatch(
                expectedCount: itemCount,
                expectedBytes: totalBytes,
                acknowledgedCount: confirmation.acknowledgedItemCount,
                acknowledgedBytes: confirmation.acknowledgedTotalBytes
            )
        }
        return ConfirmedTrashPlan(plan: self, confirmation: confirmation)
    }
}

/// The user's explicit acknowledgement of the count and size shown on the confirm sheet.
public struct TrashConfirmation: Equatable, Sendable {
    public let acknowledgedItemCount: Int
    public let acknowledgedTotalBytes: Int64
    public let confirmedAt: Date

    public init(acknowledgedItemCount: Int, acknowledgedTotalBytes: Int64, confirmedAt: Date = Date()) {
        self.acknowledgedItemCount = acknowledgedItemCount
        self.acknowledgedTotalBytes = acknowledgedTotalBytes
        self.confirmedAt = confirmedAt
    }

    public static func == (lhs: TrashConfirmation, rhs: TrashConfirmation) -> Bool {
        lhs.acknowledgedItemCount == rhs.acknowledgedItemCount
            && lhs.acknowledgedTotalBytes == rhs.acknowledgedTotalBytes
    }
}

/// A plan the user has explicitly confirmed. It can only be created through `TrashPlan.confirm(_:)`.
public struct ConfirmedTrashPlan: Sendable {
    public let plan: TrashPlan
    public let confirmation: TrashConfirmation

    init(plan: TrashPlan, confirmation: TrashConfirmation) {
        self.plan = plan
        self.confirmation = confirmation
    }
}

public enum TrashPlanError: Error, Equatable, Sendable {
    case emptyPlan
    case confirmationMismatch(
        expectedCount: Int,
        expectedBytes: Int64,
        acknowledgedCount: Int,
        acknowledgedBytes: Int64
    )
}
