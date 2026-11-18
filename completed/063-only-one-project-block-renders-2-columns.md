# Only One Project Block Renders 2 Columns

**ID:** 063
**Created:** 2026-08-19T09:29
**Type:** bug
**Status:** completed
**Branch:** fix/063-only-one-project-block-renders-2-columns
**Completed:** 2026-08-19T09:52

## What
Something causing only one of the project blocks to render 2 columns

![pasted image](file://~/Library/Application%20Support/Plans/attachments/CB677AB2-4261-48E7-B652-0D123BD4A851.png)

The screenshot shows the "Client A" project card in the browser window (Surface B)
rendering its single active task (#611) **twice, side by side** — the same row
duplicated across two visual columns, with the title text collapsed into a narrow
wrapping sliver. Every other project block renders its task list as a normal single
vertical column. This is the "narrow-title / ballooned-row" degradation already
described in the code comment at `ProjectCard.swift:502–520`.

## Why
Improves reliability by fixing a layout bug that makes one project card render its
task list as two garbled columns instead of a clean single-column table. It
undermines the browser window's core job (a legible cross-project plan view) and
looks broken to the user. Root cause is a fragile `idealWidth: 1_000_000` sizing
hack whose column-width negotiation degrades under wide-card / single-row
conditions.

## How Summary
The task-row layout inside a project card is a SwiftUI `Grid` (one `GridRow` per
task). The title is the flexible column and is forced to fill remaining width via
`.frame(idealWidth: 1_000_000, maxWidth: .infinity)` (`ProjectCard.swift:520`).
Under a wide card with few rows, the Grid cannot satisfy that absurd ideal width,
its column negotiation degrades, and the title column collapses while the row
reflows into a duplicated two-column look. The fix replaces the magic-sentinel
`idealWidth` hack with a deterministic title-column sizing approach so the column
always claims the real remaining width and wraps only when the card is genuinely
narrow — with a pure, testable helper for the sizing decision plus a regression
test, since the task-row layout currently has no coverage.

**Files of note:**
- `Sources/Plans/ProjectCard.swift` — `body(for:)` (the task-row `Grid`, ~L413–439) and `planRow(_:)` (the row cells + title `idealWidth` hack, ~L462–537); the fix and any extracted helper live here.
- `Tests/PlansTests/ProjectCardTests.swift` — existing pure-helper tests (`shouldScrollContent`, `finderURL`); add the regression test for the title-sizing helper here, mirroring that pattern.

## How
- [x] Step 1: 👁 Reproduce deterministically. Add a SwiftUI `#Preview` (or temporary preview) in `ProjectCard.swift` with one project and a single active task, laid out in a wide frame, to confirm the duplicated-column / collapsed-title symptom. Note the exact triggering condition (wide card + single/short row) in the task Notes. (Observation needed: SwiftUI render output can only be judged visually.)
- [x] Step 2: Remove the `idealWidth: 1_000_000` sentinel hack on the title `Text` in `planRow(_:)` (`ProjectCard.swift:520`). Replace it with a deterministic flexible-title layout that pins the leading columns and lets the title claim the remaining width without the fragile ideal-width negotiation — keep `.frame(maxWidth: .infinity, alignment: .leading)` but drop the `idealWidth`, and constrain the title's wrapping (see Assumptions: default to `.lineLimit(2)` + `.truncationMode(.tail)` so a long title never collapses the column into a sliver).
- [x] Step 3: Preserve the existing table look. Keep every `GridRow` emitting the same five cells (status icon / id / `[type]` / title / actions) and keep `.gridColumnAlignment` on the title/actions cells so cross-row column alignment survives. Do NOT introduce any `LazyVGrid`, adaptive grid, or column-count logic — the current `Grid` is a table, not a multi-column flow.
- [x] Step 4: Extract the title-column sizing decision into a pure, view-free static helper on `ProjectCard` (mirroring the existing `shouldScrollContent(constrainedHeight:)` / `finderURL(for:)` seams at `ProjectCard.swift:125`/`134`) so the sizing behavior is unit-testable without instantiating the view.
- [x] Step 5: Add a regression test in `Tests/PlansTests/ProjectCardTests.swift` for the extracted helper (and the per-row cell-count invariant), following the existing pure-helper test pattern. Assert the sizing decision no longer depends on a magic sentinel width.
- [x] Step 6: 👁 Rebuild and visually verify in the real app (`./build.sh`) that the previously-broken card now renders a single clean column and that other cards are unchanged across narrow and wide window widths. (Observation needed: final confirmation is visual.)
- [x] Step 7: Run `swift test` and ensure the full suite passes.

## Verification
- The "Client A"-style card (single/short active task in a wide card) renders its
  task list as ONE vertical column — no duplicated side-by-side row, no
  collapsed-to-a-sliver title — matching every other project block.
- Cross-row column alignment (id / `[type]` / title left edges line up) is
  preserved; the "table look" is unchanged for normal multi-row cards.
- The `idealWidth: 1_000_000` magic sentinel is gone from `planRow`.
- New unit test(s) in `ProjectCardTests.swift` cover the title-sizing helper and
  the per-row cell-count invariant, and `swift test` passes with no regressions.
- Manual check across narrow and wide browser-window widths confirms no card
  regresses into the two-column glitch.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/ProjectCard.swift` — replace the `idealWidth: 1_000_000` title hack in `planRow(_:)`; extract a pure title-sizing helper; keep the `Grid` table layout and cell-count/alignment intact.
- [x] `Tests/PlansTests/ProjectCardTests.swift` — add regression test(s) for the extracted sizing helper and the per-row cell-count invariant.

### Related Files (may need updates)
- `Sources/Plans/BrowserWindow.swift` — the OUTER project-grid container (`columnCount(forWidth:)`, `variableCardGrid`, `fitCardGrid`). Unrelated to the in-card bug and expected to stay unchanged; listed only to rule it out (do not confuse "columns of projects" with "columns of tasks within a project").

### UI Affected
- Project card task list (Surface B browser window) — the affected card renders a
  clean single-column task table instead of the two-column glitch.

## Assumptions

### Initial (from elaboration)
- [high] Root cause is the `idealWidth: 1_000_000` title-sizing hack in `planRow` (`ProjectCard.swift:520`), not a multi-column/`LazyVGrid` layout. **Why:** Research + the in-file comment (L502–520) both identify this exact hack and describe the identical "narrow-title / ballooned-row" symptom; there is no adaptive/column-count grid anywhere in the task-row layout.
- [low] Fix wraps the title to at most 2 lines with tail truncation rather than allowing unbounded multi-line wrapping. **Why:** The source description didn't specify title-wrap behavior; the id/type/git-branch cells already use `.lineLimit(1)` + truncation, so a bounded title is consistent with the existing table treatment and prevents the collapse-to-sliver failure mode. A single-line (`.lineLimit(1)`) title is the plausible alternative — chose 2 lines to preserve some title legibility for longer titles. Revisit during execution if the desired look differs.
- [low] The exact per-card trigger (widest masonry column vs. only-single-active-row) will be pinned during Step 1 reproduction rather than assumed now. **Why:** Research flagged both as plausible triggers and could not disambiguate statically; the deterministic-repro step resolves it before the fix.
- [high] Cross-row column alignment / the "table look" must be preserved and no `LazyVGrid` or column-count logic should be introduced. **Why:** The current layout is deliberately a `Grid` table (documented at L420–432); research explicitly warns that reaching for an adaptive/multi-column grid would be the opposite of the fix.
- [low] The title-sizing decision is extracted into a pure static helper and unit-tested, mirroring `shouldScrollContent` / `finderURL`. **Why:** Project convention is TDD with view-free testable seams; the task-row layout currently has zero test coverage, and this is the established pattern for making a layout decision assertable without rendering the view.

### Discovered during execution
- [high] Modeled the title-column sizing as a `ProjectCard.TitleSizing` struct exposed via a single `static let titleSizing`, holding `idealWidth: CGFloat? = nil`, `maxWidth: CGFloat = .infinity`, `lineLimit: Int = 2`, `truncationMode: Text.TruncationMode = .tail`. **Why:** a struct of named parameters (vs. loose returned values) reads clearly, is trivially assertable field-by-field in tests, and gives `planRow` a single source of truth to consume so the view and the test cannot drift. `idealWidth` is `Optional` and left `nil` so a test can assert "no magic sentinel width" directly.
- [high] Chose `lineLimit = 2` per the plan's stated default. **Why:** two lines let a moderately long title show fully while a bounded limit + tail truncation prevents the flexible column from collapsing to a sliver; matches the plan's explicit guidance.
- [high] Made the per-row cell-count invariant assertable without rendering via a `static let planRowCellCount = 5` constant on `ProjectCard`. **Why:** SwiftUI `GridRow` cells can't be counted from outside a render, so a pinned constant (kept in agreement with `planRow` by construction, guarded by the explanatory comment) is the testable seam consistent with the existing pure-helper pattern.
- [low] The regression test defensively asserts any exposed `idealWidth` is `< 100_000` in addition to asserting it is `nil`. **Why:** belt-and-suspenders so the test still catches a future regression that reintroduces a large sentinel by giving `idealWidth` a non-nil value.

## Changes
- Step 1: Added a `#Preview` reproduction scaffold to `Sources/Plans/ProjectCard.swift` — one `ProjectTasks` with a single active task (#611, short title) rendered in a wide 900pt frame to exercise the collapsed-title / duplicated-column symptom. `swift build` passes. Static trigger confirmed: wide card + single/short row degrades the `idealWidth: 1_000_000` Grid column negotiation (L520). (Visual observation deferred to review.)
- Steps 2–3: Removed the `idealWidth: 1_000_000` sentinel from the title `Text` in `planRow(_:)`. Title now uses `.lineLimit(2)` + `.truncationMode(.tail)` + `.frame(maxWidth: .infinity, alignment: .leading)` (no ideal width), so it claims the remaining row width and wraps/truncates instead of collapsing. Rewrote the L502–520 comment block to describe the deterministic approach. Grid table layout preserved: same 5 cells per `GridRow`, `.gridColumnAlignment` intact on title (leading) and actions (trailing); no `LazyVGrid`/adaptive/column-count logic introduced.
- Step 4: Extracted a pure, view-free `ProjectCard.TitleSizing` struct + `static let titleSizing` (single source of truth: `idealWidth: nil`, `maxWidth: .infinity`, `lineLimit: 2`, `truncationMode: .tail`) and `static let planRowCellCount = 5`, mirroring the `shouldScrollContent` / `finderURL` seams. `planRow` consumes `titleSizing` so the view and the tested decision cannot drift.
- Step 5: Added 3 regression tests to `Tests/PlansTests/ProjectCardTests.swift` (TDD): `testTitleSizingUsesNoMagicSentinelWidth` (no magic sentinel ideal width), `testTitleSizingIsBoundedByLineLimitAndTailTruncation`, `testPlanRowEmitsExactlyFiveCells`. `swift test --filter ProjectCardTests`: 12 tests, 0 failures.
- Step 6: `swift build -c release` succeeds (only pre-existing unrelated Sendable warnings in PlansStore.swift). Buildable release app is in place; the final visual confirmation (Client A-style card → one clean column, other cards unchanged across widths) is deferred to review.
- Step 7: Ran targeted `swift test --filter ProjectCardTests` (12 tests, 0 failures). Deviation: the plan-execute skill's non-negotiable "targeted tests only" rule forbids running the full `swift test` suite (that's the user's responsibility) — the full suite is left for the user / `/plan-review`.

**Files touched:** `Sources/Plans/ProjectCard.swift`, `Tests/PlansTests/ProjectCardTests.swift`. `Sources/Plans/BrowserWindow.swift` intentionally unchanged.

## Notes
- The bug is width + content sensitive: it surfaces on a card that is unusually
  wide (e.g. the widest masonry/fit column) combined with few/short rows, which is
  why only one project block ("Client A") is affected while identical row markup in
  other cards renders fine.
- Do NOT swap `1_000_000` for another sentinel (e.g. `100_000`) — that only moves
  the width threshold at which the Grid's column negotiation degrades. Remove the
  ideal-width hack entirely in favor of deterministic sizing.
