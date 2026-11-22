# Add Filter for "Completed" (Similar to Backlog)

**ID:** 131
**Created:** 2026-11-21T23:02
**Type:** feature
**Status:** review
**Branch:** feature/131-add-filter-for-completed

## What
Add Filter for "Completed". Similar to Backlog.

Add a cross-project **"Completed"** smart view to the browser sidebar's "Status"
section (Surface B), modelled on the existing **"Backlog"** smart view. Selecting
it shows every completed task across all registered projects in the content
column, exactly as Backlog shows every backlogged task.

## Why
Adds value by giving a cross-project view of finished work: completed tasks are
already parsed and loaded into the store (from each project's `.plans/completed/`
directory) but are currently unreachable in the browser — they are excluded from
every active lens and there is no dedicated lens for them. A "Completed" smart
view surfaces this existing-but-hidden data with a one-case change, mirroring the
proven Backlog pattern.

## How Summary
Add a new `SmartView.completed` case and wire it through the three existing
exhaustive vocabulary `switch`es (label / symbol / color) by delegating to the
already-centralized `TaskStatus.completed.*` vocabulary — Completed is a real
status, so no new static vocabulary is needed (unlike Backlog). Add a
`completedRows(_:)` row-mapping helper (mirroring `backlogRows`) that sources from
each project's completed tasks, and route `.completed` to it in
`rows(in:matching:)`. Everything else (sidebar rendering, counts, zero-count
hiding, selection persistence) flows generically off `SmartView`/`rows(in:matching:)`
and needs no change, except extending `resolveRow` so a clicked completed row opens
in the read-only detail column.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — `SmartView` enum + its three vocabulary `switch`es, `completedRows(_:)` helper, `rows(in:matching:)` predicate, `resolveRow`; the only source file to edit.
- `Sources/Plans/TaskType+Glyph.swift` — holds `TaskStatus.completed.filterLabel` ("Completed"); reused, not modified.
- `Sources/Plans/TaskStatus+Glance.swift` — holds `TaskStatus.completed.glanceColor` (green) and `.symbolName` ("checkmark.circle.fill"); reused, not modified.
- `Sources/Plans/TaskParser.swift` — `ProjectTasks.tasks` carries completed tasks (status `.completed`); read-only reference for the predicate.
- `Tests/PlansTests/BrowserWindowTests.swift` — smart-view tests to extend (`testSmartViewAllCasesOrder`, `testSmartViewLabelsAndVocabulary`) plus a new `completed` rows test.

## How
- [x] Step 1: In `Tests/PlansTests/BrowserWindowTests.swift`, add a failing `testSmartViewCompletedRowsAcrossProjects` (mirror `testSmartViewBacklogRowsAcrossProjects` at ~line 1519) asserting `BrowserViewModel.rows(in:matching: .completed)` returns the `.completed` tasks (from `ProjectTasks.tasks`) across projects in project/parser order. Also update `testSmartViewAllCasesOrder` (~line 1556) to expect `.completed` last in `allCases`, and extend `testSmartViewLabelsAndVocabulary` (~line 1532) with `SmartView.completed.label == TaskStatus.completed.filterLabel` / `.symbolName == TaskStatus.completed.symbolName` / `.color == TaskStatus.completed.glanceColor`. (TDD red: these fail to compile until Steps 2–4 land.)
- [x] Step 2: In `Sources/Plans/BrowserWindow.swift`, add `case completed` to the `SmartView` enum (~line 618), placed **last**, after `.backlog`, so it sits at the end of the sidebar "Status" section (`allCases` order == display order).
- [x] Step 3: Add a `.completed` arm to each of the three exhaustive `switch`es on `SmartView` (`label` ~621, `symbolName` ~635, `color` ~649), delegating to `TaskStatus.completed.filterLabel` / `TaskStatus.completed.symbolName` / `TaskStatus.completed.glanceColor` respectively — matching how the other real-status lenses (`.pending`, `.review`, `.inReview`, `.inProgress`) delegate to `TaskStatus.<case>.*`. Do NOT add new `backlog`-style statics; Completed is a real status.
- [x] Step 4: Add a `completedRows(_ project:) -> [TaskRow]` helper next to `backlogRows(_:)` (~line 1053) that maps `project.tasks.filter { $0.status == .completed }` to `TaskRow`s (same shape as `backlogRows`/`activeRows`, preserving parser order, no re-sort). Then add `case .completed: return projects.flatMap { completedRows($0) }` to `rows(in:matching:)` (~line 1306). Source from `project.tasks`, NOT `activeRows` (which drops `.completed`).
- [x] Step 5: Extend `resolveRow(in:id:)` (~line 922) so a completed row is resolvable: after the active and backlog lookups, also search `projects.flatMap { completedRows($0) }`. This lets a clicked completed plan open (read-only) in the detail column; without it `validSelection(_:in:)` would clear the selection. Keep active rows winning any id collision (search order: active → backlog → completed).
- [x] Step 6: Run `swift build` then `swift test`; confirm the new `.completed` tests pass, the two totality loops over `SmartView.allCases` (~lines 1545, 1758) still pass, and no other test regressed.
- [ ] 👁 Step 7: Run the app (`./build.sh`) and visually confirm the sidebar "Status" section shows a "Completed" lens (checkmark glyph, green tint, last in the section) whenever any project has completed tasks, that selecting it lists completed tasks across projects, and that clicking one opens its plan read-only in the detail column.

## Verification
- `swift build` succeeds (all three `SmartView` `switch`es stay exhaustive with the new case; no `default:` added).
- `swift test` passes, including the new `testSmartViewCompletedRowsAcrossProjects`, the updated `testSmartViewAllCasesOrder` (expecting `.completed` last), the extended `testSmartViewLabelsAndVocabulary`, and the existing `allCases` totality loops.
- Manual (👁): in a machine with at least one project that has completed tasks, the browser sidebar's "Status" section shows a "Completed" entry (checkmark glyph, green tint) positioned last; selecting it lists completed tasks across all projects; the lens is hidden when no project has completed tasks (generic `visibleSmartViews` zero-count hiding); clicking a completed row opens its plan in the detail column.

## Impact Scope
_Not applicable — fewer than 3 files are modified (`Sources/Plans/BrowserWindow.swift` and `Tests/PlansTests/BrowserWindowTests.swift`). The three vocabulary files are read-only references._

## Assumptions

### Initial (from elaboration)
- [low] Interpreted the task as adding a cross-project **"Completed" smart view** to the browser sidebar's "Status" section (Surface B), directly analogous to the existing "Backlog" smart view — not a per-card or per-project filter, and not a menu-bar glance change. **Why:** "Similar to Backlog" points squarely at the Backlog smart view, which lives in the sidebar Status section; research found Backlog is implemented solely there via `SmartView.backlog`.
- [high] Reuse the existing centralized `TaskStatus.completed` vocabulary (`filterLabel` "Completed", `symbolName` "checkmark.circle.fill", `glanceColor` green) rather than adding new `backlog`-style statics. **Why:** Completed is a real `TaskStatus`, and every other real-status lens (`.pending`, `.review`, `.inReview`, `.inProgress`) already delegates to `TaskStatus.<case>.*`; Backlog/All Plans only needed dedicated statics because they are NOT statuses. Research confirmed the `.completed` vocabulary already exists.
- [high] Source the lens from `project.tasks` filtered to `.completed` (via a new `completedRows(_:)` helper), NOT from `activeRows` (which explicitly drops completed). **Why:** Research confirmed completed tasks are loaded into `ProjectTasks.tasks` with `.completed` status and excluded from `activeTasks`; `backlogRows`/`activeRows` are the exact mapping template to mirror.
- [low] Placed "Completed" **last** in `SmartView.allCases` (after `.backlog`), so it sits at the end of the sidebar "Status" section. **Why:** `allCases` order IS the sidebar display order; completed is terminal/archive-like work, grouping naturally with Backlog at the end. The source description didn't specify ordering — flagged for review.
- [low] Decided a clicked completed row **should open read-only in the detail column**, so Step 5 extends `resolveRow` to also consult completed rows. **Why:** The generic `validSelection(_:visibleIn:)` path already keeps a displayed completed row selected, so making it openable is the consistent, least-surprising behavior; but `resolveRow` currently scans only active+backlog, so this is an explicit UX choice the description didn't specify.
- [high] Kept the generic `visibleSmartViews` zero-count hiding for the Completed lens (hidden when no project has completed tasks, except when selected). **Why:** Every other status lens behaves this way and the rule is applied generically to all `SmartView` cases; no special-casing is warranted.

### Discovered during execution
- [high] `resolveRow` searches active → backlog → completed, each as a separate guarded lookup so active wins any id collision (matching the pre-existing active-first precedence). **Why:** Step 5 mandates the order; `completedRows` scans `project.tasks`, which a stale poll could overlap with active/backlog, so active's truthful live state must win.
- [high] Renamed `testResolveSelectedRowReturnsNilForCompletedTaskId` → `testResolveSelectedRowReturnsCompletedTaskRow`. Old assertion: `XCTAssertNil(resolveSelectedRow([p1], "/proj1/099"))` (completed id `099` unresolvable). New assertion: the same fixture (completed `099` in `tasks`, excluded from `activeTasks`) now resolves — `completed?.id == "/proj1/099"` and `completed?.task.status == .completed`; the active `001` still resolves. **Why:** completed rows are now resolvable so a clicked completed plan opens read-only.
- [high] Renamed `testValidSelectionClearsCompletedPlan` → `testValidSelectionKeepsCompletedPlan`. Old assertion: after a plan left `activeTasks` (fixture had only `activeTasks`, empty `tasks`), `validSelection` returned `nil`. New assertion: `before`/`after` fixtures now populate `tasks` too; `after` keeps the task in `tasks` as `.completed` (absent from `activeTasks`), and `validSelection("/proj1/001", in: [after]) == "/proj1/001"` — the selection is KEPT. **Why:** a completed plan now stays selected and opens read-only instead of clearing. Note the old fixture's empty `tasks` would still have cleared (completedRows scans `tasks`), so the fixture was updated to express the intended "task moved to completed" state rather than "task vanished".

## Changes
Added a cross-project **"Completed"** smart view to the browser sidebar's "Status"
section (Surface B), mirroring the existing "Backlog" lens.

**`Sources/Plans/BrowserWindow.swift`:**
- Added `case completed` to the `SmartView` enum, placed **last** (after `.backlog`),
  so it renders at the end of the sidebar "Status" section (`allCases` order ==
  display order).
- Added `.completed` arms to all three exhaustive vocabulary `switch`es (`label`,
  `symbolName`, `color`), each delegating to the centralized
  `TaskStatus.completed.filterLabel` / `.symbolName` / `.glanceColor` — no new
  `backlog`-style statics (Completed is a real status). Switches stay exhaustive;
  no `default:` added.
- Added a `completedRows(_ project:) -> [TaskRow]` helper next to `backlogRows(_:)`
  mapping `project.tasks.filter { $0.status == .completed }` to `TaskRow`s (same
  shape as `backlogRows`/`activeRows`, parser order preserved, no re-sort), and
  routed `case .completed: return projects.flatMap { completedRows($0) }` in
  `rows(in:matching:)`. Sourced from `project.tasks`, not `activeRows` (which drops
  `.completed`).
- Extended `resolveRow(in:id:)` with a third lookup over
  `projects.flatMap { completedRows($0) }` (search order active → backlog →
  completed, active wins id collisions) so a clicked completed row opens read-only
  in the detail column rather than being cleared by `validSelection`. Updated the
  doc comments on `resolveRow`/`validSelection` accordingly.

**`Tests/PlansTests/BrowserWindowTests.swift`:**
- Added `testSmartViewCompletedRowsAcrossProjects` (asserts `rows(in:matching: .completed)`
  returns only `.completed` tasks from `ProjectTasks.tasks` in project/parser order).
- Updated `testSmartViewAllCasesOrder` to expect `.completed` last in `allCases`.
- Extended `testSmartViewLabelsAndVocabulary` with the three `.completed`
  vocabulary assertions.
- Rewrote two pre-existing tests to the new resolvable-completed behavior:
  `testResolveSelectedRowReturnsNilForCompletedTaskId` →
  `testResolveSelectedRowReturnsCompletedTaskRow`, and
  `testValidSelectionClearsCompletedPlan` → `testValidSelectionKeepsCompletedPlan`.

**Vocabulary files** (`TaskStatus+Glance.swift`, `TaskType+Glyph.swift`) and
`TaskParser.swift` — unchanged (read-only references, as planned).

**Verification:** `swift build` clean (one pre-existing, unrelated `Sendable`
warning in `PlansStore`); `swift test --filter BrowserWindowTests` = 144 tests,
0 failures (includes the new/updated `.completed` tests and the `SmartView.allCases`
totality loops).

Step 7 (👁 run the app and visually confirm the Completed lens) is deferred to
`/plan-review` per worktree mode — see state file `## Observations`.

## Notes
_Additional context_
