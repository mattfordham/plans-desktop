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

    // MARK: - (b2) #036 New Plan picker snapshot / path-identity key
    //
    // The New Plan sheet (`NewPlanModal`) drives its project picker from a LOCAL
    // snapshot of `BrowserViewModel.sortByStaleness(store.projects)` and refreshes
    // it only when the SET of project paths changes — keyed on
    // `store.projects.map(\.projectPath)`. These tests guard that identity key:
    // routine 5s re-parses (same paths, mutated metadata) must NOT change it,
    // while a genuine add/remove/relink MUST. They also confirm the snapshot
    // captures the live staleness ordering.

    /// Mirrors `NewPlanModal`'s `.onChange(of: store.projects.map(\.projectPath))`
    /// identity key.
    private func pathIdentityKey(_ projects: [ProjectTasks]) -> [String] {
        projects.map(\.projectPath)
    }

    /// A routine 5s re-parse that keeps the SAME project paths but mutates their
    /// metadata (`lastSeen`, `tasks`) leaves the path-identity key UNCHANGED — so
    /// the editor's snapshot is not refreshed and typing never churns.
    func testPathIdentityKeyUnchangedWhenOnlyMetadataMutates() {
        let before = [
            makeProject(path: "/a", name: "alpha", lastSeen: "2026-06-01T00:00:00Z"),
            makeProject(path: "/b", name: "bravo", lastSeen: "2026-06-02T00:00:00Z"),
        ]
        // Same paths, but newer `lastSeen` and added tasks — a typical re-parse.
        let after = [
            makeProject(
                path: "/a",
                name: "alpha",
                lastSeen: "2026-06-07T12:00:00Z",
                tasks: [makeTask(id: "001", status: .inProgress)]
            ),
            makeProject(
                path: "/b",
                name: "bravo",
                lastSeen: "2026-06-07T13:00:00Z",
                tasks: [makeTask(id: "002", status: .pending)]
            ),
        ]
        XCTAssertEqual(pathIdentityKey(before), pathIdentityKey(after))
    }

    /// Adding a project changes the path-identity key — a genuine project-set
    /// change that MUST refresh the picker snapshot.
    func testPathIdentityKeyChangesWhenProjectAdded() {
        let before = [makeProject(path: "/a", name: "alpha")]
        let after = [
            makeProject(path: "/a", name: "alpha"),
            makeProject(path: "/b", name: "bravo"),
        ]
        XCTAssertNotEqual(pathIdentityKey(before), pathIdentityKey(after))
    }

    /// Removing a project changes the path-identity key — the picker snapshot must
    /// refresh to drop the vanished row.
    func testPathIdentityKeyChangesWhenProjectRemoved() {
        let before = [
            makeProject(path: "/a", name: "alpha"),
            makeProject(path: "/b", name: "bravo"),
        ]
        let after = [makeProject(path: "/a", name: "alpha")]
        XCTAssertNotEqual(pathIdentityKey(before), pathIdentityKey(after))
    }

    /// Relinking a project to a new path (same count, same name) still changes the
    /// path-identity key — the snapshot must refresh because the tag the picker
    /// binds to changed.
    func testPathIdentityKeyChangesWhenProjectRelinked() {
        let before = [makeProject(path: "/old", name: "alpha")]
        let after = [makeProject(path: "/new", name: "alpha")]
        XCTAssertNotEqual(pathIdentityKey(before), pathIdentityKey(after))
    }

    /// The picker snapshot is `sortByStaleness(store.projects)`, so its captured
    /// ordering matches the live staleness order even when the store delivers the
    /// projects shuffled — confirming the snapshot reproduces the live ordering.
    func testSnapshotCapturesLiveStalenessOrdering() {
        let newest = makeProject(path: "/a", name: "alpha", lastSeen: "2026-06-04T12:00:00Z")
        let older = makeProject(path: "/b", name: "bravo", lastSeen: "2026-01-01T00:00:00Z")
        let absent = makeProject(path: "/c", name: "charlie", lastSeen: "")

        // What `refreshProjectsSnapshot()` would assign from a shuffled store.
        let snapshot = BrowserViewModel.sortByStaleness([absent, newest, older])

        XCTAssertEqual(snapshot.map(\.projectName), ["alpha", "bravo", "charlie"])
        // The path-identity key derived from the snapshot reflects that order.
        XCTAssertEqual(pathIdentityKey(snapshot), ["/a", "/b", "/c"])
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

    // MARK: - visibleUnderHideEmpty (#035: keep starred projects past the hide-empty filter)

    /// A project with NO outstanding work whose path the user STARRED survives
    /// the hide-empty filter, so its (empty) card stays in the dashboard.
    func testVisibleUnderHideEmptyTrueForStarredEmptyProject() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [makeTask(id: "099", status: .completed)],
            activeTasks: []
        )
        XCTAssertTrue(
            BrowserViewModel.visibleUnderHideEmpty(project, starredProjectPaths: ["/p"])
        )
    }

    /// A project with NO outstanding work and NOT starred is hidden by the filter.
    func testVisibleUnderHideEmptyFalseForUnstarredEmptyProject() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [makeTask(id: "099", status: .completed)],
            activeTasks: []
        )
        XCTAssertFalse(
            BrowserViewModel.visibleUnderHideEmpty(project, starredProjectPaths: [])
        )
    }

    /// A project with outstanding work is always kept, starred or not.
    func testVisibleUnderHideEmptyTrueForProjectWithOutstandingWork() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [makeTask(id: "001", status: .inProgress)],
            activeTasks: [makeTask(id: "001", status: .inProgress)]
        )
        XCTAssertTrue(
            BrowserViewModel.visibleUnderHideEmpty(project, starredProjectPaths: [])
        )
    }

    /// Starring a DIFFERENT project does not rescue this empty, unstarred one.
    func testVisibleUnderHideEmptyFalseWhenOnlyAnotherProjectStarred() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [makeTask(id: "099", status: .completed)],
            activeTasks: []
        )
        XCTAssertFalse(
            BrowserViewModel.visibleUnderHideEmpty(project, starredProjectPaths: ["/other"])
        )
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

    // MARK: - effectiveLayoutMode (fit collapses to scroll at one column)

    /// Fit-to-screen at a SINGLE column collapses to scroll: stacking full-width
    /// cards with stretched heights would just make one tall card per screen, so
    /// the grid scrolls normally instead.
    func testEffectiveLayoutModeFitAtOneColumnFallsBackToScroll() {
        XCTAssertEqual(BrowserWindow.effectiveLayoutMode(.fit, columnCount: 1), .scroll)
    }

    /// A zero/degenerate column count is also treated as the single-column case
    /// and falls back to scroll (defensive — the grid floors columns at 1 anyway).
    func testEffectiveLayoutModeFitAtZeroColumnsFallsBackToScroll() {
        XCTAssertEqual(BrowserWindow.effectiveLayoutMode(.fit, columnCount: 0), .scroll)
    }

    /// With two or more columns the requested fit mode is honored verbatim.
    func testEffectiveLayoutModeFitAtTwoColumnsStaysFit() {
        XCTAssertEqual(BrowserWindow.effectiveLayoutMode(.fit, columnCount: 2), .fit)
    }

    /// Scroll mode is never altered by the column count.
    func testEffectiveLayoutModeScrollAlwaysScroll() {
        XCTAssertEqual(BrowserWindow.effectiveLayoutMode(.scroll, columnCount: 1), .scroll)
        XCTAssertEqual(BrowserWindow.effectiveLayoutMode(.scroll, columnCount: 4), .scroll)
    }

    // MARK: - rowIndices (grouping card indices into fit-grid rows #039)

    /// An empty grid has no rows regardless of the column count.
    func testRowIndicesZeroCardsIsEmpty() {
        XCTAssertEqual(BrowserWindow.rowIndices(count: 0, columns: 3), [])
    }

    /// A partial final row keeps the remaining indices: 5 cards over 2 columns is
    /// [0,1] [2,3] [4] in reading order.
    func testRowIndicesPartialFinalRow() {
        XCTAssertEqual(
            BrowserWindow.rowIndices(count: 5, columns: 2),
            [[0, 1], [2, 3], [4]]
        )
    }

    /// An exact fit groups evenly: 6 cards over 3 columns is [0,1,2] [3,4,5].
    func testRowIndicesExactFit() {
        XCTAssertEqual(
            BrowserWindow.rowIndices(count: 6, columns: 3),
            [[0, 1, 2], [3, 4, 5]]
        )
    }

    /// A degenerate zero column count yields no rows (no infinite loop / divide).
    func testRowIndicesZeroColumnsIsEmpty() {
        XCTAssertEqual(BrowserWindow.rowIndices(count: 4, columns: 0), [])
    }

    // MARK: - columnAssignments (masonry column distribution #039)

    /// An even split distributes indices round-robin in reading order: 4 cards
    /// over 2 columns puts 0,2 in the first column and 1,3 in the second.
    func testColumnAssignmentsEvenSplit() {
        XCTAssertEqual(
            BrowserWindow.columnAssignments(count: 4, columns: 2),
            [[0, 2], [1, 3]]
        )
    }

    /// An uneven count leaves the remainder in the leading columns: 5 cards over 2
    /// columns is [0,2,4] and [1,3].
    func testColumnAssignmentsUnevenRemainder() {
        XCTAssertEqual(
            BrowserWindow.columnAssignments(count: 5, columns: 2),
            [[0, 2, 4], [1, 3]]
        )
    }

    /// A single column collects every index in order.
    func testColumnAssignmentsSingleColumn() {
        XCTAssertEqual(
            BrowserWindow.columnAssignments(count: 3, columns: 1),
            [[0, 1, 2]]
        )
    }

    /// A zero (or negative) card count yields no columns at all — an empty result.
    func testColumnAssignmentsZeroCountIsEmpty() {
        XCTAssertEqual(BrowserWindow.columnAssignments(count: 0, columns: 3), [])
        XCTAssertEqual(BrowserWindow.columnAssignments(count: -5, columns: 3), [])
    }

    /// A zero/negative column count is floored to a single column (defensive — the
    /// grid floors columns at 1 anyway), so every index lands in one column.
    func testColumnAssignmentsZeroColumnsFlooredToOne() {
        XCTAssertEqual(
            BrowserWindow.columnAssignments(count: 2, columns: 0),
            [[0, 1]]
        )
        XCTAssertEqual(
            BrowserWindow.columnAssignments(count: 2, columns: -3),
            [[0, 1]]
        )
    }

    /// The flattened union of every column's indices is exactly `0..<count` with no
    /// duplicates and no omissions — a representative coverage guard (7 over 3).
    func testColumnAssignmentsUnionCoversAllIndicesExactly() {
        let assignments = BrowserWindow.columnAssignments(count: 7, columns: 3)
        let flattened = assignments.flatMap { $0 }.sorted()
        XCTAssertEqual(flattened, Array(0..<7))
        // No duplicates: the flattened set size equals the count.
        XCTAssertEqual(Set(flattened).count, 7)
    }

    // MARK: - fitRowHeights (content-driven, viewport-filling row heights #039)

    /// The chrome (outer padding + inter-row gutters) a row layout consumes
    /// outside the rows themselves, for asserting that the final rows fill the
    /// viewport exactly. Mirrors the helper's own arithmetic.
    private func chrome(rowCount: Int, spacing: CGFloat, padding: CGFloat) -> CGFloat {
        2 * padding + CGFloat(max(0, rowCount - 1)) * spacing
    }

    /// An unmeasured viewport (height 0) can't drive a fill, so the helper returns
    /// the natural row heights unchanged as a sensible first-paint fallback.
    func testFitRowHeightsUnmeasuredViewportReturnsNaturals() {
        let naturals: [CGFloat] = [120, 200, 90]
        let result = BrowserWindow.fitRowHeights(
            naturalRowHeights: naturals,
            viewportHeight: 0,
            spacing: 16, padding: 16, minRowHeight: 160
        )
        XCTAssertEqual(result, naturals)
    }

    /// A negative viewport height is also treated as unmeasured and returns the
    /// naturals unchanged.
    func testFitRowHeightsNegativeViewportReturnsNaturals() {
        let naturals: [CGFloat] = [120, 200]
        let result = BrowserWindow.fitRowHeights(
            naturalRowHeights: naturals,
            viewportHeight: -10,
            spacing: 16, padding: 16, minRowHeight: 160
        )
        XCTAssertEqual(result, naturals)
    }

    /// No rows → no heights, never a divide-by-zero.
    func testFitRowHeightsEmptyInputIsEmpty() {
        let result = BrowserWindow.fitRowHeights(
            naturalRowHeights: [],
            viewportHeight: 800,
            spacing: 16, padding: 16, minRowHeight: 160
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// STRETCH (water-fill): rows whose natural total is shorter than the viewport
    /// fill the viewport exactly, but instead of preserving proportions the SHORTER
    /// rows are levelled UP toward the taller one — the gap between rows shrinks and
    /// the shorter row gains more absolute height than the taller row.
    func testFitRowHeightsStretchLevelsShorterRowsUp() {
        let naturals: [CGFloat] = [200, 100] // sums to 300
        let viewport: CGFloat = 1000
        let result = BrowserWindow.fitRowHeights(
            naturalRowHeights: naturals,
            viewportHeight: viewport,
            spacing: 16, padding: 16, minRowHeight: 160
        )
        // chrome = 48, available = 952, share = 476. Both naturals (200, 100) are
        // below share so both rise to 476 → the rows happen to fill exactly here.
        let total = result.reduce(0, +) + chrome(rowCount: 2, spacing: 16, padding: 16)
        XCTAssertEqual(total, viewport, accuracy: 0.001)
        XCTAssertEqual(result[0], 476, accuracy: 0.001)
        XCTAssertEqual(result[1], 476, accuracy: 0.001)
        // No row drops below its natural height.
        XCTAssertGreaterThanOrEqual(result[0], naturals[0] - 0.001)
        XCTAssertGreaterThanOrEqual(result[1], naturals[1] - 0.001)
        // The gap between the rows shrinks vs natural (was 100, now 0).
        XCTAssertLessThan(result[0] - result[1], naturals[0] - naturals[1])
        // The shorter row gains more absolute height than the taller row.
        XCTAssertGreaterThan(result[1] - naturals[1], result[0] - naturals[0])
    }

    /// STRETCH (over-fill): the short row grows to the per-row share even when that
    /// pushes the total past the budget; the tall row (already above share) stays at
    /// its natural height and the ScrollView absorbs the surplus.
    func testFitRowHeightsStretchSlackGoesToShortRowFirst() {
        let naturals: [CGFloat] = [300, 100] // sums to 400; gap of 200
        // chrome = 48; pick available = 450 → viewport = 498. share = 225.
        let viewport: CGFloat = 498
        let result = BrowserWindow.fitRowHeights(
            naturalRowHeights: naturals,
            viewportHeight: viewport,
            spacing: 16, padding: 16, minRowHeight: 160
        )
        // max(300, 225) = 300 (tall stays natural) ; max(100, 225) = 225 (short rises
        // to the share). Total 525 > 450 → over-fills; ScrollView scrolls.
        XCTAssertEqual(result[0], 300, accuracy: 0.001)
        XCTAssertEqual(result[1], 225, accuracy: 0.001)
        let total = result.reduce(0, +) + chrome(rowCount: 2, spacing: 16, padding: 16)
        XCTAssertGreaterThan(total, viewport)
    }

    /// STRETCH (over-fill): with surplus beyond the gap both rows rise above the
    /// taller natural to a COMMON level (the per-row share); here that level happens
    /// to fill the viewport exactly.
    func testFitRowHeightsStretchSurplusBeyondGapLevelsAllRows() {
        let naturals: [CGFloat] = [300, 100] // sums to 400; gap of 200
        // available large enough that both rise above 300. chrome = 48.
        // available = 800 → each row = 400 (> 300). viewport = 848.
        let viewport: CGFloat = 848
        let result = BrowserWindow.fitRowHeights(
            naturalRowHeights: naturals,
            viewportHeight: viewport,
            spacing: 16, padding: 16, minRowHeight: 160
        )
        let total = result.reduce(0, +) + chrome(rowCount: 2, spacing: 16, padding: 16)
        XCTAssertEqual(total, viewport, accuracy: 0.001)
        // Both above the taller natural, equal at a common level.
        XCTAssertEqual(result[0], result[1], accuracy: 0.001)
        XCTAssertGreaterThan(result[0], naturals[0])
    }

    /// STRETCH (over-fill): the genuinely-still-true invariants. No stretch result
    /// ever falls below its natural height, and the rows + chrome at least fill the
    /// viewport (they may EXCEED it — the over-fill policy lets a short row rise to
    /// the per-row share past the exact-fit point, with the ScrollView absorbing any
    /// surplus). The "fills exactly" invariant is deliberately gone on this path.
    func testFitRowHeightsStretchFillsViewportAndNeverBelowNatural() {
        let cases: [(naturals: [CGFloat], viewport: CGFloat)] = [
            ([200, 100], 1000),
            ([300, 100, 50], 1200),
            ([120, 120, 120], 900),
            ([400, 50, 50, 50], 1100),
        ]
        for c in cases {
            let result = BrowserWindow.fitRowHeights(
                naturalRowHeights: c.naturals,
                viewportHeight: c.viewport,
                spacing: 16, padding: 16, minRowHeight: 160
            )
            let total = result.reduce(0, +)
                + chrome(rowCount: c.naturals.count, spacing: 16, padding: 16)
            // Over-fill never leaves an empty band: the content at least fills the
            // viewport (and may exceed it, which the ScrollView handles).
            XCTAssertGreaterThanOrEqual(total, c.viewport - 0.001,
                           "naturals \(c.naturals) viewport \(c.viewport)")
            for (r, n) in zip(result, c.naturals) {
                XCTAssertGreaterThanOrEqual(r, n - 0.001,
                    "stretch result \(r) below natural \(n) for \(c.naturals)")
            }
        }
    }

    /// EXACT FIT: rows whose natural total already equals the available space are
    /// left essentially unchanged (factor ≈ 1).
    func testFitRowHeightsExactFitLeavesRowsUnchanged() {
        // availableForRows = viewport - chrome. Pick naturals summing to exactly that.
        let viewport: CGFloat = 1000
        let available = viewport - chrome(rowCount: 2, spacing: 16, padding: 16) // 1000 - 48 = 952
        let naturals: [CGFloat] = [available * 0.6, available * 0.4]
        let result = BrowserWindow.fitRowHeights(
            naturalRowHeights: naturals,
            viewportHeight: viewport,
            spacing: 16, padding: 16, minRowHeight: 160
        )
        XCTAssertEqual(result[0], naturals[0], accuracy: 0.001)
        XCTAssertEqual(result[1], naturals[1], accuracy: 0.001)
    }

    /// SHRINK above floor: rows whose natural total overflows the viewport but can
    /// shrink without any row hitting the floor scale DOWN to fill the viewport
    /// exactly, every row staying at or above the floor.
    func testFitRowHeightsShrinksAboveFloorToFill() {
        let floor: CGFloat = 160
        let naturals: [CGFloat] = [600, 500] // sums to 1100, will shrink
        let viewport: CGFloat = 800
        let result = BrowserWindow.fitRowHeights(
            naturalRowHeights: naturals,
            viewportHeight: viewport,
            spacing: 16, padding: 16, minRowHeight: floor
        )
        let total = result.reduce(0, +) + chrome(rowCount: 2, spacing: 16, padding: 16)
        XCTAssertEqual(total, viewport, accuracy: 0.001)
        for h in result { XCTAssertGreaterThanOrEqual(h, floor) }
    }

    /// SHRINK hits floor: a heavy overflow that can't fit even at the floor clamps
    /// every row to the floor; the resulting total may EXCEED the viewport (the
    /// surrounding ScrollView absorbs the overflow).
    func testFitRowHeightsClampsAllRowsToFloorOnHeavyOverflow() {
        let floor: CGFloat = 160
        let naturals: [CGFloat] = [500, 500, 500, 500] // far too tall
        let viewport: CGFloat = 400
        let result = BrowserWindow.fitRowHeights(
            naturalRowHeights: naturals,
            viewportHeight: viewport,
            spacing: 16, padding: 16, minRowHeight: floor
        )
        XCTAssertEqual(result, [floor, floor, floor, floor])
        let total = result.reduce(0, +) + chrome(rowCount: 4, spacing: 16, padding: 16)
        XCTAssertGreaterThan(total, viewport) // ScrollView handles it
    }

    /// A single row that's shorter than the viewport stretches to fill it.
    func testFitRowHeightsSingleRowStretchesToFill() {
        let viewport: CGFloat = 700
        let result = BrowserWindow.fitRowHeights(
            naturalRowHeights: [200],
            viewportHeight: viewport,
            spacing: 16, padding: 16, minRowHeight: 160
        )
        XCTAssertEqual(result.count, 1)
        let total = result[0] + chrome(rowCount: 1, spacing: 16, padding: 16)
        XCTAssertEqual(total, viewport, accuracy: 0.001)
    }

    // MARK: - fillShorterRows (over-fill to per-row share #057)

    /// #057 over-fill policy: each row's final height is `max(natural_i, share)`
    /// where `share = availableForRows / rowCount`. The short row grows up to the
    /// per-row share — even PAST the tall row's natural height — killing the empty
    /// band beneath it. Here `[350, 180]@800`, share = 400, so BOTH rows reach 400
    /// (the short row's natural 180 and the tall row's natural 350 are both below
    /// share), and the total happens to fill the budget exactly.
    func testFillShorterRowsScreenshotShortRowAbsorbsSlack() {
        let naturals: [CGFloat] = [350, 180] // tall row, short bottom row
        let available: CGFloat = 800 // share = 400; both naturals below it
        let result = BrowserWindow.fillShorterRows(
            naturalRowHeights: naturals,
            availableForRows: available
        )
        let share = available / CGFloat(naturals.count) // 400
        // max(350, 400) = 400 ; max(180, 400) = 400.
        XCTAssertEqual(result[0], 400, accuracy: 0.001)
        XCTAssertEqual(result[1], 400, accuracy: 0.001)
        // Never below natural.
        XCTAssertGreaterThanOrEqual(result[0], naturals[0] - 0.001)
        XCTAssertGreaterThanOrEqual(result[1], naturals[1] - 0.001)
        // The short row rises to AT LEAST the tall row's natural height — the band
        // beneath it is gone (the whole point of #057).
        XCTAssertGreaterThanOrEqual(result[1], naturals[0] - 0.001)
        // The short row gains MORE absolute height than the tall row (it was lower
        // so it has farther to climb to the common share).
        XCTAssertGreaterThan(result[1] - naturals[1], result[0] - naturals[0])
        // No row exceeds the per-row share (here both equal it).
        for h in result { XCTAssertLessThanOrEqual(h, share + 0.001) }
        // This case happens to fill the budget exactly (both naturals < share).
        XCTAssertEqual(result.reduce(0, +), available, accuracy: 0.001)
    }

    /// #057 over-fill, band-killing surplus regime: `[350, 180]@600`, share = 300.
    /// The short row grows to 300 (NOT 180, NOT clamped down to make the total fit),
    /// the tall row stays at its natural 350 (already above share), and the total
    /// 650 EXCEEDS the 600 budget — the surrounding ScrollView absorbs the surplus.
    /// This is the deliberate abandonment of exact-fill that kills the empty band.
    func testFillShorterRowsOverFillsPastBudgetToKillBand() {
        let naturals: [CGFloat] = [350, 180]
        let available: CGFloat = 600 // share = 300
        let result = BrowserWindow.fillShorterRows(
            naturalRowHeights: naturals,
            availableForRows: available
        )
        // max(350, 300) = 350 (tall stays natural) ; max(180, 300) = 300.
        XCTAssertEqual(result[0], 350, accuracy: 0.001)
        XCTAssertEqual(result[1], 300, accuracy: 0.001)
        // The short row grew to the share (300), NOT clamped to fit the budget.
        XCTAssertEqual(result[1], 300, accuracy: 0.001)
        // Total deliberately exceeds the budget; the ScrollView scrolls.
        XCTAssertEqual(result.reduce(0, +), 650, accuracy: 0.001)
        XCTAssertGreaterThan(result.reduce(0, +), available)
    }

    /// #057 over-fill, multi-row: ONE tall row + TWO short rows. Each short row rises
    /// to the per-row share; the tall row stays at its natural height (already above
    /// share). `[350, 150, 130]@900`, share = 300 → `[350, 300, 300]`, total 950 > 900
    /// so the ScrollView absorbs the surplus.
    func testFillShorterRowsTwoShortRowsRiseTallStaysNatural() {
        let naturals: [CGFloat] = [350, 150, 130]
        let available: CGFloat = 900 // share = 300; tall (350) > share
        let result = BrowserWindow.fillShorterRows(
            naturalRowHeights: naturals,
            availableForRows: available
        )
        // Tall row stays at its natural height (already exceeds the per-row share).
        XCTAssertEqual(result[0], 350, accuracy: 0.001)
        // The two short rows each rise to the per-row share of 300.
        XCTAssertEqual(result[1], 300, accuracy: 0.001)
        XCTAssertEqual(result[2], 300, accuracy: 0.001)
        // Each short row gained height; neither dropped below natural.
        XCTAssertGreaterThan(result[1], naturals[1])
        XCTAssertGreaterThan(result[2], naturals[2])
        // Total over-fills the budget (350 + 300 + 300 = 950 > 900).
        XCTAssertEqual(result.reduce(0, +), 950, accuracy: 0.001)
        XCTAssertGreaterThan(result.reduce(0, +), available)
    }

    /// No slack (`availableForRows <= naturalTotal`) leaves the rows at their
    /// natural heights unchanged.
    func testFillShorterRowsNoSlackReturnsNaturals() {
        let naturals: [CGFloat] = [350, 180]
        let result = BrowserWindow.fillShorterRows(
            naturalRowHeights: naturals,
            availableForRows: 530 // == natural total, no slack
        )
        XCTAssertEqual(result, naturals)
        // Strictly less than the total also returns naturals.
        let result2 = BrowserWindow.fillShorterRows(
            naturalRowHeights: naturals,
            availableForRows: 400
        )
        XCTAssertEqual(result2, naturals)
    }

    /// Empty input yields an empty result (no divide-by-zero).
    func testFillShorterRowsEmptyInputIsEmpty() {
        XCTAssertTrue(
            BrowserWindow.fillShorterRows(naturalRowHeights: [], availableForRows: 800).isEmpty
        )
    }

    /// A single row with slack takes the whole budget (its share == the budget).
    func testFillShorterRowsSingleRowTakesWholeBudget() {
        let result = BrowserWindow.fillShorterRows(
            naturalRowHeights: [200],
            availableForRows: 700
        )
        XCTAssertEqual(result, [700])
    }

    /// All-equal rows with slack rise together to the common per-row share.
    func testFillShorterRowsAllEqualRowsRiseTogether() {
        let result = BrowserWindow.fillShorterRows(
            naturalRowHeights: [120, 120, 120],
            availableForRows: 900
        )
        for h in result { XCTAssertEqual(h, 300, accuracy: 0.001) } // 900 / 3
        XCTAssertEqual(result.reduce(0, +), 900, accuracy: 0.001)
    }

    /// #057 through `fitRowHeights`: the over-fill policy wired into the public entry
    /// point. `[350, 180]@848`, chrome = 48, available = 800, share = 400 → both rows
    /// reach 400 (`max(350,400)`, `max(180,400)`), the short bottom row lifts to fill
    /// the band, and here the rows happen to fill the viewport exactly.
    func testFitRowHeightsScreenshotLiftsShortRowToFillBand() {
        let naturals: [CGFloat] = [350, 180]
        // chrome (2 rows) = 48; pick available = 800 → viewport = 848.
        let viewport: CGFloat = 848
        let result = BrowserWindow.fitRowHeights(
            naturalRowHeights: naturals,
            viewportHeight: viewport,
            spacing: 16, padding: 16, minRowHeight: 160
        )
        // share = 800 / 2 = 400; both naturals below it so both reach 400.
        XCTAssertEqual(result[0], 400, accuracy: 0.001)
        XCTAssertEqual(result[1], 400, accuracy: 0.001)
        let total = result.reduce(0, +) + chrome(rowCount: 2, spacing: 16, padding: 16)
        XCTAssertEqual(total, viewport, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(result[1], naturals[0] - 0.001)
        XCTAssertGreaterThan(result[1] - naturals[1], result[0] - naturals[0])
    }

    /// #057 through `fitRowHeights`, over-fill surplus regime: `[350, 180]@viewport648`
    /// (chrome 48 → available 600, share 300) → `[350, 300]`, total 650 + chrome 48 =
    /// 698 > 648, so the surrounding ScrollView absorbs the surplus and the short row
    /// still visibly grows to the share rather than collapsing to a band.
    func testFitRowHeightsScreenshotOverFillsViewport() {
        let naturals: [CGFloat] = [350, 180]
        let viewport: CGFloat = 648 // chrome 48 → available 600
        let result = BrowserWindow.fitRowHeights(
            naturalRowHeights: naturals,
            viewportHeight: viewport,
            spacing: 16, padding: 16, minRowHeight: 160
        )
        XCTAssertEqual(result[0], 350, accuracy: 0.001)
        XCTAssertEqual(result[1], 300, accuracy: 0.001)
        let total = result.reduce(0, +) + chrome(rowCount: 2, spacing: 16, padding: 16)
        XCTAssertGreaterThan(total, viewport) // ScrollView absorbs the surplus
    }

    // MARK: - evenRowHeights (uniform, viewport-divided row heights #045)

    /// All rows get an IDENTICAL height: the viewport minus chrome divided evenly
    /// across the rows, ignoring any per-row content height.
    func testEvenRowHeightsAllRowsEqualAndFillViewport() {
        let viewport: CGFloat = 600
        let spacing: CGFloat = 10
        let padding: CGFloat = 16
        let result = BrowserWindow.evenRowHeights(
            rowCount: 3,
            viewportHeight: viewport,
            spacing: spacing, padding: padding, minRowHeight: 160
        )
        let chrome: CGFloat = 2 * padding + 2 * spacing // 52
        let expected: CGFloat = (viewport - chrome) / 3
        XCTAssertEqual(result.count, 3)
        for h in result { XCTAssertEqual(h, expected, accuracy: 0.001) }
        // Explicitly assert all three entries are identical to one another.
        XCTAssertEqual(result[0], result[1], accuracy: 0.0001)
        XCTAssertEqual(result[1], result[2], accuracy: 0.0001)
    }

    /// A viewport whose even share comfortably clears the floor keeps every row
    /// above the floor (no clamping).
    func testEvenRowHeightsStaysAboveFloorWhenRoomy() {
        let floor: CGFloat = 160
        let result = BrowserWindow.evenRowHeights(
            rowCount: 2,
            viewportHeight: 1000,
            spacing: 16, padding: 16, minRowHeight: floor
        )
        for h in result { XCTAssertGreaterThan(h, floor) }
    }

    /// CLAMP TO FLOOR: a small viewport spread across many rows yields an even
    /// share below the floor, so every row is pinned to EXACTLY the floor and the
    /// ScrollView absorbs the overflow.
    func testEvenRowHeightsClampsAllRowsToFloorWhenTight() {
        let floor: CGFloat = 160
        let result = BrowserWindow.evenRowHeights(
            rowCount: 5,
            viewportHeight: 400,
            spacing: 16, padding: 16, minRowHeight: floor
        )
        XCTAssertEqual(result, [floor, floor, floor, floor, floor])
    }

    /// No rows → no heights, never a divide-by-zero.
    func testEvenRowHeightsZeroRowsIsEmpty() {
        let result = BrowserWindow.evenRowHeights(
            rowCount: 0,
            viewportHeight: 800,
            spacing: 16, padding: 16, minRowHeight: 160
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// An unmeasured viewport (height 0) falls back to one floor height per row.
    func testEvenRowHeightsUnmeasuredViewportReturnsFloorPerRow() {
        let floor: CGFloat = 160
        let result = BrowserWindow.evenRowHeights(
            rowCount: 3,
            viewportHeight: 0,
            spacing: 16, padding: 16, minRowHeight: floor
        )
        XCTAssertEqual(result, [floor, floor, floor])
    }

    /// A single row fills the whole viewport minus its outer padding (no inter-row
    /// gutters), floored.
    func testEvenRowHeightsSingleRowFillsViewport() {
        let viewport: CGFloat = 700
        let result = BrowserWindow.evenRowHeights(
            rowCount: 1,
            viewportHeight: viewport,
            spacing: 16, padding: 16, minRowHeight: 160
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], viewport - 2 * 16, accuracy: 0.001)
    }

    // MARK: - naturalRowHeights (per-row tallest-card aggregation #049)

    /// Each row maps to the TALLEST measured card height among its indices: an
    /// uneven 2-row grid (row 0 = 200 & 150, row 1 = 120 & 90) resolves to its
    /// per-row maxima [200, 120].
    func testNaturalRowHeightsTallestPerRow() {
        let result = BrowserWindow.naturalRowHeights(
            rows: [[0, 1], [2, 3]],
            projectPaths: ["/a", "/b", "/c", "/d"],
            measured: ["/a": 200, "/b": 150, "/c": 120, "/d": 90],
            minRowHeight: 160
        )
        XCTAssertEqual(result, [200, 120])
    }

    /// A row whose cards are ALL unmeasured falls back to the `minRowHeight`
    /// floor; a sibling row with measurements still resolves to its tallest card.
    func testNaturalRowHeightsAllUnmeasuredRowFallsBackToFloor() {
        let result = BrowserWindow.naturalRowHeights(
            rows: [[0, 1], [2, 3]],
            projectPaths: ["/a", "/b", "/c", "/d"],
            measured: ["/c": 240, "/d": 180],
            minRowHeight: 160
        )
        XCTAssertEqual(result, [160, 240])
    }

    /// A short final row (fewer indices than the full width) takes the tallest of
    /// its present cards; ignored/unmeasured siblings don't drag it down.
    func testNaturalRowHeightsShortFinalRow() {
        let result = BrowserWindow.naturalRowHeights(
            rows: [[0, 1], [2]],
            projectPaths: ["/a", "/b", "/c"],
            measured: ["/a": 200, "/b": 150, "/c": 175],
            minRowHeight: 160
        )
        XCTAssertEqual(result, [200, 175])
    }

    /// Stale indices beyond `projectPaths.count` (a mid-render shrink of the
    /// snapshot) are skipped; a row left with no in-bounds measured card falls
    /// back to the floor.
    func testNaturalRowHeightsSkipsStaleIndices() {
        let result = BrowserWindow.naturalRowHeights(
            rows: [[0, 5]],
            projectPaths: ["/a", "/b"],
            measured: ["/a": 210],
            minRowHeight: 160
        )
        XCTAssertEqual(result, [210])
    }

    // MARK: - applyManualOrder (manual override ordering)

    /// Projects are ordered exactly as the `order` array dictates when every
    /// project path appears in it.
    func testApplyManualOrderOrdersByOverride() {
        let a = makeProject(path: "/a", name: "alpha")
        let b = makeProject(path: "/b", name: "bravo")
        let c = makeProject(path: "/c", name: "charlie")

        let ordered = BrowserViewModel.applyManualOrder([a, b, c], order: ["/c", "/a", "/b"])

        XCTAssertEqual(ordered.map(\.projectName), ["charlie", "alpha", "bravo"])
    }

    /// New project paths absent from the saved order sort to the TOP, preserving
    /// their original relative order, ahead of the override-listed projects.
    func testApplyManualOrderPutsNewPathsAtTop() {
        let known = makeProject(path: "/known", name: "known")
        let new1 = makeProject(path: "/new1", name: "new1")
        let new2 = makeProject(path: "/new2", name: "new2")

        // Input order: known, new1, new2. Override only lists "/known".
        let ordered = BrowserViewModel.applyManualOrder(
            [known, new1, new2],
            order: ["/known"]
        )

        // New paths lead (stable in original order), known follows.
        XCTAssertEqual(ordered.map(\.projectName), ["new1", "new2", "known"])
    }

    /// Order entries referencing projects that no longer exist are ignored.
    func testApplyManualOrderIgnoresStalePathsInOrder() {
        let a = makeProject(path: "/a", name: "alpha")
        let b = makeProject(path: "/b", name: "bravo")

        let ordered = BrowserViewModel.applyManualOrder(
            [a, b],
            order: ["/gone", "/b", "/also-gone", "/a"]
        )

        XCTAssertEqual(ordered.map(\.projectName), ["bravo", "alpha"])
    }

    /// An empty order returns the projects in their original order (all "new").
    func testApplyManualOrderEmptyOrderPreservesInput() {
        let a = makeProject(path: "/a", name: "alpha")
        let b = makeProject(path: "/b", name: "bravo")

        let ordered = BrowserViewModel.applyManualOrder([a, b], order: [])

        XCTAssertEqual(ordered.map(\.projectName), ["alpha", "bravo"])
    }

    // MARK: - reorder (compute new order after a drag-drop)

    /// Moving a later item BEFORE an earlier target shifts it up.
    func testReorderMovesItemUpBeforeTarget() {
        let result = BrowserViewModel.reorder(
            ["/a", "/b", "/c", "/d"],
            moving: "/d",
            before: "/b"
        )
        XCTAssertEqual(result, ["/a", "/d", "/b", "/c"])
    }

    /// Moving an earlier item BEFORE a later target shifts it down to just ahead
    /// of the target.
    func testReorderMovesItemDownBeforeTarget() {
        let result = BrowserViewModel.reorder(
            ["/a", "/b", "/c", "/d"],
            moving: "/a",
            before: "/d"
        )
        XCTAssertEqual(result, ["/b", "/c", "/a", "/d"])
    }

    /// Dropping an item onto itself leaves the order unchanged.
    func testReorderOntoSelfIsNoOp() {
        let result = BrowserViewModel.reorder(
            ["/a", "/b", "/c"],
            moving: "/b",
            before: "/b"
        )
        XCTAssertEqual(result, ["/a", "/b", "/c"])
    }

    /// A source path not present in the current order leaves it unchanged.
    func testReorderUnknownSourceIsNoOp() {
        let result = BrowserViewModel.reorder(
            ["/a", "/b"],
            moving: "/zzz",
            before: "/a"
        )
        XCTAssertEqual(result, ["/a", "/b"])
    }

    /// A `nil` target (dropped past the last card, no specific target) appends the
    /// moved item to the END of the order.
    func testReorderNilTargetMovesToEnd() {
        let result = BrowserViewModel.reorder(
            ["/a", "/b", "/c"],
            moving: "/a",
            before: nil
        )
        XCTAssertEqual(result, ["/b", "/c", "/a"])
    }

    // MARK: - manual-order revert control (#017 step 4)

    /// The toolbar revert control's label reads as a recency-sort affordance so
    /// the user understands tapping it leaves the manual order.
    func testManualOrderRevertLabelDescribesRecencySort() {
        XCTAssertEqual(BrowserViewModel.manualOrderRevertLabel, "Sort by Recency")
    }

    // MARK: - ProjectTasks.hasOutstandingWork (#021)

    /// A project with at least one active (outstanding) task reports work.
    func testHasOutstandingWorkTrueWhenActiveTasksPresent() {
        let project = makeProject(
            path: "/p",
            name: "p",
            activeTasks: [makeTask(id: "001", status: .inProgress)]
        )
        XCTAssertTrue(project.hasOutstandingWork)
    }

    /// A project with no active tasks reports no outstanding work, even when it
    /// carries completed tasks in `tasks`.
    func testHasOutstandingWorkFalseWhenNoActiveTasks() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [makeTask(id: "099", status: .completed)],
            activeTasks: []
        )
        XCTAssertFalse(project.hasOutstandingWork)
    }
}
