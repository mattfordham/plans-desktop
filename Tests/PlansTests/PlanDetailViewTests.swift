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

    // MARK: - RunLogContents.scrollTarget

    func testScrollTargetReturnsLastLineIDForNonEmptyList() {
        let lines = [
            LoggedEvent(event: .text(chunk: "a")),
            LoggedEvent(event: .text(chunk: "b")),
            LoggedEvent(event: .activity(tool: "Read", detail: nil)),
        ]

        XCTAssertEqual(
            RunLogContents.scrollTarget(for: lines),
            lines.last?.id
        )
    }

    func testScrollTargetReturnsNilForEmptyList() {
        XCTAssertNil(RunLogContents.scrollTarget(for: []))
    }

    // MARK: - RunLogContents.shouldShowFailureBanner (#081)

    /// A `done`-derived failure (stranded/truncation) latches `error` mid-run
    /// while `isRunning` stays true. The banner must NOT fire in that state —
    /// the run is still live (spinner up, turns climbing); the failure is only
    /// meaningful once the run has actually ended.
    func testFailureBannerSuppressedForDoneDerivedErrorWhileRunning() {
        let stopReason = TaskRun.strandedStopReason
        let message = TaskRun.truncationError(for: stopReason)
        XCTAssertNotNil(message)

        XCTAssertFalse(
            RunLogContents.shouldShowFailureBanner(
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
            RunLogContents.shouldShowFailureBanner(
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
            RunLogContents.shouldShowFailureBanner(
                error: message,
                isRunning: true,
                stopReason: stopReason
            )
        )
        XCTAssertTrue(
            RunLogContents.shouldShowFailureBanner(
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
            RunLogContents.shouldShowFailureBanner(
                error: "Failed to launch node: executable not found",
                isRunning: true,
                stopReason: nil
            )
        )
    }

    /// No error → never show the banner, regardless of running state.
    func testFailureBannerHiddenWhenNoError() {
        XCTAssertFalse(
            RunLogContents.shouldShowFailureBanner(
                error: nil,
                isRunning: true,
                stopReason: nil
            )
        )
        XCTAssertFalse(
            RunLogContents.shouldShowFailureBanner(
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

    // MARK: - PlanDetailView.canApplyViaDiscussion (#114 — apply-changes gating)

    /// Applying edits via discussion is permitted for the active and
    /// pre-execution statuses — `pending`, `elaborated`, `in-progress`,
    /// `review`, `in-review` — so a user can reshape a live plan in flight (#115).
    /// It is withheld only for `completed` (a finished plan has nothing to
    /// re-shape; reopen is the path) and an undecodable `nil` status (not known
    /// to be safe). The applying turn is write-capable but is a deliberate,
    /// explicit second control routing through `plan-discuss`, scoped to the
    /// single selected plan.
    @MainActor
    func testCanApplyViaDiscussionPermittedForActiveStatuses() {
        for status in [TaskStatus.pending, .elaborated, .inProgress, .review, .inReview] {
            XCTAssertTrue(
                PlanDetailView.canApplyViaDiscussion(status: status,
                                                     isBlocked: false,
                                                     isBacklogged: false),
                "Apply-via-discussion must be offered for \(status.rawValue) — "
                    + "the user can reshape an active plan via discussion"
            )
        }

        XCTAssertFalse(
            PlanDetailView.canApplyViaDiscussion(status: .completed,
                                                 isBlocked: false,
                                                 isBacklogged: false),
            "Apply-via-discussion must stay hidden for completed — "
                + "a finished plan has nothing to re-shape"
        )
        XCTAssertFalse(PlanDetailView.canApplyViaDiscussion(status: nil,
                                                            isBlocked: false,
                                                            isBacklogged: false))
    }

    /// A blocked plan never offers the Apply control, regardless of status: the
    /// `isBlocked` guard is a cross-cutting gate that wins even for the newly
    /// permitted active statuses (`in-progress` / `review` / `in-review`).
    @MainActor
    func testCanApplyViaDiscussionFalseWhenBlocked() {
        for status in [TaskStatus.pending, .elaborated, .inProgress, .review, .inReview] {
            XCTAssertFalse(
                PlanDetailView.canApplyViaDiscussion(status: status,
                                                     isBlocked: true,
                                                     isBacklogged: false),
                "Apply-via-discussion must stay hidden when blocked — status \(status.rawValue)"
            )
        }
    }

    /// A backlogged plan never offers the Apply control, regardless of status:
    /// parked plans get Restore and read-only actions only. The `isBacklogged`
    /// guard is cross-cutting and wins even for the newly permitted active
    /// statuses (`in-progress` / `review` / `in-review`).
    @MainActor
    func testCanApplyViaDiscussionFalseWhenBacklogged() {
        for status in [TaskStatus.pending, .elaborated, .inProgress, .review, .inReview] {
            XCTAssertFalse(
                PlanDetailView.canApplyViaDiscussion(status: status,
                                                     isBlocked: false,
                                                     isBacklogged: true),
                "Apply-via-discussion must stay hidden when backlogged — status \(status.rawValue)"
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

    // MARK: - Placeholder sections (#105)

    /// A section body that is only plans-cc's italic "to be filled" stub is
    /// recognised, and its text returned without the emphasis markers.
    func testPlaceholderTextRecognisesToBeFilledStubs() {
        XCTAssertEqual(PlanDetailView.placeholderText("_To be filled during execution_"),
                       "To be filled during execution")
        XCTAssertEqual(PlanDetailView.placeholderText("  _To be filled during elaboration._\n"),
                       "To be filled during elaboration.")
        XCTAssertEqual(PlanDetailView.placeholderText("_To be filled during elaboration (if 3+ files affected)_"),
                       "To be filled during elaboration (if 3+ files affected)")
        XCTAssertEqual(PlanDetailView.placeholderText("*To be filled during execution*"),
                       "To be filled during execution")
    }

    /// Real content — including content that merely mentions the phrase, or a
    /// stub followed by more lines — is never treated as a placeholder.
    func testPlaceholderTextIgnoresRealContent() {
        XCTAssertNil(PlanDetailView.placeholderText("Upgrade the stack."))
        XCTAssertNil(PlanDetailView.placeholderText("_Note: to be filled in later_"))
        XCTAssertNil(PlanDetailView.placeholderText("_To be filled during elaboration_\n\n- a real step"))
        XCTAssertNil(PlanDetailView.placeholderText(""))
    }

    // MARK: - PlanDetailView.showsProgressPanel (#105 — progress panel gating)

    /// The progress panel shows ONLY while a plan is in-progress AND its How
    /// checklist actually has steps. It stays up at 100% (every step ticked)
    /// because the plan is still in-progress — the panel disappears when the
    /// status transitions, not when the bar fills.
    @MainActor
    func testShowsProgressPanelForInProgressWithSteps() {
        XCTAssertTrue(
            PlanDetailView.showsProgressPanel(status: .inProgress, howProgress: (1, 3)),
            "The panel must show for an in-progress plan with steps underway"
        )
        XCTAssertTrue(
            PlanDetailView.showsProgressPanel(status: .inProgress, howProgress: (3, 3)),
            "The panel must stay up at 100% while the plan is still in-progress"
        )
    }

    /// An in-progress plan with NO checkboxes in its How section — `(0,0)` means
    /// "no steps", not "complete" — has nothing to chart, so the panel is hidden.
    @MainActor
    func testHidesProgressPanelForInProgressWithoutSteps() {
        XCTAssertFalse(
            PlanDetailView.showsProgressPanel(status: .inProgress, howProgress: (0, 0)),
            "The panel must stay hidden when the How section has no checkboxes"
        )
    }

    /// The panel is in-progress ONLY: for every other status (and an undecodable
    /// `nil`) it stays hidden even with steps present. Sweeps `CaseIterable` so a
    /// new status is covered automatically.
    @MainActor
    func testHidesProgressPanelForEveryNonInProgressStatus() {
        let others = TaskStatus.allCases.filter { $0 != .inProgress }
        let statuses: [TaskStatus?] = others.map { $0 } + [nil]
        for status in statuses {
            XCTAssertFalse(
                PlanDetailView.showsProgressPanel(status: status, howProgress: (2, 4)),
                "The panel must stay hidden for status \(status?.rawValue ?? "nil")"
            )
        }
    }

    // MARK: - PlanDetailView.progressFraction (#105 — progress bar value)

    /// The fraction is `done / total` when there are steps.
    @MainActor
    func testProgressFractionIsDoneOverTotal() {
        XCTAssertEqual(PlanDetailView.progressFraction(done: 1, total: 4), 0.25)
        XCTAssertEqual(PlanDetailView.progressFraction(done: 3, total: 3), 1.0)
    }

    /// With zero total the fraction guards divide-by-zero and returns `0`, even
    /// when `done` is zero against a non-zero total too.
    @MainActor
    func testProgressFractionGuardsDivideByZero() {
        XCTAssertEqual(PlanDetailView.progressFraction(done: 0, total: 0), 0.0)
        XCTAssertEqual(PlanDetailView.progressFraction(done: 0, total: 5), 0.0)
    }

    // MARK: - Pinned banner sizing (the banner must never pin the column's min height)

    /// The pinned header's title is capped to a few lines instead of growing to
    /// its full wrapped height, so a long title can't inflate the banner's
    /// minimum height past the window.
    @MainActor
    func testTitleLineLimitIsAFewLines() {
        XCTAssertEqual(PlanDetailView.titleLineLimit, 3)
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

    // MARK: - #083 review gating

    /// Local `Task` fixture builder for the review-gating predicates: lets each
    /// test vary only the fields the predicate reads (status, branch, blocked,
    /// backlogged, kept worktree).
    private func reviewTask(
        id: String,
        status: TaskStatus?,
        branch: String? = "feature/x",
        isBlocked: Bool = false,
        isBacklogged: Bool = false,
        isKeptWorktree: Bool = false
    ) -> Task {
        Task(
            id: id, title: nil, type: nil, status: status, created: nil,
            branch: branch, isKeptWorktree: isKeptWorktree, blockedBy: [],
            sections: [], howProgress: (done: 0, total: 0), isBlocked: isBlocked,
            isCompletedDir: false, isBacklogged: isBacklogged
        )
    }

    /// `canReview` is true for a review/in-review plan with a branch that is not
    /// blocked, not backlogged, and has no live run. A kept worktree is NOT
    /// required (unlike the old assumption).
    func testCanReviewTrueForReviewAndInReviewWithoutKeptWorktree() {
        for status in [TaskStatus.review, .inReview] {
            XCTAssertTrue(
                PlanDetailView.canReview(status: status, branch: "feature/x",
                                         isBlocked: false, isBacklogged: false,
                                         hasLiveRun: false),
                "\(status) with a branch and no live run should be reviewable")
        }
    }

    func testCanReviewFalseWhenGatesFail() {
        // No branch.
        XCTAssertFalse(PlanDetailView.canReview(status: .review, branch: nil,
                                                isBlocked: false, isBacklogged: false,
                                                hasLiveRun: false))
        // Blocked.
        XCTAssertFalse(PlanDetailView.canReview(status: .review, branch: "b",
                                                isBlocked: true, isBacklogged: false,
                                                hasLiveRun: false))
        // Backlogged.
        XCTAssertFalse(PlanDetailView.canReview(status: .review, branch: "b",
                                                isBlocked: false, isBacklogged: true,
                                                hasLiveRun: false))
        // Live run.
        XCTAssertFalse(PlanDetailView.canReview(status: .review, branch: "b",
                                                isBlocked: false, isBacklogged: false,
                                                hasLiveRun: true))
        // Wrong statuses.
        for status in [TaskStatus.pending, .elaborated, .inProgress, .completed] {
            XCTAssertFalse(
                PlanDetailView.canReview(status: status, branch: "b",
                                         isBlocked: false, isBacklogged: false,
                                         hasLiveRun: false),
                "\(status) must not be reviewable")
        }
        // Nil status.
        XCTAssertFalse(PlanDetailView.canReview(status: nil, branch: "b",
                                                isBlocked: false, isBacklogged: false,
                                                hasLiveRun: false))
    }

    /// `availableReviewLocations` always offers worktree + main; kept only when
    /// the task shows the kept-worktree marker.
    func testAvailableReviewLocationsIncludesKeptOnlyWithMarker() {
        let kept = reviewTask(id: "001", status: .review, isKeptWorktree: true)
        XCTAssertTrue(kept.showsKeptWorktreeMarker, "precondition")
        XCTAssertEqual(PlanDetailView.availableReviewLocations(for: kept),
                       [.kept, .worktree, .main])

        let noKept = reviewTask(id: "002", status: .review, isKeptWorktree: false)
        XCTAssertFalse(noKept.showsKeptWorktreeMarker, "precondition")
        XCTAssertEqual(PlanDetailView.availableReviewLocations(for: noKept),
                       [.worktree, .main])
    }

    /// `mainCheckoutOccupant` finds a sibling in review/in-review WITHOUT a kept
    /// worktree (it would be holding the main checkout).
    func testMainCheckoutOccupantFindsReviewSiblingWithoutKeptWorktree() {
        let current = reviewTask(id: "001", status: .review, isKeptWorktree: true)
        let occupant = reviewTask(id: "002", status: .inReview, isKeptWorktree: false)
        let siblings = [current, occupant, reviewTask(id: "003", status: .pending)]

        let found = PlanDetailView.mainCheckoutOccupant(current: current, siblings: siblings)
        XCTAssertEqual(found?.id, "002")
    }

    /// No occupant when every review sibling has a kept worktree, or none is in
    /// review, and the current task is never itself the occupant.
    func testMainCheckoutOccupantNilWhenNoneHoldsMain() {
        let current = reviewTask(id: "001", status: .review, isKeptWorktree: false)
        // Sibling in review but kept → not holding main.
        let kept = reviewTask(id: "002", status: .review, isKeptWorktree: true)
        // Sibling not in review → irrelevant.
        let pending = reviewTask(id: "003", status: .pending, isKeptWorktree: false)
        let siblings = [current, kept, pending]

        XCTAssertNil(PlanDetailView.mainCheckoutOccupant(current: current, siblings: siblings),
                     "current itself must not count; kept + non-review siblings don't hold main")
    }

    // MARK: - Review panel: open-in directory (#083 Step 6)

    /// The open-in-Terminal / open-in-Editor buttons target the WORKTREE path for
    /// a `kept` or `worktree` review, and the PROJECT ROOT for a `main` review.
    func testReviewOpenDirectoryIsWorktreeForKeptAndWorktree() {
        let wt = "/Users/x/.worktrees/007-x"
        let root = "/Users/x/project"
        XCTAssertEqual(
            PlanDetailView.reviewOpenDirectory(location: .kept, worktreePath: wt, projectRoot: root),
            wt)
        XCTAssertEqual(
            PlanDetailView.reviewOpenDirectory(location: .worktree, worktreePath: wt, projectRoot: root),
            wt)
    }

    func testReviewOpenDirectoryIsProjectRootForMain() {
        let wt = "/Users/x/.worktrees/007-x"
        let root = "/Users/x/project"
        XCTAssertEqual(
            PlanDetailView.reviewOpenDirectory(location: .main, worktreePath: wt, projectRoot: root),
            root)
    }

    /// For a `kept`/`worktree` review whose worktree path has not yet been written
    /// (the skill writes it, picked up on the next store refresh), there is no
    /// directory to open — `nil` so the buttons hide.
    func testReviewOpenDirectoryNilForWorktreeLocationsWithoutPath() {
        let root = "/Users/x/project"
        XCTAssertNil(
            PlanDetailView.reviewOpenDirectory(location: .kept, worktreePath: nil, projectRoot: root))
        XCTAssertNil(
            PlanDetailView.reviewOpenDirectory(location: .worktree, worktreePath: nil, projectRoot: root))
        // main always has the project root.
        XCTAssertEqual(
            PlanDetailView.reviewOpenDirectory(location: .main, worktreePath: nil, projectRoot: root),
            root)
    }

    // MARK: - Review panel: answer assembly (#083 Step 6, multiSelect)

    /// A single-select question answers with the one picked label.
    func testReviewAnswerValueSingleSelectIsJoinedChoice() {
        XCTAssertEqual(
            PlanDetailView.reviewAnswerValue(selected: ["Approve"], multiSelect: false),
            "Approve")
    }

    /// A multi-select question joins the picked labels (order preserved).
    func testReviewAnswerValueMultiSelectJoinsChoices() {
        XCTAssertEqual(
            PlanDetailView.reviewAnswerValue(selected: ["A", "B"], multiSelect: true),
            "A, B")
    }

    /// The SDK's AskUserQuestion reads answers keyed by the QUESTION TEXT, not
    /// the header — keying by header leaves the agent seeing no answer.
    func testReviewAnswersAreKeyedByQuestionText() {
        let q = ReviewQuestion(question: "Have the criteria been met?", header: "Verification",
                               options: [ReviewQuestionOption(label: "Yes, met"),
                                         ReviewQuestionOption(label: "No, not met")])
        let answers = PlanDetailView.reviewAnswers(
            questions: [q],
            selections: ["Verification": ["Yes, met"]],
            otherText: [:])
        XCTAssertEqual(answers, ["Have the criteria been met?": "Yes, met"])
    }

    /// Non-empty "Other" text is appended to (or replaces an empty) picked value.
    func testReviewAnswersAppendOtherText() {
        let q1 = ReviewQuestion(question: "Q1?", header: "H1", options: [ReviewQuestionOption(label: "A")])
        let q2 = ReviewQuestion(question: "Q2?", header: "H2", options: [ReviewQuestionOption(label: "B")])
        let answers = PlanDetailView.reviewAnswers(
            questions: [q1, q2],
            selections: ["H1": ["A"]],
            otherText: ["H1": " also this ", "H2": "free text only"])
        XCTAssertEqual(answers, ["Q1?": "A, also this", "Q2?": "free text only"])
    }

    /// No selection yields an empty answer value (callers gate send on non-empty).
    func testReviewAnswerValueEmptyWhenNoneSelected() {
        XCTAssertEqual(PlanDetailView.reviewAnswerValue(selected: [], multiSelect: true), "")
        XCTAssertEqual(PlanDetailView.reviewAnswerValue(selected: [], multiSelect: false), "")
    }

    /// Toggling a choice in single-select REPLACES the selection; in multi-select
    /// it ADDS/REMOVES, honouring `multiSelect`.
    func testReviewToggleSelectionHonoursMultiSelect() {
        // Single-select: picking B replaces A.
        XCTAssertEqual(
            PlanDetailView.reviewToggleSelection(current: ["A"], choice: "B", multiSelect: false),
            ["B"])
        // Multi-select: picking B adds to A.
        XCTAssertEqual(
            PlanDetailView.reviewToggleSelection(current: ["A"], choice: "B", multiSelect: true),
            ["A", "B"])
        // Multi-select: picking A again removes it.
        XCTAssertEqual(
            PlanDetailView.reviewToggleSelection(current: ["A", "B"], choice: "A", multiSelect: true),
            ["B"])
    }

    // MARK: - Review panel: needs-input indicator (#083 Step 6)

    /// The needs-input indicator shows when a review run has a parked question.
    func testReviewNeedsInputReflectsPendingQuestion() {
        XCTAssertTrue(PlanDetailView.reviewNeedsInput(hasPendingQuestion: true))
        XCTAssertFalse(PlanDetailView.reviewNeedsInput(hasPendingQuestion: false))
    }

    // MARK: - Interactive run panel: live and finished gating

    private func outcomeLog() -> RunOutcomeLog {
        RunOutcomeLog(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("run-outcomes.log"))
    }

    @MainActor
    private func interactiveRun(mode: RunMode, ndjson: String = "", finish: Bool,
                                stop: Bool = false) -> TaskRun {
        let run = TaskRun(taskID: "083", mode: mode,
                          reviewLocation: mode == .review ? .main : nil,
                          outcomeLog: outcomeLog())
        run.markRunningForTesting(projectPath: "/proj")
        if !ndjson.isEmpty { run.ingestForTesting(ndjson) }
        if stop { run.stop() } else if finish { run.finishForTesting(projectPath: "/proj") }
        return run
    }

    private let cleanFinish = #"{"kind":"reply","text":"Summary","sessionId":"s"}"# + "\n"
        + #"{"kind":"done","costUsd":0.1,"turns":2,"stopReason":"end_turn"}"# + "\n"

    @MainActor
    func testFinishedReviewRunOnlyForCleanlyFinishedReview() {
        // Clean finish -> shown.
        XCTAssertNotNil(PlanDetailView.finishedReviewRun(
            interactiveRun(mode: .review, ndjson: cleanFinish, finish: true)))
        // Still running -> not finished.
        XCTAssertNil(PlanDetailView.finishedReviewRun(
            interactiveRun(mode: .review, ndjson: cleanFinish, finish: false)))
        // Errored -> not shown.
        XCTAssertNil(PlanDetailView.finishedReviewRun(
            interactiveRun(mode: .review,
                           ndjson: #"{"kind":"error","message":"boom"}"# + "\n",
                           finish: true)))
        // Truncated by a cap -> error latched -> not shown.
        XCTAssertNil(PlanDetailView.finishedReviewRun(
            interactiveRun(mode: .review,
                           ndjson: #"{"kind":"done","costUsd":1,"turns":9,"stopReason":"error_max_turns"}"# + "\n",
                           finish: true)))
        // Stopped by the user (no done) -> not shown.
        XCTAssertNil(PlanDetailView.finishedReviewRun(
            interactiveRun(mode: .review, finish: false, stop: true)))
        // Other modes -> not shown.
        XCTAssertNil(PlanDetailView.finishedReviewRun(
            interactiveRun(mode: .complete, ndjson: cleanFinish, finish: true)))
        XCTAssertNil(PlanDetailView.finishedReviewRun(
            interactiveRun(mode: .execute, ndjson: cleanFinish, finish: true)))
        XCTAssertNil(PlanDetailView.finishedReviewRun(nil))
    }

    // MARK: - Complete action gating

    func testCanCompleteForInReviewPlanWithBranch() {
        XCTAssertTrue(PlanDetailView.canComplete(status: .inReview, branch: "feature/x",
                                                 isBlocked: false, isBacklogged: false,
                                                 hasLiveRun: false))
    }

    func testCanCompleteFalseWhenGatesFail() {
        XCTAssertFalse(PlanDetailView.canComplete(status: .inReview, branch: nil,
                                                  isBlocked: false, isBacklogged: false,
                                                  hasLiveRun: false))
        XCTAssertFalse(PlanDetailView.canComplete(status: .inReview, branch: "",
                                                  isBlocked: false, isBacklogged: false,
                                                  hasLiveRun: false))
        XCTAssertFalse(PlanDetailView.canComplete(status: .inReview, branch: "b",
                                                  isBlocked: true, isBacklogged: false,
                                                  hasLiveRun: false))
        XCTAssertFalse(PlanDetailView.canComplete(status: .inReview, branch: "b",
                                                  isBlocked: false, isBacklogged: true,
                                                  hasLiveRun: false))
        XCTAssertFalse(PlanDetailView.canComplete(status: .inReview, branch: "b",
                                                  isBlocked: false, isBacklogged: false,
                                                  hasLiveRun: true))
        for status in [TaskStatus.pending, .elaborated, .inProgress, .review, .completed] {
            XCTAssertFalse(PlanDetailView.canComplete(status: status, branch: "b",
                                                      isBlocked: false, isBacklogged: false,
                                                      hasLiveRun: false),
                           "\(status) must not offer Complete")
        }
        XCTAssertFalse(PlanDetailView.canComplete(status: nil, branch: "b",
                                                  isBlocked: false, isBacklogged: false,
                                                  hasLiveRun: false))
    }

    /// The confirmation names the task and branch and states that it merges into
    /// the target branch and archives the task.
    func testCompleteConfirmationNamesTaskBranchAndConsequences() {
        let text = PlanDetailView.completeConfirmation(taskID: "083",
                                                       title: "Guided Review",
                                                       branch: "feature/083-x")
        XCTAssertTrue(text.title.contains("#083"))
        XCTAssertTrue(text.message.contains("Guided Review"))
        XCTAssertTrue(text.message.contains("feature/083-x"))
        XCTAssertTrue(text.message.localizedCaseInsensitiveContains("merge"))
        XCTAssertTrue(text.message.localizedCaseInsensitiveContains("target branch"))
        XCTAssertTrue(text.message.localizedCaseInsensitiveContains("archive"))
    }

    // MARK: - Failure banner honours mode-specific truncation copy

    func testFailureBannerSuppressesReviewTruncationWhileRunning() {
        let error = TaskRun.truncationError(for: "error_max_turns", mode: .review)
        XCTAssertFalse(RunLogContents.shouldShowFailureBanner(
            error: error, isRunning: true, stopReason: "error_max_turns", mode: .review))
        XCTAssertTrue(RunLogContents.shouldShowFailureBanner(
            error: error, isRunning: false, stopReason: "error_max_turns", mode: .review))
    }

    // MARK: - AgentDock.dockFooterMode (#117 — the docked agent panel footer)

    /// An idle agent shows the composer, whatever `canDiscuss` says — the agent
    /// is the single gate, and an idle agent accepts a fresh turn.
    @MainActor
    func testDockFooterModeIdleShowsComposer() {
        XCTAssertEqual(AgentDock.dockFooterMode(state: .idle, canDiscuss: true), .composer)
    }

    /// An idle agent on a plan that can't be discussed (blocked / backlogged)
    /// shows nothing in the footer — there is no turn to start.
    @MainActor
    func testDockFooterModeIdleWithoutDiscussShowsNothing() {
        XCTAssertEqual(AgentDock.dockFooterMode(state: .idle, canDiscuss: false), .none)
    }

    /// A working agent (any mode) shows the disabled "stop to interrupt" footer.
    @MainActor
    func testDockFooterModeWorkingShowsDisabled() {
        XCTAssertEqual(AgentDock.dockFooterMode(state: .working(.execute), canDiscuss: true),
                       .disabled)
        XCTAssertEqual(AgentDock.dockFooterMode(state: .working(.discuss), canDiscuss: true),
                       .disabled)
        // Working wins even when the plan can't be discussed.
        XCTAssertEqual(AgentDock.dockFooterMode(state: .working(.review), canDiscuss: false),
                       .disabled)
    }

    /// A needs-input agent shows the parked question form.
    @MainActor
    func testDockFooterModeNeedsInputShowsQuestion() {
        XCTAssertEqual(AgentDock.dockFooterMode(state: .needsInput, canDiscuss: true), .question)
        XCTAssertEqual(AgentDock.dockFooterMode(state: .needsInput, canDiscuss: false), .question)
    }
}
