# Interrupt-and-discuss: keep an interrupted run's session alive so the user can talk to the agent and then continue or switch skills in the same context

**ID:** 128
**Created:** 2026-11-21T08:30
**Type:** feature
**Status:** in-progress
**Branch:** feature/128-interrupt-and-discuss-keep-an-interrupted
**Worktree:** /Users/matt/Work/Open Source/plans-desktop/.worktrees/128-interrupt-and-discuss-keep-an-interrupted

## What
Interrupt-and-discuss: keep an interrupted run's session alive so the user can talk to the agent and then continue or switch skills in the same context.

Clean context per action stays the default. Fire-and-forget elaborate/execute/capture must keep working with zero interaction, and a finished action closes its session. Session continuity only kicks in when the user **interrupts** a run (or the agent asks a question). From then on the plan holds a live conversation: the user discusses with the agent in that same session, then tells it to carry on or invokes a different skill (elaborate / execute / review / complete), all in that context. Clearing or closing that conversation must be one obvious click.

## Why
Interrupting a run today strands its context. After a Stop, the user can only talk to the killed session read-only. Clicking Execute or Elaborate again starts a fresh session, so whatever was discussed is lost unless it was written into the plan file. A "held" conversation that begins only on interrupt brings the Claude Code workflow into the app (interrupt, discuss, carry on or switch skill in the same context) without giving up clean-context fire-and-forget runs, which work well for the common case.

Background: every action is its own `node run-task.js` process with one `query()` call. Stop sends SIGTERM (`TaskRun.stop()` → `process.terminate()`), which `finish(error: nil)` records exactly like a clean finish. The session id is still recorded in `PlanAgent.lastSession` (#118), so the composer can resume it read-only. `--resume` is discuss-only, in both `TaskRun.arguments` and `run-task.ts` `parseArgs`.

## How Summary
Add an explicit **hold** to the plan's `PlanAgent`. The hold is set only when a run is user-stopped (or abandoned while parked on a question) and its session is resumable from the project root. It is cleared by a successful action finish or by a one-click **Close conversation**. While a plan is held, action launches pass `--resume <held session>` (now accepted for every mode) and the composer continues the same session. With no hold, every launch has exactly today's arguments, so fire-and-forget stays clean-context and byte-identical. The runner gains a SIGTERM handler that closes the SDK query, so a Stop leaves no orphaned CLI process and leaves a resumable session. Phase 2 (a persistent streaming-input process with real `interrupt()`) is a separate follow-up task.

**Files of note:**
- `Sources/Plans/PlanAgent.swift` — the hold state and pure transition rules (set on stop, clear on success or close)
- `Sources/Plans/TaskRunner.swift` — `TaskRun.wasStopped`, `--resume` for all modes, `run`/`review`/`complete` pass the held session
- `Tools/work-task/run-task.ts` — accept `--resume` in every mode, resumed-prompt lead lines, SIGTERM → close query
- `Sources/Plans/AgentDock.swift` — held indicator, Close conversation control, Continue and skill chips in the composer
- `Tests/PlansTests/PlanAgentTests.swift`, `Tests/PlansTests/TaskRunnerTests.swift`, `Tests/PlansTests/AgentDockTests.swift`, `Tools/work-task/run-task.modes.test.ts` — tests

## How
- [ ] Step 1: **Record why a run ended.** Add `TaskRun.wasStopped` (set in `stop()` before `finish`, `TaskRunner.swift:789`). Also record whether the run was parked on a question when it ended. Tests first: a stopped run reports stopped; a natural finish and an errored finish do not (extend near `testStopFinishesOnceEvenWhenExitAndEOFFollow`).
- [ ] Step 2: **Hold state in `PlanAgent`.** Add `hold: SessionHold?` (session id, cwd, interrupted mode, summary) and a pure `static func nextHold(current:endedRun:projectRoot:) -> SessionHold?`.
  - Set the hold when the run was stopped or abandoned while parked, it has a session id, and its cwd is the project root. A kept review never sets it.
  - Clear it when an action launched *from* the hold finishes cleanly.
  - Keep it when a run fails or is stopped again, and across discuss turns.
  - A clean run started without a hold leaves it nil.
  - Add `closeConversation()`, a full idle-only reset of transcript, thread, lineage and hold, built on `reset()`.
  - Leave #118 `lastSession` lineage as-is, so composer questions after a clean finish still resume read-only.
  - TDD in `PlanAgentTests.swift`.
- [ ] Step 3: **Runner accepts `--resume` in every mode.**
  - In `run-task.ts`, remove the discuss-only guard in `parseArgs` (~281). This flips the "complete mode rejects --resume" test into "accepts --resume".
  - In `buildPrompt`, when `args.resume` is set for execute/elaborate/reElaborate*, prefix a one-line "You are continuing the conversation above — now run:" lead before the existing builder output. Review and complete stay *bare* slash commands, with any extra framing in `systemPrompt`.
  - Add a `process.on("SIGTERM")` handler that closes the active query (`response.close()`), then exits, so the CLI child is not orphaned.
  - Node tests in `run-task.modes.test.ts`, then rebuild `dist/`.
- [ ] Step 4: **Swift arguments.** In `TaskRun.arguments`, emit `--resume` for any mode when a non-empty resume is given (still last in argv). Thread a `resume:` parameter, defaulting to nil, through `TaskRunner.run`, `review` and `complete`.
  - Each uses `agent.hold` only when `hold.cwd == projectPath`. A kept review starts fresh and leaves the hold intact.
  - Capture modes never resume.
  - Tests: flip `testArgumentsIgnoreResumeForNonDiscussModes` to "emits resume for any mode when provided". Add a test that no-hold arguments are byte-identical to today for every mode. Add a launcher-seam test that a held plan's execute passes the held id and a kept review does not.
- [ ] Step 5: **Composer and discuss in a held plan.** `launchDiscuss` resumes `hold.id` when held (preferring it over `lastSession`). The fresh-turn context framing generalises `DiscussionThread.question(_:withReviewContext:)` copy from "guided review" to "the interrupted <mode> run".
- [ ] Step 6: **Dock UI (`AgentDock.swift`).**
  - The status pill shows "Interrupted · conversation held" when idle and held.
  - The idle header shows a prominent **Close conversation** button (calls `closeConversation()`), replacing New conversation while held.
  - The composer shows **Continue** (re-launches the interrupted mode with resume, through its existing modal or confirmation) plus Elaborate / Execute / Review / Complete chips, gated by the same `PlanDetailView` predicates.
  - Make the composer layout a pure static (e.g. `composerAffordances(hold:status:)`) with tests in `AgentDockTests.swift`.
  - No measured sizes (#096).
- [ ] 👁 Step 7: **Manual check in the app.**
  - Start an execute, Stop it mid-run, ask a question in the dock, then Continue. Confirm the agent remembers both the run and the discussion, and that no stray `claude` process remains after Stop (`ps`).
  - Click Close conversation, then fire off a plain Elaborate on another plan with no interaction. Confirm it starts clean.
- [ ] Step 8: Capture the Phase 2 follow-up as its own task: a persistent streaming-input runner with `query.interrupt()`, typing while working, and `AskUserQuestion` in held sessions. Then update `CLAUDE.md`'s agent dock note to describe the hold.

## Verification
- `swift test` passes, including:
  - the new pure hold-transition tests (stop sets, kept review never sets, clean finish from the hold clears, discuss keeps, failure keeps);
  - argument tests: `--resume` for any mode when provided, and no-hold arguments byte-identical to today for every mode;
  - launcher-seam tests that a held execute resumes the held id while a kept review starts fresh;
  - dock composer-affordance tests.
- `npm test` in `Tools/work-task` passes: every mode accepts `--resume`, resumed execute/elaborate prompts carry the continuation lead, and review/complete stay bare commands.
- Manual: Stop an execute, discuss, Continue → the agent has the context; no orphaned `claude` process after Stop. Close conversation, then a fire-and-forget Elaborate → clean context, no interaction needed.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/PlanAgent.swift` — `SessionHold`, `nextHold`, `closeConversation()`
- [ ] `Sources/Plans/TaskRunner.swift` — `wasStopped`, `--resume` for all modes, held-session threading in `run`/`review`/`complete`/`launchDiscuss`
- [ ] `Sources/Plans/DiscussionThread.swift` — generalised fresh-turn context framing
- [ ] `Sources/Plans/AgentDock.swift` — held pill, Close conversation, Continue and skill chips
- [ ] `Tools/work-task/run-task.ts` — `parseArgs` resume guard, resumed-prompt lead, SIGTERM handler (rebuild `dist/run-task.js`)
- [ ] `Tests/PlansTests/PlanAgentTests.swift`, `Tests/PlansTests/TaskRunnerTests.swift`, `Tests/PlansTests/AgentDockTests.swift`, `Tools/work-task/run-task.modes.test.ts` — tests

### Related Files (may need updates)
- `Sources/Plans/PlanDetailView.swift` — action gating predicates reused by the composer chips; modal triggers for Continue
- `Sources/Plans/ExecuteModal.swift`, `ElaborateModal.swift`, `ReviewModal.swift` — may need to pass the held resume through to the runner
- `CLAUDE.md` — agent dock convention note

### Endpoints/UI Affected
- Agent dock header/pill/composer — new held state, Close conversation, Continue and skill chips
- Plan action buttons — resume the held session when the plan is held; unchanged otherwise

## Assumptions

### Initial (from elaboration)
_To be filled during elaboration_

### Discovered during execution
_To be filled during execution_

## Changes
_To be filled during execution_

## Notes
Decisions from elaboration:
- **Phase 1 only.** Phase 2 (persistent process, `interrupt()`, typing while working) is a follow-up task (Step 8).
- **After a clean finish, keep the #118 read-only follow-up.** Composer questions can still resume the just-finished run's session read-only. Actions always start clean unless the plan is held.
- **Kept review on a held plan:** starts fresh in its own session as today and leaves the hold intact.
- **The hold is in memory only** for Phase 1; nothing is persisted across relaunch. If persistence is added later, use app storage (UserDefaults or Application Support), never `.plans/`: plan files are public, so no session ids or transcript paths go in them.
- **`--apply` stays a per-turn posture.** Held discuss turns remain read-only unless the user chooses apply.
- **Budget:** per-call caps ($40 action / $5 discuss) are unchanged; a held session re-sends history, so watch cost but don't add a per-session cap in Phase 1.

Risks to check during execution:
- Resumability after SIGTERM mid-tool: the transcript is written incrementally, but a `tool_use` may have no `tool_result`. Verify a Stop mid-Bash and mid-subagent resumes cleanly; the SIGTERM → `close()` handler should help.
- Re-sending "Use the plan-execute skill… worktree" inside a resumed session that was mid-execution could start a second worktree pass. `plan-execute` is "start or continue"; confirm it continues the existing worktree.
- Don't reintroduce a parallel resume bridge (#118): the hold and lineage are the only sources of truth, and `dismissCurrentRun()` must not be called on hand-off.
