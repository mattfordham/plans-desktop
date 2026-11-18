# Persistent Per-Plan Agent With A Single Docked Panel

**ID:** 117
**Created:** 2026-11-10T19:19
**Type:** feature
**Status:** completed
**Branch:** feature/117-persistent-per-plan-agent-dock
**Completed:** 2026-11-11T11:09

## What
Rethink how agents are managed and displayed: each plan has ONE persistent agent ("PlanAgent"), and the panel through which you interact with it is always in the same place and always at the ready.

Problem today: `TaskRunner` keeps two registries — `runs` (execute/elaborate/review/complete/delete/backlog/restore; single-flight per plan key) and `discussions` (`DiscussionThread`, deliberately allowed to run concurrently with runs). Since #114 a discuss `--apply` turn is write-capable, so a discussion can collide with a live execute/elaborate. Agent output for a single plan is also scattered across ~6 surfaces: the top progress drawer (#107), the bottom review/complete question panel, the finished-review panel, the discussion transcript, the row-spinner `RunProgressSheet` popover, the capture-row popover, and the toolbar active-runs popover.

Design:
1. **Model** — one `PlanAgent` per `runKey`, owning a single exclusive gate (state: idle | working(mode) | needsInput(question) | finished(outcome)). Every action — including discuss turns — goes through `agent.start(mode, …)` and is refused while busy (pure, unit-testable gate). It owns one unified transcript of segments (each run / discuss turn appends a segment) and session lineage (last resumable sessionID + cwd), generalising `continueReviewInDiscussion`. `TaskRun` stays the process wrapper beneath it.
2. **UI** — the bottom of `PlanDetailView` becomes an always-present agent dock: header with status pill + Stop / New conversation; body = unified transcript (run logs as collapsible segments, discuss turns inline); footer = composer when idle (resume the last session if same cwd, else a fresh plan-discuss with the prior segment's summary as context), disabled "Agent is executing — Stop to interrupt" while working (autonomous modes have no stdin), the question card when needsInput (existing review/complete behaviour). Header actions (Elaborate / Execute / Review / Refine / Complete) are disabled while busy, with a tooltip naming the activity. Remove the top progress drawer; keep the #105 step-count progress panel.
3. Row spinner, toolbar active-runs, and capture rows select the plan and focus its dock instead of rendering their own `RunProgressSheet` popovers.
4. **Captures** — capture rows become selectable, opening a "Capturing…" placeholder detail with the same dock; the existing `rekey(to:)` hand-off migrates the agent and its transcript to the real task id.

Decisions to resolve: transcripts in-memory only initially (recommended) vs persisted; project-level discussion (#110) remains a separate project agent — whether its `--apply` turns should be gated while any plan agent in the project is applying. Cross-plan main-checkout contention is out of scope.

## Why
A plan should have exactly one agent working on it at a time, and you should always find it in the same place. Today a discussion runs outside the run registry, so since #114 an `--apply` discuss turn can write to a plan while an execute or elaborate run is also writing to it. Agent output for one plan is also spread across about six surfaces. Putting one gated agent per plan behind one dock prevents these collisions. It also makes the agent's state (working, waiting for an answer, idle and ready to talk) obvious from a single surface.

## How Summary
Add a `PlanAgent` (one per `runKey`, owned by the single shared `TaskRunner`). It has three parts:
- **An exclusive gate.** Every launch goes through it, including discuss turns.
- **A unified transcript of segments.** Each segment is a `TaskRun` or a discussion turn.
- **Session lineage.** This generalises `continueReviewInDiscussion`: after a run, the composer resumes that run's session when it ran in the same directory, or else starts a fresh discuss turn with the previous run's summary as context.

`PlanDetailView` gets a permanent `AgentDock` at the bottom that replaces:
- the top progress drawer
- the review panel
- the finished-review panel
- the transcript and composer

Other surfaces stop rendering their own run views:
- Row spinners, the toolbar active-runs indicator and capture rows navigate to the plan and focus its dock instead of opening `RunProgressSheet` popovers.
- Captures become selectable placeholder rows. Their agent and transcript move to the real task ID when the capture reconciles.

Decisions made:
- **Discuss turns count as agent activity everywhere:** quit confirmation, toolbar indicator, row spinner and `isProjectBusy`.
- **A finished run returns the agent to idle.** The finished segment stays in the transcript.
- **"New conversation"** clears both the transcript and the session lineage, and is only enabled while idle.
- **`ParkedQuestionSheet` stays only as a fallback** for a question whose plan row can no longer be resolved.
- **The project-level discussion (#110)** stays separate. Only its `--apply` turns are refused while any plan agent in that project is working.
- **Transcripts are kept in memory only.**

**Files of note:**
- `Sources/Plans/PlanAgent.swift` (new): agent state, gate, transcript segments, session lineage.
- `Sources/Plans/TaskRunner.swift`: `agents` map replaces `runs`/`discussions`; all launches route through the agent; `runLauncherForTesting` seam; capture reconcile migrates agents.
- `Sources/Plans/DiscussionThread.swift`: turn model and event folding, reused or absorbed by `PlanAgent`.
- `Sources/Plans/PlanDetailView.swift`: the new `AgentDock`; drawer, review panel and finished-review panel removed; header and overflow actions disabled while busy; "Capturing…" placeholder detail.
- `Sources/Plans/BrowserWindow.swift`: capture-aware `validSelection` and selection remap; `ActiveRunsIndicator` focuses the dock; `ParkedQuestionSheet` as fallback only.
- `Sources/Plans/PlanRowActions.swift` / `Sources/Plans/CaptureProgressRows.swift`: popovers replaced by "open detail and focus dock"; capture rows selectable.
- `Sources/Plans/PlansApp.swift`: `isProjectBusy`, quit guard and `onDidReload` reconcile wired to agents.

## How
- [x] Step 1: **Pure `PlanAgent` model.** Write `Tests/PlansTests/PlanAgentTests.swift` first, then add `Sources/Plans/PlanAgent.swift` (`@Observable`).
  - `AgentState`: `idle | working(RunMode) | needsInput`. A run that finishes returns to `idle` and its segment stays in the transcript.
  - Pure `canStart(state:)` and `busyReason(state:)`, the latter built from `RunMode.activityVerb` and used for tooltip copy.
  - Transcript `[AgentSegment]` (`.run(TaskRun)` / `.turn(DiscussionTurn)`). Move `DiscussionThread`'s turn logic (`beginTurn` / `apply(event)` / `completeTurn` / `cancelPendingTurn` / review-context framing) in, or have the agent own a `DiscussionThread`.
  - Lineage: `lastSession (id, cwd)` generalising `resumableReviewSession`. The composer resumes when same cwd; otherwise it starts a fresh discuss turn with the prior segment's `reply` as context via `DiscussionThread.question(_:withReviewContext:)`.
  - `reset()` ("New conversation") clears the transcript and lineage, idle only.
  - Port `DiscussionThreadTests` 12-184. Test the gate matrix: execute refuses discuss/apply and vice versa; review/complete `needsInput` refuses everything.
- [x] Step 2: **Route `TaskRunner` through agents** (`Sources/Plans/TaskRunner.swift`).
  - Replace `runs` + `discussions` with `agents: [String: PlanAgent]` keyed by `runKey`, keeping thin derived accessors (`run(for:in:)`, `isRunning`, `runningSnapshots`, `runningRunCount`, `hasRunningRun`) so callers migrate gradually.
  - `run` / `review` / `complete` / `ask` / `ask(apply:)` / `continueReviewInDiscussion` all call `agent.start(...)`. Each launch builds a fresh `TaskRun` per segment (`TaskRun.start` resets its state).
  - Discuss turns count in snapshots, quit guard and `hasRunningRun` (so `isProjectBusy` pauses sync).
  - `askProject` with `apply` refuses while any plan agent in the project is working.
  - Keep `stopAllRunning` covering every agent.
  - Add a `runLauncherForTesting` DEBUG seam mirroring `discussLauncherForTesting` so every mode is testable without node. Rewrite the separation tests (`DiscussionThreadTests` 225/276/296) to the new contract.
- [x] Step 3: **Capture continuity.**
  - Extend the pure `TaskRunner.reconcile(runs:projects:)` result with a migration decision. A running re-key moves the agent map entry (with its transcript), not just `run.rekey`. A finished capture whose new ID is known (`reportedTaskID` or a single new ID) migrates its agent to the real key instead of being dropped. Errored captures stay pinned until dismissed from the placeholder dock.
  - In `BrowserWindow.swift`, make `BrowserViewModel.validSelection` keep a synthetic `capture:` selection while the runner holds that capture, and remap it to `path/realID` after migration. Pure tests in `BrowserWindowTests`.
  - Wire the remap into the selection invariant (BrowserWindow ~137-142).
- [x] Step 4: **`AgentDock` UI** (`Sources/Plans/PlanDetailView.swift`, or a new `AgentDock.swift` if it gets large). An always-present bottom panel:
  - **Header:** status pill (Idle / `activityVerb`… / Needs your answer) plus Stop / New conversation.
  - **Transcript:** run segments as collapsible `RunLogContents` (edge-to-edge), turns via the existing `discussionTurnView`, and finished-review follow-ups (Complete…) on the finished segment.
  - **Footer** chosen by a pure `dockFooterMode(state:canDiscuss:)`: the composer when idle, a disabled "Agent is <verb> — Stop to interrupt" while working, `ParkedQuestionForm` when `needsInput`.
  - Delete `progressDrawer`, `expandedRunLog`, `showProgress`, `reviewPanel`, `finishedReviewPanel` and their predicates and tests. Keep `progressPanel` (#105), and keep `deniedToolsSection` reading the agent's latest run.
  - No measured sizes (#096): reuse the `maxHeight: .infinity` split and the `ViewThatFits` question-card layout.
- [x] Step 5: **Gate every action.**
  - In `PlanDetailView`, change `detailHeader`'s running swap to disabled buttons with `.help(busyReason)`. Also gate `housekeepingActions` (Backlog / Restore / Delete), which today stays enabled while a run is in flight.
  - Mirror this in `Sources/Plans/PlanRowActions.swift` (and pass real `hasLiveRun` to Complete).
  - Pure predicate tests in `PlanDetailViewTests`.
- [x] Step 6: **One place to look.**
  - Thread `onOpenDetail` plus a dock-focus request token into `PlanRowActions` and `CaptureProgressRows` (via `ProjectCard` / `TaskListView`). Replace both `RunProgressSheet` popovers with "select plan and focus dock".
  - Make capture rows selectable (`OpenDetailOnTap`, selection background). A synthetic capture `rowID` renders a "Capturing…" placeholder header plus the same dock, which also hosts Dismiss for an errored capture.
  - `ActiveRunsIndicator.onOpen` always selects the plan or capture and focuses the dock. It falls back to `ParkedQuestionSheet` only when the needs-input agent's row can't be resolved (complete-archives-first case).
  - Delete `RunProgressSheet`, moving `scrollTarget` / `shouldShowFailureBanner` onto `RunLogContents`. Update `activeRunItems` tests for capture IDs.
- [ ] 👁 Step 7: **Full suite and manual walk-through.** _(⏳ deferred to /plan-review — worktree mode; prerequisites complete, targeted suites green)_
  - Run `swift test`.
  - `./build.sh`, then on one plan: capture (the placeholder dock shows progress and follows the rekey into the real plan), elaborate, execute, review (question card in the dock), then discuss via the idle composer.
  - Confirm a second launch, discuss or overflow action is refused with a tooltip while the agent is busy.
  - Confirm the row spinner and toolbar indicator jump to the dock.
  - Confirm no layout hangs when resizing.

## Verification
- `swift test` is green, with new and updated coverage for:
  - the `PlanAgent` gate matrix (including discuss/apply versus runs, both directions)
  - transcript segment append, reset and lineage (resume when same cwd versus context framing)
  - agent migration on capture rekey and finish
  - capture-aware selection keep and remap
  - dock footer mode and header gating predicates
  - project `--apply` gating
  - discuss turns counted in snapshots, quit guard and `hasRunningRun`
- Manual: a capture → elaborate → execute → review → discuss sequence on one plan shows a single dock throughout, with one continuous transcript. While the agent is working, every other launch (header, row, overflow, composer) is disabled with a reason. Row spinners and the toolbar indicator navigate to the dock rather than opening popovers. Resizing the window and dock causes no layout loop (#096).

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/PlanAgent.swift` (new): agent state, gate, transcript, lineage
- [x] `Sources/Plans/TaskRunner.swift`: agents map, routing, test seam, reconcile migration, project apply gate
- [ ] `Sources/Plans/DiscussionThread.swift`: absorbed into or owned by `PlanAgent`
- [x] `Sources/Plans/PlanDetailView.swift`: `AgentDock` (extracted to new `AgentDock.swift`); drawer, review panel and `RunProgressSheet` removal; header and overflow gating; capture placeholder
- [x] `Sources/Plans/BrowserWindow.swift`: capture-aware selection (seg 1), active-runs navigation + `ParkedQuestionSheet` fallback + `RunProgressSheet` deletion (seg 2)
- [x] `Sources/Plans/PlanRowActions.swift`: popover replaced by navigation; busy gating; real `hasLiveRun` to Complete
- [x] `Sources/Plans/CaptureProgressRows.swift`: selectable rows, popover removed
- [x] `Sources/Plans/ProjectCard.swift` / `Sources/Plans/TaskListView.swift`: thread `onOpenDetail` to rows
- [x] `Sources/Plans/PlansApp.swift`: `isProjectBusy`, quit guard and reconcile wiring — satisfied by seg-1 agent-aware `hasRunningRun`/`runningRunCount`/reconcile (no file edit needed)
- [x] `Sources/Plans/ProjectDiscussionView.swift`: apply refused while plan agents are busy — satisfied by seg-1 `askProject(apply:)` gate (no file edit needed)

### Related Files (may need updates)
- `Sources/Plans/ParkedQuestionForm.swift`: reused in the dock footer
- `Sources/Plans/ProjectStackView.swift`: passes selection and `onOpenDetail` through
- `Tests/PlansTests/TaskRunnerTests.swift`, `DiscussionThreadTests.swift`, `PlanDetailViewTests.swift`, `BrowserWindowTests.swift`: rewritten contracts
- `CLAUDE.md`: update the "Selection-driven detail column" note to describe the agent dock

### Endpoints/UI Affected
- Plan detail column: the bottom dock replaces the top drawer, review panels and composer
- Row spinner, capture rows, toolbar active-runs: navigate to the dock instead of popovers
- Detail header, overflow menu and row action glyphs: disabled while the plan's agent is busy

## Assumptions

### Initial (from elaboration)
_To be filled during elaboration_

### Discovered during execution
- [high] `PlanAgent` OWNS a `DiscussionThread` instance rather than absorbing its turn reducer. **Why:** the thread's begin/apply/complete/cancel/review-context logic is large and already fully tested; owning it keeps the diff minimal and the gate testable, and lets `TaskRunner`'s existing `discussion(...)`/`thread(...)` accessors keep working by returning `agent.thread`. The agent mirrors the thread's live turn into `.turn` transcript segments so the dock renders one list.
- [high] `TaskRunner.runs` and `.discussions` are now DERIVED (read-only) computed properties over the single `agents` map (`runs` = each agent's `currentRun`; `discussions` = each agent's `thread`). **Why:** ~15 source files and several test files read `runner.runs[key]` / `runner.discussion(...)` / `runner.discussions.isEmpty`; keeping these as thin derived accessors lets every existing caller compile unchanged (the segment brief's "keep thin derived accessors" directive) while `agents` is the real registry.
- [high] A discuss turn's `TaskRun` is held on `agent.thread.activeRun` (never in `currentRun`/`runs`), so it still is NOT a task run for `run(for:in:)` / `isRunning(taskID:in:)`. But running counts/snapshots/`hasRunningRun` now iterate a new `liveRuns` helper that includes BOTH the agent's `currentRun` and its live discuss turn, so a discuss turn counts as agent activity (quit guard, toolbar, `isProjectBusy`) per the #117 decision. **Why:** the brief requires discuss turns to count in snapshots/quit-guard/`hasRunningRun` while the row-spinner `isRunning` lookups stay run-only.
- [high] Reconcile result gained a `toMigrate: [synthetic: realID]` field. A FINISHED capture whose real id is known (reportedTaskID, else a single new id) now MIGRATES its agent (with transcript) to the real key instead of landing in `toDismiss`. Ambiguous (several new ids, no reported id) still dismisses; errored/no-new-id unchanged. **Why:** the brief's capture-continuity requirement ("migrates its agent to the real key instead of being dropped"). The old `taskIDsToDismiss` new-id-finished-capture tests were rewritten to assert migration.
- [low] `dismiss(taskID:)` removes the WHOLE agent for a synthetic capture key (once its run is finished) but only drops the current run segment for a real plan (keeping its transcript/discussion). **Why:** a dismissed capture placeholder has no conversation worth keeping, whereas a real plan's agent must survive a run-log dismissal so its discussion persists. This is a judgement call about capture-vs-plan dismissal semantics.
- [low] `askProject` gained an `apply:` parameter (default false) plus an `anyPlanAgentWorking(inProject:)` gate that refuses an `--apply` project turn while any PLAN agent (non-empty task id) in the project is busy; read-only project turns are never gated. **Why:** the brief requires "askProject with apply refuses while any plan agent in the project is working", but no apply path existed on `askProject` yet, so the channel was added to make the contract real and testable without changing the existing read-only call site.
- [low] `captureMigrations: [synthetic: "path/id"]` is an observable map on `TaskRunner`, consumed by the capture-aware `validSelection` overload in `BrowserViewModel`; the selection invariant re-runs on `runner.captureMigrations.count` change. **Why:** the view needs to know a synthetic selection's new real row id at migration time, and keying the remap off a count change fires it on the same reload that surfaces the new row. A richer diff than `.count` was unnecessary since entries are only ever added.
- [low] `AgentSegment.id` for a `.run` segment uses `ObjectIdentifier(run).debugDescription`. **Why:** `TaskRun` has no stable value id; its object identity is stable for the segment's lifetime, which is all the dock's `ForEach` needs. Revisit if segments ever need to survive a `TaskRun` replacement.
- [high] (Segment 2) The dock lives in a NEW `Sources/Plans/AgentDock.swift` rather than inside the already-135KB `PlanDetailView.swift`. **Why:** the step allowed either and flagged PlanDetailView's size; a new file keeps the dock self-contained (`AgentDock` + the extracted `AgentTurnView`) and the `dockFooterMode` predicate easy to find/test, while `PlanDetailView` just hosts `AgentDock(row:)` under the plan body.
- [high] (Segment 2) The private `PreparedMarkdownBlockView` nested in `PlanDetailView` was lifted to a top-level `internal struct MarkdownBlockView` (same renderer, `bodyText` stored prop renamed to avoid colliding with `View.body`). **Why:** `AgentTurnView` must render discuss-turn replies as compact markdown through the same renderer; a shared top-level struct avoids a divergent second copy, and `PlanDetailView.markdownBlockView` now delegates to it.
- [high] (Segment 2) `RunProgressSheet` was DELETED and its pure `scrollTarget` / `shouldShowFailureBanner` statics moved onto `RunLogContents`; all popovers that embedded it (`PlanRowActions` spinner, `CaptureProgressRows`) now "select the plan/capture and focus the dock" via a threaded `onOpenDetail`. **Why:** the step requires one place to look; with the sheet gone, its two pure helpers belong on the log view that survives, and the tests were repointed to `RunLogContents`.
- [low] (Segment 2) "Focus the dock" is realised purely by SELECTING the plan/capture row (the dock is always present in the detail column); no separate focus-token/`FocusState` was threaded. **Why:** the dock is unconditionally rendered beneath the plan body, so selecting the row already brings it on screen — a selection write is the minimal, reliable mechanism across the split view, avoiding a cross-column focus channel that can't be unit-tested here. A richer "scroll/focus composer" token can be added later if needed.
- [low] (Segment 2) The ActiveRunsIndicator handler now branches on `item.rowID != nil` first (select + focus dock), falling back to `ParkedQuestionSheet` only for a needs-input run with no resolvable row; `activeRunItems` carries a capture's synthetic `capture:` id as its `rowID`. **Why:** the step wants selection to be the default and the sheet a fallback only for the complete-archives-first case; the pure `activeRunRowAction` helper is retained (still unit-tested) but no longer drives the handler.
- [low] (Segment 2) `PlansApp` (`isProjectBusy` / quit guard / reconcile wiring) and `ProjectDiscussionView` (apply-refusal) needed NO Segment-2 edits. **Why:** Segment 1 already made `hasRunningRun`/`runningRunCount` agent-aware and added `anyPlanAgentWorking`-gated `askProject(apply:)` + reconcile migrations; the UI reads those unchanged, so the listed-but-already-satisfied files were left untouched (noted here rather than as deviations).

## Changes

### Segment 1 (Steps 1–3): PlanAgent model, TaskRunner routing, capture continuity
- **`Sources/Plans/PlanAgent.swift` (new):** `@Observable` `PlanAgent` with `AgentState` (`idle | working(RunMode) | needsInput`), pure `canStart(state:)` / `busyReason(state:)` from `RunMode.activityVerb`, a unified `[AgentSegment]` transcript (`.run(TaskRun)` / `.turn(DiscussionTurn)`), session lineage (`lastSession` id/cwd/summary with `resumeSession(forCwd:)` / `contextForFreshTurn(cwd:)`), and idle-only `reset()`. Owns a `DiscussionThread` and mirrors its live turn into transcript segments.
- **`Sources/Plans/TaskRunner.swift`:** replaced `runs`/`discussions` stored registries with `agents: [String: PlanAgent]` keyed by `runKey`; `runs`/`discussions` are now derived read-only accessors so all existing callers compile unchanged. Every launch (`run`/`review`/`complete`/`capture`/`ask`/`askProject`/`continueReviewInDiscussion`/`stopAllRunning`/`dismiss`) routes through agents. Added `runLauncherForTesting` DEBUG seam. Discuss turns now count in `runningRunCount`/`runningSnapshots`/`hasRunningRun` via a new `liveRuns` helper. `askProject` gained an `apply:` channel gated by `anyPlanAgentWorking(inProject:)`. Reconcile result extended with `toMigrate`; finished captures with a known real id migrate their agent (with transcript) to the real key; `captureMigrations` observable map exposes the remap.
- **`Sources/Plans/BrowserWindow.swift`:** capture-aware `BrowserViewModel.validSelection(...)` keeps a synthetic `capture:` selection while the runner holds it and remaps to `path/realID` after migration; wired into the selection invariant via `revalidateSelection()` (re-runs on row change and on `runner.captureMigrations.count`).
- **Tests:** new `PlanAgentTests.swift` (24, incl. the ported turn-model cases + full gate matrix); updated `TaskRunnerTests.swift` (166), `DiscussionThreadTests.swift` (37), `BrowserWindowTests.swift` (143). All green; `swift build` + `swift build --build-tests` clean.

### Segment 2 (Steps 4–6): AgentDock UI, action gating, one place to look
- **`Sources/Plans/AgentDock.swift` (new):** always-present bottom panel driven by the plan's `PlanAgent` — header (status pill Idle / `activityVerb`… / Needs your answer + Stop / New conversation), unified transcript (run segments as collapsible `RunLogContents`, discuss turns via extracted `AgentTurnView`, finished-review Discuss/Complete… follow-ups), footer chosen by the pure `AgentDock.dockFooterMode(state:canDiscuss:)` (composer when idle, disabled "Agent is <verb> — Stop to interrupt" while working, `ParkedQuestionForm` when `needsInput`). No measured sizes (#096) — reuses `maxHeight: .infinity` + `ViewThatFits`.
- **`Sources/Plans/PlanDetailView.swift`:** deleted `progressDrawer`, `expandedRunLog`, `showProgress`, `reviewPanel`, `finishedReviewPanel`, `conversationTranscript`, `discussionTurnView`, `discussFooter` and dead predicates + their tests; kept `progressPanel` (#105) and `deniedToolsSection` (reads the agent's current run). `detailHeader` lifecycle buttons stay visible but `.disabled(agentBusy)` with `.help(agentBusyReason)`; housekeeping overflow (Backlog/Restore/Delete) gated the same way. Lifted `PreparedMarkdownBlockView` to top-level `MarkdownBlockView` so dock turns reuse one renderer.
- **`Sources/Plans/BrowserWindow.swift`:** `ActiveRunsIndicator.onOpen` selects the plan/capture (focus dock), falls back to `ParkedQuestionSheet` only when a needs-input run has no resolvable row; `activeRunItems` carries a capture's synthetic id as `rowID`. Deleted `RunProgressSheet`, moving `scrollTarget`/`shouldShowFailureBanner` onto `RunLogContents`.
- **`Sources/Plans/PlanRowActions.swift`:** popover → navigation (`onOpenDetail`); busy gating; passes real `hasLiveRun` to Complete.
- **`Sources/Plans/CaptureProgressRows.swift`:** capture rows selectable (tap → `onOpenDetail(synthetic id)`, selection/hover background); synthetic `capture:` rowID renders a "Capturing…" placeholder + the same dock (hosts Dismiss for errored captures).
- **`Sources/Plans/ProjectCard.swift` / `TaskListView.swift`:** thread `onOpenDetail` to rows.
- **`CLAUDE.md`:** updated the "Selection-driven detail column" note and added an "Agent dock (#117)" note.
- **`PlansApp.swift` / `ProjectDiscussionView.swift`:** no edit needed — seg-1's agent-aware `hasRunningRun`/`runningRunCount`/reconcile and `askProject(apply:)` gate already satisfied their requirements.
- **Tests:** `PlanDetailViewTests.swift` (83/83, incl. new `dockFooterMode` cases), `BrowserWindowTests.swift` (143/143 incl. capture `activeRunItems`), `TaskRunnerTests.swift` (166/166), `PlanAgentTests.swift` (24/24). `swift build` + `swift build --build-tests` clean.

### Verification (targeted, re-run by orchestrator before finishing)
- `swift build`: clean.
- `swift test --filter`: PlanAgentTests 24/24, PlanDetailViewTests 83/83, TaskRunnerTests 166/166, BrowserWindowTests 143/143, DiscussionThreadTests 37/37 — all green.
- Step 7 (👁 full `swift test` + `./build.sh` + manual UI walkthrough): deferred to `/plan-review` (worktree mode). No later step depends on it.

## Notes
_Additional context_
