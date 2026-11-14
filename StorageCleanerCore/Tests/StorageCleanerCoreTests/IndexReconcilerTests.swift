import Foundation
import XCTest
@testable import StorageCleanerCore

final class IndexReconcilerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testClassifiesAddedChangedUnchangedRemoved() {
        let existing: [String: ScanFingerprint] = [
            "same": .init(byteSize: 10, modificationDate: t0),
            "resized": .init(byteSize: 10, modificationDate: t0),
            "touched": .init(byteSize: 10, modificationDate: t0),
            "gone": .init(byteSize: 10, modificationDate: t0),
        ]
        let current: [String: ScanFingerprint] = [
            "same": .init(byteSize: 10, modificationDate: t0),
            "resized": .init(byteSize: 11, modificationDate: t0),
            "touched": .init(byteSize: 10, modificationDate: t0.addingTimeInterval(5)),
            "new": .init(byteSize: 1, modificationDate: t0),
        ]

        let plan = IndexReconciler.plan(existing: existing, current: current)

        XCTAssertEqual(plan.added, ["new"])
        XCTAssertEqual(plan.changed, ["resized", "touched"])
        XCTAssertEqual(plan.unchanged, ["same"])
        XCTAssertEqual(plan.removed, ["gone"])
        XCTAssertEqual(plan.needsRefresh, ["new", "resized", "touched"])
    }

    func testFirstScanRefreshesEverything() {
        let plan = IndexReconciler.plan(existing: [:], current: ["a": .init(), "b": .init()])
        XCTAssertEqual(plan.added, ["a", "b"])
        XCTAssertTrue(plan.removed.isEmpty)
    }

    func testEmptyScanRemovesEverything() {
        let plan = IndexReconciler.plan(existing: ["a": .init(), "b": .init()], current: [:])
        XCTAssertEqual(plan.removed, ["a", "b"])
        XCTAssertTrue(plan.needsRefresh.isEmpty)
    }

    func testDateToleranceAbsorbsStoreRounding() {
        let a = ScanFingerprint(byteSize: nil, modificationDate: t0)
        XCTAssertTrue(a.matches(.init(byteSize: nil, modificationDate: t0.addingTimeInterval(0.0004))))
        XCTAssertFalse(a.matches(.init(byteSize: nil, modificationDate: t0.addingTimeInterval(0.01))))
        XCTAssertFalse(a.matches(.init(byteSize: nil, modificationDate: nil)))
        XCTAssertTrue(ScanFingerprint().matches(ScanFingerprint()))
    }
}
