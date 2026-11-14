import Foundation
import XCTest
@testable import StorageCleanerCore

final class TrashPlanTests: XCTestCase {
    private let photo = MediaItem.fixture("photo-1", bytes: 1_000)
    private let file = MediaItem(
        location: .file(URL(fileURLWithPath: "/tmp/clip.mov")),
        kind: .video,
        byteSize: 2_500
    )

    func testSummaryReflectsCountAndSize() {
        let plan = TrashPlan(items: [photo, file])
        XCTAssertEqual(plan.itemCount, 2)
        XCTAssertEqual(plan.totalBytes, 3_500)
        XCTAssertEqual(plan.summary.acknowledgedItemCount, 2)
        XCTAssertEqual(plan.summary.acknowledgedTotalBytes, 3_500)
    }

    func testDuplicateLocationsAreCollapsed() {
        let plan = TrashPlan(items: [photo, file, photo])
        XCTAssertEqual(plan.items, [photo, file])
        XCTAssertEqual(plan.totalBytes, 3_500)
    }

    func testSplitsBySource() {
        let plan = TrashPlan(items: [photo, file])
        XCTAssertEqual(plan.photoLibraryItems, [photo])
        XCTAssertEqual(plan.fileItems, [file])
    }

    func testConfirmWithMatchingSummarySucceeds() throws {
        let plan = TrashPlan(items: [photo, file])
        let confirmed = try plan.confirm(plan.summary)
        XCTAssertEqual(confirmed.plan, plan)
    }

    func testConfirmRejectsEmptyPlan() {
        let plan = TrashPlan(items: [])
        XCTAssertThrowsError(try plan.confirm(plan.summary)) { error in
            XCTAssertEqual(error as? TrashPlanError, .emptyPlan)
        }
    }

    func testConfirmRejectsStaleCount() {
        let shown = TrashPlan(items: [photo])
        let actual = TrashPlan(items: [photo, file])
        XCTAssertThrowsError(try actual.confirm(shown.summary)) { error in
            XCTAssertEqual(
                error as? TrashPlanError,
                .confirmationMismatch(
                    expectedCount: 2, expectedBytes: 3_500,
                    acknowledgedCount: 1, acknowledgedBytes: 1_000
                )
            )
        }
    }

    func testConfirmRejectsStaleSize() {
        var grown = photo
        grown.byteSize = 9_999
        let shown = TrashPlan(items: [photo])
        let actual = TrashPlan(items: [grown])
        XCTAssertThrowsError(try actual.confirm(shown.summary))
    }
}
