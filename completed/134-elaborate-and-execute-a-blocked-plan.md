# Allow Elaborate (and Execute) on a Blocked Plan

**ID:** 134
**Created:** 2026-11-24T19:31
**Type:** feature
**Status:** completed
**Completed:** 2026-11-25T09:21
**Branch:** feature/134-elaborate-and-execute-a-blocked-plan

## What
I think that even if a plan is blocked, I should be able to elaborate it and possibly even execute it.

## Why
Being blocked means a plan's dependencies aren't complete yet — but it says nothing about whether the plan is *ready to be shaped or worked on*. Today a blocked plan hides every lifecycle action (Elaborate, Execute, Discuss), so you can't flesh out or make progress on a plan while it waits on its blocker, forcing busywork (clear the `**Blocked by:**` field, act, re-add it). This mirrors the existing precedent where `canBacklog`/`canDelete` deliberately ignore `isBlocked` — relaxing the work gates the same way lets you prepare and advance blocked work without defeating the blocked signal.

## How Summary
`blocked` is a derived overlay (`Task.isBlocked`, resolved in `TaskParser.resolveBlocked` from the `**Blocked by:**` header against the completed set) — NOT a `TaskStatus` case. Action availability lives entirely in the pure `can*` predicates on `PlanDetailView`, each of which currently carries a `guard !isBlocked else { return false }` line. The change removes that guard from the Elaborate, Execute, and Discuss families (keeping the `isBlocked:` parameter in each signature so call sites and the two cross-cutting guards stay intact), leaving `canReview`/`canComplete` gated. `AgentDock` needs no change — it delegates to these predicates, so the chips light up automatically.

**Files of note:**
- `Sources/Plans/PlanDetailView.swift` — hosts every `can*` gating predicate; this is the only source file that changes.
- `Tests/PlansTests/PlanDetailViewTests.swift` — the `isBlocked`-gating tests to invert, plus new positive tests for the relaxed predicates.
- `Sources/Plans/AgentDock.swift` — consumes the predicates (`conversationButtons`); referenced only to confirm no change is needed.
- `Sources/Plans/TaskParser.swift` — defines `TaskStatus` (no `.blocked` case) and resolves `isBlocked`; referenced to confirm the model is untouched.

## How
- [x] Step 1: Invert/extend the blocked-gating unit tests in `Tests/PlansTests/PlanDetailViewTests.swift` to assert the NEW behavior first (TDD red). Change `testNoReviewActionSurvivesBlockedAtAnyStatus` so `canExecuteReview`/`canReElaborateReview` are now TRUE on the review states when blocked (still FALSE for non-review/`nil` by status). Change `testCanDiscussFalseWhenBlocked` → assert `canDiscuss` is TRUE when blocked. Change `testCanApplyViaDiscussionFalseWhenBlocked` → assert `canApplyViaDiscussion` is TRUE when blocked for its allowed statuses. Add a new `testWorkAndElaborateActionsSurviveBlocked` pinning that `canElaborate` (`pending`), `canWork`/`canExecutePending` (`elaborated`/`pending`), and `canReElaborate` (`elaborated`) are TRUE when `isBlocked: true` and `isBacklogged: false`.
- [x] Step 2: In `Sources/Plans/PlanDetailView.swift`, remove the `guard !isBlocked else { return false }` line from the Elaborate family: `canElaborate` (~1026), `canReElaborate` (~1061), `canReElaborateReview` (~1087). Keep the `isBlocked:` parameter in each signature and keep the `isBacklogged` guard.
- [x] Step 3: In `Sources/Plans/PlanDetailView.swift`, remove the `guard !isBlocked else { return false }` line from the Execute family: `canWork` (~1012), `canExecutePending` (~1046), `canExecuteReview` (~1075). Keep signatures and the `isBacklogged` guard intact.
- [x] Step 4: In `Sources/Plans/PlanDetailView.swift`, remove the `guard !isBlocked else { return false }` line from the Discuss family: `canDiscuss` (~1242) and `canApplyViaDiscussion` (~1309). Keep the `isBlocked:` parameter and the `isBacklogged` guard.
- [x] Step 5: Update the doc comments on each relaxed predicate to explain that `isBlocked` deliberately no longer withholds the action (mirroring the wording already on `canBacklog`/`canDelete`), and note that `canReview`/`canComplete` remain gated on `isBlocked` on purpose (review/merge of a blocked plan stays withheld).
- [x] Step 6: Confirm `Sources/Plans/AgentDock.swift` (`conversationButtons`) and the `PlanDetailView` action bar need no edits — they read the predicates, so relaxing them surfaces the chips/buttons automatically. Leave `TaskParser`/`TaskStatus+Glance` untouched (no new `.blocked` status).
- [x] Step 7: Run `swift build` and `swift test`; confirm the inverted/new blocked tests pass and no previously-green test regresses (especially the `isBacklogged` gates and the still-gated `canReview`/`canComplete` blocked assertions at `testCanReviewFalseWhenGatesFail` and the `canComplete` blocked test).

## Verification
- `swift test` passes, with the updated `testNoReviewActionSurvivesBlockedAtAnyStatus`, `testCanDiscussFalseWhenBlocked` (now asserting TRUE), `testCanApplyViaDiscussionFalseWhenBlocked` (now asserting TRUE), and the new `testWorkAndElaborateActionsSurviveBlocked` all green.
- The still-gated predicates remain correct: `canReview` and `canComplete` still return `false` when `isBlocked: true` (their existing blocked assertions stay green).
- The `isBacklogged` gates are untouched: `testNoWorkActionSurvivesBacklogAtAnyStatus` and `testNoReviewActionSurvivesBacklogAtAnyStatus` still pass (blocked relaxation must not relax backlog).
- `swift build` succeeds with no warnings introduced; no new inline status-vocabulary strings added (vocabulary stays in `TaskStatus+Glance.swift`).
- Manual (optional, 👁): in the running app, select a blocked plan in the browser detail column and confirm the Elaborate / Execute / Discuss actions (and the composer) now appear while the "Blocked" capsule is still shown.

## Impact Scope
_Not applicable — fewer than 3 files affected (PlanDetailView.swift and its test file)._

## Assumptions

### Initial (from elaboration)
- [low] Execute (not just Elaborate) IS relaxed on blocked plans — `canWork`, `canExecutePending`, and `canExecuteReview` drop the blocked guard. **Why:** the description explicitly says "and possibly even execute it"; the user asked for both, so the most useful reading enables the full work path while blocked. Flagged low because "possibly" hedges — if execution-while-blocked proves surprising, Step 3 can be dropped without touching the rest.
- [low] The Discuss family (`canDiscuss`, `canApplyViaDiscussion`) is also relaxed, so the agent-dock composer appears on a blocked plan. **Why:** once a blocked plan can be elaborated/executed, being able to discuss/apply edits to it is the consistent and expected companion; the research flagged this as an open question and the composer is otherwise entirely absent on blocked plans.
- [high] `canReview` and `canComplete` stay gated on `isBlocked`. **Why:** research recommended keeping these withheld — completing merges a branch and is the highest-risk action, and reviewing/merging a plan whose dependencies aren't met is outside the scope of "elaborate and execute." Clear single-option call from the research findings.
- [low] No new confirmation dialog or warning is added when acting on a blocked plan — the action is silently allowed and the existing "Blocked" capsule/banner remains the signal. **Why:** follows the established `canBacklog`/`canDelete` precedent (which silently ignore `isBlocked`) and avoids over-engineering; a confirmation can be added later if the bare relaxation feels too quiet.
- [high] No `.blocked` case is added to `TaskStatus` and `TaskParser`/`TaskStatus+Glance` are untouched — the change is purely removing boolean guards. **Why:** CLAUDE.md and `TaskStatus+Glance.swift` document blocked as a derived overlay, not a status; adding a case would break exhaustive switches and the plans-cc data contract. Unambiguous from the codebase conventions.

### Discovered during execution
- [low] Renamed the inverted tests `testCanDiscussFalseWhenBlocked` → `testCanDiscussTrueWhenBlocked`, `testCanApplyViaDiscussionFalseWhenBlocked` → `testCanApplyViaDiscussionTrueWhenBlocked`, and `testNoReviewActionSurvivesBlockedAtAnyStatus` → `testReviewActionsSurviveBlockedOnReviewStatuses`. **Why:** old names asserted the removed FALSE-when-blocked behavior; new names describe the #134 behavior.
- [low] The review-family inverted test now also pins the still-holding gates (status gate withholds non-review/`nil`; backlog still wins) rather than only the new TRUE cases, and `testCanApplyViaDiscussionTrueWhenBlocked` likewise re-asserts the `completed`/`nil` status gate and the backlog gate under `isBlocked: true`. **Why:** keep full coverage of what did NOT change so a future edit can't silently drop a gate.
- [high] Added `testWorkAndElaborateActionsSurviveBlocked` immediately before the `// MARK: - Review actions (#091 ...)` section, after the existing backlog work-predicate tests. **Why:** groups it with the other work/elaborate predicate tests. It covers `canElaborate(.pending)`, `canWork(.elaborated)`, `canExecutePending(.pending)`, `canReElaborate(.elaborated)` all with `isBlocked: true, isBacklogged: false`.

## Changes
- **`Sources/Plans/PlanDetailView.swift`** — Removed the `guard !isBlocked else { return false }` line from the eight relaxed `can*` predicates, in three families:
  - Elaborate: `canElaborate`, `canReElaborate`, `canReElaborateReview`
  - Execute: `canWork`, `canExecutePending`, `canExecuteReview`
  - Discuss: `canDiscuss`, `canApplyViaDiscussion`

  Each predicate keeps its `isBlocked:` parameter in the signature (call sites and the two cross-cutting guards stay intact) and keeps its `isBacklogged` guard. `canReview` and `canComplete` are left gated on `!isBlocked` on purpose (review/merge of a blocked plan stays withheld). Updated the doc comment on each relaxed predicate to say `isBlocked` deliberately no longer withholds the action (mirroring the existing `canBacklog`/`canDelete` wording), and added explicit notes on `canReview`/`canComplete` that they stay `isBlocked`-gated by design. Also corrected six stale inline "non-blocked" call-site comments in the `PlanDetailView` action bar that otherwise misdescribed the now-relaxed behavior (comments only — no button/predicate logic changed).
- **`Tests/PlansTests/PlanDetailViewTests.swift`** — Inverted the three blocked-gating tests to assert the new behavior (TDD red → green):
  - `testNoReviewActionSurvivesBlockedAtAnyStatus` → `testReviewActionsSurviveBlockedOnReviewStatuses` (`canExecuteReview`/`canReElaborateReview` now TRUE on `review`/`in-review` when blocked; still FALSE for non-review/`nil` and when backlogged).
  - `testCanDiscussFalseWhenBlocked` → `testCanDiscussTrueWhenBlocked`.
  - `testCanApplyViaDiscussionFalseWhenBlocked` → `testCanApplyViaDiscussionTrueWhenBlocked` (TRUE for active statuses when blocked; still FALSE for `completed`/`nil` and when backlogged).
  - Added `testWorkAndElaborateActionsSurviveBlocked` pinning `canElaborate(.pending)`, `canWork(.elaborated)`, `canExecutePending(.pending)`, `canReElaborate(.elaborated)` all TRUE with `isBlocked: true, isBacklogged: false`.
- **Confirmed no change needed** to `Sources/Plans/AgentDock.swift` (`conversationButtons` derives chip visibility purely from the relaxed predicates), the `PlanDetailView` action bar (each button wrapped in `if Self.canXXX(...)`), and `TaskParser.swift` / `TaskStatus+Glance.swift` (no `.blocked` `TaskStatus` case added; blocked stays a derived overlay).
- **Tests:** `swift build` succeeds with 0 warnings; `swift test --filter PlanDetailViewTests` = 104 tests, 0 failures (including the inverted/new blocked tests and the still-green `isBacklogged`-gate and `canReview`/`canComplete`-blocked assertions).

## Notes
_Additional context_
