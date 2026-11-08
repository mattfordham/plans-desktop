import SwiftUI
import AppKit
import OSLog

private let cardLog = Logger(subsystem: "com.plans.desktop", category: "ProjectCard")

/// A single project rendered as a card in the browser's "All projects" stack
/// (`ProjectStackView`, Surface B's content column under the sidebar's "All
/// projects" entry, #096). Cards lay out at their natural, content-hugging
/// height; the stack's `ScrollView` absorbs any overflow.
///
/// The card has two parts:
///
/// - **Header:** the project name as a prominent heading plus a per-status count
///   summary. Iterating `TaskStatus.glanceOrder` (the TUI `STAT_CARDS` order,
///   `completed` excluded), each status with a non-zero `counts` entry shows its
///   real SF Symbol `Image(systemName: status.symbolName)` in
///   `status.glanceColor` next to the count. Every status is shown; zero-count
///   statuses are rendered dimmed (50% white) rather than dropped.
/// - **Body:** one tappable row per active plan from
///   `BrowserViewModel.activeRows(project)` (already non-completed and sorted by
///   `TaskParser`). Each row shows the task's status icon via the symbol-based
///   `TaskStatusIndicator` (blocked takes precedence), the short 3-char task id,
///   an optional `[type.label]` tag (`TaskType.label`), and the title. Tapping a
///   row shows that plan in the browser window's detail column (#073/#095, via
///   the injected `onOpenDetail` closure, which sets the browser's
///   `selectedRowID`) — it never opens a separate window. Tapping the header project name
///   reveals the project's nested `.plans` directory in Finder (#047). When
///   there are no active plans the body shows a muted empty state.
///
/// The card never writes `.plans/` itself (§2). It has no status pickers or How
/// checkboxes. The one way it changes files is its footer context menu (or a
/// click on the sync glyph), which asks the store to launch the plans-cc `plans-git.js` helper: "Sync plans
/// now" for branch-mode projects, and "Convert to tracked plans…" (`migrate`,
/// after confirmation) for local-mode ones (§2.1, §6.1).
struct ProjectCard: View {
    /// The project this card renders. Read-only; never mutated.
    let project: ProjectTasks

    /// #095: the browser's detail-column selection, so the matching plan row
    /// renders the selected highlight. `nil` (the default) highlights nothing.
    var selectedRowID: TaskRow.ID? = nil

    /// Opens the shared "New Plan" modal pre-selected to this card's project
    /// (#031). Invoked by the header "+" glyph with `project.projectPath`; the
    /// presenting `BrowserWindow` owns the sheet state. Replaces the former
    /// inline capture popover this card used to host itself.
    let onNewPlan: (String) -> Void

    /// #073/#095: shows a tapped row in the browser window's detail column,
    /// keyed on the row's composite `TaskRow.ID`. The presenting
    /// `BrowserWindow` owns the selection (`selectedRowID`); this closure just
    /// sets it. Replaces the former `openWindow(id:value:)` that opened a standalone
    /// detail WINDOW. Declared as a stored `let` alongside `onNewPlan` so the
    /// synthesized memberwise init threads it through.
    let onOpenDetail: (TaskRow.ID) -> Void

    /// The shared task store, re-read after a run's progress popover closes so the
    /// task's new status is surfaced by the existing read path. Read-only (§2).
    @Environment(PlansStore.self) private var store

    // #103: the card no longer reads `TaskRunner` directly — the in-flight
    // capture rows moved to the shared `CaptureProgressRows` view, which reads
    // the runner from the environment itself. (`PlanRowActions` likewise owns its
    // own `TaskRunner` access for the per-row Elaborate / Execute controls.)

    /// #068: which plan row the pointer is currently over, by task id, or `nil`
    /// when none is. At most one row is hovered at a time; each `planRow` reads
    /// it to add the hover-strength background shift over its resting zebra
    /// stripe (mirrors the single-selection `progressPopoverTaskID` pattern).
    @State private var hoveredRowID: String? = nil

    // #094: the five per-row action request vars and their `.sheet(item:)` modals
    // moved into the shared `PlanRowActions` view, which now owns that state so
    // the same action control can be rendered by the cross-project `TaskListRow`.

    /// #076: the active per-card task-type filter, or `nil` for "All" (no
    /// filtering). Purely view-local transient state (like `hoveredRowID` and the
    /// sheet requests) — it narrows only the body rows shown by this card and is
    /// NEVER persisted and NEVER mutates `.plans/` (§2 read-only). The header
    /// status counts stay unfiltered regardless of its value. Driven by the header
    /// filter `Menu`; consumed by the `rows` computed property through the pure
    /// `BrowserViewModel.activeRows(_:matchingType:)` helper.
    @State private var typeFilter: TaskType? = nil

    /// The clickable plan rows for this card: the active plans in `TaskParser`'s
    /// active order. Starring is a PROJECT-level concern (#035) that drives the
    /// sidebar's Favourites section and does not inject completed plans into
    /// the body, so this is just the active rows.
    private var rows: [TaskRow] {
        BrowserViewModel.activeRows(project, matchingType: typeFilter)
    }

    /// #077: the project's backlogged (deferred) plan rows, in `TaskParser`'s
    /// order. Rendered as a distinct, dimmed "Backlogged" section BELOW the active
    /// rows — but ONLY when `store.showBacklog` is on AND the project actually has
    /// backlog. The active rows and the header `statusCounts` are unaffected:
    /// backlog is excluded from the counts already, and these rows are an
    /// ADDITIONAL section, never a replacement for the active empty state. The
    /// header type filter deliberately does NOT narrow backlog — the toggle is a
    /// whole-card reveal, not a per-type one.
    private var backlogRows: [TaskRow] {
        BrowserViewModel.backlogRows(project)
    }

    /// Whether the dimmed "Backlogged" section should render on this card (#077):
    /// only when the user has turned the backlog reveal on AND the project has at
    /// least one backlogged task. Off by default, so a card is byte-for-byte
    /// identical to before whenever the toggle is off.
    private var showsBacklogSection: Bool {
        store.showBacklog && !project.backloggedTasks.isEmpty
    }

    /// #047: the file URL to reveal when the project name is tapped — the
    /// project's nested `.plans` directory. A pure, view-free seam (mirroring
    /// `PlanDetailView.taskFileURL`) so the URL construction is unit-tested as a
    /// plain value, while the header's `onTapGesture` hands the result to
    /// `NSWorkspace.activateFileViewerSelecting` to reveal it in Finder.
    static func finderURL(for projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath).appendingPathComponent(".plans")
    }

    // MARK: - Title-column sizing (#063 deterministic flexible title)

    /// The sizing decision for a plan row's flexible title column, extracted as a
    /// pure value so it is unit-testable without instantiating the view (mirrors
    /// `shouldScrollContent` / `finderURL`).
    ///
    /// #063: the title used to pin a magic `idealWidth: 1_000_000` sentinel to
    /// win the `Grid`'s flexible-width negotiation. Under a wide card holding a
    /// single short row the Grid couldn't satisfy that absurd ideal, its column
    /// negotiation degraded, the title collapsed to a sliver, and the row
    /// reflowed into a duplicated two-column look. This encodes the deterministic
    /// replacement: the title carries NO ideal width (`idealWidth == nil`), just
    /// stretches to `maxWidth: .infinity` to claim the width left after the fixed
    /// status/id/type cells, and is bounded by a 2-line limit + tail truncation
    /// so a long title wraps at most twice and then truncates instead of forcing
    /// the column to a sliver.
    struct TitleSizing {
        /// No magic sentinel — the title has no fixed ideal width.
        var idealWidth: CGFloat? = nil
        /// The title stretches to fill the remaining row width.
        var maxWidth: CGFloat = .infinity
        /// Bounded so a long title never collapses the flexible column.
        var lineLimit: Int = 2
        /// Overflow past the line limit truncates at the tail.
        var truncationMode: Text.TruncationMode = .tail
    }

    /// The single source of truth for the title column's sizing, consumed by
    /// `planRow` so the view and the tested decision cannot drift apart.
    static let titleSizing = TitleSizing()

    /// #063: a `planRow` always emits exactly these five columns — status icon
    /// / id / [type] / title / actions — aligned across rows into a table look.
    /// (#068 review: the row became an `HStack` with pinned `rowColumns` widths
    /// rather than a `GridRow`, but the five-column invariant is unchanged.)
    /// Pinned as a constant so the per-row column-count invariant is assertable
    /// without rendering the view.
    static let planRowCellCount = 5

    /// #068: the very subtle zebra-stripe + hover-shift styling for plan-table
    /// rows, extracted as a pure value so the exact opacities are unit-testable
    /// without rendering the view (mirrors `titleSizing` / `planRowCellCount`).
    /// The row background is `Color.primary.opacity(...)`, so these are the
    /// alpha values applied. Only odd rows are tinted at rest (an every-other-row
    /// band, not a flat wash); hovering any row shifts it to the stronger hover
    /// alpha. Both values are held well below a flat overlay so the effect stays
    /// "very subtle" and never dominates the card.
    struct RowStyling {
        /// Resting alpha for odd rows — the zebra band. Even rows get 0.
        var stripeOpacity: Double = 0.03
        /// Alpha for any hovered row, regardless of parity — the hover shift.
        var hoverOpacity: Double = 0.06

        /// The `Color.primary` alpha for a row: 0 for an even resting row, the
        /// stripe alpha for an odd resting row, and the (stronger) hover alpha
        /// for any hovered row. Hover reads at least as strong as the resting
        /// odd stripe by construction (`hoverOpacity >= stripeOpacity`).
        func backgroundOpacity(isEven: Bool, isHovered: Bool) -> Double {
            if isHovered { return hoverOpacity }
            return isEven ? 0 : stripeOpacity
        }

        /// #095/#105: the fill for the row currently shown in the browser's
        /// detail column — the system selection colour the sidebar uses for its
        /// selected row when it isn't focused (a neutral grey), so a selected
        /// row matches the sidebar rather than a translucent accent wash.
        /// Overrides the zebra/hover tint.
        var selectedColor: Color = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)

        /// The full row background: the selection fill when `isSelected`, else
        /// the subtle `Color.primary` zebra/hover tint.
        func background(isEven: Bool, isHovered: Bool, isSelected: Bool) -> Color {
            if isSelected { return selectedColor }
            return Color.primary.opacity(backgroundOpacity(isEven: isEven, isHovered: isHovered))
        }
    }

    /// The single source of truth for plan-row zebra + hover opacities, consumed
    /// by `planRow` so the view and the tested decision cannot drift apart.
    static let rowStyling = RowStyling()

    /// #068 review: pinned column widths for a plan row.
    ///
    /// The rows were originally a `Grid`, which auto-sized each column to the
    /// widest cell across all rows. That gave the table look but made a
    /// continuous row background impossible: `GridRow` is a layout declaration,
    /// so a `.background` written on it is propagated to each CELL, and every
    /// cell's backdrop tracks its own CONTENT rather than its allotted column
    /// width. A short `[bug]` badge sitting in a column sized for `[refactor]`
    /// left a wide unpainted channel, and a row with few action glyphs left its
    /// right edge untinted.
    ///
    /// So each row is now a real `HStack` view that owns ONE background, and the
    /// column alignment the Grid used to provide is reproduced with these pinned
    /// widths. They are a pure value so the layout decision stays unit-testable
    /// without rendering (mirrors `titleSizing` / `rowStyling`).
    struct RowColumns {
        /// Width of one character in the row's monospaced font (`.body`), used to
        /// size the id / type columns from their known character counts. The
        /// measured advance of the 13pt monospaced system face is ~8.04pt, so 8
        /// UNDER-states it: `[refactor]` came out 0.36pt wider than its pinned
        /// 80pt column and SwiftUI wrapped the badge onto a second line. Rounded
        /// up to 8.5 so the derived widths always have slack.
        var monospaceCharacterWidth: CGFloat = 8.5
        /// The leading status-glyph column (unchanged from the Grid layout).
        var statusWidth: CGFloat = 20
        /// The id column — plan ids are zero-padded to a MINIMUM of 3 digits, so
        /// past 999 they grow to `1000`, `10000`, … (#090). Sized for 5
        /// characters (a 5-digit id measures ~40.2pt, just over the old 40pt);
        /// ids are leading-aligned, so 3-digit ids line up exactly as before.
        var idWidth: CGFloat = 5 * 8.5
        /// Rendered width budgeted for the muted house (`⌂ kept`) marker (#086).
        /// The house SF Symbol at `.imageScale(.small)` in the `.body` face
        /// renders ~14pt wide; 16 gives a couple of points of slack so the icon
        /// never overflows the pinned type cell and overlaps the flexible title
        /// column beside it (`.frame(width:)` does not clip).
        var keptMarkerWidth: CGFloat = 16
        /// Inter-element gap INSIDE the type cell, between the `[type]` badge and
        /// the kept-worktree marker. Shared with `planRow`'s HStack spacing so the
        /// budgeted width and the rendered spacing are one source of truth (#086).
        var typeCellSpacing: CGFloat = 4
        /// The `[type]` column, pinned to fit the widest label (`[refactor]` —
        /// 8 characters plus 2 brackets) PLUS the kept-worktree marker and the
        /// gap before it (#086), so the widest badge WITH the house icon still
        /// fits the pinned cell and every badge occupies the same width.
        var typeWidth: CGFloat = 10 * 8.5 + 16 + 4
        /// The title column flexes, absorbing all remaining width so the row's
        /// single background reaches the trailing edge on every row.
        var titleMaxWidth: CGFloat = .infinity
        /// Spacing between columns. This is `HStack` spacing INSIDE the row's
        /// background, so it separates columns without breaking the band.
        var columnGap: CGFloat = 8
        /// The card's horizontal gutter (#087). Every NON-row element — header,
        /// footer, empty state, the "Backlogged" section label, and capture rows —
        /// is inset by this so it stays aligned with the row text, while the
        /// plan-row band ITSELF bleeds edge-to-edge to the card's rounded inner
        /// edge (the card no longer wraps all content in one horizontal padding).
        /// The single source of truth for that gutter.
        var cardHorizontalPadding: CGFloat = 14
        /// Trailing inset applied INSIDE the row background, so the band
        /// extends past the trailing action glyph rather than stopping flush
        /// against it.
        var rowHorizontalPadding: CGFloat = 8
        /// #105: leading inset applied INSIDE the row background. The row band
        /// runs flush to the column's leading edge (the stack is full-bleed, like
        /// the All Plans list), so the whole card gutter sits inside the band and
        /// the row TEXT lines up with the header/footer content.
        var rowLeadingInset: CGFloat { cardHorizontalPadding }
    }

    /// The single source of truth for plan-row column widths, consumed by
    /// `planRow` so the view and the tested decision cannot drift apart.
    static let rowColumns = RowColumns()

    /// The hover tooltip for a plan row whose latest run failed (#079), or `nil`
    /// when the plan is healthy (no failure overlay). Combines the failure summary
    /// (classification + stop reason, via `PlanDetailView.failureSummary`) with
    /// the run's error message on a second line when present. Pure so the copy is
    /// unit-testable without the view. A `nil` result means the row is healthy and
    /// the caller passes an empty `help` string (no tooltip).
    static func failureTooltip(for failure: TaskFailure?) -> String? {
        guard let failure else { return nil }
        let summary = PlanDetailView.failureSummary(failure)
        if let message = failure.errorMessage, !message.isEmpty {
            return "\(summary)\n\(message)"
        }
        return summary
    }

    /// The copy for the "Convert to tracked plans…" confirmation alert. The
    /// question is plans-cc's own `/plan-init branch` confirmation, verbatim.
    struct ConvertConfirmation: Equatable {
        let title: String
        let message: String
        let confirmButton: String
    }

    static let convertConfirmation = ConvertConfirmation(
        title: "Convert to tracked plans?",
        message: "Move `.plans/` onto a dedicated `plans` branch (pushed to `origin` when it exists)? "
            + "Every file is copied and verified before the backup is removed.",
        confirmButton: "Convert"
    )

    /// The copy for the alert reporting how a convert ended.
    struct ConvertReport: Equatable {
        let title: String
        let message: String
        let isError: Bool
    }

    /// Builds the report alert for a finished `migrate`: its `OK:` / `Error:`
    /// line, any warnings, and, when the helper kept a backup, where the
    /// user's original plans now are.
    static func convertReport(for result: PlansGitHelper.MigrateResult) -> ConvertReport {
        var lines: [String] = []
        let isError: Bool
        switch result.outcome {
        case .ok(let detail):
            isError = false
            lines.append("OK: \(detail)")
        case .error(let message, let backupPath):
            isError = true
            lines.append("Error: \(message)")
            if let backupPath {
                lines.append("Your original plans are intact at \(backupPath).")
            }
        case .helperMissing:
            isError = true
            lines.append("Error: the plans-cc helper was not found at \(PlansGitHelper.defaultHelperPath).")
        }
        lines += result.warnings.map { "Warning: \($0)" }
        return ConvertReport(
            title: isError ? "Convert to tracked plans failed" : "Converted to tracked plans",
            message: lines.joined(separator: "\n"),
            isError: isError
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // #105: the header is a `SectionHeaderBand`, the same band the
            // grouped task list uses for its group headers.
            header
            // The captures + plan list: the card's growable middle content,
            // laid out inline at natural height (the stack's ScrollView handles
            // overflow — the card has no inner scroll since #096).
            scrollableContent
            // Footer (#026 git status + #035 project star): the star toggle sits
            // bottom-LEFT and the git status (when present) bottom-RIGHT, across
            // from each other. Always emitted — the star is always available — so
            // the footer divider always renders (it no longer depends on the repo
            // being a git project). Mirrors the header's treatment: the header is
            // FOLLOWED by a `Divider()`; the footer is PRECEDED by one.
            Divider()
            ProjectFooter(project: project)
                // #087: re-inset by the card gutter — only the plan rows bleed full width.
                .padding(.horizontal, ProjectCard.rowColumns.cardHorizontalPadding)
                .padding(.vertical, 10)
        }
        // Bottom padding matches the header's 14pt top gap. The footer is now
        // always the bottom-most element (a plain HStack with no vertical padding
        // of its own), so it always needs the full 14pt.
        //
        // #087: NO card-wide horizontal padding. The plan-row band must bleed
        // edge-to-edge to the card's rounded inner edge, so instead of one shared
        // horizontal gutter here, each NON-row element (header, footer, empty
        // state, "Backlogged" label, capture rows) re-applies
        // `rowColumns.cardHorizontalPadding` itself — leaving only the plan rows
        // (and the dividers) full width.
        //
        // #105: no card surface at all — the project is a section of the
        // full-bleed stack, styled like the grouped task list: a header band,
        // zebra rows on the list background, then the footer.
        .frame(maxWidth: .infinity, alignment: .leading)
        // #094: the five per-row action `.sheet(item:)` modals moved into the
        // shared `PlanRowActions` view, which owns their request state now.
    }

    /// The growable middle content of the card: the in-flight capture rows, the
    /// active plan list and the optional backlog section, between the header and
    /// the git footer.
    @ViewBuilder
    private var scrollableContent: some View {
        // #103: the in-flight capture rows are now the shared `CaptureProgressRows`
        // view (also rendered by the single-project `TaskListView`), rendering
        // nothing when no captures run. #087: non-plan-row content, so re-inset by
        // the card gutter (only the plan rows bleed full width).
        CaptureProgressRows(projectPath: project.projectPath)
            .padding(.horizontal, ProjectCard.rowColumns.cardHorizontalPadding)
        body(for: rows)
        // #077: the optional backlog section sits BELOW the active plan list. It
        // is additive — the active `body(for:)` above (including its "No
        // outstanding plans" / "No matching plans" empty state) is untouched, so a
        // project with only backlog still shows the active empty state and then
        // this section beneath it. Gated on `showsBacklogSection`, so when the
        // toggle is off the card renders exactly as before with no extra chrome.
        if showsBacklogSection {
            backlogSection
        }
    }

    // MARK: - Backlog section (#077 deferred plans)

    /// The dimmed "Backlogged" section shown below the active plan rows when the
    /// window's backlog reveal is on and this project has deferred plans. A small
    /// section label distinguishes it from the active list, and the whole section
    /// is rendered at reduced opacity so it reads as secondary/deferred while its
    /// rows stay fully clickable (they reuse `planRow(_:index:)`, so tapping one
    /// opens the detail overlay exactly like an active row). The backlog rows get
    /// their OWN zero-based indexing so their zebra parity is independent of the
    /// active rows above them.
    @ViewBuilder
    private var backlogSection: some View {
        let rows = backlogRows
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "archivebox")
                    .imageScale(.small)
                Text("Backlogged")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
            }
            .foregroundStyle(.secondary)
            // #087: inset the section LABEL by the card gutter so it aligns with
            // the header/footer; the backlog `planRow`s below stay full-bleed like
            // the active rows.
            .padding(.horizontal, ProjectCard.rowColumns.cardHorizontalPadding)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    planRow(row, index: index)
                }
            }
        }
        // Deferred treatment: the whole section is dimmed so it reads as
        // secondary to the active plans while remaining interactive.
        .padding(.top, 10)
        .opacity(0.55)
    }

    // MARK: - Header (project name + per-status count summary)

    /// The card header: the project name plus the per-status count summary.
    /// Tapping the project name reveals the project's nested `.plans` directory
    /// in Finder (#047); otherwise only the plan rows below are clickable.
    private var header: some View {
        HStack(spacing: 8) {
            Text(project.projectName)
                .font(.headline)
                .lineLimit(1)
                .layoutPriority(1)
                // #047: tapping the project name reveals the project's nested
                // `.plans` directory in Finder. `contentShape(Rectangle())` makes
                // the full text bounds hit-test (not just the glyph pixels);
                // mirrors the `NSWorkspace.activateFileViewerSelecting` reveal
                // pattern in `PlanDetailView`.
                .contentShape(Rectangle())
                .onTapGesture {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [Self.finderURL(for: project.projectPath)]
                    )
                }
                .help("Open project's .plans directory in Finder")

            // Capture / execute control: placed immediately right of the project
            // name. "+" opens the popover and stays put so back-to-back captures
            // can be submitted; running captures surface as stacked rows below the
            // divider. (Git status moved to the footer in #026, so the header no
            // longer carries the branch block.)
            captureControl

            Spacer(minLength: 8)

            TaskTypeFilterMenu(selection: $typeFilter)

            ProjectStatusBadges(project: project)
        }
        // #105: the shared section-header band (gutter inset, band colour with
        // the space above, bottom separator).
        .modifier(SectionHeaderBand())
    }

    // MARK: - Capture ("+" new plan)

    /// The per-project plan-capture control, placed immediately after the project
    /// name in the header. A "+" `CaptureGlyph` that opens the shared "New Plan"
    /// modal pre-selected to this project (#031, via `onNewPlan`) — the modal,
    /// not this card, now owns the description form and hands the result to
    /// `TaskRunner.capture` (the bundled Agent-SDK process is the sole writer of
    /// `.plans/`, §2). Running captures still surface as stacked rows below the
    /// divider (`captureRows`).
    @ViewBuilder
    private var captureControl: some View {
        // A "+" glyph sized to match the header status badges
        // (`imageScale(.large)`, 20pt wide) rather than the smaller per-row
        // action glyphs, so it reads as a peer of the count badges. Same
        // tap-gesture primitive as `RowActionGlyph` (a nested borderless
        // Button hit-tests unreliably here — see the file header note).
        CaptureGlyph {
            onNewPlan(project.projectPath)
        }
    }

    // MARK: - Capture progress rows (#103 shared `CaptureProgressRows`)

    // The in-flight capture spinner rows were extracted into the shared
    // `CaptureProgressRows` view so the single-project `TaskListView` renders the
    // same live-capture source and reconcile-on-close hand-off (#103). The card
    // renders it from `scrollableContent`; see `CaptureProgressRows.swift`.

    // MARK: - Body (the active plan rows, or the empty state)

    /// The card body: a tappable row per active plan, or a muted empty state
    /// when there are none.
    @ViewBuilder
    private func body(for rows: [TaskRow]) -> some View {
        if rows.isEmpty {
            // #076: `body(for:)` receives the ALREADY-filtered rows, so an empty
            // list means one of two things. When a type filter is active
            // (`typeFilter != nil`) the project may well have outstanding work that
            // the filter is simply hiding, so show a distinct "No matching plans"
            // message rather than implying the work vanished. With no filter
            // (`typeFilter == nil`) an empty list genuinely means no outstanding
            // work, so keep the original "No outstanding plans" wording. Same
            // muted subheadline styling in both cases.
            Text(typeFilter == nil ? "No outstanding plans" : "No matching plans")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // #087: the empty state is non-row content, so re-inset by the
                // card gutter (only the plan rows bleed full width).
                .padding(.horizontal, ProjectCard.rowColumns.cardHorizontalPadding)
                .padding(.vertical, 10)
        } else {
            // #068 review: a `VStack` of `HStack` rows, NOT a `Grid`.
            //
            // The Grid auto-sized each column to the widest cell across all rows,
            // which gave the table look — but it made a continuous row background
            // impossible. `GridRow` is a layout declaration, so a `.background`
            // written on it is propagated to each CELL, and each cell's backdrop
            // tracks its own CONTENT rather than its allotted column width: a
            // short `[bug]` badge in a column sized for `[refactor]` left a wide
            // unpainted channel, and a row with few action glyphs left the row's
            // right edge untinted.
            //
            // Each row is now a real view that owns ONE background spanning the
            // full row, and the Grid's cross-row column alignment is reproduced by
            // the pinned widths in `ProjectCard.rowColumns`. #105: `spacing: 0` so
            // adjacent rows abut exactly — no sliver of gap around a hovered or
            // selected row.
            VStack(spacing: 0) {
                // #068: index-aware so each row knows its parity for the zebra
                // stripe. Keyed on `\.element.id` (NOT `\.offset`) so a row's
                // SwiftUI identity remains its `TaskRow.ID` — reordering/removing
                // rows still animates and preserves per-row state correctly.
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    planRow(row, index: index)
                }
            }
        }
    }

    /// A single tappable plan row as a `GridRow`: the status icon (blocked takes
    /// precedence), the short 3-char task id, an always-present `[type]` cell,
    /// and the title. The whole row is the tap target — tapping opens the plan's
    /// detail in the browser window's detail column (#073/#095, via the
    /// injected `onOpenDetail` closure).
    ///
    /// Implementation notes (#068 review: the row is an `HStack` with pinned
    /// `rowColumns` widths rather than a `GridRow` in a `Grid`, so it can own one
    /// continuous background — wrapping the row in a Button would defeat that):
    ///
    /// - The `[type]` column is ALWAYS emitted (an empty monospaced `Text` when
    ///   `row.type` is nil) so column 3 exists in every row and stays aligned.
    /// - The hit-test shape and tap gesture are applied per column (see
    ///   `OpenDetailOnTap`), leaving the trailing action button its own hit
    ///   target. The inter-column gap is the `HStack`'s own `columnGap` spacing,
    ///   which sits inside the row's background and so never breaks the band.
    /// - `.padding(.vertical, 5)` on the row sets its height/tap area.
    ///   We deliberately do NOT use `.frame(maxHeight: .infinity)` here: that makes
    ///   each row a greedy vertical slack-absorber that would spread any extra
    ///   height the card is given across the rows. Rows stay content-sized.
    @ViewBuilder
    private func planRow(_ row: TaskRow, index: Int) -> some View {
        let indicator = row.indicator
        let typeText = row.type.map { "[\($0.label)]" } ?? ""
        // #068: parity drives the resting zebra stripe; hover strengthens it.
        let isEven = index.isMultiple(of: 2)
        let isHovered = hoveredRowID == row.task.id

        // #068 review: an `HStack` (not a `GridRow`) so the row is a real view
        // that can own ONE background spanning its full width. Column alignment
        // across rows comes from the pinned `ProjectCard.rowColumns` widths.
        HStack(spacing: ProjectCard.rowColumns.columnGap) {
            Image(systemName: indicator.symbolName)
                .imageScale(.large)
                .foregroundStyle(indicator.color)
                .frame(width: ProjectCard.rowColumns.statusWidth, alignment: .center)
                // #079: when the latest run for this plan failed, the indicator is
                // already the red alarm glyph (via `row.indicator`'s `isFailed`);
                // add a tooltip surfacing the classification + error message so a
                // hover explains WHY it is red — mirrors the `captureRow` failed
                // help-tooltip pattern.
                .help(ProjectCard.failureTooltip(for: row.task.failure) ?? "")
                .modifier(OpenDetailOnTap(row: row, onOpenDetail: onOpenDetail))

            Text(row.task.id)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                // An id is one token; never wrap a wide (4+ digit) id.
                .lineLimit(1)
                .frame(width: ProjectCard.rowColumns.idWidth, alignment: .leading)
                .modifier(OpenDetailOnTap(row: row, onOpenDetail: onOpenDetail))

            // Always-present cell (empty string when no type) so the title column
            // starts at the same x on every row. A kept-worktree task (executed
            // with the `keep` keyword) appends a muted house glyph after the type
            // badge — the desktop analogue of the plans-cc dashboard TUI's
            // `⌂ kept` marker. The `**Worktree:**` field (and thus
            // `isKeptWorktree`) can ALSO appear on in-progress tasks executing in
            // a worktree, so it is `showsKeptWorktreeMarker` — not
            // `isKeptWorktree` — that restricts the display to review-state rows
            // (#086). The icon has a `help` tooltip since it renders label-free.
            // The pinned width fits the widest label (`[refactor]`) PLUS the
            // marker and its gap (`RowColumns.typeWidth`), so a short badge no
            // longer leaves the row's background with an unpainted channel beside
            // it and the widest badge's icon never overflows onto the title.
            HStack(spacing: ProjectCard.rowColumns.typeCellSpacing) {
                Text(typeText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    // The badge is a fixed short token; it must never wrap or
                    // truncate even if the pinned column is a hair too narrow
                    // for the rendered face (see `monospaceCharacterWidth`).
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

            // The title is the row's flexible column: it claims the width left
            // after the pinned status/id/type columns and wraps only when that
            // runs out. #063: the sizing is deterministic and never negotiated via
            // a magic ideal width — the old `idealWidth: 1_000_000` hack degraded
            // under a wide card holding a single short row, collapsing the title
            // to a sliver. The title carries NO ideal width and simply stretches
            // to `maxWidth: .infinity`, with a bounded `lineLimit(2)` + tail
            // truncation so a long title wraps at most twice and then truncates.
            // The sizing decision lives in the pure `ProjectCard.titleSizing`
            // helper so the view and its unit test share one source of truth.
            Text(row.title ?? "(untitled)")
                .font(.body)
                .lineLimit(ProjectCard.titleSizing.lineLimit)
                .truncationMode(ProjectCard.titleSizing.truncationMode)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: ProjectCard.titleSizing.maxWidth, alignment: .leading)
                .modifier(OpenDetailOnTap(row: row, onOpenDetail: onOpenDetail))

            // Trailing per-row action: the single status-relevant Elaborate /
            // Execute icon button (or an inline spinner while THIS row is being
            // worked). It deliberately does NOT carry the open-detail tap gesture
            // (which lives on the content cells above) so the control's own tap is
            // never swallowed by a row-level gesture. #094: extracted into the
            // shared `PlanRowActions` view (which owns its own action-sheet state)
            // so the identical control also serves the cross-project `TaskListRow`.
            PlanRowActions(row: row)
        }
        // `.padding(.vertical, 5)` sets the row's height/tap area. The open-detail
        // tap gesture is applied per column (see `OpenDetailOnTap`) rather than
        // once to the whole row, so the trailing action button keeps its own
        // independent hit target.
        .padding(.vertical, 5)
        // #068 review: horizontal inset applied BEFORE the background, so the
        // band extends past the row's content on both edges instead of stopping
        // flush against the leading status glyph and the trailing action glyph.
        // #105: the full card gutter sits inside the band on the leading side so
        // the band runs flush to the column edge, exactly like `TaskListRow`.
        .padding(.leading, ProjectCard.rowColumns.rowLeadingInset)
        .padding(.trailing, ProjectCard.rowColumns.rowHorizontalPadding)
        // #068: ONE very-subtle zebra + hover band for the whole row. Because the
        // row is an `HStack` (a real view) rather than a `GridRow`, this is a
        // single rectangle covering the full row — content plus its vertical
        // padding, edge to edge — instead of a set of per-cell backdrops that
        // followed each cell's own content. Adjacent striped rows abut across the
        // enclosing `VStack(spacing: 0)` so the zebra reads as continuous bands.
        // The tint sits BEHIND the content and carries no gesture, leaving the
        // per-column `OpenDetailOnTap` seams and the trailing action button's own
        // hit target untouched. `.onHover` tracks the single hovered row id;
        // `.animation` eases the stripe/hover crossfade (mirrors
        // `RowActionGlyph`'s hover timing).
        .background(
            ProjectCard.rowStyling.background(
                isEven: isEven,
                isHovered: isHovered,
                isSelected: selectedRowID == row.id
            )
            // #095: the painted band is also the row's fallback tap target, so a
            // click in the vertical padding, the column gaps, or a cell's blank
            // space selects the plan instead of landing on nothing.
            .modifier(OpenDetailOnTap(row: row, onOpenDetail: onOpenDetail))
        )
        .onHover { hovering in
            hoveredRowID = hovering ? row.task.id : nil
        }
        .animation(.easeOut(duration: 0.12), value: hoveredRowID)
    }



}

/// The project footer row shared by a `ProjectCard` and the single-project
/// `TaskListView` (#098): git status + plans-sync glyph bottom-left, the project
/// star bottom-right, and the plans-storage context menu. Callers apply their
/// own horizontal inset.
struct ProjectFooter: View {
    let project: ProjectTasks

    @Environment(PlansStore.self) private var store

    /// The card footer row: the git status (when the project is a git repo)
    /// pinned bottom-LEFT and the project toggles bottom-RIGHT, across from
    /// each other. Git status is leading-aligned and the `Spacer` pushes the
    /// star toggle to the trailing edge; a non-git project simply shows the star
    /// alone. (#096 removed the focus toggle that sat beside the star.)
    var body: some View {
        HStack(spacing: 8) {
            gitFooter
            Spacer(minLength: 8)
            starToggle
        }
        .contextMenu { plansStorageActions }
    }

    /// The plans-storage actions offered from the footer's context menu: a
    /// manual sync for branch-mode projects, and converting a local-mode project
    /// with a remote to branch mode. Empty for every other project.
    @ViewBuilder
    private var plansStorageActions: some View {
        if project.plansMode == .branch {
            Button("Sync plans now") {
                store.syncNow(projectPath: project.projectPath)
            }
            .disabled(store.syncSkipReason(for: project.projectPath, trigger: .manual) != nil)
        }
        if store.convertSkipReason(for: project.projectPath) == nil {
            Button("Convert to tracked plans…") {
                confirmAndConvert()
            }
        }
    }

    /// Asks for confirmation, then runs the migrate and reports its outcome.
    /// Never retries: a failed convert leaves the user to read the error.
    private func confirmAndConvert() {
        let confirmation = ProjectCard.convertConfirmation
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.addButton(withTitle: confirmation.confirmButton)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let started = store.convertToTrackedPlans(projectPath: project.projectPath) { result in
            let report = ProjectCard.convertReport(for: result)
            let reportAlert = NSAlert()
            reportAlert.alertStyle = report.isError ? .warning : .informational
            reportAlert.messageText = report.title
            reportAlert.informativeText = report.message
            reportAlert.addButton(withTitle: "OK")
            reportAlert.runModal()
        }
        if !started {
            cardLog.notice("convert not started for \(project.projectPath, privacy: .public)")
        }
    }

    /// The branch-mode sync glyph, or the in-flight convert spinner. Tapping
    /// the glyph syncs now (bypassing the debounce and any conflict back-off)
    /// when a manual sync is allowed.
    @ViewBuilder
    private var plansSyncIndicator: some View {
        if store.pausedPaths.contains(project.projectPath) {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Converting plans…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help("Moving .plans onto a dedicated plans branch")
        } else if let state = PlansSyncState.resolve(
            mode: project.plansMode,
            status: project.plansSync,
            lastOutcome: store.lastSyncResult(for: project.projectPath)?.outcome,
            isSyncing: store.syncingPaths.contains(project.projectPath)
        ) {
            let canSync = store.syncSkipReason(for: project.projectPath, trigger: .manual) == nil
            let tooltip = PlansSyncState.tooltip(
                for: state,
                status: project.plansSync,
                lastResult: store.lastSyncResult(for: project.projectPath)
            )
            HStack(spacing: 2) {
                Image(systemName: state.symbolName)
                    .imageScale(.small)
                    .foregroundStyle(state.color)
                if let counts = state.countText {
                    Text(counts)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(state.color)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if canSync {
                    store.syncNow(projectPath: project.projectPath)
                }
            }
            .help(canSync ? tooltip + "\nClick to sync plans now." : tooltip)
        }
    }

    /// The card's git status — the branch glyph + name plus
    /// an orange dirty dot when the working tree is known-dirty (#026 moved this
    /// out of the header). Rendered only when the project is a git repo
    /// (`gitBranch != nil`); a `nil`/`false` `gitIsDirty` shows no dot. The
    /// branch text truncates so it never crowds the card.
    @ViewBuilder
    private var gitFooter: some View {
        if let branch = project.gitBranch {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(branch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if project.gitIsDirty == true {
                    Image(systemName: "circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.orange)
                }
                plansSyncIndicator
            }
        }
    }

    /// The project star/unstar toggle (#035). A filled yellow `star.fill` when
    /// this project's path is in `store.starredProjectPaths`, otherwise an outline
    /// `star`. Tapping toggles membership of `project.projectPath` in the persisted
    /// set (`insert`/`remove` triggers the store's `didSet` persistence). Starred
    /// projects are listed in the sidebar's Favourites section (#094); the card
    /// stack's `.starred` view mode that once filtered on them was dropped in #096.
    @ViewBuilder
    private var starToggle: some View {
        let isStarred = store.starredProjectPaths.contains(project.projectPath)
        StarToggleGlyph(
            isStarred: isStarred,
            help: isStarred ? "Unstar project" : "Star project"
        ) {
            if store.starredProjectPaths.contains(project.projectPath) {
                store.starredProjectPaths.remove(project.projectPath)
            } else {
                store.starredProjectPaths.insert(project.projectPath)
            }
        }
    }
}

/// The task-type filter `Menu` shared by a `ProjectCard` header and the
/// single-project `TaskListView` (#098), bound to the caller's view-local filter.
struct TaskTypeFilterMenu: View {
    /// #076: the per-card task-type filter control, placed in the header between
    /// the `Spacer` and the (unfiltered) status count badges — i.e. to the LEFT of
    /// the counts, so the badges keep the right edge they share with every other
    /// card and the filter reads as a control rather than another readout. A
    /// `Menu` modelled on
    /// the `ProjectViewMode` ("All / Active / Starred") toolbar select in
    /// `BrowserWindow`: an "All" reset entry (clears the filter) plus one entry per
    /// `TaskType.allCases`, each a `Label` pairing the type's SF `symbolName` with
    /// its text `label`.
    ///
    /// Like that select, the menu's own label renders the current selection as
    /// visible TEXT beside its symbol (`.titleAndIcon`) rather than a bare glyph —
    /// an unlabeled icon can't say WHICH type is active, which is the whole point
    /// of the control. Unfiltered it reads "All"; filtered it reads the type's
    /// symbol + name, accent-tinted while the list is actually narrowed. SF
    /// Symbols (not the emoji `glyph`) so it matches the native toolbar chrome.
    ///
    /// Purely view state (§2 read-only): selecting an entry only sets the local
    /// `selection`, which the `rows` computed property feeds through the pure
    /// `BrowserViewModel.activeRows(_:matchingType:)` helper. It NEVER mutates
    /// `.plans/` and does NOT touch the header `statusCounts`.
    @Binding var selection: TaskType?

    var body: some View {
        Menu {
            Button {
                selection = nil
            } label: {
                Label("All", systemImage: "square.grid.2x2")
            }
            ForEach(TaskType.allCases, id: \.self) { type in
                Button {
                    selection = type
                } label: {
                    Label(type.label, systemImage: type.symbolName)
                }
            }
        } label: {
            Label(
                selection?.label ?? "All",
                systemImage: selection?.symbolName ?? "square.grid.2x2"
            )
            .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(selection == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
        .help("Filter plans by type")
    }
}

/// The per-status count badges for one project, in `glanceOrder` (#098: shared
/// by the card header and the single-project `TaskListView`). Zero-count
/// statuses dim to 10% white so they read as present-but-empty; non-zero keep
/// the vivid glance hue. `fixedSize` so a narrow container never squeezes the
/// counts into clipped stubs.
struct ProjectStatusBadges: View {
    let project: ProjectTasks

    var body: some View {
        HStack(spacing: 8) {
            ForEach(BrowserViewModel.statusCounts(project), id: \.status) { entry in
                HStack(spacing: 4) {
                    Image(systemName: entry.status.symbolName)
                        .imageScale(.large)
                        .foregroundStyle(entry.count == 0 ? Color.white.opacity(0.1) : entry.status.glanceColor)
                        .frame(width: 20, alignment: .center)
                    Text("\(entry.count)")
                        .font(.body)
                        .foregroundStyle(entry.count == 0 ? Color.white.opacity(0.1) : Color.secondary)
                }
            }
        }
        .fixedSize()
    }
}

/// The project star/unstar glyph (#035). A `Button` with `.buttonStyle(.plain)`
/// using a solid `star.fill` in BOTH states; only the white opacity changes —
/// medium when starred, very low when not (brightening slightly on hover) — so
/// an unstarred project reads as a faint filled star that lights up on hover and
/// reads as a clearly-filled medium-white star when starred. Adds a subtle hover
/// background + cursor like `RowActionGlyph`.
private struct StarToggleGlyph: View {
    let isStarred: Bool
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "star.fill")
                .imageScale(.medium)
                .foregroundStyle(Color.white.opacity(isStarred ? 0.6 : (hovering ? 0.35 : 0.15)))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(hovering ? 0.10 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The header "+" capture glyph. Like `RowActionGlyph` (same hover/press
/// feedback and tap-gesture primitive — a nested borderless `Button` hit-tests
/// unreliably in this layout), but sized to match the header status badges
/// (`imageScale(.large)`) rather than the smaller per-row action glyphs, so it
/// reads as a peer of the count badges sitting in the same header row.
private struct CaptureGlyph: View {
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Image(systemName: "plus.circle")
            .imageScale(.large)
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(pressed ? 0.18 : (hovering ? 0.10 : 0)))
            )
            .scaleEffect(pressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { value in
                        pressed = false
                        let bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
                        if bounds.contains(value.location) { action() }
                    }
            )
            .onHover { hovering = $0 }
            .help("Capture a new plan")
    }
}

/// Applies "open this plan's detail pane on tap" to a single row content cell.
/// Used per content cell (id / type / title / status icon) rather than once on
/// the whole `GridRow`, so the trailing action button keeps an independent hit
/// target instead of competing with a row-wide tap gesture.
///
/// #073: taps invoke the injected `onOpenDetail(row.id)` closure, which sets the
/// browser window's `selectedRowID` so its detail column shows the plan (#095).
/// This replaced the earlier design, in which the tap called `openWindow(id:value:)`
/// to open a standalone detail window; that window's scene no longer exists.
///
/// #094: no longer `private` so the cross-project `TaskListRow` reuses the same
/// tap-to-open-detail seam the card rows use.
///
/// #095: it is ALSO applied to each row's background band. Without that, only
/// the cells' own frames were tappable, so a click in the row's vertical
/// padding, the gaps between columns, or the horizontal inset did nothing even
/// though that area is drawn as part of the hovered row. Because the band sits
/// BEHIND the row content, it only receives clicks that hit nothing in front of
/// it, so it never takes a click meant for the trailing action control.
struct OpenDetailOnTap: ViewModifier {
    let row: TaskRow
    let onOpenDetail: (TaskRow.ID) -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { onOpenDetail(row.id) }
    }
}

#if DEBUG
/// #063 reproduction preview: a single project with ONE short active task, laid
/// out in a WIDE fixed frame. This is the exact triggering condition for the
/// duplicated-column / collapsed-title symptom reported on the "Ensemble" card:
/// a wide card whose Grid has only one (short) row negotiates its flexible title
/// column poorly. With no other row demanding width, the Grid can size the title
/// column to the multi-line `Text`'s IDEAL width (roughly its longest word) and
/// let the `.frame(idealWidth: 1_000_000, maxWidth: .infinity)` hack at
/// `planRow` (see the title cell in `planRow`) collapse — the title shrinks to a
/// sliver and the row reflows into the two-column look.
///
/// Trigger recipe (static, determinable without running):
///   - exactly ONE active task (single `GridRow`)
///   - a short title (few words, so its ideal width is tiny)
///   - a WIDE card frame (900pt below) so there is a large surplus of width for
///     the degenerate column negotiation to mis-allocate
///
/// Wrapped in `#if DEBUG` and left un-verified — visual confirmation happens in
/// review. Building the package proves the preview compiles.
#Preview("063 — single wide row (collapsed title)") {
    let task = Task(
        id: "611",
        title: "Ensemble task",
        type: .feature,
        status: .pending,
        created: nil,
        branch: nil,
        isKeptWorktree: false,
        blockedBy: [],
        sections: [],
        howProgress: (done: 0, total: 0),
        isBlocked: false,
        isCompletedDir: false,
        isBacklogged: false
    )
    let project = ProjectTasks(
        projectPath: "/tmp/Ensemble",
        projectName: "Ensemble",
        lastSeen: "",
        tasks: [task],
        counts: [.pending: 1],
        activeTasks: [task],
        gitBranch: "main",
        gitIsDirty: false
    )
    return ProjectCard(project: project, onNewPlan: { _ in }, onOpenDetail: { _ in })
        .environment(PlansStore())
        .environment(TaskRunner())
        // The WIDE frame is the load-bearing part of the repro: a narrow card
        // does not exhibit the collapse.
        .frame(width: 900)
        .padding()
}
#endif
