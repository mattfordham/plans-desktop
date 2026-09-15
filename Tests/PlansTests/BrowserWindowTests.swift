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
        isBlocked: Bool = false,
        isKeptWorktree: Bool = false
    ) -> Task {
        Task(
            id: id,
            title: title,
            type: type,
            status: status,
            created: nil,
            branch: nil,
            isKeptWorktree: isKeptWorktree,
            blockedBy: [],
            sections: [],
            howProgress: (done: 0, total: 0),
            isBlocked: isBlocked,
            isCompletedDir: false,
            isBacklogged: false
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
        activeTasks: [Task] = [],
        backloggedTasks: [Task] = []
    ) -> ProjectTasks {
        ProjectTasks(
            projectPath: path,
            projectName: name,
            lastSeen: lastSeen,
            tasks: tasks,
            counts: [:],
            activeTasks: activeTasks,
            backloggedTasks: backloggedTasks
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

    // MARK: - (c1b) backlogRows: one project's backlogged (deferred) rows (#077)

    /// `backlogRows` maps a project's `backloggedTasks` to `TaskRow`s in the SAME
    /// order (the parser's order — no re-sort), with composite ids, mirroring
    /// `activeRows`.
    func testBacklogRowsPreservesOrderWithCompositeIds() {
        let project = makeProject(
            path: "/p",
            name: "p",
            backloggedTasks: [
                makeTask(id: "010", status: .pending),
                makeTask(id: "011", status: .pending),
            ]
        )
        let rows = BrowserViewModel.backlogRows(project)
        XCTAssertEqual(rows.map(\.id), ["/p/010", "/p/011"])
    }

    /// A project carrying no backlogged tasks yields no backlog rows.
    func testBacklogRowsEmptyWhenNoBackloggedTasks() {
        let project = makeProject(path: "/p", name: "p", backloggedTasks: [])
        XCTAssertTrue(BrowserViewModel.backlogRows(project).isEmpty)
    }

    /// `backlogRows` carries the owning project's identity onto each row, exactly
    /// as `activeRows` does.
    func testBacklogRowsCarriesProjectIdentity() {
        let project = makeProject(
            path: "/p",
            name: "myproj",
            backloggedTasks: [makeTask(id: "042", status: .pending)]
        )
        let row = BrowserViewModel.backlogRows(project).first
        XCTAssertEqual(row?.projectPath, "/p")
        XCTAssertEqual(row?.projectName, "myproj")
        XCTAssertEqual(row?.id, "/p/042")
    }

    /// `backlogRows` draws from `backloggedTasks`, NOT `activeTasks` — a project
    /// with active tasks but no backlog yields no backlog rows, and vice versa.
    func testBacklogRowsIndependentOfActiveTasks() {
        let project = makeProject(
            path: "/p",
            name: "p",
            activeTasks: [makeTask(id: "001", status: .inProgress)],
            backloggedTasks: [makeTask(id: "050", status: .pending)]
        )
        XCTAssertEqual(BrowserViewModel.backlogRows(project).map(\.id), ["/p/050"])
        XCTAssertEqual(BrowserViewModel.activeRows(project).map(\.id), ["/p/001"])
    }

    // MARK: - (c2) activeRows(matchingType:) — per-card type filter (#076)

    /// A mixed-type project fixture: a bug then a feature in `activeTasks`, so a
    /// type filter can be shown to keep only the matching rows in order.
    private func mixedTypeProject() -> ProjectTasks {
        makeProject(
            path: "/p",
            name: "p",
            activeTasks: [
                makeTask(id: "001", type: .bug, status: .inProgress),
                makeTask(id: "002", type: .feature, status: .pending),
            ]
        )
    }

    /// A `nil` filter is the pass-through case: it returns EVERY active row
    /// unchanged, matching `activeRows(_:)` exactly (same ids, same order).
    func testActiveRowsMatchingNilReturnsAllRows() {
        let project = mixedTypeProject()
        let unfiltered = BrowserViewModel.activeRows(project)
        let filtered = BrowserViewModel.activeRows(project, matchingType: nil)
        XCTAssertEqual(filtered.map(\.id), unfiltered.map(\.id))
        XCTAssertEqual(filtered.map(\.id), ["/p/001", "/p/002"])
    }

    /// A `.bug` filter keeps ONLY the bug row and drops the feature row.
    func testActiveRowsMatchingTypeKeepsOnlyMatchingRows() {
        let filtered = BrowserViewModel.activeRows(mixedTypeProject(), matchingType: .bug)
        XCTAssertEqual(filtered.map(\.id), ["/p/001"])
        XCTAssertEqual(filtered.first?.type, .bug)
    }

    /// A filter for a type absent from `activeTasks` (`.chore` here) yields an
    /// empty array.
    func testActiveRowsMatchingTypeAbsentYieldsEmpty() {
        let filtered = BrowserViewModel.activeRows(mixedTypeProject(), matchingType: .chore)
        XCTAssertTrue(filtered.isEmpty)
    }

    /// A filter that keeps MULTIPLE rows preserves their original order (the
    /// parser's pre-sort), never re-sorting.
    func testActiveRowsMatchingTypePreservesOrderForMultipleMatches() {
        let project = makeProject(
            path: "/p",
            name: "p",
            activeTasks: [
                makeTask(id: "001", type: .bug, status: .inProgress),
                makeTask(id: "002", type: .feature, status: .pending),
                makeTask(id: "003", type: .bug, status: .pending),
            ]
        )
        let filtered = BrowserViewModel.activeRows(project, matchingType: .bug)
        XCTAssertEqual(filtered.map(\.id), ["/p/001", "/p/003"])
    }

    // MARK: - visibleUnderViewMode (#072: one labelled three-state view mode)

    /// `.all` keeps every project, including one with NO outstanding work.
    func testVisibleUnderViewModeAllKeepsEmptyProject() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [makeTask(id: "099", status: .completed)],
            activeTasks: []
        )
        XCTAssertTrue(
            BrowserViewModel.visibleUnderViewMode(project, mode: .all, starredProjectPaths: [])
        )
    }

    /// `.active` keeps a project that HAS outstanding work.
    func testVisibleUnderViewModeActiveKeepsProjectWithOutstandingWork() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [makeTask(id: "001", status: .inProgress)],
            activeTasks: [makeTask(id: "001", status: .inProgress)]
        )
        XCTAssertTrue(
            BrowserViewModel.visibleUnderViewMode(project, mode: .active, starredProjectPaths: [])
        )
    }

    /// `.active` filters out a project with NO outstanding work.
    func testVisibleUnderViewModeActiveFiltersEmptyProject() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [makeTask(id: "099", status: .completed)],
            activeTasks: []
        )
        XCTAssertFalse(
            BrowserViewModel.visibleUnderViewMode(project, mode: .active, starredProjectPaths: [])
        )
    }

    /// THE BEHAVIOR-CHANGE CRUX — under the OLD "Hide Empty" gate a STARRED but
    /// empty project was rescued by an `|| isStarred` exception. That exception
    /// is deliberately GONE: `.active` means exactly "has outstanding work", so a
    /// starred-but-empty project is filtered out. Curated projects now live in
    /// `.starred`, which is a filter in its own right.
    func testVisibleUnderViewModeActiveFiltersStarredButEmptyProject() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [makeTask(id: "099", status: .completed)],
            activeTasks: []
        )
        XCTAssertFalse(
            BrowserViewModel.visibleUnderViewMode(project, mode: .active, starredProjectPaths: ["/p"])
        )
    }

    /// `.starred` keeps a starred project, even one with no outstanding work.
    func testVisibleUnderViewModeStarredKeepsStarredProject() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [makeTask(id: "099", status: .completed)],
            activeTasks: []
        )
        XCTAssertTrue(
            BrowserViewModel.visibleUnderViewMode(project, mode: .starred, starredProjectPaths: ["/p"])
        )
    }

    /// `.starred` filters out an UNSTARRED project even when it HAS outstanding
    /// work — starred is a curation filter, not an activity filter.
    func testVisibleUnderViewModeStarredFiltersUnstarredProjectWithWork() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [makeTask(id: "001", status: .inProgress)],
            activeTasks: [makeTask(id: "001", status: .inProgress)]
        )
        XCTAssertFalse(
            BrowserViewModel.visibleUnderViewMode(project, mode: .starred, starredProjectPaths: ["/other"])
        )
    }

    // MARK: - visibleUnderFocus (#067: focus mode shows only the focused project)

    /// With no project focused (`nil`), every project is visible.
    func testVisibleUnderFocusTrueWhenNoFocus() {
        let project = makeProject(path: "/p", name: "p")
        XCTAssertTrue(
            BrowserViewModel.visibleUnderFocus(project, focusedProjectPath: nil)
        )
    }

    /// With a focus set, only the project whose path MATCHES is visible.
    func testVisibleUnderFocusTrueForMatchingProject() {
        let project = makeProject(path: "/p", name: "p")
        XCTAssertTrue(
            BrowserViewModel.visibleUnderFocus(project, focusedProjectPath: "/p")
        )
    }

    /// With a focus set, a non-matching project is hidden.
    func testVisibleUnderFocusFalseForNonMatchingProject() {
        let project = makeProject(path: "/p", name: "p")
        XCTAssertFalse(
            BrowserViewModel.visibleUnderFocus(project, focusedProjectPath: "/other")
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

    /// #073: the detail pane feeds `BrowserWindow`'s optional `detailRowID`
    /// straight into `PlanDetailView(rowID:)`, so resolution must stay total over
    /// EVERY id the pane can hold, including ids that go stale while the pane is
    /// open (the store re-reads on a 5s poll and a task can complete underneath
    /// it). Resolving against an empty project list — the worst case, every
    /// project gone — must yield `nil` rather than trapping, so the pane falls
    /// back to its "Plan not found" placeholder instead of crashing.
    func testResolveRowReturnsNilWhenEveryProjectDisappears() {
        let id = BrowserViewModel.activeRows(twoProjectFixture()[0])[0].id
        XCTAssertNotNil(BrowserViewModel.resolveRow(in: twoProjectFixture(), id: id))
        XCTAssertNil(BrowserViewModel.resolveRow(in: [], id: id))
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

    // MARK: - columnCount clamped by card count (#067 focus fills the width)

    /// A single card never leaves empty columns beside it: focus mode (#067)
    /// collapses the grid to ONE card, and the raw width-driven count (4 columns
    /// at 2000pt) would strand it at `cardMinWidth` with three empty columns of
    /// dead space to its right. Clamping by the rendered card count widens the
    /// lone card to the full viewport instead.
    func testColumnCountClampsToSingleCard() {
        XCTAssertEqual(
            BrowserWindow.columnCount(forWidth: 2000, cardCount: 1), 1
        )
    }

    /// Two cards in a 4-column-wide viewport use 2 columns, not 4 — each card
    /// takes half the width rather than a quarter with half the grid empty.
    func testColumnCountClampsToCardCount() {
        XCTAssertEqual(
            BrowserWindow.columnCount(forWidth: 2000, cardCount: 2), 2
        )
    }

    /// The clamp only ever narrows: with MORE cards than the width can fit, the
    /// width-driven count still wins (4 columns at 2000pt for 10 cards) so cards
    /// never shrink below `cardMinWidth`.
    func testColumnCountNotWidenedByExtraCards() {
        XCTAssertEqual(
            BrowserWindow.columnCount(forWidth: 2000, cardCount: 10), 4
        )
    }

    /// An exact match between card count and width capacity is unchanged.
    func testColumnCountUnchangedWhenCardCountMatchesCapacity() {
        XCTAssertEqual(
            BrowserWindow.columnCount(forWidth: 2000, cardCount: 4), 4
        )
    }

    /// The `max(1, …)` floor survives the clamp: an empty grid (no projects yet,
    /// or every project hidden) must not yield 0 columns and divide by zero in
    /// the row math.
    func testColumnCountFloorHoldsAtZeroCards() {
        XCTAssertEqual(
            BrowserWindow.columnCount(forWidth: 2000, cardCount: 0), 1
        )
    }

    /// The clamp composes with the narrow-width floor: one card in a narrow
    /// viewport is still exactly one column.
    func testColumnCountSingleCardInNarrowViewport() {
        XCTAssertEqual(
            BrowserWindow.columnCount(forWidth: 300, cardCount: 1), 1
        )
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

    // MARK: - evenRowHeights (uniform, viewport-divided row heights #045/#057)

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

    /// #057 screenshot case: a 2-row fit grid at the measured viewport (848,
    /// spacing 16, padding 16, floor 160) splits evenly into two equal rows of
    /// `(848 - 48) / 2 = 400` — regardless of which cards land in which row.
    func testEvenRowHeightsScreenshotTwoRowsSplitEvenly() {
        let result = BrowserWindow.evenRowHeights(
            rowCount: 2,
            viewportHeight: 848,
            spacing: 16, padding: 16, minRowHeight: 160
        )
        XCTAssertEqual(result, [400, 400])
    }

    // MARK: - isFocusedSingleCard (#071: the full-height focused-card case)
    //
    // Focus mode (#067) collapses the grid to a single project's card. #071 makes
    // that lone card stretch to fill the whole viewport height. `isFocusedSingleCard`
    // is the pure predicate that decides whether the dedicated full-height render
    // path applies: it must be TRUE only when a project is focused (non-nil path)
    // AND exactly one card is being rendered, and FALSE otherwise.

    /// A focused path with exactly one rendered card IS the full-height case.
    func testIsFocusedSingleCardTrueWhenFocusedAndOneCard() {
        XCTAssertTrue(
            BrowserWindow.isFocusedSingleCard(focusedProjectPath: "/p", cardCount: 1)
        )
    }

    /// No focus (nil path) is never the full-height case, even with one card (e.g.
    /// a single-project registry that isn't in focus mode scrolls normally).
    func testIsFocusedSingleCardFalseWhenNoFocusEvenWithOneCard() {
        XCTAssertFalse(
            BrowserWindow.isFocusedSingleCard(focusedProjectPath: nil, cardCount: 1)
        )
    }

    /// A focused path with more than one rendered card is not the single-card case.
    func testIsFocusedSingleCardFalseWhenFocusedButMultipleCards() {
        XCTAssertFalse(
            BrowserWindow.isFocusedSingleCard(focusedProjectPath: "/p", cardCount: 2)
        )
    }

    /// A focused path with zero rendered cards (e.g. the focused project filtered
    /// away) is not the single-card case.
    func testIsFocusedSingleCardFalseWhenFocusedButNoCards() {
        XCTAssertFalse(
            BrowserWindow.isFocusedSingleCard(focusedProjectPath: "/p", cardCount: 0)
        )
    }

    /// No focus and no cards is likewise false.
    func testIsFocusedSingleCardFalseWhenNoFocusAndNoCards() {
        XCTAssertFalse(
            BrowserWindow.isFocusedSingleCard(focusedProjectPath: nil, cardCount: 0)
        )
    }

    // MARK: - focusedCardHeight (#071: the height the focused card must be given)

    // The focus branch must IMPOSE a concrete height on the card. `ProjectCard`
    // treats `constrainedHeight` only as a boolean signal (switch to the inner
    // ScrollView layout) and deliberately sets no frame of its own, so a caller
    // that forgets the frame leaves the card hugging its content — the #071 bug.
    // `focusedCardHeight` is that value, and it must be non-nil whenever a card
    // is focused so the caller always has a height to apply.

    /// With a measured viewport the focused card fills it minus the outer padding
    /// (chrome == 2*padding; a single row has no inter-row gutter).
    func testFocusedCardHeightFillsViewportMinusPadding() {
        let h = BrowserWindow.focusedCardHeight(viewportHeight: 900)
        XCTAssertEqual(h, 900 - 2 * BrowserWindow.gridPadding, accuracy: 0.001)
    }

    /// Before the viewport is measured (height 0) it falls back to the row floor
    /// rather than nil, so first paint still gets a real frame.
    func testFocusedCardHeightFallsBackToFloorBeforeMeasurement() {
        XCTAssertEqual(
            BrowserWindow.focusedCardHeight(viewportHeight: 0),
            BrowserWindow.fitRowMinHeight,
            accuracy: 0.001
        )
    }

    /// A viewport too short for the floor clamps to the floor and lets the
    /// surrounding ScrollView absorb the overflow (clamp-to-floor contract).
    func testFocusedCardHeightClampsToFloorOnShortViewport() {
        XCTAssertEqual(
            BrowserWindow.focusedCardHeight(viewportHeight: 50),
            BrowserWindow.fitRowMinHeight,
            accuracy: 0.001
        )
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

    // MARK: - shouldOpenNewPlan (#064: re-entrancy guard for the New Plan sheet)
    //
    // The New Plan sheet's open decision is extracted into a pure static helper so
    // the ⌘N re-present race and the "no projects" guard are unit-testable without
    // the store. It returns `nil` when a request is already active (so a second
    // ⌘N / toolbar tap while the sheet is open is a no-op that never re-seeds the
    // binding and wipes the in-flight draft) or when there are no projects,
    // otherwise a fresh request for the staleness-sorted first (most-recently-
    // touched) project.

    /// No projects → no request to open.
    func testShouldOpenNewPlanNilWhenNoProjects() {
        let result = BrowserWindow.shouldOpenNewPlan(
            currentRequest: nil,
            sortedProjects: []
        )
        XCTAssertNil(result)
    }

    /// A request is already active (the sheet is open) → the guard returns `nil`
    /// so a second ⌘N / toolbar tap does NOT re-present and clobber the draft.
    func testShouldOpenNewPlanNilWhenRequestAlreadyActive() {
        let active = NewPlanRequest(projectPath: "/a")
        let projects = [
            makeProject(path: "/a", name: "alpha", lastSeen: "2026-06-04T12:00:00Z"),
            makeProject(path: "/b", name: "bravo", lastSeen: "2026-01-01T00:00:00Z"),
        ]
        let result = BrowserWindow.shouldOpenNewPlan(
            currentRequest: active,
            sortedProjects: projects
        )
        XCTAssertNil(result)
    }

    /// No active request + projects present → a fresh request targeting the FIRST
    /// (staleness-sorted, most-recently-touched) project.
    func testShouldOpenNewPlanTargetsFirstSortedProjectWhenIdle() {
        let projects = BrowserViewModel.sortByStaleness([
            makeProject(path: "/b", name: "bravo", lastSeen: "2026-01-01T00:00:00Z"),
            makeProject(path: "/a", name: "alpha", lastSeen: "2026-06-04T12:00:00Z"),
        ])
        let result = BrowserWindow.shouldOpenNewPlan(
            currentRequest: nil,
            sortedProjects: projects
        )
        XCTAssertEqual(result?.projectPath, "/a")
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
