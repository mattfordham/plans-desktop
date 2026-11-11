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
    /// #105: the widest the plan body's text runs, so long lines stay a
    /// comfortable reading measure in a wide detail column.
    static let readingWidth: CGFloat = 760
}

/// Sizes and spacing for the shared markdown renderer, so plan bodies and
/// discussion replies use one renderer at different scales. `.plan` is the
/// editorial plan-detail scale; `.compact` is a system-body scale for chat-style
/// replies with plain, only modestly larger headings.
struct MarkdownStyle: Hashable {
    var bodySize: CGFloat
    var lineSpacing: CGFloat
    var blockSpacing: CGFloat
    var listSpacing: CGFloat
    /// Gap between a list marker and its text.
    var markerSpacing: CGFloat
    /// Extra space above a sub-heading.
    var headingTopPadding: CGFloat
    /// Inner padding of a fenced code block.
    var codePadding: CGFloat
    /// Whether headings take the accent/teal tints and the semantic title
    /// fonts; when false they are primary, semibold, sized by `headingSize`.
    var tintsHeadings: Bool

    static let plan = MarkdownStyle(
        bodySize: PlanType.bodySize,
        lineSpacing: PlanType.lineSpacing,
        blockSpacing: PlanType.blockSpacing,
        listSpacing: PlanType.listSpacing,
        markerSpacing: 10,
        headingTopPadding: 6,
        codePadding: 14,
        tintsHeadings: true
    )

    static let compact = MarkdownStyle(
        bodySize: 13,
        lineSpacing: 3,
        blockSpacing: 8,
        listSpacing: 4,
        markerSpacing: 6,
        headingTopPadding: 2,
        codePadding: 10,
        tintsHeadings: false
    )

    /// The point size of a plain heading at `level`, or `nil` when the style
    /// uses the semantic title fonts instead.
    func headingSize(forLevel level: Int) -> CGFloat? {
        guard !tintsHeadings else { return nil }
        switch level {
        case 1: return bodySize + 3
        case 2: return bodySize + 2
        default: return bodySize + 1
        }
    }
}

/// A self-contained renderer for a single plan's detail body (§011). This is the
/// content surface hosted by the browser window's split-view detail column
/// (#095, `BrowserWindow.detailColumn`, keyed by `.id(selectedRowID)` so sheet
/// state and progress auto-open reset per plan): the title, the owning project + status
/// line, and each `## ` section rendered as markdown (the `## How` section as a
/// read-only checklist, §2 — never interactive). It is host-agnostic — it renders
/// only its own body, no window/pane chrome — so it needed no changes when the
/// former standalone detail window was replaced by the overlay pane (#073)
/// and then by the detail column (#095).
///
/// It resolves its row from the injected `PlansStore` by composite id via the
/// shared `BrowserViewModel.resolveRow(in:id:)`, so it stays live as the store
/// re-reads. It carries NO Close button — the detail column is persistent and
/// shows a placeholder once the selection clears. When the id can't be
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

    /// Whether the guided-"Review" sheet (#083) is presented. Raised by the
    /// "Review" header action for a review/in-review plan (`canReview`) and
    /// lowered by the sheet's own Cancel/Start. Drives the `ReviewModal` (built in
    /// Step 5); for now a minimal placeholder sheet occupies the seam.
    @State private var showReview = false

    /// The live text of the discussion composer. Normalized by
    /// `Self.discussSubmission(_:)` on send (empty / whitespace-only never
    /// fires) and cleared once the question is asked. Not persisted — a fresh
    /// plan opens empty since the detail column re-keys per `selectedRowID`;
    /// the conversation itself lives on the runner's `DiscussionThread`.
    @State private var discussText = ""

    /// The resolved row for `rowID` across all projects' active rows, or `nil`
    /// when absent. Re-derived from the live store on each render.
    private var row: TaskRow? {
        guard let rowID else { return nil }
        return BrowserViewModel.resolveRow(in: store.projects, id: rowID)
    }

    var body: some View {
        Group {
            if let row {
                // #117: the plan on top, the always-present agent dock below. The
                // dock is user-resizable (`ResizableAgentDock`, a persisted height
                // used as its `maxHeight`); the plan takes the rest. Nothing
                // measures itself during layout (#096). The dock REPLACES the
                // former top progress drawer, the review / finished-review panels,
                // and the stand-alone Discuss composer with one surface driven by
                // this plan's single `PlanAgent`.
                VStack(spacing: 0) {
                    planScrollView(row)
                        .frame(minHeight: 0, maxHeight: .infinity)
                    ResizableAgentDock { AgentDock(row: row) }
                }
            } else if let rowID, TaskRunner.isSyntheticCaptureID(rowID) {
                // #117: a synthetic `capture:` selection has no backing plan yet.
                // Show a "Capturing…" placeholder header plus the SAME dock, which
                // hosts the capture's log and a Dismiss for an errored capture.
                capturePlaceholder(rowID: rowID)
            } else {
                VStack {
                    Text("Plan not found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // #107: the modal progress sheet is gone — the run log now renders inline
        // as the `progressDrawer` below the step-count panel (see `planScrollView`).
        // The old sheet's `onDisappear` side effects (drop the finished run +
        // reload the store so the new status surfaces) now fire from the drawer's
        // finished-run "Done" affordance; collapsing a LIVE run never dismisses it.
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
        // The guided-"Review" sheet (#083): the location picker + per-project
        // default + read-only main-checkout preflight. Same row-resolution shape
        // as the sheets above. The `siblings` are the project's OTHER tasks, so
        // the modal can detect a `mainCheckoutOccupant` holding the main checkout.
        .sheet(isPresented: $showReview) {
            if let row {
                ReviewModal(taskID: row.task.id,
                            projectPath: row.projectPath,
                            task: row.task,
                            siblings: Self.siblingTasks(in: store.projects, row: row))
            }
        }
        // NOTE: dismissing the detail pane deliberately does NOT stop the run.
        // Runs are independent of any presentation (they can be launched straight
        // from a card), so a run survives closing the detail; stop it explicitly
        // via the sheet's Stop button or the card.
    }

    /// The "Capturing…" placeholder (#117) for a synthetic `capture:` selection
    /// that has no backing plan yet: a minimal header naming the in-flight capture
    /// over the same `AgentDock`, which hosts the capture's live log (its one run
    /// segment) and a Dismiss for an errored capture. Once reconciliation migrates
    /// the capture to its real task id, `validSelection` remaps the selection and
    /// this view is replaced by the real plan's detail.
    @ViewBuilder
    private func capturePlaceholder(rowID: TaskRow.ID) -> some View {
        let captureRun = runner.runs[rowID]
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if captureRun?.isRunning == true {
                        ProgressView().controlSize(.small)
                    }
                    Text(captureRun?.description ?? "Capturing…")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Text("A new plan is being captured. The detail opens here once it lands.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
            Spacer(minLength: 0)
            ResizableAgentDock { AgentDock(row: nil, captureRun: captureRun) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Whether this plan's single agent is busy (working or needs input) — the
    /// one gate every header/housekeeping action is disabled behind (#117).
    private func agentBusy(_ row: TaskRow) -> Bool {
        runner.agent(for: row.task.id, in: row.projectPath)?.isBusy ?? false
    }

    /// The tooltip copy for a disabled action while the agent is busy, from the
    /// agent's pure `busyReason` (#117), or `nil` when idle.
    private func agentBusyReason(_ row: TaskRow) -> String? {
        runner.agent(for: row.task.id, in: row.projectPath)?.busyReason
    }

    /// The detail header: the title as a prominent heading, the owning project's
    /// name (since there is no longer a selected sidebar project for context),
    /// plus a status line (the type badge and the status's `filterLabel`).
    private func detailHeader(_ row: TaskRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // #105: the owning project as a small eyebrow above the title.
            Label(row.projectName, systemImage: "folder")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .padding(.bottom, 4)

            // Capped (not `fixedSize`) so a long title can't force the pinned
            // banner, and with it the detail column, taller than the window.
            // The tooltip carries the full title when it truncates.
            Text(row.title ?? "(untitled)")
                .font(.title)
                .fontWeight(.semibold)
                .lineLimit(Self.titleLineLimit)
                .truncationMode(.tail)
                .help(row.title ?? "")
                .textSelection(.enabled)
                .padding(.bottom, 10)

            HStack(spacing: 8) {
                // #105: the status as a tinted capsule (icon + label in the
                // status colour; blocked takes precedence), matching the cards
                // and the menu-bar glance via the same `symbolName`.
                let indicator = row.indicator
                HStack(spacing: 5) {
                    Image(systemName: indicator.symbolName)
                        .imageScale(.small)
                    if row.task.isBlocked {
                        Text("Blocked")
                    } else if let status = row.task.status {
                        Text(status.filterLabel)
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(indicator.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(indicator.color.opacity(0.15), in: Capsule())
                // The id and type in the plan rows' monospaced vocabulary.
                Text(row.task.id)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let type = row.type {
                    Text("[\(type.label)]")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                // A kept-worktree task (executed with the `keep` keyword) shows a
                // muted house glyph — the desktop analogue of the plans-cc
                // dashboard TUI's `⌂ kept` marker — matching the browser card row.
                // The `**Worktree:**` field can also appear on in-progress tasks,
                // so `showsKeptWorktreeMarker` (not `isKeptWorktree`) restricts the
                // display to review-state rows, shared with the browser card (#086).
                if row.task.showsKeptWorktreeMarker {
                    Image(systemName: TaskStatusIndicator.keptWorktreeSymbol)
                        .imageScale(.small)
                        .help("Kept in worktree — reviewable in isolation")
                }
            }
            .foregroundStyle(.secondary)
            .padding(.bottom, 16)

            // #105: the action bar — the status-relevant run actions as text
            // buttons (Execute prominent), the read-only file actions as compact
            // icon buttons, and the backlog/delete housekeeping in an overflow
            // menu, so the bar reads as one tidy row instead of six equal pills.
            HStack(spacing: 8) {
                // #117: while the plan's agent is busy, the lifecycle actions stay
                // VISIBLE but DISABLED (the dock below shows the live log and a
                // Stop), with a `.help(busyReason)` explaining why — the agent is
                // the single gate. `agentBusy` / `agentBusyReason` read the one
                // `PlanAgent`.
                let busy = agentBusy(row)
                let busyReason = agentBusyReason(row)
                Group {
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
                        .buttonStyle(.borderedProminent)
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
                        .buttonStyle(.borderedProminent)
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
                        .buttonStyle(.borderedProminent)
                    }

                    // "Review" (guided) — opens the interactive `plan-review`
                    // flow (#083) for a review/in-review plan. Available on the
                    // same statuses as the review Execute/Refine above, but gated
                    // additionally on the plan having a branch (the review needs a
                    // checkout). Opens the `ReviewModal` (Step 5) to pick the
                    // review location, rather than firing a run off the button.
                    if Self.canReview(status: row.task.status,
                                      branch: row.task.branch,
                                      isBlocked: row.task.isBlocked,
                                      isBacklogged: row.task.isBacklogged,
                                      hasLiveRun: runner.isRunning(taskID: row.task.id,
                                                                   in: row.projectPath)) {
                        Button {
                            showReview = true
                        } label: {
                            Label("Review", systemImage: "checklist")
                        }
                    }

                    // "Complete" — merges the branch and archives an in-review
                    // plan by driving `plan-complete` interactively. Always behind
                    // an explicit confirmation, since it moves git state.
                    if Self.canComplete(status: row.task.status,
                                        branch: row.task.branch,
                                        isBlocked: row.task.isBlocked,
                                        isBacklogged: row.task.isBacklogged,
                                        hasLiveRun: runner.isRunning(taskID: row.task.id,
                                                                     in: row.projectPath)),
                       let branch = row.task.branch {
                        Button {
                            if Self.confirmComplete(taskID: row.task.id, title: row.title,
                                                    branch: branch) {
                                runner.complete(projectPath: row.projectPath,
                                                taskID: row.task.id)
                            }
                        } label: {
                            Label("Complete…", systemImage: "checkmark.seal")
                        }
                    }
                }
                .disabled(busy)
                .help(busy ? (busyReason ?? "") : "")

                Spacer(minLength: 8)

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
                        .labelStyle(.iconOnly)
                }
                .help("Show in Finder")

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
                        .labelStyle(.iconOnly)
                }
                .help("Open in Markdown App")

                // #105: housekeeping (backlog/restore, delete) lives in an
                // overflow menu; hidden entirely when neither applies.
                if Self.canRestore(isBacklogged: row.task.isBacklogged)
                    || Self.canBacklog(status: row.task.status, isBlocked: row.task.isBlocked)
                    || Self.canDelete(status: row.task.status, isBlocked: row.task.isBlocked) {
                    Menu {
                        housekeepingActions(row)
                    } label: {
                        Label("More", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    // #117: housekeeping (Backlog / Restore / Delete) is also
                    // gated while the agent is busy — these drive their own runs.
                    .disabled(busy)
                    .help(busy ? (busyReason ?? "") : "More actions")
                }
            }
            .controlSize(.large)
        }
    }

    /// The project's OTHER tasks for `row` (#083): every task in the owning
    /// project except the row's own, so the `ReviewModal` can compute a
    /// `mainCheckoutOccupant`. Pure (takes the projects snapshot) so the lookup is
    /// unit-testable without a live store; an empty result when the project is
    /// absent from the snapshot.
    static func siblingTasks(in projects: [ProjectTasks], row: TaskRow) -> [Task] {
        guard let project = projects.first(where: { $0.projectPath == row.projectPath }) else {
            return []
        }
        return project.tasks.filter { $0.id != row.task.id }
    }


    /// The FINISHED guided review for this task, or `nil`. Only a review that
    /// ran to a clean `done` qualifies — not one that is still running, was
    /// stopped by the user (no `done`), errored, or hit a budget/turn cap — so
    /// the follow-up actions (discuss with the reviewer, complete) are offered
    /// only after a review that actually finished. Stays until dismissed. Pure so
    /// the gate is testable.
    static func finishedReviewRun(_ run: TaskRun?) -> TaskRun? {
        guard let run, run.mode == .review, !run.isRunning,
              run.error == nil, run.summary != nil else { return nil }
        return run
    }


    /// The sentinel option label (#083) the guided review offers alongside the
    /// skill's own choices: picking it hands the decision back to the agent
    /// ("Resolve for me") rather than the user choosing. It is sent verbatim as
    /// the answer value.
    static let resolveForMeLabel = "Resolve for me"

    /// Builds the `answers` payload for a parked `AskUserQuestion`. The UI keeps
    /// selection state per question `header`, but the SDK reads answers keyed by
    /// the question TEXT — so the payload is re-keyed here. Each value is the
    /// picked labels (joined per `multiSelect`) with any non-empty "Other" text
    /// appended.
    static func reviewAnswers(questions: [ReviewQuestion],
                              selections: [String: [String]],
                              otherText: [String: String]) -> [String: String] {
        var answers: [String: String] = [:]
        for question in questions {
            var value = reviewAnswerValue(selected: selections[question.header] ?? [],
                                          multiSelect: question.multiSelect)
            let other = (otherText[question.header] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !other.isEmpty {
                value = value.isEmpty ? other : "\(value), \(other)"
            }
            answers[question.question] = value
        }
        return answers
    }

    /// Opens `directory` in Terminal via `open -a Terminal <dir>` (#083). A plain
    /// `NSWorkspace` open of a directory URL would reveal it in Finder, not a
    /// shell, so Terminal is launched explicitly with the directory as its argument.
    static func openInTerminal(directory: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = [directory]
        guard let terminal = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal") else {
            // Fall back to revealing the directory if Terminal can't be located.
            NSWorkspace.shared.open(URL(fileURLWithPath: directory))
            return
        }
        NSWorkspace.shared.openApplication(at: terminal, configuration: config)
    }

    /// #105: the backlog/restore and delete actions, shown in the detail
    /// header's overflow menu.
    @ViewBuilder
    private func housekeepingActions(_ row: TaskRow) -> some View {
        Group {
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
                    Label("Delete…", systemImage: "trash")
                }
            }
        }
    }





    /// #105: the in-progress progress panel — a slim band between the header's
    /// full-bleed Divider and the body, so an active plan reads its progress at a
    /// glance without scrolling to the How checklist. Shows the in-progress
    /// accent glyph (`play.circle.fill`, amber — the SAME `symbolName` /
    /// `glanceColor` the cards and menu-bar glance use for in-progress, never a
    /// new colour), a `"<done> of <total> steps"` count, and the built-in
    /// `ProgressView` bar (NEVER a GeometryReader-measured width fed back into
    /// layout — the project has a layout-loop-hang history, #096). Rendered by
    /// the caller OUTSIDE the reading-width caps so it spans edge-to-edge; it
    /// supplies its own faint amber background and a trailing `Divider()` so it
    /// reads as a panel seam'd above (header Divider) and below.
    private func progressPanel(_ row: TaskRow) -> some View {
        let done = row.task.howProgress.done
        let total = row.task.howProgress.total
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: TaskStatus.inProgress.symbolName)
                    .foregroundStyle(TaskStatus.inProgress.glanceColor)
                Text("\(done) of \(total) steps")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(done), total: Double(total))
                    .tint(TaskStatus.inProgress.glanceColor)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TaskStatus.inProgress.glanceColor.opacity(0.12))
            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }






    /// Maximum lines for the pinned header's title before it truncates.
    static let titleLineLimit = 3


    /// A PINNED top banner (header + full-bleed rule + in-progress progress
    /// panel + #107 run-log drawer header row) above a scrolling plan body (the
    /// expanded run log, failure / denial notes and the plan's sections). #106: only the body scrolls; the
    /// banner stays fixed at the top of the detail column.
    private func planScrollView(_ row: TaskRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // #106 pinned banner. #105: the header, then a full-bleed rule
            // (outside the padded, width-capped columns), then the in-progress
            // panel. An opaque `.bar` background keeps scrolled body content
            // from showing through behind the header edges; the full-bleed rule
            // (or the panel's own trailing Divider, when shown) reads as the
            // banner's bottom seam.
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(row)
                    .frame(maxWidth: PlanType.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
                Divider()
                // #105: the in-progress progress panel, pushed down from the
                // header — rendered full-bleed (OUTSIDE the reading-width caps,
                // like the Divider above) so it spans edge-to-edge, with its own
                // trailing Divider so it reads as a seam'd band between the
                // header and the body. Gated to an in-progress plan with steps.
                if Self.showsProgressPanel(status: row.task.status,
                                           howProgress: row.task.howProgress) {
                    progressPanel(row)
                }
                // #117: the former inline run-log DRAWER is gone — the live log now
                // lives in the always-present `AgentDock` below the plan body.
            }
            .background(.bar)
            // Sized ahead of the ScrollView: the banner keeps its natural
            // height when there is room and the scrolling body absorbs any
            // squeeze. When the window is shorter still, the banner itself can
            // compress (its title is line-limited, nothing in it is
            // `fixedSize` vertically), so it never forces a minimum column
            // height taller than the window.
            .layoutPriority(1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 28) {
                        // #079: a PERSISTENT failure section (not a transient
                        // banner) when the latest run for this task failed. Reuses
                        // the `errorBanner` visual style and offers a Retry that
                        // re-runs via the same Execute consent gate.
                        if let failure = row.task.failure {
                            failureSection(row, failure: failure)
                        }
                        // Task #092: a non-fatal DENIAL note for a run that reached
                        // for tools not on the allowlist. Surfaced from the live
                        // `TaskRun` (the detail body's only run handle) so it shows
                        // EVEN WHEN the run otherwise finished cleanly — the user
                        // needs to know the plan may be built on incomplete
                        // information. Distinct from the red `failureSection`: this
                        // is a caution (orange), not a failure.
                        if let run = runner.run(for: row.task.id, in: row.projectPath),
                           !run.deniedTools.isEmpty {
                            deniedToolsSection(run)
                        }
                        ForEach(Array(row.task.sections.enumerated()), id: \.offset) { _, section in
                            sectionView(section)
                        }
                    }
                    .frame(maxWidth: PlanType.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
                }
            }
            // Both bounds are explicit so the enclosing stack can learn this
            // view's flexibility without measuring the whole plan's text.
            .frame(minHeight: 0, maxHeight: .infinity)
            .textSelection(.enabled)
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

    /// The non-fatal DENIAL note (task #092): a caution surface shown when the
    /// run reached for one or more tools that were not on the allowlist and the
    /// SDK refused them. Unlike `failureSection` (a terminal, red failure), this
    /// is a WARNING — the run may well have finished cleanly (e.g. "elaborated"),
    /// but it could not reach those tools, so the plan may be built on incomplete
    /// information. It uses a muted-orange/caution treatment (an
    /// exclamation-triangle glyph on a faint orange panel) to read as a notice,
    /// not an error. It shows the per-call count and the DISTINCT tool names
    /// (sorted) so the user can see exactly which tools were refused.
    private func deniedToolsSection(_ run: TaskRun) -> some View {
        let count = run.deniedTools.count
        let names = Array(run.deniedToolNames).sorted()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.medium)
                Text("\(count) tool call\(count == 1 ? "" : "s") denied — the plan may be "
                     + "built on incomplete information")
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            if !names.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(names, id: \.self) { name in
                        Text(name)
                            .font(.system(.callout, design: .monospaced))
                    }
                }
            }
        }
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
        )
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

    /// Pure predicate for the guided-"Review" action's availability (#083).
    /// Available for a plan in `review` / `in-review` that HAS a branch (the
    /// review needs something to check out), is not blocked, not backlogged, and
    /// has no live run. Unlike the old assumption a kept worktree is NO LONGER
    /// required — a non-kept review plan can still be reviewed on a fresh worktree
    /// or on the main checkout. `hasLiveRun` is passed by the call site from the
    /// runner so the predicate stays pure and unit-testable.
    static func canReview(status: TaskStatus?, branch: String?,
                          isBlocked: Bool, isBacklogged: Bool,
                          hasLiveRun: Bool) -> Bool {
        guard !isBacklogged else { return false }
        guard !isBlocked else { return false }
        guard !hasLiveRun else { return false }
        guard let branch, !branch.isEmpty else { return false }
        return status == .review || status == .inReview
    }

    /// The review locations offered for `task` (#083), in display order. `worktree`
    /// and `main` are ALWAYS available; `kept` is offered ONLY when the task shows
    /// the kept-worktree marker (there is a surviving execution worktree to review
    /// in place). Pure so the menu's contents are unit-testable.
    static func availableReviewLocations(for task: Task) -> [ReviewLocation] {
        var locations: [ReviewLocation] = []
        if task.showsKeptWorktreeMarker {
            locations.append(.kept)
        }
        locations.append(.worktree)
        locations.append(.main)
        return locations
    }

    /// The sibling task (same project) holding the MAIN checkout (#083), or `nil`
    /// when none does. A sibling holds main only when the main checkout is
    /// ACTUALLY on that sibling's branch, per git (`mainBranch`, read by the
    /// review modal's preflight). Status alone is not evidence: a task "ready for
    /// review" has not been checked out anywhere yet. An unknown `mainBranch`
    /// (`nil`: git unavailable / preflight pending) never asserts an occupant.
    /// The `current` task is never its own occupant. Pure so it is unit-testable.
    static func mainCheckoutOccupant(current: Task, siblings: [Task],
                                     mainBranch: String?) -> Task? {
        guard let mainBranch, !mainBranch.isEmpty else { return nil }
        return siblings.first { sibling in
            sibling.id != current.id && sibling.branch == mainBranch
        }
    }

    /// The directory the review panel's "Open in Terminal" / "Open in Editor"
    /// buttons target (#083): the WORKTREE path for a `kept` / `worktree` review,
    /// the PROJECT ROOT for a `main` review. `nil` for a `kept`/`worktree` review
    /// whose worktree path has not yet been written (the skill writes it; it
    /// surfaces on the next store refresh), so the buttons hide until then; `main`
    /// always has the project root. Pure so the targeting rule is unit-testable.
    static func reviewOpenDirectory(location: ReviewLocation,
                                    worktreePath: String?,
                                    projectRoot: String) -> String? {
        switch location {
        case .main:
            return projectRoot
        case .kept, .worktree:
            return worktreePath
        }
    }


    /// Pure predicate for the "Complete" action: an `in-review` plan with a
    /// branch to merge, not blocked, not backlogged, and with no live run.
    /// Completing merges the branch and archives the task, so it is only offered
    /// once the plan has been through review; the action itself still requires
    /// an explicit confirmation (`confirmComplete`).
    static func canComplete(status: TaskStatus?, branch: String?,
                            isBlocked: Bool, isBacklogged: Bool,
                            hasLiveRun: Bool) -> Bool {
        guard !isBacklogged, !isBlocked, !hasLiveRun else { return false }
        guard let branch, !branch.isEmpty else { return false }
        return status == .inReview
    }

    /// The wording of the Complete confirmation: names the task and its branch
    /// and states that completing merges into the target branch and archives the
    /// task. Pure so the copy is testable.
    static func completeConfirmation(taskID: String, title: String?,
                                     branch: String) -> (title: String, message: String) {
        let name = title ?? "(untitled)"
        return (
            title: "Complete plan #\(taskID)?",
            message: "\"\(name)\" will be completed: branch \(branch) will be merged "
                + "into the target branch (the task's Base branch, or the repository's "
                + "default branch) and the task will be archived to .plans/completed.\n\n"
                + "plan-complete commits any uncommitted changes in the project checkout "
                + "first, removes the task's kept worktree if it has one, and asks how to "
                + "merge (keep or delete the branch, or skip the merge) before it changes git."
        )
    }

    /// Runs the modal confirmation for "Complete", returning `true` only when the
    /// user explicitly confirms. Completing moves git state, so it is never a
    /// single click.
    static func confirmComplete(taskID: String, title: String?, branch: String) -> Bool {
        let copy = completeConfirmation(taskID: taskID, title: title, branch: branch)
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.message
        alert.addButton(withTitle: "Complete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Whether the needs-input indicator lights on the plan's row (#083): true
    /// when the plan's live review run has a parked question awaiting an answer,
    /// so a review the user navigated away from isn't lost. Pure so the row
    /// indicator's gate is testable without a live run.
    static func reviewNeedsInput(hasPendingQuestion: Bool) -> Bool {
        hasPendingQuestion
    }

    /// The new selection after toggling `choice` on a review question (#083),
    /// honouring `multiSelect`: single-select REPLACES the selection with the one
    /// choice; multi-select ADDS the choice when absent and REMOVES it when
    /// already present. Order is preserved (append on add). Pure so the
    /// selection logic is unit-testable without the view.
    static func reviewToggleSelection(current: [String], choice: String,
                                      multiSelect: Bool) -> [String] {
        guard multiSelect else { return [choice] }
        if let index = current.firstIndex(of: choice) {
            var next = current
            next.remove(at: index)
            return next
        }
        return current + [choice]
    }

    /// The answer VALUE sent for a review question given the `selected` choice
    /// labels (#083): the single label for single-select, the labels joined by
    /// ", " for multi-select, and "" when nothing is selected (callers gate send
    /// on a non-empty value). Pure so the wire value is unit-testable.
    static func reviewAnswerValue(selected: [String], multiSelect: Bool) -> String {
        selected.joined(separator: ", ")
    }

    /// Pure predicate for the "Discuss" footer's availability (#099). Unlike the
    /// lifecycle actions (Elaborate / Execute / Refine), discussion is a
    /// a read-only conversation ABOUT a plan — so it is offered at EVERY
    /// status, including an undecodable `nil` status: the footer shows whenever
    /// there is a real plan to ask about, independent of lifecycle state.
    /// Only the two cross-cutting guards hide it — a BLOCKED plan (nothing to ask
    /// an agent to do while it waits on its blocker) and a BACKLOGGED plan
    /// (discussing work the user has parked is incoherent, mirroring the other
    /// gates' `isBacklogged` withholding). The guard ordering mirrors `canWork`.
    static func canDiscuss(status: TaskStatus?, isBlocked: Bool,
                           isBacklogged: Bool = false) -> Bool {
        guard !isBacklogged else { return false }
        guard !isBlocked else { return false }
        return true
    }

    /// Normalizes a raw Discuss question into the value to send, or `nil` when
    /// there is nothing to ask (#099). Returns the question trimmed of leading /
    /// trailing whitespace and newlines when something remains, else `nil` — so
    /// callers gate the send button on a non-nil result (an empty or
    /// whitespace-only box can never fire a run). Pure so the enable/trim rule is
    /// unit-testable without the view.
    static func discussSubmission(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    /// Pure predicate for the "Apply changes" discuss control's availability
    /// (#114, widened in #115): permitted for the active and pre-execution
    /// statuses — `pending` / `elaborated` / `in-progress` / `review` /
    /// `in-review` — and withheld on blocked / backlogged plans.
    ///
    /// A read-only discuss turn can happen at any status; the *applying* turn is
    /// write-capable — it can edit and commit the plan file. But that applying
    /// turn is a deliberate, explicit second control routing through
    /// `plan-discuss`, scoped to the single selected plan, so permitting it on an
    /// active plan lets the user reshape work in flight rather than being an
    /// accidental in-app write. That is exactly the point of discussion-driven
    /// edits, so an in-progress / review / in-review plan is allowed.
    ///
    /// Only `completed` is withheld by status — a finished plan has nothing to
    /// re-shape, and reopening is the path. `nil` is excluded too because an
    /// undecodable status is not known to be safe. A `blocked` plan is withheld
    /// (applying edits is a write action, so it follows the work gates rather
    /// than the deferral ones), and a `backlogged` plan is withheld as well —
    /// parked plans offer Restore and read-only actions only.
    static func canApplyViaDiscussion(status: TaskStatus?, isBlocked: Bool,
                                      isBacklogged: Bool) -> Bool {
        guard !isBacklogged else { return false }
        guard !isBlocked else { return false }
        switch status {
        case .pending, .elaborated, .inProgress, .review, .inReview:
            return true
        case .completed, nil:
            return false
        }
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


    /// Pure predicate for the in-progress progress panel's visibility (#105).
    /// The panel — a step count + progress bar pushed down from the header — is
    /// shown ONLY when the plan is `in-progress` AND its `## How` checklist has
    /// at least one step (`total > 0`). `howProgress == (0, 0)` means the How
    /// section has no checkboxes (NOT that work is complete), so there is nothing
    /// to chart and the panel stays hidden. It deliberately stays up at 100%
    /// (`done == total`) while the status is still `in-progress`: the panel
    /// disappears on the status transition, not when the bar fills. Pure/static
    /// so the gating rule is unit-testable without the view.
    static func showsProgressPanel(status: TaskStatus?,
                                   howProgress: (done: Int, total: Int)) -> Bool {
        status == .inProgress && howProgress.total > 0
    }

    /// The progress bar's fill fraction for the in-progress panel (#105):
    /// `done / total` as a `Double`, guarding divide-by-zero by returning `0`
    /// when `total == 0`. Pure/static so the arithmetic is unit-testable without
    /// the view; callers pass this (or `done`/`total` directly) to the built-in
    /// `ProgressView` — nothing is measured, in keeping with #096.
    static func progressFraction(done: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(done) / Double(total)
    }



    /// The progress drawer's header title (#107), matching the old
    /// `RunProgressSheet.title`/`modeVerb` logic so the de-modalized log keeps
    /// the same wording. Capture / captureElaborate / executeYolo runs have no
    /// real task id yet — they're keyed by a synthetic `"capture:<path>"`
    /// identity — so they show only the verb ("Capturing", "Capturing &
    /// elaborating", "Capturing & executing") rather than "Capturing task
    /// #capture:/…". Real runs keep the "verb task #NNN" form; a `nil` mode falls
    /// back to the Execute verb. Pure/static so the wording is unit-testable
    /// without the view.
    static func progressDrawerTitle(mode: RunMode?, taskID: String?) -> String {
        let verb = mode?.activityVerb ?? RunMode.execute.activityVerb
        switch mode {
        case .capture, .captureElaborate, .executeYolo:
            return verb
        default:
            return taskID.map { "\(verb) task #\($0)" } ?? verb
        }
    }

    /// Whether the composer may send `text`: a non-blank question while no
    /// discussion turn is pending.
    static func canSendDiscussion(_ text: String, isBusy: Bool) -> Bool {
        !isBusy && discussSubmission(text) != nil
    }

    /// Whether the composer's trailing control is a stop button (cancelling the
    /// pending turn) rather than send.
    static func composerShowsStop(isBusy: Bool) -> Bool {
        isBusy
    }

    /// Whether the detail column splits into plan (top) and conversation panel
    /// (bottom). Only once a question has been asked; until then the column is
    /// just the plan with the composer pinned beneath it.
    static func showsConversationPanel(turnCount: Int) -> Bool {
        turnCount > 0
    }

    /// The turn the transcript scrolls to as the conversation grows: the newest.
    static func discussionScrollTarget(for turns: [DiscussionTurn]) -> UUID? {
        turns.last?.id
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
            // #105: one step below the plan title (`.title`), so What/Why/How
            // read as sections of the plan rather than competing with its name.
            Text(section.heading)
                .font(.title2.weight(.semibold))

            if let placeholder = Self.placeholderText(section.body) {
                placeholderView(placeholder)
            } else if section.heading == "How" {
                howChecklist(section.body)
            } else {
                markdownBlockView(section.body)
            }
        }
    }

    /// Renders a section body as block-level markdown: paragraphs, bullet /
    /// numbered lists, fenced code, blockquotes, and sub-headings, in document
    /// order. Purely presentational — performs no writes.
    ///
    /// `.equatable()` lets a parent re-evaluation (every store poll, every run
    /// update) skip this subtree when the body and style are unchanged.
    private func markdownBlockView(_ body: String, style: MarkdownStyle = .plan) -> some View {
        MarkdownBlockView(body: body, style: style)
            .equatable()
    }

    /// #105: the plans-cc "to be filled" stub for a section that a later
    /// lifecycle stage writes (`_To be filled during elaboration_`, …), with its
    /// emphasis markers stripped, or `nil` when the body is real content. Only a
    /// body that is SOLELY one such italic line counts. Pure.
    static func placeholderText(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n"), trimmed.count > 2 else { return nil }
        for marker in ["_", "*"] where trimmed.hasPrefix(marker) && trimmed.hasSuffix(marker) {
            let inner = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
            return inner.hasPrefix("To be filled") ? inner : nil
        }
        return nil
    }

    /// #105: a soft, recessed note standing in for a section a later stage will
    /// write — muted italic text with a small hourglass in a faint dashed box,
    /// so it reads as "not yet" rather than as plan content.
    private func placeholderView(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hourglass")
                .imageScale(.small)
            Text(text)
                .italic()
        }
        .font(.system(size: PlanType.bodySize - 2))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1),
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

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

/// A section/reply body rendered from `PreparedMarkdownCache`. Lifted to a
/// top-level `internal` struct (#117) so BOTH the plan-detail body and the agent
/// dock's discuss turns (`AgentTurnView`) render markdown through one renderer at
/// different `MarkdownStyle` scales. The final content is there on the first
/// frame: a loading placeholder made the section's height jump when the real text
/// replaced it, and preparing a whole plan costs only a few milliseconds, once
/// per body.
struct MarkdownBlockView: View, Equatable {
    let bodyText: String
    let style: MarkdownStyle

    init(body: String, style: MarkdownStyle = .plan) {
        self.bodyText = body
        self.style = style
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bodyText == rhs.bodyText && lhs.style == rhs.style
    }

    var body: some View {
        let blocks = PreparedMarkdownCache.shared.preparedBlocks(forBody: bodyText, style: style)
        return VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    /// Renders a single prepared block with restrained, readable styling.
    @ViewBuilder
    private func renderBlock(_ block: PreparedMarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            Text(text)
                .lineSpacing(style.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)

        case let .heading(level, text):
            Text(text)
                .font(headingFont(forLevel: level))
                .foregroundStyle(headingColor(forLevel: level))
                .padding(.top, style.headingTopPadding)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: style.listSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: style.markerSpacing) {
                        Text("•")
                            .font(.system(size: style.bodySize))
                            .foregroundStyle(.secondary)
                        Text(item)
                            .lineSpacing(style.lineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                }
            }

        case let .numberedList(items):
            VStack(alignment: .leading, spacing: style.listSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: style.markerSpacing) {
                        Text("\(index + 1).")
                            .font(.system(size: style.bodySize))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(item)
                            .lineSpacing(style.lineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                }
            }

        case let .codeBlock(highlighted):
            Text(highlighted)
                .font(.system(size: style.bodySize - 1, design: .monospaced))
                .lineSpacing(style.lineSpacing - 1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(style.codePadding)
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
                Text(text)
                    .foregroundStyle(.secondary)
                    .lineSpacing(style.lineSpacing)
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
        if let size = style.headingSize(forLevel: level) {
            return .system(size: size, weight: .semibold)
        }
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
        guard style.tintsHeadings else { return .primary }
        switch level {
        case 1: return .accentColor
        case 2: return .teal
        default: return .primary
        }
    }
}

/// The shared, host-agnostic run-log body (#107): the error banner, the
/// auto-scrolling activity/text log, the denial note, and the cost/turns summary
/// for a single `TaskRun`. Factored out of `RunProgressSheet` so BOTH the modal
/// sheet (while it remains) and the inline progress drawer (`progressDrawer`)
/// render one source of truth — no divergent copies of the log rendering (#107).
/// It renders only the stream content; the title/header/footer and
/// presentation chrome stay with each host. Nothing here measures its own size
/// (#096) — the log scrolls within whatever height the host gives it.
struct RunLogContents: View {
    /// The run to render, or `nil` when there is none (e.g. it was dropped) — the
    /// log then shows nothing.
    let run: TaskRun?

    /// The id of the line to scroll into view on first appearance: the last
    /// (newest) line, or `nil` when there are no lines yet. Pure so it's unit
    /// testable without constructing the view. (#117: moved here from the
    /// deleted `RunProgressSheet` — the log now lives wholly in `RunLogContents`.)
    static func scrollTarget(for lines: [LoggedEvent]) -> UUID? {
        lines.last?.id
    }

    /// Whether the red failure banner should be shown. Pure so it's unit
    /// testable without constructing the view. (#117: moved here from the
    /// deleted `RunProgressSheet`.)
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
        stopReason: String?,
        mode: RunMode = .execute
    ) -> Bool {
        guard let error else { return false }
        guard isRunning else { return true }
        return TaskRun.truncationError(for: stopReason, mode: mode) != error
    }

    /// `false` (default): the inset rounded log field used by the popover.
    /// `true`: the drawer's edge-to-edge treatment — no rounded field, content
    /// padded by `horizontalPadding`, the log's top padded by `topPadding` (to
    /// clear a floating header), and banners/summary in a footer below the log.
    var edgeToEdge: Bool = false
    var horizontalPadding: CGFloat = 0
    var topPadding: CGFloat = 0

    var body: some View {
        if edgeToEdge {
            VStack(alignment: .leading, spacing: 0) {
                logList
                if hasFooter {
                    Divider()
                    footer
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, 12)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                errorBannerIfNeeded
                logList
                footer
            }
        }
    }

    private var failureMessage: String? {
        guard let error = run?.error,
              Self.shouldShowFailureBanner(
                  error: error,
                  isRunning: run?.isRunning == true,
                  stopReason: run?.lastStopReason,
                  mode: run?.mode ?? .execute
              ) else { return nil }
        return error
    }

    private var hasFooter: Bool {
        failureMessage != nil || !(run?.deniedTools.isEmpty ?? true) || run?.summary != nil
    }

    @ViewBuilder
    private var errorBannerIfNeeded: some View {
        if let error = failureMessage {
            errorBanner(error)
        }
    }

    /// Denial note + summary (and, edge-to-edge, the error banner too, since the
    /// top of the log sits under the floating header).
    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if edgeToEdge { errorBannerIfNeeded }
            if let run, !run.deniedTools.isEmpty {
                deniedSummary(count: run.deniedTools.count,
                              names: Array(run.deniedToolNames).sorted())
            }
            if let summary = run?.summary {
                summaryRow(summary)
            }
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
                    // arrives, show a "Starting…" / "Waiting…" row so the log is
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
                .padding(.horizontal, edgeToEdge ? horizontalPadding : 8)
                .padding(.top, edgeToEdge ? topPadding : 8)
                .padding(.bottom, edgeToEdge ? 14 : 8)
                // Stretch the log column to the full scroll width even while it
                // holds only the short "Starting…/Waiting…" placeholder, so the
                // inset `.textBackgroundColor` field is full-width from the first
                // frame instead of hugging the narrow placeholder until log lines
                // (which already carry `maxWidth: .infinity`) arrive.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: edgeToEdge ? 0 : 6))
            .onChange(of: lines.count) {
                if let last = lines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            // On first appearance against a run that already has buffered
            // lines (e.g. opening the drawer of an in-progress task), jump
            // straight to the newest line — instantly, no animation — so the
            // view opens at the bottom instead of the top.
            .onAppear {
                if let target = Self.scrollTarget(for: lines) {
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
        case let .denied(tool):
            // Task #092: a non-fatal denied tool call. Shown inline as a muted
            // warning line (NOT the red error banner) since the run continues.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Tool not allowed:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(tool)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        case .done, .error, .reply:
            // Rendered out-of-band as the summary row / error banner; a reply's
            // text has already streamed in as `text` chunks.
            EmptyView()
        case .session:
            EmptyView()
        case .captured:
            // Task #100: an internal reconciliation signal (the launcher's real
            // task id), not a user-facing log line — consumed by TaskRunner's
            // live-capture hand-off, nothing to show in the stream.
            EmptyView()
        case let .question(_, questions):
            // Task #083: a guided-review question. The rich answer panel is built
            // in Step 6; for now render a minimal inline marker so the stream
            // switch is exhaustive and the pending question is at least visible.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text(questions.first?.question ?? "Review question")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summaryRow(_ summary: (costUsd: Double, turns: Int)) -> some View {
        Text(String(format: "$%.2f · %d turns", summary.costUsd, summary.turns))
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    /// The run-summary denial note (task #092): a caution row listing the count
    /// of denied tool calls and the distinct tool names, orange rather than red
    /// (the denial is non-fatal — the run still finished). Mirrors the detail
    /// view's `deniedToolsSection` so the same information persists whether the
    /// user watches the drawer or returns to the plan body afterwards.
    private func deniedSummary(count: Int, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                Text("\(count) tool call\(count == 1 ? "" : "s") denied — the plan may be "
                     + "built on incomplete information")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !names.isEmpty {
                Text(names.joined(separator: ", "))
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
}
