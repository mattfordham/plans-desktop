# Agent panel closed by default per plan, opened only by the user

**ID:** 130
**Created:** 2026-11-21T09:13
**Type:** bug
**Status:** elaborated

## What
The agent panel should be closed by default for every plan and only open when the user opens it. Its open/closed state should be remembered per plan.

Today:
- **Remembered per project, not per plan.** The open state is keyed by project (`AgentDock.dockOpenedKey` uses `"agentDockOpened:<projectPath>"`, #125), so opening it on one plan opens it on every plan in that project.
- **Auto-expands on activity.** `AgentDock` expands on any agent activity (`shouldAutoExpand` / `.onChange(of: agentState)`, #120). That expansion flows through `ResizableAgentDock`'s `.onChange(of: collapsed)`, which persists opened=true, so a single run marks the whole project as opened.

Fix:
- Key the persisted open flag per plan (project path + task id).
- Remove the auto-expand on activity.
- Persist only the user's own chevron toggle.

The footer (composer / Stop band / parked question) already stays visible when collapsed, so a parked question is still reachable. Update the #120/#125 tests accordingly.

**Elaboration guidance (this pass):** also fix a visual seam — the collapsed
panel strip has no top border, whereas the expanded panel reads with one. "Also,
the top of the panel when collapsed seems to not have a top border like the
discussion panel has on the top."

## Why
The agent dock is a persistent, per-plan surface, but its open/closed state leaks
across plans: open it on one plan and every plan in that project opens too, and a
single background run silently marks the whole project opened. Both break the
"closed by default, opened only by the user, remembered per plan" contract and
make the detail column feel unpredictable. The missing collapsed-state top border
is the same surface reading inconsistently between its two states — a small but
visible polish gap.

## How Summary
Re-key the dock-open persistence from project path to a per-plan identity
(project path + task id) and delete the auto-expand-on-activity behaviour so only
the user's own chevron toggle persists `opened`. Thread the per-plan key from
both `PlanDetailView` call sites into `ResizableAgentDock`, which owns the
`collapsed` `@State` and the persistence observer. Separately, give the collapsed
dock strip the same top `Divider` seam the expanded strip gets from its resize
`handle`, so the panel reads consistently in both states. Update the #120 and
#125 unit tests to the new per-plan keying and removed auto-expand.

**Files of note:**
- `Sources/Plans/AgentDock.swift` — `dockOpenedKey`/`dockWasOpened`/`setDockOpened`/`initialCollapsed` persistence helpers (re-key to per-plan), `shouldAutoExpand` + `.onChange(of: agentState)` auto-expand (remove), `ResizableAgentDock` container (`collapsed` state, `.onChange(of: collapsed)` persistence, collapsed branch that needs the top `Divider`).
- `Sources/Plans/PlanDetailView.swift` — the two `ResizableAgentDock(projectPath:)` call sites (lines ~181 and ~323) that must pass the task id for the per-plan key.
- `Tests/PlansTests/AgentDockTests.swift` — per-project open-state tests (#125) to re-point at the per-plan key.
- `Tests/PlansTests/PlanDetailViewTests.swift` — `shouldAutoExpand` tests (#120) to remove/replace once auto-expand is gone.

## Diagnosis

**Most likely:** Three independent causes produce the reported behaviour, each
localized:
1. The open flag is keyed by project only — `dockOpenedKey` returns
   `"agentDockOpened:" + projectPath` (`Sources/Plans/AgentDock.swift:283`), so
   every plan in a project shares one flag and opening one opens all.
2. The dock auto-expands on any agent activity — `shouldAutoExpand(for:)` is
   `state != .idle` (`Sources/Plans/AgentDock.swift:254`) and `.onChange(of: agentState)`
   sets `collapsed = false` (`Sources/Plans/AgentDock.swift:361`); that expansion flows
   through `ResizableAgentDock`'s `.onChange(of: collapsed)` which calls
   `setDockOpened(true, …)` (`Sources/Plans/AgentDock.swift:1028`), so a run persists
   opened without a user gesture.
3. The collapsed strip renders no top border — `ResizableAgentDock.body`'s
   collapsed branch renders only `dock($collapsed)` (`Sources/Plans/AgentDock.swift:1011`),
   while the expanded branch renders the `handle` (a `Divider`) first
   (`Sources/Plans/AgentDock.swift:1017`, `:1034`); so only the expanded dock gets a top seam.

**Evidence:** `dockOpenedKey(projectPath:)` takes only a project path and the two
`ResizableAgentDock(projectPath:)` call sites
(`Sources/Plans/PlanDetailView.swift:181`, `:323`) pass only the project path even
though both have a task id in hand (`row.task.id`, `captureRun?.taskID`). The
auto-expand observer and the persistence observer share the single `$collapsed`
binding, so auto-expand and manual-open are indistinguishable at the persistence
site (comment at `Sources/Plans/AgentDock.swift:1023-1027` says so explicitly). The
collapsed `VStack` branch has no `Divider`/`handle` child.

**Confidence:** high — all three are directly read from the current source; the
behaviour follows mechanically from the keying and the view structure.

**To confirm:** Build and run the app; select two plans in the same project and
confirm opening the dock on one no longer opens it on the other, confirm a
background run does not open a collapsed dock, and confirm the collapsed strip now
shows a top border flush with the plan body above it. (`👁` — requires observing
the running macOS UI.)

## How
- [ ] 👁 Step 1: Reproduce in the running app (`./build.sh`) — open the dock on plan A in a project, switch to plan B in the same project and confirm the dock is open there too; trigger a run on a collapsed plan and confirm it auto-expands; note the collapsed strip has no top border. (Confirms the Diagnosis before any fix; requires observing the macOS UI.)
- [ ] Step 2: Re-key the open-state persistence per plan in `Sources/Plans/AgentDock.swift`: change `dockOpenedKey` (and the `dockWasOpened` / `setDockOpened` / `initialCollapsed` helpers) to take a per-plan identity (project path + task id) instead of `projectPath` alone — e.g. `dockOpenedKey(projectPath:taskID:)` producing `"agentDockOpened:<projectPath>#<taskID>"`. Keep the "remove key on collapse" semantics.
- [ ] Step 3: Thread the task id from both call sites in `Sources/Plans/PlanDetailView.swift` into `ResizableAgentDock` (new `taskID` parameter alongside `projectPath`): `row.task.id` at the active-plan site (~line 181) and `captureRun?.taskID` at the capture-placeholder site (~line 323). Update `ResizableAgentDock`'s `init` and the `initialCollapsed` / `setDockOpened` calls to pass the per-plan key.
- [ ] Step 4: Remove the auto-expand-on-activity in `Sources/Plans/AgentDock.swift`: delete the `.onChange(of: agentState)` handler in `AgentDock.body` (lines ~361-365) and remove the now-unused `shouldAutoExpand(for:)` pure helper. Confirm `agentState` has no other consumer that breaks; leave the footer-always-visible behaviour (`showsFooter`) untouched so a parked question stays reachable while collapsed.
- [ ] Step 5: Give the collapsed strip a top border in `ResizableAgentDock.body`: render a leading `Divider()` (matching the expanded `handle`'s divider look) above `dock($collapsed)` in the collapsed branch (lines ~1011-1015) so the collapsed panel reads with the same top seam the expanded panel gets. Do not add drag behaviour to this divider — it is a static seam, not a resize handle. Introduce no size measurement (#096).
- [ ] Step 6: Update the #125 tests in `Tests/PlansTests/AgentDockTests.swift` to the per-plan key: pass `taskID` to `dockOpenedKey` / `dockWasOpened` / `setDockOpened` / `initialCollapsed`, and add a test proving two plans in the SAME project keep independent open flags (the core regression this fixes).
- [ ] Step 7: Update the #120 tests in `Tests/PlansTests/PlanDetailViewTests.swift`: remove the `shouldAutoExpand*` tests (the behaviour is gone) and, if a pure helper remains for collapse logic, assert the collapsed strip still shows the footer and now has a top-border seam insofar as it is unit-testable (otherwise rely on the Step 1 visual check).
- [ ] Step 8: Run `swift build` and `swift test`; fix any references to the removed `shouldAutoExpand` / old `dockOpenedKey` signature until the suite is green.

## Verification
- `swift build` succeeds and `swift test` passes, including the updated #120/#125 tests and a new test proving two plans in one project keep independent dock-open flags.
- 👁 In the running app: opening the dock on one plan no longer opens it on sibling plans in the same project; the open/closed state is remembered per plan across selection changes.
- 👁 A background agent run on a collapsed plan no longer forces the dock open — only the user's chevron toggle changes the open state. A parked question remains reachable (footer visible) while collapsed.
- 👁 The collapsed panel strip shows a top border flush with the plan body above it, matching the expanded panel's top seam.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/AgentDock.swift` — per-plan re-key of the open-state helpers; remove auto-expand (`.onChange(of: agentState)` + `shouldAutoExpand`); add the collapsed-strip top `Divider`.
- [ ] `Sources/Plans/PlanDetailView.swift` — pass `taskID` into both `ResizableAgentDock` call sites.
- [ ] `Tests/PlansTests/AgentDockTests.swift` — re-point #125 open-state tests at the per-plan key; add the sibling-plan independence test.
- [ ] `Tests/PlansTests/PlanDetailViewTests.swift` — remove/replace the #120 `shouldAutoExpand` tests.

### Related Files (may need updates)
- `Sources/Plans/TaskRunner.swift` / `PlanAgent` — only if `agentState` loses its sole remaining consumer after auto-expand removal (verify; likely still used by the status pill).

### Endpoints/UI Affected
- Agent dock in the browser detail column (Surface B) — per-plan open memory; no auto-expand on activity; consistent top border when collapsed.

## Assumptions

### Discovered during elaboration (autonomous design choices — flag for review)
- [low] **Per-plan key format is `"agentDockOpened:<projectPath>#<taskID>"`.** The source description says "key per plan (project path + task id)" but not the exact string. Chose a `#` delimiter appended to the existing namespaced key so it stays greppable and backward-distinct from the old project-only keys. **Why:** mirrors the existing `dockOpenedKey` namespacing; any stable composite works since the value is UserDefaults-only and in-contract private. Reviewer may prefer a different separator.
- [low] **Collapsed-strip top border is a plain static `Divider()`, not a styled/custom rule.** The expanded strip's top seam comes from the resize `handle`, which is itself a `Divider()` (with drag padding). Chose to reuse a bare `Divider()` for the collapsed strip so the two states match visually without adding resize behaviour to the collapsed seam. **Why:** matches the expanded look with the least new surface; the user's note asks only for parity with "the top border ... the discussion panel has".
- [low] **Removing auto-expand outright (not gating it) is the intended fix.** The source description says "Remove the auto-expand on activity" and "Persist only the user's own chevron toggle," so `shouldAutoExpand` and its `.onChange(of: agentState)` handler are deleted rather than made conditional. **Why:** keeping any auto-expand path would re-introduce the silent persist-on-activity leak the task targets. The footer stays visible when collapsed, so a parked question is still reachable without auto-expanding.
- [high] **The capture-placeholder dock uses `captureRun?.taskID` for its per-plan key.** Both `ResizableAgentDock` call sites already have a task id in scope; the capture site passes `captureRun?.taskID` and `captureRun?.runProjectPath ?? ""`. **Why:** the capture row is a real (synthetic) plan with its own id, and keying it consistently keeps its dock state from colliding with a sibling plan's.

### Discovered during execution
_To be filled during execution_

## Changes
_To be filled during execution_

## Notes
_Additional context_
