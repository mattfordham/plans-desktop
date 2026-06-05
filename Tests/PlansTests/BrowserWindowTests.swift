import XCTest
@testable import Plans

/// Tests for the browser's pure view-model helpers (`BrowserViewModel`) and the
/// `TaskType` badge mapping. These assert plain values only — no SwiftUI views
/// are instantiated, mirroring `TaskStatusGlanceTests` and `PlansStoreTests`.
final class BrowserWindowTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a minimal `Task` via the memberwise initializer. Only the fields a
    /// given test cares about need to be set; the rest take inert defaults.
    private func makeTask(
        id: String,
        title: String? = nil,
        type: TaskType? = nil,
        status: TaskStatus? = nil,
        isBlocked: Bool = false
    ) -> Task {
        Task(
            id: id,
            title: title,
            type: type,
            status: status,
            created: nil,
            branch: nil,
            blockedBy: [],
            sections: [],
            howProgress: (done: 0, total: 0),
            isBlocked: isBlocked,
            isCompletedDir: false
        )
    }

    /// Builds a `ProjectTasks` fixture directly with empty count/active sets.
    private func makeProject(
        path: String,
        name: String,
        lastSeen: String = "",
        tasks: [Task] = []
    ) -> ProjectTasks {
        ProjectTasks(
            projectPath: path,
            projectName: name,
            lastSeen: lastSeen,
            tasks: tasks,
            counts: [:],
            activeTasks: []
        )
    }

    // MARK: - (a) TaskType glyph + label totality

    func testBugGlyphAndLabel() {
        XCTAssertEqual(TaskType.bug.glyph, "🐞")
        XCTAssertEqual(TaskType.bug.label, "bug")
    }

    func testFeatureGlyphAndLabel() {
        XCTAssertEqual(TaskType.feature.glyph, "✨")
        XCTAssertEqual(TaskType.feature.label, "feature")
    }

    func testRefactorGlyphAndLabel() {
        XCTAssertEqual(TaskType.refactor.glyph, "♻️")
        XCTAssertEqual(TaskType.refactor.label, "refactor")
    }

    func testChoreGlyphAndLabel() {
        XCTAssertEqual(TaskType.chore.glyph, "🔧")
        XCTAssertEqual(TaskType.chore.label, "chore")
    }

    /// Every case maps to a non-empty glyph and label — totality guard.
    func testGlyphAndLabelTotalAcrossAllCases() {
        for type in TaskType.allCases {
            XCTAssertFalse(type.glyph.isEmpty, "empty glyph for \(type)")
            XCTAssertFalse(type.label.isEmpty, "empty label for \(type)")
        }
    }

    // MARK: - Status glyph mapping (matches plans-cc TUI `glyphFor`)

    /// The per-status glyph must match the plans-cc TUI dashboard `glyphFor`
    /// verbatim so the desktop reads identically to the terminal.
    func testStatusGlanceGlyphsMatchTUI() {
        XCTAssertEqual(TaskStatus.pending.glanceGlyph, "·")
        XCTAssertEqual(TaskStatus.elaborated.glanceGlyph, "○")
        XCTAssertEqual(TaskStatus.inProgress.glanceGlyph, "▶")
        XCTAssertEqual(TaskStatus.review.glanceGlyph, "★")
        XCTAssertEqual(TaskStatus.inReview.glanceGlyph, "◉")
        XCTAssertEqual(TaskStatus.completed.glanceGlyph, "✓")
    }

    /// Every status maps to a non-empty glyph — totality guard.
    func testStatusGlanceGlyphTotalAcrossAllCases() {
        for status in TaskStatus.allCases {
            XCTAssertFalse(status.glanceGlyph.isEmpty, "empty glyph for \(status)")
        }
    }

    // MARK: - TaskStatusIndicator (glyph + color, blocked precedence)

    /// A non-blocked task uses its status glyph + `glanceColor`.
    func testIndicatorUsesStatusGlyphAndColorWhenNotBlocked() {
        let indicator = TaskStatusIndicator(status: .inProgress, isBlocked: false)
        XCTAssertEqual(indicator.glyph, TaskStatus.inProgress.glanceGlyph)
        XCTAssertEqual(indicator.color, TaskStatus.inProgress.glanceColor)
    }

    /// `isBlocked` ALWAYS wins over the status (mirrors the TUI `glyphFor` /
    /// `colorForTask` precedence where the blocked check is first).
    func testIndicatorBlockedTakesPrecedenceOverStatus() {
        let indicator = TaskStatusIndicator(status: .inProgress, isBlocked: true)
        XCTAssertEqual(indicator.glyph, TaskStatusIndicator.blockedGlyph)   // "⊘"
        XCTAssertEqual(indicator.color, TaskStatusIndicator.blockedColor)   // #cc6666
    }

    /// A `nil` status (unrecognized/absent) falls back to a blank glyph in the
    /// neutral color, never a crash.
    func testIndicatorNilStatusFallsBackToNeutral() {
        let indicator = TaskStatusIndicator(status: nil, isBlocked: false)
        XCTAssertEqual(indicator.glyph, " ")
        XCTAssertEqual(indicator.color, TaskStatusIndicator.neutralColor)
    }

    /// A blocked task with a `nil` status still shows the blocked indicator.
    func testIndicatorBlockedWithNilStatusStillBlocked() {
        let indicator = TaskStatusIndicator(status: nil, isBlocked: true)
        XCTAssertEqual(indicator.glyph, TaskStatusIndicator.blockedGlyph)
        XCTAssertEqual(indicator.color, TaskStatusIndicator.blockedColor)
    }

    // MARK: - (b) sortByStaleness

    func testSortByStalenessOrdersDescendingWithGarbageAndAbsentLast() {
        let newest = makeProject(path: "/a", name: "alpha", lastSeen: "2026-06-04T12:00:00Z")
        let older = makeProject(path: "/b", name: "bravo", lastSeen: "2026-01-01T00:00:00Z")
        let garbage = makeProject(path: "/c", name: "charlie", lastSeen: "not-a-date")
        let absent = makeProject(path: "/d", name: "delta", lastSeen: "")

        // Deliberately shuffled input order.
        let sorted = BrowserViewModel.sortByStaleness([garbage, older, absent, newest])

        XCTAssertEqual(sorted.map(\.projectName), ["alpha", "bravo", "charlie", "delta"])
    }

    func testSortByStalenessTreatsFractionalSecondsAsParseable() {
        let fractional = makeProject(path: "/a", name: "alpha", lastSeen: "2026-06-04T12:00:00.123Z")
        let absent = makeProject(path: "/b", name: "bravo", lastSeen: "")

        let sorted = BrowserViewModel.sortByStaleness([absent, fractional])

        XCTAssertEqual(sorted.map(\.projectName), ["alpha", "bravo"])
    }

    func testSortByStalenessIsStableForBothUnparseable() {
        let first = makeProject(path: "/a", name: "alpha", lastSeen: "")
        let second = makeProject(path: "/b", name: "bravo", lastSeen: "garbage")
        let third = makeProject(path: "/c", name: "charlie", lastSeen: "")

        let sorted = BrowserViewModel.sortByStaleness([first, second, third])

        // All unparseable → preserve original registry order.
        XCTAssertEqual(sorted.map(\.projectName), ["alpha", "bravo", "charlie"])
    }

    // MARK: - (c) visibleTasks cross-project filter + drill-down

    /// Two projects; the second reuses an id from the first to prove composite
    /// ids stay unique.
    private func twoProjectFixture() -> [ProjectTasks] {
        let p1 = makeProject(
            path: "/proj1",
            name: "proj1",
            tasks: [
                makeTask(id: "001", status: .inProgress),
                makeTask(id: "002", status: .pending),
                makeTask(id: "003", status: nil),
            ]
        )
        let p2 = makeProject(
            path: "/proj2",
            name: "proj2",
            tasks: [
                makeTask(id: "001", status: .inProgress),
                makeTask(id: "004", status: .completed),
            ]
        )
        return [p1, p2]
    }

    func testVisibleTasksEverythingWhenNoFilters() {
        let rows = BrowserViewModel.visibleTasks(
            projects: twoProjectFixture(),
            status: nil,
            projectPath: nil
        )
        // Every outstanding task across both projects; the completed task (004)
        // is omitted even under "All" — the browser never shows finished work.
        XCTAssertEqual(
            rows.map(\.id),
            ["/proj1/001", "/proj1/002", "/proj1/003", "/proj2/001"]
        )
    }

    func testVisibleTasksAlwaysExcludesCompletedEvenUnderAll() {
        let rows = BrowserViewModel.visibleTasks(
            projects: twoProjectFixture(),
            status: nil,
            projectPath: nil
        )
        XCTAssertFalse(
            rows.contains { $0.task.status == .completed },
            "completed tasks must never appear in the browser"
        )
    }

    func testVisibleTasksStatusFilterAcrossAllProjectsExcludesNilStatus() {
        let rows = BrowserViewModel.visibleTasks(
            projects: twoProjectFixture(),
            status: .inProgress,
            projectPath: nil
        )
        // Both projects' in-progress tasks; the nil-status task (003) excluded.
        XCTAssertEqual(rows.map(\.id), ["/proj1/001", "/proj2/001"])
    }

    func testVisibleTasksDrillDownScopesToOneProject() {
        let rows = BrowserViewModel.visibleTasks(
            projects: twoProjectFixture(),
            status: nil,
            projectPath: "/proj2"
        )
        // Scoped to proj2; its completed task (004) is still omitted.
        XCTAssertEqual(rows.map(\.id), ["/proj2/001"])
    }

    func testVisibleTasksStatusAndProjectIntersection() {
        let rows = BrowserViewModel.visibleTasks(
            projects: twoProjectFixture(),
            status: .inProgress,
            projectPath: "/proj1"
        )
        XCTAssertEqual(rows.map(\.id), ["/proj1/001"])
    }

    func testVisibleTasksPreservesRegistryOrderNotStalenessSort() {
        // Even with lastSeen that would reorder under sortByStaleness, the
        // helper preserves the given array (registry) order.
        let p1 = makeProject(path: "/old", name: "old", lastSeen: "2020-01-01T00:00:00Z",
                             tasks: [makeTask(id: "001")])
        let p2 = makeProject(path: "/new", name: "new", lastSeen: "2030-01-01T00:00:00Z",
                             tasks: [makeTask(id: "002")])
        let rows = BrowserViewModel.visibleTasks(projects: [p1, p2], status: nil, projectPath: nil)
        XCTAssertEqual(rows.map(\.id), ["/old/001", "/new/002"])
    }

    // MARK: - How checklist parsing (read-only render support)

    func testHowStepsParsesDoneAndNotDoneAndStripsPrefix() {
        let body = """
        - [ ] write the test
        - [x] make it pass
        - [X] also done
        some prose that is not a checkbox
        """
        let steps = BrowserViewModel.howSteps(body)
        XCTAssertEqual(steps, [
            .init(text: "write the test", done: false),
            .init(text: "make it pass", done: true),
            .init(text: "also done", done: true),
        ])
    }

    func testParagraphsSplitsOnBlankLines() {
        let body = "first para line one\nfirst para line two\n\nsecond para\n\n\nthird"
        XCTAssertEqual(
            BrowserViewModel.paragraphs(body),
            ["first para line one\nfirst para line two", "second para", "third"]
        )
    }
}
