import SwiftUI

/// Surface B: the cross-project browser window (§008), a three-column
/// `NavigationSplitView` (#094/#095/#096): a sidebar of smart views and
/// projects, a content column, and a persistent DETAIL COLUMN.
///
/// The content column dispatches on the sidebar selection. "All projects" shows
/// `ProjectStackView`, a vertical scrolling stack of `ProjectCard`s with its
/// own stack-only toolbar items (#096). A smart view or a single project shows
/// a flat `TaskListView`. This view owns the window-wide chrome: the New Plan
/// sheet, the ⌘N trigger, the New Plan / Link Project / backlog toolbar items,
/// the menu-bar drill-down (which selects the project in the sidebar), and the
/// column widths.
///
/// Tapping a
/// plan row — in a card or a task list, via the shared `onOpenDetail` closure —
/// sets the single `selectedRowID` selection, and the detail column renders
/// `PlanDetailView(rowID:)` keyed by `.id(selectedRowID)` (or a "No Plan
/// Selected" placeholder). The selection is not persisted, Esc does not clear
/// it, and it is cleared via `BrowserViewModel.validSelection(_:visibleIn:)`
/// whenever the content column stops listing the row (a sidebar view switch,
/// or a reload that removes it or moves it out of the current view). This
/// replaces the #073 modal overlay pane and the earlier standalone per-plan
/// detail window (§011).
///
/// The view ONLY reads from the injected `PlansStore` — it never writes,
/// creates, moves, or deletes any `.plans/` data (§2 read-only).
struct BrowserWindow: View {
    @Environment(PlansStore.self) private var store

    // MARK: - Split-view column sizing (#096)

    /// The sidebar column's widths.
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarIdealWidth: CGFloat = 230
    static let sidebarMaxWidth: CGFloat = 320

    /// The content column's widths. Under "All projects" this column is the
    /// vertical card stack (`ProjectStackView`), so its ideal is one readable
    /// card wide; nothing in the stack is measured from it.
    static let contentColumnMinWidth: CGFloat = 420
    static let contentColumnIdealWidth: CGFloat = 560

    /// The detail column's widths (#095).
    static let detailMinWidth: CGFloat = 380
    static let detailIdealWidth: CGFloat = 500

    /// The window's minimum size: every column at its minimum width.
    static let windowMinWidth: CGFloat = 1000
    static let windowMinHeight: CGFloat = 520

    /// The browser window's default size (`PlansApp`'s `.defaultSize`): every
    /// column at its ideal width plus a little room for the dividers. AppKit
    /// clamps a window's initial frame to the screen, so on a smaller display
    /// the window simply opens narrower.
    static let defaultWindowWidth: CGFloat =
        sidebarIdealWidth + contentColumnIdealWidth + detailIdealWidth + 10
    static let defaultWindowHeight: CGFloat = 800

    /// #031: the in-flight request to open the shared "New Plan" modal,
    /// pre-selected to a project. `nil` keeps the sheet closed; setting it (from
    /// the global toolbar button or a card's "+" glyph) presents the sheet.
    /// Wrapped in an `Identifiable` request (a bare `String?` isn't
    /// `Identifiable`) so `.sheet(item:)` drives presentation and a fresh `id`
    /// re-presents even for the same project path.
    @State private var newPlanRequest: NewPlanRequest? = nil

    /// #095: the plan shown in the split view's detail column, keyed on the
    /// selected row's composite `TaskRow.ID`, or `nil` for the empty placeholder.
    /// ONE selection shared by the card stack (`ProjectCard.onOpenDetail`) and the
    /// task lists (`TaskListView.onOpenDetail`). UI-only, transient state —
    /// deliberately NOT persisted to UserDefaults, mirroring `newPlanRequest`.
    @State private var selectedRowID: TaskRow.ID? = nil

    var body: some View {
        // #094: a smart-view/project sidebar on the left, and a content column
        // that dispatches on the persisted
        // `store.browserSelection`: the all-projects card stack, a
        // cross-project smart-view task list, or a single project's task list.
        // The window-level chrome (New Plan sheet, ⌘N trigger, and the
        // window-wide toolbar items: New Plan, Link Project, backlog) lives on
        // the OUTER split view so it covers the whole window regardless of which
        // column is focused. #096: the stack-only toolbar items live on
        // `ProjectStackView` (the all-projects content), so they appear only
        // while the card stack is showing.
        // #095: three columns — sidebar / content (card stack or task list) / detail
        // (the selected plan, or a placeholder).
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: Self.sidebarMinWidth, ideal: Self.sidebarIdealWidth, max: Self.sidebarMaxWidth
                )
        } content: {
            // #096: one readable card wide; the card stack is never sized
            // from this column's measured width.
            contentColumn
                .navigationSplitViewColumnWidth(
                    min: Self.contentColumnMinWidth, ideal: Self.contentColumnIdealWidth
                )
        } detail: {
            detailColumn
                .navigationSplitViewColumnWidth(min: Self.detailMinWidth, ideal: Self.detailIdealWidth)
        }
            // Three columns need more width than the two-column layout did; the
            // window's `defaultSize` (PlansApp, `defaultWindowWidth`) opens with
            // every column at its ideal width.
            .frame(minWidth: Self.windowMinWidth, minHeight: Self.windowMinHeight)
            // §004 drill-down handoff (#094): when the menu bar sets a target
            // project before opening this window, SELECT that project's task list
            // in the sidebar — the ONLY drill-down effect (#096 removed the old
            // scroll-to-card path). Guarded so a stale path naming a project
            // that is no longer live is ignored.
            .onAppear { selectDrillDownProjectIfLive() }
            .onChange(of: store.selectedProjectPath) { _, _ in
                selectDrillDownProjectIfLive()
            }
            // #095: the detail column only shows a plan the content column
            // currently lists. Whenever the displayed rows change — a sidebar
            // view switch, a poll (plan completed/deleted/moved out of the
            // current smart view, project unlinked), or a backlog / view-mode
            // toggle — drop a selection that is no longer listed, falling
            // back to the "No Plan Selected" placeholder. Only assign on an
            // actual change so an unchanged selection doesn't invalidate the
            // detail column every poll.
            .onChange(of: displayedRows.map(\.id)) { _, _ in
                let valid = BrowserViewModel.validSelection(selectedRowID, visibleIn: displayedRows)
                if valid != selectedRowID {
                    selectedRowID = valid
                }
            }
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
            // #034: the app-wide ⌘N command (in `PlansApp`) can't reach this
            // window's `@State`, so it bumps `store.newPlanTrigger` and we open
            // the modal here — opening it IDENTICALLY to the toolbar button.
            .onChange(of: store.newPlanTrigger) { _, _ in
                openNewPlanForRecentProject()
            }
            .toolbar {
                // #031: open the shared "New Plan" modal pre-selected to the
                // most-recently-touched project (newest `lastSeen`, ignoring any
                // manual card reorder). Disabled when there are no projects to
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
                // #077: reveal/hide backlogged (deferred) plans. A plain `Button`
                // that flips the persisted `store.showBacklog`, sharing the
                // square toolbar footprint of the other toolbar buttons.
                // Window-wide (#096): it affects the task lists as well as the
                // card stack, so it stays on the root toolbar. Accent-tinted
                // while backlog is being shown, and its `archivebox` glyph fills in
                // (`archivebox.fill`) in that ON state. When off (default) each
                // card renders exactly as before — no backlog section is added.
                ToolbarItem {
                    Button {
                        store.showBacklog.toggle()
                    } label: {
                        Label(
                            store.showBacklog ? "Hide Backlog" : "Show Backlog",
                            systemImage: store.showBacklog ? "archivebox.fill" : "archivebox"
                        )
                    }
                    .foregroundStyle(store.showBacklog ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .help("Show or hide backlogged (deferred) plans")
                }
                // #101: a window-wide indicator of how many plans are currently
                // in progress across EVERY project. Its label is the shared
                // `.inProgress` glyph + a running count, tinted amber from the
                // status vocabulary (never inlined). The whole item is SUPPRESSED
                // at zero — mirroring `smartViewRow` / `iconSpaceCounts`, which
                // hide a zero count. The dropdown lists each running plan; a tap
                // selects the In-progress smart view and opens that plan's detail.
                let runningRows = BrowserViewModel.runningPlanRows(in: store.projects)
                if !runningRows.isEmpty {
                    ToolbarItem {
                        Menu {
                            ForEach(runningRows) { row in
                                Button {
                                    // Select the cross-project In-progress smart
                                    // view, then open this plan in the detail column.
                                    store.browserSelection = .smart(.inProgress)
                                    selectedRowID = row.id
                                } label: {
                                    Label {
                                        Text("\(row.projectName) — \(row.title ?? row.task.id)")
                                    } icon: {
                                        Image(systemName: TaskStatus.inProgress.symbolName)
                                            .foregroundStyle(TaskStatus.inProgress.glanceColor)
                                    }
                                }
                            }
                        } label: {
                            Label("\(runningRows.count)", systemImage: TaskStatus.inProgress.symbolName)
                                .labelStyle(.titleAndIcon)
                        }
                        .foregroundStyle(TaskStatus.inProgress.glanceColor)
                        .help("Plans currently in progress across all projects")
                    }
                }
            }
    }

    // MARK: - Sidebar (#094)

    /// A binding that round-trips the sidebar's `List` selection with the
    /// persisted `store.browserSelection`, resolved DEFENSIVELY on read so a
    /// stored `.project(path)` whose project is no longer live falls back to the
    /// all-projects card stack rather than highlighting a dead row.
    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { BrowserViewModel.resolve(store.browserSelection, in: store.projects) },
            // A `List` single-selection binding is optional; a tap into empty
            // space can clear it. Ignore a clear (keep the last selection) and
            // otherwise persist the new one.
            set: { if let new = $0 { store.browserSelection = new } }
        )
    }

    /// The projects listed in the sidebar's "Projects" section: starred
    /// projects pinned to the top, then the rest — each group in the SAME
    /// order the card stack uses (manual override when active + non-empty, else
    /// recency). DELIBERATELY NOT filtered by `projectViewMode` — the
    /// sidebar always lists every project so any one is reachable.
    private var sidebarProjects: [ProjectTasks] {
        let ordered: [ProjectTasks]
        if store.manualOrderActive && !store.projectOrderOverride.isEmpty {
            ordered = BrowserViewModel.applyManualOrder(
                store.projects,
                order: store.projectOrderOverride
            )
        } else {
            ordered = BrowserViewModel.sortByStaleness(store.projects)
        }
        return BrowserViewModel.pinStarredFirst(ordered, starred: store.starredProjectPaths)
    }

    /// The left column: a selectable `List` bound to `store.browserSelection`.
    /// Top-to-bottom — a "Status" section of smart views, the all-projects
    /// entry, and a single combined "Projects" section listing every project
    /// (starred ones pinned to the top with a filled-star glyph, the rest
    /// below with a folder glyph).
    private var sidebar: some View {
        List(selection: selectionBinding) {
            Section("Status") {
                ForEach(SmartView.allCases, id: \.rawValue) { view in
                    smartViewRow(view)
                        .tag(SidebarSelection.smart(view))
                }
            }

            Section {
                Label("All Projects", systemImage: "rectangle.3.group")
                    .tag(SidebarSelection.allProjects)
            }

            Section("Projects") {
                ForEach(sidebarProjects, id: \.projectPath) { project in
                    Label(
                        project.projectName,
                        systemImage: BrowserViewModel.sidebarGlyph(
                            starred: store.starredProjectPaths.contains(project.projectPath)
                        )
                    )
                    .lineLimit(1)
                    .tag(SidebarSelection.project(project.projectPath))
                }
                // Drag-reorder the Projects list. It writes the SAME manual order
                // the "All projects" card stack uses, so a move here reorders the
                // stack and vice versa. The first move seeds the manual order from
                // the currently displayed (recency) order, like a first card drag.
                .onMove { offsets, destination in
                    let newOrder = BrowserViewModel.moveOrder(
                        sidebarProjects.map(\.projectPath),
                        fromOffsets: offsets,
                        toOffset: destination
                    )
                    store.setManualOrder(newOrder)
                }
            }
        }
        .frame(minWidth: 220)
    }

    /// One smart-view row: its icon (tinted) + label + a trailing count of its
    /// matching cross-project rows (suppressed at zero).
    @ViewBuilder
    private func smartViewRow(_ view: SmartView) -> some View {
        let count = BrowserViewModel.rows(in: store.projects, matching: view).count
        HStack {
            Label {
                Text(view.label)
            } icon: {
                Image(systemName: view.symbolName)
                    .foregroundStyle(view.color)
            }
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Content column (#094)

    /// The right column: dispatches on the (defensively resolved) selection.
    /// `.allProjects` renders the card stack (`ProjectStackView`, #096); `.smart` renders
    /// a cross-project task list (project labels shown); `.project` renders that
    /// single project's active (+ optionally backlog) task list (no project
    /// labels — every row is the same project).
    @ViewBuilder
    private var contentColumn: some View {
        let selection = BrowserViewModel.resolve(store.browserSelection, in: store.projects)
        switch selection {
        case .allProjects:
            // #096: the vertical card stack; it brings its own stack-only toolbar.
            ProjectStackView(
                selectedRowID: selectedRowID,
                onNewPlan: { path in
                    newPlanRequest = NewPlanRequest(projectPath: path)
                },
                onOpenDetail: { selectedRowID = $0 }
            )
        case .smart:
            TaskListView(
                rows: displayedRows,
                showsProjectLabel: true,
                onOpenDetail: { selectedRowID = $0 },
                selectedRowID: selectedRowID
            )
        case .project:
            TaskListView(
                rows: displayedRows,
                showsProjectLabel: false,
                onOpenDetail: { selectedRowID = $0 },
                selectedRowID: selectedRowID
            )
        }
    }

    /// The rows the content column currently displays for the (defensively
    /// resolved) sidebar selection — the single source of truth shared by the
    /// task lists and the detail-selection invariant (see
    /// `BrowserViewModel.displayedRows`). For `.project` that is its active rows
    /// plus its backlog rows when `store.showBacklog` is on (an empty list if the
    /// project can't be found); for `.allProjects` it is the stacked cards' rows.
    private var displayedRows: [TaskRow] {
        BrowserViewModel.displayedRows(
            for: BrowserViewModel.resolve(store.browserSelection, in: store.projects),
            in: store.projects,
            stackProjects: ProjectStackView.stackProjects(
                store.projects,
                manualOrderActive: store.manualOrderActive,
                order: store.projectOrderOverride,
                viewMode: store.projectViewMode
            ),
            showBacklog: store.showBacklog
        )
    }

    /// §004/#094 drill-down: when the menu bar set `store.selectedProjectPath`
    /// to a LIVE project, select that project's task list in the sidebar. A stale
    /// path (no matching live project) is ignored so the selection is never
    /// stranded on a dead project. Pure store write — never touches `.plans/`.
    private func selectDrillDownProjectIfLive() {
        guard let path = store.selectedProjectPath,
              store.projects.contains(where: { $0.projectPath == path }) else { return }
        store.browserSelection = .project(path)
    }

    // MARK: - Detail column (#095)

    /// The split view's detail column: the selected plan's `PlanDetailView`, or
    /// a placeholder when nothing is selected. Keyed with `.id(selectedRowID)` so
    /// switching plans rebuilds the view — its sheet flags don't carry over and
    /// `shouldAutoOpenProgress` fires afresh for each plan.
    @ViewBuilder
    private var detailColumn: some View {
        if let selectedRowID {
            PlanDetailView(rowID: selectedRowID)
                .id(selectedRowID)
        } else {
            ContentUnavailableView("No Plan Selected", systemImage: "doc.text")
        }
    }

    // MARK: - New Plan

    /// Opens the shared "New Plan" modal pre-selected to the most-recently-touched
    /// project (the newest `lastSeen` via the staleness sort), or does nothing when
    /// there are no projects (#031). This deliberately keys off recency and ignores
    /// any active manual card reorder (#017) — the general "New Plan" entry point
    /// always defaults to the project the user most recently worked in, not whatever
    /// card happens to sit at the top of a manually reordered card stack. Shared by the
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

    /// The run-failure overlay (#079) for this row, or `nil` when healthy.
    /// Passthrough of the underlying `Task.failure`, correlated by the store.
    var failure: TaskFailure? { task.failure }

    /// The status glyph + color for this task, matching the plans-cc TUI
    /// dashboard (blocked takes precedence over status; a run failure (#079) sits
    /// just below blocked). `isFailed` lights the alarm indicator whenever the
    /// run-failure overlay is present.
    var indicator: TaskStatusIndicator {
        TaskStatusIndicator(status: task.status,
                            isBlocked: task.isBlocked,
                            isFailed: task.failure != nil)
    }
}

/// A cross-project "smart view" for the browser sidebar (#094): a saved,
/// status-like lens over every project's tasks at once. Each case maps to a
/// label/icon/color drawn from the EXISTING glyph vocabulary (`TaskStatus`
/// `filterLabel`/`symbolName`/`glanceColor`, `TaskStatusIndicator` for the
/// blocked/failed alarm, and the "Backlog" label in `TaskType+Glyph.swift`), so
/// the sidebar never invents its own inline copy. `rawValue` gives a stable
/// string form for persistence via `SidebarSelection`.
///
/// `CaseIterable`/`Equatable`/pure value code so it is `Sendable`-clean and
/// directly unit-testable without a view.
enum SmartView: String, CaseIterable, Equatable, Hashable {
    /// Tasks whose status is `.inProgress`, across every project (active rows).
    case inProgress
    /// Tasks in EITHER `.review` OR `.inReview` — one combined review lens.
    case review
    /// Active tasks flagged blocked (`Task.isBlocked`).
    case blocked
    /// Active tasks carrying a run-failure overlay (`Task.failure != nil`).
    case failed
    /// Backlogged (deferred) tasks, across every project.
    case backlog

    /// The sidebar label for this view, from the shared vocabulary. Review reads
    /// "Review" (it covers both review and in-review).
    var label: String {
        switch self {
        case .inProgress: return TaskStatus.inProgress.filterLabel
        case .review: return "Review"
        case .blocked: return "Blocked"
        case .failed: return "Failed"
        case .backlog: return TaskStatus.backlogFilterLabel
        }
    }

    /// The SF Symbol for this view, reusing the status/indicator vocabulary.
    var symbolName: String {
        switch self {
        case .inProgress: return TaskStatus.inProgress.symbolName
        case .review: return TaskStatus.review.symbolName
        case .blocked: return TaskStatusIndicator.blockedSymbol
        case .failed: return TaskStatusIndicator.failureSymbol
        case .backlog: return TaskStatus.backlogSymbolName
        }
    }

    /// The tint color for this view, reusing the status/indicator palette.
    var color: Color {
        switch self {
        case .inProgress: return TaskStatus.inProgress.glanceColor
        case .review: return TaskStatus.review.glanceColor
        case .blocked: return TaskStatusIndicator.blockedColor
        case .failed: return TaskStatusIndicator.failureColor
        case .backlog: return TaskStatus.backlogGlanceColor
        }
    }
}

/// How a cross-project task list is ordered (#094). ONE shared setting across
/// every list (persisted on `PlansStore`). Pure value enum — `Sendable`-clean.
enum TaskSort: String, CaseIterable, Equatable {
    /// By `Task.status?.activePriority`, highest first.
    case status
    /// By owning `projectName`, ascending.
    case project
    /// By staleness (`taskStalenessDate`): NEWEST first, dateless rows LAST.
    case staleness
}

/// How a cross-project task list is grouped into titled sections (#094). Reuses
/// the same dimensions as `TaskSort` so the sidebar can offer one coherent
/// control. Pure value enum — `Sendable`-clean.
enum TaskGroup: String, CaseIterable, Equatable {
    /// One section per status, with `.review`/`.inReview` COMBINED under "Review".
    case status
    /// One section per owning project (`projectName`).
    case project
}

/// The browser sidebar's current selection (#094): the all-projects card stack,
/// a cross-project smart view, or a single project by path.
///
/// `encoded`/`init?(encoded:)` give a stable STRING round trip for persistence.
/// The encoding splits on the FIRST `:` ONLY, so a project path that itself
/// contains `:` or `/` survives intact (`"project:/Users/x/My:Weird/Path"`).
enum SidebarSelection: Equatable, Hashable {
    case allProjects
    case smart(SmartView)
    case project(String)

    /// The stable string encoding. `"all"`, `"smart:<rawValue>"`, or
    /// `"project:<path>"` (the path kept verbatim after the first `:`).
    var encoded: String {
        switch self {
        case .allProjects: return "all"
        case .smart(let view): return "smart:\(view.rawValue)"
        case .project(let path): return "project:\(path)"
        }
    }

    /// Decodes an `encoded` string, splitting on the FIRST `:` only. Returns
    /// `nil` for an unrecognized prefix or an unknown smart-view rawValue.
    init?(encoded: String) {
        if encoded == "all" {
            self = .allProjects
            return
        }
        guard let colon = encoded.firstIndex(of: ":") else { return nil }
        let prefix = String(encoded[encoded.startIndex..<colon])
        let value = String(encoded[encoded.index(after: colon)...])
        switch prefix {
        case "smart":
            guard let view = SmartView(rawValue: value) else { return nil }
            self = .smart(view)
        case "project":
            self = .project(value)
        default:
            return nil
        }
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

    /// The clickable plan rows for ONE project's card (the "All projects" stack).
    ///
    /// Maps the project's `activeTasks` (already non-completed, non-nil-status,
    /// and pre-sorted by status priority then id ascending by `TaskParser`) into
    /// `TaskRow`s carrying the owning project identity. This helper does NOT
    /// re-sort — it preserves `TaskParser`'s order — and performs no I/O or
    /// SwiftUI work.
    /// Resolves a composite row id to its `TaskRow` by scanning EVERY project's
    /// active rows AND backlog rows (the same cross-project lookup the card stack
    /// and the plan-detail column both need). Returns the first row whose
    /// `id` matches; `nil` when nothing across any project matches (e.g. a
    /// completed/closed task or a project that disappeared). Pure value work —
    /// no I/O, no SwiftUI.
    ///
    /// Backlog rows MUST be searched here, not just active ones (#077 follow-up).
    /// `ProjectCard`'s backlog section reuses `planRow`, so a backlogged row
    /// carries the same `OpenDetailOnTap` modifier and opens the detail pane with
    /// its composite id — but backlogged tasks live in a SEPARATE
    /// `backloggedTasks` collection deliberately excluded from `activeTasks`, so
    /// a resolver scanning only `activeRows` could never match one and the pane
    /// fell through to its "Plan not found" placeholder.
    ///
    /// Active rows are searched FIRST so they win any id collision. A task id
    /// cannot legitimately occupy `pending/` and `backlog/` at once (the
    /// plan-backlog / plan-restore skills MOVE the file), but if a stale poll ever
    /// surfaced both, the active row is the truthful one — it reflects the task's
    /// live, outstanding state.
    static func resolveRow(in projects: [ProjectTasks], id: TaskRow.ID) -> TaskRow? {
        if let active = projects.flatMap({ activeRows($0) }).first(where: { $0.id == id }) {
            return active
        }
        return projects
            .flatMap { backlogRows($0) }
            .first { $0.id == id }
    }

    /// The detail-column selection after a store refresh: `id` unchanged while
    /// `resolveRow` still finds it (active OR backlog), else `nil` — the plan
    /// completed, was deleted, or its project disappeared. A `nil` selection
    /// stays `nil`. Pure value work — no I/O, no SwiftUI.
    static func validSelection(_ id: TaskRow.ID?, in projects: [ProjectTasks]) -> TaskRow.ID? {
        guard let id, resolveRow(in: projects, id: id) != nil else { return nil }
        return id
    }

    /// The detail-column selection given the rows the content column currently
    /// DISPLAYS: `id` unchanged while one of `rows` carries it, else `nil`. This
    /// keeps the invariant that the detail column only shows a plan the content
    /// column lists (and therefore highlights) — switching the sidebar view, or a
    /// poll moving the plan out of the current smart view, unloads it. Subsumes
    /// `validSelection(_:in:)`: a row gone from the store is gone from `rows`
    /// too. Pure value work — no I/O, no SwiftUI.
    static func validSelection(_ id: TaskRow.ID?, visibleIn rows: [TaskRow]) -> TaskRow.ID? {
        guard let id, rows.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// The rows the content column displays for a (resolved) sidebar
    /// `selection` — single source of truth for both rendering and the
    /// detail-selection invariant. `.smart` → `rows(in:matching:)` over every
    /// project; `.project` → that project's active rows (+ backlog when
    /// `showBacklog`); `.allProjects` → every `stackProjects` card's active rows
    /// (+ backlog when `showBacklog`), where `stackProjects` is the card stack's
    /// view-mode-filtered project set. Per-card type filters are card-local
    /// view state and are not reflected here. Pure value work.
    static func displayedRows(
        for selection: SidebarSelection,
        in projects: [ProjectTasks],
        stackProjects: [ProjectTasks],
        showBacklog: Bool
    ) -> [TaskRow] {
        func projectRows(_ project: ProjectTasks) -> [TaskRow] {
            showBacklog ? activeRows(project) + backlogRows(project) : activeRows(project)
        }
        switch selection {
        case .smart(let view):
            return rows(in: projects, matching: view)
        case .project(let path):
            return projects.first { $0.projectPath == path }.map(projectRows) ?? []
        case .allProjects:
            return stackProjects.flatMap(projectRows)
        }
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

    /// The backlogged (deferred) plan rows for ONE project's card (#077).
    ///
    /// Maps the project's `backloggedTasks` (populated by `TaskParser` from the
    /// `.plans/backlog/` directory, in the parser's order) into `TaskRow`s
    /// carrying the owning project identity — mirroring `activeRows(_:)` exactly.
    /// This helper does NOT re-sort (it preserves `TaskParser`'s order) and
    /// performs no I/O or SwiftUI work. Consumed by `ProjectCard`'s optional
    /// "Backlogged" section, shown only while `store.showBacklog` is on.
    static func backlogRows(_ project: ProjectTasks) -> [TaskRow] {
        project.backloggedTasks.map { task in
            TaskRow(
                projectPath: project.projectPath,
                projectName: project.projectName,
                task: task
            )
        }
    }

    /// The clickable plan rows for ONE project's card (the "All projects" stack),
    /// FILTERED by task type (#076: per-card status/type filters).
    ///
    /// A `nil` `matchingType` is the pass-through case — it returns every active
    /// row unchanged (delegating to `activeRows(_:)`), so an unfiltered card and
    /// this helper agree. A non-nil `matchingType` keeps ONLY rows whose
    /// `task.type` equals it, preserving `TaskParser`'s order. Does NOT re-sort
    /// and performs no I/O or SwiftUI work.
    static func activeRows(_ project: ProjectTasks, matchingType: TaskType?) -> [TaskRow] {
        let rows = activeRows(project)
        guard let matchingType else { return rows }
        return rows.filter { $0.task.type == matchingType }
    }

    /// Whether `project` survives the current project view mode (#072): `.all`
    /// keeps everything and `.active` keeps only projects with outstanding work.
    ///
    /// Note the deliberate behavior change from the "Hide Empty" gate this
    /// replaced: that gate rescued a starred-but-empty project via an
    /// `|| isStarred` clause. There is no such clause here — `.active` means
    /// exactly "has outstanding work". Starred projects are reached through the
    /// sidebar's Favourites section (the `.starred` mode was dropped in #096).
    ///
    /// Pure value work — no I/O, no SwiftUI; drives `ProjectStackView.stackProjects`.
    static func visibleUnderViewMode(
        _ project: ProjectTasks,
        mode: ProjectViewMode
    ) -> Bool {
        switch mode {
        case .all: return true
        case .active: return project.hasOutstandingWork
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

    /// Computes the new manual order after a `List` `.onMove` (the sidebar's
    /// Projects section, #096): moves the rows at `offsets` to `destination`
    /// with SwiftUI's `move(fromOffsets:toOffset:)` semantics over `current`
    /// (the displayed path order). Out-of-range offsets — a stale move racing a
    /// project refresh — return `current` unchanged rather than trapping. Pure
    /// value work — no I/O.
    static func moveOrder(
        _ current: [String],
        fromOffsets offsets: IndexSet,
        toOffset destination: Int
    ) -> [String] {
        guard !offsets.isEmpty,
              let last = offsets.last, last < current.count,
              (0...current.count).contains(destination) else { return current }
        var result = current
        result.move(fromOffsets: offsets, toOffset: destination)
        return result
    }

    /// The SF Symbol for a project row in the combined sidebar "Projects"
    /// section (#097): a filled star when the project is starred, otherwise a
    /// folder. Pure value work — no I/O, no SwiftUI.
    static func sidebarGlyph(starred: Bool) -> String {
        starred ? "star.fill" : "folder"
    }

    /// Stable partition for the sidebar "Projects" section (#097): starred
    /// projects first, then the rest, each group keeping its incoming
    /// (recency / manual) relative order. Pure value work — no I/O.
    static func pinStarredFirst(_ projects: [ProjectTasks], starred: Set<String>) -> [ProjectTasks] {
        projects.filter { starred.contains($0.projectPath) }
            + projects.filter { !starred.contains($0.projectPath) }
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

    // MARK: - Smart views (#094)

    /// The cross-project rows for a smart view (#094). For
    /// `.inProgress/.review/.blocked/.failed` it filters over each project's
    /// `activeRows`; for `.backlog` it collects `backlogRows`. Review combines
    /// `.review` + `.inReview`. Project order is preserved, and within a project
    /// the parser's row order is preserved. Pure value work — no I/O, no SwiftUI.
    static func rows(in projects: [ProjectTasks], matching view: SmartView) -> [TaskRow] {
        switch view {
        case .backlog:
            return projects.flatMap { backlogRows($0) }
        case .inProgress:
            return projects.flatMap { activeRows($0) }
                .filter { $0.task.status == .inProgress }
        case .review:
            return projects.flatMap { activeRows($0) }
                .filter { $0.task.status == .review || $0.task.status == .inReview }
        case .blocked:
            return projects.flatMap { activeRows($0) }
                .filter { $0.task.isBlocked }
        case .failed:
            return projects.flatMap { activeRows($0) }
                .filter { $0.task.failure != nil }
        }
    }

    /// The currently-running (in-progress) plan rows across every project
    /// (#101), in project order — the source for the top-bar running-count
    /// indicator and its dropdown. A thin alias over `rows(in:matching:)` with
    /// the `.inProgress` lens so the indicator and the In-progress smart view
    /// never diverge. Pure value work — no I/O, no SwiftUI.
    static func runningPlanRows(in projects: [ProjectTasks]) -> [TaskRow] {
        rows(in: projects, matching: .inProgress)
    }

    // MARK: - Task staleness / sorting / grouping (#094)

    /// A POSIX `yyyy-MM-dd'T'HH:mm` parser for `Task.created` (#094). Cached as a
    /// static because `DateFormatter` construction is expensive. `parseLastSeen`'s
    /// ISO8601 parser CANNOT read this minute-precision `created` format, so a
    /// dedicated formatter is required.
    private static let createdMinuteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    /// A POSIX date-only `yyyy-MM-dd` fallback parser for `Task.created` (#094).
    private static let createdDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The staleness date for a task (#094): `Task.modified` when present
    /// (`Date(timeIntervalSinceReferenceDate:)`), else `Task.created` parsed with
    /// the minute-precision POSIX formatter, else the date-only POSIX formatter.
    /// Returns `nil` when none yields a date. Pure value work.
    static func taskStalenessDate(_ task: Task) -> Date? {
        if let modified = task.modified {
            return Date(timeIntervalSinceReferenceDate: modified)
        }
        guard let created = task.created?.trimmingCharacters(in: .whitespaces),
              !created.isEmpty else { return nil }
        if let date = createdMinuteFormatter.date(from: created) { return date }
        return createdDateFormatter.date(from: created)
    }

    /// Orders `rows` by `sort` (#094), STABLY (enumerate for a stable secondary
    /// key, like `sortByStaleness`). `.status` by `activePriority` descending;
    /// `.project` by `projectName` ascending; `.staleness` by `taskStalenessDate`
    /// NEWEST first with dateless rows LAST. Pure value work — no I/O, no SwiftUI.
    static func sortRows(_ rows: [TaskRow], by sort: TaskSort) -> [TaskRow] {
        rows.enumerated().sorted { lhs, rhs in
            switch sort {
            case .status:
                let l = lhs.element.task.status?.activePriority ?? -1
                let r = rhs.element.task.status?.activePriority ?? -1
                if l != r { return l > r }
                return lhs.offset < rhs.offset
            case .project:
                let l = lhs.element.projectName
                let r = rhs.element.projectName
                if l != r { return l < r }
                return lhs.offset < rhs.offset
            case .staleness:
                let lDate = taskStalenessDate(lhs.element.task)
                let rDate = taskStalenessDate(rhs.element.task)
                switch (lDate, rDate) {
                case let (l?, r?):
                    if l != r { return l > r }   // newest first
                    return lhs.offset < rhs.offset
                case (.some, .none):
                    return true                  // dated before dateless
                case (.none, .some):
                    return false
                case (.none, .none):
                    return lhs.offset < rhs.offset
                }
            }
        }
        .map(\.element)
    }

    /// Groups `rows` into titled sections by `group` (#094). `.status` collapses
    /// `.review` + `.inReview` into one "Review" section (and `nil` status into a
    /// trailing "Other" section); `.project` groups by `projectName`. Section
    /// order and within-section row order are STABLE (first-appearance order).
    /// Pure value work — no I/O, no SwiftUI.
    static func groupRows(
        _ rows: [TaskRow],
        by group: TaskGroup
    ) -> [(title: String, rows: [TaskRow])] {
        var order: [String] = []
        var buckets: [String: [TaskRow]] = [:]
        for row in rows {
            let title = sectionTitle(for: row, group: group)
            if buckets[title] == nil {
                buckets[title] = []
                order.append(title)
            }
            buckets[title]?.append(row)
        }
        return order.map { (title: $0, rows: buckets[$0] ?? []) }
    }

    /// The section title a row lands in for a grouping dimension (#094).
    private static func sectionTitle(for row: TaskRow, group: TaskGroup) -> String {
        switch group {
        case .project:
            return row.projectName
        case .status:
            switch row.task.status {
            case .review, .inReview: return "Review"
            case .some(let status): return status.filterLabel
            case .none: return "Other"
            }
        }
    }

    /// Resolves a sidebar selection against the live projects (#094): a
    /// `.project(path)` whose path is NOT among the live projects falls back to
    /// `.allProjects`. `.allProjects` and `.smart` are returned unchanged. Pure
    /// value work — no I/O, no SwiftUI.
    static func resolve(
        _ selection: SidebarSelection,
        in projects: [ProjectTasks]
    ) -> SidebarSelection {
        guard case .project(let path) = selection else { return selection }
        return projects.contains { $0.projectPath == path } ? selection : .allProjects
    }
}
