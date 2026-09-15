import XCTest
@testable import Plans

/// Tests for `PlanDetailView.taskFileURL(projectPath:taskID:isCompletedDir:)`,
/// the pure helper that reconstructs a task's on-disk markdown file by scanning
/// `<projectPath>/.plans/<pending|completed>/` for the first `.md` whose name
/// begins with `<taskID>-`. Fixtures are written into a unique per-test temp
/// directory (the same temp-dir pattern as `TaskParserTests`).
final class PlanDetailViewTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    /// Writes a task file `filename` into `<tempDir>/.plans/<subdir>/`.
    private func writeTaskFile(filename: String, in subdir: String) throws {
        let dir = tempDir
            .appendingPathComponent(".plans")
            .appendingPathComponent(subdir)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        try "# placeholder\n".write(
            to: dir.appendingPathComponent(filename),
            atomically: true,
            encoding: .utf8
        )
    }

    func testResolvesPendingFileByIDPrefix() throws {
        try writeTaskFile(filename: "030-foo.md", in: "pending")

        let url = PlanDetailView.taskFileURL(
            projectPath: tempDir.path,
            taskID: "030",
            isCompletedDir: false
        )

        XCTAssertEqual(url?.lastPathComponent, "030-foo.md")
    }

    func testResolvesCompletedFileByIDPrefix() throws {
        try writeTaskFile(filename: "012-bar.md", in: "completed")

        let url = PlanDetailView.taskFileURL(
            projectPath: tempDir.path,
            taskID: "012",
            isCompletedDir: true
        )

        XCTAssertEqual(url?.lastPathComponent, "012-bar.md")
    }

    func testReturnsNilWhenNoMatchingFileExists() throws {
        // Directory exists but is empty.
        try FileManager.default.createDirectory(
            at: tempDir
                .appendingPathComponent(".plans")
                .appendingPathComponent("pending"),
            withIntermediateDirectories: true
        )

        let url = PlanDetailView.taskFileURL(
            projectPath: tempDir.path,
            taskID: "030",
            isCompletedDir: false
        )

        XCTAssertNil(url)
    }

    func testReturnsNilWhenIDPrefixDiffers() throws {
        try writeTaskFile(filename: "099-other.md", in: "pending")

        let url = PlanDetailView.taskFileURL(
            projectPath: tempDir.path,
            taskID: "030",
            isCompletedDir: false
        )

        XCTAssertNil(url)
    }

    // MARK: - RunProgressSheet.scrollTarget

    func testScrollTargetReturnsLastLineIDForNonEmptyList() {
        let lines = [
            LoggedEvent(event: .text(chunk: "a")),
            LoggedEvent(event: .text(chunk: "b")),
            LoggedEvent(event: .activity(tool: "Read", detail: nil)),
        ]

        XCTAssertEqual(
            RunProgressSheet.scrollTarget(for: lines),
            lines.last?.id
        )
    }

    func testScrollTargetReturnsNilForEmptyList() {
        XCTAssertNil(RunProgressSheet.scrollTarget(for: []))
    }

    // MARK: - PlanDetailView.canDelete gating (#060)

    /// `PlanDetailView.canDelete` is the pure predicate behind the Delete
    /// action's availability, and unlike its siblings (`canWork` gated to
    /// `.elaborated`, `canElaborate` gated to `.pending`) it is deliberately
    /// unconditional: an abandoned plan can sit at ANY lifecycle status, and a
    /// blocked plan is *more* deletable, not less. The real safety gate is the
    /// destructive `NSAlert` confirmation, not availability.
    ///
    /// This sweeps every `TaskStatus` case (via `CaseIterable`, so a new status
    /// is covered automatically) plus the unknown-status `nil`, crossed with
    /// both `isBlocked` values, so the "always available" contract is pinned
    /// down and any future accidental gating fails here.
    @MainActor
    func testCanDeleteIsAvailableForEveryStatusAndBlockedState() {
        let statuses: [TaskStatus?] = TaskStatus.allCases.map { $0 } + [nil]

        for status in statuses {
            for isBlocked in [false, true] {
                XCTAssertTrue(
                    PlanDetailView.canDelete(status: status, isBlocked: isBlocked),
                    "Delete must stay available for status "
                        + "\(status?.rawValue ?? "nil") / isBlocked=\(isBlocked)"
                )
            }
        }
    }

    // MARK: - PlanDetailView.canBacklog / canRestore gating (#077 follow-up)

    /// `canBacklog` is gated to `pending` / `elaborated` ONLY, and this is a
    /// safety rule rather than a cosmetic one: `plan-backlog` auto-pauses an
    /// `in-progress` / `in-review` task, which commits dirty work with
    /// `git add -A` and checks out the default branch. Restricting the button to
    /// the two quiescent statuses means that auto-pause path can never fire from
    /// a single in-app click, so no click can move git state. Backlogging an
    /// active task stays a deliberate CLI action.
    @MainActor
    func testCanBacklogOnlyForPendingAndElaborated() {
        XCTAssertTrue(PlanDetailView.canBacklog(status: .pending, isBlocked: false))
        XCTAssertTrue(PlanDetailView.canBacklog(status: .elaborated, isBlocked: false))

        for status in [TaskStatus.inProgress, .review, .inReview, .completed] {
            XCTAssertFalse(
                PlanDetailView.canBacklog(status: status, isBlocked: false),
                "Backlog must stay hidden for \(status.rawValue) — its auto-pause "
                    + "would commit work and switch branches"
            )
        }
        XCTAssertFalse(PlanDetailView.canBacklog(status: nil, isBlocked: false))
    }

    /// A blocked task is still deferrable — being blocked is a common REASON to
    /// park work — so `isBlocked` does not gate Backlog, matching `canDelete`'s
    /// reasoning rather than `canWork`'s.
    @MainActor
    func testCanBacklogIsNotGatedByBlocked() {
        XCTAssertTrue(PlanDetailView.canBacklog(status: .pending, isBlocked: true))
        XCTAssertTrue(PlanDetailView.canBacklog(status: .elaborated, isBlocked: true))
    }

    /// `canRestore` is driven by the task's SOURCE DIRECTORY, not its status:
    /// backlog is where a task lives, not what state it is in (spec §5.4), and a
    /// restored task keeps its real `pending` / `elaborated` status. So the
    /// predicate keys on `isBacklogged` and must hold across every status a
    /// backlogged file can carry.
    @MainActor
    func testCanRestoreOnlyWhenBacklogged() {
        XCTAssertTrue(PlanDetailView.canRestore(isBacklogged: true))
        XCTAssertFalse(PlanDetailView.canRestore(isBacklogged: false))
    }

    /// Backlog and Restore are mutually exclusive in practice: a task is either
    /// in `pending/` (backloggable) or in `backlog/` (restorable), never both,
    /// because the skills MOVE the file. Pinning that here keeps a future edit
    /// from rendering both buttons at once.
    @MainActor
    func testBacklogAndRestoreAreMutuallyExclusive() {
        // A pending, non-backlogged task: Backlog offered, Restore not.
        XCTAssertTrue(PlanDetailView.canBacklog(status: .pending, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canRestore(isBacklogged: false))

        // A backlogged task: Restore offered. Its status stays pending/elaborated,
        // so `canBacklog` alone would be true — the view must therefore consult
        // `canRestore` / `isBacklogged` to pick which button to show.
        XCTAssertTrue(PlanDetailView.canRestore(isBacklogged: true))
    }

    // MARK: - Work actions are withheld from backlogged plans (#077 follow-up)

    /// A backlogged plan keeps its REAL status (spec §5.4) — backlog is a source
    /// directory, not a status — so an `elaborated` plan sitting in `backlog/`
    /// satisfies `canWork` / `canReElaborate` on status alone, and a `pending`
    /// one satisfies `canElaborate`. That is exactly the trap: the work actions
    /// would render on a plan the user deliberately parked.
    ///
    /// Execute is the harmful case. `plan-execute` on a backlogged task would cut
    /// a branch and start work on deferred plan, and it writes `in-progress` back
    /// into a file under `backlog/` — stranding a task that neither
    /// `/plan-status` nor this app's active views will show. Refine and Elaborate
    /// are merely incoherent (shaping a plan you have set aside).
    ///
    /// So all three are withheld while backlogged: a parked plan offers Restore
    /// and the read-only file actions, nothing else. Restore first, then work it.
    @MainActor
    func testWorkActionsAreWithheldWhileBacklogged() {
        // Execute: `elaborated` would otherwise pass.
        XCTAssertTrue(PlanDetailView.canWork(status: .elaborated, isBlocked: false,
                                             isBacklogged: false))
        XCTAssertFalse(PlanDetailView.canWork(status: .elaborated, isBlocked: false,
                                              isBacklogged: true))

        // Refine: `elaborated` would otherwise pass.
        XCTAssertTrue(PlanDetailView.canReElaborate(status: .elaborated, isBlocked: false,
                                                    isBacklogged: false))
        XCTAssertFalse(PlanDetailView.canReElaborate(status: .elaborated, isBlocked: false,
                                                     isBacklogged: true))

        // Elaborate: `pending` would otherwise pass.
        XCTAssertTrue(PlanDetailView.canElaborate(status: .pending, isBlocked: false,
                                                  isBacklogged: false))
        XCTAssertFalse(PlanDetailView.canElaborate(status: .pending, isBlocked: false,
                                                   isBacklogged: true))
    }

    /// The backlog gate holds across EVERY status a backlogged file can carry, so
    /// no status combination can smuggle a work action onto a parked plan.
    @MainActor
    func testNoWorkActionSurvivesBacklogAtAnyStatus() {
        let statuses: [TaskStatus?] = TaskStatus.allCases.map { $0 } + [nil]

        for status in statuses {
            for isBlocked in [false, true] {
                let label = "status \(status?.rawValue ?? "nil") / isBlocked=\(isBlocked)"
                XCTAssertFalse(
                    PlanDetailView.canWork(status: status, isBlocked: isBlocked,
                                           isBacklogged: true),
                    "Execute must stay hidden on a backlogged plan — \(label)"
                )
                XCTAssertFalse(
                    PlanDetailView.canReElaborate(status: status, isBlocked: isBlocked,
                                                  isBacklogged: true),
                    "Refine must stay hidden on a backlogged plan — \(label)"
                )
                XCTAssertFalse(
                    PlanDetailView.canElaborate(status: status, isBlocked: isBlocked,
                                                isBacklogged: true),
                    "Elaborate must stay hidden on a backlogged plan — \(label)"
                )
            }
        }
    }

    /// A backlogged plan offers Restore INSTEAD of the work actions — the two
    /// halves of the same rule, pinned together so a future edit can't satisfy
    /// one and drop the other.
    @MainActor
    func testBackloggedPlanOffersRestoreAndNoWorkActions() {
        XCTAssertTrue(PlanDetailView.canRestore(isBacklogged: true))
        XCTAssertFalse(PlanDetailView.canWork(status: .elaborated, isBlocked: false,
                                              isBacklogged: true))
        XCTAssertFalse(PlanDetailView.canReElaborate(status: .elaborated, isBlocked: false,
                                                     isBacklogged: true))
        XCTAssertFalse(PlanDetailView.canElaborate(status: .pending, isBlocked: false,
                                                   isBacklogged: true))
    }

    /// `isBacklogged` defaults to `false`, so the predicates keep their existing
    /// two-argument contract for every non-backlog caller.
    @MainActor
    func testIsBackloggedDefaultsToFalseInWorkPredicates() {
        XCTAssertEqual(PlanDetailView.canWork(status: .elaborated, isBlocked: false),
                       PlanDetailView.canWork(status: .elaborated, isBlocked: false,
                                              isBacklogged: false))
        XCTAssertEqual(PlanDetailView.canElaborate(status: .pending, isBlocked: false),
                       PlanDetailView.canElaborate(status: .pending, isBlocked: false,
                                                   isBacklogged: false))
        XCTAssertEqual(PlanDetailView.canReElaborate(status: .elaborated, isBlocked: false),
                       PlanDetailView.canReElaborate(status: .elaborated, isBlocked: false,
                                                     isBacklogged: false))
    }

    // MARK: - PlanDetailView.shouldAutoOpenProgress

    func testAutoOpensProgressWhenAlreadyRunningOnAppear() {
        XCTAssertTrue(PlanDetailView.shouldAutoOpenProgress(onAppearRunning: true))
    }

    func testDoesNotAutoOpenProgressWhenNotRunningOnAppear() {
        XCTAssertFalse(PlanDetailView.shouldAutoOpenProgress(onAppearRunning: false))
    }
}
