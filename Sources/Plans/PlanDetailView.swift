import SwiftUI
import AppKit

/// Editorial typography for the plan-detail markdown surface: a larger,
/// airier scale than the system defaults so plan bodies read like a document
/// rather than a dense form. Centralized here so the body, lists, quotes, and
/// code blocks share one rhythm — change the feel in one place.
private enum PlanType {
    /// Base reading size for body text, list items, and code — larger than the
    /// system `.body` (~13pt) for a roomier, editorial measure.
    static let bodySize: CGFloat = 16
    /// Extra leading added between wrapped lines within a paragraph.
    static let lineSpacing: CGFloat = 6
    /// Vertical gap between sibling blocks in a section body.
    static let blockSpacing: CGFloat = 16
    /// Vertical gap between rows of a list.
    static let listSpacing: CGFloat = 8
    /// Gap between a section heading and its body / between sections' blocks.
    static let sectionSpacing: CGFloat = 12
}

/// A self-contained renderer for a single plan's detail body (§011). This is the
/// content surface hosted by the browser window's plan-detail modal overlay pane
/// (#073, `BrowserWindow.detailOverlay`): the title, the owning project + status
/// line, and each `## ` section rendered as markdown (the `## How` section as a
/// read-only checklist, §2 — never interactive). It is host-agnostic — it renders
/// only its own body, no window/pane chrome — so it needed no changes when the
/// former standalone detail window was replaced by the in-window pane.
///
/// It resolves its row from the injected `PlansStore` by composite id via the
/// shared `BrowserViewModel.resolveRow(in:id:)`, so it stays live as the store
/// re-reads. It carries NO Close button — the hosting overlay pane owns
/// dismissal (click the scrim or press Esc, #073). When the id can't be
/// resolved (the plan completed, the project disappeared, or `rowID` is nil) it shows a muted
/// "Plan not found" placeholder. The view itself ONLY reads from the store — it
/// never opens a `.plans/` file for writing. Its Elaborate / Refine / Execute /
/// Delete actions mutate nothing in-process; each one spawns the bundled runner
/// subprocess, the sole writer of `.plans/`, which drives the corresponding
/// plans-cc skill (§2).
struct PlanDetailView: View {
    /// The composite row id (`projectPath + "/" + task.id`) to render, or `nil`
    /// when no plan is targeted (renders the placeholder).
    let rowID: TaskRow.ID?

    @Environment(PlansStore.self) private var store

    /// The shared task-run coordinator, injected by the scene. Resolves the
    /// `TaskRun` for this view's task — driving the Elaborate/Execute actions,
    /// the inline running state, and the progress sheet.
    @Environment(TaskRunner.self) private var runner

    /// Whether the progress sheet is presented. Raised ONLY when this task is
    /// already running as the window appears (the `.onAppear` already-running
    /// case, gated by `shouldAutoOpenProgress(onAppearRunning:)`) or by the
    /// header's "Show progress" button; lowered by the sheet's Done button. A
    /// fresh run started from THIS view deliberately does NOT raise it (#061) —
    /// matching the dashboard, where Execute starts the run without popping the
    /// sheet. Kept as real view state (rather than binding the sheet to the run's
    /// `isRunning`) so the user can close the sheet WITHOUT the close being
    /// swallowed and without stopping the run — dismissing is decoupled from the
    /// run's lifecycle.
    @State private var showProgress = false

    /// Whether the "Refine Plan" sheet (#056) is presented. Raised by the
    /// "Refine" header action (only shown for an elaborated, non-blocked task)
    /// and lowered by the sheet's own Cancel/Refine. Drives the
    /// `ReElaborateModal` for THIS view's task.
    @State private var showReElaborate = false

    /// Whether the "Elaborate" sheet (#074) is presented. Raised by the
    /// "Elaborate" header action (only shown for a pending, non-blocked task)
    /// and lowered by the sheet's own Cancel/Elaborate. Drives the
    /// `ElaborateModal` for THIS view's task. Kept separate from
    /// `showReElaborate` since the two actions are gated to disjoint statuses.
    @State private var showElaborate = false

    /// Whether the pending direct-"Execute" sheet (#088) is presented. Raised by
    /// the header's "Execute" action for a PENDING plan (only shown for a pending,
    /// non-blocked, non-backlogged task — `canExecutePending`) and lowered by the
    /// sheet's own Cancel/Execute. Drives the `ExecutePendingModal` for THIS view's
    /// task, which hands the plan to `plan-execute` to auto-elaborate inline and
    /// then execute. Kept separate from `showExecute` since the two actions gate to
    /// disjoint statuses (pending vs elaborated).
    @State private var showExecutePending = false

    /// Whether the "Execute" sheet (#078) is presented. Raised by the "Execute"
    /// header action (only shown for an elaborated/in-progress, non-blocked task)
    /// and lowered by the sheet's own Cancel/Execute. Drives the `ExecuteModal`
    /// for THIS view's task, which offers the Keep toggle before launching the
    /// run the button used to fire directly.
    @State private var showExecute = false

    /// Whether the "Re-elaborate for review" sheet (#091) is presented. Raised by
    /// the "Refine" header action for a REVIEW-state plan (only shown for a
    /// review/in-review, non-blocked, non-backlogged task — `canReElaborateReview`)
    /// and lowered by the sheet's own Cancel/Refine. Drives the
    /// `ReviewReElaborateModal` for THIS view's task, which resets the plan to
    /// pending and re-elaborates it. Kept separate from `showReElaborate` since
    /// that gates to the elaborated state while this gates to review.
    @State private var showReviewReElaborate = false

    /// The resolved row for `rowID` across all projects' active rows, or `nil`
    /// when absent. Re-derived from the live store on each render.
    private var row: TaskRow? {
        guard let rowID else { return nil }
        return BrowserViewModel.resolveRow(in: store.projects, id: rowID)
    }

    var body: some View {
        Group {
            if let row {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        detailHeader(row)
                        // #079: a PERSISTENT failure section (not a transient
                        // banner) when the latest run for this task failed. Reuses
                        // the `errorBanner` visual style and offers a Retry that
                        // re-runs via the same Execute consent gate.
                        if let failure = row.task.failure {
                            failureSection(row, failure: failure)
                        }
                        ForEach(Array(row.task.sections.enumerated()), id: \.offset) { _, section in
                            sectionView(section)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
                }
                .textSelection(.enabled)
            } else {
                VStack {
                    Text("Plan not found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // If this task is ALREADY running when the window opens (e.g. the user
        // clicked the card spinner to come here), pop the progress sheet right
        // away. This is the ONLY auto-open path (#022): a fresh run started from
        // this view does NOT pop the sheet (#061) — the header's "Show progress"
        // button is the deliberate re-entry. The rule is encoded in the pure
        // `shouldAutoOpenProgress(onAppearRunning:)` helper.
        .onAppear {
            if let row,
               PlanDetailView.shouldAutoOpenProgress(
                   onAppearRunning: runner.isRunning(taskID: row.task.id, in: row.projectPath)
               ) {
                showProgress = true
            }
        }
        // The modal progress sheet. Presented via real view state so the Done
        // button / auto-dismiss can actually close it; `onDisappear` reloads the
        // store so the task's new status is surfaced by the existing read path.
        // Closing the sheet does NOT stop the run — it keeps going in the
        // background (and stays visible on the card row's inline status).
        .sheet(isPresented: $showProgress) {
            RunProgressSheet(run: row.map { runner.run(for: $0.task.id, in: $0.projectPath) } ?? nil,
                             taskID: row?.task.id)
                .onDisappear {
                    if let row { runner.dismiss(taskID: row.task.id, in: row.projectPath) }
                    store.reload()
                }
        }
        // The "Refine Plan" sheet (#056). Presented only when a row is resolved
        // (the Refine action that raises this only renders inside the `if let
        // row` header), so the unwrap is safe; if the row vanished mid-sheet we
        // render nothing rather than crash.
        .sheet(isPresented: $showReElaborate) {
            if let row {
                ReElaborateModal(taskID: row.task.id, projectPath: row.projectPath)
            }
        }
        // The "Elaborate" sheet (#074). Presented only when a row is resolved
        // (the Elaborate action that raises this only renders inside the `if let
        // row` header), so the unwrap is safe; if the row vanished mid-sheet we
        // render nothing rather than crash — same shape as the Refine sheet.
        .sheet(isPresented: $showElaborate) {
            if let row {
                ElaborateModal(taskID: row.task.id, projectPath: row.projectPath)
            }
        }
        // The pending direct-"Execute" sheet (#088). Same row-resolution shape as
        // the sheets around it: the Execute action that raises it only renders
        // inside the `if let row` header for a pending plan, so the unwrap is safe.
        // The `ExecutePendingModal` hands the OPTIONAL guidance plus the Deep and
        // Keep flags to the runner in `.execute` mode, which auto-elaborates the
        // plan inline and then executes it.
        .sheet(isPresented: $showExecutePending) {
            if let row {
                ExecutePendingModal(taskID: row.task.id, projectPath: row.projectPath,
                                    forReview: Self.canExecuteReview(status: row.task.status,
                                                                     isBlocked: row.task.isBlocked,
                                                                     isBacklogged: row.task.isBacklogged))
            }
        }
        // The "Execute" sheet (#078). Same row-resolution shape as the two sheets
        // above: the Execute action that raises it only renders inside the `if
        // let row` header, so the unwrap is safe. The `ExecuteModal` hands the
        // Keep flag to the runner in `.execute` mode; with Keep off it spawns
        // exactly the run this button used to fire directly.
        .sheet(isPresented: $showExecute) {
            if let row {
                ExecuteModal(taskID: row.task.id, projectPath: row.projectPath)
            }
        }
        // The "Re-elaborate for review" sheet (#091). Same row-resolution shape as
        // the sheets above: the Refine action that raises it only renders inside
        // the `if let row` header for a review-state plan, so the unwrap is safe.
        // The `ReviewReElaborateModal` hands the OPTIONAL guidance plus the Deep
        // flag to the runner in `.reElaborateReview` mode, which resets the plan to
        // pending and re-elaborates it.
        .sheet(isPresented: $showReviewReElaborate) {
            if let row {
                ReviewReElaborateModal(taskID: row.task.id, projectPath: row.projectPath)
            }
        }
        // NOTE: dismissing the detail pane deliberately does NOT stop the run.
        // Runs are independent of any presentation (they can be launched straight
        // from a card), so a run survives closing the detail; stop it explicitly
        // via the sheet's Stop button or the card.
    }

    /// The detail header: the title as a prominent heading, the owning project's
    /// name (since there is no longer a selected sidebar project for context),
    /// plus a status line (the type badge and the status's `filterLabel`).
    private func detailHeader(_ row: TaskRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.projectName)
                .font(.body)
                .foregroundStyle(.secondary)

            Text(row.title ?? "(untitled)")
                .font(.title)
                .fontWeight(.semibold)

            HStack(spacing: 6) {
                // The status icon + color (blocked takes precedence), matching
                // the cards and the menu-bar glance via the same `symbolName`.
                let indicator = row.indicator
                Image(systemName: indicator.symbolName)
                    .imageScale(.medium)
                    .foregroundStyle(indicator.color)
                    .frame(width: 20, alignment: .center)
                if row.task.isBlocked {
                    Text("Blocked")
                        .foregroundStyle(TaskStatusIndicator.blockedColor)
                } else if let status = row.task.status {
                    Text(status.filterLabel)
                }
                if let type = row.type {
                    Text("·").foregroundStyle(.secondary)
                    Text("[\(type.label)]")
                }
                // A kept-worktree task (executed with the `keep` keyword) shows a
                // muted house glyph — the desktop analogue of the plans-cc
                // dashboard TUI's `⌂ kept` marker — matching the browser card row.
                // The `**Worktree:**` field can also appear on in-progress tasks,
                // so `showsKeptWorktreeMarker` (not `isKeptWorktree`) restricts the
                // display to review-state rows, shared with the browser card (#086).
                if row.task.showsKeptWorktreeMarker {
                    Text("·").foregroundStyle(.secondary)
                    Image(systemName: TaskStatusIndicator.keptWorktreeSymbol)
                        .imageScale(.small)
                        .help("Kept in worktree — reviewable in isolation")
                }
            }
            .font(.body)
            .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                if runner.isRunning(taskID: row.task.id, in: row.projectPath) {
                    // This task is being worked: show live status + a way back
                    // into the progress sheet (the run is independent of this
                    // window now). No action buttons while it runs.
                    ProgressView().controlSize(.small)
                    Button("Show progress") { showProgress = true }
                } else {
                    // "Elaborate" — hands a pending plan off to the bundled
                    // runner in autonomous `plan-elaborate` mode. Available only
                    // for a pending, non-blocked task. Since #074 it opens the
                    // `ElaborateModal` first (optional guidance + Deep) instead
                    // of firing the run straight off the button; submitting the
                    // sheet with an empty box behaves exactly as before.
                    if Self.canElaborate(status: row.task.status,
                                         isBlocked: row.task.isBlocked,
                                         isBacklogged: row.task.isBacklogged) {
                        Button {
                            showElaborate = true
                        } label: {
                            Label("Elaborate", systemImage: "sparkles")
                        }
                    }

                    // "Execute" (direct) — hands a PENDING plan straight to the
                    // bundled runner's worktree-isolated `plan-execute` mode,
                    // which auto-elaborates it inline (optionally Deep + with
                    // guidance) and then executes it (#088). Available only for a
                    // pending, non-blocked, non-backlogged task — the same gate as
                    // Elaborate above — so a pending plan shows Elaborate + Execute
                    // side by side. Opens the `ExecutePendingModal` rather than
                    // firing the run straight off the button. `canExecutePending`
                    // is intentionally disjoint from `canWork` (which stays
                    // elaborated-only), preserving #027's in-progress exclusion.
                    if Self.canExecutePending(status: row.task.status,
                                              isBlocked: row.task.isBlocked,
                                              isBacklogged: row.task.isBacklogged) {
                        Button {
                            showExecutePending = true
                        } label: {
                            Label("Execute", systemImage: "play.fill")
                        }
                    }

                    // "Refine" — reopens an already-elaborated plan in
                    // `plan-elaborate` Path C with the user's guidance to refine
                    // its How checklist (#056). Available only for an elaborated,
                    // non-blocked task — so an elaborated plan shows BOTH Refine
                    // and Execute (intended). Shares the pending Elaborate's
                    // `sparkles` glyph since both drive `plan-elaborate`.
                    if Self.canReElaborate(status: row.task.status,
                                           isBlocked: row.task.isBlocked,
                                           isBacklogged: row.task.isBacklogged) {
                        Button {
                            showReElaborate = true
                        } label: {
                            Label("Refine", systemImage: "sparkles")
                        }
                    }

                    // "Execute" — hands the plan off to the bundled Agent-SDK
                    // runner in worktree-isolated `plan-execute` mode. Available
                    // only for an elaborated/in-progress, non-blocked task. Opens
                    // the `ExecuteModal` (#078) for the Keep choice rather than
                    // launching the run straight off the button.
                    if Self.canWork(status: row.task.status,
                                    isBlocked: row.task.isBlocked,
                                    isBacklogged: row.task.isBacklogged) {
                        Button {
                            showExecute = true
                        } label: {
                            Label("Execute", systemImage: "play.fill")
                        }
                    }

                    // "Refine" (review) — resets a REVIEW-state plan back to
                    // pending and re-elaborates it with the user's optional
                    // guidance (#091). Available only for a review/in-review,
                    // non-blocked, non-backlogged task — so a review plan shows
                    // BOTH Refine and Execute side by side. Opens the
                    // `ReviewReElaborateModal` first (optional guidance + Deep)
                    // rather than firing the run straight off the button. Shares
                    // the pending Elaborate's `sparkles` glyph since both drive
                    // plan-elaborate.
                    if Self.canReElaborateReview(status: row.task.status,
                                                 isBlocked: row.task.isBlocked,
                                                 isBacklogged: row.task.isBacklogged) {
                        Button {
                            showReviewReElaborate = true
                        } label: {
                            Label("Refine", systemImage: "sparkles")
                        }
                    }

                    // "Execute" (review) — re-runs a REVIEW-state plan through the
                    // bundled runner's worktree-isolated `plan-execute` mode for
                    // another execution pass (#091). Available only for a
                    // review/in-review, non-blocked, non-backlogged task — the same
                    // gate as the review Refine above. Opens the
                    // `ExecutePendingModal` sheet (in review mode: optional context
                    // + Keep) via the shared `showExecutePending` flag.
                    if Self.canExecuteReview(status: row.task.status,
                                             isBlocked: row.task.isBlocked,
                                             isBacklogged: row.task.isBacklogged) {
                        Button {
                            showExecutePending = true
                        } label: {
                            Label("Execute", systemImage: "play.fill")
                        }
                    }
                }

                // Read-only file actions, ALWAYS visible regardless of task
                // status or running state: reveal the plan's markdown file in
                // Finder, or open it in the default markdown app. Both no-op
                // safely when the file can't be resolved.
                Button {
                    if let url = Self.taskFileURL(
                        projectPath: row.projectPath,
                        taskID: row.task.id,
                        isCompletedDir: row.task.isCompletedDir
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }

                Button {
                    if let url = Self.taskFileURL(
                        projectPath: row.projectPath,
                        taskID: row.task.id,
                        isCompletedDir: row.task.isCompletedDir
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open in Markdown App", systemImage: "doc.text")
                }

                // "Backlog" / "Restore" (#077 follow-up) — the two halves of
                // plans-cc's defer/undefer pair, each handing the plan off to the
                // bundled runner (the sole writer of `.plans/`, §2). They are
                // mutually exclusive by construction: a task is either in
                // `pending/` (backloggable) or in `backlog/` (restorable), never
                // both, because the skills MOVE the file. `canRestore` is checked
                // FIRST because a backlogged task keeps its real
                // `pending`/`elaborated` status, so `canBacklog` would also be
                // true for it — source directory wins over status.
                //
                // Neither needs a confirm alert: Restore is non-destructive, and
                // Backlog is gated by `canBacklog` to the two quiescent statuses
                // precisely so the skill's git-touching auto-pause can never fire
                // from one click (see `canBacklog`).
                if Self.canRestore(isBacklogged: row.task.isBacklogged) {
                    Button {
                        runner.run(projectPath: row.projectPath,
                                   taskID: row.task.id, mode: .restore)
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.left")
                    }
                    .help("Move this plan out of the backlog, back to the active list")
                } else if Self.canBacklog(status: row.task.status,
                                          isBlocked: row.task.isBlocked) {
                    Button {
                        runner.run(projectPath: row.projectPath,
                                   taskID: row.task.id, mode: .backlog)
                    } label: {
                        Label("Backlog", systemImage: "archivebox")
                    }
                    .help("Defer this plan — move it to the backlog holding pen")
                }

                // "Delete" — hands the plan off to the bundled runner in
                // `plan-delete` mode. Lives in this always-visible file-actions
                // block (so it's hidden automatically while a run is in flight)
                // rather than the status-gated block, because `canDelete` is
                // true at every status. The modal confirm below is the REAL
                // safety gate: the runner does not allowlist `AskUserQuestion`,
                // so `plan-delete`'s own yes/no prompts can never reach the user
                // (the delete prompt pre-answers them). This is the only place a
                // human consents to an irreversible deletion.
                if Self.canDelete(status: row.task.status, isBlocked: row.task.isBlocked) {
                    Button {
                        if Self.confirmDelete(row: row) {
                            runner.run(projectPath: row.projectPath,
                                       taskID: row.task.id, mode: .delete)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    /// The PERSISTENT run-failure section (#079), shown only when `row.task`
    /// carries a `TaskFailure` overlay. Unlike the transient `errorBanner` in the
    /// progress sheet (which lives only for the duration of a run), this stays in
    /// the detail body between runs so a stranded/truncated/errored/crashed run is
    /// visible whenever the plan is opened. It reuses the `errorBanner` visual
    /// treatment (white-on-red rounded panel) and surfaces the classification,
    /// stop reason, timestamp, and the run's error message, plus a Retry that
    /// re-runs `plan-execute` via the SAME consent gate as the Execute action —
    /// the `ExecuteModal` sheet (`showExecute`), NOT a silent reload. Retry is
    /// offered regardless of status because resuming a stranded/truncated run is
    /// exactly a re-run of `plan-execute` on an in-progress task.
    private func failureSection(_ row: TaskRow, failure: TaskFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: TaskStatusIndicator.failureSymbol)
                    .imageScale(.medium)
                Text(Self.failureSummary(failure))
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
            }

            if let message = failure.errorMessage, !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                // Retry re-runs via the Execute consent gate (`ExecuteModal`),
                // matching the Execute action exactly — never a silent reload.
                // Hidden while a run for this task is already in flight so a
                // second run can't be launched over the first.
                if !runner.isRunning(taskID: row.task.id, in: row.projectPath) {
                    Button {
                        showExecute = true
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.red.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Whether the failure section + Retry affordance (#079) should render for a
    /// task, gated purely on the presence of the run-failure overlay. Pure so it
    /// is unit-testable without the view; a `nil` failure (healthy) hides both.
    static func canRetry(failure: TaskFailure?) -> Bool {
        failure != nil
    }

    /// A one-line human-readable summary of a run failure (#079) — the
    /// classification's `failureLabel`, and when present a trailing stop reason in
    /// parentheses (e.g. `Run cut short (budget/turn cap) · error_max_budget_usd`).
    /// Pure so the failure-section header (and any tooltip built from it) is
    /// unit-testable without a view. The full error message is rendered
    /// separately below the summary, not folded in here.
    static func failureSummary(_ failure: TaskFailure) -> String {
        let base = failure.classification.failureLabel
        if let stopReason = failure.stopReason, !stopReason.isEmpty {
            return "\(base) · \(stopReason)"
        }
        return base
    }

    /// Pure predicate for the "Execute" action's availability, so the gating rule
    /// is unit-testable independent of the view. Available only for an elaborated
    /// (not in-progress) task that is not blocked: once a task is in-progress it
    /// already has a run underway (or completed) and must not offer Execute again
    /// (#027). Whether a run is in flight is a separate, per-task concern (the row
    /// shows a spinner instead of the button) — runs are independent across tasks,
    /// so it does NOT gate availability.
    /// A BACKLOGGED plan is never workable, whatever its status (#077 follow-up).
    /// Backlog is a source directory, not a status (spec §5.4), so a deferred
    /// `elaborated` plan would otherwise satisfy the status gate below and offer
    /// Execute on work the user deliberately parked. Worse, `plan-execute` writes
    /// `in-progress` back into a file under `backlog/`, stranding a task that
    /// neither `/plan-status` nor this app's active views will surface. Restore
    /// it first (`canRestore`), then work it.
    static func canWork(status: TaskStatus?, isBlocked: Bool,
                        isBacklogged: Bool = false) -> Bool {
        guard !isBacklogged else { return false }
        guard !isBlocked else { return false }
        return status == .elaborated
    }

    /// Pure predicate for the "Elaborate" action's availability. Available only
    /// for a `pending` task that is not blocked — elaboration is the step that
    /// produces the How checklist a subsequent Execute run needs.
    /// Withheld from a BACKLOGGED plan (#077 follow-up): elaborating work the
    /// user has consciously set aside is incoherent. Restore it first. See
    /// `canWork` for why the source directory has to be consulted alongside the
    /// status here.
    static func canElaborate(status: TaskStatus?, isBlocked: Bool,
                             isBacklogged: Bool = false) -> Bool {
        guard !isBacklogged else { return false }
        guard !isBlocked else { return false }
        return status == .pending
    }

    /// Pure predicate for the "direct-Execute" action's availability (#088).
    /// Available only for a `pending` task that is not blocked and not
    /// backlogged — exactly the same gate as `canElaborate`, because this action
    /// is the one-click shortcut that hands a pending plan to `plan-execute`,
    /// which auto-elaborates it inline (optionally with extra guidance and the
    /// Deep reasoning pass) and THEN executes it, leaving it in `review`.
    ///
    /// This is INTENTIONALLY DISJOINT from `canWork`: `canWork` stays
    /// elaborated-only so an `in-progress` plan never re-offers Execute (#027's
    /// guarantee). Pending plans are excluded from `canWork` and handled solely
    /// here, so the two predicates never both fire for the same status and #027
    /// is preserved. Backlog is withheld for the same reason as `canElaborate`:
    /// driving work the user has parked is incoherent — restore it first.
    static func canExecutePending(status: TaskStatus?, isBlocked: Bool,
                                  isBacklogged: Bool = false) -> Bool {
        guard !isBacklogged else { return false }
        guard !isBlocked else { return false }
        return status == .pending
    }

    /// Pure predicate for the "Re-elaborate" action's availability. Available only
    /// for an already-`elaborated` task that is not blocked — re-elaboration
    /// refines the existing How checklist before an Execute run, so it only makes
    /// sense once a first elaboration has produced one (and not after work has
    /// started or completed).
    /// Withheld from a BACKLOGGED plan (#077 follow-up), for the same reason as
    /// `canElaborate`: refining a parked plan's checklist is shaping work the
    /// user set aside. Restore it first.
    static func canReElaborate(status: TaskStatus?, isBlocked: Bool,
                               isBacklogged: Bool = false) -> Bool {
        guard !isBacklogged else { return false }
        guard !isBlocked else { return false }
        return status == .elaborated
    }

    /// Pure predicate for the review-state "execute more" action's availability
    /// (#091). Available only for a plan in `review` / `in-review` that is not
    /// blocked and not backlogged — the two statuses that mean an Execute run has
    /// finished and the result is awaiting the user's review. The action hands the
    /// reviewed plan back to `plan-execute` for a further pass.
    /// Withheld from a BACKLOGGED plan for the same reason as `canReElaborate`:
    /// driving work the user has parked is incoherent — restore it first.
    static func canExecuteReview(status: TaskStatus?, isBlocked: Bool,
                                 isBacklogged: Bool = false) -> Bool {
        guard !isBacklogged else { return false }
        guard !isBlocked else { return false }
        return status == .review || status == .inReview
    }

    /// Pure predicate for the review-state "re-elaborate" action's availability
    /// (#091). Shares the SAME eligibility as `canExecuteReview` — a plan in
    /// `review` / `in-review` that is not blocked and not backlogged — because
    /// both review actions are offered together. The action resets the reviewed
    /// plan back to `pending` and re-elaborates it from scratch.
    static func canReElaborateReview(status: TaskStatus?, isBlocked: Bool,
                                     isBacklogged: Bool = false) -> Bool {
        guard !isBacklogged else { return false }
        guard !isBlocked else { return false }
        return status == .review || status == .inReview
    }

    /// Pure predicate for the "Backlog" action's availability (#077 follow-up),
    /// gated to `pending` / `elaborated` ONLY.
    ///
    /// This is a SAFETY rule, not a cosmetic one. `plan-backlog` auto-pauses an
    /// `in-progress` / `in-review` task before deferring it, and that pause
    /// commits dirty work (`git add -A`) and checks out the default branch.
    /// Restricting the button to the two quiescent statuses means the auto-pause
    /// path can never fire from a single in-app click, so no click can move git
    /// state. Deferring an active task stays a deliberate CLI action
    /// (`/plan-backlog <id>`), where the user sees what it does.
    ///
    /// `completed` is excluded because a finished task has nothing to defer (the
    /// skill itself rejects it, pointing at `/plan-reopen`), and `nil` is
    /// excluded because an undecodable status is not known to be safe.
    ///
    /// `isBlocked` deliberately does NOT gate this: being blocked is a common
    /// REASON to park work, so a blocked plan is *more* deferrable, not less —
    /// following `canDelete`'s reasoning rather than `canWork`'s.
    static func canBacklog(status: TaskStatus?, isBlocked: Bool) -> Bool {
        status == .pending || status == .elaborated
    }

    /// Pure predicate for the "Restore" action's availability (#077 follow-up).
    ///
    /// Keyed on the task's SOURCE DIRECTORY rather than its status, because
    /// backlog is where a task lives, not what state it is in (spec §5.4): a
    /// backlogged file retains its real `pending` / `elaborated` status, and
    /// `plan-restore` preserves that status on the way back. So status carries no
    /// information about restorability — `isBacklogged` is the whole question.
    ///
    /// "Restore" is the verb plans-cc uses (`/plan-restore`), so the button
    /// matches the skill and the spec's existing vocabulary.
    static func canRestore(isBacklogged: Bool) -> Bool {
        isBacklogged
    }

    /// Pure predicate for the "Delete" action's availability. Unlike Execute
    /// (gated to `elaborated`) and Elaborate (gated to `pending`), deletion is
    /// valid at EVERY lifecycle status: an abandoned plan is exactly the one you
    /// want to delete, and that plan can be sitting at any status — pending,
    /// elaborated, mid-flight, awaiting review, or completed. `isBlocked` does
    /// not gate it either: a blocked plan is *more* deletable, not less, since
    /// being blocked is a common reason to abandon it. So this predicate is
    /// unconditionally `true`; it exists for symmetry with its siblings and so
    /// the "always available" rule is explicit and unit-testable rather than an
    /// unstated absence of gating at the call site. The real safety gate is the
    /// destructive `NSAlert` confirmation, not availability.
    static func canDelete(status: TaskStatus?, isBlocked: Bool) -> Bool {
        return true
    }

    /// Runs the modal confirmation for "Delete", returning `true` only when the
    /// user explicitly confirms. Modeled on the quit-guard alert in
    /// `PlansApp.swift`: first button is the default and destructive, second
    /// cancels, and anything other than `alertFirstButtonReturn` is a cancel.
    /// Because the bundled runner can't surface `plan-delete`'s own interactive
    /// confirms, the status-specific consequences that skill would have warned
    /// about are folded into `informativeText` here instead.
    private static func confirmDelete(row: TaskRow) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete plan #\(row.task.id)?"

        var informative = "\"\(row.title ?? "(untitled)")\" will be permanently deleted. "
            + "This cannot be undone."
        switch row.task.status {
        case .review, .inReview:
            informative += "\n\nThis task has a branch with unmerged changes. "
                + "The branch will remain, but task tracking will be lost."
        case .inProgress:
            informative += "\n\nThis task is in progress. Any uncommitted work will be lost."
        default:
            break
        }
        alert.informativeText = informative

        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        default:
            return false
        }
    }

    /// Decides whether the progress sheet should auto-open, gated to the single
    /// case where the task is ALREADY running as the window appears (e.g. the
    /// user clicked the card spinner to come here). A fresh run started from THIS
    /// view must NOT auto-open the sheet — the dashboard doesn't, and neither
    /// should the detail pop-up (#061); the header's "Show progress" button is the
    /// deliberate re-entry path. `onAppearRunning` is `runner.isRunning(taskID:in:)`
    /// evaluated in `.onAppear`; this returns it unchanged, encoding the rule as a
    /// pure, testable decision.
    static func shouldAutoOpenProgress(onAppearRunning: Bool) -> Bool {
        onAppearRunning
    }

    /// Resolves the on-disk markdown file for a task, so the read-only
    /// "Show in Finder" / "Open in Markdown App" actions have a URL to act on.
    /// The `Task` model does not store the filename slug, so the file is found
    /// by scanning `<projectPath>/.plans/<pending|completed>/` for the first
    /// `.md` whose name begins with `<taskID>-`. Returns `nil` on any error or
    /// when no matching file exists (the buttons then no-op).
    static func taskFileURL(
        projectPath: String,
        taskID: String,
        isCompletedDir: Bool
    ) -> URL? {
        let subdir = isCompletedDir ? "completed" : "pending"
        let dir = URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".plans")
            .appendingPathComponent(subdir)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        let prefix = taskID + "-"
        return contents.first { url in
            url.pathExtension == "md"
                && url.lastPathComponent.hasPrefix(prefix)
        }
    }

    /// Renders one `## ` section: its heading, then its body. The `## How`
    /// section is rendered specially as a read-only checklist; all others render
    /// their body as markdown paragraphs.
    @ViewBuilder
    private func sectionView(_ section: TaskSection) -> some View {
        VStack(alignment: .leading, spacing: PlanType.sectionSpacing) {
            Text(section.heading)
                .font(.title.weight(.bold))

            if section.heading == "How" {
                howChecklist(section.body)
            } else {
                markdownBlockView(section.body)
            }
        }
    }

    /// Renders a section body as block-level markdown: paragraphs, bullet /
    /// numbered lists, fenced code, blockquotes, and sub-headings, in document
    /// order. Block structure is recovered by the pure `MarkdownBlockRenderer`;
    /// inline markdown within each block's text is still applied via
    /// `markdownParagraph(_:)`. Purely presentational — performs no writes.
    @ViewBuilder
    private func markdownBlockView(_ body: String) -> some View {
        VStack(alignment: .leading, spacing: PlanType.blockSpacing) {
            ForEach(Array(MarkdownBlockRenderer.parse(body).enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    /// Renders a single parsed `MarkdownBlock` with restrained, readable styling.
    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            markdownParagraph(text)
                .lineSpacing(PlanType.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)

        case let .heading(level, text):
            Text(text)
                .font(headingFont(forLevel: level))
                .foregroundStyle(headingColor(forLevel: level))
                .padding(.top, 6)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: PlanType.listSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•")
                            .font(.system(size: PlanType.bodySize))
                            .foregroundStyle(.secondary)
                        markdownParagraph(item)
                            .lineSpacing(PlanType.lineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                }
            }

        case let .numberedList(items):
            VStack(alignment: .leading, spacing: PlanType.listSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1).")
                            .font(.system(size: PlanType.bodySize))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        markdownParagraph(item)
                            .lineSpacing(PlanType.lineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                }
            }

        case let .codeBlock(language, code):
            Text(CodeHighlighter.highlight(code, language: language))
                .font(.system(size: PlanType.bodySize - 1, design: .monospaced))
                .lineSpacing(PlanType.lineSpacing - 1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                )

        case let .blockquote(text):
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.65))
                    .frame(width: 3)
                markdownParagraph(text)
                    .foregroundStyle(.secondary)
                    .lineSpacing(PlanType.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.06))
            )
        }
    }

    /// The emphasized font for a sub-heading, scaling down with nesting depth:
    /// level 1/2 read as section-ish, level 3+ as a smaller bold subhead.
    private func headingFont(forLevel level: Int) -> Font {
        switch level {
        case 1: return .largeTitle.bold()
        case 2: return .title.bold()
        default: return .title2.bold()
        }
    }

    /// Tints sub-headings by depth so the hierarchy reads through color as well
    /// as size: the biggest headings take the accent, the next level a cooler
    /// teal, and deeper levels settle to primary so it never becomes a rainbow.
    private func headingColor(forLevel level: Int) -> Color {
        switch level {
        case 1: return .accentColor
        case 2: return .teal
        default: return .primary
        }
    }

    /// Renders a single paragraph as markdown, tolerating parse failures by
    /// falling back to plain text. Uses an options value that does not throw on
    /// the default markdown grammar; the whole parse is wrapped in `try?`.
    private func markdownParagraph(_ paragraph: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if var attributed = try? AttributedString(markdown: paragraph, options: options) {
            attributed.font = .system(size: PlanType.bodySize)
            styleInlineCode(&attributed)
            return Text(attributed)
        }
        return Text(paragraph).font(.system(size: PlanType.bodySize))
    }

    /// Gives inline `` `code` `` runs a monospaced font and a subtle tinted
    /// "chip" foreground so they stand apart from surrounding prose. Detected via
    /// the `.code` inline presentation intent the markdown parser assigns.
    private func styleInlineCode(_ attributed: inout AttributedString) {
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            attributed[run.range].font = .system(size: PlanType.bodySize, design: .monospaced)
            attributed[run.range].foregroundColor = .accentColor
        }
    }

    /// Renders the `## How` body as a READ-ONLY checklist. Lines matching
    /// `- [ ]` / `- [x]` / `- [X]` become a `Label` with `square` /
    /// `checkmark.square`; the checkbox prefix is stripped from the step text.
    /// These are never interactive (§2): no `Toggle`, no `Button`, no binding,
    /// no writes.
    @ViewBuilder
    private func howChecklist(_ body: String) -> some View {
        VStack(alignment: .leading, spacing: PlanType.listSpacing) {
            ForEach(Array(BrowserViewModel.howSteps(body).enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: step.done ? "checkmark.square.fill" : "square")
                        .font(.system(size: PlanType.bodySize))
                        .foregroundStyle(step.done ? Color.accentColor : Color.secondary)
                    Text(step.text)
                        .font(.system(size: PlanType.bodySize))
                        .lineSpacing(PlanType.lineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(step.done ? .secondary : .primary)
                }
            }
        }
    }
}

/// The modal progress dialog for a single task's run. Renders that run's live
/// NDJSON stream: a scrolling activity/text log, a cost/turns summary once the
/// run reports `done`, an error banner on a streamed/terminal error, and a Stop
/// button wired to the run's `stop()`. It dismisses via `@Environment(\.dismiss)`,
/// so it works whether presented as a `.sheet` (the detail view) or a `.popover`
/// (the card spinner) — the Done/Close button can close it either way; closing
/// does NOT stop the run (it keeps going in the background).
struct RunProgressSheet: View {
    /// The specific run to render, or `nil` if there is none (e.g. the run was
    /// dropped). When nil the sheet shows a minimal "no active run" state.
    let run: TaskRun?

    /// The task id being worked, for the header (e.g. "Working task #019").
    let taskID: String?

    @Environment(\.dismiss) private var dismiss

    /// The id of the line to scroll into view on first appearance: the last
    /// (newest) line, or `nil` when there are no lines yet. Pure so it's unit
    /// testable without constructing the view.
    static func scrollTarget(for lines: [LoggedEvent]) -> UUID? {
        lines.last?.id
    }

    /// Whether the red failure banner should be shown. Pure so it's unit
    /// testable without constructing the view.
    ///
    /// A `done`-derived failure (a budget/turn cap or the #058 stranded signal)
    /// latches `run.error` the moment the terminal `done` line is ingested — but
    /// a `done` does NOT clear `isRunning` (only `finish()` does). So without a
    /// liveness check the banner armed mid-run and stayed armed while the run was
    /// still live (spinner up, turns climbing) — the #081 false positive. Such a
    /// `done`-derived failure is only meaningful once the run has actually ended,
    /// so it is suppressed while `isRunning`.
    ///
    /// A genuine mid-run `.error(message)` event (a real crash / launch failure)
    /// is a different animal: it means the run is broken now, so it must surface
    /// immediately even while `isRunning`. We tell the two apart by comparing the
    /// error text to `TaskRun.truncationError(for: stopReason)`: when they match,
    /// the error came from the `done` classification and gets the liveness gate;
    /// otherwise it's a genuine error and shows right away.
    static func shouldShowFailureBanner(
        error: String?,
        isRunning: Bool,
        stopReason: String?
    ) -> Bool {
        guard let error else { return false }
        // Ended runs always show whatever error latched.
        guard isRunning else { return true }
        // Still running: suppress only a `done`-derived truncation/stranded
        // failure (its text equals the mapping for the current stop reason).
        // Any other error (a genuine mid-run crash/launch failure) shows now.
        return TaskRun.truncationError(for: stopReason) != error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let error = run?.error,
               RunProgressSheet.shouldShowFailureBanner(
                   error: error,
                   isRunning: run?.isRunning == true,
                   stopReason: run?.lastStopReason
               ) {
                errorBanner(error)
            }

            logList

            if let summary = run?.summary {
                summaryRow(summary)
            }

            footer
        }
        .padding(12)
        // Cap the height so a long run log can't grow the dialog unbounded.
        // This matters most when presented as a popover from the card spinner,
        // which has no enclosing window to bound it; the `logList` ScrollView
        // scrolls any overflow within the cap.
        .frame(minWidth: 480, minHeight: 360, maxHeight: 520)
    }

    /// The verb for this run's mode ("Executing" / "Elaborating" / "Capturing"
    /// / "Capturing & elaborating" / "Capturing & executing" / "Deleting" /
    /// "Backlogging" / "Restoring").
    private var modeVerb: String {
        switch run?.mode {
        case .elaborate: return "Elaborating"
        case .reElaborate, .reElaborateReview: return "Refining"
        case .capture: return "Capturing"
        case .captureElaborate: return "Capturing & elaborating"
        case .executeYolo: return "Capturing & executing"
        case .delete: return "Deleting"
        case .backlog: return "Backlogging"
        case .restore: return "Restoring"
        case .execute, .none: return "Executing"
        }
    }

    /// The dialog title. Capture / captureElaborate / executeYolo runs have no
    /// real task id yet — they're keyed by a synthetic `"capture:<path>"`
    /// identity — so they show only the verb ("Capturing", "Capturing &
    /// elaborating", "Capturing & executing") rather than "Capturing task
    /// #capture:/…". Real runs keep the "verb task #NNN" form.
    private var title: String {
        switch run?.mode {
        case .capture, .captureElaborate, .executeYolo:
            return modeVerb
        default:
            return taskID.map { "\(modeVerb) task #\($0)" } ?? modeVerb
        }
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.headline)
            if run?.isRunning == true {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
        }
    }

    /// Auto-scrolling log of activity + text lines. Uses `ScrollViewReader` to
    /// scroll the newest line into view as lines append. Terminal `done`/`error`
    /// events are rendered out-of-band (summary row / error banner), so the list
    /// body shows only `.activity` and `.text`.
    private var logList: some View {
        let lines = run?.lines ?? []
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    // Immediate-feedback placeholder: until the first NDJSON line
                    // arrives, show a "Starting…" / "Waiting…" row so the sheet is
                    // never blank dead air while node resolves and the agent spins
                    // up (the first assistant message can take several seconds).
                    if lines.isEmpty, let phase = run?.phase {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(phase == .launching
                                 ? "Starting…"
                                 : "Waiting for the agent…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(lines) { logged in
                        lineView(logged.event)
                            .id(logged.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                // Stretch the log column to the full scroll width even while it
                // holds only the short "Starting…/Waiting…" placeholder, so the
                // inset `.textBackgroundColor` field is full-width from the first
                // frame instead of hugging the narrow placeholder until log lines
                // (which already carry `maxWidth: .infinity`) arrive.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: lines.count) {
                if let last = lines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            // On first appearance against a run that already has buffered
            // lines (e.g. opening the spinner of an in-progress task), jump
            // straight to the newest line — instantly, no animation — so the
            // view opens at the bottom instead of the top.
            .onAppear {
                if let target = RunProgressSheet.scrollTarget(for: lines) {
                    proxy.scrollTo(target, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func lineView(_ event: RunEvent) -> some View {
        switch event {
        case let .activity(tool, detail):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(tool)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case let .text(chunk):
            Text(chunk)
                .font(.callout)
        case .done, .error:
            // Rendered out-of-band as the summary row / error banner.
            EmptyView()
        }
    }

    private func summaryRow(_ summary: (costUsd: Double, turns: Int)) -> some View {
        Text(String(format: "$%.2f · %d turns", summary.costUsd, summary.turns))
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.red.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack {
            Spacer()
            if run?.isRunning == true {
                // While running: Stop ends the run; Close just backgrounds the
                // sheet (the run keeps going, reachable again via the card
                // spinner or the detail's "Show progress").
                Button(role: .destructive) {
                    run?.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)

                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                // Finished: Done dismisses (and drops the finished run).
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
