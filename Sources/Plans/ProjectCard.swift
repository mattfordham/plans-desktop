import SwiftUI
import OSLog

private let cardLog = Logger(subsystem: "com.plans.desktop", category: "ProjectCard")

/// Surface C: a single project rendered as a discrete dashboard card.
///
/// The card has two parts:
///
/// - **Header:** the project name as a prominent heading plus a per-status count
///   summary. Iterating `TaskStatus.glanceOrder` (the TUI `STAT_CARDS` order,
///   `completed` excluded), each status with a non-zero `counts` entry shows its
///   real SF Symbol `Image(systemName: status.symbolName)` in
///   `status.glanceColor` next to the count. Every status is shown; zero-count
///   statuses are rendered dimmed (50% white) rather than dropped.
/// - **Body:** one tappable row per active plan from
///   `BrowserViewModel.activeRows(project)` (already non-completed and sorted by
///   `TaskParser`). Each row shows the task's status icon via the symbol-based
///   `TaskStatusIndicator` (blocked takes precedence), the short 3-char task id,
///   an optional `[type.label]` tag (`TaskType.label`), and the title. Tapping a
///   row opens that plan's detail in a separate window (`openWindow(id:value:)`,
///   §011) — it no longer sets a selection; the header/project is NOT a tap
///   target. When there are no active plans the body shows a muted empty state.
///
/// The card is strictly READ-ONLY (§2): it only reads from the injected
/// `ProjectTasks` and opens a detail window on tap. It has NO toggles, status
/// pickers, How checkboxes, or any FS-mutating calls.
struct ProjectCard: View {
    /// The project this card renders. Read-only; never mutated.
    let project: ProjectTasks

    /// The fixed cell height imposed on this card by `BrowserWindow.cardGrid` in
    /// fit-to-screen ("grid") layout, or `nil` in scroll layout (#038).
    ///
    /// When non-nil the card is height-constrained, so its body scrolls
    /// internally (`shouldScrollContent`) rather than overflowing the cell. When
    /// `nil` the card lays out at its natural, content-hugging height exactly as
    /// before. Defaulted to `nil` so existing call sites stay source-compatible;
    /// declared BEFORE `onNewPlan` so the synthesized memberwise initializer is
    /// `ProjectCard(project:constrainedHeight:onNewPlan:)` and the trailing-closure
    /// call site keeps working.
    var constrainedHeight: CGFloat? = nil

    /// Opens the shared "New Plan" modal pre-selected to this card's project
    /// (#031). Invoked by the header "+" glyph with `project.projectPath`; the
    /// presenting `BrowserWindow` owns the sheet state. Replaces the former
    /// inline capture popover this card used to host itself.
    let onNewPlan: (String) -> Void

    /// Opens the standalone plan-detail window (§011) for a tapped row, keyed on
    /// the row's composite `TaskRow.ID`.
    @Environment(\.openWindow) private var openWindow

    /// The shared task store, re-read after a run's progress popover closes so the
    /// task's new status is surfaced by the existing read path. Read-only (§2).
    @Environment(PlansStore.self) private var store

    /// The shared "Work this task" runner, for the per-row Elaborate / Execute
    /// icon buttons and inline running status. Reads only — the run itself is the
    /// sole writer of `.plans/` (§2), driven by the bundled Agent-SDK process.
    @Environment(TaskRunner.self) private var runner

    /// Which row's run-progress popover is currently open, by task id, or `nil`
    /// when none is. At most one progress popover is open at a time per card; the
    /// per-task `Binding<Bool>` from `progressPopover(for:)` drives the `.popover`
    /// on each row's spinner.
    @State private var progressPopoverTaskID: String? = nil

    /// A per-task `Binding<Bool>` for the run-progress popover: it reads `true`
    /// only when `progressPopoverTaskID` is this `taskID`, and on set assigns the
    /// id when raised / clears it when lowered — so opening one row's popover (or
    /// the popover dismissing itself) drives the single shared state.
    private func progressPopover(for taskID: String) -> Binding<Bool> {
        Binding(
            get: { progressPopoverTaskID == taskID },
            set: { progressPopoverTaskID = $0 ? taskID : nil }
        )
    }

    /// The status counts to show in the header, in `glanceOrder`. EVERY status
    /// is included; statuses absent from `counts` or with a `0` count surface as
    /// a `0` and are rendered dimmed (50% white) rather than dropped.
    private var statusCounts: [(status: TaskStatus, count: Int)] {
        TaskStatus.glanceOrder.map { status in
            (status, project.counts[status] ?? 0)
        }
    }

    /// The clickable plan rows for this card: the active plans in `TaskParser`'s
    /// active order. Starring is now a PROJECT-level concern (#035) — it keeps an
    /// empty card visible under "Hide Empty" but does not inject completed plans
    /// into the body — so this is just the active rows.
    private var rows: [TaskRow] {
        BrowserViewModel.activeRows(project)
    }

    // MARK: - Layout decision (scroll the body when height-constrained)

    /// Whether the card should scroll its body internally instead of laying it
    /// out at natural height.
    ///
    /// #038: in fit-to-screen ("grid") card layout, `BrowserWindow.cardGrid`
    /// imposes a FIXED per-row cell height on each card (the non-nil
    /// `constrainedHeight`). A project with many plans has a natural content
    /// height taller than that imposed frame, so without an inner scroll its plan
    /// list overflows the cell and overlaps the card beneath it. In scroll mode
    /// the card is handed `nil` (no imposed height) and lays out at its natural,
    /// content-hugging size while the surrounding `ScrollView` absorbs overflow.
    ///
    /// So the rule is purely: a non-nil imposed height → scroll the body inside
    /// the card (`true`); `nil` → natural height, no inner scroll (`false`). Any
    /// non-nil value (including `0`) counts as "constrained". Pure and view-free
    /// so the decision is unit-tested as a plain value, mirroring the layout
    /// helpers in `BrowserWindow`.
    static func shouldScrollContent(constrainedHeight: CGFloat?) -> Bool {
        constrainedHeight != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            // #038: the captures + plan list are the only growable content. When
            // the card is height-constrained (fit/grid mode imposes a fixed cell
            // height) a long list would overflow the cell and overlap the card
            // beneath it, so wrap that middle content in a `ScrollView` — header
            // stays pinned at the top, git footer pinned at the bottom, and the
            // list scrolls between them. The ScrollView greedily fills the slack
            // between header and footer, so no `Spacer` is needed in this path.
            //
            // In scroll mode (`constrainedHeight == nil`) the card lays out at its
            // natural, content-hugging height and the surrounding `ScrollView` in
            // `BrowserWindow.cardGrid` handles overflow, so render the content
            // inline (NO inner ScrollView) and keep the trailing `Spacer` that
            // pins header to the top and footer to the bottom of a taller cell —
            // byte-for-byte unchanged from before.
            if ProjectCard.shouldScrollContent(constrainedHeight: constrainedHeight) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        scrollableContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                scrollableContent
                // Top-anchor the header + body and bottom-anchor the footer:
                // LazyVGrid sizes every cell to its ROW's max height, so a short
                // card handed a taller cell has slack to distribute. This
                // `Spacer(minLength: 0)` sits BETWEEN the body and the footer, so
                // it absorbs all that slack in the middle — keeping
                // header/divider/plan rows pinned to the TOP and the git footer
                // pinned to the BOTTOM edge of the card. The card's frame sets NO
                // maxHeight (below), so a content-sized card still hugs its
                // content — the Spacer only does work when the card is given extra
                // height. Mirrors the wrapper Spacer in `BrowserWindow.cardGrid`.
                Spacer(minLength: 0)
            }
            // Git status footer (#026): mirrors the header's treatment — the
            // header is FOLLOWED by a `Divider()` (bottom separator); the footer
            // is PRECEDED by one (its top border). Only emitted for git repos so
            // a non-git project never shows a dangling divider.
            if project.gitBranch != nil {
                Divider()
                gitFooter
            }
        }
        // Bottom padding matches the header's 14pt top gap. When the git footer
        // is present it's the bottom-most element (a plain HStack with no vertical
        // padding of its own), so it needs the full 14pt. With no footer the last
        // element is a plan row that already carries `.padding(.vertical, 5)` (see
        // `planRow`), so we subtract that to even out the gap (14 − 5 = 9).
        .padding(.top, 14)
        .padding(.horizontal, 14)
        .padding(.bottom, project.gitBranch != nil ? 14 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        // #038: clip the card's content to the same rounded rect as its
        // background/border so a height-constrained card's scrolled body can
        // never paint outside its rounded bounds (e.g. into the corners or over
        // the card beneath it). Placed AFTER `.background` and BEFORE `.overlay`
        // so the stroke border still renders crisply on top of the clipped
        // content. A no-op in scroll/natural-height mode where the card already
        // hugs its content.
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: 1)
        )
    }

    /// The growable middle content of the card: the in-flight capture rows and
    /// the active plan list. Factored into one `@ViewBuilder` so it can be
    /// rendered either inline (scroll mode, natural height) or inside a
    /// `ScrollView` (fit/grid mode, height-constrained) without duplicating it
    /// across the `if`/`else` in `body` (#038). The header and git footer stay
    /// OUTSIDE this — they're pinned to the card's top and bottom edges.
    @ViewBuilder
    private var scrollableContent: some View {
        captureRows
        body(for: rows)
    }

    // MARK: - Header (project name + per-status count summary)

    /// The card header: the project name plus the per-status count summary.
    /// Not a tap target — only the plan rows below are clickable.
    private var header: some View {
        HStack(spacing: 8) {
            Text(project.projectName)
                .font(.headline)
                .lineLimit(1)
                .layoutPriority(1)

            // Star / unstar this PROJECT (#035): a filled yellow star keeps the
            // card visible in the dashboard even when it has no outstanding work
            // and "Hide Empty" is on. Placed immediately right of the project name
            // so it reads as a property of the project itself, not of any plan.
            starToggle

            // Capture / execute control: placed immediately right of the project
            // name. "+" opens the popover and stays put so back-to-back captures
            // can be submitted; running captures surface as stacked rows below the
            // divider. (Git status moved to the footer in #026, so the header no
            // longer carries the branch block.)
            captureControl

            Spacer(minLength: 8)

            ForEach(statusCounts, id: \.status) { entry in
                HStack(spacing: 4) {
                    Image(systemName: entry.status.symbolName)
                        .imageScale(.large)
                        // Zero-count statuses dim to 10% white so they read as
                        // present-but-empty; non-zero keep the vivid glance hue.
                        .foregroundStyle(entry.count == 0 ? Color.white.opacity(0.1) : entry.status.glanceColor)
                        .frame(width: 20, alignment: .center)
                    Text("\(entry.count)")
                        .font(.body)
                        .foregroundStyle(entry.count == 0 ? Color.white.opacity(0.1) : Color.secondary)
                }
            }
        }
    }

    // MARK: - Capture ("+" new plan)

    /// The per-project plan-capture control, placed immediately after the project
    /// name in the header. A "+" `CaptureGlyph` that opens the shared "New Plan"
    /// modal pre-selected to this project (#031, via `onNewPlan`) — the modal,
    /// not this card, now owns the description form and hands the result to
    /// `TaskRunner.capture` (the bundled Agent-SDK process is the sole writer of
    /// `.plans/`, §2). Running captures still surface as stacked rows below the
    /// divider (`captureRows`).
    @ViewBuilder
    private var captureControl: some View {
        // A "+" glyph sized to match the header status badges
        // (`imageScale(.large)`, 20pt wide) rather than the smaller per-row
        // action glyphs, so it reads as a peer of the count badges. Same
        // tap-gesture primitive as `RowActionGlyph` (a nested borderless
        // Button hit-tests unreliably here — see the file header note).
        CaptureGlyph {
            onNewPlan(project.projectPath)
        }
    }

    // MARK: - Capture progress rows (in-flight captures)

    /// One compact row per in-flight capture/execute run for this project,
    /// stacked between the header divider and the plan rows. Each row is a small
    /// spinner + the run's free-text `description`, tappable to toggle that run's
    /// progress popover (the same `RunProgressSheet` machinery the per-row spinner
    /// uses). The "+" stays put in the header, so submitting another capture adds
    /// another row here rather than displacing the control. Rendered as nothing
    /// when no captures are running, so an idle card shows no empty gap.
    @ViewBuilder
    private var captureRows: some View {
        let captures = runner.runningCaptures(projectPath: project.projectPath)
        if !captures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(captures, id: \.taskID) { run in
                    captureRow(run)
                }
            }
        }
    }

    /// A single in-flight capture row: a small spinner plus the run's description,
    /// tappable (same `contentShape` + `onTapGesture` primitive as the per-row
    /// spinner) to toggle that run's progress popover, anchored to the row bounds.
    /// On the popover's close the finished run is dropped and the store reloaded
    /// so the new task surfaces via the read path.
    @ViewBuilder
    private func captureRow(_ run: TaskRun) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(run.description ?? "Capturing…")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            progressPopoverTaskID = (progressPopoverTaskID == run.taskID) ? nil : run.taskID
        }
        .popover(isPresented: progressPopover(for: run.taskID),
                 attachmentAnchor: .rect(.bounds)) {
            RunProgressSheet(run: run, taskID: run.taskID)
                .frame(width: 480)
                .onDisappear {
                    runner.dismiss(taskID: run.taskID)
                    store.reload()
                }
        }
        .help("Show capture progress")
    }

    // MARK: - Footer (git status)

    /// The card footer: the project's git status — the branch glyph + name plus
    /// an orange dirty dot when the working tree is known-dirty (#026 moved this
    /// out of the header). Rendered only when the project is a git repo
    /// (`gitBranch != nil`); a `nil`/`false` `gitIsDirty` shows no dot. The
    /// branch text truncates so it never crowds the card.
    @ViewBuilder
    private var gitFooter: some View {
        if let branch = project.gitBranch {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(branch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if project.gitIsDirty == true {
                    Image(systemName: "circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Body (the active plan rows, or the empty state)

    /// The card body: a tappable row per active plan, or a muted empty state
    /// when there are none.
    @ViewBuilder
    private func body(for rows: [TaskRow]) -> some View {
        if rows.isEmpty {
            Text("No outstanding plans")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            // A `Grid` (not a VStack of HStacks) so every column auto-sizes to
            // the widest cell ACROSS ALL ROWS — that gives the id / [type] /
            // title columns a consistent left edge on every row (a table look).
            // `.center` vertical alignment centers each GridRow's cells against
            // one another, so the leading status icon sits vertically centered
            // with the row text. (A baseline alignment would pin the icon to the
            // text baseline near the bottom of the glyphs, leaving the circle low;
            // `.center` is the correct primitive for centering the icon with text.)
            //
            // `horizontalSpacing: 0` (the inter-column gap is recreated via
            // per-cell trailing padding instead): with zero Grid spacing the
            // row's single highlight `.background` is one continuous region with
            // no gaps for it to break across — see `planRow`.
            Grid(alignment: Alignment(horizontal: .leading, vertical: .center), horizontalSpacing: 0, verticalSpacing: 2) {
                ForEach(rows) { row in
                    planRow(row)
                }
            }
        }
    }

    /// A single tappable plan row as a `GridRow`: the status icon (blocked takes
    /// precedence), the short 3-char task id, an always-present `[type]` cell,
    /// and the title. The whole row is the tap target — tapping opens the plan's
    /// detail in a separate window (`openWindow(id:value:)`, §011).
    ///
    /// Implementation notes (chosen to keep Grid's cross-row column sizing
    /// intact — wrapping the row in a Button would defeat that):
    ///
    /// - The `[type]` cell is ALWAYS emitted (an empty monospaced `Text` when
    ///   `row.type` is nil) so column 3 exists in every row and stays aligned.
    /// - The hit-test shape and tap gesture are applied ONCE to the whole
    ///   `GridRow` (not per cell), so the entire row is a single tap target. With
    ///   the enclosing `Grid` at `horizontalSpacing: 0`, the inter-column gap is
    ///   recreated with per-cell `.padding(.trailing, 8)` on columns 1–3.
    /// - `.padding(.vertical, 5)` on the GridRow sets the row's height/tap area.
    ///   We deliberately do NOT use `.frame(maxHeight: .infinity)` here: that makes
    ///   each row a greedy vertical slack-absorber, so when LazyVGrid hands the card
    ///   a taller cell the rows expand and distribute the extra height (drifting
    ///   toward center). With rows content-sized, the card's trailing `Spacer` (and
    ///   the cardGrid wrapper Spacer) absorb all the slack and the rows stay pinned
    ///   under the header.
    @ViewBuilder
    private func planRow(_ row: TaskRow) -> some View {
        let indicator = row.indicator
        let typeText = row.type.map { "[\($0.label)]" } ?? ""

        GridRow {
            Image(systemName: indicator.symbolName)
                .imageScale(.large)
                .foregroundStyle(indicator.color)
                .frame(width: 20, alignment: .center)
                .padding(.trailing, 8)
                .modifier(OpenDetailOnTap(row: row, openWindow: openWindow))

            Text(row.task.id)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)
                .modifier(OpenDetailOnTap(row: row, openWindow: openWindow))

            // Always-present cell (empty string when no type) so column 3 stays
            // aligned across every row.
            Text(typeText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.trailing, 8)
                .modifier(OpenDetailOnTap(row: row, openWindow: openWindow))

            Text(row.title ?? "(untitled)")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(OpenDetailOnTap(row: row, openWindow: openWindow))

            // Trailing per-row action: the single status-relevant Elaborate /
            // Execute icon button (or an inline spinner while THIS row is being
            // worked). It deliberately does NOT carry the open-detail tap gesture
            // (which lives on the content cells above) so the control's own tap is
            // never swallowed by a row-level gesture.
            rowActions(row)
                .gridColumnAlignment(.trailing)
        }
        // `.padding(.vertical, 5)` sets the row's height/tap area. The open-detail
        // tap gesture is applied per content cell (see `OpenDetailOnTap`) rather
        // than once to the whole row, so the trailing action button keeps its own
        // independent hit target. No `.frame(maxHeight: .infinity)` so rows stay
        // content-sized and top-anchored (see the height note above).
        .padding(.vertical, 5)
    }

    /// The trailing action cell for a plan row. While this row's task is being
    /// worked, shows an inline spinner. Otherwise shows the SINGLE relevant
    /// action for the row's status: Elaborate for a `pending` task, Execute for
    /// an `elaborated`/`in-progress` task, and an empty spacer for any other
    /// status. Every state is pinned to the same fixed height so the row's line
    /// height never shifts when the spinner/glyph appears or disappears. The full
    /// live log is available by opening the row's detail window.
    @ViewBuilder
    private func rowActions(_ row: TaskRow) -> some View {
        Group {
            if runner.isRunning(taskID: row.task.id) {
                // Tapping the live spinner toggles the run's progress dialog in
                // place, anchored to the spinner, with the run's live log. The
                // `.popover` attaches to the bare spinner glyph's BOUNDS (not the
                // padded hit area, and not a single center point): anchoring to the
                // bounds lets macOS land the arrow against whichever glyph edge it
                // flips to (above when space is tight, below otherwise) with the
                // arrow tip just off the spinner rather than piercing its center.
                // The leading padding / content shape / tap gesture wrap that
                // anchored glyph.
                ProgressView()
                    .controlSize(.small)
                    .popover(isPresented: progressPopover(for: row.task.id),
                             attachmentAnchor: .rect(.bounds)) {
                        // Same dialog the detail view presents as a sheet; here it
                        // pops over the spinner. The explicit 480pt width (matching
                        // the sheet's own `minWidth`) gives the popover a stable
                        // width from first paint so the inset log field fills it
                        // immediately instead of resizing after the first layout
                        // pass. On close, drop the finished run and reload so the
                        // task's new status surfaces — mirrors the detail view's
                        // sheet teardown.
                        RunProgressSheet(run: runner.run(for: row.task.id),
                                         taskID: row.task.id)
                            .frame(width: 480)
                            .onDisappear {
                                runner.dismiss(taskID: row.task.id)
                                store.reload()
                            }
                    }
                    .padding(.leading, 8)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Toggle: clicking the spinner again while open closes it.
                        progressPopoverTaskID = (progressPopoverTaskID == row.task.id) ? nil : row.task.id
                    }
                    .help("Show progress")
            } else if PlanDetailView.canElaborate(status: row.task.status,
                                                  isBlocked: row.task.isBlocked) {
                RowActionGlyph(systemImage: "sparkles", help: "Elaborate this plan") {
                    cardLog.notice("card Elaborate clicked: task=\(row.task.id, privacy: .public)")
                    runner.run(projectPath: row.projectPath, taskID: row.task.id, mode: .elaborate)
                }
            } else if PlanDetailView.canWork(status: row.task.status,
                                             isBlocked: row.task.isBlocked) {
                RowActionGlyph(systemImage: "play.fill", help: "Execute this plan") {
                    cardLog.notice("card Execute clicked: task=\(row.task.id, privacy: .public)")
                    runner.run(projectPath: row.projectPath, taskID: row.task.id, mode: .execute)
                }
            } else {
                // No action for this status: an empty spacer of the same height
                // so the row's vertical metrics match action-bearing rows.
                Color.clear.frame(width: 0)
            }
        }
        // Pin the cell to the glyph's height in every state so swapping between
        // spinner / glyph / empty never changes the row's line height.
        .frame(height: 22)
    }

    /// The project star/unstar toggle (#035). A filled yellow `star.fill` when
    /// this project's path is in `store.starredProjectPaths`, otherwise an outline
    /// `star`. Tapping toggles membership of `project.projectPath` in the persisted
    /// set (`insert`/`remove` triggers the store's `didSet` persistence). Starring
    /// keeps the card visible in the dashboard past the "Hide Empty" filter even
    /// when the project has no outstanding work.
    @ViewBuilder
    private var starToggle: some View {
        let isStarred = store.starredProjectPaths.contains(project.projectPath)
        StarToggleGlyph(
            isStarred: isStarred,
            help: isStarred ? "Unstar project" : "Star project"
        ) {
            if store.starredProjectPaths.contains(project.projectPath) {
                store.starredProjectPaths.remove(project.projectPath)
            } else {
                store.starredProjectPaths.insert(project.projectPath)
            }
        }
    }
}

/// The project star/unstar glyph (#035). A `Button` with `.buttonStyle(.plain)`
/// whose label symbol and tint reflect the starred state: a filled yellow
/// `star.fill` when starred, an outline `star` otherwise. Adds a subtle hover
/// background + cursor like `RowActionGlyph`.
private struct StarToggleGlyph: View {
    let isStarred: Bool
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isStarred ? "star.fill" : "star")
                .imageScale(.medium)
                .foregroundStyle(isStarred ? AnyShapeStyle(.yellow)
                                           : AnyShapeStyle(hovering ? Color.primary : Color.secondary))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(hovering ? 0.10 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A single small tappable glyph for a row action, with hover and press
/// feedback. Implemented as an Image with its own `.onTapGesture` +
/// `.contentShape` (NOT a `Button`): a borderless `Button` nested in a `Grid`
/// row alongside other tap gestures proved unreliable to hit-test on macOS,
/// whereas the tap-gesture primitive is the same one the content cells use to
/// open detail and works reliably.
///
/// Feedback: on hover the glyph brightens to the primary color over a subtly
/// tinted rounded background and the cursor switches to a pointing hand; while
/// pressed it scales down and dims, then runs `action` on release.
private struct RowActionGlyph: View {
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
            // glyph, and releasing within the 22×22 glyph bounds fires the
            // action. (Attached before the leading padding so the gesture's
            // coordinate space is exactly the glyph, not the padded cell.)
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

/// The header "+" capture glyph. Like `RowActionGlyph` (same hover/press
/// feedback and tap-gesture primitive — a nested borderless `Button` hit-tests
/// unreliably in this layout), but sized to match the header status badges
/// (`imageScale(.large)`) rather than the smaller per-row action glyphs, so it
/// reads as a peer of the count badges sitting in the same header row.
private struct CaptureGlyph: View {
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Image(systemName: "plus.circle")
            .imageScale(.large)
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(pressed ? 0.18 : (hovering ? 0.10 : 0)))
            )
            .scaleEffect(pressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { value in
                        pressed = false
                        let bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
                        if bounds.contains(value.location) { action() }
                    }
            )
            .onHover { hovering = $0 }
            .help("Capture a new plan")
    }
}

/// Applies "open this plan's detail window on tap" to a single row content cell.
/// Used per content cell (id / type / title / status icon) rather than once on
/// the whole `GridRow`, so the trailing action button keeps an independent hit
/// target instead of competing with a row-wide tap gesture.
private struct OpenDetailOnTap: ViewModifier {
    let row: TaskRow
    let openWindow: OpenWindowAction

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { openWindow(id: "plan-detail", value: row.id) }
    }
}
