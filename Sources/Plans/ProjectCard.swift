import SwiftUI
import AppKit
import OSLog

private let cardLog = Logger(subsystem: "com.plans.desktop", category: "ProjectCard")

/// Surface C: a single project rendered as a discrete dashboard card.
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
///   row opens that plan's detail in the browser window's in-window modal overlay
///   pane (#073, via the injected `onOpenDetail` closure) — it no longer sets a
///   selection or opens a separate window. Tapping the header project name
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

    /// The fixed cell height imposed on this card by `BrowserWindow.cardGrid` in
    /// fit-to-screen ("grid") layout, or `nil` in scroll layout (#038).
    ///
    /// When non-nil the card is height-constrained, so its body scrolls
    /// internally (`shouldScrollContent`) rather than overflowing the cell. When
    /// `nil` the card lays out at its natural, content-hugging height exactly as
    /// before. Defaulted to `nil` so existing call sites stay source-compatible;
    /// declared BEFORE `onNewPlan` so the synthesized memberwise initializer is
    /// `ProjectCard(project:constrainedHeight:onNewPlan:)` and the trailing-closure
    /// call site keeps working.
    var constrainedHeight: CGFloat? = nil

    /// Opens the shared "New Plan" modal pre-selected to this card's project
    /// (#031). Invoked by the header "+" glyph with `project.projectPath`; the
    /// presenting `BrowserWindow` owns the sheet state. Replaces the former
    /// inline capture popover this card used to host itself.
    let onNewPlan: (String) -> Void

    /// #073: opens the plan-detail modal overlay pane in the browser window for a
    /// tapped row, keyed on the row's composite `TaskRow.ID`. The presenting
    /// `BrowserWindow` owns the pane state (`detailRowID`); this closure just sets
    /// it. Replaces the former `openWindow(id:value:)` that opened a standalone
    /// detail WINDOW. Declared as a stored `let` alongside `onNewPlan` so the
    /// synthesized memberwise init threads it through.
    let onOpenDetail: (TaskRow.ID) -> Void

    /// The shared task store, re-read after a run's progress popover closes so the
    /// task's new status is surfaced by the existing read path. Read-only (§2).
    @Environment(PlansStore.self) private var store

    /// The shared "Work this task" runner, for the per-row Elaborate / Execute
    /// icon buttons and inline running status. Reads only — the run itself is the
    /// sole writer of `.plans/` (§2), driven by the bundled Agent-SDK process.
    @Environment(TaskRunner.self) private var runner

    /// Which row's run-progress popover is currently open, by task id, or `nil`
    /// when none is. At most one progress popover is open at a time per card; the
    /// per-task `Binding<Bool>` from `progressPopover(for:)` drives the `.popover`
    /// on each row's spinner.
    @State private var progressPopoverTaskID: String? = nil

    /// #068: which plan row the pointer is currently over, by task id, or `nil`
    /// when none is. At most one row is hovered at a time; each `planRow` reads
    /// it to add the hover-strength background shift over its resting zebra
    /// stripe (mirrors the single-selection `progressPopoverTaskID` pattern).
    @State private var hoveredRowID: String? = nil

    /// The pending "Refine Plan" request (#056), or `nil` when no Refine sheet is
    /// open. Set by a row's Refine glyph (elaborated, non-blocked tasks only) to
    /// that row's task id + project path; an `.sheet(item:)` keyed on it presents
    /// the `ReElaborateModal` for exactly that task. An `Identifiable` struct
    /// (rather than a bare bool + separate id) so the sheet always targets the
    /// right row even if several elaborated rows are present.
    @State private var reElaborateRequest: ReElaborateRequest? = nil

    /// The pending "Elaborate" request (#074), or `nil` when no Elaborate sheet
    /// is open. Set by a row's Elaborate glyph (pending, non-blocked tasks only)
    /// to that row's task id + project path; an `.sheet(item:)` keyed on it
    /// presents the `ElaborateModal` for exactly that task. Mirrors
    /// `reElaborateRequest` — an `Identifiable` struct rather than a bare bool +
    /// separate id, so the sheet always targets the right row even if several
    /// pending rows are present.
    @State private var elaborateRequest: ElaborateRequest? = nil

    /// The pending "Execute" request (#078), or `nil` when no Execute sheet is
    /// open. Set by a row's Execute glyph (elaborated/in-progress, non-blocked
    /// tasks only) to that row's task id + project path; an `.sheet(item:)` keyed
    /// on it presents the `ExecuteModal` for exactly that task. Mirrors
    /// `elaborateRequest` — an `Identifiable` struct rather than a bare bool +
    /// separate id, so the sheet always targets the right row even if several
    /// executable rows are present.
    @State private var executeRequest: ExecuteRequest? = nil

    /// The pending direct-"Execute" request (#088), or `nil` when no direct-Execute
    /// sheet is open. Set by a pending (un-elaborated) row's `play.fill` glyph to
    /// that row's task id + project path; an `.sheet(item:)` keyed on it presents
    /// the `ExecutePendingModal` for exactly that task. Mirrors `executeRequest` —
    /// a distinct `Identifiable` struct so this sheet stays independently keyed
    /// from the elaborated-plan Execute sheet and can never present against it.
    @State private var executePendingRequest: ExecutePendingRequest? = nil

    /// The pending "Re-elaborate for review" request (#091), or `nil` when no
    /// review-Refine sheet is open. Set by a review-state (review/in-review),
    /// non-blocked row's `sparkles` glyph to that row's task id + project path; an
    /// `.sheet(item:)` keyed on it presents the `ReviewReElaborateModal` for exactly
    /// that task, which resets the plan to pending and re-elaborates it. Mirrors
    /// `reElaborateRequest` — a distinct `Identifiable` struct so this sheet stays
    /// independently keyed from the elaborated-plan Refine sheet and can never
    /// present against it.
    @State private var reviewReElaborateRequest: ReviewReElaborateRequest? = nil

    /// #076: the active per-card task-type filter, or `nil` for "All" (no
    /// filtering). Purely view-local transient state (like `hoveredRowID` and the
    /// sheet requests) — it narrows only the body rows shown by this card and is
    /// NEVER persisted and NEVER mutates `.plans/` (§2 read-only). The header
    /// status counts stay unfiltered regardless of its value. Driven by the header
    /// filter `Menu`; consumed by the `rows` computed property through the pure
    /// `BrowserViewModel.activeRows(_:matchingType:)` helper.
    @State private var typeFilter: TaskType? = nil

    /// A per-task `Binding<Bool>` for the run-progress popover: it reads `true`
    /// only when `progressPopoverTaskID` is this `taskID`, and on set assigns the
    /// id when raised / clears it when lowered — so opening one row's popover (or
    /// the popover dismissing itself) drives the single shared state.
    private func progressPopover(for taskID: String) -> Binding<Bool> {
        Binding(
            get: { progressPopoverTaskID == taskID },
            set: { progressPopoverTaskID = $0 ? taskID : nil }
        )
    }

    /// The status counts to show in the header, in `glanceOrder`. EVERY status
    /// is included; statuses absent from `counts` or with a `0` count surface as
    /// a `0` and are rendered dimmed (50% white) rather than dropped.
    private var statusCounts: [(status: TaskStatus, count: Int)] {
        TaskStatus.glanceOrder.map { status in
            (status, project.counts[status] ?? 0)
        }
    }

    /// The clickable plan rows for this card: the active plans in `TaskParser`'s
    /// active order. Starring is now a PROJECT-level concern (#035) — it keeps an
    /// empty card visible under the `.starred` view mode but does not inject
    /// completed plans into the body — so this is just the active rows.
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

    // MARK: - Layout decision (scroll the body when height-constrained)

    /// Whether the card should scroll its body internally instead of laying it
    /// out at natural height.
    ///
    /// #038: in fit-to-screen ("grid") card layout, `BrowserWindow.cardGrid`
    /// imposes a FIXED per-row cell height on each card (the non-nil
    /// `constrainedHeight`). A project with many plans has a natural content
    /// height taller than that imposed frame, so without an inner scroll its plan
    /// list overflows the cell and overlaps the card beneath it. In scroll mode
    /// the card is handed `nil` (no imposed height) and lays out at its natural,
    /// content-hugging size while the surrounding `ScrollView` absorbs overflow.
    ///
    /// So the rule is purely: a non-nil imposed height → scroll the body inside
    /// the card (`true`); `nil` → natural height, no inner scroll (`false`). Any
    /// non-nil value (including `0`) counts as "constrained". Pure and view-free
    /// so the decision is unit-tested as a plain value, mirroring the layout
    /// helpers in `BrowserWindow`.
    static func shouldScrollContent(constrainedHeight: CGFloat?) -> Bool {
        constrainedHeight != nil
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
        /// Margin between the card's LEADING edge and the start of the row band
        /// (#087 review), so the band doesn't sit flush against the card's left
        /// border. The band still bleeds to the trailing edge.
        var rowBandLeadingMargin: CGFloat = 6
        /// Horizontal inset applied INSIDE the row background, so the band
        /// extends past the leading status glyph and the trailing action glyph
        /// rather than stopping flush against them. Together with
        /// `rowBandLeadingMargin` it sums to the card gutter (#087) so the row
        /// TEXT lines up with the re-inset header/footer content.
        var rowHorizontalPadding: CGFloat = 8
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
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            // #038: the captures + plan list are the only growable content. When
            // the card is height-constrained (fit/grid mode imposes a fixed cell
            // height) a long list would overflow the cell and overlap the card
            // beneath it, so wrap that middle content in a `ScrollView` — header
            // stays pinned at the top, git footer pinned at the bottom, and the
            // list scrolls between them. The ScrollView greedily fills the slack
            // between header and footer, so no `Spacer` is needed in this path.
            //
            // In scroll mode (`constrainedHeight == nil`) the card lays out at its
            // natural, content-hugging height and the surrounding `ScrollView` in
            // `BrowserWindow.cardGrid` handles overflow, so render the content
            // inline (NO inner ScrollView) and keep the trailing `Spacer` that
            // pins header to the top and footer to the bottom of a taller cell —
            // byte-for-byte unchanged from before.
            if ProjectCard.shouldScrollContent(constrainedHeight: constrainedHeight) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        scrollableContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // #046: trailing inset so the per-row action buttons clear the
                    // card-internal overlay scroller (this inner ScrollView only
                    // exists in fit-to-screen mode). Reuses the shared clearance
                    // constant so it tracks the outer grid's value.
                    .padding(.trailing, BrowserWindow.scrollerClearance)
                }
            } else {
                scrollableContent
                // Top-anchor the header + body and bottom-anchor the footer:
                // LazyVGrid sizes every cell to its ROW's max height, so a short
                // card handed a taller cell has slack to distribute. This
                // `Spacer(minLength: 0)` sits BETWEEN the body and the footer, so
                // it absorbs all that slack in the middle — keeping
                // header/divider/plan rows pinned to the TOP and the git footer
                // pinned to the BOTTOM edge of the card. The card's frame sets NO
                // maxHeight (below), so a content-sized card still hugs its
                // content — the Spacer only does work when the card is given extra
                // height. Mirrors the wrapper Spacer in `BrowserWindow.cardGrid`.
                Spacer(minLength: 0)
            }
            // Footer (#026 git status + #035 project star): the star toggle sits
            // bottom-LEFT and the git status (when present) bottom-RIGHT, across
            // from each other. Always emitted — the star is always available — so
            // the footer divider always renders (it no longer depends on the repo
            // being a git project). Mirrors the header's treatment: the header is
            // FOLLOWED by a `Divider()`; the footer is PRECEDED by one.
            Divider()
            footer
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
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        // #038: clip the card's content to the same rounded rect as its
        // background/border so a height-constrained card's scrolled body can
        // never paint outside its rounded bounds (e.g. into the corners or over
        // the card beneath it). Placed AFTER `.background` and BEFORE `.overlay`
        // so the stroke border still renders crisply on top of the clipped
        // content. A no-op in scroll/natural-height mode where the card already
        // hugs its content.
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: 1)
        )
        // The "Refine Plan" sheet (#056), keyed on the requesting row's task so
        // the modal targets exactly the row whose Refine glyph was tapped. The
        // `ReElaborateModal` hands the user's guidance to the runner in
        // `.reElaborate` mode (the sole `.plans/` writer, §2).
        .sheet(item: $reElaborateRequest) { request in
            ReElaborateModal(taskID: request.taskID, projectPath: request.projectPath)
        }
        // The "Elaborate" sheet (#074), keyed on the requesting row's task the
        // same way the Refine sheet above is. The `ElaborateModal` hands the
        // user's OPTIONAL guidance plus the Deep flag to the runner in
        // `.elaborate` mode (the sole `.plans/` writer, §2).
        .sheet(item: $elaborateRequest) { request in
            ElaborateModal(taskID: request.taskID, projectPath: request.projectPath)
        }
        // The "Execute" sheet (#078), keyed on the requesting row's task the same
        // way the two sheets above are. The `ExecuteModal` hands the Keep flag to
        // the runner in `.execute` mode (the sole `.plans/` writer, §2); with Keep
        // off it spawns exactly the run the bare glyph used to fire.
        .sheet(item: $executeRequest) { request in
            ExecuteModal(taskID: request.taskID, projectPath: request.projectPath)
        }
        // The pending direct-"Execute" sheet (#088), keyed on the requesting
        // pending row's task the same way the three sheets above are. The
        // `ExecutePendingModal` hands the OPTIONAL guidance plus the Deep and Keep
        // flags to the runner in `.execute` mode (the sole `.plans/` writer, §2),
        // which auto-elaborates the plan inline and then executes it.
        .sheet(item: $executePendingRequest) { request in
            ExecutePendingModal(taskID: request.taskID, projectPath: request.projectPath)
        }
        // The "Re-elaborate for review" sheet (#091), keyed on the requesting
        // review-state row's task the same way the four sheets above are. The
        // `ReviewReElaborateModal` hands the OPTIONAL guidance plus the Deep flag
        // to the runner in `.reElaborateReview` mode (the sole `.plans/` writer,
        // §2), which resets the plan to pending and re-elaborates it.
        .sheet(item: $reviewReElaborateRequest) { request in
            ReviewReElaborateModal(taskID: request.taskID, projectPath: request.projectPath)
        }
    }

    /// The growable middle content of the card: the in-flight capture rows and
    /// the active plan list. Factored into one `@ViewBuilder` so it can be
    /// rendered either inline (scroll mode, natural height) or inside a
    /// `ScrollView` (fit/grid mode, height-constrained) without duplicating it
    /// across the `if`/`else` in `body` (#038). The header and git footer stay
    /// OUTSIDE this — they're pinned to the card's top and bottom edges.
    @ViewBuilder
    private var scrollableContent: some View {
        captureRows
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

            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    planRow(row, index: index)
                }
            }
        }
        // Deferred treatment: the whole section is dimmed so it reads as
        // secondary to the active plans while remaining interactive.
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

            typeFilterMenu

            ForEach(statusCounts, id: \.status) { entry in
                HStack(spacing: 4) {
                    Image(systemName: entry.status.symbolName)
                        .imageScale(.large)
                        // Zero-count statuses dim to 10% white so they read as
                        // present-but-empty; non-zero keep the vivid glance hue.
                        .foregroundStyle(entry.count == 0 ? Color.white.opacity(0.1) : entry.status.glanceColor)
                        .frame(width: 20, alignment: .center)
                    Text("\(entry.count)")
                        .font(.body)
                        .foregroundStyle(entry.count == 0 ? Color.white.opacity(0.1) : Color.secondary)
                }
            }
        }
        // #087: re-inset by the card gutter — only the plan rows bleed full width.
        .padding(.horizontal, ProjectCard.rowColumns.cardHorizontalPadding)
    }

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
    /// `typeFilter`, which the `rows` computed property feeds through the pure
    /// `BrowserViewModel.activeRows(_:matchingType:)` helper. It NEVER mutates
    /// `.plans/` and does NOT touch the header `statusCounts`.
    @ViewBuilder
    private var typeFilterMenu: some View {
        Menu {
            Button {
                typeFilter = nil
            } label: {
                Label("All", systemImage: "square.grid.2x2")
            }
            ForEach(TaskType.allCases, id: \.self) { type in
                Button {
                    typeFilter = type
                } label: {
                    Label(type.label, systemImage: type.symbolName)
                }
            }
        } label: {
            Label(
                typeFilter?.label ?? "All",
                systemImage: typeFilter?.symbolName ?? "square.grid.2x2"
            )
            .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(typeFilter == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
        .help("Filter plans by type")
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

    // MARK: - Capture progress rows (in-flight captures)

    /// One compact row per in-flight capture/execute run for this project,
    /// stacked between the header divider and the plan rows. Each row is a small
    /// spinner + the run's free-text `description`, tappable to toggle that run's
    /// progress popover (the same `RunProgressSheet` machinery the per-row spinner
    /// uses). The "+" stays put in the header, so submitting another capture adds
    /// another row here rather than displacing the control. Rendered as nothing
    /// when no captures are running, so an idle card shows no empty gap.
    @ViewBuilder
    private var captureRows: some View {
        let captures = runner.runningCaptures(projectPath: project.projectPath)
        if !captures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(captures, id: \.taskID) { run in
                    captureRow(run)
                }
            }
            // #087: capture rows are non-plan-row content, so re-inset by the card
            // gutter (only the plan rows bleed full width).
            .padding(.horizontal, ProjectCard.rowColumns.cardHorizontalPadding)
        }
    }

    /// A single capture row: a small spinner plus the run's description,
    /// tappable (same `contentShape` + `onTapGesture` primitive as the per-row
    /// spinner) to toggle that run's progress popover, anchored to the row bounds.
    /// On the popover's close the finished run is dropped and the store reloaded
    /// so the new task surfaces via the read path.
    ///
    /// A capture that finished IN ERROR swaps the spinner for a warning glyph —
    /// reconciliation pins errored runs (they are never auto-dismissed), so this
    /// row is how the failure is raised; closing its popover is what clears it.
    @ViewBuilder
    private func captureRow(_ run: TaskRun) -> some View {
        let failed = !run.isRunning && run.error != nil
        HStack(spacing: 8) {
            if failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .imageScale(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(run.description ?? "Capturing…")
                .font(.body)
                .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            progressPopoverTaskID = (progressPopoverTaskID == run.taskID) ? nil : run.taskID
        }
        .popover(isPresented: progressPopover(for: run.taskID),
                 attachmentAnchor: .rect(.bounds)) {
            RunProgressSheet(run: run, taskID: run.taskID)
                .frame(width: 480)
                .onDisappear {
                    runner.dismiss(taskID: run.taskID, in: project.projectPath)
                    store.reload()
                }
        }
        .help(failed ? "Capture failed — click for details, close to dismiss"
                     : "Show capture progress")
    }

    // MARK: - Footer (project star + git status)

    /// The card footer row: the git status (when the project is a git repo)
    /// pinned bottom-LEFT and the project toggles bottom-RIGHT, across from
    /// each other. Git status is leading-aligned and the `Spacer` pushes the
    /// toggles to the trailing edge; a non-git project simply shows the toggles
    /// alone. The trailing cluster reads focus → star.
    private var footer: some View {
        HStack(spacing: 8) {
            gitFooter
            Spacer(minLength: 8)
            focusToggle
            starToggle
        }
        // #087: re-inset by the card gutter — only the plan rows bleed full width.
        .padding(.horizontal, ProjectCard.rowColumns.cardHorizontalPadding)
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
        let confirmation = Self.convertConfirmation
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.addButton(withTitle: confirmation.confirmButton)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let started = store.convertToTrackedPlans(projectPath: project.projectPath) { result in
            let report = Self.convertReport(for: result)
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
            // the pinned widths in `ProjectCard.rowColumns`. `spacing: 2` matches
            // the Grid's former `verticalSpacing`, so adjacent stripes still abut
            // into continuous zebra bands.
            VStack(spacing: 2) {
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
    /// detail in the browser window's in-window modal overlay pane (#073, via the
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
    ///   each row a greedy vertical slack-absorber, so when LazyVGrid hands the card
    ///   a taller cell the rows expand and distribute the extra height (drifting
    ///   toward center). With rows content-sized, the card's trailing `Spacer` (and
    ///   the cardGrid wrapper Spacer) absorb all the slack and the rows stay pinned
    ///   under the header.
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
            // never swallowed by a row-level gesture.
            rowActions(row)
        }
        // `.padding(.vertical, 5)` sets the row's height/tap area. The open-detail
        // tap gesture is applied per column (see `OpenDetailOnTap`) rather than
        // once to the whole row, so the trailing action button keeps its own
        // independent hit target.
        .padding(.vertical, 5)
        // #068 review: horizontal inset applied BEFORE the background, so the
        // band extends past the row's content on both edges instead of stopping
        // flush against the leading status glyph and the trailing action glyph.
        .padding(.horizontal, ProjectCard.rowColumns.rowHorizontalPadding)
        // #068: ONE very-subtle zebra + hover band for the whole row. Because the
        // row is an `HStack` (a real view) rather than a `GridRow`, this is a
        // single rectangle covering the full row — content plus its vertical
        // padding, edge to edge — instead of a set of per-cell backdrops that
        // followed each cell's own content. Adjacent striped rows abut across the
        // enclosing `VStack(spacing: 2)` so the zebra reads as continuous bands.
        // The tint sits BEHIND the content and carries no gesture, leaving the
        // per-column `OpenDetailOnTap` seams and the trailing action button's own
        // hit target untouched. `.onHover` tracks the single hovered row id;
        // `.animation` eases the stripe/hover crossfade (mirrors
        // `RowActionGlyph`'s hover timing).
        .background(
            Color.primary.opacity(
                ProjectCard.rowStyling.backgroundOpacity(isEven: isEven, isHovered: isHovered)
            )
        )
        .onHover { hovering in
            hoveredRowID = hovering ? row.task.id : nil
        }
        .animation(.easeOut(duration: 0.12), value: hoveredRowID)
        // #087 review: applied AFTER the background so the band stops short of
        // the card's leading edge while still bleeding to the trailing edge.
        .padding(.leading, ProjectCard.rowColumns.rowBandLeadingMargin)
    }

    /// The trailing action cell for a plan row. While this row's task is being
    /// worked, shows an inline spinner. Otherwise shows the SINGLE relevant
    /// action for the row's status: Elaborate for a `pending` task, Execute for
    /// an `elaborated`/`in-progress` task, and an empty spacer for any other
    /// status. Every state is pinned to the same fixed height so the row's line
    /// height never shifts when the spinner/glyph appears or disappears. The full
    /// live log is available by opening the row's detail overlay pane (#073).
    @ViewBuilder
    private func rowActions(_ row: TaskRow) -> some View {
        Group {
            if runner.isRunning(taskID: row.task.id, in: row.projectPath) {
                // Tapping the live spinner toggles the run's progress dialog in
                // place, anchored to the spinner, with the run's live log. The
                // `.popover` attaches to the bare spinner glyph's BOUNDS (not the
                // padded hit area, and not a single center point): anchoring to the
                // bounds lets macOS land the arrow against whichever glyph edge it
                // flips to (above when space is tight, below otherwise) with the
                // arrow tip just off the spinner rather than piercing its center.
                // The leading padding / content shape / tap gesture wrap that
                // anchored glyph.
                ProgressView()
                    .controlSize(.small)
                    .popover(isPresented: progressPopover(for: row.task.id),
                             attachmentAnchor: .rect(.bounds)) {
                        // Same dialog the detail view presents as a sheet; here it
                        // pops over the spinner. The explicit 480pt width (matching
                        // the sheet's own `minWidth`) gives the popover a stable
                        // width from first paint so the inset log field fills it
                        // immediately instead of resizing after the first layout
                        // pass. On close, drop the finished run and reload so the
                        // task's new status surfaces — mirrors the detail view's
                        // sheet teardown.
                        RunProgressSheet(run: runner.run(for: row.task.id, in: row.projectPath),
                                         taskID: row.task.id)
                            .frame(width: 480)
                            .onDisappear {
                                runner.dismiss(taskID: row.task.id, in: row.projectPath)
                                store.reload()
                            }
                    }
                    .padding(.leading, 8)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Toggle: clicking the spinner again while open closes it.
                        progressPopoverTaskID = (progressPopoverTaskID == row.task.id) ? nil : row.task.id
                    }
                    .help("Show progress")
            } else if PlanDetailView.canRetry(failure: row.task.failure) {
                // #079: the latest run for this plan failed. Offer a Retry glyph
                // that re-runs `plan-execute` via the SAME Execute consent gate as
                // the Execute glyph below (the `ExecuteModal` sheet keyed on
                // `executeRequest`) — never a silent reload. Takes precedence over
                // the status-gated Elaborate/Execute branches because a failed run
                // usually left the task at in-progress (which those branches don't
                // surface any action for), and re-running is the actionable step.
                RowActionGlyph(systemImage: "arrow.clockwise", help: "Retry this plan") {
                    cardLog.notice("card Retry clicked: task=\(row.task.id, privacy: .public)")
                    executeRequest = ExecuteRequest(
                        taskID: row.task.id,
                        projectPath: row.projectPath
                    )
                }
            } else if PlanDetailView.canElaborate(status: row.task.status,
                                                  isBlocked: row.task.isBlocked,
                                                  isBacklogged: row.task.isBacklogged) {
                // A pending, non-blocked task surfaces BOTH Elaborate and a
                // direct-Execute glyph (#088), mirroring the elaborated-row
                // Refine+Execute pair below: a tight `HStack(spacing: -4)` of two
                // `RowActionGlyph`s (each a 22pt cell with built-in 8pt leading
                // padding) so they read as a tight pair within the row's pinned
                // height. Elaborate (unchanged, #074) opens the `ElaborateModal`
                // for an optional-guidance + Deep elaboration; direct-Execute
                // opens the `ExecutePendingModal` (#088), which hands the plan to
                // `plan-execute` to auto-elaborate inline and then execute.
                HStack(spacing: -4) {
                    RowActionGlyph(systemImage: "sparkles", help: "Elaborate this plan") {
                        cardLog.notice("card Elaborate clicked: task=\(row.task.id, privacy: .public)")
                        elaborateRequest = ElaborateRequest(
                            taskID: row.task.id,
                            projectPath: row.projectPath
                        )
                    }
                    RowActionGlyph(systemImage: "play.fill", help: "Execute this plan directly") {
                        cardLog.notice("card direct-Execute clicked: task=\(row.task.id, privacy: .public)")
                        executePendingRequest = ExecutePendingRequest(
                            taskID: row.task.id,
                            projectPath: row.projectPath
                        )
                    }
                }
            } else if PlanDetailView.canWork(status: row.task.status,
                                             isBlocked: row.task.isBlocked,
                                             isBacklogged: row.task.isBacklogged) {
                // An elaborated, non-blocked task surfaces BOTH Refine and Execute
                // (#056). The two glyphs sit in a tight HStack — each
                // `RowActionGlyph` is its own 22pt-tall cell with built-in 8pt
                // leading padding, so the pair stays within the row's pinned 22pt
                // height and the row's vertical metrics match its single-glyph
                // neighbours. A negative `spacing` trims the gap between the two
                // adjacent glyphs (each already carries 8pt leading padding) so
                // they read as a tight pair. Refine opens the `ReElaborateModal`
                // via the card's `.sheet(item:)`; Execute likewise opens the
                // `ExecuteModal` (#078) rather than firing the run straight off
                // the glyph. `canWork` and `canReElaborate` share the same
                // elaborated+non-blocked gate, so Refine appears exactly when
                // Execute does.
                HStack(spacing: -4) {
                    RowActionGlyph(systemImage: "sparkles", help: "Refine this plan") {
                        cardLog.notice("card Refine clicked: task=\(row.task.id, privacy: .public)")
                        reElaborateRequest = ReElaborateRequest(
                            taskID: row.task.id,
                            projectPath: row.projectPath
                        )
                    }
                    RowActionGlyph(systemImage: "play.fill", help: "Execute this plan") {
                        cardLog.notice("card Execute clicked: task=\(row.task.id, privacy: .public)")
                        executeRequest = ExecuteRequest(
                            taskID: row.task.id,
                            projectPath: row.projectPath
                        )
                    }
                }
            } else if PlanDetailView.canExecuteReview(status: row.task.status,
                                                      isBlocked: row.task.isBlocked,
                                                      isBacklogged: row.task.isBacklogged)
                        || PlanDetailView.canReElaborateReview(status: row.task.status,
                                                               isBlocked: row.task.isBlocked,
                                                               isBacklogged: row.task.isBacklogged) {
                // A review-state (review/in-review), non-blocked task surfaces BOTH
                // Refine and Execute (#091) — mirroring the elaborated-row pair
                // above — so the user can push the plan back to pending for a fresh
                // re-elaboration OR run another execution pass. Same tight
                // `HStack(spacing: -4)` of two `RowActionGlyph`s within the row's
                // pinned height. Refine opens the `ReviewReElaborateModal` (which
                // resets the plan to pending and re-elaborates); Execute reuses the
                // elaborated-plan `ExecuteModal` via the shared `executeRequest`.
                // `canExecuteReview` and `canReElaborateReview` share the same
                // review+non-blocked gate, so Refine appears exactly when Execute
                // does.
                HStack(spacing: -4) {
                    RowActionGlyph(systemImage: "sparkles", help: "Re-elaborate this plan for review") {
                        cardLog.notice("card review-Refine clicked: task=\(row.task.id, privacy: .public)")
                        reviewReElaborateRequest = ReviewReElaborateRequest(
                            taskID: row.task.id,
                            projectPath: row.projectPath
                        )
                    }
                    RowActionGlyph(systemImage: "play.fill", help: "Execute this plan again") {
                        cardLog.notice("card review-Execute clicked: task=\(row.task.id, privacy: .public)")
                        executeRequest = ExecuteRequest(
                            taskID: row.task.id,
                            projectPath: row.projectPath
                        )
                    }
                }
            } else {
                // No action for this status: an empty spacer of the same height
                // so the row's vertical metrics match action-bearing rows.
                Color.clear.frame(width: 0)
            }
        }
        // Pin the cell to the glyph's height in every state so swapping between
        // spinner / glyph / empty never changes the row's line height.
        .frame(height: 22)
    }

    /// The project star/unstar toggle (#035). A filled yellow `star.fill` when
    /// this project's path is in `store.starredProjectPaths`, otherwise an outline
    /// `star`. Tapping toggles membership of `project.projectPath` in the persisted
    /// set (`insert`/`remove` triggers the store's `didSet` persistence). Starring
    /// is a filter input in its own right (#072): the `.starred` project view mode
    /// shows exactly the starred projects, empty or not.
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

    /// The project focus toggle (#067). A `viewfinder` glyph, opaque/tinted when
    /// this project is the currently-focused one and muted otherwise. Tapping
    /// toggles focus on `project.projectPath` (`store.toggleFocus`), which the
    /// browser's `sortedProjects` reacts to — collapsing the grid to this card, or
    /// restoring the full grid when the same card is toggled off.
    @ViewBuilder
    private var focusToggle: some View {
        let isFocused = store.focusedProjectPath == project.projectPath
        FocusToggleGlyph(
            isFocused: isFocused,
            help: isFocused ? "Exit focus" : "Focus project"
        ) {
            store.toggleFocus(project.projectPath)
        }
    }

}

/// A pending "Refine Plan" request (#056): the task + project a tapped Refine
/// glyph targets, driving the card's `.sheet(item:)`. `Identifiable` on the task
/// id so SwiftUI presents (and re-targets) the sheet for the right row.
private struct ReElaborateRequest: Identifiable {
    let taskID: String
    let projectPath: String
    var id: String { taskID }
}

/// A pending "Elaborate" request (#074): the task + project a tapped Elaborate
/// glyph targets, driving the card's second `.sheet(item:)`. A distinct type
/// from `ReElaborateRequest` (rather than a shared one) so the two sheets stay
/// independently keyed and can never be presented against each other's state.
private struct ElaborateRequest: Identifiable {
    let taskID: String
    let projectPath: String
    var id: String { taskID }
}

/// A pending "Execute" request (#078): the task + project a tapped Execute glyph
/// targets, driving the card's third `.sheet(item:)`. A distinct type from
/// `ElaborateRequest`/`ReElaborateRequest` (rather than a shared one) so the
/// three sheets stay independently keyed and can never be presented against each
/// other's state.
private struct ExecuteRequest: Identifiable {
    let taskID: String
    let projectPath: String
    var id: String { taskID }
}

/// A pending direct-"Execute" request (#088): the task + project a tapped pending
/// `play.fill` glyph targets, driving the card's fourth `.sheet(item:)`. A distinct
/// type from `ExecuteRequest`/`ElaborateRequest`/`ReElaborateRequest` (rather than a
/// shared one) so the four sheets stay independently keyed and can never be
/// presented against each other's state.
private struct ExecutePendingRequest: Identifiable {
    let taskID: String
    let projectPath: String
    var id: String { taskID }
}

/// A pending "Re-elaborate for review" request (#091): the task + project a tapped
/// review-state `sparkles` glyph targets, driving the card's fifth `.sheet(item:)`.
/// A distinct type from the other request structs (rather than a shared one) so the
/// five sheets stay independently keyed and can never be presented against each
/// other's state.
private struct ReviewReElaborateRequest: Identifiable {
    let taskID: String
    let projectPath: String
    var id: String { taskID }
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

/// The project focus glyph (#067). Mirrors `StarToggleGlyph`: a `.plain` `Button`
/// showing a solid `viewfinder` whose white opacity conveys state — medium when
/// this project is focused, very low otherwise (brightening slightly on hover) —
/// over the same subtle hover background and cursor treatment as the star.
private struct FocusToggleGlyph: View {
    let isFocused: Bool
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "viewfinder")
                .imageScale(.medium)
                .foregroundStyle(Color.white.opacity(isFocused ? 0.6 : (hovering ? 0.35 : 0.15)))
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

/// A single small tappable glyph for a row action, with hover and press
/// feedback. Implemented as an Image with its own `.onTapGesture` +
/// `.contentShape` (NOT a `Button`): a borderless `Button` nested in a `Grid`
/// row alongside other tap gestures proved unreliable to hit-test on macOS,
/// whereas the tap-gesture primitive is the same one the content cells use to
/// open detail and works reliably.
///
/// Feedback: on hover the glyph brightens to the primary color over a subtly
/// tinted rounded background and the cursor switches to a pointing hand; while
/// pressed it scales down and dims, then runs `action` on release.
private struct RowActionGlyph: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Image(systemName: systemImage)
            .imageScale(.medium)
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(pressed ? 0.18 : (hovering ? 0.10 : 0)))
            )
            .scaleEffect(pressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .contentShape(Rectangle())
            // A min-distance-0 drag gesture gives us press-down / release-up
            // feedback that `.onTapGesture` alone can't: press dims+shrinks the
            // glyph, and releasing within the 22×22 glyph bounds fires the
            // action. (Attached before the leading padding so the gesture's
            // coordinate space is exactly the glyph, not the padded cell.)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { value in
                        pressed = false
                        let bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
                        if bounds.contains(value.location) { action() }
                    }
            )
            .onHover { hovering = $0 }
            .padding(.leading, 8)
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
/// browser window's `detailRowID` to present the in-window modal overlay pane.
/// This replaced the earlier design, in which the tap called `openWindow(id:value:)`
/// to open a standalone detail window; that window's scene no longer exists.
private struct OpenDetailOnTap: ViewModifier {
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
