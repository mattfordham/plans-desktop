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

    /// The clickable plan rows for this card, in `TaskParser`'s active order.
    private var rows: [TaskRow] {
        BrowserViewModel.activeRows(project)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            body(for: rows)
            // Top-anchor: LazyVGrid sizes every cell to its ROW's max height, so
            // a short card handed a taller cell would let this VStack distribute
            // the slack and drift its content toward vertical center. A trailing
            // `Spacer(minLength: 0)` absorbs the extra height so header + divider
            // + plan rows stay grouped at the TOP. The card's frame deliberately
            // sets NO maxHeight (below), so a content-sized card still hugs its
            // content — the Spacer only does work when the card is given extra
            // height. Mirrors the wrapper Spacer in `BrowserWindow.cardGrid`.
            Spacer(minLength: 0)
        }
        // Asymmetric padding so the visible gap under the LAST plan row matches
        // the gap above the header. Each plan row carries `.padding(.vertical, 5)`
        // (see `planRow`), so the final row already contributes ~5pt below itself;
        // we subtract that from the bottom edge (14 − 5 = 9) to even it out.
        .padding(.top, 14)
        .padding(.horizontal, 14)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: 1)
        )
    }

    // MARK: - Header (project name + per-status count summary)

    /// The card header: the project name plus the per-status count summary.
    /// Not a tap target — only the plan rows below are clickable.
    private var header: some View {
        HStack(spacing: 8) {
            Text(project.projectName)
                .font(.headline)
                .lineLimit(1)

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
            // Execute icon button, or an inline spinner while THIS row is being
            // worked. This cell deliberately does NOT carry the open-detail tap
            // gesture (which lives on the content cells above) so the button's
            // own tap is never swallowed by a row-level gesture. The full live
            // log is available by opening the row's detail window.
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
                // Tapping the live spinner pops the run's progress dialog in
                // place, anchored just below the spinner, with the run's live log.
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { progressPopoverTaskID = row.task.id }
                    .help("Show progress")
                    .popover(isPresented: progressPopover(for: row.task.id),
                             attachmentAnchor: .point(.bottom),
                             arrowEdge: .top) {
                        // Same dialog the detail view presents as a sheet; here it
                        // pops over the spinner. On close, drop the finished run
                        // and reload so the task's new status surfaces — mirrors
                        // the detail view's sheet teardown.
                        RunProgressSheet(run: runner.run(for: row.task.id),
                                         taskID: row.task.id)
                            .onDisappear {
                                runner.dismiss(taskID: row.task.id)
                                store.reload()
                            }
                    }
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
