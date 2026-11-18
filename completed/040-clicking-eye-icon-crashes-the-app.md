# Clicking "eye" icon crashes the app

**ID:** 040
**Created:** 2026-06-08T10:52
**Type:** bug
**Status:** completed
**Branch:** fix/040-clicking-eye-icon-crashes-the-app
**Completed:** 2026-06-08T11:15

## What
Clicking the "eye" icon (the "Hide Empty" toggle in the browser toolbar) crashes
the app with a Swift "Index out of range" fatal error.

Crash signature:
- Exception: `EXC_BREAKPOINT (SIGTRAP)` — Swift runtime failure: Index out of range
- Crash site: `BrowserWindow.swift:493`, inside
  `closure #2 in BrowserWindow.fitCardGrid(columns:)`
- Triggered during a SwiftUI `ForEachChild.updateValue()` graph update on the
  main thread.

## Why
Improves reliability by fixing a hard crash on a routine toolbar action. The
eye/"Hide Empty" toggle is a primary control of the browser window — hitting it
should never bring the whole app down.

## How
Root cause (confirmed by research): a classic SwiftUI **stale-index race**. The
eye button calls `store.hideEmptyProjects.toggle()` (BrowserWindow.swift:312).
`sortedProjects` is a computed property that `.filter`s out empty projects when
`hideEmptyProjects` is true, so toggling it **shrinks the array**. But the grid
functions compute their index arrays once at the top from `sortedProjects.count`
and then subscript `sortedProjects[idx]` inside `ForEach` closures that SwiftUI
may re-evaluate against a newer (smaller) `sortedProjects` — so an index from the
old, larger count traps.

Three grid functions share the hazard, all in `BrowserWindow.swift`:
- `fitCardGrid` (line 471 `rows`, subscripts at 475 + 493)
- `measurementLayer` (subscript at 541; it receives `rows` from `fitCardGrid`)
- `variableCardGrid` (line 600 `assignments`, subscript at 608)

Chosen approach: **snapshot `sortedProjects` once per grid entry point** and
derive both the index arrays and every subscript from that one snapshot, plus add
bounds guards so any residual stale-`rows` re-evaluation can't trap.

- [x] Step 1: In `fitCardGrid(columns:)`, bind `let projects = sortedProjects`
      at the top (before `rows`). Compute `rows` from `projects.count`, and
      replace `sortedProjects[$0]` (line 475) and `sortedProjects[idx]` (line 493)
      with `projects[...]`. Guard each subscript: if `idx >= projects.count`, fall
      back to `Self.fitRowMinHeight` (line 475) / render nothing (line 493).
- [x] Step 2: Pass the same snapshot into the measurement pass — change
      `measurementLayer(rows:columns:)` to
      `measurementLayer(rows:columns:projects:)` and have it subscript the passed
      `projects` (line 541) with the same `idx < projects.count` guard. Update the
      call site at line 516 to pass `projects`.
- [x] Step 3: In `variableCardGrid(columns:)`, bind `let projects = sortedProjects`
      at the top, compute `assignments` from `projects.count`, subscript
      `projects[idx]` (line 608) with the same bounds guard.
- [x] Step 4: Add a focused unit test that reproduces the count-shrink race at the
      pure-helper level: assert `BrowserWindow.rowIndices` /
      `BrowserWindow.columnAssignments` only emit indices `< count`, and (if
      practical) a guard that subscripting the snapshot with any emitted index is
      in bounds. (`fitRowHeights` already returns one height per row, so
      `finalHeights[rowIndex]` stays in range and needs no change.)
- [x] 👁 Step 5: Build and run the app (`./build.sh`), open the browser window
      with a mix of empty and non-empty projects, and click the eye icon
      repeatedly in both grid modes (fit + variable/scroll) to confirm it no
      longer crashes. — User confirmed: no crash in either grid mode.

## Verification
- The app no longer crashes when the eye / "Hide Empty" toggle is clicked, in
  both the fit grid and the variable (scroll) grid, with projects being filtered
  in and out.
- `swift test` passes, including the new index-bounds test.

## Impact Scope
_Single file (`Sources/Plans/BrowserWindow.swift`) plus one test file — under the
3-file threshold, so no detailed Impact Scope needed._

## Assumptions

### Initial (from elaboration)
- [high] Root cause is the stale-index race between the `hideEmptyProjects`
  filter shrinking `sortedProjects` and the grid's pre-computed index arrays.
  **Why:** The crash stack is exactly `fitCardGrid` → `ForEachChild.updateValue`
  → `Array.subscript` out of range, and `sortedProjects` is confirmed to be a
  computed property that `.filter`s on `hideEmptyProjects`; `rows` is computed
  from `sortedProjects.count` at line 471 and reused inside the `ForEach`.
- [high] Fix via snapshot-once + bounds guards rather than restructuring the
  observation/timing. **Why:** Research found no existing safe-subscript helper
  and three structurally identical subscript sites; snapshotting the array each
  function uses and guarding the subscripts is the minimal, local, idiomatic
  SwiftUI fix and removes the trap regardless of update ordering.
- [low] Apply the same fix to all three grid functions (`fitCardGrid`,
  `measurementLayer`, `variableCardGrid`), not just the crashing line 493.
  **Why:** Research flagged lines 541 and 608 as the same hazard; fixing only the
  reported site would leave latent crashes, but the user only reported one path —
  flagging this as a scope decision made on their behalf.
- [low] `finalHeights[rowIndex]` (lines 493, 506) is left unguarded. **Why:**
  `fitRowHeights` returns exactly one height per input row and `rowIndex` is
  enumerated from `rows`, so it stays in bounds — but this relies on that
  invariant holding, so it's noted rather than asserted.

### Discovered during execution
- [high] On the stale-index bounds guard, chose to SKIP rendering the card
  entirely (wrap the `cardCell`/`ProjectCard` in `if idx < projects.count { ... }`)
  rather than substitute a placeholder view. **Why:** a stale index only appears
  for a frame during the toggle-driven shrink; the next re-render against the
  fresh, smaller snapshot drops the row anyway, so rendering nothing is the
  correct transient behavior and matches the surrounding `if`-gated `ForEach`
  padding style.
- [high] Created a new test file `Tests/PlansTests/BrowserGridIndexBoundsTests.swift`
  (class `BrowserGridIndexBoundsTests`). **Why:** the existing `BrowserWindowTests`
  focuses on `BrowserViewModel` ordering/badges; a dedicated file keeps the #040
  index-bounds regression contract self-documenting. Sweeps count 0...12 ×
  columns 1...5, asserting in-range AND exact `0..<count` coverage for both
  `rowIndices` and `columnAssignments`.
- [high] Changed `measurementLayer`'s signature to add a `projects:` parameter
  (`measurementLayer(rows:columns:projects:)`) and updated its sole call site in
  `fitCardGrid`. **Why:** it must index the SAME snapshot `fitCardGrid` captured,
  not re-read the computed `sortedProjects`, to avoid the same stale-index race.

## Changes
- `Sources/Plans/BrowserWindow.swift`: snapshotted `sortedProjects` into a local
  `let projects` at the top of `fitCardGrid` and `variableCardGrid`, and computed
  `rows` / `assignments` from `projects.count`. Replaced all
  `sortedProjects[idx]` subscripts in the grid `ForEach` closures with the
  snapshot, each behind an `if idx < projects.count { … }` bounds guard.
- `Sources/Plans/BrowserWindow.swift`: changed `measurementLayer(rows:columns:)`
  → `measurementLayer(rows:columns:projects:)` so it indexes the SAME snapshot
  `fitCardGrid` captured (guarded the same way); updated the `.background(...)`
  call site to pass `projects:`.
- `Tests/PlansTests/BrowserGridIndexBoundsTests.swift` (new): regression test
  for #040 — sweeps `count` 0...12 × `columns` 1...5 asserting `rowIndices` and
  `columnAssignments` only emit in-range indices AND together cover exactly
  `0..<count` (no gaps/dupes).
- `swift build` clean; `swift test --filter BrowserGridIndexBoundsTests` → 4
  tests, 0 failures.

## Notes
Full crash report captured 2026-06-08 10:52:20 -0700, macOS 15.7.4,
MacBookPro18,3 (arm64). App build: /Applications/Plans.app (release).

Eye button: `BrowserWindow.swift:311-321` → `store.hideEmptyProjects.toggle()`.
`sortedProjects` computed property with the empty-filter: `BrowserWindow.swift:238-252`.
