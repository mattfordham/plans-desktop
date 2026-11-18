# In-Progress Plans Should Not Have Execute Button

**ID:** 027
**Created:** 2026-06-06T15:52
**Type:** bug
**Status:** completed
**Completed:** 2026-06-06T16:00
**Branch:** fix/027-in-progress-plans-should-not-have-execute-button

## What
A plan whose status is `in-progress` currently shows an "Execute" action (the
`play.fill` glyph in the project card row, and the "Execute" menu/toolbar action
in the detail window). An in-progress plan is already being worked — offering an
Execute button on it is misleading and lets the user kick off a redundant run.
In-progress plans should not surface the Execute action at all.

## Why
The Execute action exists to *start* work on a plan. Once a plan is in-progress,
that work is already underway (or paused mid-run), so re-executing is not a valid
user intent and is confusing. Restricting Execute to `elaborated` plans makes the
action's meaning unambiguous — Execute always means "begin executing a plan that
is ready but not yet started." Resuming in-progress work is handled elsewhere
(the run spinner / progress dialog), not by the Execute affordance.

## How
- [x] Step 1: In `Tests/PlansTests/`, add/extend a targeted test for `PlanDetailView.canWork(status:isBlocked:)` asserting that it returns `true` for `.elaborated` (not blocked) and `false` for `.inProgress` (not blocked), plus the existing blocked/other-status cases. Write this test FIRST (RED) — it should fail against the current implementation which returns `true` for `.inProgress`.
- [x] Step 2: In `Sources/Plans/PlanDetailView.swift`, change the `canWork` predicate so it returns `true` only for `status == .elaborated` (still guarded by `!isBlocked`). Remove `.inProgress` from the allowed set. Update the doc comment above `canWork` to say the action is available only for an elaborated (not in-progress) task that is not blocked. This single predicate gates both the project-card row glyph (`ProjectCard.swift` `rowActions`) and the detail-window Execute action, so both surfaces are fixed at once (GREEN).
- [x] Step 3: Run the targeted test (`swift test --filter PlanDetailViewTests` or whichever file holds the `canWork` tests) to confirm the new behavior holds and no existing `canWork`/`canElaborate` assertion regressed. Run `swift build` to confirm everything compiles.

## Verification
- `swift build` succeeds.
- `PlanDetailView.canWork(status: .inProgress, isBlocked: false)` returns `false`; `canWork(status: .elaborated, isBlocked: false)` returns `true`.
- In the running app, an in-progress plan row shows no `play.fill` Execute glyph (and the detail window's Execute action is disabled/absent for an in-progress plan); an elaborated plan still shows Execute.
- The targeted `canWork` test passes.

## Impact Scope
_Two files (`Sources/Plans/PlanDetailView.swift` + a targeted test file); under the 3-file threshold, so no detailed scope table. The fix is a single pure-predicate change that both the card row and the detail view already consume._

## Assumptions

### Initial (from elaboration)
- [high] The fix belongs in the shared `canWork` predicate, not at each call site. **Why:** Both `ProjectCard.rowActions` (line ~469) and `PlanDetailView` (line ~160) gate the Execute action through `PlanDetailView.canWork`, so changing the predicate fixes both surfaces consistently and keeps the gating rule single-sourced and unit-testable (matching the existing `canWork`/`canElaborate` design).
- [high] Execute should remain available for `.elaborated`. **Why:** Elaborated-but-not-started is exactly the state Execute is meant for; only `.inProgress` is being removed per the request.
- [low] No new affordance is added for resuming in-progress work as part of this task. **Why:** The request is strictly to remove the Execute button from in-progress plans; resuming is already represented by the run spinner/progress dialog. Adding a "resume" affordance would be out of scope.

### Discovered during execution
- [high] Extended the existing `canWork` tests in `Tests/PlansTests/TaskRunnerTests.swift` (`testCanWorkGating`) rather than creating a new `PlanDetailViewTests.swift`. **Why:** The `canWork`/`canElaborate` predicate tests already live there as a dedicated section ("Work this task" button gating); matching the existing convention keeps the suite cohesive and avoids a redundant file. No real ambiguity arose.

## Changes
- `Sources/Plans/PlanDetailView.swift`: `canWork(status:isBlocked:)` now returns `status == .elaborated` (was `status == .elaborated || status == .inProgress`); doc comment updated. This drops the Execute affordance for in-progress plans on both surfaces (project-card row `play.fill` glyph and the detail-window Execute action), which both consume this single predicate.
- `Tests/PlansTests/TaskRunnerTests.swift`: extended `testCanWorkGating` — `.inProgress` (not blocked) now asserted `false`; `.elaborated` (not blocked) `true`; `.pending`/`.review`/`.inReview`/`.completed`/`nil` and blocked cases all `false`. (Tests live here alongside the existing `canWork`/`canElaborate` gating section rather than a new `PlanDetailViewTests.swift`.)
- Verified: `swift test --filter TaskRunnerTests` → 16 tests, 0 failures; `swift build` → Build complete.

## Notes
Root cause: `PlanDetailView.canWork` (`Sources/Plans/PlanDetailView.swift:177`)
returns `status == .elaborated || status == .inProgress`. The `.inProgress`
branch is what surfaces Execute on in-progress plans. Consumers:
`ProjectCard.swift` `rowActions` (`play.fill` glyph) and `PlanDetailView`'s
Execute action. A run-in-flight is a separate concern (shows a spinner) and does
not gate availability, so this change is purely about the persisted status.
