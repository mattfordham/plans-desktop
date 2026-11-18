# Add Dynamic Card Height Adjustments

**ID:** 049
**Created:** 2026-06-12T19:41
**Type:** feature
**Status:** completed
**Completed:** 2026-06-17T09:58
**Branch:** feature/049-add-dynamic-card-height-adjustments

## What
Add dynamic card height adjustments?

Make the Browser window (Surface B) **fit mode** grid grow rows *per row* to fit
their content, instead of forcing every row to the same height. Today fit mode
divides the viewport evenly across all rows (`evenRowHeights`), so a row of tall
cards and a row of short cards get identical heights. The intent is for a row to
scale to its **tallest card**, while the grid still fills the viewport.

Note (from the captured context): when *every* card has the same content height
(e.g. the same number of plans), the grid will still look even — that's correct,
because all rows then share the same natural height. The change only makes rows
differ when their content differs.

## Why
Adds value by letting fit mode reflect real content: rows with denser cards get
the room they need while sparser rows stay compact, instead of every row being
clamped to a uniform viewport-share that wastes space on short rows and clips
tall ones.

## How Summary
Swap fit mode's uniform row sizing for content-driven sizing. The hidden
measurement layer already populates `cardNaturalHeights[projectPath]`; aggregate
those into a per-row "tallest card" array and feed it to the existing, already
tested `fitRowHeights(...)` (which proportionally scales rows and still fills the
viewport) in place of `evenRowHeights(...)`. Extract the per-row aggregation into
a small pure static helper so it can be unit-tested directly.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — `fitCardGrid()` (the call site, ~L516-533),
  `fitRowHeights`/`evenRowHeights` (~L120-242), and the new aggregation helper.
- `Tests/PlansTests/BrowserWindowTests.swift` — existing `fitRowHeights`/`evenRowHeights`
  tests; add the row-aggregation test here.

## How
- [x] Step 1: Add a failing test in `Tests/PlansTests/BrowserWindowTests.swift` for a
      new pure helper `naturalRowHeights(rows:projects:measured:minRowHeight:)` (name TBD)
      that maps each row of indices to the **tallest measured card height** in that row,
      falling back to `fitRowMinHeight` for cards with no measurement / empty rows.
      Cover: an uneven 2-row grid (e.g. row 0 tallest = 200, row 1 tallest = 120 →
      `[200, 120]`), a row whose cards are all unmeasured (→ floor), and a short final row.
- [x] Step 2: Implement `naturalRowHeights(...)` in `BrowserWindow.swift` as a pure
      `static` function (mirroring the style of `fitRowHeights`/`evenRowHeights`,
      ~L120-242): for each row of indices, take `measured[projects[idx].projectPath]`
      where present, `max()` them, default to `minRowHeight` when a row has no measured
      cards. Guard `idx < projects.count` (same stale-index concern as `fitCardGrid`).
      Make Step 1's test pass.
- [x] Step 3: In `fitCardGrid(columns:)` (~L522-533), replace the `evenRowHeights(...)`
      call with: build `naturalRowHeights` via the new helper from `rows`, `projects`,
      and `cardNaturalHeights`, then pass that array to
      `fitRowHeights(naturalRowHeights:viewportHeight:spacing:padding:minRowHeight:)`.
      Keep `gridHeight`, `Self.gridSpacing`, `Self.gridPadding`, `Self.fitRowMinHeight`.
      Per the design decision, fit mode still **stretches to fill the viewport** — this
      is exactly `fitRowHeights`' existing behavior, so no change to that function.
- [x] Step 4: Update the `#045` comment at ~L524-526 (which states "We no longer derive
      per-row natural heights here") to reflect that fit mode is once again content-driven,
      noting it now consumes `cardNaturalHeights` per row.
- [x] Step 5: Run `swift test` — confirm the new test passes and the existing
      `fitRowHeights`/`evenRowHeights`/measurement tests still pass. Leave `evenRowHeights`
      in place (it stays unit-tested) unless it becomes provably dead, in which case note
      it rather than removing in this task.
- [x] 👁 Step 6: Run `./build.sh`, open the Browser window in fit mode with projects of
      differing plan counts across rows, and confirm rows now differ in height (tall-card
      rows taller, short-card rows shorter) while the grid still fills the viewport with
      no bottom gap. Confirm a grid where all cards are equal still looks even.

## Verification
- `swift test` passes, including a new test asserting per-row tallest-card aggregation
  produces distinct heights for an uneven grid (and floor fallback for unmeasured/empty rows).
- In the running app (fit mode), rows visibly grow to fit their tallest card's content
  and differ row-to-row when content differs, while the grid still fills the viewport
  (no empty space at the bottom) and over-full cards still scroll/clip internally.
- A grid where all cards have equal content still renders with even rows (no regression).

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/BrowserWindow.swift` — add `naturalRowHeights(...)` pure helper;
      swap `evenRowHeights` → `fitRowHeights` in `fitCardGrid()`; update the `#045` comment.
- [x] `Tests/PlansTests/BrowserWindowTests.swift` — add the row-aggregation unit test.

### Related Files (may need updates)
- `Sources/Plans/ProjectCard.swift` — no change expected; its internal
  `constrainedHeight` ScrollView (clip/scroll over-full cards) keeps working with
  the new per-row heights. Verify only.
- `Sources/Plans/CardLayout.swift` — no change; `.fit` / `.scroll` mode toggle is untouched.

### Endpoints/UI Affected
- Browser window (Surface B) fit-mode grid — rows now size to their tallest card
  rather than to an even viewport share.

## Assumptions

### Initial (from elaboration)
_To be filled during elaboration_

### Discovered during execution
- [high] `naturalRowHeights` takes `projectPaths: [String]` rather than the full `[ProjectTasks]`. **Why:** keeps the helper pure and trivially unit-testable without constructing `ProjectTasks` fixtures; the call site supplies `projects.map(\.projectPath)`.
- [high] An empty row or a row with no in-bounds measured card falls back to `minRowHeight` (not 0). **Why:** matches the existing unmeasured-card default (`fitRowMinHeight`) and gives `fitRowHeights` a sensible non-zero natural to scale from.

## Changes
- `Sources/Plans/BrowserWindow.swift`: added pure `static func naturalRowHeights(rows:projectPaths:measured:minRowHeight:)` that maps each row to its tallest measured card height (falling back to `minRowHeight` for empty / fully-unmeasured rows, guarding stale indices). Rewrote `fitCardGrid(columns:)` to build per-row naturals via that helper and feed them to the existing `fitRowHeights(...)` instead of `evenRowHeights(...)`, restoring content-driven fit-mode sizing. Updated the `#039/#045` comment block accordingly. `evenRowHeights` left in place (still unit-tested).
- `Tests/PlansTests/BrowserWindowTests.swift`: added a `naturalRowHeights` test section (4 tests): uneven 2-row grid → `[200, 120]`, all-unmeasured row → floor, short final row, and stale-index skipping.
- Tests: `swift test --filter BrowserWindowTests` → 83 tests, 0 failures.

## Notes
- Captured autonomously (capture-only, no interactive elaboration). The original
  description was phrased as an open question ("Add dynamic card height
  adjustments?"); assumed intent is a feature request to make project/plan cards
  in the Browser window (Surface B) size their height dynamically to fit their
  content rather than using a fixed height. Confirm scope during elaboration.
