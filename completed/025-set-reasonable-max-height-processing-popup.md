# Set A More Reasonable Max Height On The Processing Pop Up

**ID:** 025
**Created:** 2026-06-06T00:00
**Type:** feature
**Status:** completed
**Branch:** feature/025-set-reasonable-max-height-processing-popup
**Completed:** 2026-06-06T00:00

## What
Set a more reasonable max height on the processing pop up.

The run-progress dialog (`RunProgressSheet`) — shown when clicking the live
spinner on a project-card plan row to watch a task execute — grows to fill the
entire screen height when the agent produces a long log. The dialog should cap
at a reasonable height and let its inner log scroll instead of expanding without
bound.

## Why
Adds value by keeping the progress popover usable: a dialog pinned to the card
spinner that stretches the full height of the display is awkward, hides the rest
of the UI, and defeats the inner `ScrollView` that already exists to handle long
logs.

## How
- [x] Add a `maxHeight` to `RunProgressSheet`'s outer frame in
      `Sources/Plans/PlanDetailView.swift` (currently
      `.frame(minWidth: 480, minHeight: 360)` at ~line 282) so the dialog caps at
      a reasonable height (e.g. `maxHeight: 520`) instead of growing unbounded.
      The existing `logList` `ScrollView` then scrolls overflow within the cap.
- [x] Build (`swift build`) to confirm it compiles cleanly.

## Verification
- The progress popover (click a running plan's spinner on its project card) no
  longer expands to the full screen height when the log is long.
- The log area inside the dialog scrolls when content exceeds the cap, and still
  auto-scrolls to the newest line.
- The dialog still renders correctly when presented as a sheet from the plan
  detail view (`minHeight` floor preserved).

## Impact Scope
_Single file (`PlanDetailView.swift`) — Impact Scope not required._

## Assumptions

### Initial (from elaboration)
- [low] Cap the dialog with a `maxHeight` of ~520pt on the existing
  `RunProgressSheet` frame rather than wrapping the popover content separately.
  **Why:** The frame already sets `minWidth`/`minHeight` here and the inner
  `logList` is already a `ScrollView`, so adding `maxHeight` is the smallest
  change that makes the existing scroll view do its job. The exact value is a
  UX judgement the task didn't specify.
- [high] The "processing pop up" refers to `RunProgressSheet` shown via the
  card-spinner `.popover` in `ProjectCard.swift`. **Why:** It's the only
  run-progress dialog in the app, it is the one shown in the task screenshot
  ("Executing task #352"), and its frame sets no `maxHeight`, which directly
  explains the unbounded growth.

### Discovered during execution
- [high] Used `maxHeight: 520` (the value suggested in the plan) and kept the
  existing `minWidth: 480, minHeight: 360`. **Why:** The plan specified 520
  explicitly; combining a `minHeight: 360` floor with a `maxHeight: 520` cap is
  valid in a single `.frame` call and lets the dialog size to content between
  those bounds, with the inner `logList` ScrollView absorbing overflow above the
  cap. This applies uniformly to both presentation paths (sheet and popover);
  the sheet was already comfortably within 520pt, so the cap is effectively a
  no-op for the sheet and only constrains the unbounded popover case.

## Changes
- `Sources/Plans/PlanDetailView.swift`: Added `maxHeight: 520` to
  `RunProgressSheet`'s outer `.frame` (now `minWidth: 480, minHeight: 360,
  maxHeight: 520`) so the run-progress dialog caps its height instead of growing
  unbounded; the inner `logList` ScrollView scrolls overflow within the cap. Added
  a comment noting the cap exists because the card-spinner popover has no enclosing
  window to bound it. `swift build` clean.

## Notes
_Additional context_
