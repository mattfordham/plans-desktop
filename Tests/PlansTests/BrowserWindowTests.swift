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
        isKeptWorktree: Bool = false,
        failure: TaskFailure? = nil,
        modified: TimeInterval? = nil,
        created: String? = nil
    ) -> Task {
        Task(
            id: id,
            title: title,
            type: type,
            status: status,
            created: created,
            branch: nil,
            isKeptWorktree: isKeptWorktree,
            blockedBy: [],
            sections: [],
            howProgress: (done: 0, total: 0),
            isBlocked: isBlocked,
            isCompletedDir: false,
            isBacklogged: false,
            failure: failure,
            modified: modified
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

    // MARK: - visibleUnderViewMode (#072/#096: one labelled All / Active view mode)

    /// `.all` keeps every project, including one with NO outstanding work.
    func testVisibleUnderViewModeAllKeepsEmptyProject() {
        let project = makeProject(
            path: "/p",
            name: "p",
            tasks: [makeTask(id: "099", status: .completed)],
            activeTasks: []
        )
        XCTAssertTrue(
            BrowserViewModel.visibleUnderViewMode(project, mode: .all)
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
            BrowserViewModel.visibleUnderViewMode(project, mode: .active)
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
            BrowserViewModel.visibleUnderViewMode(project, mode: .active)
        )
    }

    /// #096: `ProjectViewMode` is exactly All / Active — `.starred` was dropped
    /// because the sidebar's Favourites section already lists starred projects.
    func testProjectViewModeCasesAreAllAndActive() {
        XCTAssertEqual(ProjectViewMode.allCases, [.all, .active])
        XCTAssertEqual(ProjectViewMode.allCases.map(\.label), ["All", "Active"])
    }

    /// #096: the two-mode cycle flips between `.all` and `.active`.
    func testProjectViewModeNextCyclesBetweenAllAndActive() {
        XCTAssertEqual(ProjectViewMode.all.next, .active)
        XCTAssertEqual(ProjectViewMode.active.next, .all)
    }

    // MARK: - ProjectStackView.stackProjects (#096: the "All projects" card list)

    /// `.active` drops projects without outstanding work, keeping manual order.
    func testStackProjectsAppliesManualOrderAndViewMode() {
        let a = makeProject(path: "/a", name: "a",
                            tasks: [makeTask(id: "001", status: .pending)],
                            activeTasks: [makeTask(id: "001", status: .pending)])
        let b = makeProject(path: "/b", name: "b",
                            tasks: [makeTask(id: "002", status: .completed)])
        let c = makeProject(path: "/c", name: "c",
                            tasks: [makeTask(id: "003", status: .inProgress)],
                            activeTasks: [makeTask(id: "003", status: .inProgress)])
        let result = ProjectStackView.stackProjects(
            [a, b, c],
            manualOrderActive: true,
            order: ["/c", "/b", "/a"],
            viewMode: .active
        )
        XCTAssertEqual(result.map(\.projectPath), ["/c", "/a"])
    }

    /// With no manual order active, `.all` keeps every project in recency order
    /// (the same order `sortByStaleness` produces).
    func testStackProjectsFallsBackToRecencyWithoutManualOrder() {
        let a = makeProject(path: "/a", name: "a")
        let b = makeProject(path: "/b", name: "b")
        let result = ProjectStackView.stackProjects(
            [a, b], manualOrderActive: false, order: ["/b", "/a"], viewMode: .all
        )
        XCTAssertEqual(
            result.map(\.projectPath),
            BrowserViewModel.sortByStaleness([a, b]).map(\.projectPath)
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

    /// #077 follow-up: a BACKLOGGED row must resolve too. `ProjectCard`'s
    /// backlog section reuses `planRow`, so a backlogged row carries the same
    /// `OpenDetailOnTap` modifier as an active one and opens the detail pane
    /// with its composite id. But backlogged tasks live in a SEPARATE
    /// `backloggedTasks` collection that is deliberately excluded from
    /// `activeTasks`, so a resolver scanning only `activeRows` can never match
    /// one — the pane fell through to its "Plan not found" placeholder. The
    /// resolver must therefore consult backlog rows as well.
    func testResolveRowFindsBackloggedRow() {
        let project = makeProject(
            path: "/proj1",
            name: "proj1",
            activeTasks: [makeTask(id: "001", status: .inProgress)],
            backloggedTasks: [makeTask(id: "050", status: .pending)]
        )
        let row = BrowserViewModel.resolveRow(in: [project], id: "/proj1/050")
        XCTAssertEqual(row?.id, "/proj1/050")
        XCTAssertEqual(row?.projectPath, "/proj1")
        XCTAssertEqual(row?.task.id, "050")
    }

    /// A backlogged row resolves in the SECOND project even when both projects
    /// reuse the same task id — the composite id disambiguates, exactly as it
    /// does for active rows.
    func testResolveRowFindsBackloggedRowInSecondProject() {
        let p1 = makeProject(
            path: "/proj1",
            name: "proj1",
            backloggedTasks: [makeTask(id: "050", status: .pending)]
        )
        let p2 = makeProject(
            path: "/proj2",
            name: "proj2",
            backloggedTasks: [makeTask(id: "050", status: .pending)]
        )
        let row = BrowserViewModel.resolveRow(in: [p1, p2], id: "/proj2/050")
        XCTAssertEqual(row?.projectPath, "/proj2")
    }

    /// Resolution stays total: an id in neither the active nor the backlog rows
    /// still yields `nil` so the pane shows its placeholder rather than trapping.
    func testResolveRowReturnsNilWhenAbsentFromBothActiveAndBacklog() {
        let project = makeProject(
            path: "/proj1",
            name: "proj1",
            activeTasks: [makeTask(id: "001", status: .inProgress)],
            backloggedTasks: [makeTask(id: "050", status: .pending)]
        )
        XCTAssertNil(BrowserViewModel.resolveRow(in: [project], id: "/proj1/999"))
    }

    /// Active rows take precedence over backlog rows. A task id cannot legitimately
    /// occupy `pending/` and `backlog/` at once (the skills MOVE the file), but if a
    /// stale poll ever surfaced both, the active row is the truthful one — it
    /// reflects the task's live, outstanding state.
    func testResolveRowPrefersActiveRowOverBackloggedDuplicate() {
        let project = makeProject(
            path: "/proj1",
            name: "proj1",
            activeTasks: [makeTask(id: "001", status: .inProgress)],
            backloggedTasks: [makeTask(id: "001", status: .pending)]
        )
        let row = BrowserViewModel.resolveRow(in: [project], id: "/proj1/001")
        XCTAssertEqual(row?.task.status, .inProgress)
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

    // MARK: - BrowserViewModel.validSelection (detail-column selection, #095)

    /// A selection whose row still resolves (an active row) is kept as-is.
    func testValidSelectionKeepsIDThatStillResolves() {
        XCTAssertEqual(
            BrowserViewModel.validSelection("/proj2/001", in: twoProjectFixture()),
            "/proj2/001"
        )
    }

    /// A backlogged row's id is a valid selection — backlog rows open the
    /// detail column just like active rows.
    func testValidSelectionKeepsBacklogRowID() {
        let project = makeProject(
            path: "/proj1",
            name: "proj1",
            backloggedTasks: [makeTask(id: "050", status: .pending)]
        )
        XCTAssertEqual(
            BrowserViewModel.validSelection("/proj1/050", in: [project]),
            "/proj1/050"
        )
    }

    /// A plan that completed (dropped out of `activeTasks`, so no longer in any
    /// row collection) clears the selection.
    func testValidSelectionClearsCompletedPlan() {
        let before = makeProject(
            path: "/proj1",
            name: "proj1",
            activeTasks: [makeTask(id: "001", status: .inProgress)]
        )
        let after = makeProject(path: "/proj1", name: "proj1", activeTasks: [])
        XCTAssertEqual(BrowserViewModel.validSelection("/proj1/001", in: [before]), "/proj1/001")
        XCTAssertNil(BrowserViewModel.validSelection("/proj1/001", in: [after]))
    }

    /// A deleted plan (its id now matches nothing, while siblings remain)
    /// clears the selection.
    func testValidSelectionClearsDeletedPlan() {
        XCTAssertNil(BrowserViewModel.validSelection("/proj1/999", in: twoProjectFixture()))
    }

    /// A deleted backlogged plan clears the selection too.
    func testValidSelectionClearsDeletedBacklogPlan() {
        let project = makeProject(
            path: "/proj1",
            name: "proj1",
            backloggedTasks: [makeTask(id: "050", status: .pending)]
        )
        XCTAssertNil(BrowserViewModel.validSelection("/proj1/051", in: [project]))
    }

    /// When the selected row's project disappears (unlinked), the selection
    /// clears — including the worst case where every project is gone.
    func testValidSelectionClearsWhenProjectIsGone() {
        let remaining = [twoProjectFixture()[1]]
        XCTAssertNil(BrowserViewModel.validSelection("/proj1/001", in: remaining))
        XCTAssertNil(BrowserViewModel.validSelection("/proj1/001", in: []))
    }

    /// No selection stays no selection.
    func testValidSelectionOfNilIsNil() {
        XCTAssertNil(BrowserViewModel.validSelection(nil, in: twoProjectFixture()))
    }

    // MARK: - BrowserViewModel.displayedRows / validSelection(visibleIn:) (#095)

    /// One project with an in-progress, a review, and a backlogged plan — enough
    /// to exercise which rows each sidebar selection displays.
    private func mixedStatusFixture(reviewID: String = "002", reviewStatus: TaskStatus = .review) -> [ProjectTasks] {
        [
            makeProject(
                path: "/proj1",
                name: "proj1",
                activeTasks: [
                    makeTask(id: "001", status: .inProgress),
                    makeTask(id: reviewID, status: reviewStatus),
                ],
                backloggedTasks: [makeTask(id: "050", status: .pending)]
            ),
        ]
    }

    private func displayedIDs(
        _ selection: SidebarSelection,
        _ projects: [ProjectTasks],
        stackProjects: [ProjectTasks]? = nil,
        showBacklog: Bool = false
    ) -> [TaskRow.ID] {
        BrowserViewModel.displayedRows(
            for: selection,
            in: projects,
            stackProjects: stackProjects ?? projects,
            showBacklog: showBacklog
        ).map(\.id)
    }

    /// A smart view displays exactly that view's cross-project rows.
    func testDisplayedRowsForSmartViewMatchesSmartViewRows() {
        let projects = mixedStatusFixture()
        XCTAssertEqual(displayedIDs(.smart(.inProgress), projects), ["/proj1/001"])
        XCTAssertEqual(displayedIDs(.smart(.review), projects), ["/proj1/002"])
        XCTAssertEqual(displayedIDs(.smart(.backlog), projects), ["/proj1/050"])
    }

    /// A project list displays its active rows, plus backlog only when shown.
    func testDisplayedRowsForProjectHonorsShowBacklog() {
        let projects = mixedStatusFixture()
        XCTAssertEqual(displayedIDs(.project("/proj1"), projects), ["/proj1/001", "/proj1/002"])
        XCTAssertEqual(
            displayedIDs(.project("/proj1"), projects, showBacklog: true),
            ["/proj1/001", "/proj1/002", "/proj1/050"]
        )
        XCTAssertEqual(displayedIDs(.project("/missing"), projects), [])
    }

    /// The all-projects card stack displays every STACK project's active rows
    /// (plus backlog when shown) — the grid projects are the view-mode/focus
    /// filtered set, not necessarily every project.
    func testDisplayedRowsForAllProjectsUsesGridProjects() {
        let projects = twoProjectFixture()
        XCTAssertEqual(
            displayedIDs(.allProjects, projects),
            ["/proj1/001", "/proj1/002", "/proj2/001"]
        )
        XCTAssertEqual(
            displayedIDs(.allProjects, projects, stackProjects: [projects[1]]),
            ["/proj2/001"]
        )
        let withBacklog = mixedStatusFixture()
        XCTAssertEqual(
            displayedIDs(.allProjects, withBacklog, showBacklog: true),
            ["/proj1/001", "/proj1/002", "/proj1/050"]
        )
    }

    private func visibleSelection(
        _ id: TaskRow.ID?,
        _ selection: SidebarSelection,
        _ projects: [ProjectTasks],
        showBacklog: Bool = false
    ) -> TaskRow.ID? {
        BrowserViewModel.validSelection(
            id,
            visibleIn: BrowserViewModel.displayedRows(
                for: selection, in: projects, stackProjects: projects, showBacklog: showBacklog
            )
        )
    }

    /// Switching to a smart view that doesn't list the selected plan unloads it.
    func testSwitchingSmartViewThatHidesSelectionClearsIt() {
        XCTAssertNil(visibleSelection("/proj1/001", .smart(.review), mixedStatusFixture()))
    }

    /// Switching to a view that still lists the selected plan keeps it.
    func testSwitchingToViewThatStillContainsSelectionKeepsIt() {
        let projects = mixedStatusFixture()
        XCTAssertEqual(visibleSelection("/proj1/001", .smart(.inProgress), projects), "/proj1/001")
        XCTAssertEqual(visibleSelection("/proj1/001", .project("/proj1"), projects), "/proj1/001")
    }

    /// A poll that moves the selected plan out of the current smart view
    /// (In Progress -> Review) unloads it.
    func testPollMovingSelectionOutOfSmartViewClearsIt() {
        let before = mixedStatusFixture()
        let after = [
            makeProject(
                path: "/proj1",
                name: "proj1",
                activeTasks: [
                    makeTask(id: "001", status: .review),
                    makeTask(id: "002", status: .review),
                ]
            ),
        ]
        XCTAssertEqual(visibleSelection("/proj1/001", .smart(.inProgress), before), "/proj1/001")
        XCTAssertNil(visibleSelection("/proj1/001", .smart(.inProgress), after))
    }

    /// The card stack / a project list containing the selected plan keeps it;
    /// a backlogged selection survives only while backlog rows are shown.
    func testCardGridAndProjectViewContainingSelectionKeepIt() {
        let projects = mixedStatusFixture()
        XCTAssertEqual(visibleSelection("/proj1/002", .allProjects, projects), "/proj1/002")
        XCTAssertEqual(visibleSelection("/proj1/002", .project("/proj1"), projects), "/proj1/002")
        XCTAssertEqual(
            visibleSelection("/proj1/050", .allProjects, projects, showBacklog: true),
            "/proj1/050"
        )
        XCTAssertNil(visibleSelection("/proj1/050", .allProjects, projects))
    }

    /// No selection stays no selection under any view.
    func testValidSelectionVisibleInOfNilIsNil() {
        XCTAssertNil(visibleSelection(nil, .allProjects, mixedStatusFixture()))
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

    // MARK: - Split-view column sizing (#096)

    /// The default window width holds all three columns at their ideal widths,
    /// so the card stack opens at its ideal width rather than being squeezed.
    func testDefaultWindowWidthHoldsAllColumnsAtIdealWidth() {
        XCTAssertGreaterThanOrEqual(
            BrowserWindow.defaultWindowWidth,
            BrowserWindow.sidebarIdealWidth
                + BrowserWindow.contentColumnIdealWidth
                + BrowserWindow.detailIdealWidth
        )
    }

    /// The window minimum still floors at the columns' MINIMUM widths, and the
    /// default window is larger than that minimum.
    func testWindowMinWidthHoldsAllColumnsAtMinimumWidth() {
        XCTAssertGreaterThanOrEqual(
            BrowserWindow.windowMinWidth,
            BrowserWindow.sidebarMinWidth
                + BrowserWindow.contentColumnMinWidth
                + BrowserWindow.detailMinWidth
        )
        XCTAssertLessThan(BrowserWindow.windowMinWidth, BrowserWindow.defaultWindowWidth)
    }

    /// The content column's ideal width sits between its minimum and a single
    /// readable card width — no multi-card ideal any more (#096 dropped the grid).
    func testContentColumnIdealWidthIsAboveMinimum() {
        XCTAssertGreaterThan(BrowserWindow.contentColumnIdealWidth, BrowserWindow.contentColumnMinWidth)
        XCTAssertLessThanOrEqual(BrowserWindow.contentColumnIdealWidth, 600)
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

    // MARK: - moveOrder (sidebar Projects `.onMove` -> manual order, #096)

    /// Moving the first row below the third (`.onMove` destination 3) lands it
    /// after the third, matching SwiftUI's `move(fromOffsets:toOffset:)`.
    func testMoveOrderMovesRowDown() {
        let result = BrowserViewModel.moveOrder(
            ["/a", "/b", "/c", "/d"], fromOffsets: IndexSet(integer: 0), toOffset: 3
        )
        XCTAssertEqual(result, ["/b", "/c", "/a", "/d"])
    }

    /// Moving the last row to destination 0 puts it first.
    func testMoveOrderMovesRowToTop() {
        let result = BrowserViewModel.moveOrder(
            ["/a", "/b", "/c"], fromOffsets: IndexSet(integer: 2), toOffset: 0
        )
        XCTAssertEqual(result, ["/c", "/a", "/b"])
    }

    /// Destination == count appends to the end.
    func testMoveOrderMovesRowToEnd() {
        let result = BrowserViewModel.moveOrder(
            ["/a", "/b", "/c"], fromOffsets: IndexSet(integer: 0), toOffset: 3
        )
        XCTAssertEqual(result, ["/b", "/c", "/a"])
    }

    /// Out-of-range offsets (a stale `.onMove` racing a refresh) leave the order
    /// unchanged instead of trapping.
    func testMoveOrderOutOfRangeIsNoOp() {
        let paths = ["/a", "/b"]
        XCTAssertEqual(
            BrowserViewModel.moveOrder(paths, fromOffsets: IndexSet(integer: 5), toOffset: 0),
            paths
        )
        XCTAssertEqual(
            BrowserViewModel.moveOrder(paths, fromOffsets: IndexSet(integer: 0), toOffset: 9),
            paths
        )
    }

    // MARK: - sidebarGlyph (combined Projects section icon, #097)

    /// A starred project's row uses the filled-star glyph; an unstarred one uses
    /// the folder glyph.
    func testSidebarGlyphReflectsStarredState() {
        XCTAssertEqual(BrowserViewModel.sidebarGlyph(starred: true), "star.fill")
        XCTAssertEqual(BrowserViewModel.sidebarGlyph(starred: false), "folder")
    }

    // MARK: - pinStarredFirst (starred projects lead the sidebar list, #097)

    /// Starred projects move above every unstarred project; each group keeps
    /// its incoming (recency / manual) relative order.
    func testPinStarredFirstFloatsStarredAboveOthersStably() {
        let a = makeProject(path: "/a", name: "alpha")
        let b = makeProject(path: "/b", name: "bravo")
        let c = makeProject(path: "/c", name: "charlie")
        let d = makeProject(path: "/d", name: "delta")

        let pinned = BrowserViewModel.pinStarredFirst([a, b, c, d], starred: ["/d", "/b"])

        XCTAssertEqual(pinned.map(\.projectName), ["bravo", "delta", "alpha", "charlie"])
    }

    /// With nothing starred the order is unchanged.
    func testPinStarredFirstWithNoStarsIsIdentity() {
        let a = makeProject(path: "/a", name: "alpha")
        let b = makeProject(path: "/b", name: "bravo")

        let pinned = BrowserViewModel.pinStarredFirst([a, b], starred: [])

        XCTAssertEqual(pinned.map(\.projectName), ["alpha", "bravo"])
    }

    // MARK: - autoScrollTarget (card-stack edge auto-scroll, #096)

    /// Scrolling down steps from the top-visible card to the next one.
    func testAutoScrollTargetStepsDown() {
        XCTAssertEqual(
            ProjectStackView.autoScrollTarget(in: ["/a", "/b", "/c"], current: "/a", direction: .down),
            "/b"
        )
    }

    /// Scrolling up steps to the previous card.
    func testAutoScrollTargetStepsUp() {
        XCTAssertEqual(
            ProjectStackView.autoScrollTarget(in: ["/a", "/b", "/c"], current: "/c", direction: .up),
            "/b"
        )
    }

    /// At either end there is nowhere to go, so the auto-scroll loop stops.
    func testAutoScrollTargetIsNilAtEdges() {
        XCTAssertNil(ProjectStackView.autoScrollTarget(in: ["/a", "/b"], current: "/a", direction: .up))
        XCTAssertNil(ProjectStackView.autoScrollTarget(in: ["/a", "/b"], current: "/b", direction: .down))
        XCTAssertNil(ProjectStackView.autoScrollTarget(in: [], current: nil, direction: .down))
    }

    /// No recorded scroll position means the stack is at its top: down steps to
    /// the second card, up has nowhere to go.
    func testAutoScrollTargetTreatsNilCurrentAsTop() {
        XCTAssertEqual(
            ProjectStackView.autoScrollTarget(in: ["/a", "/b"], current: nil, direction: .down),
            "/b"
        )
        XCTAssertNil(ProjectStackView.autoScrollTarget(in: ["/a", "/b"], current: nil, direction: .up))
    }

    /// A current id that is no longer displayed (filtered out or removed) is
    /// treated as the top too.
    func testAutoScrollTargetTreatsUnknownCurrentAsTop() {
        XCTAssertEqual(
            ProjectStackView.autoScrollTarget(in: ["/a", "/b"], current: "/gone", direction: .down),
            "/b"
        )
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

    // MARK: - (#094 Step 1) Smart-view rows + summary counts

    private func makeFailure() -> TaskFailure {
        TaskFailure(
            classification: .error,
            errorMessage: "boom",
            stopReason: nil,
            timestamp: "2026-11-07T10:00:00Z"
        )
    }

    func testSmartViewInProgressRowsAcrossProjects() {
        let a = makeProject(
            path: "/a", name: "A",
            activeTasks: [makeTask(id: "001", status: .inProgress),
                          makeTask(id: "002", status: .review)]
        )
        let b = makeProject(
            path: "/b", name: "B",
            activeTasks: [makeTask(id: "003", status: .inProgress)]
        )
        let rows = BrowserViewModel.rows(in: [a, b], matching: .inProgress)
        XCTAssertEqual(rows.map(\.id), ["/a/001", "/b/003"])
    }

    // MARK: - (#101) activeRunItems: the top-bar live-runs indicator

    /// A run on an existing task resolves to that task's row: its title, its
    /// project name, the mode verb, and the row id to open in the detail column.
    func testActiveRunItemForExistingTaskResolvesItsRow() {
        let a = makeProject(
            path: "/a", name: "A",
            activeTasks: [makeTask(id: "001", title: "Fix the thing", status: .pending)]
        )
        let items = BrowserViewModel.activeRunItems(
            from: [RunSnapshot(projectPath: "/a", taskID: "001", mode: .elaborate, description: nil)],
            projects: [a]
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].verb, "Elaborating")
        XCTAssertEqual(items[0].title, "Fix the thing")
        XCTAssertEqual(items[0].projectName, "A")
        XCTAssertEqual(items[0].projectPath, "/a")
        XCTAssertEqual(items[0].rowID, "/a/001")
    }

    /// A capture run has no task yet: it shows its description, has no row to
    /// open, and still names its project.
    func testActiveRunItemForCaptureUsesDescriptionAndHasNoRow() {
        let a = makeProject(path: "/a", name: "A")
        let items = BrowserViewModel.activeRunItems(
            from: [RunSnapshot(projectPath: "/a", taskID: "capture:/a:XYZ",
                               mode: .captureElaborate, description: "Add dark mode")],
            projects: [a]
        )
        XCTAssertEqual(items.map(\.verb), ["Capturing & elaborating"])
        XCTAssertEqual(items.map(\.title), ["Add dark mode"])
        XCTAssertEqual(items.map(\.projectName), ["A"])
        XCTAssertNil(items[0].rowID)
    }

    /// A run whose task is not (or no longer) listed falls back to `#id` and the
    /// project path's last component, so the row is never blank.
    func testActiveRunItemFallsBackWhenTaskOrProjectUnknown() {
        let items = BrowserViewModel.activeRunItems(
            from: [RunSnapshot(projectPath: "/x/proj", taskID: "042", mode: .execute, description: nil)],
            projects: []
        )
        XCTAssertEqual(items.map(\.title), ["#042"])
        XCTAssertEqual(items.map(\.projectName), ["proj"])
        XCTAssertNil(items[0].rowID)
    }

    /// Items are ordered by project name then title, so the list is stable
    /// across polls regardless of dictionary order.
    func testActiveRunItemsAreStablyOrdered() {
        let a = makeProject(path: "/a", name: "Alpha",
                            activeTasks: [makeTask(id: "002", title: "Zed"),
                                          makeTask(id: "001", title: "Apple")])
        let b = makeProject(path: "/b", name: "Beta",
                            activeTasks: [makeTask(id: "003", title: "Mid")])
        let items = BrowserViewModel.activeRunItems(
            from: [RunSnapshot(projectPath: "/b", taskID: "003", mode: .execute, description: nil),
                   RunSnapshot(projectPath: "/a", taskID: "002", mode: .execute, description: nil),
                   RunSnapshot(projectPath: "/a", taskID: "001", mode: .execute, description: nil)],
            projects: [a, b]
        )
        XCTAssertEqual(items.map(\.title), ["Apple", "Zed", "Mid"])
    }

    /// Every run mode has a present-participle verb for the indicator.
    func testRunModeActivityVerbs() {
        XCTAssertEqual(RunMode.execute.activityVerb, "Executing")
        XCTAssertEqual(RunMode.capture.activityVerb, "Capturing")
        XCTAssertEqual(RunMode.executeYolo.activityVerb, "Capturing & executing")
        XCTAssertEqual(RunMode.reElaborate.activityVerb, "Refining")
        XCTAssertEqual(RunMode.delete.activityVerb, "Deleting")
    }

    func testSmartViewReviewCombinesReviewAndInReview() {
        let a = makeProject(
            path: "/a", name: "A",
            activeTasks: [makeTask(id: "001", status: .review),
                          makeTask(id: "002", status: .inReview),
                          makeTask(id: "003", status: .inProgress)]
        )
        let rows = BrowserViewModel.rows(in: [a], matching: .review)
        XCTAssertEqual(Set(rows.map(\.id)), ["/a/001", "/a/002"])
    }

    func testSmartViewBlockedActiveRowsOnly() {
        let a = makeProject(
            path: "/a", name: "A",
            activeTasks: [makeTask(id: "001", status: .inProgress, isBlocked: true),
                          makeTask(id: "002", status: .inProgress)]
        )
        let rows = BrowserViewModel.rows(in: [a], matching: .blocked)
        XCTAssertEqual(rows.map(\.id), ["/a/001"])
    }

    func testSmartViewFailedActiveRowsOnly() {
        let a = makeProject(
            path: "/a", name: "A",
            activeTasks: [makeTask(id: "001", status: .inProgress, failure: makeFailure()),
                          makeTask(id: "002", status: .inProgress)]
        )
        let rows = BrowserViewModel.rows(in: [a], matching: .failed)
        XCTAssertEqual(rows.map(\.id), ["/a/001"])
    }

    func testSmartViewBacklogRowsAcrossProjects() {
        let a = makeProject(
            path: "/a", name: "A",
            backloggedTasks: [makeTask(id: "009", status: .pending)]
        )
        let b = makeProject(
            path: "/b", name: "B",
            backloggedTasks: [makeTask(id: "010", status: .elaborated)]
        )
        let rows = BrowserViewModel.rows(in: [a, b], matching: .backlog)
        XCTAssertEqual(rows.map(\.id), ["/a/009", "/b/010"])
    }

    func testSmartViewLabelsAndVocabulary() {
        XCTAssertEqual(SmartView.inProgress.label, TaskStatus.inProgress.filterLabel)
        XCTAssertEqual(SmartView.review.label, "Review")
        XCTAssertEqual(SmartView.inProgress.symbolName, TaskStatus.inProgress.symbolName)
        XCTAssertEqual(SmartView.review.symbolName, TaskStatus.review.symbolName)
        XCTAssertEqual(SmartView.blocked.symbolName, TaskStatusIndicator.blockedSymbol)
        XCTAssertEqual(SmartView.failed.symbolName, TaskStatusIndicator.failureSymbol)
        // Non-empty labels/icons across every case (totality guard).
        for view in SmartView.allCases {
            XCTAssertFalse(view.label.isEmpty, "empty label for \(view)")
            XCTAssertFalse(view.symbolName.isEmpty, "empty symbol for \(view)")
        }
    }

    // MARK: - (#094 Step 2) Task staleness / sorting / grouping

    func testTaskStalenessUsesModifiedWhenPresent() {
        let t = makeTask(id: "001", modified: 1000)
        XCTAssertEqual(
            BrowserViewModel.taskStalenessDate(t),
            Date(timeIntervalSinceReferenceDate: 1000)
        )
    }

    func testTaskStalenessFallsBackToCreatedISOMinute() {
        let t = makeTask(id: "001", modified: nil, created: "2026-11-07T11:48")
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        fmt.timeZone = TimeZone(identifier: "UTC")
        // Only assert it is non-nil and parses — exact TZ handling is internal.
        XCTAssertNotNil(BrowserViewModel.taskStalenessDate(t))
    }

    func testTaskStalenessFallsBackToCreatedDateOnly() {
        let t = makeTask(id: "001", modified: nil, created: "2026-11-07")
        XCTAssertNotNil(BrowserViewModel.taskStalenessDate(t))
    }

    func testTaskStalenessNilWhenNoDate() {
        let t = makeTask(id: "001", modified: nil, created: nil)
        XCTAssertNil(BrowserViewModel.taskStalenessDate(t))
        let garbage = makeTask(id: "002", modified: nil, created: "not-a-date")
        XCTAssertNil(BrowserViewModel.taskStalenessDate(garbage))
    }

    private func rows(_ project: ProjectTasks) -> [TaskRow] {
        BrowserViewModel.activeRows(project)
    }

    func testSortRowsByStatusPriority() {
        let a = makeProject(
            path: "/a", name: "A",
            activeTasks: [makeTask(id: "001", status: .pending),
                          makeTask(id: "002", status: .inReview),
                          makeTask(id: "003", status: .inProgress)]
        )
        let sorted = BrowserViewModel.sortRows(rows(a), by: .status)
        // Higher activePriority first: in-review(5) > in-progress(3) > pending(1)
        XCTAssertEqual(sorted.map(\.id), ["/a/002", "/a/003", "/a/001"])
    }

    func testSortRowsByProjectName() {
        let a = makeProject(path: "/a", name: "Zed",
                            activeTasks: [makeTask(id: "001", status: .inProgress)])
        let b = makeProject(path: "/b", name: "Alpha",
                            activeTasks: [makeTask(id: "002", status: .inProgress)])
        let all = rows(a) + rows(b)
        let sorted = BrowserViewModel.sortRows(all, by: .project)
        XCTAssertEqual(sorted.map(\.projectName), ["Alpha", "Zed"])
    }

    func testSortRowsByStalenessNewestFirstNilLast() {
        let a = makeProject(
            path: "/a", name: "A",
            activeTasks: [makeTask(id: "001", status: .inProgress, modified: 100),
                          makeTask(id: "002", status: .inProgress, modified: 900),
                          makeTask(id: "003", status: .inProgress, modified: nil, created: nil)]
        )
        let sorted = BrowserViewModel.sortRows(rows(a), by: .staleness)
        // Newest first (900 > 100), the dateless row last.
        XCTAssertEqual(sorted.map(\.id), ["/a/002", "/a/001", "/a/003"])
    }

    func testSortRowsByStalenessStableForTies() {
        let a = makeProject(
            path: "/a", name: "A",
            activeTasks: [makeTask(id: "001", status: .inProgress, modified: 500),
                          makeTask(id: "002", status: .inProgress, modified: 500)]
        )
        let sorted = BrowserViewModel.sortRows(rows(a), by: .staleness)
        XCTAssertEqual(sorted.map(\.id), ["/a/001", "/a/002"])
    }

    func testSortRowsByStalenessUsesCreatedFallback() {
        let a = makeProject(
            path: "/a", name: "A",
            activeTasks: [makeTask(id: "001", status: .inProgress, modified: nil, created: "2026-11-01T09:00"),
                          makeTask(id: "002", status: .inProgress, modified: nil, created: "2026-11-07T11:48")]
        )
        let sorted = BrowserViewModel.sortRows(rows(a), by: .staleness)
        XCTAssertEqual(sorted.map(\.id), ["/a/002", "/a/001"])
    }

    func testGroupRowsByStatusCombinesReview() {
        let a = makeProject(
            path: "/a", name: "A",
            activeTasks: [makeTask(id: "001", status: .review),
                          makeTask(id: "002", status: .inReview),
                          makeTask(id: "003", status: .inProgress)]
        )
        let groups = BrowserViewModel.groupRows(rows(a), by: .status)
        // Review + in-review collapse into one "Review" section.
        let reviewSection = groups.first { $0.title == "Review" }
        XCTAssertNotNil(reviewSection)
        XCTAssertEqual(Set(reviewSection?.rows.map(\.id) ?? []), ["/a/001", "/a/002"])
        XCTAssertTrue(groups.contains { $0.title == TaskStatus.inProgress.filterLabel })
    }

    func testGroupRowsByProject() {
        let a = makeProject(path: "/a", name: "Alpha",
                            activeTasks: [makeTask(id: "001", status: .inProgress)])
        let b = makeProject(path: "/b", name: "Beta",
                            activeTasks: [makeTask(id: "002", status: .inProgress)])
        let groups = BrowserViewModel.groupRows(rows(a) + rows(b), by: .project)
        XCTAssertEqual(groups.map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(groups.first?.rows.map(\.id), ["/a/001"])
    }

    // MARK: - (#094 Step 3) SidebarSelection encoding + fallback

    func testSidebarSelectionAllRoundTrip() {
        let sel = SidebarSelection.allProjects
        XCTAssertEqual(sel.encoded, "all")
        XCTAssertEqual(SidebarSelection(encoded: "all"), .allProjects)
    }

    func testSidebarSelectionSmartRoundTrip() {
        for view in SmartView.allCases {
            let sel = SidebarSelection.smart(view)
            XCTAssertEqual(SidebarSelection(encoded: sel.encoded), sel)
        }
    }

    func testSidebarSelectionProjectRoundTripWithColonAndSlash() {
        let path = "/Users/x/My:Weird/Path"
        let sel = SidebarSelection.project(path)
        XCTAssertEqual(sel.encoded, "project:\(path)")
        XCTAssertEqual(SidebarSelection(encoded: sel.encoded), .project(path))
    }

    func testSidebarSelectionDecodeRejectsGarbage() {
        XCTAssertNil(SidebarSelection(encoded: "bogus"))
        XCTAssertNil(SidebarSelection(encoded: "smart:nope"))
    }

    func testResolveFallsBackToAllWhenProjectMissing() {
        let a = makeProject(path: "/a", name: "A")
        let resolved = BrowserViewModel.resolve(.project("/gone"), in: [a])
        XCTAssertEqual(resolved, .allProjects)
    }

    func testResolveKeepsLiveProject() {
        let a = makeProject(path: "/a", name: "A")
        let resolved = BrowserViewModel.resolve(.project("/a"), in: [a])
        XCTAssertEqual(resolved, .project("/a"))
    }

    func testResolveKeepsSmartAndAll() {
        let a = makeProject(path: "/a", name: "A")
        XCTAssertEqual(BrowserViewModel.resolve(.allProjects, in: [a]), .allProjects)
        XCTAssertEqual(
            BrowserViewModel.resolve(.smart(.inProgress), in: [a]),
            .smart(.inProgress)
        )
    }
}
