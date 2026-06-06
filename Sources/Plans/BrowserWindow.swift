import SwiftUI

/// Surface B/C: the cross-project dashboard window (§008). A pure, full-width
/// **card dashboard**: a `ScrollView` + `LazyVGrid` of `ProjectCard`s, one per
/// registered project, recency-sorted (`sortByStaleness`, most-recently-seen
/// first). Each card shows the project name, a per-status count summary, and its
/// outstanding (non-completed) plan rows.
///
/// Tapping a plan row opens that plan's detail in a SEPARATE WINDOW (§011, via
/// `ProjectCard`'s `openWindow(id: "plan-detail", value:)`) rather than an
/// inline drawer — this window has no detail pane, no `HSplitView`, and holds no
/// selection state.
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

    /// The measured available content width of the card grid's scroll viewport,
    /// fed by a `GeometryReader` width probe (see `cardGrid`). Drives the
    /// responsive column count. `0` until the first layout pass measures it.
    @State private var gridWidth: CGFloat = 0

    /// #017: the project path of the card currently being hovered as a drop
    /// target during a card drag, or `nil` when nothing is targeted. Driven by
    /// each card's `.dropDestination(isTargeted:)` callback so the grid can paint
    /// an insertion indicator on the leading edge of the card the dragged item
    /// would land before, making the otherwise-invisible drop position visible.
    @State private var dropTargetPath: String? = nil

    /// Pure width → column-count function: fits as many `cardMinWidth` columns
    /// (plus a `gridSpacing` gutter each) into the padded content width as will
    /// fit, with a floor of 1. No side effects and no view-state reads, so it is
    /// directly unit-testable (segment 2) without instantiating the view.
    static func columnCount(forWidth width: CGFloat) -> Int {
        max(1, Int((width - 2 * gridPadding) / (cardMinWidth + gridSpacing)))
    }

    /// The projects in display order for the card grid. When the user's manual
    /// order is active and non-empty (#017), the grid honors that override
    /// (`applyManualOrder`, new project paths to the top); otherwise it falls
    /// back to the automatic recency sort (`sortByStaleness`) exactly as before.
    private var sortedProjects: [ProjectTasks] {
        if store.manualOrderActive && !store.projectOrderOverride.isEmpty {
            return BrowserViewModel.applyManualOrder(
                store.projects,
                order: store.projectOrderOverride
            )
        }
        return BrowserViewModel.sortByStaleness(store.projects)
    }

    var body: some View {
        // A pure, full-width card dashboard. Tapping a plan row opens that plan's
        // detail in a separate window (§011); this window has no detail pane.
        cardGrid
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
                            ProjectCard(project: project)
                            Spacer(minLength: 0)
                        }
                        .id(project.projectPath)
                        // #017 drop indicator: while a card is dragged over this
                        // cell, paint a vertical accent bar on its LEADING edge to
                        // show the dragged card will be inserted BEFORE this one —
                        // the same semantics `handleDrop`/`reorder` apply. Without
                        // this the drop position is invisible and dragging is hard
                        // to aim. The overlay is inside the drag/drop chrome but
                        // adds no layout (it's an `.overlay`), so the grid math is
                        // untouched.
                        .overlay(alignment: .leading) {
                            if dropTargetPath == project.projectPath {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.accentColor)
                                    .frame(width: 4)
                                    .padding(.vertical, 2)
                                    .transition(.opacity)
                            }
                        }
                        // #017: drag a card and drop it onto another card to
                        // override the order. The card carries its project path
                        // as the dragged payload; the drop target re-inserts the
                        // dragged path BEFORE this card via the pure `reorder`
                        // helper over the CURRENTLY displayed order, then persists
                        // through the store. View modifier stays thin — all order
                        // math lives in `BrowserViewModel`. `isTargeted` drives the
                        // `dropTargetPath` highlight above.
                        .draggable(project.projectPath)
                        .dropDestination(for: String.self) { items, _ in
                            dropTargetPath = nil
                            guard let sourcePath = items.first else { return false }
                            handleDrop(sourcePath: sourcePath, before: project.projectPath)
                            return true
                        } isTargeted: { targeted in
                            // Set on enter; clear only if WE are still the recorded
                            // target, so a neighbor's enter (which may arrive before
                            // our exit) isn't clobbered back to nil.
                            if targeted {
                                dropTargetPath = project.projectPath
                            } else if dropTargetPath == project.projectPath {
                                dropTargetPath = nil
                            }
                        }
                    }
                }
                .padding(Self.gridPadding)
            }
            // #017 step 4: a revert affordance lives in the window toolbar so the
            // user can leave the manual card order and return to the automatic
            // recency sort. The control is ALWAYS present (persistent toolbar) so
            // its placement doesn't shift as state changes; it is simply DISABLED
            // when no manual order is active (nothing to revert). Both icon and
            // title text are shown (`.titleAndIcon`) so the button is
            // self-explanatory. Tapping it calls `store.clearManualOrder()`, which
            // flips `manualOrderActive` off — `sortedProjects` already reacts to
            // the flag and the grid re-sorts by staleness. Pure store call; never
            // writes `.plans/` (§2).
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        store.clearManualOrder()
                    } label: {
                        Label(
                            BrowserViewModel.manualOrderRevertLabel,
                            systemImage: "arrow.uturn.backward"
                        )
                        .labelStyle(.titleAndIcon)
                    }
                    // Flat toolbar styling: the default bordered toolbar button
                    // renders the icon+title as a chunky padded pill. `.borderless`
                    // gives the standard flat macOS toolbar control (icon + text,
                    // natural spacing) that matches the window chrome.
                    .buttonStyle(.borderless)
                    .disabled(!store.manualOrderActive)
                    .help("Discard the manual card order and sort by recency.")
                }
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
            // grid to that project's card. Pure scroll — never mutates `.plans/` (§2).
            .onAppear { scrollToSelectedProject(proxy) }
            .onChange(of: store.selectedProjectPath) { _, _ in
                scrollToSelectedProject(proxy)
            }
        }
    }

    /// Resolves a drag-drop into a new persisted manual order (#017). Computes
    /// the new ordering by moving `sourcePath` immediately before `targetPath`
    /// over the CURRENTLY displayed order (`sortedProjects`' paths) via the pure
    /// `BrowserViewModel.reorder` helper, then activates + persists it through the
    /// store. The view modifier stays thin; all order math is in the helper. This
    /// only writes UserDefaults via the store — never `.plans/` (§2 read-only).
    private func handleDrop(sourcePath: String, before targetPath: String) {
        let current = sortedProjects.map(\.projectPath)
        let newOrder = BrowserViewModel.reorder(
            current,
            moving: sourcePath,
            before: targetPath
        )
        store.setManualOrder(newOrder)
    }

    /// Scrolls the card grid to `store.selectedProjectPath`'s card if it matches a
    /// live project. The card's `.id(projectPath)` is the scroll target. Performs
    /// no writes. On `.onAppear` the grid may not have laid out yet, so the scroll
    /// is also dispatched to the next runloop tick to reliably anchor on first paint.
    private func scrollToSelectedProject(_ proxy: ScrollViewProxy) {
        guard let path = store.selectedProjectPath,
              store.projects.contains(where: { $0.projectPath == path }) else { return }
        proxy.scrollTo(path, anchor: .top)
        DispatchQueue.main.async {
            proxy.scrollTo(path, anchor: .top)
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
    /// The label shown on the toolbar revert control while the manual card order
    /// is active (#017 step 4). Pure constant — kept here (rather than inline in
    /// the view) so the copy is unit-testable and lives alongside the other
    /// ordering vocabulary. Tapping the control reverts to the recency sort.
    static let manualOrderRevertLabel = "Sort by Recency"

    /// The clickable plan rows for ONE project's card (Surface C dashboard).
    ///
    /// Maps the project's `activeTasks` (already non-completed, non-nil-status,
    /// and pre-sorted by status priority then id ascending by `TaskParser`) into
    /// `TaskRow`s carrying the owning project identity. This helper does NOT
    /// re-sort — it preserves `TaskParser`'s order — and performs no I/O or
    /// SwiftUI work.
    /// Resolves a composite row id to its `TaskRow` by scanning EVERY project's
    /// active rows (the same cross-project lookup the browser window and the
    /// standalone plan-detail window both need). Flattens `activeRows` over all
    /// projects and returns the first row whose `id` matches; `nil` when no
    /// active row across any project matches (e.g. a completed/closed task or a
    /// project that disappeared). Pure value work — no I/O, no SwiftUI.
    static func resolveRow(in projects: [ProjectTasks], id: TaskRow.ID) -> TaskRow? {
        projects
            .flatMap { activeRows($0) }
            .first { $0.id == id }
    }

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

    /// Orders projects by the user's manual override (#017): an array of project
    /// paths giving the desired display order. Projects whose path is NOT listed
    /// in `order` are treated as new and sort to the TOP, preserving their
    /// original relative order; listed projects follow in `order`'s sequence.
    /// Stale entries in `order` (paths with no matching project) are ignored.
    /// Pure value work — no I/O, no SwiftUI, never mutates `.plans/`.
    static func applyManualOrder(
        _ projects: [ProjectTasks],
        order: [String]
    ) -> [ProjectTasks] {
        // Rank each path by its index in `order`; unlisted paths get no rank.
        let rank = Dictionary(
            order.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        // New (unranked) projects lead; ranked projects follow by their rank.
        // Enumerate for a stable secondary key preserving original order within
        // each group.
        return projects.enumerated().sorted { lhs, rhs in
            let lRank = rank[lhs.element.projectPath]
            let rRank = rank[rhs.element.projectPath]
            switch (lRank, rRank) {
            case let (l?, r?):
                if l != r { return l < r }
                return lhs.offset < rhs.offset
            case (.none, .some):
                return true   // new (unranked) sorts to the top
            case (.some, .none):
                return false
            case (.none, .none):
                return lhs.offset < rhs.offset
            }
        }
        .map(\.element)
    }

    /// Computes the new manual order after a drag-drop: removes `sourcePath` from
    /// `current` and re-inserts it immediately BEFORE `targetPath`. A `nil`
    /// `targetPath` (dropped past the last card) appends the source to the END.
    /// No-ops when the source is absent or equals the target. Pure value work —
    /// no I/O, no SwiftUI.
    static func reorder(
        _ current: [String],
        moving sourcePath: String,
        before targetPath: String?
    ) -> [String] {
        guard sourcePath != targetPath,
              current.contains(sourcePath) else { return current }

        var result = current.filter { $0 != sourcePath }
        if let target = targetPath,
           let targetIndex = result.firstIndex(of: target) {
            result.insert(sourcePath, at: targetIndex)
        } else {
            result.append(sourcePath)
        }
        return result
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
