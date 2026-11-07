import XCTest
@testable import Plans

/// #098: tests for the shared pure helper `BrowserViewModel.statusCounts(_:)`, the
/// single source of truth for the per-status count badges shown both in a project
/// card's header and in the single-project `TaskListView` control bar. Asserts
/// plain values only — no SwiftUI views are instantiated, mirroring
/// `BrowserWindowTests` / `TaskStatusGlanceTests`.
final class BrowserViewModelStatusCountsTests: XCTestCase {

    /// Builds a `ProjectTasks` fixture carrying only the `counts` the helper reads.
    private func makeProject(counts: [TaskStatus: Int]) -> ProjectTasks {
        ProjectTasks(
            projectPath: "/tmp/example",
            projectName: "Example",
            lastSeen: "",
            tasks: [],
            counts: counts,
            activeTasks: [],
            backloggedTasks: []
        )
    }

    /// EVERY status in `glanceOrder` surfaces as an entry — none are dropped — even
    /// when the project supplies a sparse `counts` dictionary.
    func testEveryGlanceOrderStatusAppears() {
        let project = makeProject(counts: [.inProgress: 3])
        let entries = BrowserViewModel.statusCounts(project)

        XCTAssertEqual(entries.map(\.status), TaskStatus.glanceOrder)
    }

    /// Statuses absent from `counts` (and those explicitly `0`) surface as `0`
    /// rather than being omitted.
    func testAbsentAndZeroStatusesSurfaceAsZero() {
        let project = makeProject(counts: [.pending: 2, .review: 0])
        let entries = BrowserViewModel.statusCounts(project)
        let byStatus = Dictionary(uniqueKeysWithValues: entries.map { ($0.status, $0.count) })

        XCTAssertEqual(byStatus[.pending], 2)
        XCTAssertEqual(byStatus[.review], 0)        // explicit zero preserved
        XCTAssertEqual(byStatus[.elaborated], 0)    // absent -> zero
        XCTAssertEqual(byStatus[.inProgress], 0)    // absent -> zero
        XCTAssertEqual(byStatus[.inReview], 0)      // absent -> zero
    }

    /// The entries come back in `glanceOrder`, not in dictionary iteration order.
    func testOrderMatchesGlanceOrder() {
        let project = makeProject(counts: [
            .inReview: 1,
            .pending: 5,
            .review: 4,
            .inProgress: 3,
            .elaborated: 2,
        ])
        let entries = BrowserViewModel.statusCounts(project)

        XCTAssertEqual(entries.map(\.status), TaskStatus.glanceOrder)
        XCTAssertEqual(entries.map(\.count), [5, 2, 3, 4, 1])
    }
}
