import XCTest
@testable import Plans

/// Regression tests for #040 ("Clicking the eye icon crashes the app"): the card
/// grid's pure index helpers must never emit an index outside `0..<count`. The
/// crash was a stale-index race where `sortedProjects` shrank (the project view
/// mode filters it) while a `ForEach` re-evaluated cached indices against the
/// smaller array. The view-level fix snapshots `sortedProjects` and bounds-guards
/// each subscript; these tests pin the contract of the underlying pure helpers —
/// every index they emit is in range, and together the emitted indices cover
/// exactly `0..<count` (no gaps, no duplicates) — so the snapshot the views index
/// is always indexed by valid offsets. No SwiftUI views are instantiated here,
/// mirroring `BrowserWindowTests`.
final class BrowserGridIndexBoundsTests: XCTestCase {

    /// Counts (incl. the empty grid) and column counts to sweep.
    private let counts = Array(0...12)
    private let columnRange = 1...5

    func testRowIndicesNeverOutOfBounds() {
        for count in counts {
            for columns in columnRange {
                let rows = BrowserWindow.rowIndices(count: count, columns: columns)
                for index in rows.flatMap({ $0 }) {
                    XCTAssertGreaterThanOrEqual(
                        index, 0,
                        "rowIndices(count: \(count), columns: \(columns)) emitted negative index \(index)"
                    )
                    XCTAssertLessThan(
                        index, count,
                        "rowIndices(count: \(count), columns: \(columns)) emitted out-of-range index \(index)"
                    )
                }
            }
        }
    }

    func testRowIndicesCoverExactlyZeroToCount() {
        for count in counts {
            for columns in columnRange {
                let emitted = BrowserWindow.rowIndices(count: count, columns: columns).flatMap { $0 }
                XCTAssertEqual(
                    emitted.sorted(), Array(0..<count),
                    "rowIndices(count: \(count), columns: \(columns)) must cover 0..<\(count) with no gaps or dupes"
                )
            }
        }
    }

    func testColumnAssignmentsNeverOutOfBounds() {
        for count in counts {
            for columns in columnRange {
                let assignments = BrowserWindow.columnAssignments(count: count, columns: columns)
                for index in assignments.flatMap({ $0 }) {
                    XCTAssertGreaterThanOrEqual(
                        index, 0,
                        "columnAssignments(count: \(count), columns: \(columns)) emitted negative index \(index)"
                    )
                    XCTAssertLessThan(
                        index, count,
                        "columnAssignments(count: \(count), columns: \(columns)) emitted out-of-range index \(index)"
                    )
                }
            }
        }
    }

    func testColumnAssignmentsCoverExactlyZeroToCount() {
        for count in counts {
            for columns in columnRange {
                let emitted = BrowserWindow.columnAssignments(count: count, columns: columns).flatMap { $0 }
                XCTAssertEqual(
                    emitted.sorted(), Array(0..<count),
                    "columnAssignments(count: \(count), columns: \(columns)) must cover 0..<\(count) with no gaps or dupes"
                )
            }
        }
    }
}
