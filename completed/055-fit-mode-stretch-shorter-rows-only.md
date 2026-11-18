# Fit-Mode Grid: Stretch Shorter Rows Only So The Tall Row Isn't Exaggerated

**ID:** 055
**Created:** 2026-06-18T00:00
**Type:** refactor
**Status:** completed
**Completed:** 2026-06-18T15:30
**Branch:** refactor/055-fit-mode-stretch-shorter-rows-only

## What
In the browser window's Fit to Screen mode, `BrowserWindow.fitRowHeights`
currently multiplies every row by the same factor on the stretch path
(`availableForRows / naturalTotal`), preserving relative proportions — so an
already-tall row (e.g. Client A with 8 plans) gets stretched even taller,
leaving a big empty gap below its content. Instead, on the stretch path only,
distribute the leftover slack to the shorter rows first (water-fill / level-up
toward equalization): raise the shortest rows to a common level until the
viewport is filled; no row drops below its natural height; the tallest row stays
at natural until shorter rows catch up. Only the stretch branch changes —
shrink/overflow/clamp-to-floor behavior stays exactly as-is.

## Why
Improves the look and usability of Fit to Screen mode. Today the uniform stretch
factor exaggerates whichever row is tallest: a row containing a dense card (many
plans) balloons past its content, leaving a conspicuous empty gap below the
content while shorter rows stay cramped. Filling the viewport by leveling the
shorter rows up first keeps the grid full (no bottom gap) while making the tall
row sit close to its real content height — which is what the user expects.

## How Summary
Change only the **stretch branch** of `BrowserWindow.fitRowHeights`
(`Sources/Plans/BrowserWindow.swift`). Today, when content fits the viewport, it
multiplies every row by one factor (`availableForRows / naturalTotal`),
preserving proportions and thus exaggerating the tallest row. Replace that with a
**water-fill (level-up)** distribution in a new pure helper
`stretchShorterRows(naturalRowHeights:availableForRows:)`: find the water level
`L` (closed form, by walking the sorted naturals) at which
`sum(max(natural_i, L)) == availableForRows`, then set each row to
`max(natural_i, L)`. Short rows rise to the common level first; the tallest row
stays at its natural height until the shorter rows catch up; the result still
fills the viewport exactly. The shrink path (`factor < 1`) and its
`distributeWithFloor` clamp-to-floor handling are left untouched, as are the
early guards (empty input, unmeasured/degenerate viewport, all-rows-at-floor
overflow). On the stretch path every row only grows, so no per-row floor handling
is needed there.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — add `stretchShorterRows` helper near
  `distributeWithFloor` (~line 172); rewire the stretch branch of `fitRowHeights`
  (~lines 148-164); update the `fitRowHeights` doc comment (~lines 100-118) so
  the "Stretch" bullet describes level-up toward equalization instead of a single
  proportional factor.
- `Tests/PlansTests/BrowserWindowTests.swift` — rewrite
  `testFitRowHeightsStretchesToFillPreservingProportions` (~lines 657-670, the
  proportion-preserving contract is intentionally replaced) and add water-fill
  tests; confirm `testFitRowHeightsExactFitLeavesRowsUnchanged` and
  `testFitRowHeightsSingleRowStretchesToFill` still pass.

## How
- [x] Step 1 (Red): In `Tests/PlansTests/BrowserWindowTests.swift`, add failing
      tests for the new stretch behavior:
      - Slack goes to the short row: naturals `[300, 100]`, ample viewport →
        short row grows toward 300, tall row stays at/near 300 until the short
        row catches up; result + chrome sums to viewport exactly.
      - Surplus beyond the gap: naturals `[300, 100]` with a viewport large enough
        that both rise above 300 → both rows equal at a common level, still
        filling exactly.
      - Sum-fills-viewport invariant across a few naturals/viewports.
      - Every stretch-path result height `>= its natural height`.
- [x] Step 2 (Red): Rewrite `testFitRowHeightsStretchesToFillPreservingProportions`
      to assert the NEW behavior — fills the viewport exactly, but the shorter row
      rises toward the taller (gap shrinks vs natural; shorter row gains more
      absolute height than the taller row) — replacing the old 2:1-proportion
      assertion.
- [x] Step 3 (Green): Add `static func stretchShorterRows(naturalRowHeights:availableForRows:) -> [CGFloat]`
      in `BrowserWindow` near `distributeWithFloor` (~line 172). Implement the
      water-fill: sort naturals ascending (track original indices), walk the
      sorted list accumulating to find the bracket where the running total reaches
      `availableForRows`, solve for the level `L` there in closed form, then return
      `max(natural_i, L)` mapped back to original order. Handle edge cases:
      `availableForRows <= naturalTotal` returns naturals unchanged (no slack);
      empty input returns `[]`.
- [x] Step 4 (Green): Rewire the stretch branch of `fitRowHeights`
      (`Sources/Plans/BrowserWindow.swift` ~lines 148-164): compute
      `factor = availableForRows / naturalTotal`; if `factor >= 1`, return
      `Self.stretchShorterRows(naturalRowHeights:availableForRows:)`. Leave the
      `factor < 1` shrink path and its `distributeWithFloor` clamp exactly as-is.
      Leave the early guards (lines 127-146) untouched.
- [x] Step 5 (Refactor): Update the `fitRowHeights` doc comment (~lines 100-118)
      so the "Stretch (content fits)" bullet describes leveling the shorter rows
      up to a common water level (equalization) rather than scaling every row by a
      single factor preserving relative proportions. Add a doc comment to
      `stretchShorterRows` in the same style as `distributeWithFloor`.
- [x] Step 6: Run `swift test` — all new + rewritten tests pass; the unchanged
      shrink/overflow tests (`testFitRowHeightsShrinksAboveFloorToFill`,
      `testFitRowHeightsClampsAllRowsToFloorOnHeavyOverflow`,
      `testFitRowHeightsExactFitLeavesRowsUnchanged`,
      `testFitRowHeightsSingleRowStretchesToFill`) stay green.
- [x] 👁 Step 7: `./build.sh`, open the browser window in **Fit to Screen** mode
      with a tall project (many plans) plus an empty/short project, and confirm
      the tall first row is no longer stretched past its content while the grid
      still fills the window (no empty gap at the bottom).

## Verification
- `swift test` passes: new water-fill tests green; the rewritten stretch test
  asserts equalization (shorter row rises toward taller, still fills viewport);
  the shrink, clamp-to-floor, exact-fit, single-row, empty-input, and
  unmeasured-viewport tests are all still green and unchanged.
- Manual (`./build.sh`): in Fit to Screen mode with a dense project + a short one,
  the previously-too-tall first row now sits close to its natural content height,
  shorter rows take up the slack, and the grid still fills the window. Verify the
  single-column case (falls back to `.scroll`) and the overflow case (many tall
  projects) are unaffected.

## Impact Scope
_Not applicable — change touches 2 files (BrowserWindow.swift, BrowserWindowTests.swift)._

## Assumptions

### Initial (from elaboration)
- [high] Only the stretch branch (`factor >= 1`) changes; shrink/overflow/clamp-to-floor
  stays as-is. **Why:** The user explicitly scoped the change to the stretch path,
  and the screenshot issue only manifests when content fits the viewport.
- [high] "Stretch shorter rows only" = water-fill / level-up (raise the lowest
  rows to a common level first), not "give all slack to the last row" or
  "cap the stretch factor". **Why:** The user picked "Stretch shorter rows only"
  from the four offered layout options, whose description is "distribute leftover
  space to SHORTER rows first (toward equalizing)".
- [low] No per-row floor handling on the stretch path. **Why:** On this path every
  row only grows from its natural height, and the early guards already establish
  it isn't the all-rows-at-floor overflow case, so a row can't fall below
  `minRowHeight` here. (Flagged low because it relies on the upstream guards
  holding that invariant.)
- [low] `stretchShorterRows` takes `availableForRows` (already net of chrome)
  rather than recomputing chrome internally. **Why:** Mirrors how
  `distributeWithFloor` is structured (caller computes chrome once), keeping the
  helper pure and consistent with the existing sibling helper.

### Discovered during execution
- [high] Made `stretchShorterRows` `static` and internal (not `private`), matching the visibility of `fitRowHeights` rather than `distributeWithFloor`. **Why:** keeps it directly unit-testable later if desired; current tests stay black-box through `fitRowHeights`, and internal visibility is harmless within the module.
- [high] Kept the new Step-1/Step-2 black-box tests routed through `fitRowHeights` (not calling `stretchShorterRows` directly). **Why:** the segment explicitly says to prefer black-box tests, and these are EXPECTED to be red until the next segment rewires the stretch branch. Verified the helper's closed-form math independently in a scratch compile (slack-to-short, surplus-levels-all, sums fill exactly).
- [low] In `testFitRowHeightsStretchSlackGoesToShortRowFirst`, the not-yet-rewired `fitRowHeights` returns the floor (160) for the short row instead of the helper's 150. **Why:** flags that when the next segment wires `stretchShorterRows` into `fitRowHeights`, the per-row floor interaction (minRowHeight vs water-fill level) must be reconciled — the helper itself does not consider the floor.
- [high] Branched on `factor >= 1` (computed `availableForRows / naturalTotal`) to select the stretch path, rather than comparing `availableForRows >= naturalTotal` directly. **Why:** the plan's Step 4 specifies the `factor >= 1` form, and it reuses the same `factor` the shrink path needs, keeping a single source of truth. The exact-fit case (`factor == 1`) enters `stretchShorterRows`, which has a strict no-slack guard (`availableForRows > naturalTotal`) and returns naturals unchanged — `testFitRowHeightsExactFitLeavesRowsUnchanged` stays green.
- [high] Did NOT route the stretch path through `distributeWithFloor`, so the segment-1 concern about the short row clamping to the floor (160) is now moot — on the stretch path the helper alone decides heights and rows only grow. **Why:** the stretch path can't drop a row below natural, and the upstream all-rows-at-floor guard already handles the overflow case, so the floor is never relevant when `factor >= 1`.

## Changes
- `Sources/Plans/BrowserWindow.swift`:
  - Added `static func stretchShorterRows(naturalRowHeights:availableForRows:) -> [CGFloat]`
    (water-fill / level-up): finds the level `L` where `sum(max(natural_i, L)) ==
    availableForRows` (closed form via sorted naturals + suffix sums), returns
    `max(natural_i, L)` in original order. Returns naturals unchanged when there's
    no slack (`availableForRows <= naturalTotal`) and `[]` for empty input. Sibling
    to `distributeWithFloor`, with a matching doc comment.
  - Rewired the stretch branch of `fitRowHeights`: when `factor >= 1`, returns
    `Self.stretchShorterRows(...)` instead of scaling every row by one factor. The
    shrink path (`factor < 1`), its `distributeWithFloor` floor clamp, and all early
    guards are unchanged.
  - Updated the `fitRowHeights` doc comment "Stretch (content fits)" bullet to
    describe leveling the shorter rows up to a common water level (the tallest row
    stays at natural until shorter rows catch up) instead of proportional scaling.
- `Tests/PlansTests/BrowserWindowTests.swift`:
  - Added 3 water-fill tests: `testFitRowHeightsStretchSlackGoesToShortRowFirst`,
    `testFitRowHeightsStretchSurplusBeyondGapLevelsAllRows`,
    `testFitRowHeightsStretchFillsViewportAndNeverBelowNatural`.
  - Rewrote `testFitRowHeightsStretchesToFillPreservingProportions` →
    `testFitRowHeightsStretchLevelsShorterRowsUp` (asserts equalization: shorter row
    rises toward taller, gap shrinks, still fills viewport exactly).
- Tests: `swift test --filter BrowserWindowTests` → 86 executed, 0 failures. The
  unchanged shrink/clamp-to-floor/exact-fit/single-row/empty-input/unmeasured-viewport
  tests all stay green.
- Step 7 (👁 manual Fit-to-Screen verification) deferred to `/plan-review` per
  worktree mode.

## Notes
A detailed pre-plan was drafted before capture at
`~/.claude/plans/about-row-heights-see-snoopy-puzzle.md`.

User chose "Stretch shorter rows only" from the layout-behavior options offered
during planning (the other options were: cap rows at natural height; stretch the
last row only; cap the per-row stretch factor).
