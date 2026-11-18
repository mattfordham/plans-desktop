# Focussed Project Pane Should Stretch To 100% Tall

**ID:** 071
**Created:** 2026-08-27T00:00
**Type:** feature
**Status:** completed
**Branch:** feature/071-focussed-project-pane-should-stretch
**Completed:** 2026-08-31T14:11

## What
Focussed project pane should stretch to 100% tall

## Why
Adds value by making Focus mode (#067) feel intentional: when a single project's
card is focused it currently hugs its content height and strands a large band of
empty space below it. Stretching the focused card to fill 100% of the viewport
height (pinning its header/footer and scrolling the plan list internally) makes
the focused view read as a dedicated pane rather than a lone short card floating
in an empty window.

## How Summary
Focus mode (#067) collapses the grid to a single project's card. Because that is
one column, `effectiveLayoutMode` forces `.scroll`, which routes the card through
`variableCardGrid` at its natural (content-hugging) height — leaving empty space
below. Add a dedicated focus render branch in `cardGrid` that, when a project is
actually focused (`store.focusedProjectPath` resolves to a live project),
renders the single `ProjectCard` at full viewport height by reusing the existing
`evenRowHeights(rowCount: 1, …)` helper to compute the height and feeding it into
`cardCell(constrainedHeight:)` — the same #038 machinery fit mode uses (header
pinned top, footer pinned bottom, plan list scrolls internally). A new pure
helper makes the "is this the focus single-card case" decision unit-testable.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — `cardGrid` (layout entry), `variableCardGrid` / `fitCardGrid` (existing paths), `evenRowHeights` + `cardCell(constrainedHeight:)` (reused), `sortedProjects`/`focusedProjectPath` (focus resolution). All changes live here.
- `Tests/PlansTests/BrowserWindowTests.swift` — pure value tests for the layout helpers; the new focus decision helper gets tested alongside `evenRowHeights`/`effectiveLayoutMode`.

## How
- [x] Step 1: Add a failing test in `Tests/PlansTests/BrowserWindowTests.swift` for a new pure helper `isFocusedSingleCard(focusedProjectPath:cardCount:)` (true only when a focus path is set AND exactly one card is showing), and a test confirming `evenRowHeights(rowCount: 1, viewportHeight:…)` returns a single viewport-filling height (chrome = `2*padding`) — the height a focused card should occupy.
- [x] Step 2: Add the pure `static func isFocusedSingleCard(focusedProjectPath:cardCount:)` helper to `BrowserWindow` (no view-state reads, mirrors the style of `effectiveLayoutMode`) so the failing test passes.
- [x] Step 3: Add a `focusCardGrid` render path (or an inline focus branch in `cardGrid`) that renders the single focused `ProjectCard` via `cardCell(for:constrainedHeight:)`, where `constrainedHeight` comes from `evenRowHeights(rowCount: 1, viewportHeight: gridHeight, spacing: gridSpacing, padding: gridPadding, minRowHeight: fitRowMinHeight).first`, wrapped so it fills width and full viewport height (`.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)` on the container, matching `gridPadding`/`scrollerClearance` conventions).
- [x] Step 4: Wire the branch into `cardGrid`: when `isFocusedSingleCard(focusedProjectPath: effectiveFocus, cardCount: sortedProjects.count)` is true, render `focusCardGrid` instead of `variableCardGrid`/`fitCardGrid`; otherwise the existing `effectiveMode` dispatch is unchanged. Keep the outer `ScrollView` + `.scrollBounceBehavior(.basedOnSize)` so an over-tall focused card still scrolls internally without overscroll bounce.
- [x] Step 5: Run the targeted test file (`swift test --filter BrowserWindowTests`) and confirm the new tests pass and existing layout-helper tests still pass.
- [x] 👁 Step 6: Build and run the app, enter Focus mode on a project via a card's viewfinder glyph, and visually confirm the focused card now stretches to fill the full window height (header pinned top, plan list scrolling internally, no empty band below), and that leaving focus restores the normal multi-card grid unchanged. _(⏳ deferred to review — requires running the GUI app; verify during /plan-review)_

## Verification
- In Focus mode (single project focused via the viewfinder glyph), the focused
  card fills 100% of the window's vertical height with no empty space below it.
- When the focused project's plan list is taller than the viewport, the card
  caps at viewport height and its plan list scrolls internally (header/footer
  stay pinned) rather than the card overflowing.
- Leaving Focus mode restores the normal multi-card grid layout unchanged.
- `swift test --filter BrowserWindowTests` passes, including the new focus helper
  tests and the existing `evenRowHeights` / `effectiveLayoutMode` tests.

## Impact Scope
_Not applicable — fewer than 3 files affected (BrowserWindow.swift plus its test)._

## Assumptions

### Initial (from elaboration)
- [low] "Focussed project pane" means Focus mode (#067) — the single focused project's card in the Browser window (Surface B) — not `PlanDetailView` or a split detail pane. **Why:** The Browser is a pure card dashboard with no HSplitView/detail pane; plans open in separate windows. Focus mode is the only feature that collapses to a single project's "pane," and it exhibits exactly the content-hugging gap described. Research flagged this as the intended target with high confidence.
- [low] Scope the stretch to explicit Focus mode only — keyed off `store.focusedProjectPath` resolving to a live project — rather than any incidental single-card grid (e.g. one linked project, or "Hide Empty" collapsing to one). **Why:** Focus is the deliberate, user-invoked "show me just this" gesture the task describes; keying off it keeps the behavior predictable and matches the #067 feature boundary. Other single-card cases were left on the existing masonry path to avoid changing unrelated layouts.
- [low] When the focused project's content exceeds the viewport, cap the card at viewport height and scroll its plan list internally (reuse the #038 `constrainedHeight` behavior) rather than letting the card grow past the viewport. **Why:** "100% tall" implies filling — and not exceeding — the viewport; the #038 machinery (header pinned top, footer pinned bottom, body scrolls) already delivers exactly this and is reused rather than reinvented.
- [high] Reuse `evenRowHeights(rowCount: 1, …)` to compute the focused card's height and feed it through the existing `cardCell(for:constrainedHeight:)` chrome, rather than inventing new layout math. **Why:** `evenRowHeights` is pure, unit-tested, and already computes a viewport-filling height with a min-height floor; `cardCell` already threads `constrainedHeight` into `ProjectCard`. Research explicitly recommended this reuse over the `fitCardGrid` row-division machinery.

### Discovered during execution
- [high] Reused the existing `testEvenRowHeightsSingleRowFillsViewport` test to satisfy the Step 1 single-row requirement rather than adding a duplicate. **Why:** That test already asserts `evenRowHeights(rowCount: 1, …)` returns exactly one element equal to `viewportHeight - 2*padding` (chrome = `2*padding`) above the floor — the exact contract Step 1 asked to confirm — so a second identical test would only duplicate coverage.
- [low] Implemented `focusCardGrid` as a `private func focusCardGrid() -> some View` (parameterless) rather than a computed `private var`. **Why:** The other grid builders on `BrowserWindow` are functions (`fitCardGrid`/`variableCardGrid`); a func keeps the pattern consistent even though this one takes no arguments. Wrapped the single card in a `VStack(spacing: 0)` so the `if let` guard has a container to attach the `.frame(maxWidth:maxHeight:alignment:)`/padding modifiers to (mirrors how `fitCardGrid` returns a `VStack`).
- [high] Computed `effectiveFocus` inline in `cardGrid` by duplicating the resolution logic from `sortedProjects` (the `store.focusedProjectPath.flatMap { … }` snippet) rather than extracting a shared computed property. **Why:** The task said "compute the same way (or reuse a shared computed value)"; the snippet is two lines and `sortedProjects` already reads it locally, so inlining avoided introducing a new stored/computed member for a minor DRY gain. Can be hoisted to a shared computed value later if a third caller appears.

## Changes
- `Sources/Plans/BrowserWindow.swift`:
  - Added pure helper `static func isFocusedSingleCard(focusedProjectPath:cardCount:) -> Bool` (true iff a focus path is set and exactly one card shows).
  - Added `private func focusCardGrid()` rendering the single focused project's card via `cardCell(for:constrainedHeight:)`, with `constrainedHeight` from `evenRowHeights(rowCount: 1, viewportHeight: gridHeight, …).first`, wrapped to fill width and full viewport height (`.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)`, matching gridPadding/scrollerClearance).
  - `cardGrid` now computes `effectiveFocus` + `focusedSingleCard` and dispatches `focusCardGrid()` first, falling through to the unchanged fit/variable dispatch otherwise. Outer `ScrollView` + `.scrollBounceBehavior(.basedOnSize)` retained.
- `Tests/PlansTests/BrowserWindowTests.swift`: +5 `isFocusedSingleCard` unit tests. Reused existing `testEvenRowHeightsSingleRowFillsViewport` for the rowCount:1 assertion.
- Targeted tests: `swift test --filter BrowserWindowTests` → 89 pass, 0 fail.
- **Fix during /plan-review (Step 6 observation failed):** `focusCardGrid` computed
  the height but never imposed it — it passed `constrainedHeight` to `cardCell` and
  relied on `.frame(maxHeight: .infinity)`. `ProjectCard` uses `constrainedHeight`
  only as a boolean signal (switch to inner-scrolling layout) and sets no frame of
  its own, and `maxHeight: .infinity` is inert inside the grid's `ScrollView`, so the
  card kept hugging its content. Extracted `static func focusedCardHeight(viewportHeight:)`
  (non-optional, clamps to `fitRowMinHeight`) and applied `.frame(height:)` on the card —
  matching `fitCardGrid`'s per-row `.frame(height:)` contract. +3 tests.
- Tests after fix: `swift test` → 400 pass, 0 fail (`BrowserWindowTests` 92, +3).

## Notes
_Additional context_
