import Foundation
import XCTest
@testable import StorageCleanerCore

final class ReviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func item(_ name: String, bytes: Int64, daysAgo: Double? = nil, kind: MediaKind = .photo,
                      favorite: Bool = false, shared: Bool = false, edited: Bool = false) -> MediaItem {
        MediaItem(location: .file(URL(fileURLWithPath: "/m/\(name)")), kind: kind, byteSize: bytes, filename: name,
                  creationDate: daysAgo.map { now.addingTimeInterval(-$0 * day) },
                  isFavorite: favorite, isInSharedAlbum: shared, isEdited: edited)
    }

    // MARK: Selection

    func testPreselectionAndBulkSelectionSkipProtectedItems() {
        let plain = item("a", bytes: 1)
        let favorite = item("b", bytes: 2, favorite: true)
        let shared = item("c", bytes: 3, shared: true)
        let edited = item("d", bytes: 4, edited: true)
        let all = [plain, favorite, shared, edited]

        var selection = ReviewSelection(preselected: all)
        XCTAssertEqual(selection.selected, [plain.location])

        selection.deselectAll(all)
        XCTAssertEqual(selection.selectAll(all), 3)
        XCTAssertEqual(selection.selected, [plain.location])
    }

    func testPerItemOverrideCanSelectProtectedAndDeselectSuggested() {
        let plain = item("a", bytes: 1)
        let favorite = item("b", bytes: 2, favorite: true)
        var selection = ReviewSelection(preselected: [plain, favorite])

        selection.toggle(plain)
        selection.toggle(favorite)

        XCTAssertFalse(selection.isSelected(plain))
        XCTAssertTrue(selection.isSelected(favorite))
    }

    func testPlanKeepsOrderAndOnlySelectedItems() throws {
        let a = item("a", bytes: 10), b = item("b", bytes: 20), c = item("c", bytes: 30)
        var selection = ReviewSelection(preselected: [c, a])
        selection.toggle(b)

        let plan = selection.plan(from: [a, b, c])

        XCTAssertEqual(plan.items, [a, b, c])
        XCTAssertEqual(plan.summary.acknowledgedItemCount, 3)
        XCTAssertEqual(plan.summary.acknowledgedTotalBytes, 60)
        XCTAssertNoThrow(try plan.confirm(plan.summary))
        XCTAssertTrue(ReviewSelection().plan(from: [a]).isEmpty)
    }

    // MARK: Filters

    func testSizeDateAndKindFilters() {
        let small = item("small", bytes: 500_000, daysAgo: 2)
        let recentBig = item("recentBig", bytes: 60_000_000, daysAgo: 10)
        let oldBig = item("oldBig", bytes: 200_000_000, daysAgo: 800)
        let undated = item("undated", bytes: 70_000_000)
        let song = item("song", bytes: 80_000_000, daysAgo: 1_500, kind: .audio)
        let all = [small, recentBig, oldBig, undated, song]

        var filter = ReviewFilter()
        XCTAssertFalse(filter.isActive)
        filter.size = .atLeast50MB
        XCTAssertEqual(filter.apply(to: all, now: now), [oldBig, song, undated, recentBig])

        filter.date = .olderThanOneYear
        XCTAssertEqual(filter.apply(to: all, now: now), [oldBig, song])

        filter.kinds = [.photo]
        XCTAssertEqual(filter.apply(to: all, now: now), [oldBig])

        filter = ReviewFilter()
        filter.date = .lastMonth
        XCTAssertEqual(Set(filter.apply(to: all, now: now)), [small, recentBig])
        XCTAssertTrue(filter.isActive)
    }

    func testSortByDatePutsUndatedLast() {
        let old = item("old", bytes: 1, daysAgo: 100), new = item("new", bytes: 1, daysAgo: 1), undated = item("u", bytes: 9)
        var filter = ReviewFilter()
        filter.sort = .newestFirst
        XCTAssertEqual(filter.apply(to: [old, undated, new], now: now), [new, old, undated])
        filter.sort = .oldestFirst
        XCTAssertEqual(filter.apply(to: [old, undated, new], now: now), [old, new, undated])
    }

    // MARK: Pruning

    func testPruningResultsAfterTrashing() throws {
        let keeper = item("k", bytes: 10, daysAgo: 30), copy = item("c", bytes: 10, daysAgo: 1), copy2 = item("c2", bytes: 10, daysAgo: 2)
        let group = try XCTUnwrap(DuplicateGroup(match: .exact, items: [keeper, copy, copy2], similarity: 1))

        XCTAssertEqual(group.removing([copy.location])?.items, [keeper, copy2])
        XCTAssertNil(group.removing([copy.location, copy2.location]))

        let classification = Classification(category: .screenshots, confidence: 0.99, reasons: [.screenshotFlag])
        let review = CategoryReview(
            category: .screenshots,
            likelyToDelete: [ClassifiedItem(item: copy, classification: classification,
                                           verdict: .likelyDelete(.confident(threshold: 0.8)), isPreselected: true)],
            likelyToKeep: [ClassifiedItem(item: keeper, classification: classification,
                                         verdict: .likelyKeep(.belowThreshold(threshold: 0.8)), isPreselected: false)]
        )
        XCTAssertEqual(review.removing([copy.location])?.likelyToKeep.map(\.item), [keeper])
        XCTAssertNil(review.removing([copy.location, keeper.location]))
    }

    func testDetectsSelectionOfEveryCopy() throws {
        let a = item("a", bytes: 1, daysAgo: 5), b = item("b", bytes: 1, daysAgo: 1)
        let group = try XCTUnwrap(DuplicateGroup(match: .exact, items: [a, b], similarity: 1))
        var selection = ReviewSelection(preselected: group.suggestedForRemoval)
        XCTAssertFalse(group.selectsEveryCopy(selection))
        selection.toggle(group.keeper)
        XCTAssertTrue(group.selectsEveryCopy(selection))
    }

    // MARK: Decision log

    func testDecisionLogAppendsAndRoundTrips() throws {
        let photo = item("a.jpg", bytes: 100)
        let entry = DecisionLogEntry(
            date: now, confirmedCount: 2, confirmedBytes: 300,
            items: [
                .init(item: photo, destination: .trash,
                      reason: .category(Classification(category: .lowQuality, confidence: 0.8, reasons: [.blurry]))),
                .init(item: item("b.mov", bytes: 200, kind: .video), destination: .notMoved, reason: .largeFile, error: "denied"),
            ]
        )

        let first = try DecisionLog.appending(entry, to: nil)
        let second = try DecisionLog.appending(entry, to: first)
        let decoded = try DecisionLog.decoder().decode([DecisionLogEntry].self, from: second)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0], entry)
        XCTAssertEqual(decoded[0].movedBytes, 100)
        XCTAssertEqual(decoded[0].items[0].reason?.details, ["blurry"])
        XCTAssertThrowsError(try DecisionLog.appending(entry, to: Data("not json".utf8)))
    }
}
