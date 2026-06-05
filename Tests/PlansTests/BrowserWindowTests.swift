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

    /// Builds a `ProjectTasks` fixture directly. `activeTasks` defaults to empty
    /// so staleness-only tests can ignore it; tests exercising `activeRows`
    /// populate it explicitly (the parser pre-sorts active tasks, so the fixture
    /// supplies them in the desired final order).
    private func makeProject(
        path: String,
        name: String,
        lastSeen: String = "",
        tasks: [Task] = [],
        activeTasks: [Task] = []
    ) -> ProjectTasks {
        ProjectTasks(
            projectPath: path,
            projectName: name,
            lastSeen: lastSeen,
            tasks: tasks,
            counts: [:],
            activeTasks: activeTasks
        )
    }

    /// Replicates the BrowserWindow view's cross-project selected-row resolution:
    /// flatten every project's `activeRows` and find the row with `targetID`.
    /// Returns `nil` when no active row across any project matches.
    private func resolveSelectedRow(_ projects: [ProjectTasks], _ targetID: TaskRow.ID) -> TaskRow? {
        BrowserViewModel.resolveRow(in: projects, id: targetID)
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

    // MARK: - (c) activeRows: one project's card rows

    /// Two projects; the second reuses task id "001" from the first to prove the
    /// composite id (`projectPath + "/" + task.id`) disambiguates them. Each
    /// project's `activeTasks` is supplied already non-completed and in final
    /// order (the parser pre-sorts; `activeRows` must NOT re-sort).
    private func twoProjectFixture() -> [ProjectTasks] {
        let p1 = makeProject(
            path: "/proj1",
            name: "proj1",
            activeTasks: [
                makeTask(id: "001", status: .inProgress),
                makeTask(id: "002", status: .pending),
            ]
        )
        let p2 = makeProject(
            path: "/proj2",
            name: "proj2",
            activeTasks: [
                makeTask(id: "001", status: .inProgress),
            ]
        )
        return [p1, p2]
    }

    /// `activeRows` maps a project's `activeTasks` to `TaskRow`s in the SAME
    /// order, with composite ids, and never re-sorts.
    func testActiveRowsPreservesOrderWithCompositeIds() {
        let project = makeProject(
            path: "/p",
            name: "p",
            activeTasks: [
                makeTask(id: "001", status: .inProgress),
                makeTask(id: "002", status: .pending),
            ]
        )
        let rows = BrowserViewModel.activeRows(project)
        XCTAssertEqual(rows.map(\.id), ["/p/001", "/p/002"])
    }

    /// A project carrying an empty `activeTasks` yields no rows.
    func testActiveRowsEmptyWhenNoActiveTasks() {
        let project = makeProject(path: "/p", name: "p", activeTasks: [])
        XCTAssertTrue(BrowserViewModel.activeRows(project).isEmpty)
    }

    /// `activeRows` carries the owning project's identity onto each row.
    func testActiveRowsCarriesProjectIdentity() {
        let project = makeProject(
            path: "/p",
            name: "myproj",
            activeTasks: [makeTask(id: "001", status: .inProgress)]
        )
        let row = BrowserViewModel.activeRows(project).first
        XCTAssertEqual(row?.projectPath, "/p")
        XCTAssertEqual(row?.projectName, "myproj")
        XCTAssertEqual(row?.id, "/p/001")
    }

    // MARK: - Cross-project selected-row resolution (mirrors the view)

    /// The view resolves `selectedRowID` by scanning EVERY project's active rows.
    /// A composite id belonging to the SECOND project resolves to that project's
    /// row even though both projects share task id "001".
    func testResolveSelectedRowFindsRowInSecondProject() {
        let row = resolveSelectedRow(twoProjectFixture(), "/proj2/001")
        XCTAssertEqual(row?.id, "/proj2/001")
        XCTAssertEqual(row?.projectPath, "/proj2")
    }

    /// The first project's "001" resolves independently of the second's.
    func testResolveSelectedRowDisambiguatesSharedTaskIdAcrossProjects() {
        let row = resolveSelectedRow(twoProjectFixture(), "/proj1/001")
        XCTAssertEqual(row?.projectPath, "/proj1")
    }

    /// An id present in no project's active rows resolves to `nil`.
    func testResolveSelectedRowReturnsNilForAbsentId() {
        XCTAssertNil(resolveSelectedRow(twoProjectFixture(), "/proj1/999"))
    }

    /// An id belonging to a completed/closed task (never in any `activeTasks`)
    /// resolves to `nil` — the detail panel can't open on finished work.
    func testResolveSelectedRowReturnsNilForCompletedTaskId() {
        // p1's `tasks` includes a completed task, but `activeTasks` excludes it,
        // so its composite id is unresolvable.
        let p1 = makeProject(
            path: "/proj1",
            name: "proj1",
            tasks: [
                makeTask(id: "001", status: .inProgress),
                makeTask(id: "099", status: .completed),
            ],
            activeTasks: [makeTask(id: "001", status: .inProgress)]
        )
        XCTAssertNil(resolveSelectedRow([p1], "/proj1/099"))
        XCTAssertNotNil(resolveSelectedRow([p1], "/proj1/001"))
    }

    // MARK: - BrowserViewModel.resolveRow (shared cross-project lookup)

    /// The shared `resolveRow` helper finds a composite id belonging to the
    /// SECOND project even when both projects reuse task id "001".
    func testResolveRowFindsRowInSecondProject() {
        let row = BrowserViewModel.resolveRow(in: twoProjectFixture(), id: "/proj2/001")
        XCTAssertEqual(row?.id, "/proj2/001")
        XCTAssertEqual(row?.projectPath, "/proj2")
    }

    /// `resolveRow` returns `nil` for an id present in no project's active rows.
    func testResolveRowReturnsNilForAbsentId() {
        XCTAssertNil(BrowserViewModel.resolveRow(in: twoProjectFixture(), id: "/proj1/999"))
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

    // MARK: - columnCount (responsive grid)

    /// A narrow viewport (300pt) fits zero full `cardMinWidth` columns by the raw
    /// formula, but the `max(1, …)` floor guarantees a single column so the grid
    /// is never empty. usable = 300 - 32 = 268; per-column footprint = 400 + 16 =
    /// 416; 268 / 416 = 0 → max(1, 0) = 1.
    func testColumnCountNarrowWidthYieldsOneColumn() {
        XCTAssertEqual(BrowserWindow.columnCount(forWidth: 300), 1)
    }

    /// The floor holds even at a tiny / degenerate width (50pt): the raw quotient
    /// is 0 (or could go negative once padding exceeds the width), yet the column
    /// count never drops below 1.
    func testColumnCountFloorHoldsAtTinyWidth() {
        XCTAssertEqual(BrowserWindow.columnCount(forWidth: 50), 1)
    }

    /// At the legacy reference width (820pt) the new 400pt card min yields a
    /// SINGLE column. usable = 820 - 32 = 788; per-column footprint = 400 + 16 =
    /// 416; 788 / 416 = 1.89 → Int = 1 → max(1, 1) = 1. (Pre-400 this was 2; the
    /// window can now shrink below 820 anyway, so 820 is no longer a floor.)
    func testColumnCountAtLegacyReferenceWidthYieldsOneColumn() {
        XCTAssertEqual(BrowserWindow.columnCount(forWidth: 820), 1)
    }

    /// A roomier viewport (1000pt) yields EXACTLY 2 columns under the 400pt card
    /// min. usable = 1000 - 32 = 968; 968 / 416 = 2.32 → Int = 2 → max(1, 2) = 2.
    func testColumnCountAtRoomyWidthYieldsTwoColumns() {
        XCTAssertEqual(BrowserWindow.columnCount(forWidth: 1000), 2)
    }

    /// A wide viewport (2000pt) reflows to 4 columns. usable = 2000 - 32 = 1968;
    /// 1968 / 416 = 4.73 → Int = 4 → max(1, 4) = 4.
    func testColumnCountWideWidthYieldsFourColumns() {
        XCTAssertEqual(BrowserWindow.columnCount(forWidth: 2000), 4)
    }
}
