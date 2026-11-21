# Interrupt-and-discuss: keep an interrupted run's session alive so the user can talk to the agent and then continue or switch skills in the same context

**ID:** 128
**Created:** 2026-11-21T08:30
**Type:** feature
**Status:** completed
**Completed:** 2026-11-21T09:40
**Branch:** feature/128-interrupt-and-discuss-keep-an-interrupted

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
- [x] Step 1: **Record why a run ended.** Add `TaskRun.wasStopped` (set in `stop()` before `finish`, `TaskRunner.swift:789`). Also record whether the run was parked on a question when it ended. Tests first: a stopped run reports stopped; a natural finish and an errored finish do not (extend near `testStopFinishesOnceEvenWhenExitAndEOFFollow`).
- [x] Step 2: **Hold state in `PlanAgent`.** Add `hold: SessionHold?` (session id, cwd, interrupted mode, summary) and a pure `static func nextHold(current:endedRun:projectRoot:) -> SessionHold?`.
  - Set the hold when the run was stopped or abandoned while parked, it has a session id, and its cwd is the project root. A kept review never sets it.
  - Clear it when an action launched *from* the hold finishes cleanly.
  - Keep it when a run fails or is stopped again, and across discuss turns.
  - A clean run started without a hold leaves it nil.
  - Add `closeConversation()`, a full idle-only reset of transcript, thread, lineage and hold, built on `reset()`.
  - Leave #118 `lastSession` lineage as-is, so composer questions after a clean finish still resume read-only.
  - TDD in `PlanAgentTests.swift`.
- [x] Step 3: **Runner accepts `--resume` in every mode.**
  - In `run-task.ts`, remove the discuss-only guard in `parseArgs` (~281). This flips the "complete mode rejects --resume" test into "accepts --resume".
  - In `buildPrompt`, when `args.resume` is set for execute/elaborate/reElaborate*, prefix a one-line "You are continuing the conversation above — now run:" lead before the existing builder output. Review and complete stay *bare* slash commands, with any extra framing in `systemPrompt`.
  - Add a `process.on("SIGTERM")` handler that closes the active query (`response.close()`), then exits, so the CLI child is not orphaned.
  - Node tests in `run-task.modes.test.ts`, then rebuild `dist/`.
- [x] Step 4: **Swift arguments.** In `TaskRun.arguments`, emit `--resume` for any mode when a non-empty resume is given (still last in argv). Thread a `resume:` parameter, defaulting to nil, through `TaskRunner.run`, `review` and `complete`.
  - Each uses `agent.hold` only when `hold.cwd == projectPath`. A kept review starts fresh and leaves the hold intact.
  - Capture modes never resume.
  - Tests: flip `testArgumentsIgnoreResumeForNonDiscussModes` to "emits resume for any mode when provided". Add a test that no-hold arguments are byte-identical to today for every mode. Add a launcher-seam test that a held plan's execute passes the held id and a kept review does not.
- [x] Step 5: **Composer and discuss in a held plan.** `launchDiscuss` resumes `hold.id` when held (preferring it over `lastSession`). The fresh-turn context framing generalises `DiscussionThread.question(_:withReviewContext:)` copy from "guided review" to "the interrupted <mode> run".
- [x] Step 6: **Dock UI (`AgentDock.swift`).**
  - The status pill shows "Interrupted · conversation held" when idle and held.
  - The idle header shows a prominent **Close conversation** button (calls `closeConversation()`), replacing New conversation while held.
  - The composer shows **Continue** (re-launches the interrupted mode with resume, through its existing modal or confirmation) plus Elaborate / Execute / Review / Complete chips, gated by the same `PlanDetailView` predicates.
  - Make the composer layout a pure static (e.g. `composerAffordances(hold:status:)`) with tests in `AgentDockTests.swift`.
  - No measured sizes (#096).
- [x] 👁 Step 7: **Manual check in the app.**
  - Start an execute, Stop it mid-run, ask a question in the dock, then Continue. Confirm the agent remembers both the run and the discussion, and that no stray `claude` process remains after Stop (`ps`).
  - Click Close conversation, then fire off a plain Elaborate on another plan with no interaction. Confirm it starts clean.
- [x] Step 8: Capture the Phase 2 follow-up as its own task: a persistent streaming-input runner with `query.interrupt()`, typing while working, and `AskUserQuestion` in held sessions. Then update `CLAUDE.md`'s agent dock note to describe the hold.

## Issues
- [x] Review feedback: keep the input field persistent (also while the agent works). Remove the Stop / Close conversation / New conversation buttons from the dock header. Sending a message while the agent works interrupts it, then discusses in the held session. All conversation buttons (Stop, Close/New conversation, Continue + skill chips) sit directly above the input field.

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
- [high] `TaskRun.endedWhileParked` is snapshotted in `finish` before `pendingQuestion` is cleared, so it covers any end path (stop, exit, error) while parked. **Why:** `finish` already wipes the question; this is the single place both stop and natural ends pass through.
- [low] `nextHold` takes a pure `PlanAgent.EndedRun` value (built from a `TaskRun` via `EndedRun.init(_:)`) rather than the live `TaskRun`. "Launched from the hold" means `run.resume == hold.id`. **Why:** keeps the transition table testable without a process; the resume id is the only reliable link between a launch and the hold.
- [low] Re-stopping a held run re-points the hold at the newest session id and mode; stopped before any `session` event keeps the old hold. **Why:** the next Continue should resume the latest context and re-launch the latest interrupted skill.
- [low] Capture modes (`capture`/`captureElaborate`/`executeYolo`) and discuss never set or clear the hold, and a clean run NOT launched from the hold leaves an existing hold alone. **Why:** captures live on a throwaway synthetic agent; "a clean run started without a hold leaves it nil" generalised to "leaves it unchanged".
- [low] The hold summary is the run's `reply`, falling back to the last streamed `text` chunk. **Why:** a stopped run almost never has a clean reply.
- [low] `reset()` ("New conversation") keeps the hold; only `closeConversation()` clears it. **Why:** the plan says `closeConversation` is built on `reset()` and Close replaces New conversation in the held UI (Step 6).
- [low] `run`/`review`/`complete` take `resume: String? = nil` as an explicit override; when nil they fall back to `agent.heldResume(forCwd: projectPath)`, so the modals need no changes. A held resume is applied in `run(...)` only for execute / elaborate / reElaborate / reElaborateReview / complete (`TaskRunner.resumesHeldSession`); delete / backlog / restore and capture modes start fresh. A kept review ignores even an explicit resume. **Why:** housekeeping moves are not skill conversations; kept-review sessions can't be found from the root.
- [low] Resumed review/complete get continuation framing appended to their existing `systemPrompt` via a new exported `buildSystemPrompt(args)`; delete/backlog/restore/capture prompts get no lead. The runner's SIGTERM handler calls `response.close()` then exits with 143. **Why:** slash-command prompts must stay bare; 143 is the conventional SIGTERM exit code and Swift's `stop()` has already finished the run.
- [high] `parseArgs` now carries `resume` through every mode's returned `Args` (review/complete/capture included). **Why:** removing the guard alone would have silently dropped it for modes whose return objects omitted the field.
- [low] A discuss turn that resumed the hold and reported a session re-points the hold at that session id (keeping the interrupted mode); failed turns keep the hold unchanged, including a resumed held turn whose session turned out to be gone (the user can Close conversation). **Why:** if the CLI forks a new id on `--resume`, Continue must resume the session that contains the discussion, not the pre-discussion one.
- [low] `LastSession` now records the producing run's `mode` and whether it was `interrupted`, and an interrupted run's lineage summary falls back to its last streamed text. Fresh-turn framing picks "the interrupted <mode> run" / "the <mode> run that just finished" / the original guided-review copy (review, discuss or unknown). `question(_:withReviewContext:)` is kept as a wrapper. **Why:** the hold only exists when a session id was reported; a run stopped before its session arrived still deserves accurate framing.
- [low] Mode nouns in copy come from a new `RunMode.actionName` next to `activityVerb` ("execute", "refine", …). **Why:** run-mode vocabulary already lives there; the CLAUDE.md glyph/label files cover task statuses and types, not run modes.
- [low] Composer chips are shown only while held and idle: Continue (always, whatever the status, since it resumes the interrupted run) plus Elaborate (canElaborate/canReElaborate/canReElaborateReview), Execute (canExecutePending/canWork/canExecuteReview), Review (canReview), Complete (canComplete). The dock emits an `ActionRoute` through an `onAction` closure that `PlanDetailView` maps onto its existing sheet flags / `confirmComplete`; the modals launch through `TaskRunner`, which applies the hold fallback. Continue picks the modal by the interrupted mode's family and the plan's CURRENT status (an interrupted execute on an in-progress plan opens the plain Execute modal). **Why:** no launch logic duplicated; the action bar and chips share one set of predicates and modals.
- [low] Close conversation is a `.borderedProminent` header button through a new `TaskRunner.closeConversation(projectPath:taskID:)` wrapper. Continuing a review via the Review modal lets the user pick `kept`, which starts fresh (existing rule). **Why:** keeps the dock talking to the runner, matching New conversation's `resetDiscussion` path.
- [low] The CLAUDE.md hold note is a new "Held conversation (#128)" bullet directly after the "Agent dock (#117)" bullet, not text folded into it. #129 is filed as `pending` (not elaborated) with only What/Why filled in. **Why:** the #117 bullet is already long, and a separate bullet keeps each one concise. Phase 2 still needs its own elaboration.
- [high] Send-to-interrupt queues the message on the agent (`PlanAgent.queuedSend`) and drains it from `launchRun`'s finish closure right after `completeRunSegment`, so the turn starts only once `nextHold` has held the stopped run's session. `TaskRun.stop()` finishes synchronously, so in practice the turn launches within the same send; the dock also renders a queued message as a pending "Interrupting…" bubble in case a finish ever arrives later. A live discuss turn is cancelled via the existing `cancelDiscussionTurn` (which idles the agent synchronously) and the new turn launches right after in the same thread. **Why:** no sleeping/polling and no parallel resume bridge; the hold/lineage stay the only resume sources.
- [low] `PlanAgent.sendDisposition` refuses when the agent is busy with nothing live to interrupt (inconsistent gate) or a send is already queued; `TaskRunner.send` returns `false` and the composer keeps its text. **Why:** never drop or double-launch a message.
- [low] New conversation shows only when idle, unheld and there is something to clear: a thread turn or recorded lineage (`lastSession`), since `resetDiscussion` clears exactly those. Close / New conversation now use `.bordered` style in the row above the field (Continue stays prominent, Stop is destructive). **Why:** after a reset the button would otherwise linger over kept run logs it doesn't clear.
- [low] A working agent on a plan that can't be discussed (or a capture placeholder) gets a buttons-only footer (`DockFooterMode.buttonsOnly`) holding just Stop; a parked non-discussable plan shows the question form plus Stop. **Why:** the header no longer has Stop, so it must stay reachable without a composer.

## Changes
- **Segment 1 (steps 1–4, commit 920ca5b):**
  - `TaskRun.wasStopped` / `endedWhileParked` record why a run ended (`TaskRunner.swift`).
  - `PlanAgent.hold: SessionHold?` + pure `nextHold(current:endedRun:projectRoot:)`, `heldResume(forCwd:)`, `closeConversation()`; the hold is applied on every run end via `completeRunSegment` (`PlanAgent.swift`).
  - `run-task.ts`: `--resume` accepted in every mode; resumed execute/elaborate prompts lead with a continuation line; review/complete stay bare commands with framing in `buildSystemPrompt`; SIGTERM closes the query and exits 143. `dist/` rebuilt.
  - `TaskRun.arguments` emits `--resume` (last) for any mode; `run`/`review`/`complete` take `resume:` and fall back to the hold for execute/elaborate/reElaborate*/review/complete; kept review and capture never resume.
  - Tests: `TaskRunnerTests` (177 pass), `PlanAgentTests` (44 pass), work-task node tests (33 pass).
- **Segment 2 (steps 5–6, commit 69d12c4):**
  - Discuss in a held plan resumes the hold (`PlanAgent.discussResume(forCwd:)`, preferring it over `lastSession`); `holdAfterDiscussTurn` follows a forked session id so Continue keeps the discussion. `LastSession` gained optional `mode` / `interrupted`.
  - `DiscussionThread.question(_:withContext:from:)` frames fresh turns as "the interrupted <mode> run" / "the <mode> run that just finished" / guided review; old API forwards to it. `RunMode.actionName` added.
  - `AgentDock`: pure `composerAffordances`, `route(for:status:)`, `statusPillLabel(state:isHeld:)` ("Interrupted · conversation held"), `idleHeaderAction(isHeld:)` (Close conversation replaces New conversation while held). Continue + Elaborate/Execute/Review/Complete chips above the composer, gated by the action bar's predicates.
  - `PlanDetailView.openDockAction` routes chips to the existing modals / Complete confirmation; `TaskRunner.closeConversation(projectPath:taskID:)`.
  - Tests: AgentDock/PlanAgent/DiscussionThread/TaskRunner 285 pass, PlanDetailViewTests 105 pass; `swift build` clean.
- **Step 7 (manual check):** ✓ confirmed by the user in review (after the persistent-composer fix).
- **Review fix (commit 1a47896):** persistent composer with send-to-interrupt.
  - The dock header now holds only the chevron and status pill.
  - The composer stays available while working or parked; its placeholder reads "Send to interrupt and discuss…". The "Stop to interrupt" band is gone.
  - Sending while busy goes through the pure `PlanAgent.sendDisposition` and `TaskRunner.send`:
    - a live run is stopped, and the queued message launches from its finish path, resuming the new hold;
    - a live discuss turn is cancelled and re-sent.
  - `AgentDock.conversationButtons` puts every conversation button in one row above the field: Stop while busy; Continue, skill chips and Close conversation when held; New conversation otherwise. It replaces `composerAffordances` and `idleHeaderAction`.
  - `CLAUDE.md` dock notes updated.
  - Tests: 407 pass across AgentDock, PlanAgent, TaskRunner, DiscussionThread and PlanDetailView.
- **Segment 3 (step 8, commit 4d75c62):** Captured Phase 2 as #129 (persistent streaming-input runner, `query.interrupt()`, typing while working, `AskUserQuestion` in held sessions). Added a "Held conversation (#128)" bullet to `CLAUDE.md` after the agent dock note.

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
