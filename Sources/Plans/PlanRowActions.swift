import SwiftUI
import OSLog

private let rowActionsLog = Logger(subsystem: "com.plans.desktop", category: "PlanRowActions")

/// The trailing per-row action cell for a plan row, extracted (#094) so the
/// identical control can be rendered by BOTH `ProjectCard.planRow` and the
/// cross-project `TaskListRow` without duplicating the branch logic, the five
/// request structs, the per-row run-progress popover, or the five consent-gate
/// `.sheet(item:)` modals.
///
/// It owns its OWN sheet state: each of the five request `@State` vars and their
/// `.sheet(item:)` modifiers live here, so a row's action modal is scoped to the
/// row's own actions view rather than the enclosing card. The visuals and branch
/// behaviour are moved verbatim from the former `ProjectCard.rowActions(_:)`.
///
/// While this row's task is being worked, shows an inline spinner (tapping it
/// toggles the run's progress popover). Otherwise shows the SINGLE status-relevant
/// action(s): Retry for a failed run, Elaborate + direct-Execute for a pending
/// task, Refine + Execute for an elaborated/in-progress task, Refine + Execute for
/// a review-state task, and an empty spacer for any other status. Every state is
/// pinned to the same fixed `.frame(height: 22)` so the row's line height never
/// shifts when the spinner/glyph appears or disappears.
///
/// Reads the shared `PlansStore` and `TaskRunner` from the environment itself
/// (exactly as `ProjectCard` did) — it never writes `.plans/` (§2); the run is the
/// sole writer, driven by the bundled Agent-SDK process.
struct PlanRowActions: View {
    /// The row whose action this cell renders. Read-only; never mutated.
    let row: TaskRow

    /// The shared task store, re-read after a run's progress popover closes so the
    /// task's new status is surfaced by the existing read path. Read-only (§2).
    @Environment(PlansStore.self) private var store

    /// The shared "Work this task" runner, for the per-row Elaborate / Execute
    /// icon buttons and inline running status. Reads only — the run itself is the
    /// sole writer of `.plans/` (§2), driven by the bundled Agent-SDK process.
    @Environment(TaskRunner.self) private var runner

    /// Whether this row's run-progress popover is currently open. Scoped to this
    /// single row's actions view (one per row), so it needs no id disambiguation.
    @State private var progressPopoverOpen = false

    /// The pending "Refine Plan" request (#056), or `nil` when no Refine sheet is
    /// open. Set by the Refine glyph (elaborated, non-blocked tasks only); an
    /// `.sheet(item:)` keyed on it presents the `ReElaborateModal`.
    @State private var reElaborateRequest: ReElaborateRequest? = nil

    /// The pending "Elaborate" request (#074), or `nil` when no Elaborate sheet is
    /// open. Set by the Elaborate glyph (pending, non-blocked tasks only); an
    /// `.sheet(item:)` keyed on it presents the `ElaborateModal`.
    @State private var elaborateRequest: ElaborateRequest? = nil

    /// The pending "Execute" request (#078), or `nil` when no Execute sheet is
    /// open. Set by the Execute glyph (elaborated/in-progress, non-blocked tasks
    /// only); an `.sheet(item:)` keyed on it presents the `ExecuteModal`.
    @State private var executeRequest: ExecuteRequest? = nil

    /// The pending direct-"Execute" request (#088), or `nil` when no direct-Execute
    /// sheet is open. Set by a pending row's `play.fill` glyph; an `.sheet(item:)`
    /// keyed on it presents the `ExecutePendingModal`.
    @State private var executePendingRequest: ExecutePendingRequest? = nil

    /// The pending "Re-elaborate for review" request (#091), or `nil` when no
    /// review-Refine sheet is open. Set by a review-state row's `sparkles` glyph; an
    /// `.sheet(item:)` keyed on it presents the `ReviewReElaborateModal`.
    @State private var reviewReElaborateRequest: ReviewReElaborateRequest? = nil

    var body: some View {
        actions
            // Pin the cell to the glyph's height in every state so swapping between
            // spinner / glyph / empty never changes the row's line height.
            .frame(height: 22)
            // The "Refine Plan" sheet (#056), keyed on this row's task so the modal
            // targets exactly the row whose Refine glyph was tapped. The
            // `ReElaborateModal` hands the user's guidance to the runner in
            // `.reElaborate` mode (the sole `.plans/` writer, §2).
            .sheet(item: $reElaborateRequest) { request in
                ReElaborateModal(taskID: request.taskID, projectPath: request.projectPath)
            }
            // The "Elaborate" sheet (#074). The `ElaborateModal` hands the user's
            // OPTIONAL guidance plus the Deep flag to the runner in `.elaborate`
            // mode (the sole `.plans/` writer, §2).
            .sheet(item: $elaborateRequest) { request in
                ElaborateModal(taskID: request.taskID, projectPath: request.projectPath)
            }
            // The "Execute" sheet (#078). The `ExecuteModal` hands the Keep flag to
            // the runner in `.execute` mode (the sole `.plans/` writer, §2); with
            // Keep off it spawns exactly the run the bare glyph used to fire.
            .sheet(item: $executeRequest) { request in
                ExecuteModal(taskID: request.taskID, projectPath: request.projectPath)
            }
            // The pending direct-"Execute" sheet (#088). The `ExecutePendingModal`
            // hands the OPTIONAL guidance plus the Deep and Keep flags to the runner
            // in `.execute` mode (the sole `.plans/` writer, §2), which
            // auto-elaborates the plan inline and then executes it.
            .sheet(item: $executePendingRequest) { request in
                ExecutePendingModal(taskID: request.taskID, projectPath: request.projectPath,
                                    forReview: request.forReview)
            }
            // The "Re-elaborate for review" sheet (#091). The `ReviewReElaborateModal`
            // hands the OPTIONAL guidance plus the Deep flag to the runner in
            // `.reElaborateReview` mode (the sole `.plans/` writer, §2), which
            // resets the plan to pending and re-elaborates it.
            .sheet(item: $reviewReElaborateRequest) { request in
                ReviewReElaborateModal(taskID: request.taskID, projectPath: request.projectPath)
            }
    }

    /// Whether this row's run is a guided review PARKED on a question (#083): a
    /// needs-input signal so a review the user navigated away from isn't lost. The
    /// gate comes from the pure `PlanDetailView.reviewNeedsInput` helper.
    private var reviewNeedsInput: Bool {
        guard let run = runner.run(for: row.task.id, in: row.projectPath) else { return false }
        return PlanDetailView.reviewNeedsInput(hasPendingQuestion: run.pendingQuestion != nil)
    }

    @ViewBuilder
    private var actions: some View {
        if runner.isRunning(taskID: row.task.id, in: row.projectPath) {
            // #083: a guided review parked on a question lights a needs-input
            // badge beside the spinner, so the parked review is visible after
            // switching plans. Tapping it (like the spinner) opens the progress
            // popover; the full answer panel lives in the detail view.
            HStack(spacing: 2) {
                if reviewNeedsInput {
                    Image(systemName: "questionmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(Color.accentColor)
                        .help("This review needs your input")
                }
            // Tapping the live spinner toggles the run's progress dialog in
            // place, anchored to the spinner, with the run's live log. The
            // `.popover` attaches to the bare spinner glyph's BOUNDS so macOS
            // lands the arrow against whichever glyph edge it flips to with the
            // arrow tip just off the spinner rather than piercing its center.
            ProgressView()
                .controlSize(.small)
                .popover(isPresented: $progressPopoverOpen,
                         attachmentAnchor: .rect(.bounds)) {
                    // Same dialog the detail view presents as a sheet; here it
                    // pops over the spinner. The explicit 480pt width (matching
                    // the sheet's own `minWidth`) gives the popover a stable
                    // width from first paint. On close, drop the finished run and
                    // reload so the task's new status surfaces.
                    RunProgressSheet(run: runner.run(for: row.task.id, in: row.projectPath),
                                     taskID: row.task.id)
                        .frame(width: 480)
                        .onDisappear {
                            runner.dismiss(taskID: row.task.id, in: row.projectPath)
                            store.reload()
                        }
                }
                .padding(.leading, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    progressPopoverOpen.toggle()
                }
                .help("Show progress")
            }
        } else if PlanDetailView.canRetry(failure: row.task.failure) {
            // #079: the latest run for this plan failed. Offer a Retry glyph that
            // re-runs `plan-execute` via the SAME Execute consent gate as the
            // Execute glyph below (the `ExecuteModal` sheet keyed on
            // `executeRequest`) — never a silent reload.
            RowActionGlyph(systemImage: "arrow.clockwise", help: "Retry this plan") {
                rowActionsLog.notice("row Retry clicked: task=\(row.task.id, privacy: .public)")
                executeRequest = ExecuteRequest(
                    taskID: row.task.id,
                    projectPath: row.projectPath
                )
            }
        } else if PlanDetailView.canElaborate(status: row.task.status,
                                              isBlocked: row.task.isBlocked,
                                              isBacklogged: row.task.isBacklogged) {
            // A pending, non-blocked task surfaces BOTH Elaborate and a
            // direct-Execute glyph (#088), mirroring the elaborated-row
            // Refine+Execute pair below: a tight `HStack(spacing: -4)` of two
            // `RowActionGlyph`s so they read as a tight pair within the row's
            // pinned height.
            HStack(spacing: -4) {
                RowActionGlyph(systemImage: "sparkles", help: "Elaborate this plan") {
                    rowActionsLog.notice("row Elaborate clicked: task=\(row.task.id, privacy: .public)")
                    elaborateRequest = ElaborateRequest(
                        taskID: row.task.id,
                        projectPath: row.projectPath
                    )
                }
                RowActionGlyph(systemImage: "play.fill", help: "Execute this plan directly") {
                    rowActionsLog.notice("row direct-Execute clicked: task=\(row.task.id, privacy: .public)")
                    executePendingRequest = ExecutePendingRequest(
                        taskID: row.task.id,
                        projectPath: row.projectPath
                    )
                }
            }
        } else if PlanDetailView.canWork(status: row.task.status,
                                         isBlocked: row.task.isBlocked,
                                         isBacklogged: row.task.isBacklogged) {
            // An elaborated, non-blocked task surfaces BOTH Refine and Execute
            // (#056). Refine opens the `ReElaborateModal`; Execute opens the
            // `ExecuteModal` (#078) rather than firing the run straight off the
            // glyph. `canWork` and `canReElaborate` share the same gate.
            HStack(spacing: -4) {
                RowActionGlyph(systemImage: "sparkles", help: "Refine this plan") {
                    rowActionsLog.notice("row Refine clicked: task=\(row.task.id, privacy: .public)")
                    reElaborateRequest = ReElaborateRequest(
                        taskID: row.task.id,
                        projectPath: row.projectPath
                    )
                }
                RowActionGlyph(systemImage: "play.fill", help: "Execute this plan") {
                    rowActionsLog.notice("row Execute clicked: task=\(row.task.id, privacy: .public)")
                    executeRequest = ExecuteRequest(
                        taskID: row.task.id,
                        projectPath: row.projectPath
                    )
                }
            }
        } else if PlanDetailView.canExecuteReview(status: row.task.status,
                                                  isBlocked: row.task.isBlocked,
                                                  isBacklogged: row.task.isBacklogged)
                    || PlanDetailView.canReElaborateReview(status: row.task.status,
                                                           isBlocked: row.task.isBlocked,
                                                           isBacklogged: row.task.isBacklogged) {
            // A review-state (review/in-review), non-blocked task surfaces BOTH
            // Refine and Execute (#091). Refine opens the `ReviewReElaborateModal`
            // (which resets the plan to pending and re-elaborates); Execute opens
            // the `ExecutePendingModal` in review mode. The two share the same gate.
            HStack(spacing: -4) {
                RowActionGlyph(systemImage: "sparkles", help: "Re-elaborate this plan for review") {
                    rowActionsLog.notice("row review-Refine clicked: task=\(row.task.id, privacy: .public)")
                    reviewReElaborateRequest = ReviewReElaborateRequest(
                        taskID: row.task.id,
                        projectPath: row.projectPath
                    )
                }
                RowActionGlyph(systemImage: "play.fill", help: "Execute this plan again") {
                    rowActionsLog.notice("row review-Execute clicked: task=\(row.task.id, privacy: .public)")
                    executePendingRequest = ExecutePendingRequest(
                        taskID: row.task.id,
                        projectPath: row.projectPath,
                        forReview: true
                    )
                }
                // An in-review plan can also be completed (merge + archive).
                // It moves git state, so the glyph only ever opens the explicit
                // confirmation — never a one-click run.
                if PlanDetailView.canComplete(status: row.task.status,
                                              branch: row.task.branch,
                                              isBlocked: row.task.isBlocked,
                                              isBacklogged: row.task.isBacklogged,
                                              hasLiveRun: false),
                   let branch = row.task.branch {
                    RowActionGlyph(systemImage: "checkmark.seal", help: "Complete this plan…") {
                        rowActionsLog.notice("row Complete clicked: task=\(row.task.id, privacy: .public)")
                        if PlanDetailView.confirmComplete(taskID: row.task.id, title: row.title,
                                                          branch: branch) {
                            runner.complete(projectPath: row.projectPath, taskID: row.task.id)
                        }
                    }
                }
            }
        } else {
            // No action for this status: an empty spacer of the same height so the
            // row's vertical metrics match action-bearing rows.
            Color.clear.frame(width: 0)
        }
    }
}

// MARK: - Request structs (moved from ProjectCard, #094)

/// A pending "Refine Plan" request (#056): the task + project a tapped Refine
/// glyph targets, driving the `.sheet(item:)`. `Identifiable` on the task id so
/// SwiftUI presents (and re-targets) the sheet for the right row.
struct ReElaborateRequest: Identifiable {
    let taskID: String
    let projectPath: String
    var id: String { taskID }
}

/// A pending "Elaborate" request (#074): the task + project a tapped Elaborate
/// glyph targets. A distinct type from `ReElaborateRequest` so the two sheets stay
/// independently keyed and can never be presented against each other's state.
struct ElaborateRequest: Identifiable {
    let taskID: String
    let projectPath: String
    var id: String { taskID }
}

/// A pending "Execute" request (#078): the task + project a tapped Execute glyph
/// targets. A distinct type from `ElaborateRequest`/`ReElaborateRequest` so the
/// sheets stay independently keyed.
struct ExecuteRequest: Identifiable {
    let taskID: String
    let projectPath: String
    var id: String { taskID }
}

/// A pending direct-"Execute" request (#088): the task + project a tapped pending
/// `play.fill` glyph targets. A distinct type so this sheet stays independently
/// keyed from the elaborated-plan Execute sheet.
struct ExecutePendingRequest: Identifiable {
    let taskID: String
    let projectPath: String
    /// Whether the target is a review-state plan (#091), so the sheet asks for
    /// context for another pass and hides Deep.
    var forReview = false
    var id: String { taskID }
}

/// A pending "Re-elaborate for review" request (#091): the task + project a tapped
/// review-state `sparkles` glyph targets. A distinct type so this sheet stays
/// independently keyed from the elaborated-plan Refine sheet.
struct ReviewReElaborateRequest: Identifiable {
    let taskID: String
    let projectPath: String
    var id: String { taskID }
}

// MARK: - Row action glyph (moved from ProjectCard, #094)

/// A single small tappable glyph for a row action, with hover and press feedback.
/// Implemented as an Image with its own `.onTapGesture` + `.contentShape` (NOT a
/// `Button`): a borderless `Button` nested in a row alongside other tap gestures
/// proved unreliable to hit-test on macOS, whereas the tap-gesture primitive is
/// the same one the content cells use to open detail and works reliably.
///
/// Feedback: on hover the glyph brightens to the primary color over a subtly
/// tinted rounded background and the cursor switches to a pointing hand; while
/// pressed it scales down and dims, then runs `action` on release.
///
/// #094: moved out of `ProjectCard` into this shared file (no longer `private`) so
/// both `PlanRowActions` here and `ProjectCard` reuse the one definition.
struct RowActionGlyph: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Image(systemName: systemImage)
            .imageScale(.medium)
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(pressed ? 0.18 : (hovering ? 0.10 : 0)))
            )
            .scaleEffect(pressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .contentShape(Rectangle())
            // A min-distance-0 drag gesture gives us press-down / release-up
            // feedback that `.onTapGesture` alone can't: press dims+shrinks the
            // glyph, and releasing within the 22×22 glyph bounds fires the action.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { value in
                        pressed = false
                        let bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
                        if bounds.contains(value.location) { action() }
                    }
            )
            .onHover { hovering = $0 }
            .padding(.leading, 8)
            .help(help)
    }
}
