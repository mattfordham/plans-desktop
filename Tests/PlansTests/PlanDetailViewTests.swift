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

    /// Ids past 999 are 4+ digits (#090); the full id resolves its own file.
    func testResolvesFourDigitIDFile() throws {
        try writeTaskFile(filename: "100-short.md", in: "pending")
        try writeTaskFile(filename: "1000-wide.md", in: "pending")

        let url = PlanDetailView.taskFileURL(
            projectPath: tempDir.path,
            taskID: "1000",
            isCompletedDir: false
        )

        XCTAssertEqual(url?.lastPathComponent, "1000-wide.md")
    }

    /// The `<id>-` prefix (dash included) keeps `100` from matching `1000-*.md`.
    func testThreeDigitIDDoesNotMatchFourDigitFile() throws {
        try writeTaskFile(filename: "1000-wide.md", in: "pending")

        let url = PlanDetailView.taskFileURL(
            projectPath: tempDir.path,
            taskID: "100",
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

    // MARK: - RunProgressSheet.shouldShowFailureBanner (#081)

    /// A `done`-derived failure (stranded/truncation) latches `error` mid-run
    /// while `isRunning` stays true. The banner must NOT fire in that state —
    /// the run is still live (spinner up, turns climbing); the failure is only
    /// meaningful once the run has actually ended.
    func testFailureBannerSuppressedForDoneDerivedErrorWhileRunning() {
        let stopReason = TaskRun.strandedStopReason
        let message = TaskRun.truncationError(for: stopReason)
        XCTAssertNotNil(message)

        XCTAssertFalse(
            RunProgressSheet.shouldShowFailureBanner(
                error: message,
                isRunning: true,
                stopReason: stopReason
            )
        )
    }

    /// Once the same `done`-derived failure's run has ended (`isRunning ==
    /// false`), the banner fires — the failure is now the terminal outcome.
    func testFailureBannerShownForDoneDerivedErrorOnceEnded() {
        let stopReason = TaskRun.strandedStopReason
        let message = TaskRun.truncationError(for: stopReason)

        XCTAssertTrue(
            RunProgressSheet.shouldShowFailureBanner(
                error: message,
                isRunning: false,
                stopReason: stopReason
            )
        )
    }

    /// A truncating cap failure behaves the same way: suppressed while live,
    /// shown once ended.
    func testFailureBannerSuppressedForTruncatingCapWhileRunning() {
        let stopReason = "error_max_budget_usd"
        let message = TaskRun.truncationError(for: stopReason)
        XCTAssertNotNil(message)

        XCTAssertFalse(
            RunProgressSheet.shouldShowFailureBanner(
                error: message,
                isRunning: true,
                stopReason: stopReason
            )
        )
        XCTAssertTrue(
            RunProgressSheet.shouldShowFailureBanner(
                error: message,
                isRunning: false,
                stopReason: stopReason
            )
        )
    }

    /// A genuine mid-run `.error(message)` event (a real crash / launch failure)
    /// carries an error text that does NOT match any `truncationError` for the
    /// current stop reason. It MUST show immediately, even while `isRunning`.
    func testFailureBannerShownForGenuineErrorWhileRunning() {
        // No stop reason yet (no `done` seen) and a crash-style message.
        XCTAssertTrue(
            RunProgressSheet.shouldShowFailureBanner(
                error: "Failed to launch node: executable not found",
                isRunning: true,
                stopReason: nil
            )
        )
    }

    /// No error → never show the banner, regardless of running state.
    func testFailureBannerHiddenWhenNoError() {
        XCTAssertFalse(
            RunProgressSheet.shouldShowFailureBanner(
                error: nil,
                isRunning: true,
                stopReason: nil
            )
        )
        XCTAssertFalse(
            RunProgressSheet.shouldShowFailureBanner(
                error: nil,
                isRunning: false,
                stopReason: "stranded_at_in_progress"
            )
        )
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

    // MARK: - Review actions (#091 — Execute-more / Re-Elaborate from review)

    /// Both review actions share one eligibility: a plan in `review` / `in-review`
    /// that is NOT blocked and NOT backlogged. This pins the positive case — the
    /// only states where either button renders.
    @MainActor
    func testReviewActionsAreOfferedForReviewAndInReviewWhenEligible() {
        for status in [TaskStatus.review, .inReview] {
            let label = "status \(status.rawValue)"
            XCTAssertTrue(
                PlanDetailView.canExecuteReview(status: status, isBlocked: false,
                                                isBacklogged: false),
                "Execute-more must render for an eligible reviewed plan — \(label)"
            )
            XCTAssertTrue(
                PlanDetailView.canReElaborateReview(status: status, isBlocked: false,
                                                    isBacklogged: false),
                "Re-Elaborate must render for an eligible reviewed plan — \(label)"
            )
        }
    }

    /// The backlog gate holds across EVERY status for both review actions, so no
    /// status combination can smuggle a review action onto a parked plan.
    @MainActor
    func testNoReviewActionSurvivesBacklogAtAnyStatus() {
        let statuses: [TaskStatus?] = TaskStatus.allCases.map { $0 } + [nil]

        for status in statuses {
            for isBlocked in [false, true] {
                let label = "status \(status?.rawValue ?? "nil") / isBlocked=\(isBlocked)"
                XCTAssertFalse(
                    PlanDetailView.canExecuteReview(status: status, isBlocked: isBlocked,
                                                    isBacklogged: true),
                    "Execute-more must stay hidden on a backlogged plan — \(label)"
                )
                XCTAssertFalse(
                    PlanDetailView.canReElaborateReview(status: status, isBlocked: isBlocked,
                                                        isBacklogged: true),
                    "Re-Elaborate must stay hidden on a backlogged plan — \(label)"
                )
            }
        }
    }

    /// The blocked gate holds across EVERY status for both review actions — a
    /// blocked plan offers no review action regardless of status or backlog.
    @MainActor
    func testNoReviewActionSurvivesBlockedAtAnyStatus() {
        let statuses: [TaskStatus?] = TaskStatus.allCases.map { $0 } + [nil]

        for status in statuses {
            for isBacklogged in [false, true] {
                let label = "status \(status?.rawValue ?? "nil") / isBacklogged=\(isBacklogged)"
                XCTAssertFalse(
                    PlanDetailView.canExecuteReview(status: status, isBlocked: true,
                                                    isBacklogged: isBacklogged),
                    "Execute-more must stay hidden on a blocked plan — \(label)"
                )
                XCTAssertFalse(
                    PlanDetailView.canReElaborateReview(status: status, isBlocked: true,
                                                        isBacklogged: isBacklogged),
                    "Re-Elaborate must stay hidden on a blocked plan — \(label)"
                )
            }
        }
    }

    /// Both review actions are gated to the review states: for every NON-review
    /// status they stay withheld even when otherwise eligible (not blocked, not
    /// backlogged), so neither renders on a pending/elaborated/in-progress/etc plan.
    @MainActor
    func testReviewActionsWithheldForNonReviewStatusesWhenOtherwiseEligible() {
        let nonReview = TaskStatus.allCases.filter { $0 != .review && $0 != .inReview }
        let statuses: [TaskStatus?] = nonReview.map { $0 } + [nil]

        for status in statuses {
            let label = "status \(status?.rawValue ?? "nil")"
            XCTAssertFalse(
                PlanDetailView.canExecuteReview(status: status, isBlocked: false,
                                                isBacklogged: false),
                "Execute-more must stay hidden outside review — \(label)"
            )
            XCTAssertFalse(
                PlanDetailView.canReElaborateReview(status: status, isBlocked: false,
                                                    isBacklogged: false),
                "Re-Elaborate must stay hidden outside review — \(label)"
            )
        }
    }

    // MARK: - PlanDetailView.shouldAutoOpenProgress

    func testAutoOpensProgressWhenAlreadyRunningOnAppear() {
        XCTAssertTrue(PlanDetailView.shouldAutoOpenProgress(onAppearRunning: true))
    }

    func testDoesNotAutoOpenProgressWhenNotRunningOnAppear() {
        XCTAssertFalse(PlanDetailView.shouldAutoOpenProgress(onAppearRunning: false))
    }

    // MARK: - PlanDetailView.canDiscuss (#099 — Discuss footer gating)

    /// Discuss is available for a real plan at ANY lifecycle status, including an
    /// undecodable `nil` status: the footer shows whenever there is a plan to ask
    /// about, independent of status. Only blocked / backlogged hide it (below).
    func testCanDiscussTrueForEveryStatusWhenNotBlockedOrBacklogged() {
        let statuses: [TaskStatus?] = TaskStatus.allCases.map { $0 } + [nil]
        for status in statuses {
            XCTAssertTrue(
                PlanDetailView.canDiscuss(status: status, isBlocked: false),
                "Discuss must be offered at status \(status?.rawValue ?? "nil")"
            )
        }
    }

    /// A blocked plan offers no Discuss footer, at any status.
    func testCanDiscussFalseWhenBlocked() {
        let statuses: [TaskStatus?] = TaskStatus.allCases.map { $0 } + [nil]
        for status in statuses {
            XCTAssertFalse(
                PlanDetailView.canDiscuss(status: status, isBlocked: true),
                "Discuss must stay hidden on a blocked plan — status \(status?.rawValue ?? "nil")"
            )
        }
    }

    /// A backlogged plan offers no Discuss footer, at any status — consistent
    /// with the other action gates, which withhold work on parked plans.
    func testCanDiscussFalseWhenBacklogged() {
        let statuses: [TaskStatus?] = TaskStatus.allCases.map { $0 } + [nil]
        for status in statuses {
            XCTAssertFalse(
                PlanDetailView.canDiscuss(status: status, isBlocked: false, isBacklogged: true),
                "Discuss must stay hidden on a backlogged plan — status \(status?.rawValue ?? "nil")"
            )
        }
    }

    // MARK: - PlanDetailView.discussSubmission (#099 — submit-enable/trim)

    /// An empty question yields `nil`, so the send button stays disabled.
    func testDiscussSubmissionEmptyIsNil() {
        XCTAssertNil(PlanDetailView.discussSubmission(""))
    }

    /// A whitespace/newline-only question trims to nothing and yields `nil`.
    func testDiscussSubmissionWhitespaceOnlyIsNil() {
        XCTAssertNil(PlanDetailView.discussSubmission("   \n\t  "))
    }

    /// A real question is returned trimmed of surrounding whitespace/newlines.
    func testDiscussSubmissionTrimsNormalQuestion() {
        XCTAssertEqual(
            PlanDetailView.discussSubmission("  Why is this blocked?\n"),
            "Why is this blocked?"
        )
    }

    // MARK: - PlanDetailView.canSendDiscussion

    /// A real question can be sent while the conversation is idle.
    func testCanSendDiscussionWhenIdleWithQuestion() {
        XCTAssertTrue(PlanDetailView.canSendDiscussion("What does step 3 mean?", isBusy: false))
    }

    /// A blank question can never be sent.
    func testCannotSendBlankDiscussion() {
        XCTAssertFalse(PlanDetailView.canSendDiscussion("  \n ", isBusy: false))
    }

    /// While a turn is pending the composer cannot send another question.
    func testCannotSendDiscussionWhileBusy() {
        XCTAssertFalse(PlanDetailView.canSendDiscussion("Follow-up?", isBusy: true))
    }

    // MARK: - PlanDetailView.shouldAutoOpenProgress (discussion)

    /// A discussion turn never pops the progress sheet — its reply renders inline.
    func testDoesNotAutoOpenProgressForDiscussRun() {
        XCTAssertFalse(PlanDetailView.shouldAutoOpenProgress(onAppearRunning: true, mode: .discuss))
    }

    /// Any other live run still auto-opens on appear.
    func testAutoOpensProgressForExecuteRun() {
        XCTAssertTrue(PlanDetailView.shouldAutoOpenProgress(onAppearRunning: true, mode: .execute))
    }

    // MARK: - PlanDetailView.discussionScrollTarget

    @MainActor
    func testDiscussionScrollTargetIsLastTurn() {
        let thread = DiscussionThread()
        XCTAssertNil(PlanDetailView.discussionScrollTarget(for: thread.turns))
        thread.beginTurn(question: "one")
        thread.apply(.done(costUsd: 0, turns: 1, stopReason: "end_turn"))
        thread.beginTurn(question: "two")
        XCTAssertEqual(PlanDetailView.discussionScrollTarget(for: thread.turns), thread.turns[1].id)
    }

    // MARK: - PlanDetailView.showsConversationPanel

    /// With no turns the detail column is just the plan (composer pinned).
    func testNoConversationPanelWithoutTurns() {
        XCTAssertFalse(PlanDetailView.showsConversationPanel(turnCount: 0))
    }

    /// Once a question has been asked the column splits: plan above, the
    /// conversation panel (transcript + composer) below.
    func testConversationPanelShownOnceThereIsATurn() {
        XCTAssertTrue(PlanDetailView.showsConversationPanel(turnCount: 1))
        XCTAssertTrue(PlanDetailView.showsConversationPanel(turnCount: 4))
    }

    // MARK: - PlanDetailView.canRetry (#079 — failure section + Retry gating)

    /// A healthy task (no failure overlay) never shows the failure section /
    /// Retry affordance.
    func testCanRetryFalseWhenHealthy() {
        XCTAssertFalse(PlanDetailView.canRetry(failure: nil))
    }

    /// Any failure overlay enables the failure section + Retry.
    func testCanRetryTrueWhenFailurePresent() {
        let failure = TaskFailure(
            classification: .stranded,
            errorMessage: nil,
            stopReason: "stranded_at_in_progress",
            timestamp: "2026-01-01T00:00:00Z"
        )
        XCTAssertTrue(PlanDetailView.canRetry(failure: failure))
    }

    // MARK: - PlanDetailView.failureSummary (#079 — failure section header)

    /// With a stop reason, the summary appends it after the classification label.
    func testFailureSummaryWithStopReason() {
        let failure = TaskFailure(
            classification: .truncated,
            errorMessage: "cap hit",
            stopReason: "error_max_turns",
            timestamp: "2026-01-01T00:00:00Z"
        )
        XCTAssertEqual(
            PlanDetailView.failureSummary(failure),
            "Run cut short (budget/turn cap) · error_max_turns"
        )
    }

    /// Without a stop reason, the summary is just the classification label (the
    /// error message is rendered separately, not folded in here).
    func testFailureSummaryWithoutStopReason() {
        let failure = TaskFailure(
            classification: .error,
            errorMessage: "boom",
            stopReason: nil,
            timestamp: "2026-01-01T00:00:00Z"
        )
        XCTAssertEqual(PlanDetailView.failureSummary(failure), "Run errored")
    }

    // MARK: - RunOutcome.Classification.failureLabel (#079)

    func testFailureLabelForEachFailingClassification() {
        XCTAssertEqual(RunOutcome.Classification.truncated.failureLabel,
                       "Run cut short (budget/turn cap)")
        XCTAssertEqual(RunOutcome.Classification.stranded.failureLabel,
                       "Stranded at in-progress")
        XCTAssertEqual(RunOutcome.Classification.error.failureLabel, "Run errored")
        XCTAssertEqual(RunOutcome.Classification.crashed.failureLabel, "Run crashed")
    }

    // MARK: - Review-state Execute dialog (#091)

    /// A review plan's Execute opens `ExecutePendingModal` in review mode: the
    /// guidance box asks for context for another pass, and the Deep toggle (an
    /// elaboration-only option) is hidden since the plan is already elaborated.
    func testExecuteDialogInReviewModeAsksForContextAndHidesDeep() {
        XCTAssertEqual(ExecutePendingModal.placeholder(taskID: "091", forReview: true),
                       "Add optional context for another pass on plan #091…")
        XCTAssertFalse(ExecutePendingModal.offersDeep(forReview: true))
    }

    /// The pending direct-Execute dialog (#088) is unchanged by review mode.
    func testExecuteDialogInPendingModeKeepsGuidanceAndDeep() {
        XCTAssertEqual(ExecutePendingModal.placeholder(taskID: "088", forReview: false),
                       "Add optional guidance for executing plan #088…")
        XCTAssertTrue(ExecutePendingModal.offersDeep(forReview: false))
    }

    // MARK: - Discussion composer stop control

    /// The trailing composer glyph becomes a stop button only while a turn is
    /// pending.
    func testComposerShowsStopOnlyWhileBusy() {
        XCTAssertTrue(PlanDetailView.composerShowsStop(isBusy: true))
        XCTAssertFalse(PlanDetailView.composerShowsStop(isBusy: false))
    }

    // MARK: - MarkdownStyle

    /// The plan style keeps the editorial scale and tinted headings.
    func testPlanMarkdownStyleKeepsEditorialValues() {
        let style = MarkdownStyle.plan
        XCTAssertEqual(style.bodySize, 16)
        XCTAssertEqual(style.lineSpacing, 6)
        XCTAssertEqual(style.blockSpacing, 16)
        XCTAssertEqual(style.listSpacing, 8)
        XCTAssertTrue(style.tintsHeadings)
        XCTAssertNil(style.headingSize(forLevel: 1))
    }

    /// The compact style reads at the system body scale with tighter rhythm
    /// and plain, only modestly larger headings.
    func testCompactMarkdownStyleIsSmallerAndPlain() {
        let style = MarkdownStyle.compact
        XCTAssertEqual(style.bodySize, 13)
        XCTAssertLessThan(style.lineSpacing, MarkdownStyle.plan.lineSpacing)
        XCTAssertLessThan(style.blockSpacing, MarkdownStyle.plan.blockSpacing)
        XCTAssertLessThan(style.listSpacing, MarkdownStyle.plan.listSpacing)
        XCTAssertFalse(style.tintsHeadings)
        for level in 1...4 {
            let size = try? XCTUnwrap(style.headingSize(forLevel: level))
            XCTAssertNotNil(size)
            XCTAssertGreaterThanOrEqual(size ?? 0, style.bodySize)
            XCTAssertLessThanOrEqual(size ?? 0, style.bodySize + 4)
        }
        XCTAssertGreaterThanOrEqual(style.headingSize(forLevel: 1) ?? 0,
                                    style.headingSize(forLevel: 3) ?? 0)
    }
}
