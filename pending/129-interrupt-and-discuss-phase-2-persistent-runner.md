# Interrupt-and-discuss Phase 2: persistent streaming-input runner with real interrupt, typing while working, and AskUserQuestion in held sessions

**ID:** 129
**Created:** 2026-11-21T09:03
**Type:** feature
**Status:** pending

## What
Follow-up to #128.

Phase 2 of interrupt-and-discuss. Replace the one-process-per-action runner with a persistent, streaming-input process per plan, so a held conversation is a live session rather than a chain of `--resume` launches.

Scope:
- **Persistent streaming-input runner.** `run-task.ts` keeps one `query()` open with an async-iterable prompt stream. The app feeds follow-up user messages into it instead of spawning a new `node run-task.js --resume <id>` for each turn or action.
- **Real interrupt.** Stop calls `query.interrupt()` instead of SIGTERM, so the agent halts mid-turn and the session stays live in the same process. No `tool_use` is left without a `tool_result`, and nothing has to be reloaded from the transcript.
- **Typing while working.** The dock composer stays usable while the agent is running. A message sent mid-run either queues for the next turn or interrupts and redirects. This replaces the disabled "Stop to interrupt" band.
- **`AskUserQuestion` in held sessions.** A held or discuss session can park on an `AskUserQuestion` and show the `ParkedQuestionForm`, just like action runs do today. Read-only discuss turns currently can't.

Phase 1 (#128) stays the baseline. Fire-and-forget actions keep clean context, a finished action closes its session, and Close conversation is still one click.

## Why
Phase 1 (#128) holds an interrupted session by SIGTERM-ing the runner and resuming the session id in a new process for every turn. That works, but it has costs:
- each turn pays a process spawn and a history reload;
- a Stop mid-tool can leave a dangling `tool_use`;
- the user can't type while the agent works;
- held discuss turns can't ask the user a structured question.

A persistent streaming-input process with `query.interrupt()` gives the actual Claude Code interaction model: interrupt, redirect, answer questions, all in one live session.

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
