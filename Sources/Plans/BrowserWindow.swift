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

    /// The measured available content height of the card grid's scroll viewport
    /// (#033), fed by the same `GeometryReader` probe that measures the width.
    /// Drives the content-driven, viewport-filling row heights in fit-to-screen
    /// mode (#039) so the rows stretch/shrink to fill the screen. `0` until the
    /// first layout pass measures it (fit mode then falls back to the cards'
    /// natural row heights via `fitRowHeights` returning them unchanged).
    @State private var gridHeight: CGFloat = 0

    /// #039: each card's NATURAL (content-hugging) height, keyed by project path,
    /// measured by a zero-impact `GeometryReader` in each rendered cell's
    /// `.background` (so reading the height can't feed back into the cell's own
    /// layout). Fit-to-screen mode groups these into per-row max heights and then
    /// stretches/shrinks the rows to fill the viewport via `fitRowHeights`. Cards
    /// not yet measured fall back to `fitRowMinHeight` so first paint is reasonable.
    /// Empty in scroll mode (the measurement only runs on the fit path).
    @State private var cardNaturalHeights: [String: CGFloat] = [:]

    /// #017: the project path of the card currently being hovered as a drop
    /// target during a card drag, or `nil` when nothing is targeted. Driven by
    /// each card's `.dropDestination(isTargeted:)` callback so the grid can paint
    /// an insertion indicator on the leading edge of the card the dragged item
    /// would land before, making the otherwise-invisible drop position visible.
    @State private var dropTargetPath: String? = nil

    /// #031: the in-flight request to open the shared "New Plan" modal,
    /// pre-selected to a project. `nil` keeps the sheet closed; setting it (from
    /// the global toolbar button or a card's "+" glyph) presents the sheet.
    /// Wrapped in an `Identifiable` request (a bare `String?` isn't
    /// `Identifiable`) so `.sheet(item:)` drives presentation and a fresh `id`
    /// re-presents even for the same project path.
    @State private var newPlanRequest: NewPlanRequest? = nil

    /// Pure width → column-count function: fits as many `cardMinWidth` columns
    /// (plus a `gridSpacing` gutter each) into the padded content width as will
    /// fit, with a floor of 1. No side effects and no view-state reads, so it is
    /// directly unit-testable (segment 2) without instantiating the view.
    static func columnCount(forWidth width: CGFloat) -> Int {
        max(1, Int((width - 2 * gridPadding) / (cardMinWidth + gridSpacing)))
    }

    /// Resolves the EFFECTIVE card layout for a given column count (#033). Fit-to-
    /// screen only makes sense with two or more columns: at a single column (a
    /// narrow window) cards are already full-width and stacking them with stretched
    /// heights would just produce one tall card per screen, so we fall back to
    /// `.scroll` and let the content scroll normally. With 2+ columns the requested
    /// `mode` is honored verbatim. Pure (no view-state reads) so it is directly
    /// unit-testable without instantiating the view.
    static func effectiveLayoutMode(_ mode: CardLayoutMode, columnCount: Int) -> CardLayoutMode {
        columnCount <= 1 ? .scroll : mode
    }

    /// Content-driven, viewport-filling per-row heights for fit-to-screen mode
    /// (#039). Given each row's NATURAL height (the tallest card in that row, as
    /// measured) in display order, returns the FINAL height for each row so that:
    ///
    /// - **Stretch (content fits):** when the rows' natural total plus the chrome
    ///   (`2*padding` + inter-row `spacing` gutters) is at most the measured
    ///   `viewportHeight`, every row is scaled up by a single factor so the rows
    ///   together exactly fill the available height — no empty gap at the bottom —
    ///   while keeping their RELATIVE proportions (a light row stays shorter than a
    ///   heavy one).
    /// - **Shrink (content overflows):** when the natural total overflows, rows are
    ///   scaled DOWN by the same kind of single factor toward fitting, but never
    ///   below `minRowHeight`. If even all rows at the floor still overflow, every
    ///   row is left at the floor and the remaining overflow is left to the
    ///   surrounding `ScrollView` (the "only scroll once even the minimum overflows"
    ///   case).
    ///
    /// Returns the natural heights UNCHANGED when `viewportHeight <= 0` (not yet
    /// measured — a sensible first-paint fallback) or when there are no rows. The
    /// clamp-to-floor case re-distributes the leftover budget across the still-
    /// shrinkable rows so the result fills the viewport whenever it can.
    ///
    /// Pure and total (no view-state reads), so it is directly unit-testable.
    static func fitRowHeights(
        naturalRowHeights: [CGFloat],
        viewportHeight: CGFloat,
        spacing: CGFloat,
        padding: CGFloat,
        minRowHeight: CGFloat
    ) -> [CGFloat] {
        guard !naturalRowHeights.isEmpty, viewportHeight > 0 else {
            return naturalRowHeights
        }

        let rowCount = naturalRowHeights.count
        let chrome = 2 * padding + CGFloat(rowCount - 1) * spacing
        let availableForRows = viewportHeight - chrome
        let naturalTotal = naturalRowHeights.reduce(0, +)

        // Degenerate viewport (chrome alone exceeds it) or zero natural content:
        // fall back to the floor per row, letting the ScrollView absorb overflow.
        guard availableForRows > 0, naturalTotal > 0 else {
            return naturalRowHeights.map { _ in minRowHeight }
        }

        // If even all rows at the floor can't fit, clamp every row to the floor and
        // let the ScrollView scroll — there's no slack to distribute.
        if CGFloat(rowCount) * minRowHeight >= availableForRows {
            return naturalRowHeights.map { _ in minRowHeight }
        }

        // Stretch (factor > 1) or shrink (factor < 1) every row by one factor so the
        // rows together fill the available height, preserving relative proportions.
        let factor = availableForRows / naturalTotal
        var heights = naturalRowHeights.map { $0 * factor }

        // Enforce the per-row floor. Any row pinned UP to the floor steals budget
        // from the rest, so re-scale the still-shrinkable rows to reclaim the
        // leftover and keep the total filling the viewport.
        if heights.contains(where: { $0 < minRowHeight }) {
            heights = distributeWithFloor(
                naturalRowHeights: naturalRowHeights,
                availableForRows: availableForRows,
                minRowHeight: minRowHeight
            )
        }
        return heights
    }

    /// Resolves the per-row heights when one or more rows would fall below
    /// `minRowHeight`: pins those rows to the floor and re-scales the remaining
    /// (above-floor) rows to absorb the leftover budget, iterating until the set of
    /// floored rows is stable. Used only on the shrink path of `fitRowHeights`.
    /// Pure helper; the caller has already established that NOT every row needs the
    /// floor (so there is always at least one shrinkable row to re-scale).
    private static func distributeWithFloor(
        naturalRowHeights: [CGFloat],
        availableForRows: CGFloat,
        minRowHeight: CGFloat
    ) -> [CGFloat] {
        let count = naturalRowHeights.count
        var floored = Array(repeating: false, count: count)

        while true {
            // Budget left for the not-yet-floored rows after reserving the floor for
            // the floored ones.
            let flooredCount = floored.filter { $0 }.count
            let remainingBudget = availableForRows - CGFloat(flooredCount) * minRowHeight
            // Natural total of the rows still free to scale.
            let freeNaturalTotal = zip(naturalRowHeights, floored)
                .filter { !$0.1 }
                .reduce(0) { $0 + $1.0 }

            // No free rows left, or no budget for them: everything is at the floor.
            guard freeNaturalTotal > 0, remainingBudget > 0 else {
                return Array(repeating: minRowHeight, count: count)
            }

            let factor = remainingBudget / freeNaturalTotal
            // Find a free row that the factor would push below the floor; pin it and
            // recompute. If none, the factor is final.
            if let idx = (0..<count).first(where: { !floored[$0] && naturalRowHeights[$0] * factor < minRowHeight }) {
                floored[idx] = true
                continue
            }

            return (0..<count).map { i in
                floored[i] ? minRowHeight : naturalRowHeights[i] * factor
            }
        }
    }

    /// The minimum per-row height in fit-to-screen mode (#033/#039). Below this a
    /// card can't show its header + a plan row legibly, so the grid never shrinks a
    /// row below it; once even all rows at this floor overflow the viewport, the
    /// ScrollView (kept in place) absorbs the overflow. Also the per-row default
    /// used for unmeasured cards before the measurement pass reports their heights.
    static let fitRowMinHeight: CGFloat = 160

    /// Distributes `count` card indices across `columns` columns for the variable-
    /// height (masonry) scroll layout (#039). Returns one inner array per column
    /// (outer length == the effective column count), each listing the ordered
    /// card indices assigned to that column. Index `i` lands in column `i %
    /// columns`, so a left-to-right read across the columns' heads still yields
    /// reading order (top-to-bottom, left-to-right). `columns <= 0` is floored to
    /// 1 (defensive — the grid floors columns at 1 anyway); `count <= 0` yields an
    /// empty result (no columns). Pure (no view-state reads) so it is directly
    /// unit-testable without instantiating the view.
    static func columnAssignments(count: Int, columns: Int) -> [[Int]] {
        guard count > 0 else { return [] }
        let cols = max(1, columns)
        var result = Array(repeating: [Int](), count: cols)
        for i in 0..<count {
            result[i % cols].append(i)
        }
        return result
    }

    /// The projects in display order for the card grid. When the user's manual
    /// order is active and non-empty (#017), the grid honors that override
    /// (`applyManualOrder`, new project paths to the top); otherwise it falls
    /// back to the automatic recency sort (`sortByStaleness`) exactly as before.
    ///
    /// After the order is resolved, the "Hide Empty" toolbar toggle (#021) is
    /// applied: when `store.hideEmptyProjects` is true the result is filtered to
    /// projects with outstanding work (`hasOutstandingWork`), preserving order.
    /// `store.projects` is never mutated — only this derived view is filtered.
    private var sortedProjects: [ProjectTasks] {
        let sorted: [ProjectTasks]
        if store.manualOrderActive && !store.projectOrderOverride.isEmpty {
            sorted = BrowserViewModel.applyManualOrder(
                store.projects,
                order: store.projectOrderOverride
            )
        } else {
            sorted = BrowserViewModel.sortByStaleness(store.projects)
        }
        return store.hideEmptyProjects ? sorted.filter(\.hasOutstandingWork) : sorted
    }

    var body: some View {
        // A pure, full-width card dashboard. Tapping a plan row opens that plan's
        // detail in a separate window (§011); this window has no detail pane.
        cardGrid
            .frame(minWidth: 480, minHeight: 520)
            // #031: the shared "New Plan" modal, presented over the whole window.
            // Driven by `newPlanRequest` (set by the global toolbar button below
            // or a card's "+" glyph via the `onNewPlan` closure passed into each
            // `ProjectCard`). `.sheet(item:)` so a fresh request id re-presents
            // even for the same project path.
            .sheet(item: $newPlanRequest) { request in
                NewPlanModal(initialProjectPath: request.projectPath)
            }
            // #034: the app-wide ⌘N command (in `PlansApp`) can't reach this
            // window's `@State`, so it bumps `store.newPlanTrigger` and we open
            // the modal here — opening it IDENTICALLY to the toolbar button.
            .onChange(of: store.newPlanTrigger) { _, _ in
                openNewPlanForRecentProject()
            }
            .toolbar {
                // #031: open the shared "New Plan" modal pre-selected to the
                // most-recently-touched project (newest `lastSeen`, ignoring any
                // manual grid reorder). Disabled when there are no projects to
                // capture against. Per-card "+" glyphs open the same modal
                // pre-selected to their own project.
                ToolbarItem {
                    Button {
                        openNewPlanForRecentProject()
                    } label: {
                        Label("New Plan", systemImage: "square.and.pencil")
                    }
                    .help("Capture a new plan")
                    .disabled(store.projects.isEmpty)
                }
                ToolbarItem {
                    Button {
                        // Same shared pick → link → report flow used by the menu
                        // bar's "Link Project…" button (§018). A folder without a
                        // `.plans/` directory surfaces the identical modal alert.
                        linkProjectWithUserPrompt(using: store)
                    } label: {
                        Label("Link Project…", systemImage: "plus")
                    }
                    .help("Link a plans-cc project folder")
                }
                // #021: hide projects with no outstanding plans. A persistent
                // toolbar toggle bound to `store.hideEmptyProjects`; flipping it
                // re-derives `sortedProjects` (the filter lives there) so the grid
                // reflows. Pure store/UserDefaults state — never writes `.plans/`.
                ToolbarItem {
                    // A plain `Button` (not a button-styled `Toggle`) so this
                    // control shares the IDENTICAL toolbar chrome as the "+"
                    // button beside it — same square hover/active footprint and
                    // no persistent background box (the `.toggleStyle(.button)`
                    // pill made the two look inconsistent). The on/off state is
                    // conveyed by the glyph itself: `eye.slash` (accent-tinted)
                    // while empty projects are hidden, plain `eye` when shown.
                    Button {
                        store.hideEmptyProjects.toggle()
                    } label: {
                        Label(
                            "Hide Empty",
                            systemImage: store.hideEmptyProjects ? "eye.slash" : "eye"
                        )
                    }
                    .foregroundStyle(store.hideEmptyProjects ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .help("Hide projects with no outstanding plans")
                }
                // #033: card-layout toggle. Mirrors the "Hide Empty" chrome
                // exactly — a plain `Button` (not a button-styled `Toggle`) so it
                // shares the IDENTICAL square toolbar footprint. The glyph/label
                // come from `CardLayoutMode`; the control is accent-tinted while
                // fit-to-screen is the active mode.
                ToolbarItem {
                    Button {
                        store.cardLayoutMode = store.cardLayoutMode.toggled
                    } label: {
                        Label(
                            store.cardLayoutMode.label,
                            systemImage: store.cardLayoutMode.symbolName
                        )
                    }
                    .foregroundStyle(store.cardLayoutMode == .fit ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .help("Toggle between scrolling and fit-to-screen card layout")
                }
            }
    }

    // MARK: - Content: the recency-sorted card grid (dashboard)

    /// The dashboard content column: a `ScrollView` + adaptive `LazyVGrid` of
    /// `ProjectCard`s over the recency-sorted projects. Wrapped in a
    /// `ScrollViewReader` and each card item tagged with `.id(projectPath)` so a
    /// menu-bar drill-down (segment 4) can scroll the grid to a target project.
    /// Opens the shared "New Plan" modal pre-selected to the most-recently-touched
    /// project (the newest `lastSeen` via the staleness sort), or does nothing when
    /// there are no projects (#031). This deliberately keys off recency and ignores
    /// any active manual grid reorder (#017) — the general "New Plan" entry point
    /// always defaults to the project the user most recently worked in, not whatever
    /// card happens to sit at the top of a manually reordered grid. Shared by the
    /// toolbar "New Plan" button and the app-wide ⌘N command (#034, via
    /// `newPlanTrigger`) so both open the modal identically.
    private func openNewPlanForRecentProject() {
        if let first = BrowserViewModel.sortByStaleness(store.projects).first {
            newPlanRequest = NewPlanRequest(projectPath: first.projectPath)
        }
    }

    private var cardGrid: some View {
        // #033: fit-to-screen reuses the SAME width-driven column breakpoints as
        // scroll (1→2→3→4…) — the two modes only differ in vertical sizing. The
        // column count is computed once here so the grid, the effective-mode
        // decision, and the per-row height all agree on it.
        let columns = BrowserWindow.columnCount(forWidth: gridWidth)
        // At a single column fit-to-screen collapses to scroll (see
        // `effectiveLayoutMode`); otherwise the user's choice stands.
        let effectiveMode = BrowserWindow.effectiveLayoutMode(
            store.cardLayoutMode, columnCount: columns
        )
        return ScrollViewReader { proxy in
            ScrollView {
                // #039: fit-to-screen mode renders CONTENT-DRIVEN, viewport-filling
                // variable-height rows (`fitCardGrid`): each row is as tall as its
                // tallest card's natural height, then all rows are stretched (or
                // shrunk toward a floor) to fill the viewport so a light row stays
                // short and a heavy row stays tall while the grid still fills the
                // screen. Scroll mode keeps the masonry `variableCardGrid` so short
                // cards leave no gap below them. Both share the same width-driven
                // `columns` count and the same per-card chrome via `cardCell(for:)`.
                if effectiveMode == .fit {
                    fitCardGrid(columns: columns)
                } else {
                    variableCardGrid(columns: columns)
                }
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
                        // #033: the same probe reports the viewport HEIGHT, feeding
                        // the fit-to-screen per-row height. Lives in `.background`
                        // (not the scroll content) so reading it can't grow or loop
                        // the scroll content's own height.
                        .preference(key: GridHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(GridWidthKey.self) { gridWidth = $0 }
            .onPreferenceChange(GridHeightKey.self) { gridHeight = $0 }
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

    /// The fit-to-screen card grid (#039): an explicit `VStack` of `HStack` ROWS
    /// (a `LazyVGrid` can't give per-row heights), each `columns` cards wide in
    /// reading order. Each row is sized to a CONTENT-DRIVEN height — the tallest
    /// card's measured natural height for that row, then stretched up (when content
    /// fits) or shrunk toward `fitRowMinHeight` (when it overflows) by
    /// `fitRowHeights` so the rows together fill the viewport. A light row stays
    /// short and a heavy row stays tall while the grid still fills the screen; once
    /// even the floor overflows, the surrounding `ScrollView` absorbs the rest.
    ///
    /// Lazy-ness is unnecessary here: by definition fit mode keeps content on (or
    /// near) one screen. Cards report their natural heights via the hidden
    /// `measurementLayer` (in `.background`); until a card is measured it
    /// contributes `fitRowMinHeight` so first paint (before the measurement pass
    /// lands) is reasonable. Each visible cell shares the same `cardCell` chrome
    /// (`.id`, drop indicator, drag/drop, "+").
    private func fitCardGrid(columns: Int) -> some View {
        let rows = Self.rowIndices(count: sortedProjects.count, columns: columns)
        let naturalRowHeights = rows.map { row in
            // The row's natural height is its TALLEST card's measured height; an
            // as-yet-unmeasured card contributes the floor so the row isn't degenerate.
            row.map { cardNaturalHeights[sortedProjects[$0].projectPath] ?? Self.fitRowMinHeight }
                .max() ?? Self.fitRowMinHeight
        }
        let finalHeights = Self.fitRowHeights(
            naturalRowHeights: naturalRowHeights,
            viewportHeight: gridHeight,
            spacing: Self.gridSpacing,
            padding: Self.gridPadding,
            minRowHeight: Self.fitRowMinHeight
        )
        return VStack(spacing: Self.gridSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(alignment: .top, spacing: Self.gridSpacing) {
                    ForEach(row, id: \.self) { idx in
                        cardCell(for: sortedProjects[idx])
                            // Share the row's width evenly; the card stretches to the
                            // row height via its internal Spacer.
                            .frame(maxWidth: .infinity)
                    }
                    // Pad a short final row so its cards keep the full-grid column
                    // width instead of stretching to fill the leftover columns.
                    if row.count < columns {
                        ForEach(0..<(columns - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: finalHeights[rowIndex])
            }
        }
        .padding(Self.gridPadding)
        // #039: a hidden, parallel layout of the SAME cards at their NATURAL height
        // (no row-height frame), at the identical column widths, measuring each
        // card's content height into `cardNaturalHeights`. It lives in `.background`
        // at zero opacity / no hit-testing so it contributes nothing visible and
        // doesn't enter the visible grid's own height — measuring the visible cells
        // directly would feed their STRETCHED height back in and never settle.
        .background(measurementLayer(rows: rows, columns: columns))
        .onPreferenceChange(CardHeightKey.self) { heights in
            // Merge so a card that scrolled out (and stopped reporting) keeps its
            // last measurement; only update when a value actually changed to avoid
            // redundant state churn.
            for (path, height) in heights where cardNaturalHeights[path] != height {
                cardNaturalHeights[path] = height
            }
        }
    }

    /// The hidden measurement pass for the fit grid (#039): mirrors the visible
    /// VStack-of-HStacks row layout (same `columns`, same even column widths) but
    /// renders each card via a bare `ProjectCard` at its NATURAL content height —
    /// NO row-height frame — reporting each card's measured height keyed by project
    /// path through `CardHeightKey`. Hidden (zero opacity, not hit-testable) so it
    /// adds nothing visible and, crucially, doesn't participate in the visible
    /// grid's height the way measuring the stretched cells directly would (which
    /// would loop). A bare `ProjectCard` (not `cardCell`) is enough — only the
    /// content height matters here, not the `.id`/drag/drop chrome.
    private func measurementLayer(rows: [[Int]], columns: Int) -> some View {
        VStack(spacing: Self.gridSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: Self.gridSpacing) {
                    ForEach(row, id: \.self) { idx in
                        let project = sortedProjects[idx]
                        ProjectCard(project: project) { _ in }
                            .frame(maxWidth: .infinity)
                            // `.fixedSize(vertical:)` pins the card to its NATURAL
                            // (ideal) content height regardless of the height the
                            // background context proposes — its internal Spacer
                            // collapses to 0 — so the GeometryReader reports the
                            // content height rather than a stretched one (otherwise
                            // the proposed grid height would feed back and loop).
                            .fixedSize(horizontal: false, vertical: true)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: CardHeightKey.self,
                                        value: [project.projectPath: geo.size.height]
                                    )
                                }
                            )
                    }
                    if row.count < columns {
                        ForEach(0..<(columns - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .padding(Self.gridPadding)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Groups `count` card indices into rows of `columns` each, in reading order
    /// (row r = indices `r*columns ..< min((r+1)*columns, count)`). Returns an
    /// empty array for an empty grid or a non-positive column count. Pure helper
    /// feeding the fit grid's per-row layout and natural-height grouping.
    static func rowIndices(count: Int, columns: Int) -> [[Int]] {
        guard count > 0, columns > 0 else { return [] }
        var rows: [[Int]] = []
        var start = 0
        while start < count {
            let end = min(start + columns, count)
            rows.append(Array(start..<end))
            start = end
        }
        return rows
    }

    /// The variable-height (masonry) card grid for scroll mode (#039): N column
    /// `LazyVStack`s side-by-side in an `HStack(alignment: .top)`, each rendering
    /// the cards the pure `columnAssignments` helper assigned to it at their
    /// NATURAL content height — no trailing Spacer and no fixed `.frame(height:)`.
    /// This removes the gap a `LazyVGrid` left below a short card (which forced
    /// every cell in a row to the row's max height). The index-modulo assignment
    /// keeps the grid reading left-to-right, top-to-bottom. Each card uses the same
    /// `cardCell(for:)` chrome (`.id`, drop indicator, drag/drop reorder, "+"
    /// glyph) as the fit path, so #017 reorder and #004 drill-down still work.
    private func variableCardGrid(columns: Int) -> some View {
        let assignments = BrowserWindow.columnAssignments(
            count: sortedProjects.count,
            columns: columns
        )
        return HStack(alignment: .top, spacing: Self.gridSpacing) {
            ForEach(0..<assignments.count, id: \.self) { col in
                LazyVStack(spacing: Self.gridSpacing) {
                    ForEach(assignments[col], id: \.self) { idx in
                        let project = sortedProjects[idx]
                        cardCell(for: project)
                    }
                }
                // Each column shares the available width evenly and tops-aligns its
                // stack so a shorter column doesn't get stretched vertically.
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(Self.gridPadding)
    }

    /// The shared per-card chrome used by BOTH the fit (`fitCardGrid`) and the
    /// variable-height scroll (`variableCardGrid`) paths: the `ProjectCard` plus
    /// the menu-bar drill-down `.id` (#004), the #017 leading drop-indicator
    /// overlay, and the #017 drag/drop reorder modifiers, with the card's "+" glyph
    /// wired to the shared "New Plan" modal pre-selected to THIS project (#031). It
    /// applies NO height frame and NO trailing Spacer — the fit path wraps it in a
    /// fixed-height frame, while the scroll path lets it size to its content.
    @ViewBuilder
    private func cardCell(for project: ProjectTasks) -> some View {
        // #031: the card's "+" glyph opens the shared modal pre-selected to THIS
        // card's project via this closure (a fresh `NewPlanRequest` id so
        // `.sheet(item:)` fires).
        ProjectCard(project: project) { path in
            newPlanRequest = NewPlanRequest(projectPath: path)
        }
        // #004 drill-down target: the ScrollViewReader scrolls to this id.
        .id(project.projectPath)
        // #017 drop indicator: while a card is dragged over this cell, paint a
        // vertical accent bar on its LEADING edge to show the dragged card will be
        // inserted BEFORE this one. The overlay adds no layout so the grid math is
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
        // #017: drag a card and drop it onto another card to override the order.
        // The card carries its project path as the dragged payload; the drop target
        // re-inserts the dragged path BEFORE this card via the pure `reorder` helper
        // over the CURRENTLY displayed order, then persists through the store.
        // `isTargeted` drives the `dropTargetPath` highlight above.
        .draggable(project.projectPath)
        .dropDestination(for: String.self) { items, _ in
            dropTargetPath = nil
            guard let sourcePath = items.first else { return false }
            handleDrop(sourcePath: sourcePath, before: project.projectPath)
            return true
        } isTargeted: { targeted in
            // Set on enter; clear only if WE are still the recorded target, so a
            // neighbor's enter (which may arrive before our exit) isn't clobbered
            // back to nil.
            if targeted {
                dropTargetPath = project.projectPath
            } else if dropTargetPath == project.projectPath {
                dropTargetPath = nil
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

/// #031: an `Identifiable` wrapper around a target project path so the "New
/// Plan" modal can be driven by `.sheet(item:)` (a bare `String?` isn't
/// `Identifiable`). A fresh `id` per request means re-tapping the same project's
/// "+" re-presents the sheet rather than being deduplicated.
private struct NewPlanRequest: Identifiable {
    let id = UUID()
    let projectPath: String
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

/// Carries the card grid's measured viewport HEIGHT up from the same
/// `GeometryReader` probe (#033), driving the fit-to-screen row heights in
/// `BrowserWindow.fitRowHeights`. Mirrors `GridWidthKey`: read in `.background`
/// so the height measurement never feeds back into the scroll content's own
/// vertical layout. Reduces by taking the latest (max) reported height.
private struct GridHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// #039: carries each card's measured NATURAL height up from the fit grid's
/// hidden measurement layer (`measurementLayer`) to
/// `BrowserWindow.cardNaturalHeights`, keyed by project path. Each card reports a
/// single-entry `[path: height]` dictionary from a `GeometryReader` in its
/// `.background`; the reduce MERGES the per-path entries across all cards so the
/// window receives the full path→height map in one preference change. Newer
/// entries win on a key collision (the same path measured twice in a pass).
private struct CardHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
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
