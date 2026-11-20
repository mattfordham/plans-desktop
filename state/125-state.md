# Execution State: Task #125

**Task:** Fix agent panel clipping and collapse it by default
**Branch:** fix/125-fix-agent-panel-clipping-and-collapse
**Started:** 2026-11-20

## Segments
- Segment 1 (step 1): complete (observation deferred)
- Segment 2 (steps 2-4): complete
- Segment 3 (steps 5-7): complete (step 7 observation deferred)

## Completed Steps
- Step 1: 👁 reproduce — deferred to review (worktree mode)
- Step 2: TDD — AgentDockTests.swift (10 tests): inline run-log mode + per-project persistence helpers
- Step 3: Clipping fix — removed 360pt cap; added `inline`/`logListIsScrolling` non-scrolling path to RunLogContents; AgentDock passes inline:true
- Step 4: TDD + helpers — `nonisolated static` dockOpenedKey/dockWasOpened/setDockOpened/initialCollapsed on AgentDock (helpers only, not yet wired)
- Step 5: Wired per-project collapse — removed global `@AppStorage("agentDockCollapsed")`; `ResizableAgentDock` takes `projectPath`, seeds `@State collapsed` from `initialCollapsed`, persists via single `.onChange(of: collapsed)` → `setDockOpened`; both host sites pass projectPath; `agentDockHeight` stays global
- Step 6: Targeted tests — `swift build` clean; AgentDockTests 10/0, PlanDetailViewTests 105/0
- Step 7: 👁 launch-and-verify — deferred to review (worktree mode)

## Key Decisions
- Inline run-log path drops inner ScrollViewReader/auto-scroll; outer dock transcript owns scroll via transcriptScrollKey (avoids nested scroll fighting).
- Testable seam is pure `logListIsScrolling(inline:)` + `inline` default (SwiftUI bodies not unit-tested here).
- `setDockOpened(false)` removes the key (no sticky false) so a collapsed project reverts to collapsed-by-default.
- Segment 2 appended assumption bullets to task file ## Assumptions (see task file for details).

## Deviations
- None.

## Observations
- Step 1: ✓ User confirmed (branch: fix/125-fix-agent-panel-clipping-and-collapse @ 0fcf26a) (replayed at dcfc2ac) — manual reproduce of the clipping before fix; no later step is functionally gated on it (the Diagnosis is already high-confidence)
- Step 7: ✓ User confirmed (branch: fix/125-fix-agent-panel-clipping-and-collapse @ 0fcf26a) (replayed at dcfc2ac) — launch app and verify collapsed-by-default per project, expand persistence across selection/relaunch, and single-container long-transcript scroll with no clipping/blank band

## Test Status
- `swift build`: clean. `swift test --filter AgentDockTests`: 10/0. `swift test --filter PlanDetailViewTests`: 105/0.
