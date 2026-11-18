# Add Count Badges To The Projects In Sidebar

**ID:** 108
**Created:** 2026-11-07T22:27
**Type:** feature
**Status:** completed
**Completed:** 2026-11-08T08:33
**Branch:** feature/108-add-count-badges-to-sidebar-projects

## What
Add count badges to the projects in sidebar. I'm not sure how to do this compactly, but come up with something

## Why
Adds value by letting you see, at a glance, how much outstanding work each project
has without selecting it — the sidebar already does this for every smart view, but
Project rows carry no count, so the one place that lists every project is the one
place with no outstanding-work signal.

## How Summary
Give each Project row in the browser sidebar the same compact trailing count badge
the smart-view rows already use: a bare `.caption.monospacedDigit().secondary`
`Text`, suppressed at zero. The count is the project's active (outstanding) task
count (`project.activeTasks.count`), surfaced through a new pure
`BrowserViewModel.activeCount(_:)` helper so it has a unit-test seam. The Project
`ForEach` body is lifted into a small `@ViewBuilder projectRow(_:)` that mirrors
`smartViewRow` exactly (Label + `Spacer(minLength: 4)` + conditional count),
preserving the existing `.lineLimit(1)`, `.tag`, and `.onMove` wiring.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — sidebar Project `ForEach` (render site ~L284–293), `smartViewRow` template (~L313–330), and `BrowserViewModel` where the new `activeCount` helper lands (next to `statusCounts`, ~L859).
- `Sources/Plans/TaskParser.swift` — `ProjectTasks.activeTasks` (L310), the count source; read-only reference.
- `Tests/PlansTests/BrowserWindowTests.swift` — `makeProject` fixture (L47) + new `activeCount` test alongside the `sidebarGlyph` tests (~L1119).

## How
- [x] Step 1: Add a pure static helper `BrowserViewModel.activeCount(_ project: ProjectTasks) -> Int` returning `project.activeTasks.count`, placed next to `statusCounts(_:)` in `BrowserWindow.swift` (~L859), with a doc comment noting it is the single source of truth for the sidebar project-row badge and excludes completed and backlogged tasks by construction.
- [x] Step 2: Write a failing XCTest in `Tests/PlansTests/BrowserWindowTests.swift` (in a new `// MARK: - activeCount` section near the `sidebarGlyph` tests, ~L1119) that asserts `activeCount` returns `activeTasks.count` for a project with several active tasks, and `0` for a project with none. Use the existing `makeProject` fixture's `activeTasks:` parameter. Run only this file's tests (`swift test --filter PlansTests.BrowserWindowTests`) and watch it fail (RED), then pass once Step 1 is in (GREEN).
- [x] Step 3: Extract the sidebar Projects `ForEach` body into a `@ViewBuilder private func projectRow(_ project: ProjectTasks) -> some View` structured exactly like `smartViewRow`: an `HStack` of the existing `Label(project.projectName, systemImage: BrowserViewModel.sidebarGlyph(starred:))` with `.lineLimit(1)`, then `Spacer(minLength: 4)`, then `if BrowserViewModel.activeCount(project) > 0 { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }`. Keep the `.tag(SidebarSelection.project(project.projectPath))` and the `.onMove` modifier on the `ForEach` unchanged.
- [x] Step 4: Call `projectRow(project)` from the `ForEach(sidebarProjects, id: \.projectPath)` in place of the inline `Label`. Verify no `GeometryReader`, measured width, or `.frame(idealWidth:)` sentinel is introduced (per the ProjectStackView/#063 layout-loop guidance in CLAUDE.md — a trailing `Text` count needs none).
- [x] 👁 Step 5: Build and run the app (`./build.sh`), open the Browser window, and confirm each Project row in the sidebar shows a right-aligned count of its active tasks, that projects with no outstanding work show no badge, that long project names still truncate (name truncates before the count), and that drag-reorder still works. _(Implementation prerequisites in place; visual observation ⏳ deferred to review per yolo mode — see state file Observations.)_

## Verification
- `swift test --filter PlansTests.BrowserWindowTests` passes, including the new `activeCount` test.
- In the running app, every sidebar Project row with active tasks shows a compact trailing count matching the number of outstanding (non-completed, non-backlog) tasks; rows with zero active tasks show no badge.
- The badge styling matches the existing smart-view counts (monospaced-digit, secondary) with no new capsule/background shape.
- Long project names still truncate with `.lineLimit(1)` and the count stays visible; drag-reorder of the Projects section is unaffected.

## Impact Scope
_Only 2 files affected (BrowserWindow.swift, BrowserWindowTests.swift) — Impact Scope section omitted (threshold is 3+ files)._

## Assumptions

### Initial (from elaboration)
- [low] The badge shows the project's ACTIVE (outstanding, non-completed, non-backlog) task count via `project.activeTasks.count`, not a total-including-completed count or a per-status breakdown. **Why:** the whole app vocabulary (menu bar glance, smart-view counts, `.active` view mode, `hasOutstandingWork`) treats "active" as the unit of outstanding work, and the single trailing pill is the compact, convention-consistent choice for a 220pt-min sidebar column; a 5-icon per-status breakdown (`ProjectStatusBadges`) would crowd the name. The task explicitly left the compact form to judgement.
- [low] The badge EXCLUDES backlogged tasks regardless of any "Show Backlog" toggle. **Why:** `ProjectTasks.counts`/`activeTasks` deliberately exclude backlog (#077), so the sidebar badge is a stable outstanding-active-work signal independent of the backlog toggle; including backlog would make a global sidebar count fluctuate with a per-project/content-column setting.
- [high] Reuse the `smartViewRow` layout and the `.caption.monospacedDigit().foregroundStyle(.secondary)` styling verbatim rather than introducing a new badge view or a filled capsule. **Why:** that is the established compact-count convention across the app (smart views, active-runs indicator) and the research found no filled-pill count badge anywhere; consistency and reuse over a new visual primitive.
- [high] The badge is suppressed when the count is zero (matching `smartViewRow`). **Why:** every existing trailing count in the sidebar is suppressed at zero, and absence doubles as a subtle "nothing outstanding" signal.
- [high] A new pure `BrowserViewModel.activeCount(_:)` helper is added as the test seam rather than inlining `project.activeTasks.count` in the view. **Why:** every sidebar helper in this file (`sidebarGlyph`, `pinStarredFirst`, `visibleSmartViews`, `statusCounts`) has a pure static helper plus a unit test; following that convention keeps the view thin and testable.

### Discovered during execution
- [low] Built the `activeTasks:` test fixture with the existing `makeTask(id:status:)` helper (ids 001/002/003, statuses in-progress/pending/review), since only the array COUNT matters for `activeCount`. **Why:** matches how sibling tests in the file construct `Task` values and keeps the assertion focused on the count, not task content.
- [low] Added the `let count = BrowserViewModel.activeCount(project)` binding at the top of `projectRow`, mirroring `smartViewRow`'s `let count = ...` so the `if count > 0` guard and `Text("\(count)")` read identically. **Why:** stays faithful to the `smartViewRow` template the step asked to mirror exactly.
- [high] Placed the `.tag(SidebarSelection.project(...))` on the outer `HStack` of `projectRow` (previously on the `Label`). **Why:** the row is now an `HStack`, not a bare `Label`; tagging the row's root view preserves the same selection wiring, matching how the extracted view is the tagged unit.

## Changes
- `Sources/Plans/BrowserWindow.swift`:
  - Added `BrowserViewModel.activeCount(_ project: ProjectTasks) -> Int` (returns `project.activeTasks.count`) next to `statusCounts(_:)` — the single source of truth for the sidebar project-row badge; excludes completed/backlog by construction.
  - Added `@ViewBuilder private func projectRow(_ project: ProjectTasks) -> some View` mirroring `smartViewRow`: `HStack` of `Label(name, systemImage: sidebarGlyph(starred:)).lineLimit(1)` + `Spacer(minLength: 4)` + `if count > 0 { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }`, with `.tag(SidebarSelection.project(...))` on the row.
  - Replaced the inline `Label` in the Projects `ForEach` with `projectRow(project)`; `.onMove` unchanged. No `GeometryReader`/measured-width/`idealWidth` sentinel introduced.
- `Tests/PlansTests/BrowserWindowTests.swift`: added `testActiveCountReflectsActiveTaskCount` in a new `// MARK: - activeCount` section — asserts `3` for a 3-active-task project and `0` for an empty one.
- Targeted tests: `swift test --filter PlansTests.BrowserWindowTests` → 137 tests, 0 failures (includes the new test). Suite compiles, confirming the view builds.

## Notes
- The sidebar's "Favourites" is merged into one combined "Projects" section (starred pinned first, #097); there is no separate Favourites section — the badge applies to every row in that combined section.
- Not a design-system / Figma task; no `**Build:**` route (project has no `design-system/` directory).
