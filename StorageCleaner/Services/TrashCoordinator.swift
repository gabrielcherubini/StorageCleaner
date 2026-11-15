import Foundation
import Observation
import StorageCleanerCore

/// Runs a confirmed trash action from a review screen: hands the plan to `TrashService` (with the
/// folder security scopes for iCloud Drive files), drops moved items from the index and results,
/// and appends to the decision log when the user turned it on.
@MainActor
@Observable
final class TrashCoordinator {
    struct Outcome: Identifiable, Sendable {
        let id = UUID()
        let result: TrashResult
        let confirmedCount: Int
        let confirmedBytes: Int64
        let logURL: URL?
        let logError: String?

        var recentlyDeletedCount: Int { result.moved.filter { $0.destination == .recentlyDeleted }.count }
        var trashCount: Int { result.moved.count - recentlyDeletedCount }
    }

    private(set) var isTrashing = false
    @ObservationIgnored private let scanner: ScanCoordinator
    @ObservationIgnored private let service: TrashService
    @ObservationIgnored private let log: DecisionLogStore

    init(scanner: ScanCoordinator, service: TrashService = TrashService(), log: DecisionLogStore = .standard) {
        self.scanner = scanner
        self.service = service
        self.log = log
    }

    /// `confirmation` must echo the count and size the confirm sheet showed; a mismatch moves
    /// nothing.
    func moveToTrash(
        _ plan: TrashPlan,
        confirmation: TrashConfirmation,
        reasons: [MediaLocation: DecisionReason]
    ) async -> Outcome? {
        guard !isTrashing, !scanner.isScanning else { return nil }
        let confirmed: ConfirmedTrashPlan
        do {
            confirmed = try plan.confirm(confirmation)
        } catch {
            scanner.report(error: "Nothing was moved: the selection changed before it was confirmed.")
            return nil
        }

        isTrashing = true
        defer { isTrashing = false }

        let access: FolderAccess
        do {
            access = try await FolderAccess.load(store: scanner.store)
        } catch {
            scanner.report(error: "Nothing was moved: \(error.localizedDescription)")
            return nil
        }
        let result = await service.moveToTrash(confirmed, fileAccess: access)

        let moved = result.moved.map(\.item)
        do {
            try await scanner.store.dropRows(forKeys: moved.map(\.location.indexKey))
        } catch {
            scanner.report(error: "Moved items may still be listed until the next scan: \(error.localizedDescription)")
        }
        await scanner.removeTrashed(Set(moved.map(\.location)))

        var logURL: URL?, logError: String?
        if scanner.keepsDecisionLog {
            let entry = Self.logEntry(for: result, confirmation: confirmation, reasons: reasons)
            do {
                try log.append(entry)
                logURL = log.url
            } catch {
                logError = error.localizedDescription
            }
        }
        return Outcome(result: result, confirmedCount: confirmation.acknowledgedItemCount,
                       confirmedBytes: confirmation.acknowledgedTotalBytes, logURL: logURL, logError: logError)
    }

    static func logEntry(for result: TrashResult, confirmation: TrashConfirmation,
                         reasons: [MediaLocation: DecisionReason]) -> DecisionLogEntry {
        let moved = result.moved.map { moved -> DecisionLogEntry.Item in
            let destination: DecisionLogEntry.Destination = moved.destination == .recentlyDeleted ? .recentlyDeleted : .trash
            return .init(item: moved.item, destination: destination, reason: reasons[moved.item.location])
        }
        let failed = result.failures.map { failure -> DecisionLogEntry.Item in
            let message: String
            switch failure.reason {
            case .notFound: message = "not found"
            case let .systemError(text): message = text
            }
            return .init(item: failure.item, destination: .notMoved, reason: reasons[failure.item.location], error: message)
        }
        return DecisionLogEntry(date: confirmation.confirmedAt, confirmedCount: confirmation.acknowledgedItemCount,
                                confirmedBytes: confirmation.acknowledgedTotalBytes, items: moved + failed)
    }
}
