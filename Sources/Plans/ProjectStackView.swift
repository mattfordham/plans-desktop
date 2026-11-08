import SwiftUI

/// The "All projects" content of the browser window (#096): a single vertical,
/// scrolling stack of `ProjectCard`s, one per registered project, each at the
/// full column width and its natural height.
///
/// It is deliberately a plain `ScrollView` + `VStack` with no measured layout:
/// no `GeometryReader` probes, no preference keys, and no width/height state
/// feeding the layout. The earlier responsive grid (fit-to-screen and masonry
/// layouts, focus mode) measured its own column and fed the result back into
/// its layout; inside a split-view column that hung the app in endless SwiftUI
/// layout passes twice, so it was replaced by this stack. The project count is
/// small, so a non-lazy `VStack` is fine and avoids lazy-stack measurement
/// estimates entirely.
///
/// The view is split in two so drag-hover state never rebuilds the toolbar:
/// this outer view owns the stack-only toolbar items (the All/Active view-mode
/// menu and "Sort by Recency") and reads only store settings, while the inner
/// `ProjectStackContent` owns the `dropTargetPath` drag highlight and the
/// `ScrollView`. A `.toolbar` on a NavigationSplitView content-column view
/// merges into the window toolbar while this view is showing and leaves with
/// it, so these items only appear under "All projects". Window-wide controls
/// (New Plan, Link Project, backlog) stay on `BrowserWindow`'s root toolbar.
///
/// Window-level concerns are injected rather than owned: the plan-detail
/// selection (`selectedRowID` / `onOpenDetail`, #095) and the shared "New Plan"
/// sheet (`onNewPlan`, #031) both live on `BrowserWindow`.
///
/// The view ONLY reads from the injected `PlansStore` (plus UserDefaults-backed
/// order / view-mode writes) — never `.plans/` (§2 read-only).
struct ProjectStackView: View {
    @Environment(PlansStore.self) private var store

    /// The plan currently shown in the detail column, so the matching card row
    /// renders as selected (#095).
    let selectedRowID: TaskRow.ID?

    /// Opens the shared "New Plan" sheet pre-selected to the given project path
    /// (a card's "+" glyph, #031).
    let onNewPlan: (String) -> Void

    /// Selects a plan row into the window's detail column (#095).
    let onOpenDetail: (TaskRow.ID) -> Void

    // MARK: - Layout constants

    /// The vertical gap between stacked projects. #105: zero — projects abut
    /// like the grouped task list's sections; each project's `SectionHeaderBand`
    /// carries the separating space.
    static let cardSpacing: CGFloat = 0

    /// #105: no side inset — project sections and their row bands run edge to
    /// edge like the All Plans list.
    static let stackHorizontalPadding: CGFloat = 0

    /// #105: zero — the first project's header band sits flush at the top.
    static let stackVerticalPadding: CGFloat = 0

    /// The projects in display order for the card stack. When the user's manual
    /// order is active and non-empty (#017) the stack honours that override
    /// (`applyManualOrder`, new project paths to the top); otherwise it falls
    /// back to the automatic recency sort (`sortByStaleness`). The view-mode
    /// menu (#072) is then applied: `.all` keeps everything, `.active` keeps
    /// only projects with outstanding work, preserving order.
    ///
    /// Static and pure so `BrowserWindow` can derive the SAME list for its
    /// detail-selection invariant (`displayedRows`) without owning the stack.
    static func stackProjects(
        _ projects: [ProjectTasks],
        manualOrderActive: Bool,
        order: [String],
        viewMode: ProjectViewMode
    ) -> [ProjectTasks] {
        let sorted: [ProjectTasks]
        if manualOrderActive && !order.isEmpty {
            sorted = BrowserViewModel.applyManualOrder(projects, order: order)
        } else {
            sorted = BrowserViewModel.sortByStaleness(projects)
        }
        return sorted.filter {
            BrowserViewModel.visibleUnderViewMode($0, mode: viewMode)
        }
    }

    /// Which way an edge auto-scroll is moving the stack.
    enum AutoScrollDirection: Equatable {
        case up, down
    }

    /// The height of the invisible drop strips pinned to the top and bottom of
    /// the stack's visible area that drive edge auto-scroll during a card drag.
    /// Kept thin so they cover little more than the stack padding at either
    /// end. A constant, never measured.
    static let autoScrollEdgeHeight: CGFloat = 28

    /// How often an edge auto-scroll steps one card while a strip is targeted.
    static let autoScrollInterval: Duration = .milliseconds(350)

    /// The next card to scroll to during an edge auto-scroll: the card after
    /// (`.down`) or before (`.up`) `current`, the top-visible card reported by
    /// the scroll view. A `nil` or no-longer-displayed `current` counts as the
    /// top of the stack. Returns `nil` when there is nowhere further to go, which
    /// stops the auto-scroll loop. Pure value work.
    static func autoScrollTarget(
        in paths: [String],
        current: String?,
        direction: AutoScrollDirection
    ) -> String? {
        guard !paths.isEmpty else { return nil }
        let index = current.flatMap { paths.firstIndex(of: $0) } ?? 0
        let next = direction == .down ? index + 1 : index - 1
        return paths.indices.contains(next) ? paths[next] : nil
    }

    var body: some View {
        ProjectStackContent(
            selectedRowID: selectedRowID,
            onNewPlan: onNewPlan,
            onOpenDetail: onOpenDetail
        )
        // The stack-only toolbar. Attached HERE, on a view whose body reads only
        // store settings — never the inner view's drag/drop state — so a
        // drag-hover change can't rebuild the toolbar content.
        .toolbar {
            // #072: the project view mode. Setting `store.projectViewMode`
            // re-derives `stackProjects` so the stack refilters. A `Menu` (kept
            // after #096 dropped `.starred`) whose label shows the current mode
            // as visible TEXT beside its symbol; accent-tinted while a filter
            // is actually narrowing the stack (any mode but `.all`).
            ToolbarItem {
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
                .help("Show all projects or only those with outstanding work")
            }
            // #017: leave the manual card order and return to the automatic
            // recency sort. Always present while the stack is (so its placement
            // doesn't shift), DISABLED when no manual order is active. Pure store
            // call; never writes `.plans/` (§2).
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
                // Flat toolbar styling rather than the chunky bordered pill.
                .buttonStyle(.borderless)
                .disabled(!store.manualOrderActive)
                .help("Discard the manual card order and sort by recency.")
            }
        }
    }
}

/// The scrolling card stack itself, split out of `ProjectStackView` so its
/// `dropTargetPath` drag-hover state is invisible to the toolbar (see there).
private struct ProjectStackContent: View {
    @Environment(PlansStore.self) private var store

    let selectedRowID: TaskRow.ID?
    let onNewPlan: (String) -> Void
    let onOpenDetail: (TaskRow.ID) -> Void

    /// #017: the project path of the card currently hovered as a drop target
    /// during a card drag, or `nil`. Driven by each card's
    /// `.dropDestination(isTargeted:)` callback so the stack can paint an
    /// insertion indicator on the TOP edge of the card the dragged card would
    /// land before. Purely visual — it never feeds layout.
    @State private var dropTargetPath: String? = nil

    /// The top-visible card, tracked by the scroll view itself through
    /// `.scrollPosition(id:)`, and written to step the stack during an edge
    /// auto-scroll. Nothing here measures geometry or feeds layout.
    @State private var scrolledPath: String? = nil

    /// Whether a card drag is (probably) in progress over the stack. SwiftUI's
    /// `.draggable` has no drag-ended callback, so this is set whenever a card
    /// or edge strip is targeted, cleared on drop, and cleared after a short
    /// grace period with nothing targeted (a drag that left the stack or was
    /// cancelled). It gates the edge strips so they never block clicks on the
    /// first or last card outside a drag.
    @State private var dragInProgress = false

    /// The edge strip currently targeted by a drag, if any.
    @State private var edgeTarget: ProjectStackView.AutoScrollDirection? = nil

    /// The running edge auto-scroll loop. Cancelled when its strip loses the
    /// target, on any drop, and on disappear, so it can never keep running.
    @State private var autoScrollTask: _Concurrency.Task<Void, Never>? = nil

    /// The pending "drag has ended" grace-period check (see `dragInProgress`).
    @State private var dragEndTask: _Concurrency.Task<Void, Never>? = nil

    /// The store-backed stack projects (see `ProjectStackView.stackProjects`).
    private var projects: [ProjectTasks] {
        ProjectStackView.stackProjects(
            store.projects,
            manualOrderActive: store.manualOrderActive,
            order: store.projectOrderOverride,
            viewMode: store.projectViewMode
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: ProjectStackView.cardSpacing) {
                ForEach(projects, id: \.projectPath) { project in
                    cardCell(for: project)
                }
            }
            // Marks each card as a scroll target so `.scrollPosition(id:)`
            // reports (and can be set to) the top-visible card. No layout effect.
            .scrollTargetLayout()
            .padding(.horizontal, ProjectStackView.stackHorizontalPadding)
            .padding(.vertical, ProjectStackView.stackVerticalPadding)
        }
        .scrollPosition(id: $scrolledPath, anchor: .top)
        // #045: no empty overscroll bounce when the stack fits the column.
        .scrollBounceBehavior(.basedOnSize)
        // Edge auto-scroll strips: overlays pinned to the visible area (outside
        // the scroll content, so they add no layout), present only while a drag
        // is in progress so they never intercept ordinary clicks.
        .overlay(alignment: .top) {
            if dragInProgress { edgeStrip(.up) }
        }
        .overlay(alignment: .bottom) {
            if dragInProgress { edgeStrip(.down) }
        }
        .overlay {
            if projects.isEmpty {
                Text("No projects")
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { endDrag() }
    }

    /// An invisible drop strip at the top (`.up`) or bottom (`.down`) edge.
    /// Hovering it steps the stack in that direction; dropping on it moves the
    /// dragged card to the very start (top strip) or end (bottom strip) of the
    /// order. A faint accent wash shows while it is targeted. Purely an overlay.
    private func edgeStrip(_ direction: ProjectStackView.AutoScrollDirection) -> some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(edgeTarget == direction ? 0.18 : 0), .clear],
            startPoint: direction == .up ? .top : .bottom,
            endPoint: direction == .up ? .bottom : .top
        )
        .frame(maxWidth: .infinity)
        .frame(height: ProjectStackView.autoScrollEdgeHeight)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            endDrag()
            guard let sourcePath = items.first else { return false }
            let target = direction == .up ? projects.first?.projectPath : nil
            handleDrop(sourcePath: sourcePath, before: target)
            return true
        } isTargeted: { targeted in
            if targeted {
                edgeTarget = direction
                startAutoScroll(direction)
            } else if edgeTarget == direction {
                edgeTarget = nil
                stopAutoScroll()
            }
            refreshDragState()
        }
    }

    /// Starts (or restarts) stepping the stack one card per
    /// `autoScrollInterval` toward `direction`, stopping by itself at the end of
    /// the stack.
    private func startAutoScroll(_ direction: ProjectStackView.AutoScrollDirection) {
        stopAutoScroll()
        autoScrollTask = _Concurrency.Task { @MainActor in
            while !_Concurrency.Task.isCancelled {
                guard let next = ProjectStackView.autoScrollTarget(
                    in: projects.map(\.projectPath),
                    current: scrolledPath,
                    direction: direction
                ) else { break }
                withAnimation(.easeInOut(duration: 0.25)) {
                    scrolledPath = next
                }
                try? await _Concurrency.Task.sleep(for: ProjectStackView.autoScrollInterval)
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
    }

    /// Keeps `dragInProgress` in step with targeting: on while anything is
    /// targeted, off after a short grace period with nothing targeted (the gaps
    /// between cards briefly target nothing, so it can't clear immediately).
    private func refreshDragState() {
        dragEndTask?.cancel()
        dragEndTask = nil
        if dropTargetPath != nil || edgeTarget != nil {
            dragInProgress = true
            return
        }
        guard dragInProgress else { return }
        dragEndTask = _Concurrency.Task { @MainActor in
            try? await _Concurrency.Task.sleep(for: .seconds(1.5))
            guard !_Concurrency.Task.isCancelled,
                  dropTargetPath == nil, edgeTarget == nil else { return }
            dragInProgress = false
            stopAutoScroll()
        }
    }

    /// Tears down all drag state and stops every timer: on drop and disappear.
    private func endDrag() {
        stopAutoScroll()
        dragEndTask?.cancel()
        dragEndTask = nil
        edgeTarget = nil
        dropTargetPath = nil
        dragInProgress = false
    }

    /// One card in the stack: the `ProjectCard` plus its per-project `.id`, the
    /// #017 drop indicator, and the drag/drop reorder modifiers.
    @ViewBuilder
    private func cardCell(for project: ProjectTasks) -> some View {
        // #031: the card's "+" glyph opens the shared modal pre-selected to THIS
        // project via `onNewPlan`. #095: a plan-row tap selects it into the
        // detail column via `onOpenDetail`.
        ProjectCard(
            project: project,
            selectedRowID: selectedRowID,
            onNewPlan: onNewPlan,
            onOpenDetail: onOpenDetail
        )
        // Key the card's identity on its project so its local state (type
        // filter, hover, open popover) follows the project across reorder and
        // view-mode changes.
        .id(project.projectPath)
        // #017 drop indicator: while a card is dragged over this one, paint a
        // horizontal accent bar on its TOP edge — the dragged card will be
        // inserted BEFORE (above) this one. An overlay, so it adds no layout.
        .overlay(alignment: .top) {
            if dropTargetPath == project.projectPath {
                // #105: sections abut, so the bar sits ON the boundary.
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 3)
                    .offset(y: -1.5)
                    .transition(.opacity)
            }
        }
        // #017: drag a card and drop it onto another to override the order. The
        // card carries its project path as the payload; the drop target
        // re-inserts the dragged path BEFORE this card via the pure `reorder`
        // helper over the CURRENTLY displayed order, then persists through the
        // store (shared with the sidebar's Projects list).
        .draggable(project.projectPath)
        .dropDestination(for: String.self) { items, _ in
            endDrag()
            guard let sourcePath = items.first else { return false }
            handleDrop(sourcePath: sourcePath, before: project.projectPath)
            return true
        } isTargeted: { targeted in
            // Set on enter; clear only if WE are still the recorded target, so a
            // neighbour's enter (which may arrive before our exit) isn't
            // clobbered back to nil.
            if targeted {
                dropTargetPath = project.projectPath
            } else if dropTargetPath == project.projectPath {
                dropTargetPath = nil
            }
            refreshDragState()
        }
    }

    /// Resolves a drag-drop into a new persisted manual order (#017): moves
    /// `sourcePath` immediately before `targetPath` (or to the end for `nil`)
    /// via `BrowserViewModel.reorder`, then activates + persists it through the
    /// store. The reorder runs over the FULL ordered project list (view mode
    /// `.all`, the same list the sidebar's Projects section shows), not just the
    /// visible cards, so a drag under the Active filter can't drop the hidden
    /// projects out of the shared order. Only writes UserDefaults via the store
    /// — never `.plans/`.
    private func handleDrop(sourcePath: String, before targetPath: String?) {
        let current = ProjectStackView.stackProjects(
            store.projects,
            manualOrderActive: store.manualOrderActive,
            order: store.projectOrderOverride,
            viewMode: .all
        ).map(\.projectPath)
        let newOrder = BrowserViewModel.reorder(
            current,
            moving: sourcePath,
            before: targetPath
        )
        store.setManualOrder(newOrder)
    }
}
