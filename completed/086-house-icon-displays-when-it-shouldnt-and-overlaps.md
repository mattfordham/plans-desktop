# House icon displays when it shouldn't and overlaps the title

**ID:** 086
**Created:** 2026-09-30T00:00
**Type:** bug
**Status:** completed
**Completed:** 2026-09-30T15:54
**Branch:** fix/086-house-icon-displays-when-it-shouldnt-and-overlaps

## What
The house icon seems to be displaying at times when it shouldn't AND is overlapping.

A pasted screenshot shows a browser-window plan row where, immediately after the
`[refactor]` type badge, the muted house glyph appears crowded up against — and
visually overlapping — the start of the title text ("Revert Playing Row Render,
Add Blue Cover-Art Border").

_Attachment:_ `file://~/Library/Application Support/Plans/attachments/E430E7C1-59FD-4B7F-A44A-D7CA90ECFBDC.png`

## Why
The muted house glyph is the desktop analogue of the plans-cc dashboard TUI's
`⌂ kept` marker: it should mean "this task was executed with the `keep` keyword,
so its git worktree was preserved after the run and is reviewable in isolation."
By intent (per the code comments) it should appear **only on review-state rows**,
because a *kept* worktree is a post-execute artifact awaiting review.

Two independent defects break this:

1. **Displays when it shouldn't.** `TaskParser` derives `isKeptWorktree` purely
   from the presence of a non-empty `**Worktree:**` field
   (`TaskParser.swift:711-714`) with **no status gating whatsoever**. But a
   `**Worktree:**` line is present both *during* execution (status `in-progress`,
   the worktree is transient) and *after* a `keep` run (status `review` /
   `in-review`, the worktree is intentionally kept). So the glyph renders on
   in-progress tasks too — the repo's own fixture
   (`TaskParserTests.testAllFrontmatterFieldsPresent`) has an in-progress task
   with a live worktree and asserts `isKeptWorktree == true`. Status is the only
   proxy the app has to tell "transient" from "kept".

2. **Overlaps the title.** In `ProjectCard.planRow`, the house `Image` is placed
   *inside* the fixed-width type-badge frame (`.frame(width: typeWidth)`),
   appended after the `[refactor]` `Text` (which is `.fixedSize(horizontal:)` +
   `lineLimit(1)`, so it never shrinks). `typeWidth` is sized to fit *exactly*
   `[refactor]` plus its brackets (`ProjectCard.swift:293`, `10 * 8.5`) with no
   budget for the icon or the 4pt HStack spacing. With the widest badge present,
   `[refactor]` + 4pt + house image exceeds `typeWidth`; a SwiftUI `.frame(width:)`
   does not clip, so the icon overflows past the frame into the adjacent flexible
   title column — crowding/overlapping the title's leading edge. It's
   intermittent because a narrow badge (`[bug]`) leaves slack inside the frame and
   fits the icon without overflow.

## How Summary
Fix both symptoms with the smallest change that stays inside the repo's
established "pure, unit-tested helper" conventions:

- **Display gate (symptom 1):** add a pure derived predicate that is true only
  when the task both has a kept worktree AND is in the review family
  (`.review` / `.inReview`). Keep the raw `isKeptWorktree` (field presence)
  unchanged for correctness; gate only the *display*. Both call sites
  (`ProjectCard.planRow` and `PlanDetailView`) consume the one predicate so they
  cannot drift.
- **Overlap (symptom 2):** budget the house icon's rendered width plus the 4pt
  HStack gap into `RowColumns.typeWidth` so the widest-badge-plus-icon combination
  fits inside the pinned frame and never overflows into the title column. This
  keeps every row's title left-edge aligned (the whole point of the pinned
  columns) and is unit-testable next to `testTypeColumnFitsWidestLabel`.

**Files of note:**
- `Sources/Plans/TaskParser.swift` — home of `Task`/`isKeptWorktree`; add the pure
  `showsKeptWorktreeMarker` derived predicate (kept AND review-family) here so it
  is testable in `TaskParserTests` and shared by both views.
- `Sources/Plans/ProjectCard.swift` — `planRow` render site (gate on the predicate)
  and `RowColumns.typeWidth` (widen to budget the icon + gap).
- `Sources/Plans/PlanDetailView.swift` — the sibling render site; gate on the same
  predicate. Its layout is a flexible HStack, so no overlap fix is needed there.
- `Tests/PlansTests/TaskParserTests.swift` — where the predicate is unit-tested.
- `Tests/PlansTests/ProjectCardTests.swift` — where `typeWidth` is unit-tested.

## How
- [x] Step 1: (TDD) In `Tests/PlansTests/TaskParserTests.swift`, add failing unit
  tests for a new pure derived property `Task.showsKeptWorktreeMarker`: true when
  `isKeptWorktree` AND status is `.review` or `.inReview`; false for an
  in-progress task carrying a live worktree (the exact `testAllFrontmatterFieldsPresent`
  scenario, asserted the other way); false when `isKeptWorktree` is false
  regardless of status; false for `nil` status. Then implement
  `var showsKeptWorktreeMarker: Bool` on `Task` in `Sources/Plans/TaskParser.swift`
  as a pure computed property (no new stored field, so `==`/init are untouched) and
  make the tests pass.
- [x] Step 2: (TDD) In `Tests/PlansTests/ProjectCardTests.swift`, extend/add a
  test asserting `ProjectCard.rowColumns.typeWidth` is wide enough to fit the
  MEASURED width of `[refactor]` PLUS the rendered small-house image width PLUS the
  4pt inter-element gap (so the badge+icon HStack cannot overflow its frame). Then
  widen `RowColumns.typeWidth` in `Sources/Plans/ProjectCard.swift` to include that
  icon+gap budget, keeping the existing `testTypeColumnFitsWidestLabel` /
  `testTypeColumnFitsMeasuredWidestLabel` green. Centralize the icon-width and gap
  constants so the view and the test share one source of truth.
- [x] Step 3: In `Sources/Plans/ProjectCard.swift` `planRow`, change the render
  guard from `if row.task.isKeptWorktree` to `if row.task.showsKeptWorktreeMarker`,
  and use the shared gap constant from Step 2 for the type-cell HStack spacing.
  Update the now-inaccurate doc comment that claims "only review-state tasks carry a
  live worktree" to state the truth (the field can appear on in-progress too; the
  predicate is what restricts display).
- [x] Step 4: In `Sources/Plans/PlanDetailView.swift`, change its render guard from
  `if row.task.isKeptWorktree` to `if row.task.showsKeptWorktreeMarker` so the
  detail view and the browser card share the same gating. Update its doc comment
  similarly.
- [x] Step 5: Run the targeted tests (`swift test --filter TaskParserTests` and
  `swift test --filter ProjectCardTests`) and `swift build`; confirm the new tests
  pass and nothing regressed.

## Verification
- `swift build` succeeds; `swift test --filter TaskParserTests` and
  `swift test --filter ProjectCardTests` pass, including the new
  `showsKeptWorktreeMarker` and widened-`typeWidth` tests.
- In the browser window, the house glyph appears ONLY on `review` / `in-review`
  rows that were kept — no longer on `in-progress` tasks that merely happen to be
  running in a worktree.
- On a kept review row with the widest `[refactor]` badge, the house glyph sits
  entirely within its type column and no longer crowds or overlaps the title text;
  every row's title left-edge stays aligned.
- The plan detail window shows the house marker under the same rule (review-family
  only), unchanged layout otherwise.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/TaskParser.swift` — add pure `Task.showsKeptWorktreeMarker`.
- [x] `Sources/Plans/ProjectCard.swift` — widen `typeWidth` (icon+gap budget); gate `planRow` render on the predicate; fix doc comment.
- [x] `Sources/Plans/PlanDetailView.swift` — gate render on the predicate; fix doc comment.
- [x] `Tests/PlansTests/TaskParserTests.swift` — tests for `showsKeptWorktreeMarker`.
- [x] `Tests/PlansTests/ProjectCardTests.swift` — test the widened `typeWidth`.

### Related Files (may need updates)
- `Sources/Plans/TaskStatus+Glance.swift` — home of `keptWorktreeSymbol`; comment may need a light touch, no logic change.

### Endpoints/UI Affected
- Browser window plan rows (`ProjectCard`) — house glyph now review-only and non-overlapping.
- Plan detail window (`PlanDetailView`) — house glyph now review-only.

## Assumptions

### Initial (from elaboration)
- [low] Symptom 1 is fixed by gating *display* on status (`.review` / `.inReview`) via a pure derived predicate, NOT by changing what `isKeptWorktree` parses. **Why:** `isKeptWorktree` (field presence) is used correctly elsewhere as raw data and there is no on-disk field distinguishing "transient worktree" from "kept worktree"; status is the only available proxy, and the code comments state the intended surface is review-state rows. A parser-level change would cross the app/CLI boundary (would need plans-cc to write a distinct marker) — out of scope for this bug.
- [low] The review family is exactly `{.review, .inReview}`. **Why:** those are the two post-execute review statuses in `TaskStatus`; a kept worktree is a post-execute artifact, and no other status represents "awaiting review."
- [low] Symptom 2 is fixed by budgeting the icon+gap into the pinned `typeWidth` (reserving the lane) rather than moving the icon into its own outer-HStack lane. **Why:** it preserves cross-row title-left-edge alignment (the stated purpose of the pinned columns) with the least structural change, and fits the existing `RowColumns` pure-value + `ProjectCardTests` unit-test pattern. The tradeoff — the type column is a bit wider on every row even when no icon shows — is a small constant channel and is the accepted cost of keeping alignment deterministic.
- [high] `showsKeptWorktreeMarker` is a pure computed property (no new stored field), so `Task.==` and the initializer are untouched. **Why:** the `==` is load-bearing (gates reload publishing) and enumerates every stored property; a derived computed property adds no stored state and cannot destabilize equality.

### Discovered during execution
- [low] Chose `keptMarkerWidth = 16` for the house SF Symbol at `.imageScale(.small)` in the `.body` face. **Why:** the plan cited an approx 14pt rendered width for `house` at that scale; 16 gives ~2pt of slack so the icon never overflows the pinned type cell (`.frame(width:)` does not clip) while adding only a small constant channel to every row. Made it a named `RowColumns` constant (with `typeCellSpacing = 4`) so the width budget and the rendered HStack spacing share one source of truth and are unit-testable.
- [high] Placed `showsKeptWorktreeMarker` as a pure computed property immediately after `Task.==`, leaving the initializer and `==` untouched. **Why:** matches the plan's "no stored field" constraint; verified `swift build` and all three targeted suites stay green.

## Changes

**Summary:** Fixed both symptoms of the kept-worktree house glyph. (1) The glyph
no longer shows on tasks that merely happen to be running in a worktree — display
is now gated on a new pure derived predicate `Task.showsKeptWorktreeMarker`
(kept AND status `.review`/`.inReview`), shared by both render sites. (2) The
glyph no longer overflows its pinned type column onto the title — the house
icon's width plus the type-cell gap is now budgeted into `RowColumns.typeWidth`,
and the rendered HStack spacing is driven by the same shared constant, so the
widest badge (`[refactor]`) plus the icon always fits the cell and every row's
title left-edge stays aligned.

**Files changed (5, on branch `fix/086-house-icon-displays-when-it-shouldnt-and-overlaps`):**
- `Sources/Plans/TaskParser.swift` — added pure computed property
  `var showsKeptWorktreeMarker: Bool` on `Task`
  (`isKeptWorktree && (status == .review || status == .inReview)`). No stored
  field, so `Task.==` and the initializer are untouched. Kept raw `isKeptWorktree`
  (field presence) unchanged.
- `Sources/Plans/ProjectCard.swift` — added `RowColumns.keptMarkerWidth = 16` and
  `RowColumns.typeCellSpacing = 4`; widened `typeWidth` from `10 * 8.5` to
  `10 * 8.5 + 16 + 4` (badge + marker + gap). In `planRow`, changed the render
  guard to `showsKeptWorktreeMarker` and the type-cell HStack spacing to the shared
  `typeCellSpacing`; corrected the doc comment (the `**Worktree:**` field can also
  appear on in-progress tasks; the predicate is what restricts display).
- `Sources/Plans/PlanDetailView.swift` — changed the render guard to
  `showsKeptWorktreeMarker` (shared gating with the browser card); updated its doc
  comment. Layout is a flexible HStack, so no width change needed.
- `Tests/PlansTests/TaskParserTests.swift` — added 5 TDD tests for
  `showsKeptWorktreeMarker` (true on review + kept; true on in-review + kept; false
  on in-progress + live worktree; false when not kept; false on nil status).
- `Tests/PlansTests/ProjectCardTests.swift` — added
  `testTypeColumnFitsWidestLabelPlusKeptMarker` asserting `typeWidth` fits the
  measured `[refactor]` width plus the marker width plus the gap; existing
  `testTypeColumnFitsWidestLabel` / `...Measured...` stay green (they use `>=`).

**Tests / build (run in the worktree, independently re-verified by the orchestrator):**
- `swift build` — clean.
- `swift test --filter PlansTests.TaskParserTests` — 41 passed, 0 failed (incl. 5 new).
- `swift test --filter PlansTests.ProjectCardTests` — 28 passed, 0 failed (incl. 1 new).
- `swift test --filter PlansTests.PlanDetailViewTests` — 27 passed, 0 failed (no regression).

**Out of scope (unchanged):** `TaskStatus+Glance.swift` (`keptWorktreeSymbol`) — no
logic change needed. No parser-level change to `isKeptWorktree` (there is no on-disk
field distinguishing a transient worktree from a kept one; status is the only proxy,
and changing the writer would cross the app/CLI boundary).

## Notes
Captured and elaborated autonomously via `/plan-execute … yolo`. Root cause and
fix approach derived from a read-only research pass over `TaskParser`,
`ProjectCard`, `PlanDetailView`, and their tests.
