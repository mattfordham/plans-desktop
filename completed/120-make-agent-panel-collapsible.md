# Make Agent Panel Collapsible

**ID:** 120
**Created:** 2026-11-12T16:51
**Type:** feature
**Status:** completed
**Completed:** 2026-11-12T17:11
**Branch:** feature/120-make-agent-panel-collapsible

## What
Make agent panel collapsible. Should be collapsed by default. Should open automatically when actions are executed (refine, execute, etc)

![pasted image](file://~/Library/Application%20Support/Plans/attachments/0AF85174-09A0-4B81-AD22-14CE97EFF4C7.png)

## Why
Adds value by letting the plan body own the full detail column by default: the agent dock (#117) is always-present and takes a large persisted slice of the column, crowding out the plan when no agent work is happening. Making it collapse to a header-only strip — collapsed by default, auto-expanding the moment an action (refine / execute / discuss / review / capture) starts — keeps the agent one click (or zero, on action) away while giving reading the plan priority.

## How Summary
Add a persisted `agentDockCollapsed` boolean (global `@AppStorage`, collapsed by default, a sibling of the existing `agentDockHeight`) owned by `ResizableAgentDock`. When collapsed, the container suppresses the drag handle and lets the dock take its intrinsic header-only height instead of applying `maxHeight: agentDockHeight`; the `AgentDock` header gains a leading disclosure chevron (reusing the existing per-run `chevron.right` + `.snappy(0.2)` idiom) that toggles the bound state, and renders only the header (status pill stays visible) while collapsed. A single `.onChange(of: agentState)` observer in `AgentDock` flips `collapsed = false` whenever the agent leaves `.idle`, so every action path (which all funnel through `PlanAgent` state → `.working`/`.needsInput`) auto-expands the dock without touching any trigger site. The expand decision is factored into a pure, unit-tested helper.

**Files of note:**
- `Sources/Plans/AgentDock.swift` — the dock + `ResizableAgentDock`; add collapsed AppStorage, header chevron, collapsed presentation, auto-expand observer, pure helper
- `Sources/Plans/PlanDetailView.swift` — embeds `ResizableAgentDock { AgentDock(row:) }` in the plan column and the capture placeholder; referenced for parity, likely unchanged
- `Tests/PlansTests/PlanDetailViewTests.swift` — holds the pure-function tests for `resizedHeight` / `dockFooterMode`; extend with the new collapse helper's test

## How
- [x] Step 1: Add a pure, testable static helper to `AgentDock` — `static func shouldAutoExpand(for state: PlanAgent.AgentState) -> Bool` returning `state != .idle` (true for `.working`/`.needsInput`). Write a failing XCTest for it in `Tests/PlansTests/PlanDetailViewTests.swift` first (mirror the existing `dockFooterMode` test block), then implement to green.
- [x] Step 2: Add `@AppStorage("agentDockCollapsed") private var collapsed: Bool = true` to `ResizableAgentDock`. When collapsed, render only the dock body without the drag `handle` and drop the `maxHeight: CGFloat(height)` frame so it takes its intrinsic header height (do NOT measure content size — preserve the #096 invariant); when expanded, keep today's `handle` + `maxHeight` layout exactly.
- [x] Step 3: Pass the collapsed state into `AgentDock` as a `@Binding Bool` so its header can toggle it. In `AgentDock`'s header, add a leading disclosure chevron `Button` (reuse the per-run `chevron.right` rotation + `withAnimation(.snappy(duration: 0.2))` idiom from `runSegment`) that flips the binding. Keep the status pill visible in both states; render `Divider() + transcript + footer` only when expanded.
- [x] Step 4: Add a single `.onChange(of: agentState)` observer in `AgentDock` that, when `AgentDock.shouldAutoExpand(for:)` is true, sets `collapsed = false` inside `withAnimation(.snappy(duration: 0.2))`. This covers refine/execute/elaborate/review/complete/capture/discuss uniformly (all flip agent state) including the capture placeholder dock — without touching any trigger site.
- [x] 👁 Step 5: Build (`swift build`) and run the app (`./build.sh`); verify the dock is collapsed by default (header-only strip, status pill visible, plan body gets the space), the chevron toggles it smoothly, the drag handle is absent while collapsed, and starting any action (execute/refine/discuss/review/capture) auto-expands it.

## Verification
- `swift build` succeeds and `swift test` passes the new `shouldAutoExpand` test plus the existing `AgentDock` pure-function tests (`resizedHeight`, `dockFooterMode`).
- In the running app, the agent dock in the plan-detail column is collapsed to a header-only strip by default, with the status pill still visible.
- Clicking the header chevron expands/collapses the dock with a snappy animation; while collapsed the resize handle is gone, and expanding restores the previously stored `agentDockHeight`.
- Triggering any agent action (execute, refine/elaborate, discuss, review, complete, capture) automatically expands the dock; the capture "Capturing…" placeholder is expanded over its live log, not collapsed.
- No layout-loop hang on resize or collapse/expand (#096 invariant preserved — no self-measurement).

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/AgentDock.swift` — add `shouldAutoExpand` pure helper, `agentDockCollapsed` AppStorage on `ResizableAgentDock`, collapsed layout (no handle / intrinsic height), header disclosure chevron toggling a bound bool, and the `.onChange(of: agentState)` auto-expand observer
- [ ] `Tests/PlansTests/PlanDetailViewTests.swift` — add a test for `AgentDock.shouldAutoExpand(for:)`

### Related Files (may need updates)
- `Sources/Plans/PlanDetailView.swift` — embeds `ResizableAgentDock { AgentDock(...) }` in the plan column and the capture placeholder; included only if the collapsed binding must be plumbed above the dock (preferred design keeps the AppStorage inside `ResizableAgentDock`, so likely no change)

### UI Affected
- Agent dock in the browser window's plan-detail column — new collapsed/expanded presentation with a header disclosure chevron; collapsed by default; auto-expands on any agent action

## Assumptions

### Initial (from elaboration)
- [low] Collapsed/expanded state is a single GLOBAL preference via `@AppStorage("agentDockCollapsed")` (not per-plan). **Why:** "collapsed by default" reads as a global preference and matches the existing `agentDockHeight` convention; a per-plan `@State` would reset on every plan switch because the detail column is `.id(selectedRowID)`-keyed, which is likely not the intent.
- [low] After an action finishes and the agent returns to `.idle`, the dock STAYS expanded until the user manually collapses it (no auto-collapse). **Why:** the task only specifies auto-open on action; auto-collapsing would be surprising and hide a transcript the user may still want to read.
- [low] The status pill stays visible while collapsed (header-only strip, not a fully hidden dock). **Why:** keeps "Needs your answer" / working state glanceable, and mirrors the always-present header intent of the #117 dock.
- [low] The collapsed state is passed into `AgentDock` as a `@Binding Bool` while the `@AppStorage` lives on `ResizableAgentDock`. **Why:** the container owns both the handle and the height frame (the things collapse must suppress), so keeping the source of truth there and binding it down keeps the two in sync without duplicating the AppStorage key.
- [high] Auto-expand is hooked on `agentState` changing away from `.idle` rather than on each of the ~7 action trigger sites. **Why:** research confirmed every action funnels through `PlanAgent.beginRunSegment`/`beginDiscussTurn`, which flip `state` to `.working`/`.needsInput`, so one observer covers them all uniformly and avoids touching modals/runner call sites.

### Discovered during execution
- [high] Threaded the collapsed binding through `ResizableAgentDock`'s closure (`@ViewBuilder let dock: (Binding<Bool>) -> Dock`) rather than adding a parameter to `AgentDock` call sites directly. The container owns the `@AppStorage("agentDockCollapsed")` and passes `$collapsed` into the closure; both `PlanDetailView` call sites became `ResizableAgentDock { collapsed in AgentDock(..., collapsed: collapsed) }`. **Why:** keeps the source of truth on the container (which also owns the handle/height frame collapse must suppress) and avoids a second AppStorage read in `AgentDock`; the closure signature change is confined to the two existing call sites.
- [high] Collapsed layout drops BOTH the drag `handle` and the `.frame(minHeight:maxHeight:)` so the dock takes its intrinsic header-only height — no GeometryReader / measurement (preserves #096). Expanded branch keeps today's handle + frame exactly. **Why:** the segment's explicit #096 invariant.
- [low] Used the zero-argument `.onChange(of: agentState)` form (no old/new values) for the auto-expand observer, reading `agentState` directly in the closure. **Why:** the observer only needs the current state to call `shouldAutoExpand`; the newer zero-arg form is the simplest and matches the existing `.onChange(of: segments.count)` idiom already in `AgentDock`.
- [low] Added `.contentShape(Rectangle())` to the header chevron's label and `.buttonStyle(.plain)` to keep the tap target and styling consistent with the per-run disclosure chevron in `runSegment`. **Why:** mirrors the established idiom; keeps the chevron a bare glyph rather than a bordered button.

## Changes

Implemented a collapsible agent dock (collapsed by default, auto-expands on any agent action).

- `Sources/Plans/AgentDock.swift`:
  - Added pure helper `AgentDock.shouldAutoExpand(for: PlanAgent.AgentState) -> Bool` (`state != .idle`).
  - Added `@Binding var collapsed: Bool` to `AgentDock`; added a leading header disclosure chevron `Button` (rotating `chevron.right`, `withAnimation(.snappy(duration: 0.2))`, `.buttonStyle(.plain)`) before the status pill that toggles the binding. The status pill stays visible in both states; `Divider() + transcript + footer` now render only when `!collapsed`, so the collapsed dock is a header-only strip.
  - Added `.onChange(of: agentState)` in `AgentDock.body` that sets `collapsed = false` (animated) when `shouldAutoExpand(for:)` is true — one observer auto-expands on execute/refine/elaborate/review/complete/capture/discuss (all flip agent state), including the capture placeholder dock.
  - `ResizableAgentDock`: added `@AppStorage("agentDockCollapsed") private var collapsed: Bool = true` (global, collapsed by default, orthogonal to `agentDockHeight`). Its `dock` closure is now `(Binding<Bool>) -> Dock`; when collapsed the body renders `dock($collapsed)` with no drag handle and no `maxHeight` frame (intrinsic header height — no measurement, #096 preserved); when expanded it keeps today's `handle` + `.frame(minHeight:maxHeight:)` exactly.
- `Sources/Plans/PlanDetailView.swift`: updated both `ResizableAgentDock { … }` call sites (plan column + capture placeholder) to `ResizableAgentDock { collapsed in AgentDock(…, collapsed: collapsed) }`.
- `Tests/PlansTests/PlanDetailViewTests.swift`: added `testShouldAutoExpand` (TDD red→green) covering `.idle` → false, `.working(…)` → true, `.needsInput` → true.

**Build:** `swift build` — Build complete. **Tests:** `swift test --filter testShouldAutoExpand` — 3 tests, 0 failures.

Steps 1–4 complete. Step 5 (👁 run-the-app visual verification) deferred to review (yolo/worktree mode).

## Notes
Preserve the #096 layout-loop invariant: never read a measured content/window size during layout. Collapse must be implemented by suppressing the drag handle and dropping the `maxHeight` frame (letting the collapsed dock take intrinsic header height), NOT by computing a collapsed height from a measurement. Keep collapse orthogonal to `agentDockHeight` — the drag height must be preserved so expanding returns to it.
