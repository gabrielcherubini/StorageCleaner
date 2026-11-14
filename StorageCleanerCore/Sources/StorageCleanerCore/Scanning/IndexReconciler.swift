import Foundation

/// The cheap facts a scanner can read without opening an item, used to decide whether an indexed
/// item must be re-read on the next scan.
public struct ScanFingerprint: Hashable, Codable, Sendable {
    public var byteSize: Int64?
    public var modificationDate: Date?

    public init(byteSize: Int64? = nil, modificationDate: Date? = nil) {
        self.byteSize = byteSize
        self.modificationDate = modificationDate
    }

    /// Dates are compared with millisecond tolerance because stores round-trip them as doubles.
    public func matches(_ other: ScanFingerprint) -> Bool {
        guard byteSize == other.byteSize else { return false }
        switch (modificationDate, other.modificationDate) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.timeIntervalSince(rhs)) < 0.001
        default:
            return false
        }
    }
}

public struct ReconcilePlan: Equatable, Sendable {
    /// Keys seen for the first time.
    public var added: [String]
    /// Keys whose fingerprint changed since the last scan.
    public var changed: [String]
    /// Keys that can keep their indexed data as is.
    public var unchanged: [String]
    /// Keys in the index that the scan no longer found; their index rows should be dropped.
    public var removed: [String]

    /// Keys whose details must be (re)read.
    public var needsRefresh: [String] { added + changed }
}

public enum IndexReconciler {
    /// Compares what the index holds for one scan scope (the photo library, or one folder) with what
    /// a fresh scan of that same scope found. All outputs are sorted for deterministic processing.
    public static func plan(
        existing: [String: ScanFingerprint],
        current: [String: ScanFingerprint]
    ) -> ReconcilePlan {
        var added: [String] = []
        var changed: [String] = []
        var unchanged: [String] = []

        for (key, fingerprint) in current {
            if let previous = existing[key] {
                if previous.matches(fingerprint) {
                    unchanged.append(key)
                } else {
                    changed.append(key)
                }
            } else {
                added.append(key)
            }
        }
        let removed = existing.keys.filter { current[$0] == nil }

        return ReconcilePlan(
            added: added.sorted(),
            changed: changed.sorted(),
            unchanged: unchanged.sorted(),
            removed: removed.sorted()
        )
    }
}
