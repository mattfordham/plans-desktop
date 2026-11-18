# Balance Masonry Columns By Height In Browser Window Scroll Mode

**ID:** 045
**Created:** 2026-06-10T00:00
**Type:** bug
**Status:** completed
**Branch:** fix/045-balance-masonry-columns-by-height
**Completed:** 2026-06-10T00:00

## What
**Clarified scope (the real ask):** make the fit-to-screen grid use **even-height rows** — every row the same height — instead of each row stretching to its tallest card's proportional height. The **column/row arrangement stays exactly as it is** (reading-order `rowIndices`; no bin-packing). The only change: in `fitCardGrid`, replace the per-row proportional heights from `fitRowHeights` with a single shared row height = the viewport height divided evenly across the rows (`(viewport - chrome) / rowCount`), floored at `fitRowMinHeight` (when even that overflows, clamp to the floor and let the `ScrollView` scroll, exactly as today). Cards still clip internally (#038) via the same `constrainedHeight`. Scroll mode (`variableCardGrid`) is unchanged.

## Why
In fit mode today, `fitRowHeights` stretches each row to fill the viewport while preserving its proportion to the tallest card in that row — so a row containing the giant "Client A" card stays much taller than a row of small/empty cards. The user wants the rows visually even (uniform height throughout), which reads as a tidy grid. Dividing the viewport equally across rows gives every row the same height; over-full cards clip/scroll internally as they already do.

## How
> **Scope reset (after manual testing).** The earlier plan (greedy column bin-packing for scroll mode + a fit-mode column rework) was reverted in full — it changed the column arrangement, which is NOT wanted. The real ask is just even-height rows in fit mode. All prior code changes were `git checkout`'d back to HEAD; the steps below are the actual, minimal plan.

- [x] Step 1: Add a pure static `evenRowHeights(rowCount:viewportHeight:spacing:padding:minRowHeight:) -> [CGFloat]` to `Sources/Plans/BrowserWindow.swift` (next to `fitRowHeights`, ~line 112). Return an array of length `rowCount` where every element is the SAME shared height = `(viewportHeight - chrome) / rowCount`, where `chrome = 2*padding + (rowCount-1)*spacing`. Floor each at `minRowHeight`: when the even share would fall below `minRowHeight` (content overflows the viewport), return `minRowHeight` for every row and let the surrounding `ScrollView` absorb the overflow — mirroring `fitRowHeights`'s clamp-to-floor case. Guard: `rowCount <= 0` → `[]`; `viewportHeight <= 0` (not yet measured) → `minRowHeight` for every row (sensible first paint). Pure + total + unit-testable. Doc-comment in the `fitRowHeights` voice, noting it ignores per-row natural heights entirely (every row is uniform).
- [x] Step 2: Add unit tests for `evenRowHeights` in `Tests/PlansTests/BrowserWindowTests.swift` (new `// MARK:` section, match existing style): all rows equal (e.g. 3 rows, viewport 600 → each `(600 - chrome)/3`); the shared height never below `minRowHeight`; overflow (many rows / small viewport) → every row exactly `minRowHeight`; `rowCount: 0` → `[]`; `viewportHeight: 0` → all `minRowHeight`. Write before/alongside step 1 (TDD).
- [x] Step 3: In `fitCardGrid(columns:)`, replace the `let finalHeights = Self.fitRowHeights(naturalRowHeights:...)` call with `let finalHeights = Self.evenRowHeights(rowCount: rows.count, viewportHeight: gridHeight, spacing: Self.gridSpacing, padding: Self.gridPadding, minRowHeight: Self.fitRowMinHeight)`. The `naturalRowHeights` local becomes unused — remove it. Everything else stays byte-for-byte: same `rows = Self.rowIndices(...)`, same `VStack`-of-`HStack` render, same `.frame(height: finalHeights[rowIndex])`, same `cardCell(for:constrainedHeight: finalHeights[rowIndex])` (#038 clip), same #040 stale-index guard, same `.background(measurementLayer(rows: rows, ...))` + `.onPreferenceChange` (measurement still populates `cardNaturalHeights`; even-rows just no longer consults it — keep the plumbing so #038 clip math and any future use stay intact). Update `fitCardGrid`'s doc-comment to say rows are now uniform height (viewport split evenly), not proportional.
- [x] Step 4: Decide on `fitRowHeights`/`distributeWithFloor`. They lose their production caller. KEEP both (their unit tests stay green; deletion is out of scope and would only add churn) — they remain as the documented proportional-fill baseline. Confirm no other production caller exists.
- [x] Step 5: `swift build` (must compile, no new warnings) + run ONLY `swift test --filter BrowserWindowTests` and `swift test --filter BrowserGridIndexBoundsTests` (both green; existing `fitRowHeights`/`rowIndices`/`columnAssignments` tests untouched + new `evenRowHeights` tests passing). Never run the bare full suite.
- [x] 👁 Step 6: Run `swift test`, then `./build.sh`; open the app in **fit mode** with the reported project set (one giant "Client A", several empty projects). Confirm every row is now the SAME height (no row towering over another), the column/card arrangement is unchanged from before, an over-full card still clips/scrolls internally, and resizing through 1→2→3→4 columns + toggling "Hide Empty" + reordering produce no flicker, oscillation, or "Index out of range" trap. Scroll mode should be unchanged from main.

## Verification
`swift test` passes (new `evenRowHeights` tests + all existing `fitRowHeights`/`rowIndices`/`columnAssignments`/bounds tests unchanged). In the running app's FIT mode, all rows render at one uniform height (viewport divided evenly) instead of the giant card's row towering over the others; the column/card arrangement is identical to before; over-full cards clip internally; resizing / Hide-Empty / reorder produce no flicker, oscillation, or index trap. Scroll mode is unchanged.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/BrowserWindow.swift` — new pure `evenRowHeights` (~near `fitRowHeights`); swap the `fitRowHeights` call in `fitCardGrid` for `evenRowHeights` and drop the now-unused `naturalRowHeights` local. (Also: `.scrollBounceBehavior(.basedOnSize)` on the cardGrid ScrollView.)
- [x] `Tests/PlansTests/BrowserWindowTests.swift` — `evenRowHeights` unit tests.

### Related Files (may need updates)
- `Sources/Plans/ProjectCard.swift` — no change expected; still measured via `measurementLayer`, still clips via `constrainedHeight` (#038).

### Endpoints/UI Affected
- Browser window dashboard, FIT (fit-to-screen) mode — rows become uniform height. Scroll (masonry) mode unchanged. Column/card arrangement unchanged in both.

## Assumptions

### Initial (from elaboration)
- [high] The real ask is even-height rows in FIT mode, with the column/card arrangement unchanged — NOT height-aware column bin-packing. **Why:** explicit user correction after testing the bin-packing build: "I simply wanted the grid to have even height rows… the column arrangement should be exactly as it was."
- [high] "Even rows" = the viewport height divided evenly across the rows (`viewport / rowCount`), with over-full cards clipping internally (#038). **Why:** explicit user choice via AskUserQuestion ("Divide viewport evenly"), over "tallest card drives it" or "natural even, no stretch."
- [high] Keep `fitRowHeights`/`distributeWithFloor` even though they lose their production caller. **Why:** their unit tests stay green unchanged; they document the prior proportional-fill baseline; deletion is out of scope and only adds churn.

### Discovered during execution
- [high] `evenRowHeights` is a standalone pure sibling of `fitRowHeights`, not a modification of it. **Why:** The segment required keeping `fitRowHeights`/`distributeWithFloor` and their tests green as the documented proportional baseline; a uniform-row policy is cleaner as a separate total function.
- [high] Even share that drops below `fitRowMinHeight` clamps EVERY row to the floor (not just deficient ones) and lets the ScrollView absorb overflow. **Why:** Mirrors `fitRowHeights`' clamp-to-floor contract and keeps rows uniform; per-row clamping would re-introduce uneven heights.
- [high] Updated the `gridHeight` and `cardNaturalHeights` `@State` doc-comments (beyond the listed `fitCardGrid` doc) because they described the now-removed proportional `fitRowHeights` path. **Why:** Leaving them would document wrong behavior; reported as a deviation. No executable code in those properties changed.
- [low] New `evenRowHeights` test calls emit the same pre-existing `#ActorIsolatedCall` warning that ~73 existing BrowserWindowTests calls already emit (test class is not `@MainActor`); treated as matching established style, not a new warning class. **Why:** `fitRowHeights`/`rowIndices`/`columnCount` tests carry identical warnings, so no new warning category was introduced.

## Changes
- (Reset) The first implementation pass — greedy `balancedColumnAssignments` column bin-packing for scroll mode plus a `fitColumnScale` fit-mode column rework — was fully reverted via `git checkout` after manual testing showed it changed the column arrangement, which the user did not want. Working tree returned to HEAD before the minimal even-rows change below.
- Added pure `evenRowHeights(rowCount:viewportHeight:spacing:padding:minRowHeight:) -> [CGFloat]` next to `fitRowHeights` in `BrowserWindow.swift`: every row gets the SAME share `(viewport - chrome)/rowCount` (chrome = `2*padding + (rowCount-1)*spacing`); clamps ALL rows to `minRowHeight` when the share would fall below it (ScrollView absorbs overflow, matching `fitRowHeights`); `[]` for `rowCount<=0`; floor-per-row for an unmeasured (`<=0`) viewport.
- Swapped the `fitRowHeights(naturalRowHeights:...)` call in `fitCardGrid` for `evenRowHeights(rowCount: rows.count, ...)` and removed the now-unused `naturalRowHeights` local. Column/row arrangement (`rowIndices`), the VStack/HStack render, `.frame(height:)`, the #038 `constrainedHeight` clip, the #040 stale-index guard, and the `measurementLayer`/`onPreferenceChange` plumbing are all unchanged.
- Added 6 `evenRowHeights` unit tests to `BrowserWindowTests.swift`. `fitRowHeights` + `distributeWithFloor` kept as the documented proportional-fill baseline (now test-only, no production caller). Refreshed stale doc-comments on the `gridHeight`/`cardNaturalHeights` @State props (no code change). `swift build` clean; `BrowserWindowTests` 79/79, `BrowserGridIndexBoundsTests` 4/4. Scroll mode unchanged.
- Follow-up (user request): added `.scrollBounceBehavior(.basedOnSize)` to the `cardGrid` `ScrollView` so the empty overscroll bounce is suppressed when the grid fits the window (fit mode), while a genuinely overflowing grid (fit-mode clamp-to-floor, or scroll mode) still scrolls normally. Also rewrote the now-stale `#039` comment inside the ScrollView to describe the even-rows behavior. `swift build` clean; `BrowserWindowTests` 79/79.

## Notes
The original report and an early draft plan framed this as "balance masonry columns by height." Manual testing clarified the actual intent: **even-height rows in fit mode, same column arrangement.** The title is now historical; the What/Why/How reflect the corrected scope. Earlier draft plan (now superseded): `~/.claude/plans/something-about-the-sizing-compressed-barto.md`.
