# Show in-progress captured plans in the project task list

**ID:** 103
**Created:** 2026-11-07T00:00
**Type:** bug
**Status:** completed
**Completed:** 2026-11-07T00:00
**Branch:** fix/103-new-plan-being-captured-shows-in-project

## What
When a new plan is in the process of being captured, I would expect it to show up in the list of plans for the project as it does in the project card under all projects.

## Why
Improves consistency and reliability of the browser: a plan being captured already surfaces as a live spinner row on the project card under "All projects", but drilling into that same project's task list shows nothing — the in-flight capture silently disappears. Surfacing it in both places gives the user the same immediate "it's being created" feedback regardless of which surface they are looking at.

## How Summary
The project **card** (`ProjectCard`) renders in-flight captures by reading `TaskRunner.runningCaptures(projectPath:)` in its `captureRows`/`captureRow` views; the single-project **task list** (`TaskListView`) renders only the parsed on-disk rows handed to it and never consults `TaskRunner`, so a capture that has no `.plans/` file yet has no row source there. The fix extracts the card's spinner-row renderer into a shared view and renders it in `TaskListView` for the single-project case (`project != nil`) as a sibling section above the parsed task sections — reusing the exact same live-capture source and reconcile-on-close hand-off the card already has.

**Files of note:**
- `Sources/Plans/ProjectCard.swift` — source of the existing `captureRows`/`captureRow(_:)` renderer to extract/share.
- `Sources/Plans/TaskListView.swift` — the single-project list that must gain the capture-row section.
- `Sources/Plans/TaskRunner.swift` — `runningCaptures(projectPath:)`, the live in-flight-capture registry both surfaces read.
- `Sources/Plans/CaptureProgressRows.swift` — new shared view (extracted from the card) rendering the capture spinner/warning rows.
- `Tests/PlansTests/TaskRunnerTests.swift` — existing `runningCaptures` coverage; extend if a new pure seam is added.

## Diagnosis

**Most likely:** `TaskListView` never incorporates `TaskRunner.runningCaptures` for its project, so an in-flight capture — which exists only in the live run registry with a synthetic `capture:<path>:<uuid>` id and no on-disk `.plans/` file — has no row source in the single-project list (`Sources/Plans/TaskListView.swift:216-247`, `:330-333`; contrast `Sources/Plans/ProjectCard.swift:531-544`).
**Evidence:** `ProjectCard.captureRows` reads `runner.runningCaptures(projectPath:)` (`ProjectCard.swift:532-533`) and renders a spinner row per in-flight capture, independent of any parsed file; `TaskListView` has no `@Environment(TaskRunner.self)` and renders only its handed-in `rows`, which `BrowserViewModel.displayedRows` builds purely from `activeTasks`/backlog (`BrowserWindow.swift:371-383`). A capture has no parsed `Task`, so it never enters those rows.
**Confidence:** high

**Alternative:** A partially-written `pending/` file excluded by the list's active-task filter (`TaskParser.swift:618-628`) — **Confidence:** low. ~~Ruled out~~ — disproved: the active filter excludes only `.completed` and `nil`-status tasks, and both views draw from the same `activeTasks`, so an on-disk file would appear in BOTH or NEITHER, never only on the card.

**To confirm:** During the window where the card shows its spinner row, verify `runner.runningCaptures(projectPath:)` is non-empty for the project while that project has no corresponding parsed `activeTasks` entry (no `.plans/pending/` file yet) — confirming the discrepancy is the missing capture-row source in `TaskListView`, not parser filtering.

## How
- [x] Step 1: Add a failing/scaffolding test confirming the capture source is what the card uses and the list lacks — assert `TaskRunner.runningCaptures(projectPath:)` returns an in-flight capture run for a project with no parsed task (agent-verifiable via `TaskRunnerTests`; this pins the Diagnosis before the fix). Reuse the existing `runningCaptures` test setup in `Tests/PlansTests/TaskRunnerTests.swift`.
- [x] Step 2: Extract the card's capture-row rendering (`captureRows` + `captureRow(_:)` from `ProjectCard.swift:531-590`, including the spinner/warning-glyph state, description text, progress popover, and reconcile-on-close that calls `runner.dismiss(...)` + `store.reload()`) into a new shared view `CaptureProgressRows` in `Sources/Plans/CaptureProgressRows.swift`, parameterized by `projectPath` — mirroring how `PlanRowActions`/`ProjectFooter`/`ProjectStatusBadges` were extracted for reuse across both surfaces.
- [x] Step 3: Update `ProjectCard` to render the new shared `CaptureProgressRows` in place of its inline `captureRows`/`captureRow(_:)`, preserving the current card gutter inset and placement (above `body(for:)`), so the card's behavior and appearance are unchanged.
- [x] Step 4: Render `CaptureProgressRows(projectPath:)` in `TaskListView` for the single-project case only (`project != nil`), as a sibling section placed above the parsed task sections (not inside the sort/group/section pipeline, so the detail-selection invariant and sorting are untouched). Leave the cross-project smart-view list (`project == nil`) unchanged.
- [x] 👁 Step 5: Build and run the app; capture a new plan for a project, and while it is still being captured, confirm the spinner row now appears in BOTH the project card (All projects) AND that project's single-project task list, and that it clears from both once the plan file lands. _(⏳ Deferred to review — yolo/worktree mode. Implementation complete and `swift build` clean; manual visual confirmation to be done at review.)_

## Verification
- With a capture in flight, the single-project task list shows a spinner row labeled with the capture description, matching the project card under "All projects".
- When the captured plan file lands and is parsed, the spinner row is replaced by the real plan row in both surfaces (reconcile-on-close/`onDidReload` hand-off works unchanged).
- An errored capture surfaces its warning glyph in the list too (parity with the card).
- The card's existing capture-row behavior and appearance are unchanged after the extraction.
- Cross-project smart-view lists are unchanged (no duplicated capture rows there).
- `swift test` targeted at the touched tests passes (`TaskRunnerTests`).

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/ProjectCard.swift` — replace inline capture-row views with the shared `CaptureProgressRows`.
- [x] `Sources/Plans/TaskListView.swift` — render `CaptureProgressRows` for the single-project case.
- [x] `Sources/Plans/CaptureProgressRows.swift` — new shared capture-row view (extracted from the card).

### Related Files (may need updates)
- `Sources/Plans/TaskRunner.swift` — `runningCaptures(projectPath:)` consumed unchanged; only touched if a new pure seam is needed.
- `Tests/PlansTests/TaskRunnerTests.swift` — extend capture-source coverage if a new seam is added.

### Endpoints/UI Affected
- Single-project task list (Surface B, sidebar → a project) — gains in-flight capture spinner rows.
- Project card under "All projects" — visually unchanged after the renderer extraction.

## Assumptions

### Initial (from elaboration)
- [low] Scope the fix to the SINGLE-project task list only (`project != nil`), not the cross-project smart views. **Why:** the report says "the list of plans for the project" and a capture has a clear single project owner; the window toolbar's `ActiveRunsIndicator` already covers captures globally, so duplicating them in smart views would be redundant (research Open Questions + Approach Warnings).
- [low] Include ERRORED captures in the list too (warning glyph), for full parity with the card. **Why:** the card pins errored captures until dismissed; showing them only on one surface would re-create a subtler version of the same inconsistency this task fixes.
- [low] Extract the card's existing `captureRows`/`captureRow(_:)` into a shared `CaptureProgressRows` view rather than duplicating the markup. **Why:** matches the established reuse pattern (`PlanRowActions`, `ProjectFooter`, `ProjectStatusBadges`, `TaskTypeFilterMenu`) and keeps the two surfaces rendering captures identically (research Reusable Existing Code).
- [high] Do NOT synthesize a fake parsed `Task`/`TaskRow` for the capture and feed it through `displayedRows`. **Why:** a capture has no task id/title/status and would pollute the shared cross-project row/detail-selection pipeline; the capture belongs in a dedicated spinner-row section, exactly as the card does it (research Approach Warnings; single plausible correct design).
- [high] Do not touch `ProjectStackView`; this fix does not require it. **Why:** CLAUDE.md forbids self-measurement there (the #096 layout-loop hazard) and the card-stack path already renders captures via `ProjectCard`.

### Discovered during execution
- [high] Placed `CaptureProgressRows` in `TaskListView` as a sibling BETWEEN the `controlBar` `Divider()` and the `if visibleRows.isEmpty` branch (not inside the `else`-branch `ScrollView`). **Why:** a capture with no parsed `.plans/` file yet means `visibleRows` is empty, which routes to the centered "No tasks" empty-state branch; placing the capture rows only inside the populated `ScrollView` would hide them exactly when a project's sole in-flight item is a capture. As a sibling above both branches they always render while staying out of the sort/group/section pipeline.
- [low] Removed the now-unused `@Environment(TaskRunner.self) private var runner` from `ProjectCard` (it was only read by the extracted capture rows; `PlanRowActions` reads its own `TaskRunner` from the environment). **Why:** after the extraction the card has no direct `runner.` references; leaving the stored environment property would be dead state. `CaptureProgressRows` and `PlanRowActions` still read `TaskRunner` from the environment injected upstream, so the environment contract is unchanged. Kept `store` (still used by `showsBacklogSection`).
- [high] Applied the card gutter inset (`.padding(.horizontal, ProjectCard.rowColumns.cardHorizontalPadding)`) at the CALL SITE in both surfaces rather than inside `CaptureProgressRows`. **Why:** matches the file's "caller applies its own horizontal inset" convention used by `ProjectFooter`; keeps the shared view layout-neutral so each surface controls its own gutter.

## Changes
Shared the project card's in-flight capture spinner rows so they also appear in the single-project task list (#103).

- `Sources/Plans/CaptureProgressRows.swift` (new): extracted shared view `CaptureProgressRows(projectPath:)` rendering one spinner-or-warning row per `runner.runningCaptures(projectPath:)` entry, with the tappable `RunProgressSheet` progress popover and the reconcile-on-close `onDisappear { runner.dismiss(...) ; store.reload() }`. Reads `TaskRunner`/`PlansStore` from the environment and owns its own `progressPopoverTaskID` selection state. Renders nothing when no captures are in flight.
- `Sources/Plans/ProjectCard.swift`: replaced the inline `captureRows`/`captureRow(_:)` views (and the now-unused `progressPopoverTaskID` `@State`, `progressPopover(for:)` helper, and `runner` environment) with `CaptureProgressRows(projectPath: project.projectPath)` rendered from `scrollableContent` above `body(for:)`, keeping the card gutter inset. Appearance/placement unchanged.
- `Sources/Plans/TaskListView.swift`: render `CaptureProgressRows(projectPath:)` for the single-project case only (`if let project`), as a sibling above the parsed task sections (between the control-bar `Divider()` and the rows/empty-state) so it stays out of the sort/group/section pipeline and the detail-selection invariant. Smart-view lists (`project == nil`) are unchanged.
- `Tests/PlansTests/TaskRunnerTests.swift`: added `testRunningCapturesReturnsInFlightCaptureForProjectWithNoParsedTask`, pinning that `runningCaptures(projectPath:)` returns an in-flight capture for a project with no parsed task — the capture source the card used and the list lacked.

## Notes
Research (diagnostic Explore agent) confirmed the card-vs-list divergence is architectural: two row-source pipelines, only one of which reads `TaskRunner.runningCaptures`. The reconcile-on-close/`onDidReload` hand-off already dismisses the spinner once the parsed row appears, so a list that renders captures gets the spinner-out/row-in transition for free.
