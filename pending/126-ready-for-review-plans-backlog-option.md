# "Ready for review" plans should still have the backlog option

**ID:** 126
**Created:** 2026-11-20T00:00
**Type:** bug
**Status:** elaborated

## What
"Ready for review" plans should still have the backlog option.

## Why
Improves usability: a plan that has finished execution and is sitting in the
`review` state ("Ready for review") is a perfectly valid thing to defer, but the
detail view's overflow menu currently hides the Backlog action for it — forcing
the user to drop to the CLI (`/plan-backlog NNN`) to park a review-state plan. A
review-state plan has no active worktree checkout to disturb, so offering Backlog
for it is safe and restores the expected parity with pending/elaborated plans.

## How Summary
Widen the single pure predicate `PlanDetailView.canBacklog(status:isBlocked:)` to
also return `true` for `.review`, in addition to the existing `.pending` /
`.elaborated`. Both the overflow-menu visibility gate and the Backlog button
already consume this predicate, so no UI wiring changes are needed — the button
lights up automatically. `.inReview` stays excluded deliberately: `plan-backlog`
auto-pauses an `in-review` task (git `add -A` + default-branch checkout), and the
existing safety rule keeps that git-moving path off a single in-app click. Update
the test that pins the old behavior.

**Files of note:**
- `Sources/Plans/PlanDetailView.swift` — `canBacklog(status:isBlocked:)` at ~line 1250 is the sole decision point; the menu gate (~582) and button (~699) already use it.
- `Tests/PlansTests/PlanDetailViewTests.swift` — `testCanBacklogOnlyForPendingAndElaborated` (~line 320) pins the current exclusion and must be updated.
- `Sources/Plans/TaskParser.swift` — `TaskStatus` enum defines the distinct `.review` and `.inReview` cases.

## Diagnosis

**Most likely:** The pure predicate `canBacklog(status:isBlocked:)` returns `true` only for `.pending`/`.elaborated`, so it evaluates `false` for `.review`, and both the overflow-menu visibility gate and the Backlog button (which consume it) hide the action for review-state plans (`Sources/Plans/PlanDetailView.swift:1250-1252`).
**Evidence:** `canBacklog` is `status == .pending || status == .elaborated`; the menu gate at `PlanDetailView.swift:582-584` and the button's `else if Self.canBacklog(...)` branch at `PlanDetailView.swift:699-708` both call it; `Tests/PlansTests/PlanDetailViewTests.swift:324` asserts it is `false` for `.review`.
**Confidence:** high

**Alternative:** A separate per-row backlog action in `PlanRowActions.swift` is responsible — **Confidence:** low (ruled out: `PlanRowActions.swift` offers no backlog action in any status branch; Backlog is detail-view-only).

**To confirm:** `plan-backlog`'s auto-pause (git `add -A` + default-branch checkout) fires ONLY when Status is `in-progress` or `in-review` (plan-backlog SKILL.md step 5); for `review` it is skipped entirely — so widening `canBacklog` to include `.review` moves no git state and needs no confirmation dialog, while `.inReview` must stay excluded to preserve that safety rule.

## How
- [ ] Step 1: Add/extend a failing unit test in `Tests/PlansTests/PlanDetailViewTests.swift` asserting `PlanDetailView.canBacklog(status: .review, isBlocked: false)` is `true` while `.inReview`, `.inProgress`, `.completed`, and `nil` stay `false` (confirms the Diagnosis; agent-verifiable, so untagged).
- [ ] Step 2: Widen `canBacklog(status:isBlocked:)` in `Sources/Plans/PlanDetailView.swift` to return `true` for `.pending`, `.elaborated`, and `.review` (leave `.inReview` excluded).
- [ ] Step 3: Update the predicate's doc comment to explain that `.review` is safe (no auto-pause, no git state moved) while `.inReview` remains excluded because its auto-pause commits work and switches branches.
- [ ] Step 4: Run the targeted test file (`swift test` filtered to `PlanDetailViewTests`) and confirm green.

## Verification
- `PlanDetailView.canBacklog(status: .review, isBlocked: false)` returns `true`; `.inReview`, `.inProgress`, `.completed`, and `nil` still return `false`.
- The `PlanDetailViewTests` suite passes.
- In the running app, selecting a `review`-state plan shows the "Backlog" item in the detail view's "More" overflow menu; an `in-review` plan does not.

## Impact Scope
_Fewer than 3 files — skipped._

## Assumptions

### Initial (from elaboration)
- [low] "Ready for review" maps to the `.review` status only, not `.inReview`. **Why:** The user-facing "Ready for review" state is `review` (what a finished worktree/yolo execution produces); `in-review` is a review actively in progress. The title's wording and the safety comment (which names `in-review` as the git-touching case) both point to widening `review` alone.
- [low] Widen `canBacklog` to include `.review` without adding a confirmation dialog. **Why:** `plan-backlog` skips its git-touching auto-pause for `review` status (auto-pause fires only for `in-progress`/`in-review`), so a single in-app Backlog click on a review plan moves no git state — the existing safety rationale for a confirm gate does not apply. `.inReview` stays excluded to preserve that rule.
- [high] No new UI, predicate, or per-row action is added; the fix is a one-predicate widening plus a test update. **Why:** Research confirmed the overflow-menu gate and the Backlog button already consume `canBacklog`, so widening it lights up the existing button automatically.

### Discovered during execution
_To be filled during execution_

## Changes
_To be filled during execution_

## Notes
Root cause and fix location identified via diagnostic research; see Diagnosis.
