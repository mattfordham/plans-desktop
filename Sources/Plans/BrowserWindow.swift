import SwiftUI

/// Surface B/C: the cross-project dashboard window (§008). A project-centric
/// **card dashboard** with a collapsible plan-detail panel:
///
/// - **Content (primary, default = full-width):** a `ScrollView` + `LazyVGrid`
///   of `ProjectCard`s, one per registered project, recency-sorted
///   (`sortByStaleness`, most-recently-seen first). Each card shows the project
///   name, a per-status count summary, and its outstanding (non-completed) plan
///   rows. Tapping a plan row selects it. This is the DEFAULT view — pure cards,
///   no detail pane.
/// - **Detail (right, collapsed by default):** the selected plan's rendered body
///   — title, project + status line, and each `## ` section as markdown, with
///   the `## How` section as a read-only checklist (never interactive, §2). The
///   column is hidden until a plan is clicked, and a "Close" control returns to
///   the pure card view.
///
/// The "closed by default, opens on click, closable" behavior is achieved by
/// CONDITIONAL COMPOSITION rather than `NavigationSplitView`'s column-visibility
/// enum: a two-column split's visibility enum (`.doubleColumn` / `.detailOnly`)
/// cannot express "show only the content column," so it can't model a detail
/// pane that is fully hidden by default. Instead the layout is an `HStack` whose
/// detail column (an `HSplitView`-style divider + the detail renderer) is only
/// INSERTED when `selectedRowID != nil`, animated. When nothing is selected the
/// card grid is the sole, full-width view (the pure dashboard); clicking a plan
/// inserts the detail column; the Close control clears `selectedRowID` and
/// removes it again. See Assumptions for why.
///
/// The view ONLY reads from the injected `PlansStore` — it never writes,
/// creates, moves, or deletes any `.plans/` data (§2 read-only).
struct BrowserWindow: View {
    @Environment(PlansStore.self) private var store

    // MARK: - Layout constants (single source of truth for the grid math)

    /// The responsive minimum card width. The column count is derived by fitting
    /// as many `cardMinWidth`-wide columns (plus `gridSpacing` gutters) into the
    /// available content width as will fit. Low-confidence estimate (see §009
    /// Assumptions) to confirm at the observation step.
    static let cardMinWidth: CGFloat = 400

    /// The inter-column / inter-row spacing of the grid.
    static let gridSpacing: CGFloat = 16

    /// The padding around the grid content inside the scroll view.
    static let gridPadding: CGFloat = 16

    /// The id of the currently selected plan row across ALL projects' active
    /// rows, or `nil` when nothing is selected (the default: detail collapsed,
    /// pure card view).
    @State private var selectedRowID: TaskRow.ID?

    /// The measured available content width of the card grid's scroll viewport,
    /// fed by a `GeometryReader` width probe (see `cardGrid`). Drives the
    /// responsive column count. `0` until the first layout pass measures it.
    @State private var gridWidth: CGFloat = 0

    /// Pure width → column-count function: fits as many `cardMinWidth` columns
    /// (plus a `gridSpacing` gutter each) into the padded content width as will
    /// fit, with a floor of 1. No side effects and no view-state reads, so it is
    /// directly unit-testable (segment 2) without instantiating the view.
    static func columnCount(forWidth width: CGFloat) -> Int {
        max(1, Int((width - 2 * gridPadding) / (cardMinWidth + gridSpacing)))
    }

    /// The projects sorted by staleness (recency) for the card grid.
    private var sortedProjects: [ProjectTasks] {
        BrowserViewModel.sortByStaleness(store.projects)
    }

    /// The currently selected row resolved from `selectedRowID` by scanning
    /// EVERY project's active rows (not a single drilled-down project, which no
    /// longer exists). `nil` when nothing is selected or the prior selection
    /// closed/disappeared.
    private var selectedRow: TaskRow? {
        guard let id = selectedRowID else { return nil }
        return store.projects
            .flatMap { BrowserViewModel.activeRows($0) }
            .first { $0.id == id }
    }

    var body: some View {
        // The card grid is always present. When a plan is selected, the detail
        // pane is shown beside it in a user-resizable `HSplitView`; otherwise the
        // grid is the sole, full-width view (the default pure-dashboard state).
        //
        // The detail pane is kept as a single, stably-identified subview (the
        // `if` only toggles between the grid-only `HStack` and the split) so
        // switching from one plan to another does NOT tear down and rebuild the
        // detail column — only its content rebuilds, which keeps plan-switching
        // responsive instead of re-creating the whole pane each time.
        Group {
            if selectedRow != nil {
                HSplitView {
                    // The grid is the flexible side (grows/shrinks with the
                    // window and the divider). The detail pane carries a bounded
                    // min…max range plus a modest ideal, so the divider has real
                    // slack to drag (a maxWidth-less, greedy grid pane would pin
                    // the divider and make it un-draggable) and the pane opens at
                    // a sensible width rather than overly wide.
                    cardGrid
                        .frame(minWidth: 400, maxWidth: .infinity)
                    detail
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 520)
                }
            } else {
                cardGrid
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 480, minHeight: 520)
    }

    // MARK: - Content: the recency-sorted card grid (dashboard)

    /// The dashboard content column: a `ScrollView` + adaptive `LazyVGrid` of
    /// `ProjectCard`s over the recency-sorted projects. Wrapped in a
    /// `ScrollViewReader` and each card item tagged with `.id(projectPath)` so a
    /// menu-bar drill-down (segment 4) can scroll the grid to a target project.
    private var cardGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    // Responsive equal-flexible columns: the count is derived from
                    // the measured viewport width (`gridWidth`) via the pure
                    // `columnCount(forWidth:)` helper, so cards reflow 1→2→3→4… as
                    // the window/split divider resizes while still sharing width
                    // evenly. LazyVGrid sizes each cell to its ROW's max height, so
                    // each card is wrapped in a top-anchor VStack + trailing Spacer
                    // (see the ForEach below) to keep the card content-sized and
                    // pinned to the top of a taller cell rather than stretched.
                    // (`alignment:` here is HORIZONTAL only and stays at the
                    // default `.center`; cards fill their column via maxWidth so it
                    // has no visible effect.)
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: Self.gridSpacing),
                        count: BrowserWindow.columnCount(forWidth: gridWidth)
                    ),
                    spacing: Self.gridSpacing
                ) {
                    ForEach(sortedProjects, id: \.projectPath) { project in
                        // Top-anchor wrapper: LazyVGrid sizes every cell in a row
                        // to the row's max height, which would otherwise stretch a
                        // short card's background/border to fill the whole cell.
                        // Keeping the card content-sized and pairing it with a
                        // trailing `Spacer(minLength: 0)` lets the spacer absorb the
                        // extra cell height so the card's chrome hugs its content
                        // and pins to the TOP of the cell. ProjectCard's own frame
                        // intentionally sets NO maxHeight — adding one here would
                        // re-introduce the stretch. The `.id` stays on this wrapper
                        // so the ScrollViewReader drill-down still targets the cell.
                        VStack(spacing: 0) {
                            ProjectCard(project: project, selectedRowID: $selectedRowID)
                            Spacer(minLength: 0)
                        }
                        .id(project.projectPath)
                    }
                }
                .padding(Self.gridPadding)
            }
            // Width-probe approach (low-confidence layout choice, see §009
            // Assumptions): a zero-impact `GeometryReader` lives in the
            // ScrollView's `.background` so it measures the VIEWPORT width without
            // contributing to the scroll content's intrinsic height (avoiding the
            // greedy-GeometryReader-in-ScrollView zero-height/layout-loop trap).
            // Only the width is read and pushed into `gridWidth` via a preference
            // key; the column count is the sole derived value.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: GridWidthKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(GridWidthKey.self) { gridWidth = $0 }
            .overlay {
                if sortedProjects.isEmpty {
                    Text("No projects")
                        .foregroundStyle(.secondary)
                }
            }
            // §004 drill-down handoff: when the menu bar set a target project
            // (`store.selectedProjectPath`) before opening this window, anchor the
            // grid to that project's card. Pure scroll — never opens the detail
            // panel (`selectedRowID` stays nil) and never mutates `.plans/` (§2).
            .onAppear { scrollToSelectedProject(proxy) }
            .onChange(of: store.selectedProjectPath) { _, _ in
                scrollToSelectedProject(proxy)
            }
        }
    }

    /// Scrolls the card grid to `store.selectedProjectPath`'s card if it matches a
    /// live project. The card's `.id(projectPath)` is the scroll target. Does NOT
    /// touch `selectedRowID` (detail stays collapsed) and performs no writes. On
    /// `.onAppear` the grid may not have laid out yet, so the scroll is also
    /// dispatched to the next runloop tick to reliably anchor on first paint.
    private func scrollToSelectedProject(_ proxy: ScrollViewProxy) {
        guard let path = store.selectedProjectPath,
              store.projects.contains(where: { $0.projectPath == path }) else { return }
        proxy.scrollTo(path, anchor: .top)
        DispatchQueue.main.async {
            proxy.scrollTo(path, anchor: .top)
        }
    }

    // MARK: - Right: the selected task's rendered body

    /// The right pane: the selected task's title, a status line, and its `## `
    /// sections rendered as markdown (the `## How` section rendered as a read-
    /// only checklist). Shows a muted placeholder when nothing is selected.
    @ViewBuilder
    private var detail: some View {
        if let row = selectedRow {
            VStack(alignment: .leading, spacing: 0) {
                // The Close control: collapses the detail column back to the
                // pure card view by clearing the selection. Inline (not a
                // toolbar) since the detail isn't hosted in a NavigationStack.
                HStack {
                    Spacer()
                    Button {
                        selectedRowID = nil
                    } label: {
                        Label("Close", systemImage: "xmark")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                    .help("Close the plan detail")
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

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
            }
        } else {
            VStack {
                Text("Select a plan")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            }
            .font(.body)
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

/// Carries the card grid's measured viewport width up from a `GeometryReader`
/// width probe (in `cardGrid`'s `.background`) to `BrowserWindow.gridWidth`,
/// keeping the width read out of the scroll content's vertical layout so it
/// can't collapse the grid or trip a layout loop. Reduces by taking the latest
/// (max) reported width.
private struct GridWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
    /// The clickable plan rows for ONE project's card (Surface C dashboard).
    ///
    /// Maps the project's `activeTasks` (already non-completed, non-nil-status,
    /// and pre-sorted by status priority then id ascending by `TaskParser`) into
    /// `TaskRow`s carrying the owning project identity. This helper does NOT
    /// re-sort — it preserves `TaskParser`'s order — and performs no I/O or
    /// SwiftUI work.
    static func activeRows(_ project: ProjectTasks) -> [TaskRow] {
        project.activeTasks.map { task in
            TaskRow(
                projectPath: project.projectPath,
                projectName: project.projectName,
                task: task
            )
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
