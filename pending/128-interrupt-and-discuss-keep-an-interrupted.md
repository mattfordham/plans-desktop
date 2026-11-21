# Interrupt-and-discuss: keep an interrupted run's session alive so the user can talk to the agent and then continue or switch skills in the same context

**ID:** 128
**Created:** 2026-11-21T08:30
**Type:** feature
**Status:** pending

## What
Interrupt-and-discuss: keep an interrupted run's session alive so the user can talk to the agent and then continue or switch skills in the same context.

Clean context per action stays the default. Fire-and-forget elaborate/execute/capture must keep working with zero interaction, and a finished action closes its session. Session continuity only kicks in when the user **interrupts** a run (or the agent asks a question). From then on the plan holds a live conversation: the user discusses with the agent in that same session, then tells it to carry on or invokes a different skill (elaborate / execute / review / complete), all in that context. Clearing or closing that conversation must be one obvious click.

## Why
_To be filled during elaboration_

Context from the design discussion: today every action is its own `node run-task.js` process with a single `query()` call. Stop sends SIGTERM (`TaskRun.stop()` → `process.terminate()`). A follow-up composer turn resumes the killed session, but in `--mode discuss` (read-only tools, $5 cap, `/plan-discuss` framing). Clicking an action again starts a fresh session because `--resume` is discuss-only (`TaskRun.arguments`; the runner rejects it for other modes), so the discussion is lost unless it was applied to the plan file. In Claude Code, by contrast, Esc interrupts a turn without ending the session, and the next skill runs in the same conversation.

## How Summary
_To be filled during elaboration_

## How
_To be filled during elaboration_

Starting direction (not committed):

- **Session lifecycle model:** `closed` (default; the next action starts clean), `held` (after an interrupt or a parked question, the plan keeps its session id), then back to `closed` when the user clears it or when an action run in the held session finishes successfully. Default on action completion is to close (configurable later if wanted).
- **Phase 1 (small):** allow `--resume` for every mode, not just discuss. When the plan's session is `held`, action buttons and the composer resume it (the action is sent as the next message, e.g. `/plan-execute NNN worktree`); when `closed`, actions start fresh exactly as today. Keep per-mode tool lists per call: allowed tools are chosen per `query()`, so a read-only discuss turn can still share the session.
- **Phase 2:** a persistent runner process using SDK streaming input (`prompt: AsyncIterable<SDKUserMessage>`). Stop becomes `query.interrupt()` instead of SIGTERM; messages typed while the agent works are queued; the stdin `AskUserQuestion` bridge extends beyond review/complete for held sessions. Autonomous fire-and-forget runs keep "don't ask" prompts.
- **UI:** the dock shows whether the session is held, with a prominent **Clear / Close conversation** action; finishing an action closes it automatically; the composer offers "Continue" plus skill shortcuts when held.

## Verification
_To be filled during elaboration_

## Impact Scope
_To be filled during elaboration (if 3+ files affected)_

Likely: `Tools/work-task/run-task.ts`, `Sources/Plans/TaskRunner.swift`, `Sources/Plans/PlanAgent.swift`, `Sources/Plans/DiscussionThread.swift`, `Sources/Plans/AgentDock.swift`, plus tests.

## Assumptions

### Initial (from elaboration)
_To be filled during elaboration_

### Discovered during execution
_To be filled during execution_

## Changes
_To be filled during execution_

## Notes
Open questions to resolve in elaboration:
- Does a session killed by SIGTERM mid-tool resume cleanly, or can it leave a tool call with no result? This decides whether Phase 1 can keep SIGTERM.
- cwd constraint: sessions resume only from the directory they ran in. A kept-worktree review runs from the worktree, so it can't share a project-root session. Option: run review at the root and point it at the worktree path.
- Budget: today's caps ($40 action / $5 discuss) are per call; a held session spanning several actions may need a per-session cap.
- Session ids for held conversations should persist in app storage (Application Support), never in plan files (public).
- The new model makes the discuss `--apply` flag and the read-only/apply split less central; decide whether to keep them as per-turn tool postures.
- Bonus: in a persistent process, background subagents (#116) can deliver their completion instead of being killed at turn end.
