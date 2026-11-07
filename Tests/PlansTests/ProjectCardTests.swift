import AppKit
import XCTest
@testable import Plans

/// Tests for the data-layer invariants the `ProjectCard` git footer depends on
/// (#026 moved the git indicator from the header into a dedicated card footer).
///
/// `ProjectCard` is a SwiftUI view whose rendered output is impractical to
/// assert against directly, so these tests pin the `ProjectTasks` git fields the
/// footer reads: the footer (and its preceding divider) render ONLY when
/// `gitBranch != nil`, and the orange dirty dot renders ONLY when
/// `gitIsDirty == true` (a `nil`/`false` value shows no dot). Mirrors
/// `BrowserWindowTests`, which asserts plain values without instantiating views.
final class ProjectCardTests: XCTestCase {

    /// Builds a `ProjectTasks` fixture, optionally with git fields, via the
    /// memberwise initializer used across the suite.
    private func makeProject(
        gitBranch: String? = nil,
        gitIsDirty: Bool? = nil
    ) -> ProjectTasks {
        ProjectTasks(
            projectPath: "/tmp/example",
            projectName: "example",
            lastSeen: "",
            tasks: [],
            counts: [:],
            activeTasks: [],
            gitBranch: gitBranch,
            gitIsDirty: gitIsDirty
        )
    }

    /// A git repo with a dirty working tree: the footer would show the branch
    /// plus the orange dirty dot.
    func testGitRepoDirtyExposesBranchAndDirtyTrue() {
        let project = makeProject(gitBranch: "main", gitIsDirty: true)
        XCTAssertEqual(project.gitBranch, "main")
        XCTAssertEqual(project.gitIsDirty, true)
    }

    /// A git repo with a clean working tree: the footer shows the branch but no
    /// dirty dot (`gitIsDirty == false` is known-clean, not unknown).
    func testGitRepoCleanShowsNoDirtyDot() {
        let project = makeProject(gitBranch: "feature/x", gitIsDirty: false)
        XCTAssertEqual(project.gitBranch, "feature/x")
        XCTAssertEqual(project.gitIsDirty, false)
        // Only an exact `true` renders the dot.
        XCTAssertNotEqual(project.gitIsDirty, true)
    }

    /// A git repo whose dirty state is unknown (`nil`): branch shown, no dot.
    func testGitRepoUnknownDirtyShowsNoDot() {
        let project = makeProject(gitBranch: "main", gitIsDirty: nil)
        XCTAssertEqual(project.gitBranch, "main")
        XCTAssertNil(project.gitIsDirty)
        XCTAssertNotEqual(project.gitIsDirty, true)
    }

    /// A non-git project: `gitBranch == nil`, so neither the footer nor its
    /// preceding divider render (the body guards on `gitBranch != nil`).
    func testNonGitProjectHasNilBranch() {
        let project = makeProject(gitBranch: nil, gitIsDirty: nil)
        XCTAssertNil(project.gitBranch)
        XCTAssertNil(project.gitIsDirty)
    }

    /// The git fields default to `nil` when omitted, so existing call sites and
    /// fixtures that predate #024 keep behaving as non-git projects.
    func testGitFieldsDefaultToNil() {
        let project = makeProject()
        XCTAssertNil(project.gitBranch)
        XCTAssertNil(project.gitIsDirty)
    }

    // MARK: - failureTooltip (#079 — plan-row failed indicator tooltip)

    /// A healthy plan (no failure overlay) yields NO tooltip — the caller passes
    /// an empty `help` string and the row shows no failure explanation.
    func testFailureTooltipNilWhenHealthy() {
        XCTAssertNil(ProjectCard.failureTooltip(for: nil))
    }

    /// A failure WITH an error message folds the classification/stop-reason
    /// summary and the message onto two lines.
    func testFailureTooltipWithMessageCombinesSummaryAndMessage() {
        let failure = TaskFailure(
            classification: .error,
            errorMessage: "boom",
            stopReason: nil,
            timestamp: "2026-01-01T00:00:00Z"
        )
        XCTAssertEqual(
            ProjectCard.failureTooltip(for: failure),
            "Run errored\nboom"
        )
    }

    /// A failure with a stop reason but NO error message shows only the summary
    /// (classification label + stop reason).
    func testFailureTooltipWithStopReasonNoMessage() {
        let failure = TaskFailure(
            classification: .truncated,
            errorMessage: nil,
            stopReason: "error_max_budget_usd",
            timestamp: "2026-01-01T00:00:00Z"
        )
        XCTAssertEqual(
            ProjectCard.failureTooltip(for: failure),
            "Run cut short (budget/turn cap) · error_max_budget_usd"
        )
    }

    /// An empty error message is treated as absent (no trailing blank line).
    func testFailureTooltipEmptyMessageOmitsMessageLine() {
        let failure = TaskFailure(
            classification: .crashed,
            errorMessage: "",
            stopReason: nil,
            timestamp: "2026-01-01T00:00:00Z"
        )
        XCTAssertEqual(ProjectCard.failureTooltip(for: failure), "Run crashed")
    }

    // MARK: - finderURL (tap project name → reveal project in Finder, #047)

    /// #047: tapping the project name reveals the project's nested `.plans`
    /// directory in Finder via `NSWorkspace.activateFileViewerSelecting`. The
    /// `finderURL(for:)` helper is the pure, view-free seam that builds that URL
    /// from `project.projectPath`; it must produce a file URL pointing at the
    /// `.plans` subdirectory of the project path.
    func testFinderURLBuildsFileURLForPlansDirectory() {
        let url = ProjectCard.finderURL(for: "/tmp/example")
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.path, "/tmp/example/.plans")
        XCTAssertEqual(url.lastPathComponent, ".plans")
    }

    // MARK: - titleSizing (deterministic flexible-title column, #063)

    /// #063: the title column previously relied on a magic `idealWidth:
    /// 1_000_000` sentinel to win the Grid's flexible-width negotiation. Under a
    /// wide card with a single short row that negotiation degraded, collapsing
    /// the title into a sliver and reflowing the row into a duplicated
    /// two-column look. The fix pins the sizing decision in a pure, view-free
    /// `titleSizing` helper: the title stretches to `maxWidth: .infinity` (no
    /// ideal width) and is bounded by a 2-line limit with tail truncation so a
    /// long title never collapses the column. This asserts the decision no
    /// longer depends on any magic sentinel width.
    func testTitleSizingUsesNoMagicSentinelWidth() {
        let sizing = ProjectCard.titleSizing
        // The title stretches to the full remaining width — no bounded ideal.
        XCTAssertNil(sizing.idealWidth)
        XCTAssertEqual(sizing.maxWidth, .infinity)
        // Defensively: whatever ideal is exposed, it is not a large sentinel.
        if let ideal = sizing.idealWidth {
            XCTAssertLessThan(ideal, 100_000)
        }
    }

    /// #063: the title is bounded by a line limit + tail truncation so a long
    /// title wraps to at most two lines and then truncates, rather than forcing
    /// the flexible column to a sliver.
    func testTitleSizingIsBoundedByLineLimitAndTailTruncation() {
        let sizing = ProjectCard.titleSizing
        XCTAssertEqual(sizing.lineLimit, 2)
        XCTAssertEqual(sizing.truncationMode, .tail)
    }

    // MARK: - planRow cell-count invariant (table layout, #063)

    /// #063: each `planRow` GridRow must emit exactly five cells — status icon /
    /// id / [type] / title / actions — so the `Grid`'s cross-row column
    /// alignment (a table look) survives. Pinning the count as a static
    /// constant lets this invariant be asserted without rendering the view; the
    /// view and this constant are kept in agreement by construction.
    func testPlanRowEmitsExactlyFiveCells() {
        XCTAssertEqual(ProjectCard.planRowCellCount, 5)
    }

    // MARK: - rowStyling (very subtle zebra striping + hover shift, #068)

    /// #068: plan-table rows carry a very subtle zebra stripe plus a hover shift.
    /// The decision is a pure, view-free value (`rowStyling.backgroundOpacity`)
    /// so the exact opacities are assertable without rendering the SwiftUI view,
    /// mirroring `titleSizing` / `planRowCellCount`. The background is
    /// `Color.primary.opacity(...)`, so these are the alpha values applied.

    /// Even rows carry NO stripe at rest — only odd rows are tinted, so the
    /// zebra reads as an every-other-row band rather than a flat wash.
    func testEvenRowsHaveNoStripeAtRest() {
        let opacity = ProjectCard.rowStyling.backgroundOpacity(isEven: true, isHovered: false)
        XCTAssertEqual(opacity, 0, "Even rows must have no resting stripe")
    }

    /// Odd rows carry a small but nonzero stripe at rest — the zebra band.
    func testOddRowsHaveSmallNonzeroStripeAtRest() {
        let opacity = ProjectCard.rowStyling.backgroundOpacity(isEven: false, isHovered: false)
        XCTAssertGreaterThan(opacity, 0, "Odd rows must have a nonzero resting stripe")
    }

    /// Hovering a row always adds an additional shift, so a hovered row reads
    /// stronger than that same row's resting value — for BOTH parities.
    func testHoverAddsShiftOverRestForBothParities() {
        let evenRest = ProjectCard.rowStyling.backgroundOpacity(isEven: true, isHovered: false)
        let evenHover = ProjectCard.rowStyling.backgroundOpacity(isEven: true, isHovered: true)
        XCTAssertGreaterThan(evenHover, evenRest, "Hovering an even row must strengthen it")

        let oddRest = ProjectCard.rowStyling.backgroundOpacity(isEven: false, isHovered: false)
        let oddHover = ProjectCard.rowStyling.backgroundOpacity(isEven: false, isHovered: true)
        XCTAssertGreaterThan(oddHover, oddRest, "Hovering an odd row must strengthen it")
    }

    /// Every opacity the styling returns is "very subtle" — capped well below a
    /// flat overlay so the zebra and hover never dominate the card.
    func testEveryOpacityIsVerySubtle() {
        for isEven in [true, false] {
            for isHovered in [true, false] {
                let opacity = ProjectCard.rowStyling.backgroundOpacity(isEven: isEven, isHovered: isHovered)
                XCTAssertLessThanOrEqual(
                    opacity, 0.08,
                    "Opacity for isEven=\(isEven) isHovered=\(isHovered) must stay very subtle"
                )
            }
        }
    }

    /// A hovered row always reads at least as strong as the resting odd-row
    /// stripe, so hover feedback is never weaker than the ambient zebra band.
    func testHoveredRowIsAtLeastAsStrongAsRestingOddStripe() {
        let oddRest = ProjectCard.rowStyling.backgroundOpacity(isEven: false, isHovered: false)
        for isEven in [true, false] {
            let hovered = ProjectCard.rowStyling.backgroundOpacity(isEven: isEven, isHovered: true)
            XCTAssertGreaterThanOrEqual(
                hovered, oddRest,
                "A hovered row (isEven=\(isEven)) must be at least as strong as the resting odd stripe"
            )
        }
    }
    // MARK: - rowColumns (row-owned band, #068 review fix)

    /// #068 review: the zebra/hover band must be ONE rectangle spanning the full
    /// row. A `.background` on a `GridRow` cannot do that — `GridRow` is a layout
    /// declaration, so the modifier is propagated to each CELL and every cell's
    /// backdrop tracks its own CONTENT rather than its allotted column width.
    /// A short `[bug]` badge in a column sized for `[refactor]` therefore left a
    /// wide unpainted channel, and a sparse action cell left the row's right edge
    /// untinted. The row is now a real view (an `HStack`) that owns one
    /// background, with the former Grid column auto-sizing replaced by pinned
    /// widths so the id / [type] / title columns keep a consistent left edge.

    /// The type column is pinned wide enough for the widest label (`[refactor]`),
    /// so every row's badge occupies the same column width and the band behind it
    /// is continuous regardless of which type a row carries.
    func testTypeColumnFitsWidestLabel() {
        let widest = TaskType.allCases.map(\.label.count).max() ?? 0
        XCTAssertEqual(
            TaskType.refactor.label.count, widest,
            "[refactor] is expected to be the widest type label"
        )
        XCTAssertGreaterThanOrEqual(
            ProjectCard.rowColumns.typeWidth,
            CGFloat(widest + 2) * ProjectCard.rowColumns.monospaceCharacterWidth,
            "Type column must fit the widest label plus its surrounding brackets"
        )
    }

    /// The nominal `monospaceCharacterWidth` must not UNDER-state the real
    /// advance width of the `.body` monospaced face the row actually renders in.
    /// It did (8.0 assumed vs ~8.4 measured at the 13pt system body size), so
    /// `[refactor]` overflowed its pinned column by a fraction of a character and
    /// SwiftUI wrapped it onto a second line — visibly breaking the badge as
    /// `[refactor` / `]` and making that row taller than its neighbours.
    func testTypeColumnFitsMeasuredWidestLabel() {
        let font = NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .regular
        )
        let widest = "[\(TaskType.refactor.label)]"
        let measured = (widest as NSString)
            .size(withAttributes: [.font: font])
            .width

        XCTAssertGreaterThanOrEqual(
            ProjectCard.rowColumns.typeWidth, measured,
            "Type column must fit the MEASURED width of [refactor], not an "
                + "under-estimated nominal character width, or the badge wraps"
        )
    }

    /// The type column must fit the widest label AND the kept-worktree house
    /// marker beside it (#086). The marker is rendered INSIDE the fixed-width
    /// type cell, appended after the `[refactor]` badge with the cell's
    /// inter-element gap; `.frame(width:)` does not clip, so if the budget omits
    /// the icon and gap the house overflows the cell and overlaps the title.
    func testTypeColumnFitsWidestLabelPlusKeptMarker() {
        let font = NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .regular
        )
        let widest = "[\(TaskType.refactor.label)]"
        let measured = (widest as NSString)
            .size(withAttributes: [.font: font])
            .width

        XCTAssertGreaterThanOrEqual(
            ProjectCard.rowColumns.typeWidth,
            measured
                + ProjectCard.rowColumns.keptMarkerWidth
                + ProjectCard.rowColumns.typeCellSpacing,
            "Type column must fit [refactor] PLUS the kept-worktree house marker "
                + "and the type-cell gap, or the icon overflows and overlaps the title"
        )
    }

    /// plans-cc ids are zero-padded to a MINIMUM of 3 digits, so past task 999
    /// they grow to `1000`, `10000`, … (#090). The pinned id column must fit
    /// the MEASURED width of a 5-digit id in the face the id cell renders in,
    /// or a wide id clips / wraps instead of reading as one token.
    func testIdColumnFitsMeasuredFiveDigitId() {
        let font = NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .regular
        )
        let measured = ("10000" as NSString)
            .size(withAttributes: [.font: font])
            .width

        XCTAssertGreaterThanOrEqual(
            ProjectCard.rowColumns.idWidth, measured,
            "Id column must fit the MEASURED width of a 5-digit id"
        )
    }

    /// The status and id columns are pinned too, so all three leading columns
    /// align across rows exactly as the Grid used to make them.
    func testLeadingColumnsArePinned() {
        XCTAssertGreaterThan(ProjectCard.rowColumns.statusWidth, 0)
        XCTAssertGreaterThan(ProjectCard.rowColumns.idWidth, 0)
    }

    /// The gap between columns is real and positive, but it is spacing INSIDE the
    /// row's single background, so it never punches a hole through the band.
    func testColumnGapIsPositiveAndInsideTheBand() {
        XCTAssertGreaterThan(
            ProjectCard.rowColumns.columnGap, 0,
            "Columns must be visually separated"
        )
    }

    /// The row band spans the full width: the title column flexes to absorb all
    /// remaining space, so the background reaches the row's trailing edge even
    /// when a row has few or no action glyphs.
    func testTitleColumnFlexesSoBandReachesTrailingEdge() {
        XCTAssertEqual(
            ProjectCard.rowColumns.titleMaxWidth, .infinity,
            "Title column must flex so the row band spans full width"
        )
    }

    /// The band is inset from the row's content on BOTH edges, so the tint
    /// breathes past the leading status glyph and the trailing action glyph
    /// instead of stopping flush against them.
    func testBandHasHorizontalPaddingOnBothEdges() {
        XCTAssertGreaterThan(
            ProjectCard.rowColumns.rowHorizontalPadding, 0,
            "The band must extend past the row content on the leading/trailing edges"
        )
    }

    // MARK: - full-bleed row band (#087)

    /// #087: only the plan-row zebra/hover band bleeds to the card's rounded
    /// inner edge; every non-row element (header, footer, empty state, the
    /// "Backlogged" label, capture rows) is re-inset by this single card gutter
    /// so it stays aligned with the row text. The gutter must be a real, positive
    /// inset — a zero gutter would leave the header/footer flush against the card
    /// edge.
    func testCardHorizontalPaddingIsPositive() {
        XCTAssertGreaterThan(
            ProjectCard.rowColumns.cardHorizontalPadding, 0,
            "The card gutter must inset the non-row content from the card edge"
        )
    }

    /// #087 review: the row band stops short of the card's LEADING edge by a
    /// small margin (it still bleeds to the trailing edge), so it doesn't sit
    /// flush against the card's left border.
    func testRowBandHasLeadingMargin() {
        XCTAssertGreaterThan(
            ProjectCard.rowColumns.rowBandLeadingMargin, 0,
            "The row band must stop short of the card's leading edge"
        )
    }

    /// #087: the band's leading margin plus its inner text inset must equal the
    /// card gutter, so the row text lines up with the re-inset header/footer
    /// content.
    func testRowInsetKeepsBandTextAlignedWithCardContent() {
        XCTAssertEqual(
            ProjectCard.rowColumns.rowBandLeadingMargin
                + ProjectCard.rowColumns.rowHorizontalPadding,
            ProjectCard.rowColumns.cardHorizontalPadding,
            "Band margin + band text inset must match the card gutter so row "
                + "text aligns with the re-inset header/footer content"
        )
    }

    // MARK: - Convert to tracked plans (alert copy)

    func testConvertConfirmationUsesPlansCcWording() {
        let confirmation = ProjectCard.convertConfirmation
        XCTAssertEqual(confirmation.title, "Convert to tracked plans?")
        XCTAssertEqual(
            confirmation.message,
            "Move `.plans/` onto a dedicated `plans` branch (pushed to `origin` when it exists)? "
                + "Every file is copied and verified before the backup is removed."
        )
        XCTAssertEqual(confirmation.confirmButton, "Convert")
    }

    func testConvertReportForSuccessCarriesOKLine() {
        let report = ProjectCard.convertReport(for: PlansGitHelper.MigrateResult(
            outcome: .ok(".plans is now on branch plans"),
            warnings: ["push skipped"]
        ))
        XCTAssertFalse(report.isError)
        XCTAssertTrue(report.message.hasPrefix("OK: .plans is now on branch plans"), report.message)
        XCTAssertTrue(report.message.contains("Warning: push skipped"), report.message)
    }

    func testConvertReportForErrorCarriesErrorLine() {
        let report = ProjectCard.convertReport(for: PlansGitHelper.MigrateResult(
            outcome: .error("plans already exists", backupPath: nil)
        ))
        XCTAssertTrue(report.isError)
        XCTAssertEqual(report.message, "Error: plans already exists")
    }

    func testConvertReportStatesBackupPathExplicitly() {
        let backup = "/Users/me/proj/.plans.migrate-backup"
        let report = ProjectCard.convertReport(for: PlansGitHelper.MigrateResult(
            outcome: .error("verify failed; backup kept at \(backup)", backupPath: backup)
        ))
        XCTAssertTrue(report.isError)
        XCTAssertTrue(report.message.hasPrefix("Error: verify failed; backup kept at \(backup)"), report.message)
        XCTAssertTrue(
            report.message.contains("Your original plans are intact at \(backup)"),
            report.message
        )
    }

    func testConvertReportForMissingHelperIsAnError() {
        let report = ProjectCard.convertReport(for: PlansGitHelper.MigrateResult(outcome: .helperMissing))
        XCTAssertTrue(report.isError)
        XCTAssertTrue(report.message.hasPrefix("Error: "), report.message)
        XCTAssertTrue(report.message.contains("plans-git.js"), report.message)
    }
}
