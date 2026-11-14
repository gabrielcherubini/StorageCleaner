import Foundation
import StorageCleanerCore

/// Brings one scope of the index in line with a fresh scan, re-reading details only for items that
/// are new or whose fingerprint changed.
struct IndexUpdater: Sendable {
    let store: MediaIndexStore
    var batchSize = 500

    /// - Parameters:
    ///   - current: Fingerprints for everything the scan found in `scope`.
    ///   - details: Reads full details for a batch of keys. Called only for new or changed keys.
    ///   - progress: Reports `(done, total)` over the keys that need refreshing.
    @discardableResult
    func apply(
        current: [String: ScanFingerprint],
        to scope: IndexScope,
        details: @Sendable ([String]) async throws -> [ScannedItem],
        progress: @Sendable (_ done: Int, _ total: Int) async -> Void = { _, _ in }
    ) async throws -> ReconcilePlan {
        let existing = try await store.fingerprints(in: scope)
        let plan = IndexReconciler.plan(existing: existing, current: current)
        try await store.dropRows(forKeys: plan.removed)

        let refresh = plan.needsRefresh
        var done = 0
        await progress(0, refresh.count)
        for chunk in refresh.chunked(into: batchSize) {
            try Task.checkCancellation()
            try await store.upsert(try await details(chunk), in: scope)
            done += chunk.count
            await progress(done, refresh.count)
        }
        return plan
    }

    /// For scanners that read everything in one pass, such as folder scans.
    @discardableResult
    func apply(
        scanned: [ScannedItem],
        to scope: IndexScope,
        progress: @Sendable (_ done: Int, _ total: Int) async -> Void = { _, _ in }
    ) async throws -> ReconcilePlan {
        let byKey = Dictionary(scanned.map { ($0.indexKey, $0) }, uniquingKeysWith: { first, _ in first })
        return try await apply(
            current: byKey.mapValues(\.fingerprint),
            to: scope,
            details: { keys in keys.compactMap { byKey[$0] } },
            progress: progress
        )
    }
}
