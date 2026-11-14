import Foundation
import StorageCleanerCore

/// The optional local decision log: a JSON array of `DecisionLogEntry` in Application Support.
/// It records what was moved and why; it never touches media.
struct DecisionLogStore: Sendable {
    let url: URL

    static var standard: DecisionLogStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DecisionLogStore(url: base.appendingPathComponent("StorageCleaner", isDirectory: true)
            .appendingPathComponent("decision-log.json"))
    }

    func append(_ entry: DecisionLogEntry) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        try DecisionLog.appending(entry, to: existing).write(to: url, options: .atomic)
    }

    func entries() throws -> [DecisionLogEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try DecisionLog.decoder().decode([DecisionLogEntry].self, from: Data(contentsOf: url))
    }
}
