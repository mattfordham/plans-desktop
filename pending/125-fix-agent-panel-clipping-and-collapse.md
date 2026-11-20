# Fix agent panel clipping and collapse it by default

**ID:** 125
**Created:** 2026-11-20T10:33
**Type:** bug
**Status:** in-progress
**Branch:** fix/125-fix-agent-panel-clipping-and-collapse
**Worktree:** /Users/matt/Work/Open Source/plans-desktop/.worktrees/125-fix-agent-panel-clipping-and-collapse

## What
The agent panel is sometimes clipped like in the screenshot. Additionally, this panel should never be open by default. It should always be collapsed unless user previously opened it for the viewed project.

![pasted image](file:///Users/matt/Library/Application Support/Plans/attachments/4F92DDD5-867D-41C4-862F-D99166D30889.png)

## Why
Improves reliability of the agent dock: long run transcripts are currently cropped mid-line at both edges of a nested 360pt box with a dead blank band below, making run output unreadable (a case #121 explicitly deferred). Making the dock collapsed-by-default and per-project keeps the detail column unobtrusive — today one global `agentDockCollapsed` flag means expanding it anywhere (or any agent activity anywhere) leaves it open for every project thereafter.

## How Summary
Two changes in the agent dock. (1) Clipping: remove the nested, hard-capped 360pt inner `ScrollView` around `RunLogContents` and give the run log a non-scrolling inline render path when hosted inside the dock transcript, so the dock's outer transcript `ScrollView` is the single scroll container (no self-measurement — #096 invariant holds). (2) Collapse default: replace the single global `agentDockCollapsed` `@AppStorage` with a per-project persisted "user opened the dock" flag (UserDefaults key namespaced by project path, mirroring `ReviewModal`'s `defaultLocationKey(projectPath:)` idiom); the dock derives `collapsed` from that flag, defaulting to collapsed for any project the user never opened it in.

**Files of note:**
- `Sources/Plans/AgentDock.swift` — clipping site (`maxHeight: 360` wrapper at :343) and collapse-state owner (`ResizableAgentDock`'s `@AppStorage` at :634/:639, auto-expand at :147-151)
- `Sources/Plans/PlanDetailView.swift` — `RunLogContents` and its inner `ScrollView`/`logList` (:1802-1838); hosts `ResizableAgentDock` in the detail column
- `Sources/Plans/ReviewModal.swift` — per-project UserDefaults key pattern to mirror (:224-242)
- `Sources/Plans/BrowserWindow.swift` — detail column keyed `.id(selectedRowID)`; why per-plan `@State` cannot persist the flag
- `Tests/PlansTests/PlanDetailViewTests.swift` / `PlanAgentTests.swift` — existing homes for dock/run-log helper tests

## Diagnosis

**Most likely:** The run transcript is rendered as an independent inner `ScrollView` hard-capped at 360pt inside the dock's outer transcript `ScrollView` (`Sources/Plans/AgentDock.swift:343` → `RunLogContents.logList`, `Sources/Plans/PlanDetailView.swift:1802-1838`). Content taller than 360pt is clipped mid-line at the inner box's top and bottom edges, and when the dock is resized taller than header + 360 + footer, the capped box cannot grow — producing the blank band below the clipped text.
**Evidence:** `.frame(maxWidth: .infinity, maxHeight: 360)` at `AgentDock.swift:343`; nested `ScrollView` at `PlanDetailView.swift:1805` with `.clipShape` at :1838; transcript `maxHeight: .infinity` at `AgentDock.swift:129` with footer `.layoutPriority(1)` at :140 — matches the screenshot's two-edge mid-line crop plus dead space. #121's own Assumptions flagged this nested-scroll cap as the retained, deferred alternative cause.
**Confidence:** high

**Alternative:** Run-segment stacking or auto-scroll re-key regressions from #121 (`AgentDock.swift:271-295`) — **Confidence:** low — #121 already fixed those paths; the screenshot symptom (fixed-height box + gap) doesn't match them.

**To confirm:** Expand the dock on a plan with a long run log and drag the handle taller than ~500pt: if the log stays pinned at 360pt with a growing blank band below while still clipping mid-line top and bottom, the inner-cap hypothesis is confirmed.

## How
- [ ] 👁 Step 1: Reproduce — open a plan with a long run transcript, expand the agent dock, and drag the handle taller than ~500pt; confirm the log stays pinned at ~360pt with mid-line clipping at both edges and a blank band below (confirms the Diagnosis before any fix)
- [ ] Step 2: TDD — write failing tests for a `RunLogContents` inline (non-scrolling) hosting mode and for any new `AgentDock` layout helper (pure helpers in the existing `PlanDetailViewTests`/`PlanAgentTests` style)
- [ ] Step 3: Fix clipping — drop the `maxHeight: 360` wrapper at `Sources/Plans/AgentDock.swift:343` and render `RunLogContents` through a non-scrolling inline path (extend the existing `edgeToEdge`-style option at `PlanDetailView.swift:1730`) when hosted in the dock transcript, so the outer transcript `ScrollView` is the single scroll container; preserve auto-scroll-to-bottom behavior and the #096 no-self-measurement invariant
- [ ] Step 4: TDD — write failing tests for per-project dock-open persistence: `nonisolated static` key/getter/setter helpers keyed `"agentDockOpened:" + projectPath`, mirroring `ReviewModal.swift:224-242`
- [ ] Step 5: Replace the global `agentDockCollapsed` `@AppStorage` (`AgentDock.swift:639`) with per-project derived state: thread the project path into `ResizableAgentDock`/`AgentDock`, default to collapsed when no flag is set, record the flag on manual header expand (`AgentDock.swift:212-214`) and on auto-expand-on-activity (`AgentDock.swift:147-151`), and clear it on manual collapse; keep `agentDockHeight` global
- [ ] Step 6: Run `swift test` — full suite passes, including the new tests
- [ ] 👁 Step 7: Launch the app (`./build.sh`) and verify: dock starts collapsed on a project never opened in; expanding persists only for that project across selection changes and relaunch; a long transcript scrolls fully in one container with no mid-line clipping and no blank band at any dock height

## Verification
- The clipping no longer occurs: with a long run transcript and the dock resized to any height, log content scrolls fully within a single scroll container — no mid-line cropping at the top or bottom, no dead blank band between the log and the footer.
- The dock is collapsed by default: on a project where the user never opened it, the dock renders collapsed on every plan; manually expanding it persists the open state for that project only (other projects stay collapsed); manually collapsing returns that project to collapsed-by-default.
- New unit tests cover the inline run-log hosting mode and the per-project opened-flag helpers; `swift test` passes with no regressions.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/AgentDock.swift` — remove the 360pt inner cap; swap global `agentDockCollapsed` for per-project opened-flag derivation; record the flag on manual/auto expand
- [ ] `Sources/Plans/PlanDetailView.swift` — `RunLogContents` inline (non-scrolling) hosting mode; pass project path into `ResizableAgentDock` where needed
- [ ] `Tests/PlansTests/PlanDetailViewTests.swift` — tests for the inline run-log mode / layout helpers
- [ ] `Tests/PlansTests/PlanAgentTests.swift` — tests for per-project opened-flag helpers (or a dedicated `AgentDockTests.swift` if cleaner)

### Related Files (may need updates)
- `Sources/Plans/BrowserWindow.swift` — detail column `.id(selectedRowID)` keying; verify project-path threading survives selection changes
- `Sources/Plans/ReviewModal.swift` — reference only: the per-project UserDefaults key idiom being mirrored

### Endpoints/UI Affected
- Browser window detail column (Surface B) — agent dock default state, expand/collapse persistence, and run-transcript layout at all dock heights

## Assumptions

### Initial (from elaboration)
- [high] Collapse-state persistence is per-project (keyed by project path), not per-plan. **Why:** the task text says "for the viewed project", and `ReviewModal.swift:224-242` is the established per-project UserDefaults idiom; a per-plan `@State` would reset on every selection change because the detail column is `.id(selectedRowID)`-keyed.
- [high] The clipping fix is to remove the nested 360pt-capped inner `ScrollView` in favor of a single outer scroll container (inline run-log render path). **Why:** research confirmed the hard cap at `AgentDock.swift:343` with high confidence, and #121's Assumptions explicitly deferred exactly this change.
- [low] Auto-expand-on-agent-activity (#120 behavior at `AgentDock.swift:147-151`) is kept, and counts as "opening" the dock for that project (it records the per-project opened flag). **Why:** research flagged this as an unresolved open question; starting an agent action is an explicit user interaction with that project's plan, so suppressing the running transcript would hide feedback the user just requested.
- [low] Manually collapsing the dock clears the per-project opened flag, so that project returns to collapsed-by-default. **Why:** UX decision the description didn't specify; "always collapsed unless user previously opened it" is read as remembering the user's last explicit intent per project.
- [low] `agentDockHeight` (the drag-resize height) stays a single global preference; only the collapsed/opened state becomes per-project. **Why:** scope decision the description didn't specify — the complaint is about open-by-default, not height; keeping height global avoids churn in the #096-sensitive resize path.

### Discovered during execution
_To be filled during execution_

## Changes
_To be filled during execution_

## Notes
- Screenshot evidence: the dock's run transcript clipped mid-line at top and bottom of a fixed-height box with a blank band below, while expanded by default.
- Prior work: #120 made the dock collapsible (global `@AppStorage`, deliberate at the time); #121 fixed bottom-half clipping from segment stacking/auto-scroll but explicitly retained the nested 360pt log cap as out of scope. This task completes that deferred change and revisits #120's global-flag decision.
- Hard constraint (#096): nothing in the dock stack may measure its own size during layout — the clipping fix must be a static layout change.
