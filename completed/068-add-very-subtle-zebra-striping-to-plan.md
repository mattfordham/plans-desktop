# Add Very Subtle Zebra Striping To Plan Tables, And Row Hover Color Shift

**ID:** 068
**Created:** 2026-08-24T16:51
**Type:** feature
**Status:** completed
**Branch:** feature/068-add-very-subtle-zebra-striping-to-plan
**Completed:** 2026-08-25T10:32

## What
Add very subtle zebra striping (alternating row background tint) to the plan tables in the app, plus a background color shift when hovering a row.

## Why
Adds value by making the plan tables easier to scan: alternating row tints let the eye track a row across the id / [type] / title columns, and a hover shift gives clear feedback about which row the pointer (and its tap target) is over.

## How Summary
The only genuine "plan table" is the `Grid` of `planRow` GridRows inside `ProjectCard` (`body(for:)` → `Grid` → `planRow`). Introduce a pure, unit-testable `RowStyling` value type on `ProjectCard` that maps `(isEven, isHovered)` to a single "very subtle" `Color.primary` opacity, mirroring the codebase's existing pure-value seams (`titleSizing`, `planRowCellCount`). Make the row `ForEach` index-aware, add a single `@State hoveredRowID` (mirroring the `progressPopoverTaskID` single-selection pattern), and apply one continuous `.background` + `.onHover` on each `GridRow` — the `Grid` is already built at `horizontalSpacing: 0` specifically so a row's single highlight background is one gapless region.

**Files of note:**
- `Sources/Plans/ProjectCard.swift` — the plan table lives here: `body(for:)` (Grid + row ForEach ~L471), `planRow(_:)` GridRow (~L500), pure-value constants (`titleSizing`/`planRowCellCount` ~L167), and the canonical hover pattern to mirror (`RowActionGlyph`/`StarToggleGlyph` `@State hovering` + `.onHover` + `Color.primary.opacity(...)` + `.easeOut(duration: 0.12)`).
- `Tests/PlansTests/ProjectCardTests.swift` — where the pure `RowStyling` opacity mapping is unit-tested, following the suite's "assert pure values, don't render the view" convention.

## How
- [x] Step 1: Add a failing test in `Tests/PlansTests/ProjectCardTests.swift` for a pure `ProjectCard.RowStyling` value — assert even rows get 0 opacity, odd rows get a small nonzero stripe opacity, hover adds an additional shift, stripe+hover opacities are "very subtle" (each ≤ ~0.08), and hover always reads at least as strong as the resting stripe. (RED)
- [x] Step 2: Add the pure `RowStyling` type + a `static let rowStyling` constant on `ProjectCard` (alongside `titleSizing`/`planRowCellCount`), exposing `backgroundOpacity(isEven:isHovered:) -> Double`, with stripe alpha ~0.03 and hover alpha ~0.06 so tests go GREEN. (GREEN)
- [x] Step 3: Make the plan-row `ForEach` in `body(for:)` index-aware — `ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in planRow(row, index: index) }` — preserving `TaskRow` identity via `\.element.id`.
- [x] Step 4: Add `@State private var hoveredRowID: String?` to `ProjectCard` (mirroring `progressPopoverTaskID`), and in `planRow` apply one continuous `.background(Color.primary.opacity(ProjectCard.rowStyling.backgroundOpacity(isEven: index.isMultiple(of: 2), isHovered: hoveredRowID == row.task.id)))` plus `.onHover { hoveredRowID = $0 ? row.task.id : nil }` and `.animation(.easeOut(duration: 0.12), value: hoveredRowID)` on the `GridRow`, without disturbing the existing per-cell `OpenDetailOnTap` tap seams or the `.padding(.vertical, 5)`.
- [x] 👁 Step 5: Build and run the app (`./build.sh`) and visually confirm the plan rows show a very subtle alternating stripe and a slightly stronger hover shift in both light and dark mode, with tap-to-open-detail still working.

## Verification
- `swift test` passes, including the new `RowStyling` opacity tests (targeted: the ProjectCard tests).
- The plan rows in a project card render an alternating, barely-there background tint (odd rows tinted, even rows untinted).
- Hovering a row shifts its background to a slightly stronger (still subtle) tint, animated with the existing 0.12s ease-out timing.
- The stripe/hover tint adapts to light and dark appearance (uses `Color.primary.opacity`), and tapping a row still opens its detail window.

## Impact Scope
_Not applicable (fewer than 3 files affected: ProjectCard.swift + its test)._

## Assumptions

### Initial (from elaboration)
- [low] Scope of "plan tables" = only `ProjectCard`'s plan-row `Grid`; `MenuBarView`'s `ProjectGlanceRow` list (rows of projects, not plans) and `PlanDetailView`'s markdown/list `ForEach`s are excluded. **Why:** research found `ProjectCard` is the only genuine table of *plan* rows; the task says "plan tables," which points squarely at it. Recommended default with no user input available in yolo mode.
- [low] Stripe opacity ~0.03 and hover opacity ~0.06 via `Color.primary.opacity(...)` (adaptive to light/dark). **Why:** the ask is "very subtle"; the existing glyph hovers use 0.10 which reads much stronger across a full-width row, so a smaller alpha was chosen. Exact magnitudes are a UX judgement call the description didn't specify.
- [high] Striping is keyed by stable per-row index (not per-visible-scroll-position), and hover is purely visual (no change to hit-testing / tap seams). **Why:** matches the existing `progressPopoverTaskID` single-selection state pattern and the glyph `.onHover` precedent, which never alter hit-testing. Single plausible path given codebase conventions.
- [high] Style is centralized as a pure, unit-testable `RowStyling` value type on `ProjectCard` rather than an inline magic opacity, and no `List`/`Table`/shared `ViewModifier`/`EnvironmentKey` is introduced. **Why:** the codebase has an explicit "pure value seam" convention (`titleSizing`, `planRowCellCount`) that is testable without rendering, and the four existing glyph hovers are each inline `@State` + `.onHover` — matching house style and enabling TDD.

### Discovered during execution
- [high] `RowStyling.backgroundOpacity` returns the hover alpha (0.06) FLATLY for any hovered row regardless of parity, rather than resting+delta. **Why:** simpler and satisfies every test constraint — hover (0.06) > even-rest (0) and > odd-rest (0.03), all values ≤ 0.08, and a hovered row always reads ≥ the resting odd stripe. Avoids an even/odd hover asymmetry that would make hover strength depend on which row you happen to be over.
- [high] The row `.background` is applied OUTSIDE `.padding(.vertical, 5)` (after it in the modifier chain), so the tint fills the full padded row region. **Why:** stripes then span the whole row height and adjacent striped rows abut across the Grid's `verticalSpacing: 2`, reading as continuous zebra bands; placing it inside the padding would leave a 5pt untinted gutter above/below each row's content and break the band look.
- [low] Kept the explicit stripe 0.03 / hover 0.06 alphas from the plan's suggested range. **Why:** "very subtle" is a UX judgement the description left open; these match the elaboration's initial assumption and stay well under the existing glyph-hover 0.10 which reads too strong across a full-width row.

## Changes
- `Sources/Plans/ProjectCard.swift`:
  - Added a pure, unit-testable `RowStyling` struct (`stripeOpacity = 0.03`, `hoverOpacity = 0.06`, `backgroundOpacity(isEven:isHovered:) -> Double`) and `static let rowStyling` constant, sitting alongside `titleSizing` / `planRowCellCount`.
  - Added `@State private var hoveredRowID: String?`.
  - Made `body(for:)`'s plan-row loop index-aware: `ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in planRow(row, index: index) }` (identity preserved via `\.element.id`).
  - Updated `planRow(_ row:index:)` to apply one continuous `.background(Color.primary.opacity(ProjectCard.rowStyling.backgroundOpacity(isEven:isHovered:)))` + `.onHover { hoveredRowID = … }` + `.animation(.easeOut(duration: 0.12), value: hoveredRowID)` on the `GridRow`, after the existing `.padding(.vertical, 5)`. Per-cell `OpenDetailOnTap` tap seams and the trailing action button's hit target are untouched.
- `Tests/PlansTests/ProjectCardTests.swift`: added 5 `RowStyling` opacity tests (even-rest = 0, odd-rest nonzero, hover > rest for both parities, all values ≤ ~0.08 "very subtle", hover ≥ resting odd stripe). Asserts pure values without rendering the view (suite convention).
- Tests: `swift test --filter ProjectCardTests` passes; `swift build` succeeds.
- **Deferred to review:** Step 5 (👁) — visual confirmation, performed during `/plan-review`. It FAILED three times and drove a structural rework (below).

### Review rework (commit 4ef0714)
The original implementation applied the band via `.background` on a `GridRow`. That
does not produce a row background: `GridRow` is a layout declaration, so SwiftUI
propagates the modifier to each CELL, and every cell's backdrop tracks its own
CONTENT rather than its allotted column width. Three symptoms followed, all
confirmed with a temporary solid-red diagnostic build:
- a wide unpainted channel where a short `[bug]` badge sat in a column sized for
  the widest label `[refactor]`;
- an untinted right edge on rows with few or no action glyphs (the trailing cell
  was only as wide as its content);
- ragged band heights, since each cell hugged its own content height.

Two intermediate fixes (moving the column gap onto cell content; `maxWidth`/
`maxHeight: .infinity` on the cells) did not work — a cell's own frame and the
title's `fixedSize` override modifiers propagated from the GridRow.

Final fix: each row is an `HStack` — a real view owning ONE background spanning
the full row. The Grid's cross-row column alignment is reproduced by pinned widths
in a new pure `RowColumns` seam (`statusWidth` 20, `idWidth` 40, `typeWidth` 80
sized for `[refactor]`, `titleMaxWidth` `.infinity`, `columnGap` 8,
`rowHorizontalPadding` 8). The title column flexes so the band always reaches the
trailing edge, and the horizontal inset lets the tint extend past the leading and
trailing glyphs. `planRowCellCount` (5) is unchanged.

**Follow-up worth watching:** the id/type columns are now PINNED rather than
auto-sized, so an unusually long plan id or a future longer type label would clip
where the Grid would have grown. Widen `RowColumns` if that appears.

## Notes
Research (Explore agent) confirmed: `ProjectCard.body(for:)` builds the plan table as a `Grid(horizontalSpacing: 0, verticalSpacing: 2)` iterating `ForEach(rows) { planRow($0) }` (~L471-475); `planRow` is a five-cell `GridRow` with only `.padding(.vertical, 5)` and no row background/divider/hover today. The `horizontalSpacing: 0` design was chosen so a row's single highlight `.background` is one continuous gapless region (see the comments at ~L466-476), which this task now uses. Hover pattern to mirror: `RowActionGlyph`/`StarToggleGlyph` — `@State hovering` + `.onHover { hovering = $0 }` + `Color.primary.opacity(...)` background + `.animation(.easeOut(duration: 0.12), value:)`.
