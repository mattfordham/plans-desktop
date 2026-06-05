import SwiftUI

/// Surface C: a single project rendered as a discrete dashboard card.
///
/// The card has two parts:
///
/// - **Header:** the project name as a prominent heading plus a per-status count
///   summary. Iterating `TaskStatus.glanceOrder` (the TUI `STAT_CARDS` order,
///   `completed` excluded), each status with a non-zero `counts` entry shows its
///   real SF Symbol `Image(systemName: status.symbolName)` in
///   `status.glanceColor` next to the count. Zero-count statuses are dropped.
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

    /// The non-zero status counts to show in the header, in `glanceOrder`.
    /// Statuses absent from `counts` or with a `0` count are dropped.
    private var statusCounts: [(status: TaskStatus, count: Int)] {
        TaskStatus.glanceOrder.compactMap { status in
            guard let count = project.counts[status], count > 0 else { return nil }
            return (status, count)
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
        .padding(14)
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
                        .foregroundStyle(entry.status.glanceColor)
                        .frame(width: 20, alignment: .center)
                    Text("\(entry.count)")
                        .font(.body)
                        .foregroundStyle(.secondary)
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
            // `.topLeading` keeps multi-line titles top-aligned with the icon.
            //
            // `horizontalSpacing: 0` (the inter-column gap is recreated via
            // per-cell trailing padding instead): with zero Grid spacing the
            // row's single highlight `.background` is one continuous region with
            // no gaps for it to break across — see `planRow`.
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 2) {
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

            Text(row.task.id)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)

            // Always-present cell (empty string when no type) so column 3 stays
            // aligned across every row.
            Text(typeText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.trailing, 8)

            Text(row.title ?? "(untitled)")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Row-level chrome: a single hit-test shape + the tap gesture applied to
        // the whole row so the entire row is one tap target (no inter-column gaps
        // since the Grid `horizontalSpacing` is 0). Tapping opens the plan detail
        // in its own window. No `.frame(maxHeight: .infinity)` so rows stay
        // content-sized and top-anchored (see the height note above).
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { openWindow(id: "plan-detail", value: row.id) }
    }
}
