import Foundation

/// How readily a category calls items "Likely to delete".
public enum Strictness: String, Codable, CaseIterable, Sendable {
    /// Only very confident matches.
    case conservative
    case balanced
    /// Also less certain matches.
    case aggressive
}

/// User choices that guide the review split and pre-selection. Defaults reproduce the built-in
/// behavior: balanced thresholds, pre-selection on, no extra rules. Protected items are never
/// pre-selected whatever these say.
public struct ReviewPreferences: Codable, Equatable, Sendable {
    public var strictness: [CleanupCategory: Strictness] = [:]
    /// Categories whose "Likely to delete" items start selected. Missing means on.
    public var preselect: [CleanupCategory: Bool] = [:]
    /// "Always keep receipts newer than N months"; `nil` turns the rule off.
    public var keepReceiptsNewerThanMonths: Int?
    /// "Screenshots older than N days are likely to delete"; `nil` turns the rule off.
    public var screenshotsOlderThanDays: Int?

    public static let `default` = ReviewPreferences()

    public init() {}

    public func strictness(for category: CleanupCategory) -> Strictness { strictness[category] ?? .balanced }

    public func preselects(_ category: CleanupCategory) -> Bool { preselect[category] ?? true }

    /// Confidence needed for "Likely to delete".
    public func threshold(for category: CleanupCategory) -> Double {
        Self.threshold(for: category, strictness: strictness(for: category))
    }

    public static func threshold(for category: CleanupCategory, strictness: Strictness) -> Double {
        let balanced = ClassifierOptions.default.deleteThreshold(for: category)
        switch strictness {
        case .conservative: return min(0.95, balanced + 0.1)
        case .balanced: return balanced
        case .aggressive: return max(ClassifierOptions.default.minimumConfidence + 0.1, balanced - 0.15)
        }
    }
}
