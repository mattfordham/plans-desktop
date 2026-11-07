import SwiftUI

/// #094: display strings for the shared cross-project task sort/group controls.
/// `TaskSort`/`TaskGroup` are pure value enums with no view vocabulary, so the
/// menu labels live here (file-scoped) rather than widening those enums.
extension TaskSort {
    var menuLabel: String {
        switch self {
        case .status: return "Status"
        case .project: return "Project"
        case .staleness: return "Recent"
        }
    }

    var menuSymbol: String {
        switch self {
        case .status: return "circle.grid.2x2"
        case .project: return "folder"
        case .staleness: return "clock"
        }
    }
}

extension TaskGroup {
    var menuLabel: String {
        switch self {
        case .status: return "Status"
        case .project: return "Project"
        }
    }

    var menuSymbol: String {
        switch self {
        case .status: return "circle.grid.2x2"
        case .project: return "folder"
        }
    }
}

/// #094: one row of the cross-project "smart view" task list. A flat, single-row
/// analogue of `ProjectCard.planRow` — same column metrics, zebra/hover styling,
/// failure tooltip, status indicator, `[type]` cell, flexible title, and trailing
/// `PlanRowActions` control — with an OPTIONAL leading project-label column so a
/// list that spans multiple projects shows which project each task belongs to.
///
/// It reuses the card's pinned `ProjectCard.rowColumns` / `rowStyling` /
/// `titleSizing` / `failureTooltip(for:)` so a task reads identically whether seen
/// on its project card or in a cross-project list. Tapping any content cell opens
/// that plan's detail via the injected `onOpenDetail` closure (the same
/// `OpenDetailOnTap` seam the card uses); the trailing action control keeps its
/// own hit target.
struct TaskListRow: View {
    /// The task this row renders. Read-only; never mutated.
    let row: TaskRow

    /// Row parity for the resting zebra stripe (matches `planRow`'s `index`).
    let index: Int

    /// Whether to show the leading project-label column. Set when the list spans
    /// multiple projects; omitted for a single-project list where every row would
    /// repeat the same name.
    let showsProjectLabel: Bool

    /// #094/#095: shows a tapped row in the browser's detail column, keyed on
    /// the row's composite `TaskRow.ID`. Threaded in by the presenting window.
    let onOpenDetail: (TaskRow.ID) -> Void

    /// #095: whether this row is the one shown in the browser's detail column.
    var isSelected: Bool = false

    /// #068: which row the pointer is over, tracked so hover strengthens the
    /// resting zebra stripe. Row-local (one per row view).
    @State private var hovering = false

    /// A fixed width for the project-label column so the status/id/type/title
    /// columns still line up across rows exactly as on a card.
    private var projectLabelWidth: CGFloat { 120 }

    var body: some View {
        let indicator = row.indicator
        let typeText = row.type.map { "[\($0.label)]" } ?? ""
        let isEven = index.isMultiple(of: 2)

        HStack(spacing: ProjectCard.rowColumns.columnGap) {
            if showsProjectLabel {
                // The owning project's name, leading the row so a cross-project
                // list reads which project each task belongs to. Tapping it opens
                // the plan detail like the other content cells.
                Text(row.projectName)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: projectLabelWidth, alignment: .leading)
                    .modifier(OpenDetailOnTap(row: row, onOpenDetail: onOpenDetail))
            }

            Image(systemName: indicator.symbolName)
                .imageScale(.large)
                .foregroundStyle(indicator.color)
                .frame(width: ProjectCard.rowColumns.statusWidth, alignment: .center)
                .help(ProjectCard.failureTooltip(for: row.task.failure) ?? "")
                .modifier(OpenDetailOnTap(row: row, onOpenDetail: onOpenDetail))

            Text(row.task.id)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: ProjectCard.rowColumns.idWidth, alignment: .leading)
                .modifier(OpenDetailOnTap(row: row, onOpenDetail: onOpenDetail))

            HStack(spacing: ProjectCard.rowColumns.typeCellSpacing) {
                Text(typeText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if row.task.showsKeptWorktreeMarker {
                    Image(systemName: TaskStatusIndicator.keptWorktreeSymbol)
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .help("Kept in worktree — reviewable in isolation")
                }
            }
            .frame(width: ProjectCard.rowColumns.typeWidth, alignment: .leading)
            .modifier(OpenDetailOnTap(row: row, onOpenDetail: onOpenDetail))

            Text(row.title ?? "(untitled)")
                .font(.body)
                .lineLimit(ProjectCard.titleSizing.lineLimit)
                .truncationMode(ProjectCard.titleSizing.truncationMode)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: ProjectCard.titleSizing.maxWidth, alignment: .leading)
                .modifier(OpenDetailOnTap(row: row, onOpenDetail: onOpenDetail))

            // Trailing per-row action — the SAME shared control the card uses.
            PlanRowActions(row: row)
        }
        .padding(.vertical, 5)
        // #095: unlike a card row, the list row's band runs flush to the content
        // column's edges (no `rowBandLeadingMargin` outside the band), so the
        // whole leading gutter moves INSIDE the band. The full card gutter keeps
        // the row text aligned with the section header and control bar.
        .padding(.leading, ProjectCard.rowColumns.cardHorizontalPadding)
        .padding(.trailing, ProjectCard.rowColumns.rowHorizontalPadding)
        .background(
            ProjectCard.rowStyling.background(
                isEven: isEven,
                isHovered: hovering,
                isSelected: isSelected
            )
            // #095: the painted band is also the row's fallback tap target, so a
            // click in the vertical padding, the column gaps, or a cell's blank
            // space selects the plan (see `OpenDetailOnTap`).
            .modifier(OpenDetailOnTap(row: row, onOpenDetail: onOpenDetail))
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// #094: the cross-project task list rendered in the browser's detail pane for a
/// smart view or a single project. It takes ALREADY-RESOLVED rows (the sidebar
/// selection → rows resolution is wired up in Segment 3 via the pure
/// `BrowserViewModel` helpers) plus whether to show the per-row project label,
/// then:
///
/// - sorts the rows via `BrowserViewModel.sortRows(_:by: store.taskSort)`,
/// - groups them into titled sections via
///   `BrowserViewModel.groupRows(_:by: store.taskGroup)`,
/// - renders each section's header + its `TaskListRow`s,
/// - offers a sort + group control (two `Menu`s mirroring the `ProjectViewMode`
///   toolbar idiom, bound to the persisted `store.taskSort` / `store.taskGroup`),
/// - and shows a centered muted empty state when there are no rows (mirroring the
///   grid's "No projects" overlay).
struct TaskListView: View {
    /// The already-resolved rows to display. Resolution (active + optional backlog,
    /// filtered by the sidebar selection) happens upstream in Segment 3.
    let rows: [TaskRow]

    /// Whether each row shows its owning project's name (true for cross-project
    /// lists; false for a single-project list).
    let showsProjectLabel: Bool

    /// #094/#095: shows a tapped row in the browser's detail column.
    let onOpenDetail: (TaskRow.ID) -> Void

    /// #095: the browser's detail-column selection; the matching row renders
    /// highlighted. `nil` highlights nothing.
    var selectedRowID: TaskRow.ID? = nil

    /// #098: the project this list belongs to, supplied ONLY for the single-project
    /// view. When non-nil (together with `onNewPlan`) the control bar gains the
    /// card header's "+" new-plan affordance plus trailing per-status count badges.
    /// `nil` for the cross-project smart-view list, which renders unchanged.
    var project: ProjectTasks? = nil

    /// #098: invoked with a project path when the single-project "+" is tapped, so
    /// the presenting window can raise the new-plan flow. `nil` (the smart-view
    /// case) hides the "+" entirely.
    var onNewPlan: ((String) -> Void)? = nil

    /// The shared store, read for the persisted sort/group selection.
    @Environment(PlansStore.self) private var store

    /// #098: the single-project type filter, view-local like a card's. `nil` is
    /// "All". Reset per project by the caller's `.id(projectPath)`.
    @State private var typeFilter: TaskType? = nil

    /// The rows after the single-project type filter (a no-op for smart views,
    /// which never show the filter).
    private var visibleRows: [TaskRow] {
        BrowserViewModel.filterRows(rows, matchingType: project == nil ? nil : typeFilter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let project {
                projectHeader(project)
                Divider()
            }
            controlBar
            Divider()
            if visibleRows.isEmpty {
                // Centered muted empty state, mirroring the grid's "No projects".
                Text(rows.isEmpty ? "No tasks" : "No matching tasks")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(sections, id: \.title) { entry in
                            sectionView(title: entry.title, rows: entry.rows)
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let project {
                Divider()
                ProjectFooter(project: project)
                    .padding(.horizontal, ProjectCard.rowColumns.cardHorizontalPadding)
                    .padding(.vertical, 8)
            }
        }
    }

    /// #098: single-project only — the card header's controls on their own row
    /// above sort/group, so the fixed-size count badges always have room: the
    /// "+" new-plan glyph leading, the type filter and status badges trailing.
    private func projectHeader(_ project: ProjectTasks) -> some View {
        HStack(spacing: 8) {
            if let onNewPlan {
                CaptureGlyph { onNewPlan(project.projectPath) }
            }
            Spacer(minLength: 8)
            TaskTypeFilterMenu(selection: $typeFilter)
            ProjectStatusBadges(project: project)
        }
        .padding(.horizontal, ProjectCard.rowColumns.cardHorizontalPadding)
        .padding(.vertical, 8)
    }

    /// The sort + group control bar: two `Menu`s mirroring the `ProjectViewMode`
    /// toolbar select — each names all options up front and renders the current
    /// choice as visible TEXT beside its symbol (`.titleAndIcon`).
    @ViewBuilder
    private var controlBar: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(TaskSort.allCases, id: \.rawValue) { sort in
                    Button {
                        store.taskSort = sort
                    } label: {
                        Label(sort.menuLabel, systemImage: sort.menuSymbol)
                    }
                }
            } label: {
                Label("Sort: \(store.taskSort.menuLabel)",
                      systemImage: store.taskSort.menuSymbol)
                    .labelStyle(.titleAndIcon)
            }
            .fixedSize()
            .help("Sort tasks")

            Menu {
                ForEach(TaskGroup.allCases, id: \.rawValue) { group in
                    Button {
                        store.taskGroup = group
                    } label: {
                        Label(group.menuLabel, systemImage: group.menuSymbol)
                    }
                }
            } label: {
                Label("Group: \(store.taskGroup.menuLabel)",
                      systemImage: store.taskGroup.menuSymbol)
                    .labelStyle(.titleAndIcon)
            }
            .fixedSize()
            .help("Group tasks")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, ProjectCard.rowColumns.cardHorizontalPadding)
        .padding(.vertical, 8)
    }

    /// The sorted rows grouped into titled sections for the current selection.
    private var sections: [(title: String, rows: [TaskRow])] {
        let sorted = BrowserViewModel.sortRows(visibleRows, by: store.taskSort)
        return BrowserViewModel.groupRows(sorted, by: store.taskGroup)
    }

    /// One titled section: its header label plus its `TaskListRow`s, each indexed
    /// from zero within the section so zebra parity is section-local.
    @ViewBuilder
    private func sectionView(title: String, rows: [TaskRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, ProjectCard.rowColumns.cardHorizontalPadding)

            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    TaskListRow(
                        row: row,
                        index: index,
                        showsProjectLabel: showsProjectLabel,
                        onOpenDetail: onOpenDetail,
                        isSelected: selectedRowID == row.id
                    )
                }
            }
        }
    }
}
