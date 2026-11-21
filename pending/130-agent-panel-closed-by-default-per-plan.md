# Agent panel closed by default per plan, opened only by the user

**ID:** 130
**Created:** 2026-11-21T09:13
**Type:** bug
**Status:** pending

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

## Why
_To be filled during elaboration_

## How Summary
_To be filled during elaboration_

## How
_To be filled during elaboration_

## Verification
_To be filled during elaboration_

## Impact Scope
_To be filled during elaboration (if 3+ files affected)_

## Assumptions

### Initial (from elaboration)
_To be filled during elaboration_

### Discovered during execution
_To be filled during execution_

## Changes
_To be filled during execution_

## Notes
_Additional context_
