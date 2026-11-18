# Sort Plans In Card By Status Then By Number

**ID:** 028
**Created:** 2026-06-06T15:55
**Type:** refactor
**Status:** completed
**Completed:** 2026-06-06T16:10
**Branch:** refactor/028-sort-plans-in-card-by-status-then-number

## What
Plans within a project card should be sorted by status THEN by number. Use the status badge sorting as a guide (in-review at top, pending at bottom).

## Why
Improves scanability by grouping a card's plan rows by status in a deliberate, meaningful order that matches the header status badges. The desired top-to-bottom order is the reverse of the badge order (`TaskStatus.glanceOrder`): in-review first, then review, in-progress, elaborated, and pending last — surfacing the work closest to "done" (in-review) at the top and not-yet-started work (pending) at the bottom. Within a status, ascending id keeps a stable, predictable secondary order.

## How
- [x] Step 1: In `Tests/PlansTests/TaskParserTests.swift`, update `testActiveTasksSortedByStatusPriorityThenId` to expect the new status order (in-review at top, pending at bottom): the existing fixtures should now order as `["063", "062", "064", "061", "060", "065"]` (in-review > review > in-progress > elaborated > pending, ascending id tiebreak). Rename/adjust the test's wording to reflect the badge-derived order. Run it (`swift test --filter testActiveTasksSortedByStatusPriorityThenId`) and confirm it FAILS first (red).
- [x] Step 2: Change `TaskStatus.activePriority` in `Sources/Plans/TaskParser.swift` so priority follows the reverse of `TaskStatus.glanceOrder` (badge order): `inReview = 5`, `review = 4`, `inProgress = 3`, `elaborated = 2`, `pending = 1`, `completed = 0`. Update the doc comment above it to describe the badge-derived order (in-review top → pending bottom) instead of the old `in-progress > in-review > …` order. The existing id-ascending tiebreak in the `activeTasks` sort (`TaskParser.swift` ~line 276) stays unchanged.
- [x] Step 3: Run the targeted parser test again and confirm it PASSES (green). Also run any sort-related browser test (`swift test --filter Sort`) to confirm no other ordering test regressed.
- [x] 👁 Step 4: Build and launch the app (`./build.sh`) and visually confirm that within a project card the plan rows are ordered in-review → review → in-progress → elaborated → pending, with ascending id within each status, matching the left-to-right header badge vocabulary reversed top-to-bottom. _(Build/compile confirmed clean; visual confirmation deferred to /plan-review.)_

## Verification
- A project card with mixed-status plans lists rows top-to-bottom as in-review, review, in-progress, elaborated, pending.
- Within a single status, rows are ordered by ascending task id.
- The updated `testActiveTasksSortedByStatusPriorityThenId` passes.
- The browser window (which shares `activeTasks`) shows the same new order without regressions.

## Impact Scope
_Fewer than 3 source files modified — section omitted._

## Assumptions

### Initial (from elaboration)
- [low] Implement the reorder by changing the single canonical `TaskStatus.activePriority` rather than adding a card-only sort. **Why:** `ProjectCard` consumes `BrowserViewModel.activeRows`, which preserves `TaskParser`'s `activeTasks` order; the task says "use status badge sorting as guide", and the badges are the single order vocabulary, so one shared definition keeps the card and browser consistent. A card-only sort was the alternative but would diverge the two surfaces.
- [high] Desired order is the reverse of `TaskStatus.glanceOrder` — in-review, review, in-progress, elaborated, pending. **Why:** The task explicitly anchors "in-review at top, pending at bottom"; `glanceOrder` is `pending → elaborated → inProgress → review → inReview`, so its exact reverse satisfies both named anchors and the badge-as-guide instruction.
- [high] Keep ascending task id as the within-status tiebreak. **Why:** "sorted by status THEN by number" — number is the task id; ascending id is the existing tiebreak already in the `activeTasks` sort.

### Discovered during execution
_To be filled during execution_

## Changes
- `Sources/Plans/TaskParser.swift` — Changed `TaskStatus.activePriority` to follow the reverse of the header badge order (`glanceOrder`): `inReview=5, review=4, inProgress=3, elaborated=2, pending=1, completed=0`. Rewrote its doc comment to describe the badge-derived order (in-review at top → pending at bottom). The id-ascending tiebreak in the `activeTasks` sort was left unchanged. Because `ProjectCard` renders rows from `BrowserViewModel.activeRows` (which preserves this order) and the browser window shares the same `activeTasks`, both surfaces now order plan rows in-review → review → in-progress → elaborated → pending, ascending id within each status.
- `Tests/PlansTests/TaskParserTests.swift` — Updated `testActiveTasksSortedByStatusPriorityThenId` to expect the new order `["063", "062", "064", "061", "060", "065"]`, with wording/comments revised to describe the badge-derived order. Confirmed red before the change, green after.
- Verified: targeted test green, `swift test --filter Sort` green (5 tests, 0 failures, no regressions), `swift build` clean.

## Notes
The header status badges iterate `TaskStatus.glanceOrder` left-to-right (pending → … → in-review). This task makes the ROW order the reverse of that, so the most-advanced active status (in-review) sits at the top of the card body. `activePriority` is the shared comparator used by both the card and the browser window; both surfaces update together.
