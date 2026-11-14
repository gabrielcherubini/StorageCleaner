import Foundation

/// Why an item was in the confirm sheet, for the optional decision log.
public struct DecisionReason: Codable, Hashable, Sendable {
    /// `duplicates`, a `CleanupCategory` raw value, or `largeFiles`.
    public var source: String
    public var confidence: Double?
    public var details: [String]

    public init(source: String, confidence: Double? = nil, details: [String] = []) {
        self.source = source
        self.confidence = confidence
        self.details = details
    }

    public static func category(_ classification: Classification) -> DecisionReason {
        DecisionReason(source: classification.category.rawValue, confidence: classification.confidence,
                       details: classification.reasons.map(\.rawValue))
    }

    public static func duplicate(of group: DuplicateGroup) -> DecisionReason {
        DecisionReason(source: CleanupCategory.duplicates.rawValue, confidence: group.similarity,
                       details: ["\(group.match.rawValue)", "keeper: \(group.keeper.filename ?? group.keeper.location.indexKey)"])
    }

    public static let largeFile = DecisionReason(source: CleanupCategory.largeFiles.rawValue)
}

/// One confirmed trash action: what was moved where and why. Kept locally only when the user
/// turns the decision log on.
public struct DecisionLogEntry: Codable, Equatable, Sendable {
    public enum Destination: String, Codable, Sendable {
        case recentlyDeleted
        case trash
        case notMoved
    }

    public struct Item: Codable, Equatable, Sendable {
        public var key: String
        public var filename: String?
        public var kind: MediaKind
        public var byteSize: Int64
        public var destination: Destination
        public var reason: DecisionReason?
        public var error: String?

        public init(item: MediaItem, destination: Destination, reason: DecisionReason?, error: String? = nil) {
            key = item.location.indexKey
            filename = item.filename
            kind = item.kind
            byteSize = item.byteSize
            self.destination = destination
            self.reason = reason
            self.error = error
        }
    }

    public var id: UUID
    public var date: Date
    /// What the confirm sheet showed and the user accepted.
    public var confirmedCount: Int
    public var confirmedBytes: Int64
    public var items: [Item]

    public init(id: UUID = UUID(), date: Date = Date(), confirmedCount: Int, confirmedBytes: Int64, items: [Item]) {
        self.id = id
        self.date = date
        self.confirmedCount = confirmedCount
        self.confirmedBytes = confirmedBytes
        self.items = items
    }

    public var movedBytes: Int64 {
        items.filter { $0.destination != .notMoved }.reduce(0) { $0 + $1.byteSize }
    }
}

public enum DecisionLog {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Appends `entry` to an existing log (a JSON array). An unreadable log is not discarded: the
    /// call throws so the caller can keep it and report the problem.
    public static func appending(_ entry: DecisionLogEntry, to existing: Data?) throws -> Data {
        var entries: [DecisionLogEntry] = []
        if let existing, !existing.isEmpty {
            entries = try decoder().decode([DecisionLogEntry].self, from: existing)
        }
        entries.append(entry)
        return try encoder().encode(entries)
    }
}
