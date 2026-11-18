# Show new plan button and stats in single-project view

**ID:** 098
**Created:** 2026-11-07T14:38
**Type:** feature
**Status:** completed
**Completed:** 2026-11-07T15:40
**Branch:** feature/098-view-project-new-plan-button-and-stats

## What
When viewing a project by clicking a project in the sidebar, the new plan button should be present at the top of the list, kind of like it is in the all projects view. Additionally, the other stats that show in the project, all projects list should show up in the project view.

## Why
Adds value by giving the single-project view (the flat task list shown when a project is selected in the sidebar) the same at-a-glance capture affordance and per-status count summary the "All projects" cards already provide — so a user who has drilled into one project doesn't have to go back to the card stack (or the recency-based toolbar button) to add a plan to *that* project or to see its status breakdown.

## How Summary
Thread the project context into `TaskListView` so its existing `controlBar` can render a leading "+" new-plan glyph (reusing the card header's `CaptureGlyph`, wired to the same `newPlanRequest` sheet closure the cards use) and a trailing per-status count cluster (the same `glanceOrder` badges the card header shows). Both are gated on a non-nil project so the cross-project smart-view list is byte-for-byte unchanged. The per-status counts are computed from the project's `counts` (backlog-excluded, matching the card) via a shared `BrowserViewModel` helper extracted from `ProjectCard.statusCounts`, so card and list share one source of truth.

**Files of note:**
- `Sources/Plans/TaskListView.swift` — add optional `project`/`onNewPlan` props and render the "+" + count badges in `controlBar`
- `Sources/Plans/BrowserWindow.swift` — resolve the selected `ProjectTasks` and pass it + the `newPlanRequest` closure into `TaskListView` for the `.project` case only; add the shared `statusCounts` helper to `BrowserViewModel`
- `Sources/Plans/ProjectCard.swift` — un-private `CaptureGlyph` for cross-view reuse; refactor `statusCounts` to call the new shared helper
- `Sources/Plans/TaskStatus+Glance.swift` — reference only: `glanceOrder` / `symbolName` / `glanceColor` badge vocabulary
- `Tests/PlansTests/` — unit-test the shared `statusCounts` helper

## How
- [x] Step 1: Add a shared pure helper `BrowserViewModel.statusCounts(_ project: ProjectTasks) -> [(status: TaskStatus, count: Int)]` returning `TaskStatus.glanceOrder.map { ($0, project.counts[$0] ?? 0) }`, and refactor `ProjectCard.statusCounts` to call it (single source of truth). Add a focused XCTest in `Tests/PlansTests/` first (TDD): assert every `glanceOrder` status appears, absent/zero statuses surface as `0`, and the order matches `glanceOrder`.
- [x] Step 2: Make `CaptureGlyph` module-visible (drop `private`) in `ProjectCard.swift` so `TaskListView` can reuse the exact header "+" affordance, matching the un-private precedent of `OpenDetailOnTap` / `PlanRowActions`.
- [x] Step 3: Add two optional props to `TaskListView` — `var project: ProjectTasks? = nil` and `var onNewPlan: ((String) -> Void)? = nil` — defaulting to nil so existing call sites (the `.smart` case) compile unchanged and render identically.
- [x] Step 4: In `TaskListView.controlBar`, when both `project` and `onNewPlan` are non-nil, render a leading `CaptureGlyph { onNewPlan(project.projectPath) }` before the Sort/Group menus, and render the trailing per-status count badges (via `BrowserViewModel.statusCounts(project)`) after the existing `Spacer`, copying the card header's badge view (symbol in `glanceColor`, dimmed at zero, count text) for visual consistency. Keep the smart-view list unchanged when the props are nil.
- [x] Step 5: In `BrowserWindow.contentColumn`'s `.project` case, resolve the `ProjectTasks` from `store.projects` by the selected path and pass it as `project:` plus `onNewPlan: { newPlanRequest = NewPlanRequest(projectPath: $0) }` (identical wiring to the card stack). Leave the `.smart` case passing neither.
- [x] 👁 Step 6: Build and run the app (`swift build`, then `./build.sh` or launch), select a single project in the sidebar, and confirm the "+" new-plan button appears at the top of the list (opening the New Plan modal pre-selected to that project) and the per-status count badges appear — while the "All projects" cards and the cross-project smart-view lists are visually unchanged.

## Verification
- A single project selected in the sidebar shows a "+" new-plan button at the top of its task list; tapping it opens the New Plan modal pre-selected to that project.
- The same per-status count badges shown on the "All projects" card header appear in the single-project list (same statuses, same order, zeros dimmed).
- Cross-project smart-view lists (In Progress, Review, etc.) are unchanged — no "+" button, no per-project counts.
- `swift test` passes, including the new shared-`statusCounts` helper test.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/BrowserViewModel` (in `BrowserWindow.swift`) — add shared `statusCounts(_:)` helper
- [x] `Sources/Plans/ProjectCard.swift` — refactor `statusCounts` to the shared helper; un-private `CaptureGlyph`
- [x] `Sources/Plans/TaskListView.swift` — add `project`/`onNewPlan` props; render button + badges in `controlBar`
- [x] `Sources/Plans/BrowserWindow.swift` — thread project + onNewPlan into `TaskListView` for `.project`
- [x] `Tests/PlansTests/` — new test for the shared `statusCounts` helper

### Endpoints/UI Affected
- Single-project task list control bar — gains a leading "+" new-plan glyph and a trailing per-status count cluster
- Cross-project smart-view list — unchanged (props nil)
- "All projects" card header — unchanged behavior (now sourced from the shared helper)

## Assumptions

### Initial (from elaboration)
- [low] Use the card header's "+" `CaptureGlyph` (not a labeled "New Plan" button) for the single-project view. **Why:** the task says "kind of like it is in the all projects view," and the cards use the compact "+" glyph; reusing it keeps the two surfaces visually consistent.
- [low] "The other stats" means the per-status count badges from the card header (the full `glanceOrder` cluster, zeros dimmed) — and only those, NOT the per-card type-filter menu. **Why:** the task calls them "stats"; the type filter is a control, not a readout, and leaving it out keeps the single-project control bar focused on sort/group + the two requested additions.
- [high] Compute the single-project stats from `project.counts` (backlog-excluded), not from the displayed rows. **Why:** matches the card header exactly (`ProjectCard.statusCounts`), which is unfiltered and backlog-excluded; sourcing from rows would diverge from the card.
- [low] Extract a shared `BrowserViewModel.statusCounts(_:)` helper rather than copying the expression a third time. **Why:** research flagged the codebase's strong single-source-of-truth convention; card and list (and potentially the menu bar) should share one computation.
- [low] Gate the new affordances on non-nil `project`/`onNewPlan` props so the `.smart` (cross-project) list is left byte-for-byte unchanged. **Why:** a smart view spans projects, so there is no single capture target or per-project count to show there.

### Discovered during execution
- [high] Gated the trailing count badges on `if let project` alone (not `if let project, let onNewPlan`), while the leading "+" is gated on both props. **Why:** the "+" genuinely needs `onNewPlan` to act, but the badges only read `project.counts`; in practice both props are supplied together for `.project` and both nil for `.smart`, so behavior matches the spec either way — gating the badges on `project` alone keeps the dependency honest.
- [low] Placed the new `BrowserViewModel.statusCounts(_:)` helper immediately above `backlogRows` / below the `activeRows(_:)` family in `BrowserWindow.swift`. **Why:** keeps all the per-project-card data helpers grouped together, next to the other `ProjectTasks -> [...]` pure helpers.
- [low] Put the helper's test in a NEW focused file `Tests/PlansTests/BrowserViewModelStatusCountsTests.swift` rather than appending to `BrowserWindowTests.swift`. **Why:** the segment said to run only the new test file via `--filter <ClassName>`; a dedicated class keeps that filter targeted and the existing suite untouched. Also added a defaulted `counts:` parameter to `BrowserWindowTests.makeProject` (previously hardcoded `[:]`) so future count-based tests there are possible — a backward-compatible signature change.
- [low] Copied the card header's badge view verbatim into `TaskListView.controlBar` (symbol in `glanceColor`, dimmed to `Color.white.opacity(0.1)` at zero, count `Text`, `HStack(spacing: 4)`) rather than extracting a shared badge View. **Why:** the segment explicitly asked to copy the card header's badge view for visual consistency; extracting a shared SwiftUI view was out of scope for this segment.

## Changes

### Segment 1 (steps 1-4)
- `Sources/Plans/BrowserWindow.swift` — added shared pure helper `BrowserViewModel.statusCounts(_ project: ProjectTasks) -> [(status: TaskStatus, count: Int)]` (`TaskStatus.glanceOrder.map { ($0, project.counts[$0] ?? 0) }`), placed alongside the other per-project data helpers.
- `Sources/Plans/ProjectCard.swift` — refactored `statusCounts` to delegate to the shared helper (single source of truth); dropped `private` from `CaptureGlyph` so it is module-visible for cross-view reuse (precedent: `OpenDetailOnTap` / `PlanRowActions`).
- `Sources/Plans/TaskListView.swift` — added optional props `var project: ProjectTasks? = nil` and `var onNewPlan: ((String) -> Void)? = nil` (default nil → existing `.smart` call site unchanged); in `controlBar`, render a leading `CaptureGlyph { onNewPlan(project.projectPath) }` (gated on both props) before the Sort/Group menus, and trailing per-status count badges via `BrowserViewModel.statusCounts(project)` (gated on `project`) after the `Spacer`, copying the card header's badge view (symbol in `glanceColor`, dimmed to `Color.white.opacity(0.1)` at zero, count text).
- `Tests/PlansTests/BrowserViewModelStatusCountsTests.swift` (new) — 3 cases for the helper: every `glanceOrder` status present, absent/zero surface as `0`, order matches `glanceOrder`. All pass.
- `Tests/PlansTests/BrowserWindowTests.swift` — backward-compatible: added a defaulted `counts: [TaskStatus: Int] = [:]` parameter to the `makeProject` fixture.
- Build clean (`swift build`); `swift test --filter BrowserViewModelStatusCountsTests` → 3 passed, 0 failed.

### Segment 2 (steps 5-6)
- `Sources/Plans/BrowserWindow.swift` — `contentColumn`'s `.project` case now binds `case .project(let path):`, resolves the `ProjectTasks` via `store.projects.first { $0.projectPath == path }` (nil-safe since props are optional), and passes `project:` + `onNewPlan: { newPlanRequest = NewPlanRequest(projectPath: $0) }` into `TaskListView` — mirroring the `.allProjects` card-stack wiring exactly. The `.smart` case still passes neither prop.
- Build clean (`swift build` → Build complete). Branch/SHA provenance unchanged across the build (no drift).
- Step 6 is an observation step: prerequisites in place and the build compiles, but the GUI render is DEFERRED TO REVIEW (worktree/yolo mode — see `/plan-review 098`).

### Review fixes
- Badges were squeezed in the sort/group bar: the single-project list now has its own header row ("New Plan" labelled button; Backlog toggle, type filter, fixed-size status badges) above sort/group, plus the card's git/sync/star footer.
- Extracted `ProjectFooter`, `TaskTypeFilterMenu`, `ProjectStatusBadges` (shared by card and list) and `BrowserViewModel.filterRows(_:matchingType:)` (tested); `CaptureGlyph` back to `private`.

## Notes
_Additional context_
