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
///   row sets `selectedRowID` to that row's id; the header/project is NOT a tap
///   target. When there are no active plans the body shows a muted empty state.
///
/// The card is strictly READ-ONLY (§2): it only reads from the injected
/// `ProjectTasks` and drives selection through the `selectedRowID` binding. It
/// has NO toggles, status pickers, How checkboxes, or any FS-mutating calls.
struct ProjectCard: View {
    /// The project this card renders. Read-only; never mutated.
    let project: ProjectTasks

    /// The dashboard's currently selected plan row id, driven by tapping a row
    /// in this (or any sibling) card. `nil` when nothing is selected.
    @Binding var selectedRowID: TaskRow.ID?

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
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    planRow(row)
                }
            }
        }
    }

    /// A single tappable plan row: the status icon (blocked takes precedence),
    /// the short 3-char task id, an optional `[type]` tag, and the title. The
    /// whole row is the tap target (sets `selectedRowID`); the selected row is
    /// subtly highlighted.
    private func planRow(_ row: TaskRow) -> some View {
        let indicator = row.indicator
        let isSelected = row.id == selectedRowID
        return Button {
            selectedRowID = row.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: indicator.symbolName)
                    .imageScale(.large)
                    .foregroundStyle(indicator.color)
                    .frame(width: 20, alignment: .center)
                Text(row.task.id)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let type = row.type {
                    Text("[\(type.label)]")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(row.title ?? "(untitled)")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}
