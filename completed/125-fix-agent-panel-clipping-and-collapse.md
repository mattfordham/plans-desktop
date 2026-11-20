# Fix agent panel clipping and collapse it by default

**ID:** 125
**Created:** 2026-11-20T10:33
**Type:** bug
**Status:** completed
**Branch:** fix/125-fix-agent-panel-clipping-and-collapse
**Completed:** 2026-11-20T12:13

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
- [x] 👁 Step 1: Reproduce — open a plan with a long run transcript, expand the agent dock, and drag the handle taller than ~500pt; confirm the log stays pinned at ~360pt with mid-line clipping at both edges and a blank band below (confirms the Diagnosis before any fix)
- [x] Step 2: TDD — write failing tests for a `RunLogContents` inline (non-scrolling) hosting mode and for any new `AgentDock` layout helper (pure helpers in the existing `PlanDetailViewTests`/`PlanAgentTests` style)
- [x] Step 3: Fix clipping — drop the `maxHeight: 360` wrapper at `Sources/Plans/AgentDock.swift:343` and render `RunLogContents` through a non-scrolling inline path (extend the existing `edgeToEdge`-style option at `PlanDetailView.swift:1730`) when hosted in the dock transcript, so the outer transcript `ScrollView` is the single scroll container; preserve auto-scroll-to-bottom behavior and the #096 no-self-measurement invariant
- [x] Step 4: TDD — write failing tests for per-project dock-open persistence: `nonisolated static` key/getter/setter helpers keyed `"agentDockOpened:" + projectPath`, mirroring `ReviewModal.swift:224-242`
- [x] Step 5: Replace the global `agentDockCollapsed` `@AppStorage` (`AgentDock.swift:639`) with per-project derived state: thread the project path into `ResizableAgentDock`/`AgentDock`, default to collapsed when no flag is set, record the flag on manual header expand (`AgentDock.swift:212-214`) and on auto-expand-on-activity (`AgentDock.swift:147-151`), and clear it on manual collapse; keep `agentDockHeight` global
- [x] Step 6: Run `swift test` — scoped to affected classes per the targeted-tests rule (AgentDockTests, PlanDetailViewTests) plus `swift build`; all pass
- [ ] 👁 Step 7: Launch the app (`./build.sh`) and verify: dock starts collapsed on a project never opened in; expanding persists only for that project across selection changes and relaunch; a long transcript scrolls fully in one container with no mid-line clipping and no blank band at any dock height — deferred to human review (worktree mode)

## Verification
- The clipping no longer occurs: with a long run transcript and the dock resized to any height, log content scrolls fully within a single scroll container — no mid-line cropping at the top or bottom, no dead blank band between the log and the footer.
- The dock is collapsed by default: on a project where the user never opened it, the dock renders collapsed on every plan; manually expanding it persists the open state for that project only (other projects stay collapsed); manually collapsing returns that project to collapsed-by-default.
- New unit tests cover the inline run-log hosting mode and the per-project opened-flag helpers; `swift test` passes with no regressions.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/AgentDock.swift` — remove the 360pt inner cap; swap global `agentDockCollapsed` for per-project opened-flag derivation; record the flag on manual/auto expand
- [x] `Sources/Plans/PlanDetailView.swift` — `RunLogContents` inline (non-scrolling) hosting mode; pass project path into `ResizableAgentDock` where needed
- [x] `Tests/PlansTests/AgentDockTests.swift` (new) — tests for the inline run-log mode and the per-project opened-flag helpers (consolidated here rather than split across PlanDetailViewTests/PlanAgentTests)

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
- [high] The inline `RunLogContents` path intentionally DROPS the inner `ScrollViewReader`/auto-scroll (both the `.onChange(of: lines.count)` follow and the `.onAppear` jump-to-bottom). **Why:** the dock's outer transcript `ScrollView` already owns scroll + auto-scroll-to-bottom via `AgentDock.transcriptScrollKey` (keyed on the last run's `lines.count`), so keeping an inner auto-scroll would fight the outer one and nest a second scroll region — the exact nesting that caused the 360pt mid-line clipping. Inline keeps the same column content/padding/background; only the scroll wrapper is removed.
- [high] The testable seam for Step 3 is the pure `RunLogContents.logListIsScrolling(inline:) -> Bool` (returns `!inline`) plus the public `inline` stored property (defaults `false`). **Why:** SwiftUI view bodies aren't unit-tested here; a pure static flag/helper is the project's established testable surface (mirrors `dockFooterMode`, `showsTranscript`), and asserting the property default guards every existing non-dock call site.
- [high] Step 4 UserDefaults test isolation uses a per-test `UserDefaults(suiteName:)` with a UUID-named suite, torn down via `removePersistentDomain(forName:)`. **Why:** mirrors the project's UUID-named filesystem-fixture isolation so tests never read/write `.standard`; `removePersistentDomain` in `tearDown` leaves no residue between runs.
- [high] `dockWasOpened` reads via `defaults.bool(forKey:)` (not `object(forKey:)`), relying on `bool` returning `false` for a missing key. **Why:** `setDockOpened(false)` REMOVES the key (collapsed-by-default == never-opened), so a missing key must read as not-opened; `bool(forKey:)` gives exactly that without an extra nil-check.
- [high] A SINGLE `.onChange(of: collapsed)` in `ResizableAgentDock` persists the per-project flag for BOTH the manual header-chevron toggle AND the auto-expand-on-activity path (Step 5). **Why:** both mutate the same `$collapsed` binding owned by `ResizableAgentDock` (the header's `collapsed.toggle()` and the dock's `.onChange(of: agentState)` auto-expand both write through the shared binding), so one observer on the owner's state covers every transition — expand records opened=true, manual collapse clears the flag (collapsed-by-default). No separate hook per call site is needed.
- [low] The capture-placeholder host passes `projectPath: captureRun?.runProjectPath ?? ""`; an empty project path is accepted as-is. **Why:** a synthetic `capture:` selection has no stable project until it lands, so its dock reads/writes the harmless `"agentDockOpened:"` (empty-suffix) key. The placeholder is transient and `validSelection` remaps to the real row once the capture migrates, at which point the real project's per-project state applies; storing a global-ish empty-key flag for the brief capture window is acceptable and never leaks into a real project's key.

## Changes

### Clipping fix (Steps 2–3)
- `Sources/Plans/PlanDetailView.swift` — `RunLogContents` gained an `inline: Bool = false` property and a pure `static func logListIsScrolling(inline:) -> Bool`. `logList` now splits into a scrolling path (unchanged inner `ScrollView` + `ScrollViewReader` auto-scroll) and a non-scrolling inline path; shared content extracted into a `logColumn` view so both paths render identical lines/padding/background. The inline path has no inner scroll — the host's outer scroll owns scrolling.
- `Sources/Plans/AgentDock.swift` — `runSegment` now calls `RunLogContents(run:edgeToEdge:true, inline:true, …)` and the `.frame(maxHeight: 360)` cap was replaced with `.frame(maxWidth: .infinity)`. The dock's outer transcript `ScrollView` is now the single scroll container; a long run log scrolls fully with no mid-line crop and no blank band at any dock height. #096 preserved (static layout, no self-measurement).
- `Tests/PlansTests/AgentDockTests.swift` (new) — 3 tests for the inline run-log mode.

### Per-project persistence helpers (Step 4)
- `Sources/Plans/AgentDock.swift` — added `nonisolated static` helpers mirroring `ReviewModal`'s per-project UserDefaults idiom: `dockOpenedKey(projectPath:)` → `"agentDockOpened:" + projectPath`, `dockWasOpened(projectPath:defaults:)`, `setDockOpened(_:projectPath:defaults:)` (removes the key when not opened), and `initialCollapsed(projectPath:defaults:)` → `!dockWasOpened(...)`.
- `Tests/PlansTests/AgentDockTests.swift` — 7 tests for the persistence helpers (isolated via per-test `UserDefaults(suiteName:)`).

### Per-project collapse wiring (Step 5)
- `Sources/Plans/AgentDock.swift` — removed the single global `@AppStorage("agentDockCollapsed")` from `ResizableAgentDock`; added a `let projectPath: String` plus an explicit `init(projectPath:dock:)` that seeds `@State private var collapsed` from `AgentDock.initialCollapsed(projectPath:)` (collapsed unless the user previously opened the dock for that project). A single `.onChange(of: collapsed)` calls `AgentDock.setDockOpened(!collapsed, projectPath:)`, so expanding (manual chevron OR auto-expand-on-activity, which both flow through the same binding) records opened=true and manual collapse clears the flag → collapsed-by-default. `@AppStorage("agentDockHeight")` stays global/untouched.
- `Sources/Plans/PlanDetailView.swift` — both `ResizableAgentDock` host sites now pass `projectPath:` (real plan → `row.projectPath`; capture placeholder → `captureRun?.runProjectPath ?? ""`).

### Tests
- `swift build` clean. `swift test --filter AgentDockTests` → 10 passed. `swift test --filter PlanDetailViewTests` → 105 passed (regression check for the `RunLogContents` refactor). Scoped per the targeted-tests rule; full suite is the user's responsibility.

### Deferred to review (worktree mode)
- Step 1 (👁 reproduce the clipping) and Step 7 (👁 launch app: collapsed-by-default per project, expand persistence across selection/relaunch, long-transcript single-container scroll) are observation steps deferred to `/plan-review` for human verification. Branch @ work: see state file for provenance SHAs.

## Notes
- Screenshot evidence: the dock's run transcript clipped mid-line at top and bottom of a fixed-height box with a blank band below, while expanded by default.
- Prior work: #120 made the dock collapsible (global `@AppStorage`, deliberate at the time); #121 fixed bottom-half clipping from segment stacking/auto-scroll but explicitly retained the nested 360pt log cap as out of scope. This task completes that deferred change and revisits #120's global-flag decision.
- Hard constraint (#096): nothing in the dock stack may measure its own size during layout — the clipping fix must be a static layout change.
