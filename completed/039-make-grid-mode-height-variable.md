# Make Grid Mode Height Variable

**ID:** 039
**Created:** 2026-06-07T00:00
**Type:** feature
**Status:** completed
**Completed:** 2026-06-08T00:00
**Branch:** feature/039-make-grid-mode-height-variable

## What
Make grid mode "height variable". Meaning if a row of cards "can" be shorter/taller allow for it (based on flex box).

## Why
Adds value by letting the card grid (scroll mode) reflow with content-driven,
variable card heights instead of forcing every card in a row to the tallest
card's height. Today `LazyVGrid` equalizes each row to its max-height cell, so a
short card leaves a visible empty gap below it (the trailing `Spacer` only pins
content to the top — the cell still occupies the full row height). A masonry-
style layout removes those gaps, packs cards more densely, and matches the
"based on flex box" intent (intrinsic, content-driven heights).

## How
- [x] Step 1: Add a pure, unit-testable column-assignment helper to `BrowserWindow.swift` — `static func columnAssignments(count:columns:) -> [[Int]]` returning, for each column, the ordered indices of cards assigned to it. Distribute card indices across columns in reading order (index `i` → column `i % columns`) so the grid still reads left-to-right, top-to-bottom while allowing per-column variable heights. Floor `columns` at 1; return `[]` for `count <= 0`. Follow the existing pure-helper style (`columnCount`, `rowCount`).
- [x] Step 2: Add a `variableCardGrid` (masonry) view path in `BrowserWindow.swift` for scroll mode: an `HStack(alignment: .top, spacing: gridSpacing)` of N column `LazyVStack(spacing: gridSpacing)`s, each column rendering its assigned cards (via the Step 1 helper) at their natural content height. Each card keeps its existing chrome: `.frame(maxWidth: .infinity)`, `.id(project.projectPath)`, drop-indicator overlay, `.draggable`/`.dropDestination` reorder behavior, and the `+`-glyph new-plan closure. No trailing `Spacer` and no `.frame(height:)` in this path — cards size to content.
- [x] Step 3: Wire `cardGrid` to choose the layout: when `effectiveMode == .fit` (and `fitHeight != nil`), keep the EXISTING `LazyVGrid` fit path unchanged (uniform rows fill the viewport). Otherwise (scroll mode) render the new `variableCardGrid`. Keep the surrounding `ScrollView` + `ScrollViewReader` (drill-down `scrollTo`) and the `GeometryReader` width/height probe (`GridWidthKey`/`GridHeightKey`) intact so column count, drill-down, and toolbar all still work.
- [x] Step 4: Add unit tests in `Tests/PlansTests/BrowserWindowTests.swift` for `columnAssignments(count:columns:)`: even split, uneven remainder, single column, zero/negative count, columns floored at 1, and that the union of all column index-lists is exactly `0..<count` in the expected reading order. Run only this file: `swift test --filter BrowserWindowTests`.
- [x] 👁 Step 5: Build and run the app (`./build.sh`) and visually confirm variable heights. **Reworked during review:** the user clarified the intent — variable heights belong to the FIT (fill-the-screen) path: each row sizes to its content while the grid still fills the viewport (stretch when short, shrink-then-scroll when tall). Confirmed visually by the user after the rework.

## Verification
- `swift test --filter BrowserWindowTests` passes, including the new `columnAssignments` tests.
- In scroll mode, cards in the same row render at their own content heights (no forced equal-height gaps); the grid reads left-to-right, top-to-bottom.
- Cards still reflow 1→2→3→4 columns as the window/split resizes.
- Drag-to-reorder and the per-card "+" new-plan affordance still work.
- Fit-to-screen mode still divides the viewport into uniform rows (unchanged).

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/BrowserWindow.swift` — add `columnAssignments` helper, add `variableCardGrid` masonry view, branch `cardGrid` between the new scroll path and the existing fit path.
- [ ] `Tests/PlansTests/BrowserWindowTests.swift` — add `columnAssignments` unit tests.

### Related Files (may need updates)
- `Sources/Plans/ProjectCard.swift` — no change expected; card already sizes to content (no `maxHeight`). Verify the internal `Spacer` (used to fill fit-mode cells) doesn't force extra height in the natural-height scroll path.

### UI Affected
- Surface B browser grid (scroll/card mode) — cards gain variable, content-driven heights (masonry). Fit-to-screen mode visually unchanged.

## Assumptions

### Initial (from elaboration)
- [low] "Height variable" means a masonry-style layout where cards in the same visual row may have different heights, not merely content-sizing (which already happens but is defeated by `LazyVGrid`'s row-height equalization). **Why:** Only this interpretation produces a user-visible change matching "if a row of cards can be shorter/taller allow for it (based on flex box)"; research confirmed `LazyVGrid` forces uniform row heights.
- [low] Variable heights apply to scroll mode only; fit-to-screen (`.fit`) mode keeps its existing uniform-row behavior. **Why:** `.fit` mode (#033) is explicitly about dividing the viewport into equal rows that fill the screen — variable heights contradict that goal. Scoping to scroll mode is the least-surprising, smallest change and avoids reworking the `fitRowHeight` math.
- [low] Implement masonry via N column `LazyVStack`s in an `HStack(alignment: .top)` using an index-modulo column assignment, rather than a custom `Layout` protocol type. **Why:** It keeps lazy rendering, reuses the existing pure `columnCount` helper, needs no per-card height measurement pass, and exposes a pure assignment helper that fits the codebase's "pure helper + thin view" testing pattern. A custom `Layout` would be view-only code that can't be unit-tested as a pure function.
- [high] Reuse the existing `columnCount(forWidth:)`, `GridWidthKey`/`GridHeightKey` probe, `ScrollViewReader` drill-down, and drag/drop modifiers unchanged. **Why:** Research and the code show these are pure/independent of the row-equalization behavior; preserving them keeps #017 (reorder) and #004 (drill-down) working with no extra risk.

### Discovered during execution
- [high] Extracted the shared per-card chrome into `cardCell(for: ProjectTasks)` and the fit `LazyVGrid` into `fitCardGrid(columns:fitHeight:)`, so BOTH the fit and the new `variableCardGrid` paths reuse identical chrome. **Why:** Avoids duplicating the `.id` / drop-indicator / drag-drop / "+" closure across two paths; the fit branch just wraps `cardCell` in `.frame(height: fitHeight)` to preserve its existing uniform-row visual behavior unchanged.
- [high] In the fit path the trailing `Spacer`/`VStack` wrapper was REMOVED; the fixed `.frame(height: fitHeight)` alone (the card's own internal Spacer fills the slack) reproduces the prior fit behavior. **Why:** With the scroll path no longer using `LazyVGrid`, the old `if fitHeight == nil { Spacer }` branch only ever ran in fit mode as a no-op-less wrapper; the fit branch only needs the fixed-height frame, matching the documented #033 behavior.
- [high] `variableCardGrid` iterates `ForEach(0..<assignments.count, id: \.self)` (the helper already floors columns at 1 and returns `[]` for empty), rather than `0..<columns`. **Why:** `columnAssignments` is the single source of truth for column count in this path; when `sortedProjects` is empty it returns `[]` so the HStack renders nothing and the empty-state overlay shows.
- [low] Each masonry column uses `.frame(maxWidth: .infinity, alignment: .top)` so columns share width evenly (mirroring `LazyVGrid`'s flexible columns) and top-align. **Why:** Keeps the 1→2→3→4 reflow width behavior consistent with the fit path while letting each column's height be content-driven.

## Changes
- `Sources/Plans/BrowserWindow.swift`:
  - Added pure helper `columnAssignments(count:columns:) -> [[Int]]` (index-modulo column distribution; columns floored at 1; `[]` for empty).
  - Added `variableCardGrid(columns:)` — masonry layout: `HStack(alignment: .top)` of per-column `LazyVStack`s rendering cards at natural content height (no equal-row height, no trailing Spacer/fixed frame).
  - Extracted shared per-card chrome into `cardCell(for:)` (ProjectCard + `.id` + drop-indicator overlay + `.draggable`/`.dropDestination` reorder + "+" new-plan closure), reused by both paths.
  - Extracted the existing fit `LazyVGrid` into `fitCardGrid(columns:fitHeight:)` (uniform-row behavior unchanged) and branched `cardGrid` to render `fitCardGrid` when `fitHeight != nil`, else `variableCardGrid`. ScrollView/ScrollViewReader, GeometryReader width/height probe, toolbar, empty-state overlay, and drill-down scroll all preserved.
- `Tests/PlansTests/BrowserWindowTests.swift`: added 6 `columnAssignments` unit tests (even split, uneven remainder, single column, zero/negative count, columns floored at 1, union-coverage).
- Tests: `swift test --filter BrowserWindowTests` → 60 tests, 0 failures.

## Notes
_Additional context_
