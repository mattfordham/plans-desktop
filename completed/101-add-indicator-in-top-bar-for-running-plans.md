# Add Indicator In Top Bar For The Count Of Currently Running Plans

**ID:** 101
**Created:** 2026-11-07T14:54
**Type:** feature
**Status:** completed
**Completed:** 2026-11-07T15:12
**Branch:** feature/101-add-indicator-in-top-bar-for-running-plans

## What
Add indicator in top bar for the count of currently running plans and clicking on it should show a drop-down dialogue of the running plans.

## Why
Adds value by surfacing, window-wide, how many plans are actively in progress across every registered project and giving one-click access to them — so the user can see and jump to running work from anywhere in the browser without hunting through the sidebar's "In progress" smart view.

## How Summary
Add one window-wide `ToolbarItem` to `BrowserWindow`'s existing root `.toolbar` that shows a count badge of currently-running plans (status `in-progress`) and opens a dropdown `Menu` listing those plans; each menu row opens that plan in the detail column (and selects the In-progress smart view) via the existing `selectedRowID` / `store.browserSelection` mechanisms. All counting/listing reuses `BrowserViewModel.rows(in:matching: .inProgress)`; glyph/tint/label come from the existing `TaskStatus`/`SmartView` vocabulary. The indicator hides entirely when nothing is running, mirroring `smartViewRow`/`iconSpaceCounts`.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — adds the toolbar indicator + dropdown; adds a small pure `BrowserViewModel.runningPlanRows(in:)` helper reused by both the badge count and the menu contents.
- `Sources/Plans/TaskStatus+Glance.swift` — source of the `in-progress` symbol/color/label (read-only; not modified).
- `Tests/PlansTests/BrowserWindowTests.swift` — unit tests for the new pure helper.

## How
- [x] Step 1: Add a pure, view-less helper `BrowserViewModel.runningPlanRows(in projects: [ProjectTasks]) -> [TaskRow]` that returns `rows(in: projects, matching: .inProgress)` (so both the badge count and the dropdown contents share one definition). Write the failing unit test(s) first in `BrowserWindowTests.swift` (TDD red): assert it returns exactly the `in-progress` rows across projects in project order, and returns an empty array when none are in progress.
- [x] Step 2: Make the test(s) pass by adding the helper (TDD green). Run only `swift test --filter BrowserWindowTests`.
- [x] Step 3: Add a window-wide `ToolbarItem` to `BrowserWindow`'s existing root `.toolbar` (alongside New Plan / Link Project / Backlog), using the `Menu { … } label: { Label }` idiom from `ProjectStackView`. The label shows the running count with `TaskStatus.inProgress.symbolName` and `.glanceColor`; suppress the whole item when the running count is zero (mirror `smartViewRow`/`iconSpaceCounts`). Add a `.help(...)` string.
- [x] Step 4: In the `Menu` body, `ForEach` the running `TaskRow`s and render one `Button` per row showing project name + title (reuse `TaskRow.projectName` / `.title` and the `.inProgress` glyph/tint from the vocabulary — never hardcode). Each button's action selects the In-progress smart view (`store.browserSelection = .smart(.inProgress)`) and opens the plan in the detail column by setting `selectedRowID` to `row.id`, reusing the existing navigation mechanism.
- [ ] 👁 Step 5: Build and run the app (`./build.sh`), confirm the toolbar indicator appears with the correct running count, the dropdown lists the running plans, clicking a plan opens it in the detail column, and the indicator disappears when nothing is in progress.

## Verification
- `swift test --filter BrowserWindowTests` passes, including the new `runningPlanRows` tests.
- In the running app, the browser window toolbar shows a play-glyph indicator with the count of in-progress plans across all projects.
- Clicking the indicator opens a dropdown listing each running plan (project name + title); the list hides / the indicator disappears when there are no in-progress plans.
- Clicking a plan in the dropdown opens that plan in the detail column.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/BrowserWindow.swift` — add `BrowserViewModel.runningPlanRows(in:)` helper and the toolbar indicator + dropdown Menu.
- [x] `Tests/PlansTests/BrowserWindowTests.swift` — unit tests for the new helper.

### Related Files (read-only, not modified)
- `Sources/Plans/TaskStatus+Glance.swift` — supplies the `in-progress` symbol / color / label vocabulary.
- `Sources/Plans/PlansStore.swift` — supplies `store.projects` and `store.browserSelection`.

### Endpoints/UI Affected
- Browser window (Surface B) root toolbar — gains a running-plans indicator button with a dropdown.

## Assumptions

### Initial (from elaboration)
- [high] ~~"Running plans" = plans whose status is `in-progress`~~ **Corrected in review:** "running" means live `TaskRunner` runs (capturing, elaborating, executing, …). A plan can be `in-progress` with nothing working on it, and must not appear. **Why:** Two meanings exist in code — file-derived status `.inProgress` (stable, matches the existing "In progress" sidebar smart view) vs. `TaskRunner.runningRunCount` (transient, only app-launched runs). The phrase "currently running plans" is ambiguous, but status `.inProgress` is the stable, user-meaningful definition that matches the rest of the app's vocabulary and the existing cross-project lens.
- [low] "Top bar" = the browser window's root toolbar, not the macOS menu bar. **Why:** "Clicking shows a drop-down dialogue" fits a toolbar `Menu`, and the browser toolbar already has `store` in scope; the menu bar surface (Surface A) already shows per-status counts.
- [low] Clicking a plan in the dropdown navigates to it (opens it in the detail column and selects the In-progress smart view). **Why:** The task says "show a drop-down of the running plans"; making each row open its plan reuses the existing `selectedRowID` navigation and is the obviously useful behavior, but display-only was a defensible alternative.
- [high] The indicator and dropdown reuse `BrowserViewModel.rows(in:matching: .inProgress)` and the existing `TaskStatus`/`SmartView` glyph/color/label vocabulary rather than new counting/filtering or inline glyphs. **Why:** CLAUDE.md centralizes the vocabulary and the research found the exact reusable cross-project row list; a parallel implementation would be an anti-pattern.
- [high] The indicator hides entirely at zero running plans. **Why:** Matches the established `smartViewRow` and `iconSpaceCounts` convention of suppressing zero counts.
- [high] The indicator lives on the root `BrowserWindow` toolbar (window-wide), not `ProjectStackView`'s stack-only toolbar. **Why:** A running-plans indicator should be visible under any sidebar selection, like New Plan / Backlog; the stack-only toolbar is explicitly scoped to the card stack (CLAUDE.md).

### Discovered during execution
- [low] Each dropdown button's label shows `"<projectName> — <title ?? task.id>"`, falling back to the task id when `title` is nil. **Why:** `TaskRow.title` is optional; a running plan with no parsed title would otherwise render a blank menu item, so the stable composite task id is the safest non-empty fallback.

## Changes

**Steps 1–4 (segment 1) complete** on branch `feature/101-add-indicator-in-top-bar-for-running-plans`.

- `Sources/Plans/BrowserWindow.swift`:
  - Added pure helper `BrowserViewModel.runningPlanRows(in: [ProjectTasks]) -> [TaskRow]`, a thin alias over `rows(in:matching: .inProgress)` so the top-bar indicator and the In-progress smart view never diverge.
  - Added a window-wide `ToolbarItem` to the root `.toolbar` (after the Backlog item). It derives `runningRows` once via the helper, and is wrapped in `if !runningRows.isEmpty` so the whole indicator is suppressed at zero (mirroring `smartViewRow` / `iconSpaceCounts`). The label is `Label("\(count)", systemImage: TaskStatus.inProgress.symbolName)` tinted with `TaskStatus.inProgress.glanceColor` (vocabulary, not inlined), with `.help("Plans currently in progress across all projects")`.
  - The dropdown `Menu` `ForEach`es the running rows, one `Button` per row labelled `"<projectName> — <title ?? task.id>"` with the `.inProgress` glyph/tint. Each action sets `store.browserSelection = .smart(.inProgress)` then `selectedRowID = row.id`, reusing the existing selection/navigation mechanism to open the plan in the detail column.
- `Tests/PlansTests/BrowserWindowTests.swift`:
  - Added `testRunningPlanRowsAreInProgressRowsInProjectOrder` and `testRunningPlanRowsEmptyWhenNothingInProgress` (TDD).

**Test/build status:** `swift test --filter BrowserWindowTests` → 118 tests, 0 failures. `swift build` → success.

**Step 5 (👁 run-the-app check)** is deferred to review (yolo mode runs headless). The reviewer should build/run the app and confirm the toolbar indicator shows the running count, the dropdown lists running plans, clicking one opens its detail, and the indicator disappears at zero running plans.

### Review fixes
- Indicator opens a fixed-width (320pt) popover instead of an NSMenu so long titles wrap.
- Indicator now lists live `TaskRunner` runs via `TaskRunner.runningSnapshots` → `BrowserViewModel.activeRunItems(from:projects:)`; each row shows title, verb · project. Clicking selects the run's project and, for an existing plan, opens it in the detail column. Verb vocabulary moved to `RunMode.activityVerb` (shared with the run-progress dialog). `runningPlanRows` removed.

## Notes
_Additional context_
