# Interrupt-and-discuss Phase 2: persistent streaming-input runner with real interrupt, typing while working, and AskUserQuestion in held sessions

**ID:** 129
**Created:** 2026-11-21T09:03
**Type:** feature
**Status:** in-progress
**Branch:** feature/129-interrupt-and-discuss-phase-2-persistent-runner

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
Give `run-task.ts` a `--session` mode. In that mode the SDK `query()` takes an async-iterable prompt queue, and a stdin control protocol (`user` / `interrupt` / `answer` / `close`) drives it. The app launches resumable actions and discuss turns as session processes. A clean action finish still closes its process (Phase 1 clean context). A Stop calls `query.interrupt()`, which leaves the process alive and idle as the plan's live held session. Follow-up messages and Continue go into that session over stdin, and discuss turns can park on `AskUserQuestion`. Read-only discuss turns inside a write-capable session are enforced per turn by a `PreToolUse` posture hook. Action chips launched from a live session hand off (close, then a fresh `--session --resume` process), because cwd, system prompt and allowlist are fixed when the query starts.

**Files of note:**
- `Tools/work-task/run-task.ts`: `--session`, input queue, `parseControlLine`, posture hook, per-turn `turn` / `done.interrupted` events, session discuss prompts
- `Tools/work-task/run-task.session.test.ts` (new): pure tests for the control protocol, posture predicate and prompts
- `Sources/Plans/TaskRunner.swift`: session `TaskRun` (stdin writers, `turnActive`, `onTurnEnd`), launch/stop/send/close wiring, `RunEvent` decoding
- `Sources/Plans/PlanAgent.swift`: `liveSession`, session-aware `sendDisposition`, interrupted-turn hold, discuss `.needsInput`, `pendingQuestionRun`
- `Sources/Plans/AgentDock.swift`: question footer resolves the session/discuss run; Stop interrupts the live session
- `CLAUDE.md`: held-conversation / agent dock conventions

## How
- [ ] Step 1: Spike outside the repo (scratch Node script against the installed SDK 0.3.215, not committed). Confirm three things: (a) a slash command (`/plan-execute N`) sent as the first streaming-input message invokes the skill exactly as a string prompt does; (b) `query.interrupt()` mid-tool produces a `result` of a known shape (record `subtype` / `terminal_reason` / `interrupt_receipt_v1`), leaves no dangling `tool_use`, and a message pushed afterwards runs in the same session; (c) a `PreToolUse` hook deny blocks Write/Edit/Bash under `permissionMode: "acceptEdits"`. Record the findings in `## Changes`. If (a) or (b) fails, stop and report a blocker.
- [ ] Step 2: Runner session core in `Tools/work-task/run-task.ts`. Add a valueless `--session` flag (no flag means the single-string path stays byte-for-byte unchanged). Add an exported `createInputQueue()` (push/end) whose first message is `buildPrompt(args)`, and an exported pure `parseControlLine` for `{kind:user,text,posture}`, `{kind:interrupt}`, `{kind:answer,...}` and `{kind:close}`; stdin EOF means close. In session mode, always install `canUseTool` parking; a parked question aborted by interrupt resolves to `deny`, not an empty `allow`. Emit `{kind:"turn",state}` at turn boundaries and `done.interrupted:true` for an interrupted turn. A cleanly finished, non-interrupted action turn ends the queue so the process exits (finished action closes its session); a discuss session stays open until `close`/EOF. SIGTERM stays as the hard fallback. Update the NDJSON header doc. TDD in new `Tools/work-task/run-task.session.test.ts`, added to the `test` script.
- [ ] Step 3: Per-turn posture and session discuss prompts in `run-task.ts`. Add an exported pure `toolAllowedForPosture(tool, posture)` (discuss = read-only: deny Write/Edit/NotebookEdit/Bash; apply/action = allow), enforced through a `PreToolUse` hook keyed on the current turn's posture. Add session variants of the discuss follow-up / apply prompts that drop "do NOT ask the user any questions" and allow `AskUserQuestion`. Keep `AskUserQuestion` out of `allowedTools` (shadowing). Session budget is the launching mode's cap. Tests first; then `npm run build` to refresh `dist/`.
- [ ] Step 4: Swift `TaskRun` session support in `Sources/Plans/TaskRunner.swift`. Add a `session` flag that appends `--session` to `arguments` and creates the stdin pipe when `mode.isInteractive || session`. Add pure `userLine(text:posture:)` / `interruptLine()` / `closeLine()` beside `answerLine`, and `send(text:posture:)` / `interrupt()` / `close()` writers on `answerQueue`. Decode the `turn` event and `done.interrupted` in `RunEvent`. Track `turnActive` separately from process-alive, and fire a per-turn `onTurnEnd` callback without the process exiting. Tests in `Tests/PlansTests/TaskRunnerTests.swift` via the `ingestForTesting` / `standardInputForTesting` seams.
- [ ] Step 5: `Sources/Plans/PlanAgent.swift` state machine. Add `liveSession: TaskRun?` and a `pendingQuestionRun` accessor (`currentRun ?? liveSession ?? discuss run`). Make `sendDisposition` session-aware: `.deliverToSession` when the session is idle, and `.interruptSessionThenDeliver` when a turn is active (the message waits as `queuedSend` until the interrupted turn's `onTurnEnd`, so no queued message survives the interrupt). Add a pure `holdAfterSessionTurn` (an interrupted turn holds the same session id; a clean action turn clears the hold), leaving `nextHold` unchanged for fire-and-forget. `applyDiscussEvent` handles `.question` → `.needsInput`, and an answer returns to `.working(.discuss)`. Tests in `Tests/PlansTests/PlanAgentTests.swift`.
- [ ] Step 6: `TaskRunner` wiring. Resumable actions (execute, elaborate, reElaborate*, review, complete — not kept review, capture, or executeYolo) and discuss turns with no live session launch with `session: true`. Stop on a session run writes `interrupt` (no SIGTERM, no `finish`), and the process becomes `liveSession` with the hold set; Stop on a non-session run stays SIGTERM. `send` / Continue go into the live session via `userLine` (posture discuss or apply) instead of `launchDiscuss`. Action chips from a live session hand off: `close`, then launch a fresh session process with `--resume <held id>`. `closeConversation` writes `close`. Quit / `stopAllRunning` send `close`, then SIGTERM after a grace period. `liveRuns` / `hasRunningRun` / the quit guard / sync pause use `turnActive`, so an idle held session doesn't count as running, and a store reload fires on each action `onTurnEnd`. Recorder-pattern tests in `TaskRunnerTests.swift`.
- [ ] Step 7: Dock and docs. In `Sources/Plans/AgentDock.swift`, the `.question` footer resolves the form via `pendingQuestionRun` so discuss/session turns show `ParkedQuestionForm`, and answers route to that run. Stop calls the session interrupt. Keep `dockFooterMode` / `conversationButtons` pure, with tests for the live-session states in `Tests/PlansTests/AgentDockTests.swift`; do no size measurement (#096). Update the CLAUDE.md agent-dock and held-conversation bullets (Phase 2 delivered: live session, real interrupt, discuss questions) and the NDJSON contract docs on both sides. Run the targeted tests (`swift test --filter` for the touched suites; `npm test` in `Tools/work-task`).
- [ ] 👁 Step 8: Manual check in the app (`./build.sh`). Start Execute on a plan and Stop mid-tool: the pill shows the held state and no new process is spawned. Send a message: the reply arrives in the same session. Ask something that makes the agent use `AskUserQuestion` in a discuss turn: `ParkedQuestionForm` appears and the answer continues the turn. Send mid-turn: it interrupts and redirects. Close conversation: the node process exits.

## Verification
- `npm test` in `Tools/work-task` passes, including the new `run-task.session.test.ts`. Without `--session`, the runner's argv and prompts are unchanged (existing mode tests stay green).
- Targeted `swift test --filter` runs for TaskRunnerTests, PlanAgentTests, AgentDockTests and DiscussionThreadTests pass. Phase 1 fire-and-forget tests (`nextHold`, SIGTERM stop of non-session runs) stay green.
- In the app: Stop mid-run keeps the same node process alive as an idle held session (`pgrep -fl run-task` shows one process; no relaunch with `--resume` on the next message).
- A discuss turn in a held session can show `ParkedQuestionForm` and resume after the answer. Close conversation exits the process. A clean action finish still exits its process (clean context).

## Impact Scope

### Files to Modify
- [ ] `Tools/work-task/run-task.ts`: session mode, control protocol, posture hook, turn events, session prompts
- [ ] `Tools/work-task/package.json`: add the session test file to `test`
- [ ] `Tools/work-task/run-task.session.test.ts` (new): pure session tests
- [ ] `Sources/Plans/TaskRunner.swift`: session TaskRun, RunEvent, launch/stop/send/close wiring
- [ ] `Sources/Plans/PlanAgent.swift`: liveSession, sendDisposition, session hold, discuss needsInput
- [ ] `Sources/Plans/AgentDock.swift`: question footer source, Stop → interrupt
- [ ] `Tests/PlansTests/TaskRunnerTests.swift`, `PlanAgentTests.swift`, `AgentDockTests.swift`: new cases
- [ ] `CLAUDE.md`: agent dock / held conversation conventions

### Related Files (may need updates)
- `Sources/Plans/DiscussionThread.swift`: currently ignores `.question`; may need to render a parked-question turn
- `Sources/Plans/PlanDetailView.swift`: `reviewAnswers` / `openDockAction` answer routing and chips
- `Sources/Plans/BrowserWindow.swift`: active-runs indicator and answer sheet use `liveRuns`
- `Sources/Plans/PlansApp.swift`: quit guard / `stopAllRunning`

### Endpoints/UI Affected
- Agent dock: Stop, composer send, Continue, Close conversation, parked-question footer in discuss turns
- Toolbar active-runs indicator and quit guard (an idle held session is not "running")

## Assumptions

### Initial (from elaboration)
- [low] Session lifetime: resumable actions and discuss run as session processes. A clean action finish exits (clean context), an interrupt keeps the process alive as the held live session, and fire-and-forget behaviour is otherwise unchanged. **Why:** matches the task's "a finished action closes its session" while making Stop a real `interrupt()`; research listed per-plan always-on sessions as the alternative.
- [low] Mid-run send interrupts and redirects (keeps #128 behaviour). There is no separate "queue for next turn without interrupting" gesture. **Why:** the first option; the redirect waits for the interrupted turn's end, so no stale queued message runs.
- [low] Action chips (Execute/Elaborate/Review/Complete) from a live session hand off (close, then a fresh `--session --resume`) rather than being pushed into the session. **Why:** cwd, systemPrompt and allowedTools are fixed at query start; review/complete depend on their own system prompt.
- [low] Read-only discuss turns in a write-capable session are enforced by a per-turn `PreToolUse` posture hook, not by a separate read-only process. **Why:** under `acceptEdits`, allowlisted Write/Edit never reach `canUseTool`; the spike (Step 1c) confirms the hook works.
- [low] Budget is one session-wide cap equal to the launching mode's cap (no per-turn cost-delta enforcement). **Why:** `maxBudgetUsd` is per query; per-turn caps need delta tracking, which is out of scope.
- [high] Kept reviews, capture modes and executeYolo stay fire-and-forget single-turn processes. **Why:** they never resume a hold today (`resumesHeldSession`), and kept reviews run in a worktree cwd that `nextHold` never holds.

### Discovered during execution
_To be filled during execution_

## Changes
_To be filled during execution_

## Notes
_Additional context_
