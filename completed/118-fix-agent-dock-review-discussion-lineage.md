# Fix Agent Dock Review Discussion And Wire Composer To Session Lineage

**ID:** 118
**Created:** 2026-11-11T11:29
**Type:** bug
**Status:** completed
**Completed:** 2026-11-12T16:40
**Branch:** fix/118-fix-agent-dock-review-discussion-lineage

## What
Wire the agent dock composer to session lineage and remove "Discuss with Reviewer".

**Bug:** clicking "Discuss with Reviewer" after a guided review empties the dock, and the chat can't be brought back. `continueReviewInDiscussion` (`TaskRunner.swift:1763`) seeds a summary turn on `DiscussionThread` without mirroring it into `PlanAgent.transcript`, then calls `dismissCurrentRun()`, which deletes the review run segment.

**Root cause:** #117's session lineage (`PlanAgent.lastSession`, `resumeSession(forCwd:)`, `contextForFreshTurn(cwd:)`) is never used in production; only tests call it. `launchDiscuss` resumes `thread.sessionID` instead, so after any run the "Ask about this plan…" composer starts a new session with no context. The button is the only bridge, and it is broken.

**Desired:** each plan has one persistent agent conversation. Refine, execute and review add segments to it, and the composer always continues from the last segment: it resumes the session when the directory matches, else it starts a fresh discuss turn carrying the prior summary as context.

**Fix:**
1. The composer uses `lastSession` lineage.
2. Delete "Discuss with Reviewer" and `continueReviewInDiscussion`; keep Complete….
3. Never drop run segments as a side effect of discussing.
4. Keep one source of truth for the resume session, and fix `completeDiscussTurn` recording cwd as `lastSession?.cwd ?? ""` instead of the directory the turn ran in.
5. Remove the run-summary **"$X · N turns"** cost/turn line from the UI (the only display site is `RunLogContents.summaryRow`). Keep the underlying data on the durable `RunOutcome` log for diagnostics — this is a display-only removal.
6. Tests: `ask` after a finished review resumes its session; a different-cwd run gives a fresh turn with summary context; the run segment survives a discuss turn; the run footer no longer renders a cost/turn line.

## Why
After a guided review the dock becomes unrecoverably empty the moment a user tries to keep talking to the reviewer — the single worst failure mode for the #117 agent dock, which exists to be one persistent conversation per plan. Fixing it also activates the session-lineage machinery #117 already built but never wired up, so every composer turn continues the real prior session instead of silently starting a context-less new one.

## How Summary
Route the dock composer through the existing-but-unused `PlanAgent.lastSession` lineage so one persistent conversation accumulates per plan, and delete the parallel review-specific bridge (`continueReviewInDiscussion` + `DiscussionThread.seedFromReview`/`takeReviewContext` + the "Discuss with Reviewer" button) that empties the dock. `launchDiscuss` stops reading `thread.sessionID`/`thread.takeReviewContext()` and instead asks `agent.resumeSession(forCwd:)` / `agent.contextForFreshTurn(cwd:)` for the project root — resuming when the lineage directory matches, else starting a fresh turn that carries the prior summary as context. To keep the kept-worktree rule intact, `completeRunSegment` records a review's lineage session via `resumableReviewSession(...)` (nil for `.kept`), and `completeDiscussTurn` records the real run cwd rather than `lastSession?.cwd ?? ""`. As a bundled cleanup, drop the run footer's **"$X · N turns"** cost/turn line — its sole display site is `RunLogContents.summaryRow` in `PlanDetailView.swift`; this is a display-only removal that leaves the SDK `done` wire fields, the `TaskRun.summary` tuple, and the durable `RunOutcome.costUsd`/`turns` persistence intact (the latter is kept for post-hoc diagnostics of stranded/budget-capped runs).

**Files of note:**
- `Sources/Plans/TaskRunner.swift` — `launchDiscuss` (resume/context now from lineage), delete `continueReviewInDiscussion`, `completeRunSegment` callsite (`launchRun`, 1593)
- `Sources/Plans/PlanAgent.swift` — `completeRunSegment`/`completeDiscussTurn` lineage recording; `resumeSession(forCwd:)`/`contextForFreshTurn(cwd:)` become production readers
- `Sources/Plans/DiscussionThread.swift` — remove the review-specific `seedFromReview`/`takeReviewContext`/`pendingReviewContext`/`reviewSummary` plumbing (and `isReviewSummary` if unused after)
- `Sources/Plans/AgentDock.swift` — delete the "Discuss with Reviewer" button from `finishedReviewActions`; composer `submit` already calls `runner.ask`, so it rides the fixed lineage path
- `Sources/Plans/PlanDetailView.swift` — delete `summaryRow` (1907-1911) and its `footer` callsite (1786-1788); drop `run?.summary != nil` from `hasFooter` (1766) so a clean run with no denials/error shows no footer
- `Tests/PlansTests/TaskRunnerTests.swift` — replace the `continueReviewInDiscussion` tests with lineage/survival tests
- `Tests/PlansTests/PlanDetailViewTests.swift` — assert the footer no longer renders the cost/turn string on a finished run
- `Tests/PlansTests/PlanAgentTests.swift` / `DiscussionThreadTests.swift` — keep lineage tests; drop `seedFromReview`/`takeReviewContext` tests that reference deleted API

## Diagnosis

**Most likely:** The review summary is seeded onto `DiscussionThread.turns` only, never mirrored into `PlanAgent.transcript`, and then `dismissCurrentRun()` removes the review `.run` segment — so the dock's data source (`agent.transcript`) is left empty and the only bridge back (the button lived on the now-deleted segment) is gone. (`TaskRunner.swift:1768` seeds the thread; `TaskRunner.swift:1775` → `PlanAgent.swift:280` deletes the segment; dock renders `agent.transcript` at `AgentDock.swift:198`)
**Evidence:** `continueReviewInDiscussion` calls `agent.thread.seedFromReview(...)` directly (thread-only append at `DiscussionThread.swift:84`), bypassing `PlanAgent.beginDiscussTurn`/`mirrorLastTurn` (`PlanAgent.swift:164,223`); it then calls `agent.dismissCurrentRun()` which removes the `.run` segment from the transcript (`PlanAgent.swift:282-285`). Existing tests assert only on `thread.turns`/`thread.sessionID` (`TaskRunnerTests.swift:2737-2740`), never on `agent.transcript`, which is why the empty-dock defect escaped.
**Confidence:** high

**Alternative (contributing structural cause, not an either/or):** The lineage bridge (`resumeSession`/`contextForFreshTurn`) has zero production callers (`PlanAgent.swift:248,257`), so `launchDiscuss` derives its resume id from `thread.sessionID` via `beginTurn` (`TaskRunner.swift:2020`, `PlanAgent.swift:168`, `DiscussionThread.swift:60`) and its context from `thread.takeReviewContext()` (`TaskRunner.swift:2025`) — the designed per-directory resume-or-reframe decision is never exercised, and the broken button is the only path that ever carried review context. — **Confidence:** high

**Alternative (latent):** `completeDiscussTurn` records lineage cwd as `lastSession?.cwd ?? ""` (`PlanAgent.swift:192-194`) instead of the directory the turn ran in (contrast `completeRunSegment` using `run.runProjectPath`, `PlanAgent.swift:148`); harmless today because nothing reads lineage for discuss, but corrupts the next resume decision once the composer uses lineage. — **Confidence:** medium

**To confirm:** Add a transcript assertion to the current review-continue path (`XCTAssertFalse(agent.transcript.isEmpty)` after `continueReviewInDiscussion`) and watch it fail today — proving the empty transcript, not a display choice, is the mechanism.

## How
- [x] Step 1: Add a failing test that reproduces the empty-dock mechanism — assert `agent.transcript` is non-empty (and still holds the review `.run` segment) after the review-continue/discuss path. This confirms the Diagnosis before any fix; agent-verifiable (XCTest), so untagged. (`Tests/PlansTests/TaskRunnerTests.swift`)
- [x] Step 2: Wire `launchDiscuss` to lineage: compute `resume = agent.resumeSession(forCwd: projectPath)` and the fresh-turn context from `agent.contextForFreshTurn(cwd: projectPath)`, replacing the `thread.sessionID`-derived `resume` and `thread.takeReviewContext()` context. Frame the outgoing question with `DiscussionThread.question(_:withReviewContext:)` when a context string is present. Do NOT call `dismissCurrentRun()` here — run segments must survive a discuss turn. (`Sources/Plans/TaskRunner.swift:2006`-2050, `Sources/Plans/PlanAgent.swift:248,257`)
- [x] Step 3: Make `completeRunSegment` record a resumable lineage session: for a `.review` run pass `resumableReviewSession(sessionID: run.sessionID, location: run.reviewLocation)` (nil for `.kept`) so a kept review naturally carries summary-as-context instead of resuming a project-root session the CLI can't find; keep `cwd: run.runProjectPath ?? ""` and `summary: run.reply`. (`Sources/Plans/PlanAgent.swift:146-151`, `Sources/Plans/TaskRunner.swift:1782`)
- [x] Step 4: Fix `completeDiscussTurn` to record the directory the turn actually ran in (the project path the discuss run started in) rather than `lastSession?.cwd ?? ""`, so chained discuss turns keep the lineage cwd correct. Thread the run's project path to the completion callback as needed. (`Sources/Plans/PlanAgent.swift:185-196`, `Sources/Plans/TaskRunner.swift:2034-2042`)
- [x] Step 5: Delete the "Discuss with Reviewer" button from `finishedReviewActions` and remove `continueReviewInDiscussion` from `TaskRunner`; keep the Complete… action untouched. Remove the now-dead review-seed plumbing in `DiscussionThread` (`seedFromReview`, `takeReviewContext`, `pendingReviewContext`, `reviewSummary`, and `isReviewSummary`/review-summary rendering in `AgentTurnView` only if no longer referenced). (`Sources/Plans/AgentDock.swift:283-315`, `Sources/Plans/TaskRunner.swift:1763-1776`, `Sources/Plans/DiscussionThread.swift:46-94`)
- [x] Step 6: Replace the deleted-API tests: swap the `continueReviewInDiscussion` tests (`TaskRunnerTests.swift:2711-2783`) and `seedFromReview`/`takeReviewContext` tests (`DiscussionThreadTests.swift:373-420`) for tests asserting (a) `ask` after a finished `.worktree` review resumes its session, (b) a different-cwd (`.kept`) run gives a fresh turn carrying summary context, and (c) the review `.run` segment survives a discuss turn (transcript still holds it). Keep the `PlanAgentTests` lineage tests. (`Tests/PlansTests/TaskRunnerTests.swift`, `Tests/PlansTests/DiscussionThreadTests.swift`, `Tests/PlansTests/PlanAgentTests.swift`)
- [x] Step 7: Remove the run-summary cost/turn line from the UI. Delete `RunLogContents.summaryRow(_:)` (`PlanDetailView.swift:1907-1911`) and its invocation in the `footer` view (`PlanDetailView.swift:1786-1788`), and drop the `run?.summary != nil` disjunct from `hasFooter` (`PlanDetailView.swift:1766`) so a clean run with no denials and no error renders no footer. This is display-only: do NOT touch `RunEvent.done`'s `costUsd`/`turns` wire fields, the `TaskRun.summary` tuple (`TaskRunner.swift:599,1098`), or `writeOutcome`'s `RunOutcome.costUsd`/`turns` persistence (`TaskRunner.swift:1287-1288`) — those stay for the durable diagnostics log. (`Sources/Plans/PlanDetailView.swift`)
- [x] Step 8: Update the footer/summary tests to match. Add/adjust a `PlanDetailViewTests` assertion that a finished run's footer no longer contains the `"$… · N turns"` string, and confirm the footer still appears for denial/error cases. Leave the `TaskRunnerTests`/`RunOutcomeLogTests`/`PlanAgentTests` fixtures that decode `costUsd`/`turns` from the `done` event and persist them to `RunOutcome` unchanged — those assert data flow and persistence, not display. (`Tests/PlansTests/PlanDetailViewTests.swift`)
- [x] Step 9: Run `swift build` and `swift test`; confirm the Step 1 reproduction now passes, the new no-cost/turn-footer assertion passes, and the whole suite is green.

## Verification
- `swift test` passes; the Step 1 reproduction (added to assert `agent.transcript` survives) fails before the fix and passes after.
- A finished `.worktree` review followed by a composer question resumes the review's session (`launched.resume == <review session>`), with the review `.run` segment still present in `agent.transcript`.
- A `.kept` review (different session directory) followed by a composer question starts a fresh turn whose outgoing description carries the review summary as context and whose `resume` is nil; the transcript shows the user's question, not the framed context.
- No "Discuss with Reviewer" button renders on a finished review; `continueReviewInDiscussion`, `seedFromReview`, and `takeReviewContext` no longer exist, and nothing in `Sources/` references them (grep clean).
- No "$X · N turns" cost/turn line renders in any run footer; `summaryRow` no longer exists and nothing in `Sources/` references it (grep clean). A clean run with no denied tools and no error shows no footer at all.
- The durable diagnostics path is untouched: `RunOutcome.costUsd`/`turns` are still written to `run-outcomes.log` (the `RunOutcomeLogTests`/`TaskRunnerTests` persistence assertions remain green), and the SDK `done` event still decodes `costUsd`/`turns`.
- Manually (optional, `👁`): run a real guided review in the app, click into the composer, ask a follow-up — the review log stays visible, the reply continues the reviewer's conversation, and no cost/turn line appears beneath the run.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/TaskRunner.swift` — rewire `launchDiscuss` to lineage; delete `continueReviewInDiscussion`; thread the discuss run's cwd to `completeDiscussTurn`
- [x] `Sources/Plans/PlanAgent.swift` — `completeRunSegment` records a resumable review session; `completeDiscussTurn` records the real run cwd; `resumeSession`/`contextForFreshTurn` gain their first production callers
- [x] `Sources/Plans/DiscussionThread.swift` — remove `seedFromReview`/`takeReviewContext`/`pendingReviewContext`/`reviewSummary` (and `isReviewSummary` if unused)
- [x] `Sources/Plans/AgentDock.swift` — delete the "Discuss with Reviewer" button from `finishedReviewActions`
- [x] `Sources/Plans/PlanDetailView.swift` — delete `summaryRow` + its `footer` callsite; drop `run?.summary != nil` from `hasFooter` (removes the "$X · N turns" line)
- [x] `Tests/PlansTests/TaskRunnerTests.swift` — replace `continueReviewInDiscussion` tests with lineage/survival tests
- [x] `Tests/PlansTests/DiscussionThreadTests.swift` — drop `seedFromReview`/`takeReviewContext` tests
- [x] `Tests/PlansTests/PlanAgentTests.swift` — keep lineage tests; adjust `completeRunSegment` expectations if the review-session recording changes assertions
- [x] `Tests/PlansTests/PlanDetailViewTests.swift` — assert the finished-run footer no longer renders the cost/turn string

### Related Files (may need updates)
- `Sources/Plans/PlanDetailView.swift` — also hosts `finishedReviewRun`/`canComplete`/`canDiscuss` helpers the dock calls; verify none become dead or need adjustment after the button removal (separate from the `summaryRow`/footer edits above)
- `Sources/Plans/AgentDock.swift` (`AgentTurnView`) — review-summary rendering (`isReviewSummary`) only if that field is removed
- `Sources/Plans/TaskRunner.swift` / `Sources/Plans/RunOutcomeLog.swift` — INTENTIONALLY NOT changed for the cost/turn removal: `TaskRun.summary`, `RunEvent.done`'s `costUsd`/`turns`, and `RunOutcome.costUsd`/`turns` persistence stay (display-only removal)

### Endpoints/UI Affected
- Agent dock finished-review actions — "Discuss with Reviewer" button removed; "Complete…" unchanged
- Agent dock composer ("Ask about this plan…") — now continues the real prior session (resume or summary-context), not a context-less new one
- Run footer (`RunLogContents`) — the "$X · N turns" cost/turn summary line is removed; the footer now shows only for denied-tool or error runs

## Assumptions

### Initial (from elaboration)
- [low] Kept-worktree reviews are made non-resumable at the lineage layer by routing a review's `completeRunSegment` session through `resumableReviewSession(...)` (nil for `.kept`), rather than by recording the worktree path as the lineage cwd. **Why:** `runProjectPath` is always the project root (`start(projectPath:)` is called with the root for every run kind), and no existing API hands back the worktree's real path; reusing the already-tested `resumableReviewSession` rule preserves the exact kept-vs-worktree semantics `continueReviewInDiscussion` relied on with the smallest diff. The reporter's "single source of truth for the resume session" is `lastSession`, and this keeps it so.
- [low] After removing the button, a finished review does NOT auto-seed a synthetic "Guided review" summary turn into the transcript. **Why:** the desired model says "the composer always continues from the last segment"; the review `.run` segment stays visible (no longer dismissed) and its session is resumable via `lastSession`, so no synthetic turn is needed — this is why `seedFromReview`/`isReviewSummary` can be deleted rather than kept. The research Open Question flagged this; the desired description resolves it toward the no-synthetic-turn reading.
- [low] `completeDiscussTurn` is fixed to record the discuss run's actual project path (threaded into the finish callback) rather than `lastSession?.cwd ?? ""`. **Why:** fix item #4 names this defect explicitly; recording the directory the turn ran in keeps chained discuss turns' resume decisions correct once lineage is the live source.
- [low] `launchDiscuss` computes resume/context against the project root (`projectPath`), since per-task and project discuss runs both start there. **Why:** `start(projectPath:)` receives the project root; matching lineage against that root is what makes a same-directory resume fire and a kept-worktree review (recorded with a nil session) fall through to summary context.
- [low] This bug task was NOT routed to `des-build` and carries no `**Build:**` field. **Why:** it is agent/runner lifecycle logic in `Sources/Plans/` with no `design-system/` directory in the project and no design-system component work involved.
- [high] (further-elaboration pass) "Remove the turn count and cost" is interpreted as **display-only** removal: delete the `RunLogContents.summaryRow` "$X · N turns" line (its only render site) while keeping the SDK `done` wire fields, the `TaskRun.summary` tuple, and the durable `RunOutcome.costUsd`/`turns` persistence. **Why:** research found exactly one display site (`PlanDetailView.swift:1907-1911`); the same data is separately written to `run-outcomes.log`, whose documented purpose is post-hoc diagnostics of stranded/budget-capped runs (and whose cost field is a diagnostic signal referenced by the project memory note on diagnosing swallowed captures). Deleting the durable fields would be over-removal with no user-visible benefit, so the smallest correct change strips only the UI.
- [low] (further-elaboration pass) Removing `summaryRow` also narrows `hasFooter` so a clean successful run (no denied tools, no error) shows **no footer at all**, rather than an empty footer container. **Why:** the footer's remaining contents are the denial note and error banner, both conditional; dropping the `run?.summary != nil` disjunct is the minimal edit and avoids a stray empty `VStack`. The source description didn't specify footer behaviour for clean runs, so this is a judgement call flagged for review.
- [low] (further-elaboration pass) The cost/turn removal is scoped as a **bundled cleanup** on this existing lineage-fix task rather than split into a separate task, and the `## Diagnosis` (which concerns the lineage/empty-dock root cause) is left unchanged because the removal touches a different, non-defective code path. **Why:** the guidance ("while we're at it") explicitly frames it as a ride-along; both changes live in the agent-dock/run-log surface, so one task keeps the diff coherent.

### Discovered during execution
- [low] In `launchDiscuss`, I keep calling `agent.beginDiscussTurn(...)` (for the gate + transcript mirroring) but IGNORE its returned resume value, computing resume from `agent.resumeSession(forCwd:)` and context from `agent.contextForFreshTurn(cwd:)` instead. **Why:** `beginDiscussTurn` also appends the pending turn to the thread and enters `working(.discuss)`, which must still happen; only the resume/context sources move to lineage. The thread's own `sessionID`/`isResumed` bookkeeping becomes cosmetic for the launched run since lineage now decides resume — acceptable for the smallest diff, and the thread's session is no longer the composer's source of truth.
- [low] Step 1's RED reproduction was first written against the current `continueReviewInDiscussion` path and confirmed to FAIL (transcript emptied, review `.run` stripped by `dismissCurrentRun()`). I then REPLACED it with a permanent transcript-survival test (`testDiscussAfterReviewKeepsReviewSegmentInTranscript`) exercising the production `review → complete → ask` path, so no known-failing transitional test is left in the suite. **Why:** `continueReviewInDiscussion` is deleted in Step 5 (a later segment); a permanent test against the surviving `ask` path is more durable and still proves the fix.
- [high] The two existing tests `testContinueReviewInDiscussionResumesReviewSession` and `testContinueKeptReviewInDiscussionCarriesSummaryAsContext` now FAIL after Step 2, because they drive the OLD thread-seeding path (`continueReviewInDiscussion` → `thread.seedFromReview`) that `launchDiscuss` no longer reads (it reads lineage). **Why:** this is the anticipated consequence of wiring the composer to lineage — these are exactly the "deleted-API tests" the plan's Step 5/6 remove/replace. Left as-is for the next segment rather than edited outside this segment's step scope.
- [high] (Segment 2, Step 4) `completeDiscussTurn` now takes `cwd: String = ""` and records lineage against it (passed `projectPath` from `launchDiscuss`) rather than `lastSession?.cwd ?? ""`. **Why:** chaining `lastSession.cwd` carried over a prior review's worktree directory, so the next composer would resume/reframe against the wrong cwd. A defaulted param keeps the existing `PlanAgentTests` `completeDiscussTurn(error:)` calls (which never assert lineage cwd) compiling and passing unchanged.
- [high] (Segment 2, Step 5) Removed the "Discuss with Reviewer" button from `finishedReviewActions` (keeping Complete…), deleted `TaskRunner.continueReviewInDiscussion`, and deleted the dead review-seed plumbing on `DiscussionThread` (`seedFromReview`, `takeReviewContext`, `pendingReviewContext`, `reviewSummary`, `DiscussionTurn.isReviewSummary`). `resumableReviewSession` and `DiscussionThread.question(_:withReviewContext:)` are kept — both still drive lineage. **Why:** grep confirmed every deleted symbol was referenced only by the removed button/method and the deleted-API tests; `isReviewSummary` had no renderer branch in `AgentTurnView`, so no UI behavior is lost.
- [low] (Segment 2, Step 6) Dropped `testContinueReviewInDiscussionIgnoresLiveOrNonReviewRuns` and the review-seed `DiscussionThreadTests` (incl. `testFailedResumeOfReviewSessionFallsBackToSummaryContext`) without a direct replacement; added `testDiscussAfterKeptReviewStartsFreshTurnCarryingSummaryContext` (case b) and kept Segment 1's survival test (cases a/c) + `testQuestionWithReviewContext`. **Why:** the live/non-review guard and generic failed-resume-clears-session behavior are already covered by the single gate (`testExecuteAndDiscussAreMutuallyExclusivePerPlan`) and `testErrorOnResumedTurnClearsSessionSoNextAskStartsFresh`; the removed fallback tested review-summary carry that no longer exists.
- [high] (Segment 3, Step 7) Promoted the former private `hasFooter` logic to a pure static `RunLogContents.shouldShowFooter(hasFailureMessage:hasDeniedTools:)` and had the instance `hasFooter` delegate to it, mirroring the existing testable `shouldShowFailureBanner`/`scrollTarget` statics. **Why:** `footer`/`hasFooter` are `private` instance members of the `RunLogContents` view and can't be asserted from XCTest; a pure static gives a direct, construction-free testable surface proving the cost/turn summary no longer forces a footer, following the file's established pattern rather than exposing the view internals.
- [low] (Segment 3, Step 7) Also updated the now-stale `footer` doc comment ("Denial note + summary" → "Denial note") since the summary row it described is gone. **Why:** display-only cleanup; the comment would otherwise misdescribe the view. No behavior change.
- [high] (Segment 3, Step 8) Asserted the no-cost/turn-footer behavior via `shouldShowFooter` (clean finished run with `summary != nil`, no denials, no error ⇒ no footer) plus a denial/failure matrix, and a denial-rides-alongside-clean-finish case proving the denial (not the summary) drives the footer. Left all `TaskRunner`/`RunOutcomeLog`/`PlanAgent` `costUsd`/`turns` decode+persist fixtures untouched. **Why:** Step 8 asks to prove the display removal without weakening the durable-diagnostics data-flow assertions; `run.summary` is still asserted non-nil in the new tests to show the figures remain captured even though they no longer render.

## Changes

### Segment 1 (steps 1-3)
- `Tests/PlansTests/TaskRunnerTests.swift`: confirmed RED reproduction against the current `continueReviewInDiscussion` path (transcript emptied + review `.run` segment stripped), then replaced it with permanent survival test `testDiscussAfterReviewKeepsReviewSegmentInTranscript` (asserts transcript keeps the review segment and the composer resumes the review session in the same dir).
- `Sources/Plans/TaskRunner.swift`: `launchDiscuss` rewired to lineage — resume from `agent.resumeSession(forCwd: projectPath)`, context from `agent.contextForFreshTurn(cwd: projectPath)`, outgoing question framed via `DiscussionThread.question(_:withReviewContext:)`; no `dismissCurrentRun()` so run segments survive a discuss turn.
- `Sources/Plans/PlanAgent.swift`: `completeRunSegment` records a resumable lineage session, routing `.review` runs through `resumableReviewSession(sessionID:location:)` (nil for `.kept`), keeping `cwd: run.runProjectPath ?? ""` and `summary: run.reply`.
- Build clean. Two old thread-seeding tests now fail as expected (deleted/replaced in Steps 5-6).

### Segment 2 (steps 4-6)
- `Sources/Plans/PlanAgent.swift`: `completeDiscussTurn` gains a `cwd: String = ""` param and records lineage against the directory the turn actually ran in, instead of `lastSession?.cwd ?? ""`.
- `Sources/Plans/TaskRunner.swift`: `launchDiscuss` passes `projectPath` into the `onFinish` completion; removed `continueReviewInDiscussion`.
- `Sources/Plans/AgentDock.swift`: deleted the "Discuss with Reviewer" button from `finishedReviewActions` (Complete… untouched).
- `Sources/Plans/DiscussionThread.swift`: removed dead review-seed plumbing — `seedFromReview`, `takeReviewContext`, `pendingReviewContext`, `reviewSummary`, `DiscussionTurn.isReviewSummary` (confirmed unreferenced), and their refs in `reset()`/`setError()`. Kept `question(_:withReviewContext:)` and `resumableReviewSession` (drive lineage).
- `Tests/PlansTests/TaskRunnerTests.swift`: removed the three `testContinueReviewInDiscussion*` tests + `finishedReviewRun` helper.
- `Tests/PlansTests/DiscussionThreadTests.swift`: removed the "Seeding from a finished review" block.
- Added case (b) `testDiscussAfterKeptReviewStartsFreshTurnCarryingSummaryContext` (fresh turn, `resume == nil`, outgoing description carries summary, transcript shows the user's plain question, review segment survives). Cases (a)/(c) covered by Segment 1's survival test.
- Targeted tests green: DiscussionThreadTests 32, PlanAgentTests 24, TaskRunnerTests 165. Build clean.

### Segment 3 (steps 7-9)
- `Sources/Plans/PlanDetailView.swift`: deleted `RunLogContents.summaryRow(_:)` and its `footer` callsite; dropped the `run?.summary != nil` disjunct from `hasFooter` so a clean run (no denials, no error) renders no footer. Updated the stale `footer` doc comment. Promoted the footer predicate to a pure static `RunLogContents.shouldShowFooter(hasFailureMessage:hasDeniedTools:)` (mirrors the file's existing `shouldShowFailureBanner`/`scrollTarget` pattern) so it is testable from XCTest. Display-only: `RunEvent.done` `costUsd`/`turns`, the `TaskRun.summary` tuple, and `RunOutcome.costUsd`/`turns` persistence all untouched.
- `Tests/PlansTests/PlanDetailViewTests.swift`: added `testCleanFinishedRunRendersNoFooter`, `testFooterStillShownForDenialAndFailure`, `testDeniedToolDrivesFooterNotSummary`.
- Step 9 verification — `swift build` clean; targeted filters all green: PlanDetailViewTests 91, TaskRunnerTests 165, DiscussionThreadTests 32, PlanAgentTests 24, RunOutcomeLogTests 17 (costUsd/turns persistence fixtures unchanged and green). `summaryRow` grep-clean in `Sources/`. No branch/SHA drift.

## Notes
_Additional context_
