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
///   row opens that plan's detail in a separate window (`openWindow(id:value:)`,
///   §011) — it no longer sets a selection. Tapping the header project name
///   reveals the project's nested `.plans` directory in Finder (#047). When
///   there are no active plans the body shows a muted empty state.
///
/// The card is strictly READ-ONLY (§2): it only reads from the injected
/// `ProjectTasks` and opens a detail window on tap. It has NO toggles, status
/// pickers, How checkboxes, or any FS-mutating calls.
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

    /// Opens the standalone plan-detail window (§011) for a tapped row, keyed on
    /// the row's composite `TaskRow.ID`.
    @Environment(\.openWindow) private var openWindow

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
    /// empty card visible under "Hide Empty" but does not inject completed plans
    /// into the body — so this is just the active rows.
    private var rows: [TaskRow] {
        BrowserViewModel.activeRows(project)
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
        /// size the id / type columns from their known character counts.
        var monospaceCharacterWidth: CGFloat = 8
        /// The leading status-glyph column (unchanged from the Grid layout).
        var statusWidth: CGFloat = 20
        /// The id column — plan ids are short numeric strings; 4 characters plus
        /// slack covers every id the parser produces.
        var idWidth: CGFloat = 40
        /// The `[type]` column, pinned to fit the widest label (`[refactor]` —
        /// 8 characters plus 2 brackets) so every badge occupies the same width.
        var typeWidth: CGFloat = 10 * 8
        /// The title column flexes, absorbing all remaining width so the row's
        /// single background reaches the trailing edge on every row.
        var titleMaxWidth: CGFloat = .infinity
        /// Spacing between columns. This is `HStack` spacing INSIDE the row's
        /// background, so it separates columns without breaking the band.
        var columnGap: CGFloat = 8
        /// Horizontal inset applied INSIDE the row's background, so the band
        /// extends past the leading status glyph and the trailing action glyph
        /// rather than stopping flush against them.
        var rowHorizontalPadding: CGFloat = 8
    }

    /// The single source of truth for plan-row column widths, consumed by
    /// `planRow` so the view and the tested decision cannot drift apart.
    static let rowColumns = RowColumns()

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
        .padding(.top, 14)
        .padding(.horizontal, 14)
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
                    runner.dismiss(taskID: run.taskID)
                    store.reload()
                }
        }
        .help(failed ? "Capture failed — click for details, close to dismiss"
                     : "Show capture progress")
    }

    // MARK: - Footer (project star + git status)

    /// The card footer row: the git status (when the project is a git repo)
    /// pinned bottom-LEFT and the project star toggle bottom-RIGHT, across from
    /// each other. Git status is leading-aligned and the `Spacer` pushes the star
    /// to the trailing edge; a non-git project simply shows the star alone.
    private var footer: some View {
        HStack(spacing: 8) {
            gitFooter
            Spacer(minLength: 8)
            focusToggle
            starToggle
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
            }
        }
    }

    // MARK: - Body (the active plan rows, or the empty state)

    /// The card body: a tappable row per active plan, or a muted empty state
    /// when there are none.
    @ViewBuilder
    private func body(for rows: [TaskRow]) -> some View {
        if rows.isEmpty {
            Text("No outstanding plans")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
    /// detail in a separate window (`openWindow(id:value:)`, §011).
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
                .modifier(OpenDetailOnTap(row: row, openWindow: openWindow))

            Text(row.task.id)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: ProjectCard.rowColumns.idWidth, alignment: .leading)
                .modifier(OpenDetailOnTap(row: row, openWindow: openWindow))

            // Always-present cell (empty string when no type) so the title column
            // starts at the same x on every row. A kept-worktree task (executed
            // with the `keep` keyword) appends a muted house glyph after the type
            // badge — the desktop analogue of the plans-cc dashboard TUI's
            // `⌂ kept` marker. Only review-state tasks carry a live worktree, so
            // it appears only there; the icon has a `help` tooltip since it
            // renders label-free. The pinned width fits the widest label
            // (`[refactor]`), so a short badge no longer leaves the row's
            // background with an unpainted channel beside it.
            HStack(spacing: 4) {
                Text(typeText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if row.task.isKeptWorktree {
                    Image(systemName: TaskStatusIndicator.keptWorktreeSymbol)
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .help("Kept in worktree — reviewable in isolation")
                }
            }
            .frame(width: ProjectCard.rowColumns.typeWidth, alignment: .leading)
            .modifier(OpenDetailOnTap(row: row, openWindow: openWindow))

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
                .modifier(OpenDetailOnTap(row: row, openWindow: openWindow))

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
    }

    /// The trailing action cell for a plan row. While this row's task is being
    /// worked, shows an inline spinner. Otherwise shows the SINGLE relevant
    /// action for the row's status: Elaborate for a `pending` task, Execute for
    /// an `elaborated`/`in-progress` task, and an empty spacer for any other
    /// status. Every state is pinned to the same fixed height so the row's line
    /// height never shifts when the spinner/glyph appears or disappears. The full
    /// live log is available by opening the row's detail window.
    @ViewBuilder
    private func rowActions(_ row: TaskRow) -> some View {
        Group {
            if runner.isRunning(taskID: row.task.id) {
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
                        RunProgressSheet(run: runner.run(for: row.task.id),
                                         taskID: row.task.id)
                            .frame(width: 480)
                            .onDisappear {
                                runner.dismiss(taskID: row.task.id)
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
            } else if PlanDetailView.canElaborate(status: row.task.status,
                                                  isBlocked: row.task.isBlocked) {
                RowActionGlyph(systemImage: "sparkles", help: "Elaborate this plan") {
                    cardLog.notice("card Elaborate clicked: task=\(row.task.id, privacy: .public)")
                    runner.run(projectPath: row.projectPath, taskID: row.task.id, mode: .elaborate)
                }
            } else if PlanDetailView.canWork(status: row.task.status,
                                             isBlocked: row.task.isBlocked) {
                // An elaborated, non-blocked task surfaces BOTH Refine and Execute
                // (#056). The two glyphs sit in a tight HStack — each
                // `RowActionGlyph` is its own 22pt-tall cell with built-in 8pt
                // leading padding, so the pair stays within the row's pinned 22pt
                // height and the row's vertical metrics match its single-glyph
                // neighbours. A negative `spacing` trims the gap between the two
                // adjacent glyphs (each already carries 8pt leading padding) so
                // they read as a tight pair. Refine opens the `ReElaborateModal`
                // via the card's `.sheet(item:)`; Execute launches the run as
                // before. `canWork` and `canReElaborate` share the same
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
                        runner.run(projectPath: row.projectPath, taskID: row.task.id, mode: .execute)
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
    /// keeps the card visible in the dashboard past the "Hide Empty" filter even
    /// when the project has no outstanding work.
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

/// Applies "open this plan's detail window on tap" to a single row content cell.
/// Used per content cell (id / type / title / status icon) rather than once on
/// the whole `GridRow`, so the trailing action button keeps an independent hit
/// target instead of competing with a row-wide tap gesture.
private struct OpenDetailOnTap: ViewModifier {
    let row: TaskRow
    let openWindow: OpenWindowAction

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { openWindow(id: "plan-detail", value: row.id) }
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
        isCompletedDir: false
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
    return ProjectCard(project: project, onNewPlan: { _ in })
        .environment(PlansStore())
        .environment(TaskRunner())
        // The WIDE frame is the load-bearing part of the repro: a narrow card
        // does not exhibit the collapse.
        .frame(width: 900)
        .padding()
}
#endif
