import SwiftUI

/// Surface B: the cross-project browser window (§1). A 3-pane
/// `NavigationSplitView`:
///
/// - **Left (sidebar):** a global status filter (All + the outstanding §5.4
///   statuses; `completed` is omitted entirely) plus the project list sorted by
///   staleness (`lastSeen` descending, unparseable/absent last). Selecting a
///   project scopes the middle list to it; "All projects" returns to
///   cross-project.
/// - **Middle:** the flattened, filtered task list — outstanding tasks across
///   ALL live projects (or scoped to the drilled-down project), filtered to the
///   selected status (or all). Completed tasks never appear. Each row shows a
///   colored type-badge dot, the task id, and the title.
/// - **Right:** the selected task's rendered body — title, status line, and each
///   `## ` section as markdown, with the `## How` section as a read-only
///   checklist (never interactive, §2).
///
/// The view ONLY reads from the injected `PlansStore` — it never writes,
/// creates, moves, or deletes any `.plans/` data (§2 read-only).
struct BrowserWindow: View {
    @Environment(PlansStore.self) private var store

    /// The selected global status filter. `nil` means "All" (no status scope).
    @State private var selectedStatus: TaskStatus?

    /// The selected project's path, or `nil` for cross-project ("All projects").
    /// Pre-seeded from `store.selectedProjectPath` on appear so a menu-bar
    /// drill-down lands on that project.
    @State private var selectedProjectPath: String?

    /// The id of the currently selected task row in the middle list, or `nil`
    /// when nothing is selected (the right pane shows the placeholder).
    @State private var selectedRowID: TaskRow.ID?

    /// The projects sorted by staleness for the sidebar list.
    private var sortedProjects: [ProjectTasks] {
        BrowserViewModel.sortByStaleness(store.projects)
    }

    /// The flattened, filtered rows for the middle pane. Cross-project unless a
    /// project is selected (drill-down); status-scoped unless "All". Order is
    /// the store's registry order (NOT the staleness sort) so the task list is
    /// deterministic and independent of the sidebar ordering.
    private var visibleRows: [TaskRow] {
        BrowserViewModel.visibleTasks(
            projects: store.projects,
            status: selectedStatus,
            projectPath: selectedProjectPath
        )
    }

    /// The currently selected row resolved from `selectedRowID` against the
    /// current `visibleRows`. `nil` when nothing is selected or the prior
    /// selection fell out of the filtered set.
    private var selectedRow: TaskRow? {
        guard let id = selectedRowID else { return nil }
        return visibleRows.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            taskList
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear {
            // Honor the §004 drill-down handoff: if the menu bar pre-selected a
            // project, land on it. Only adopt it when it matches a live project
            // so a stale selection doesn't leave the sidebar pointing at nothing.
            if let path = store.selectedProjectPath,
               store.projects.contains(where: { $0.projectPath == path }) {
                selectedProjectPath = path
            }
        }
    }

    // MARK: - Left: status filter + project list

    private var sidebar: some View {
        List {
            Section("Status") {
                // "All" clears the status scope.
                Button {
                    selectedStatus = nil
                } label: {
                    statusRow(label: "All", isSelected: selectedStatus == nil)
                }
                .buttonStyle(.plain)

                // The outstanding statuses only. `completed` is omitted entirely
                // from the browser (it surfaces neither in the filter nor the
                // task list), so we iterate `glanceOrder` (which excludes it).
                // Each row shows the same status glyph + color as the task rows.
                ForEach(TaskStatus.glanceOrder, id: \.self) { status in
                    Button {
                        selectedStatus = status
                    } label: {
                        statusRow(
                            label: status.filterLabel,
                            glyph: status.glanceGlyph,
                            color: status.glanceColor,
                            isSelected: selectedStatus == status
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Projects") {
                // "All projects" clears the project scope (cross-project view).
                Button {
                    selectedProjectPath = nil
                } label: {
                    statusRow(
                        label: "All projects",
                        isSelected: selectedProjectPath == nil
                    )
                }
                .buttonStyle(.plain)

                ForEach(sortedProjects, id: \.projectPath) { project in
                    Button {
                        selectedProjectPath = project.projectPath
                    } label: {
                        statusRow(
                            label: project.projectName,
                            isSelected: selectedProjectPath == project.projectPath
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Plans")
    }

    /// A single sidebar row: an optional status glyph in its status color, a
    /// label, and a checkmark when selected. A fixed-width glyph slot keeps the
    /// labels left-aligned whether or not a glyph is present (e.g. "All").
    private func statusRow(
        label: String,
        glyph: String? = nil,
        color: Color? = nil,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(glyph ?? " ")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(color ?? .secondary)
                .frame(width: 12, alignment: .center)
            Text(label)
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Middle: the flattened, filtered task list

    /// The middle pane: a `List(selection:)` over the cross-project (or drilled-
    /// down) filtered rows. Each row shows the §6 type badge, the task id, and
    /// the title. Selection drives the right detail pane.
    private var taskList: some View {
        List(visibleRows, selection: $selectedRowID) { row in
            taskRow(row)
        }
        .navigationTitle("Tasks")
        .overlay {
            if visibleRows.isEmpty {
                Text("No tasks")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A single task row: the status glyph in the status color (matching the
    /// plans-cc TUI dashboard), the short task id (the 3-char `task.id`, NOT the
    /// composite row id/path), an optional `[type]` tag, and the title (falling
    /// back to "(untitled)").
    private func taskRow(_ row: TaskRow) -> some View {
        let indicator = row.indicator
        return HStack(spacing: 8) {
            Text(indicator.glyph)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(indicator.color)
                .frame(width: 12, alignment: .center)
            Text(row.task.id)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            if let type = row.type {
                Text("[\(type.label)]")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(row.title ?? "(untitled)")
                .lineLimit(1)
        }
        .tag(row.id)
    }

    // MARK: - Right: the selected task's rendered body

    /// The right pane: the selected task's title, a status line, and its `## `
    /// sections rendered as markdown (the `## How` section rendered as a read-
    /// only checklist). Shows a muted placeholder when nothing is selected.
    @ViewBuilder
    private var detail: some View {
        if let row = selectedRow {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader(row)
                    ForEach(Array(row.task.sections.enumerated()), id: \.offset) { _, section in
                        sectionView(section)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .textSelection(.enabled)
        } else {
            VStack {
                Text("Select a task")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The detail header: the title as a prominent heading plus a status line
    /// (the type badge and the status's `filterLabel` when present).
    private func detailHeader(_ row: TaskRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title ?? "(untitled)")
                .font(.title)
                .fontWeight(.semibold)

            HStack(spacing: 6) {
                // The status glyph + color (blocked takes precedence), matching
                // the task rows and the sidebar filter.
                let indicator = row.indicator
                Text(indicator.glyph)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(indicator.color)
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
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    /// Renders one `## ` section: its heading, then its body. The `## How`
    /// section is rendered specially as a read-only checklist; all others render
    /// their body as markdown paragraphs.
    @ViewBuilder
    private func sectionView(_ section: TaskSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.heading)
                .font(.headline)

            if section.heading == "How" {
                howChecklist(section.body)
            } else {
                markdownBody(section.body)
            }
        }
    }

    /// Renders a section body as markdown, one paragraph at a time. The body is
    /// split on blank lines; each paragraph is parsed with
    /// `AttributedString(markdown:)`, falling back to plain `Text` when parsing
    /// fails or yields nil. Performs no writes — purely presentational.
    @ViewBuilder
    private func markdownBody(_ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(BrowserViewModel.paragraphs(body).enumerated()), id: \.offset) { _, paragraph in
                markdownParagraph(paragraph)
            }
        }
    }

    /// Renders a single paragraph as markdown, tolerating parse failures by
    /// falling back to plain text. Uses an options value that does not throw on
    /// the default markdown grammar; the whole parse is wrapped in `try?`.
    private func markdownParagraph(_ paragraph: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: paragraph, options: options) {
            return Text(attributed)
        }
        return Text(paragraph)
    }

    /// Renders the `## How` body as a READ-ONLY checklist. Lines matching
    /// `- [ ]` / `- [x]` / `- [X]` become a `Label` with `square` /
    /// `checkmark.square`; the checkbox prefix is stripped from the step text.
    /// These are never interactive (§2): no `Toggle`, no `Button`, no binding,
    /// no writes.
    @ViewBuilder
    private func howChecklist(_ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(BrowserViewModel.howSteps(body).enumerated()), id: \.offset) { _, step in
                Label(step.text, systemImage: step.done ? "checkmark.square" : "square")
            }
        }
    }
}

/// A single renderable task row in the middle pane. Carries the owning project
/// identity plus the underlying `Task` so the detail pane can render its body.
///
/// `Task` is not `Identifiable`, and the same task id can occur in different
/// projects, so identity is a composite of `projectPath + "/" + task.id`. This
/// wrapper supplies the `Identifiable` conformance locally (the model stays
/// unchanged).
struct TaskRow: Identifiable {
    /// The owning project's root path.
    let projectPath: String
    /// The owning project's display name.
    let projectName: String
    /// The underlying parsed task.
    let task: Task

    /// Composite stable id: `projectPath + "/" + task.id`. Unique even when the
    /// same task id appears across multiple projects.
    var id: String { projectPath + "/" + task.id }

    /// Convenience passthroughs for the row UI.
    var type: TaskType? { task.type }
    var title: String? { task.title }

    /// The status glyph + color for this task, matching the plans-cc TUI
    /// dashboard (blocked takes precedence over status).
    var indicator: TaskStatusIndicator {
        TaskStatusIndicator(status: task.status, isBlocked: task.isBlocked)
    }
}

/// Pure, SwiftUI-free view-model helpers for the browser so the filter/sort
/// logic is unit-testable as plain values (segment 2 tests these directly).
/// This namespace performs NO I/O and never mutates `.plans/` data.
enum BrowserViewModel {
    /// Flattens tasks across `projects` into renderable rows, applying the
    /// global status filter and optional project drill-down.
    ///
    /// - `projectPath` non-nil scopes to only that project's tasks (drill-down).
    /// - `status` non-nil keeps only tasks whose `status` matches; tasks with a
    ///   `nil` status are excluded while a status filter is active and included
    ///   only under "All" (`status == nil`).
    /// - `completed` tasks are ALWAYS excluded — the browser omits finished work
    ///   entirely (matching the menu-bar glance), so even "All" never shows them.
    /// - Both filters nil → every outstanding task from every project.
    ///
    /// Order is deterministic: `projects` in their given (registry) order — this
    /// helper does NOT re-sort — and within each project the existing `tasks`
    /// order. Performs no I/O and touches no SwiftUI.
    static func visibleTasks(
        projects: [ProjectTasks],
        status: TaskStatus?,
        projectPath: String?
    ) -> [TaskRow] {
        projects
            .filter { projectPath == nil || $0.projectPath == projectPath }
            .flatMap { project in
                project.tasks
                    .filter { $0.status != .completed }
                    .filter { status == nil || $0.status == status }
                    .map { task in
                        TaskRow(
                            projectPath: project.projectPath,
                            projectName: project.projectName,
                            task: task
                        )
                    }
            }
    }

    /// Splits a section body into paragraphs on blank lines for per-paragraph
    /// markdown rendering. Consecutive blank lines collapse to one separator;
    /// leading/trailing blank lines are dropped. Each paragraph keeps its
    /// internal newlines verbatim. Empty input yields no paragraphs.
    static func paragraphs(_ body: String) -> [String] {
        var result: [String] = []
        var current: [String] = []

        func flush() {
            guard !current.isEmpty else { return }
            result.append(current.joined(separator: "\n"))
            current = []
        }

        for line in body.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                current.append(line)
            }
        }
        flush()

        return result
    }

    /// A single read-only `## How` checklist step: the display text (checkbox
    /// prefix stripped) and whether it is marked done.
    struct HowStep: Equatable {
        let text: String
        let done: Bool
    }

    /// Parses `## How` body lines into read-only checklist steps, mirroring
    /// `TaskParser.howProgress`: `- [ ]` is not-done, `- [x]` / `- [X]` is done.
    /// Leading whitespace is tolerated; the `- [ ] ` / `- [x] ` prefix is
    /// stripped from the returned text. Non-checkbox lines are ignored. Performs
    /// no I/O — pure string work.
    static func howSteps(_ body: String) -> [HowStep] {
        var steps: [HowStep] = []
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- [ ]") {
                steps.append(HowStep(text: stripCheckboxPrefix(line), done: false))
            } else if line.hasPrefix("- [x]") || line.hasPrefix("- [X]") {
                steps.append(HowStep(text: stripCheckboxPrefix(line), done: true))
            }
        }
        return steps
    }

    /// Strips the leading `- [ ]` / `- [x]` / `- [X]` marker (and a following
    /// space) from a checklist line, returning the trimmed step text.
    private static func stripCheckboxPrefix(_ line: String) -> String {
        let withoutMarker = String(line.dropFirst(5)) // "- [ ]" / "- [x]"
        return withoutMarker.trimmingCharacters(in: .whitespaces)
    }

    /// Orders projects by staleness for the sidebar: most-recently-seen first
    /// (`lastSeen` ISO-8601 timestamp, descending). Entries whose `lastSeen` is
    /// absent or unparseable sort LAST, in a stable order preserving their
    /// original relative position.
    ///
    /// The ISO→`Date` parse happens here (not in `TaskParser`, which stays
    /// Foundation-only over raw strings). Parse failures map to "no date" and
    /// fall to the end.
    static func sortByStaleness(_ projects: [ProjectTasks]) -> [ProjectTasks] {
        // Enumerate to keep a stable secondary key for equal/unparseable dates.
        projects.enumerated().sorted { lhs, rhs in
            let lDate = parseLastSeen(lhs.element.lastSeen)
            let rDate = parseLastSeen(rhs.element.lastSeen)

            switch (lDate, rDate) {
            case let (l?, r?):
                if l != r { return l > r }
                return lhs.offset < rhs.offset
            case (.some, .none):
                return true   // parseable date sorts before unparseable
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.offset < rhs.offset
            }
        }
        .map(\.element)
    }

    /// Parses a raw registry `lastSeen` string into a `Date`, tolerating both
    /// fractional-seconds and plain ISO-8601 forms. Returns `nil` for empty or
    /// unrecognized input.
    static func parseLastSeen(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: trimmed) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }
}
