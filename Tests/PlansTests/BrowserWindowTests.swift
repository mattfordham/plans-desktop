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

    // MARK: - starredRows (#035: active rows + starred-completed rows)

    /// A project with 1 active task and 1 starred COMPLETED task returns BOTH
    /// rows — the starred completed plan stays visible on the card.
    func testStarredRowsIncludesActiveAndStarredCompleted() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [
                makeTask(id: "001", status: .inProgress),
                makeTask(id: "099", status: .completed),
            ],
            activeTasks: [makeTask(id: "001", status: .inProgress)]
        )
        let rows = BrowserViewModel.starredRows(project, starredIDs: ["/p/099"])
        XCTAssertEqual(rows.map(\.id), ["/p/001", "/p/099"])
    }

    /// An un-starred completed task is NOT surfaced — only active rows show.
    func testStarredRowsExcludesUnstarredCompleted() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [
                makeTask(id: "001", status: .inProgress),
                makeTask(id: "099", status: .completed),
            ],
            activeTasks: [makeTask(id: "001", status: .inProgress)]
        )
        let rows = BrowserViewModel.starredRows(project, starredIDs: [])
        XCTAssertEqual(rows.map(\.id), ["/p/001"])
    }

    /// Starred-completed rows are APPENDED after the active rows, preserving the
    /// parser's active order at the front.
    func testStarredRowsAppendsStarredCompletedAfterActive() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [
                makeTask(id: "099", status: .completed),
                makeTask(id: "001", status: .inProgress),
                makeTask(id: "002", status: .pending),
            ],
            activeTasks: [
                makeTask(id: "001", status: .inProgress),
                makeTask(id: "002", status: .pending),
            ]
        )
        let rows = BrowserViewModel.starredRows(project, starredIDs: ["/p/099"])
        XCTAssertEqual(rows.map(\.id), ["/p/001", "/p/002", "/p/099"])
    }

    // MARK: - projectHasStarredTask (#035: keep starred projects past the hide-empty filter)

    /// A project whose ONLY task is a starred completed task reports it has a
    /// starred task, so the hide-empty filter keeps the card visible.
    func testProjectHasStarredTaskTrueForStarredCompletedTask() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [makeTask(id: "099", status: .completed)],
            activeTasks: []
        )
        XCTAssertTrue(
            BrowserViewModel.projectHasStarredTask(project, starredIDs: ["/p/099"])
        )
    }

    /// A project with no starred tasks reports false.
    func testProjectHasStarredTaskFalseWhenNoneStarred() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [
                makeTask(id: "001", status: .inProgress),
                makeTask(id: "099", status: .completed),
            ],
            activeTasks: [makeTask(id: "001", status: .inProgress)]
        )
        XCTAssertFalse(
            BrowserViewModel.projectHasStarredTask(project, starredIDs: [])
        )
    }

    /// A starred id that is ALSO an active task is not duplicated — it appears
    /// once, in its active position.
    func testStarredRowsDoesNotDuplicateActiveTask() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [makeTask(id: "001", status: .inProgress)],
            activeTasks: [makeTask(id: "001", status: .inProgress)]
        )
        let rows = BrowserViewModel.starredRows(project, starredIDs: ["/p/001"])
        XCTAssertEqual(rows.map(\.id), ["/p/001"])
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

    /// STRETCH: rows whose natural total is shorter than the viewport scale UP so
    /// they (plus gutters + padding) fill the viewport exactly, and their relative
    /// proportions are preserved (the 2:1 ratio survives the stretch).
    func testFitRowHeightsStretchesToFillPreservingProportions() {
        let naturals: [CGFloat] = [200, 100] // 2:1, sums to 300
        let viewport: CGFloat = 1000
        let result = BrowserWindow.fitRowHeights(
            naturalRowHeights: naturals,
            viewportHeight: viewport,
            spacing: 16, padding: 16, minRowHeight: 160
        )
        // Rows + chrome fill the viewport.
        let total = result.reduce(0, +) + chrome(rowCount: 2, spacing: 16, padding: 16)
        XCTAssertEqual(total, viewport, accuracy: 0.001)
        // Relative proportion preserved.
        XCTAssertEqual(result[0] / result[1], 2.0, accuracy: 0.001)
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
