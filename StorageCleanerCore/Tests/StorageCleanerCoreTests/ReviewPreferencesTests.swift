import Foundation
import XCTest
@testable import StorageCleanerCore

final class ReviewPreferencesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func item(_ name: String, daysAgo: Double = 10, favorite: Bool = false, shared: Bool = false) -> MediaItem {
        MediaItem(location: .file(URL(fileURLWithPath: "/m/\(name)")), kind: .photo, byteSize: 100, filename: name,
                  creationDate: now.addingTimeInterval(-daysAgo * day), isFavorite: favorite, isInSharedAlbum: shared)
    }

    private func reviews(_ entries: [(MediaItem, CleanupCategory, Double)],
                         _ preferences: ReviewPreferences = .default) -> [CleanupCategory: CategoryReview] {
        var classifications: [String: [Classification]] = [:]
        for (item, category, confidence) in entries {
            classifications[item.location.indexKey, default: []].append(
                Classification(category: category, confidence: confidence, reasons: []))
        }
        let built = CategoryReview.build(items: entries.map(\.0), classifications: classifications,
                                         preferences: preferences, now: now)
        return Dictionary(uniqueKeysWithValues: built.map { ($0.category, $0) })
    }

    func testDefaultsPreselectLikelyToDeleteInEveryCategory() {
        let entries = CleanupCategory.allCases.filter { $0 != .duplicates && $0 != .largeFiles }.map {
            (item("\($0.rawValue)"), $0, 0.99)
        }
        XCTAssertFalse(entries.isEmpty)
        for (item, category, _) in entries {
            let review = reviews(entries)[category]
            XCTAssertEqual(review?.preselectedItems, [item], "\(category)")
            XCTAssertEqual(review?.likelyToDelete.first?.verdict,
                           .likelyDelete(.confident(threshold: ReviewPreferences.default.threshold(for: category))))
        }
    }

    func testStrictnessMovesTheThreshold() {
        let receipt = item("r")
        let conservative = ReviewPreferences.threshold(for: .receipts, strictness: .conservative)
        let balanced = ReviewPreferences.threshold(for: .receipts, strictness: .balanced)
        let aggressive = ReviewPreferences.threshold(for: .receipts, strictness: .aggressive)
        XCTAssertGreaterThan(conservative, balanced)
        XCTAssertGreaterThan(balanced, aggressive)
        XCTAssertGreaterThan(aggressive, ClassifierOptions.default.minimumConfidence)

        let confidence = (balanced + aggressive) / 2
        XCTAssertEqual(reviews([(receipt, .receipts, confidence)])[.receipts]?.likelyToKeep.first?.verdict,
                       .likelyKeep(.belowThreshold(threshold: balanced)))

        var preferences = ReviewPreferences()
        preferences.strictness[.receipts] = .aggressive
        XCTAssertEqual(reviews([(receipt, .receipts, confidence)], preferences)[.receipts]?.preselectedItems, [receipt])
    }

    func testPreselectToggleKeepsTheSplitButSelectsNothing() {
        let shot = item("s")
        var preferences = ReviewPreferences()
        preferences.preselect[.screenshots] = false
        let review = reviews([(shot, .screenshots, 0.99)], preferences)[.screenshots]
        XCTAssertEqual(review?.likelyToDelete.map(\.item), [shot])
        XCTAssertEqual(review?.preselectedItems, [])
    }

    func testRecentReceiptsAreAlwaysKept() {
        let recent = item("recent", daysAgo: 40), old = item("old", daysAgo: 200)
        var preferences = ReviewPreferences()
        preferences.keepReceiptsNewerThanMonths = 3
        let review = reviews([(recent, .receipts, 0.99), (old, .receipts, 0.99)], preferences)[.receipts]
        XCTAssertEqual(review?.likelyToKeep.map(\.item), [recent])
        XCTAssertEqual(review?.likelyToKeep.first?.verdict, .likelyKeep(.recentReceipt(months: 3)))
        XCTAssertEqual(review?.preselectedItems, [old])
    }

    func testOldScreenshotsAreLikelyToDeleteEvenWhenUnsure() {
        let old = item("old", daysAgo: 60), recent = item("recent", daysAgo: 5)
        var preferences = ReviewPreferences()
        preferences.screenshotsOlderThanDays = 30
        let review = reviews([(old, .screenshots, 0.5), (recent, .screenshots, 0.5)], preferences)[.screenshots]
        XCTAssertEqual(review?.likelyToDelete.first?.verdict, .likelyDelete(.oldScreenshot(days: 30)))
        XCTAssertEqual(review?.preselectedItems, [old])
        XCTAssertEqual(review?.likelyToKeep.map(\.item), [recent])
    }

    func testProtectedItemsAreNeverPreselectedWhateverTheRules() {
        let favorite = item("f", daysAgo: 400, favorite: true), shared = item("s", daysAgo: 400, shared: true)
        var preferences = ReviewPreferences()
        preferences.strictness[.screenshots] = .aggressive
        preferences.screenshotsOlderThanDays = 7
        let review = reviews([(favorite, .screenshots, 0.99), (shared, .screenshots, 0.99)], preferences)[.screenshots]
        XCTAssertEqual(review?.likelyToDelete, [])
        XCTAssertEqual(review?.preselectedItems, [])
        XCTAssertEqual(Set(review?.likelyToKeep.map(\.verdict) ?? []), [.likelyKeep(.protected)])
    }

    func testRebuildingAnOutcomeAndPruningIt() {
        let a = item("a"), b = item("b")
        let outcome = ClassificationOutcome(items: [a, b], classifications: [
            a.location.indexKey: [Classification(category: .screenshots, confidence: 0.82, reasons: [])],
            b.location.indexKey: [Classification(category: .screenshots, confidence: 0.82, reasons: [])],
        ])
        var conservative = ReviewPreferences()
        conservative.strictness[.screenshots] = .conservative
        XCTAssertEqual(outcome.reviews(preferences: .default, now: now).first?.likelyToDelete.count, 2)
        XCTAssertEqual(outcome.reviews(preferences: conservative, now: now).first?.likelyToDelete.count, 0)

        let pruned = outcome.removing([a.location])
        XCTAssertEqual(pruned.items, [b])
        XCTAssertEqual(Array(pruned.classifications.keys), [b.location.indexKey])
    }

    func testPreferencesRoundTripThroughJSON() throws {
        var preferences = ReviewPreferences()
        preferences.strictness[.chatForwards] = .conservative
        preferences.preselect[.lowQuality] = false
        preferences.keepReceiptsNewerThanMonths = 6
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(ReviewPreferences.self, from: data), preferences)
    }
}
