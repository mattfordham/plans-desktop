import SwiftUI

/// Surface B/C: the cross-project dashboard window (§008). A pure, full-width
/// **card dashboard**: a `ScrollView` + `LazyVGrid` of `ProjectCard`s, one per
/// registered project, recency-sorted (`sortByStaleness`, most-recently-seen
/// first). Each card shows the project name, a per-status count summary, and its
/// outstanding (non-completed) plan rows.
///
/// Tapping a plan row opens that plan's detail as an IN-WINDOW MODAL OVERLAY
/// PANE (#073, via `ProjectCard`'s `onOpenDetail` closure setting `detailRowID`)
/// rather than an inline drawer or a separate window — the dashboard keeps no
/// `HSplitView` and no selection state; `detailRowID` is the sole presentation
/// state. The pane dismisses by clicking the scrim or pressing Esc. This
/// replaces the former standalone per-plan detail window (§011), whose scene has
/// been removed from `PlansApp`.
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

    /// Extra trailing inset (#046) added on top of `gridPadding` so the rightmost
    /// cards — and their per-row action buttons (`RowActionGlyph`) — clear the
    /// macOS overlay scroller, which floats over the trailing edge of the scroll
    /// content and would otherwise sit on top of those buttons. ~15pt is the
    /// nominal overlay-scroller width. Shared with `ProjectCard`'s inner fit-mode
    /// scroll view so both scrollers clear the same chrome.
    static let scrollerClearance: CGFloat = 15

    /// The measured available content width of the card grid's scroll viewport,
    /// fed by a `GeometryReader` width probe (see `cardGrid`). Drives the
    /// responsive column count. `0` until the first layout pass measures it.
    @State private var gridWidth: CGFloat = 0

    /// The measured available content height of the card grid's scroll viewport
    /// (#033), fed by the same `GeometryReader` probe that measures the width.
    /// Drives the uniform, viewport-filling row heights in fit-to-screen mode
    /// (#057, `evenRowHeights`) so the rows divide the screen evenly. `0` until the
    /// first layout pass measures it (fit mode then falls back to one
    /// `fitRowMinHeight` per row for a sensible first paint).
    @State private var gridHeight: CGFloat = 0

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

    /// #073: the plan whose detail is shown as an in-window modal overlay pane,
    /// keyed on the tapped row's composite `TaskRow.ID`, or `nil` when no pane is
    /// open. Set by a card row tap (threaded in via `ProjectCard`'s `onOpenDetail`
    /// closure) and cleared by a click on the dimming scrim behind the pane.
    /// UI-only, transient presentation state — deliberately NOT persisted to
    /// UserDefaults, mirroring `newPlanRequest`.
    @State private var detailRowID: TaskRow.ID? = nil

    /// Pure width → column-count function: fits as many `cardMinWidth` columns
    /// (plus a `gridSpacing` gutter each) into the padded content width as will
    /// fit, with a floor of 1. No side effects and no view-state reads, so it is
    /// directly unit-testable (segment 2) without instantiating the view.
    static func columnCount(forWidth width: CGFloat) -> Int {
        max(1, Int((width - 2 * gridPadding) / (cardMinWidth + gridSpacing)))
    }

    /// The width-driven column count CLAMPED by how many cards are actually being
    /// rendered, so the grid never lays out more columns than it has cards to put
    /// in them. Without the clamp a grid showing fewer cards than the viewport can
    /// fit strands them at `cardMinWidth` against a run of empty columns — most
    /// visibly under focus mode (#067), where collapsing to a single project left
    /// one 400pt card in a 4-column window with three columns of dead space.
    ///
    /// The clamp only ever NARROWS the count: with more cards than the width can
    /// fit, the width-driven value stands and cards keep their `cardMinWidth`
    /// floor. The `max(1, …)` floor is preserved for an empty grid so the row math
    /// never divides by zero. Pure, so it is directly unit-testable.
    static func columnCount(forWidth width: CGFloat, cardCount: Int) -> Int {
        max(1, min(columnCount(forWidth: width), cardCount))
    }

    /// Whether the grid is in the FULL-HEIGHT focused single-card case (#071):
    /// focus mode (#067) has collapsed the grid to exactly one rendered card, so
    /// that lone card should stretch to fill the entire viewport height (rather
    /// than sitting at its natural content height in the ordinary scroll/masonry
    /// path). True only when a project is focused (`focusedProjectPath` non-nil)
    /// AND exactly one card is being rendered; false for no focus, or any card
    /// count other than one. Pure (no view-state reads) so it is directly
    /// unit-testable without instantiating the view.
    static func isFocusedSingleCard(focusedProjectPath: String?, cardCount: Int) -> Bool {
        focusedProjectPath != nil && cardCount == 1
    }

    /// The concrete height a focused single card must be GIVEN (#071). `ProjectCard`
    /// uses `constrainedHeight` only as a boolean signal to switch to its internal
    /// scrolling layout — it deliberately applies no frame of its own (see the
    /// "card's frame sets NO maxHeight" note there) — so the caller has to impose
    /// the height, exactly as `fitCardGrid` does with `.frame(height:)` per row.
    /// A `maxHeight: .infinity` inside the grid's `ScrollView` is NOT enough: scroll
    /// content is sized to its natural height, so the card would keep hugging its
    /// content and strand dead space below it.
    ///
    /// Wraps `evenRowHeights(rowCount: 1, …)` — the viewport minus the outer padding
    /// (a single row has no inter-row gutter) — and returns a non-optional so there
    /// is always a height to apply: before the viewport is measured, and on a
    /// viewport too short for the floor, it clamps to `fitRowMinHeight` and lets the
    /// surrounding ScrollView absorb the overflow (the clamp-to-floor contract).
    static func focusedCardHeight(viewportHeight: CGFloat) -> CGFloat {
        evenRowHeights(
            rowCount: 1,
            viewportHeight: viewportHeight,
            spacing: gridSpacing,
            padding: gridPadding,
            minRowHeight: fitRowMinHeight
        ).first ?? fitRowMinHeight
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

    /// Uniform, viewport-filling per-row heights for fit-to-screen mode (#057):
    /// every row gets the SAME height — the viewport divided evenly across the
    /// rows — DELIBERATELY IGNORING per-row natural content heights. The result is
    /// uniform regardless of which cards land in which row.
    ///
    /// Chrome is `2 * padding + (rowCount - 1) * spacing`. Clamp-to-floor overflow
    /// contract: when the even share would fall below `minRowHeight`, every row is
    /// pinned to the floor and the leftover overflow is left to the surrounding
    /// `ScrollView`.
    ///
    /// Returns `[]` when there are no rows, and `minRowHeight` for every row when
    /// `viewportHeight <= 0` (not yet measured — a sensible first-paint fallback).
    ///
    /// Pure and total (no view-state reads), so it is directly unit-testable.
    static func evenRowHeights(
        rowCount: Int,
        viewportHeight: CGFloat,
        spacing: CGFloat,
        padding: CGFloat,
        minRowHeight: CGFloat
    ) -> [CGFloat] {
        guard rowCount > 0 else { return [] }
        guard viewportHeight > 0 else {
            return Array(repeating: minRowHeight, count: rowCount)
        }
        let chrome = 2 * padding + CGFloat(rowCount - 1) * spacing
        let share = (viewportHeight - chrome) / CGFloat(rowCount)
        // Content overflows: pin every row to the floor and let the ScrollView
        // absorb the rest (the clamp-to-floor overflow contract).
        guard share >= minRowHeight else {
            return Array(repeating: minRowHeight, count: rowCount)
        }
        return Array(repeating: share, count: rowCount)
    }

    /// The minimum per-row height in fit-to-screen mode (#033/#057). Below this a
    /// card can't show its header + a plan row legibly, so the grid never shrinks a
    /// row below it; once even all rows at this floor overflow the viewport, the
    /// ScrollView (kept in place) absorbs the overflow. Also the per-row fallback
    /// `evenRowHeights` returns before the viewport height is measured.
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
    /// After the order is resolved, the "view mode" toolbar control (#072) is
    /// applied: `store.projectViewMode` filters the result to everything
    /// (`.all`), to projects with outstanding work (`.active`), or to starred
    /// projects (`.starred`) via `visibleUnderViewMode`, preserving order.
    /// `store.projects` is never mutated — only this derived view is filtered.
    ///
    /// Finally, "Focus" mode (#067) collapses the result to the single focused
    /// project's card. The focus is resolved defensively: a `focusedProjectPath`
    /// naming a project that is no longer live is treated as no focus at all, so
    /// unlinking/losing the focused project restores the full grid instead of
    /// leaving it stuck on an empty view.
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
        // #072: the single labelled view mode — `.all`, `.active` or `.starred`.
        let modeResolved = sorted.filter {
            BrowserViewModel.visibleUnderViewMode(
                $0,
                mode: store.projectViewMode,
                starredProjectPaths: store.starredProjectPaths
            )
        }
        // Auto-clear a stale focus: only honor the focused path when some live
        // project actually carries it, otherwise fall back to showing everything.
        return modeResolved.filter {
            BrowserViewModel.visibleUnderFocus($0, focusedProjectPath: effectiveFocusPath)
        }
    }

    /// The focused project path, resolved DEFENSIVELY: a `focusedProjectPath`
    /// naming a project that is no longer live (unregistered, deleted) is treated
    /// as no focus at all, so a stale value can never strand the grid on an empty
    /// focus or leave the exit-focus control stranded on screen. Single source of
    /// truth for "is a live project actually focused" — used by `sortedProjects`,
    /// the full-height single-card branch (#071), and the toolbar's exit control.
    private var effectiveFocusPath: String? {
        store.focusedProjectPath.flatMap { path in
            store.projects.contains { $0.projectPath == path } ? path : nil
        }
    }

    var body: some View {
        // A pure, full-width card dashboard. Tapping a plan row opens that plan's
        // detail as a modal overlay pane over this window (#073, `detailOverlay`).
        cardGrid
            .frame(minWidth: 480, minHeight: 520)
            // #031: the shared "New Plan" modal, presented over the whole window.
            // Driven by `newPlanRequest` (set by the global toolbar button below
            // or a card's "+" glyph via the `onNewPlan` closure passed into each
            // `ProjectCard`). `.sheet(item:)` so a fresh request id re-presents
            // even for the same project path.
            .sheet(item: $newPlanRequest) { request in
                // #064: niling the `item:` binding is the AUTHORITATIVE dismissal
                // for `.sheet(item:)` — the sheet stays presented until this
                // becomes `nil`. Rather than relying on `@Environment(\.dismiss)`
                // writing the binding back (which left the request set after a
                // Capture/Cancel, so the next open restored the stale draft), the
                // modal calls this `onClose` to nil the request itself.
                NewPlanModal(initialProjectPath: request.projectPath) {
                    newPlanRequest = nil
                }
            }
            // #073: the plan-detail modal overlay pane. Replaces the standalone
            // per-plan detail WINDOW: tapping a card row sets `detailRowID`, which
            // presents `PlanDetailView` here as a dimmed in-window overlay instead
            // of opening a separate window. Rendered inside an `.overlay` so it
            // floats over the whole card grid without affecting its layout.
            .overlay {
                if detailRowID != nil {
                    detailOverlay
                }
            }
            // Animate the pane in/out with the presentation-state change so both
            // the scrim and the pane fade/scale together.
            .animation(.easeInOut(duration: 0.18), value: detailRowID)
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
                // #072: the project view mode — ONE labelled control replacing
                // the unlabeled "Hide Empty" eye toggle (and the star's old role
                // as a mere exception to it). Setting `store.projectViewMode`
                // re-derives `sortedProjects` (the filter lives there) so the grid
                // reflows. Pure store/UserDefaults state — never writes `.plans/`.
                ToolbarItem {
                    // A `Menu` rather than a cycling button: with THREE named
                    // states, a click-to-cycle control makes the user step through
                    // modes they didn't want to reach the one they did, and can't
                    // show what the other options even are. The menu names all
                    // three up front and jumps straight to one.
                    //
                    // Crucially the menu's own label renders the current mode's
                    // `label` as visible TEXT beside its symbol — the entire point
                    // of this redesign was that three adjacent unlabeled glyphs
                    // were unreadable at a glance. Accent-tinted while a filter is
                    // actually narrowing the grid (i.e. any mode but `.all`).
                    Menu {
                        ForEach(ProjectViewMode.allCases, id: \.rawValue) { mode in
                            Button {
                                store.projectViewMode = mode
                            } label: {
                                Label(mode.label, systemImage: mode.symbolName)
                            }
                        }
                    } label: {
                        Label(
                            store.projectViewMode.label,
                            systemImage: store.projectViewMode.symbolName
                        )
                        .labelStyle(.titleAndIcon)
                    }
                    .foregroundStyle(
                        store.projectViewMode == .all
                            ? AnyShapeStyle(.primary)
                            : AnyShapeStyle(.tint)
                    )
                    .help("Show all projects, only active ones, or only starred ones")
                }
                // #033: card-layout toggle. A plain `Button` (not a button-styled
                // `Toggle`) so it shares the IDENTICAL square toolbar footprint as
                // the "+" button and the reveal control. The glyph/label
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

    // MARK: - Plan-detail modal overlay pane (#073)

    /// #073: the in-window plan-detail overlay — a dimming scrim behind a large
    /// rounded card holding `PlanDetailView`. Replaces the standalone detail
    /// window (§011). Presented over the whole card grid via `body`'s `.overlay`
    /// whenever `detailRowID != nil`.
    ///
    /// "Blur closes it": the SCRIM alone carries the click-away `onTapGesture`
    /// that clears `detailRowID`. The pane sits ABOVE the scrim with its own
    /// opaque background + `.contentShape(Rectangle())` so taps inside it are
    /// absorbed by the pane and never fall through to the scrim (a tap inside the
    /// pane must NOT dismiss). The pane carries a `.scale + .opacity` transition so
    /// it grows/fades in with the `body`-level `.animation(value: detailRowID)`.
    private var detailOverlay: some View {
        ZStack {
            // The dimming scrim: click-away dismissal lives HERE only.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { detailRowID = nil }
                .transition(.opacity)

            // The detail pane: an opaque rounded card, clamped to the window with
            // generous padding so it never fills the whole surface, sized toward
            // the removed scene's 900×600 intent but bounded by the window.
            PlanDetailView(rowID: detailRowID)
                .frame(maxWidth: 900, maxHeight: 600)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.separator, lineWidth: 1)
                )
                .shadow(radius: 30)
                // Absorb taps so clicks inside the pane never reach the scrim
                // behind it (only the scrim dismisses).
                .contentShape(Rectangle())
                .padding(40)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        // #073: keyboard dismissal — Esc closes the pane, matching the
        // scrim's click-away. Per the task's Assumptions the pane is scrim +
        // Esc only (no always-visible Close button). Attached on the whole
        // overlay (scrim + pane) so it is active for the full time the pane is
        // shown. A bare `detailRowID = nil` suffices: `body`'s
        // `.animation(value: detailRowID)` already animates the dismissal.
        .onExitCommand { detailRowID = nil }
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
        // #064: only SET the binding when the helper hands back a fresh request.
        // When it returns `nil` because a request is already active (the sheet is
        // open), we deliberately leave `newPlanRequest` UNTOUCHED — assigning the
        // `nil` back would close the open sheet instead of no-op'ing. So both the
        // toolbar button and the ⌘N `.onChange` are true no-ops mid-capture.
        if let request = BrowserWindow.shouldOpenNewPlan(
            currentRequest: newPlanRequest,
            sortedProjects: BrowserViewModel.sortByStaleness(store.projects)
        ) {
            newPlanRequest = request
        }
    }

    /// The pure open-decision for the shared "New Plan" sheet (#064). Given the
    /// CURRENTLY-active request and the already-staleness-sorted projects, returns
    /// the FRESH request to present, or `nil` when the sheet should not (re-)open:
    ///
    /// - `currentRequest != nil` → `nil`. This is the re-entrancy guard: a second
    ///   ⌘N (or toolbar tap) while the sheet is open must NOT mint a fresh request
    ///   — a new `id` would re-present the sheet and re-seed the fields, wiping
    ///   whatever draft the user is mid-way through. The caller treats `nil` as
    ///   "leave the current binding alone" (see `openNewPlanForRecentProject`), so
    ///   the open sheet is untouched.
    /// - no projects → `nil` (nothing to capture against; keeps the sheet closed).
    /// - idle + projects present → a FRESH `NewPlanRequest` for the first (most-
    ///   recently-touched) project. The caller passes the staleness-sorted list so
    ///   this stays pure and testable without the store.
    static func shouldOpenNewPlan(
        currentRequest: NewPlanRequest?,
        sortedProjects: [ProjectTasks]
    ) -> NewPlanRequest? {
        guard currentRequest == nil else { return nil }
        guard let first = sortedProjects.first else { return nil }
        return NewPlanRequest(projectPath: first.projectPath)
    }

    private var cardGrid: some View {
        // #033: fit-to-screen reuses the SAME width-driven column breakpoints as
        // scroll (1→2→3→4…) — the two modes only differ in vertical sizing. The
        // column count is computed once here so the grid, the effective-mode
        // decision, and the per-row height all agree on it.
        // #067: clamp by the number of cards actually being rendered so a grid
        // with fewer cards than the viewport can fit widens them to fill it
        // instead of stranding them beside empty columns — the focused
        // single-card case being the one that made this visible.
        let columns = BrowserWindow.columnCount(
            forWidth: gridWidth, cardCount: sortedProjects.count
        )
        // At a single column fit-to-screen collapses to scroll (see
        // `effectiveLayoutMode`); otherwise the user's choice stands.
        let effectiveMode = BrowserWindow.effectiveLayoutMode(
            store.cardLayoutMode, columnCount: columns
        )
        // #071: resolve the effective focus the SAME defensive way `sortedProjects`
        // does — a `focusedProjectPath` naming a project that is no longer live is
        // treated as no focus at all — so the full-height branch only fires when a
        // live project is actually focused.
        // #071: whether the grid has collapsed to a single focused card, which gets
        // a dedicated full-viewport-height render path (`focusCardGrid`).
        let focusedSingleCard = BrowserWindow.isFocusedSingleCard(
            focusedProjectPath: effectiveFocusPath, cardCount: sortedProjects.count
        )
        return ScrollViewReader { proxy in
            ScrollView {
                // #039/#057: fit-to-screen mode renders UNIFORM-HEIGHT rows
                // (`fitCardGrid` via `evenRowHeights`): the viewport is split evenly
                // across the rows so every row is the SAME height regardless of its
                // cards' natural content, and an over-full card clips/scrolls
                // internally (#038) rather than stretching its row. Scroll mode keeps
                // the masonry `variableCardGrid` so short cards leave no gap below
                // them. Both share the same width-driven `columns` count and the same
                // per-card chrome via `cardCell(for:)`.
                // #071: a single focused card stretches to fill the whole viewport
                // height via its dedicated path; otherwise the normal fit/scroll
                // dispatch stands unchanged. The outer ScrollView (+ .basedOnSize
                // bounce) is kept in every case so an over-tall focused card scrolls
                // internally without empty overscroll bounce.
                if focusedSingleCard {
                    focusCardGrid()
                } else if effectiveMode == .fit {
                    fitCardGrid(columns: columns)
                } else {
                    variableCardGrid(columns: columns)
                }
            }
            // #045: stop the empty overscroll bounce when the grid fits the window
            // (fit mode); a genuinely overflowing grid (clamp-to-floor / scroll mode)
            // still scrolls normally.
            .scrollBounceBehavior(.basedOnSize)
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
                // #067: exit "Focus" mode. Rendered ONLY while a live project is
                // actually focused — it is the way out of a single-card view, so
                // outside focus mode it has nothing to do and would just cost
                // permanent toolbar width (it previously sat there always-present
                // but disabled). Gated on `effectiveFocusPath`, not the raw stored
                // path, so a focus naming a project that is no longer live cannot
                // strand a dead control on screen. Tapping it clears
                // `store.focusedProjectPath` so `sortedProjects` re-derives to the
                // full grid. Pure store call; never writes `.plans/` (§2).
                if effectiveFocusPath != nil {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            store.clearFocus()
                        } label: {
                            Label("Show All Projects", systemImage: "rectangle.3.group")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                        .help("Exit focus mode and show every project.")
                    }
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

    /// The fit-to-screen card grid (#039/#057): an explicit `VStack` of `HStack`
    /// ROWS (a `LazyVGrid` can't give per-row heights), each `columns` cards wide in
    /// reading order. Fit mode gives every row the SAME height — the viewport
    /// divided evenly across the rows via `evenRowHeights`, IGNORING per-row natural
    /// content heights — so the rows always split the screen evenly regardless of
    /// which cards land where. Once even all rows at `fitRowMinHeight` overflow the
    /// viewport the rows clamp to the floor and the surrounding `ScrollView` absorbs
    /// the overflow.
    ///
    /// Lazy-ness is unnecessary here: by definition fit mode keeps content on (or
    /// near) one screen. Before the viewport height is measured, `evenRowHeights`
    /// falls back to `fitRowMinHeight` per row so first paint is reasonable. Each
    /// visible cell shares the same `cardCell` chrome (`.id`, drop indicator,
    /// drag/drop, "+").
    private func fitCardGrid(columns: Int) -> some View {
        // #040: snapshot `sortedProjects` ONCE so every index below indexes the
        // SAME array the row indices were computed from. `sortedProjects` is a
        // computed property whose length SHRINKS when the view-mode filter
        // changes mid-render; the `ForEach` closures re-evaluate lazily, so without
        // a stable snapshot a stale index would trap ("Index out of range").
        let projects = sortedProjects
        let rows = Self.rowIndices(count: projects.count, columns: columns)
        // #057: fit mode gives every row the SAME height — the viewport divided
        // evenly across the rows via `evenRowHeights` — ignoring per-row natural
        // content heights entirely. Clamps to `fitRowMinHeight` and lets the
        // surrounding `ScrollView` absorb any overflow once even the floors don't fit.
        let finalHeights = Self.evenRowHeights(
            rowCount: rows.count,
            viewportHeight: gridHeight,
            spacing: Self.gridSpacing,
            padding: Self.gridPadding,
            minRowHeight: Self.fitRowMinHeight
        )
        return VStack(spacing: Self.gridSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(alignment: .top, spacing: Self.gridSpacing) {
                    ForEach(row, id: \.self) { idx in
                        // #040: skip a stale index left over from a mid-render
                        // shrink of `sortedProjects` (see the snapshot note above);
                        // indexing `projects[idx]` unguarded would trap here.
                        if idx < projects.count {
                            // #038: hand the card the SAME fixed height the row frame
                            // below imposes (`finalHeights[rowIndex]`) so an over-full
                            // card scrolls its plan list internally and is clipped to its
                            // bounds instead of overflowing the cell into its neighbour.
                            cardCell(for: projects[idx], constrainedHeight: finalHeights[rowIndex])
                                // Share the row's width evenly; the card stretches to the
                                // row height via its internal Spacer.
                                .frame(maxWidth: .infinity)
                        }
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
        // #046: extra trailing inset so the rightmost cards' action buttons clear
        // the macOS overlay scroller. Applied on top of the symmetric gridPadding
        // so only the trailing edge gains the extra space.
        .padding(.trailing, Self.scrollerClearance)
    }

    /// The full-height focused single-card grid (#071): when focus mode (#067) has
    /// collapsed the grid to exactly one project's card, render that card stretched
    /// to fill the whole viewport height instead of sitting at its natural content
    /// height with dead space below. Reuses `evenRowHeights(rowCount: 1, …)` — the
    /// same viewport-filling math the fit grid uses for a single row — as the card's
    /// `constrainedHeight`, so an over-tall card scrolls its plan list internally
    /// (#038) and the surrounding `ScrollView` absorbs any overflow (mirrors the fit
    /// grid's clamp-to-floor contract). Before the viewport height is measured,
    /// `evenRowHeights` falls back to `fitRowMinHeight` for a sensible first paint.
    ///
    /// Padding matches `fitCardGrid`/`variableCardGrid` (symmetric `gridPadding`
    /// plus the trailing `scrollerClearance` so the card's action buttons clear the
    /// overlay scroller). The container fills width AND height, top-aligned, so the
    /// card anchors to the top when it does overflow.
    private func focusCardGrid() -> some View {
        // #040: snapshot `sortedProjects` ONCE (see `fitCardGrid`) so the guard and
        // the render read the SAME array — the computed property can shrink mid-
        // render (e.g. the focus auto-clears when its project disappears), and an
        // unguarded first-element read would trap on an emptied snapshot.
        let projects = sortedProjects
        // #071: the single full-viewport-height value a focused card should occupy.
        // `rowCount: 1` yields one height == the viewport minus its outer padding
        // (no inter-row gutter), clamped to `fitRowMinHeight` and letting the
        // ScrollView absorb any overflow.
        let constrainedHeight = Self.focusedCardHeight(viewportHeight: gridHeight)
        return VStack(spacing: 0) {
            // Guard for the single element: if the snapshot is unexpectedly empty
            // (focus resolved away mid-render), render nothing gracefully.
            if let project = projects.first {
                // Hand the card the SAME height the frame below imposes, exactly as
                // `fitCardGrid` does per row: `constrainedHeight` flips ProjectCard
                // into its internal-scrolling layout (header pinned top, footer
                // pinned bottom) while the `.frame(height:)` is what actually makes
                // the card fill the viewport. `maxHeight: .infinity` alone does
                // nothing here — the enclosing ScrollView sizes its content to the
                // natural height, leaving the card hugging its content.
                cardCell(for: project, constrainedHeight: constrainedHeight)
                    .frame(maxWidth: .infinity)
                    .frame(height: constrainedHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(Self.gridPadding)
        // #046: match the other grids — extra trailing inset so the card's action
        // buttons clear the macOS overlay scroller.
        .padding(.trailing, Self.scrollerClearance)
    }

    /// Groups `count` card indices into rows of `columns` each, in reading order
    /// (row r = indices `r*columns ..< min((r+1)*columns, count)`). Returns an
    /// empty array for an empty grid or a non-positive column count. Pure helper
    /// feeding the fit grid's per-row layout (`fitCardGrid`).
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
        // #040: snapshot once (see `fitCardGrid`) so the assignment indices index
        // the same array; a mid-render shrink of `sortedProjects` from the "Hide
        // Empty" toggle would otherwise trap on a stale index here.
        let projects = sortedProjects
        let assignments = BrowserWindow.columnAssignments(
            count: projects.count,
            columns: columns
        )
        return HStack(alignment: .top, spacing: Self.gridSpacing) {
            ForEach(0..<assignments.count, id: \.self) { col in
                LazyVStack(spacing: Self.gridSpacing) {
                    ForEach(assignments[col], id: \.self) { idx in
                        // #040: skip a stale index against the shrunk snapshot.
                        if idx < projects.count {
                            let project = projects[idx]
                            cardCell(for: project)
                        }
                    }
                }
                // Each column shares the available width evenly and tops-aligns its
                // stack so a shorter column doesn't get stretched vertically.
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(Self.gridPadding)
        // #046: match the fit grid — extra trailing inset so the rightmost cards'
        // action buttons clear the macOS overlay scroller.
        .padding(.trailing, Self.scrollerClearance)
    }

    /// The shared per-card chrome used by BOTH the fit (`fitCardGrid`) and the
    /// variable-height scroll (`variableCardGrid`) paths: the `ProjectCard` plus
    /// the menu-bar drill-down `.id` (#004), the #017 leading drop-indicator
    /// overlay, and the #017 drag/drop reorder modifiers, with the card's "+" glyph
    /// wired to the shared "New Plan" modal pre-selected to THIS project (#031). It
    /// applies NO height frame and NO trailing Spacer — the fit path wraps it in a
    /// fixed-height frame, while the scroll path lets it size to its content.
    ///
    /// #038: `constrainedHeight` is the fixed cell height the fit path imposes on
    /// this card's row (`finalHeights[rowIndex]`); the scroll path passes `nil`. A
    /// non-nil value tells `ProjectCard` to scroll its plan list internally (and
    /// clip to its bounds) instead of overflowing the cell and overlapping the card
    /// beneath it; `nil` keeps the card at its natural, content-hugging height.
    @ViewBuilder
    private func cardCell(for project: ProjectTasks, constrainedHeight: CGFloat? = nil) -> some View {
        // #031: the card's "+" glyph opens the shared modal pre-selected to THIS
        // card's project via `onNewPlan` (a fresh `NewPlanRequest` id so
        // `.sheet(item:)` fires).
        // #073: a plan-row tap opens the in-window detail overlay by setting
        // `detailRowID` via `onOpenDetail` (mirrors the `onNewPlan` plumbing).
        ProjectCard(
            project: project,
            constrainedHeight: constrainedHeight,
            onNewPlan: { path in
                newPlanRequest = NewPlanRequest(projectPath: path)
            },
            onOpenDetail: { id in
                detailRowID = id
            }
        )
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
///
/// Declared at module visibility (not `private`) so the `shouldOpenNewPlan`
/// re-entrancy guard (#064) can be unit-tested by constructing/inspecting a
/// request directly, without the store.
struct NewPlanRequest: Identifiable {
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
/// `BrowserWindow.evenRowHeights`. Mirrors `GridWidthKey`: read in `.background`
/// so the height measurement never feeds back into the scroll content's own
/// vertical layout. Reduces by taking the latest (max) reported height.
private struct GridHeightKey: PreferenceKey {
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
    /// active rows (the same cross-project lookup the card grid and the
    /// plan-detail overlay pane both need). Flattens `activeRows` over all
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

    /// Whether `project` survives the current project view mode (#072): `.all`
    /// keeps everything, `.active` keeps only projects with outstanding work, and
    /// `.starred` keeps only projects whose path the user has starred.
    ///
    /// Note the deliberate behavior change from the "Hide Empty" gate this
    /// replaced: that gate rescued a starred-but-empty project via an
    /// `|| isStarred` clause, so star was only ever an EXCEPTION to a rule rather
    /// than a filter. There is no such clause here — `.active` means exactly
    /// "has outstanding work", and curated projects are found under `.starred`.
    ///
    /// Pure value work — no I/O, no SwiftUI; drives `BrowserWindow.sortedProjects`.
    static func visibleUnderViewMode(
        _ project: ProjectTasks,
        mode: ProjectViewMode,
        starredProjectPaths: Set<String>
    ) -> Bool {
        switch mode {
        case .all: return true
        case .active: return project.hasOutstandingWork
        case .starred: return starredProjectPaths.contains(project.projectPath)
        }
    }

    /// Whether `project` is visible under focus mode (#067): when
    /// `focusedProjectPath` is `nil`, focus mode is off and every project is
    /// visible; otherwise only the project whose path matches the focused path is
    /// shown. Pure value work — no I/O, no SwiftUI.
    static func visibleUnderFocus(
        _ project: ProjectTasks,
        focusedProjectPath: String?
    ) -> Bool {
        guard let focusedProjectPath else { return true }
        return project.projectPath == focusedProjectPath
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
