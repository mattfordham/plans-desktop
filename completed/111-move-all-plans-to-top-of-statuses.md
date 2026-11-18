# Move "All Plans" to the top of the statuses list

**ID:** 111
**Created:** 2026-11-08T15:15
**Type:** feature
**Status:** completed
**Completed:** 2026-11-09T10:45
**Branch:** feature/111-move-all-plans-to-top-of-statuses

## What
Move "All Plans" to the top of the statuses list

## Why
Adds value by surfacing the "All Plans" catch-all lens first in the sidebar's
"Status" section, so the most-used cross-project view is the easiest to reach
instead of sitting at the bottom of the list.

## How Summary
The sidebar "Status" order is driven entirely by the declaration order of the
`SmartView` `CaseIterable` enum in `BrowserWindow.swift`; `visibleSmartViews`
and the sidebar `ForEach` both follow `allCases` order with no sort. Moving
`case all` from last to first is the single load-bearing change; the three
order-asserting tests and the two order-describing doc comments are updated to
match.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — `SmartView` enum declares the status
  order; `case all` is the "All Plans" lens, currently declared last.
- `Tests/PlansTests/BrowserWindowTests.swift` — asserts the exact `allCases`
  order and the order of `visibleSmartViews` output.

## How
- [x] Step 1: Update the three order-asserting tests in `Tests/PlansTests/BrowserWindowTests.swift` to expect `.all` first — `testSmartViewAllCasesOrder` → `[.all, .review, .inReview, .pending, .inProgress, .blocked, .failed, .backlog]`; `testVisibleSmartViewsHidesEmptyLenses` → `[.all, .review, .inProgress, .blocked]` and `[.all]`; `testVisibleSmartViewsKeepsSelectedEmptyLens` → `[.all, .review, .failed]` (RED).
- [x] Step 2: Move `case all` (with its doc comment) to the top of the `SmartView` enum in `Sources/Plans/BrowserWindow.swift`, before `case review`, so `allCases` order puts "All Plans" first (GREEN).
- [x] Step 3: Update the enum's leading doc comment and the `visibleSmartViews` doc comment so both describe "All Plans" as first rather than last.
- [x] Step 4: Run the targeted test file (`swift test` filtered to `BrowserWindowTests`) and confirm the order tests pass.

## Verification
Verify `SmartView.allCases` begins with `.all` and the sidebar "Status" section
renders "All Plans" as the first row; the updated `BrowserWindowTests` order
assertions pass. Rawvalue-keyed persistence is unaffected (selections keyed by
`"all"` string, not ordinal).

## Impact Scope
_Not applicable (fewer than 3 files)._

## Assumptions

### Initial (from elaboration)
- [low] "Top of the statuses list" means the first row within the sidebar's "Status" section (above "Ready for review"), implemented by making `.all` the first `SmartView` case. **Why:** The research flagged this as the one open question; there is a separate "All Projects" card-stack entry (`SidebarSelection.allProjects`) in its own section, but the task says "statuses list", which maps to the Status smart-view section, so the "All Plans" lens is the intended target.
- [low] Auto-accepted Path A simple-task defaults (auto-generated Why/How/Verification) without interactive review. **Why:** Skip mode; the change is a single idiomatic enum-case reorder with validated file locations and clear test impact.

### Discovered during execution
- none

## Changes
Moved the "All Plans" lens to the top of the sidebar "Status" section by
reordering the `SmartView` `CaseIterable` enum — `case all` now precedes
`case review`, so `allCases` (and therefore `visibleSmartViews` and the sidebar
`ForEach`) renders "All Plans" first. No sort or ordering array was introduced;
the change is a single idiomatic case reorder and is persistence-safe (selections
keyed by rawValue `"all"`, not ordinal).

**Files touched:**
- `Sources/Plans/BrowserWindow.swift` — moved `case all` (with its doc comment)
  to the top of the `SmartView` enum; updated the enum's leading doc comment and
  the `BrowserViewModel.visibleSmartViews` doc comment to describe "All Plans
  first" (and refreshed the ordering issue reference from #102 to #111).
- `Tests/PlansTests/BrowserWindowTests.swift` — updated the three order
  assertions (`testSmartViewAllCasesOrder`, `testVisibleSmartViewsHidesEmptyLenses`,
  `testVisibleSmartViewsKeepsSelectedEmptyLens`) and their doc comments to expect
  `.all` first.

**Tests:** `swift test --filter BrowserWindowTests` → 137 tests, 0 failures.

## Notes
Ordering mechanism is intentionally enum declaration order (#102) — do NOT
introduce a sort or custom ordering array. Reordering a single `case` is the
minimal, idiomatic change and is persistence-safe (rawValue-keyed).
