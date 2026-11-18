# Add Scrolling Of Card Plans When Needed

**ID:** 038
**Created:** 2026-06-07T19:25
**Type:** feature
**Status:** completed
**Completed:** 2026-06-08T09:05
**Branch:** feature/038-add-scrolling-of-card-plans-when-needed

## What
Add scrolling of card plans, for when needed. Cards should not break out of grid
(when in gridmode).

In fit-to-screen ("grid") card layout (#033), every card cell in
`BrowserWindow.cardGrid` is forced to a fixed per-row height via
`.frame(height: fitHeight)`. `ProjectCard` lays its content (header, capture
rows, the per-plan rows, the git footer) out at its **natural** height with a
trailing `Spacer(minLength: 0)` to stretch into a taller cell. When a project
has more plans than the fixed cell height can show, the natural content height
**exceeds** the imposed frame height, so the card's plan list overflows the cell
and paints over the row beneath it — the card "breaks out of the grid."

This task makes a height-constrained card **scroll its body internally** (a
`ScrollView` around the plan-list content) so overflowing plans scroll within
the card, and **clips** the card to its rounded-rectangle bounds so nothing can
ever render outside the card's footprint. In scroll layout (natural,
unconstrained height) behavior is unchanged — no internal scrolling, cards hug
their content exactly as before.

## Why
Fit-to-screen layout (#033) deliberately trades scrolling the *whole grid* for
seeing every project at a glance, but it has no answer for a single project with
many plans: that one card silently overflows and overlaps its neighbours, which
looks broken and hides rows. Letting an over-full card scroll *inside its cell*
(and clipping it to its bounds) keeps the promise of fit-to-screen — the grid
itself doesn't scroll, all projects stay visible in their cells — while making
the long-plan-list case graceful instead of broken. It reuses the existing
height signal the grid already computes (`fitHeight`), so it adds no new layout
math, only a conditional `ScrollView` + clip in the card.

## How
- [x] Step 1: Add a pure, unit-testable static helper
      `ProjectCard.shouldScrollContent(constrainedHeight:)` that returns `true`
      when a card has been handed a fixed cell height (a non-nil
      `constrainedHeight`, i.e. fit/grid mode) and `false` otherwise (scroll
      mode, natural height). This mirrors the existing pure-helper pattern in
      `BrowserWindow` (`fitRowHeight`, `effectiveLayoutMode`) so the
      scroll-vs-natural decision stays testable without instantiating the view.
      Write XCTest cases FIRST (TDD red) in `ProjectCardTests.swift` covering:
      non-nil height → true, `nil` height → false. Then implement to green.
- [x] Step 2: Thread the imposed height into `ProjectCard`. Add a
      `var constrainedHeight: CGFloat? = nil` stored property (defaulted so the
      standalone/preview call sites and existing tests are source-compatible).
      In `BrowserWindow.cardGrid`'s `ForEach`, pass the already-computed
      `fitHeight` as `ProjectCard(project:constrainedHeight:onNewPlan:)`. The
      card now owns the height decision; the wrapper `.frame(height: fitHeight)`
      stays as the cell's outer size, and the existing scroll-mode trailing
      `Spacer` logic (`if fitHeight == nil`) is unchanged.
- [x] Step 3: Make the card body scroll when constrained. In `ProjectCard.body`,
      when `ProjectCard.shouldScrollContent(constrainedHeight:)` is true, wrap
      the scrollable content (the capture rows + the plan-list `body(for:)` —
      NOT the header, divider, or git footer, which stay pinned) in a
      `ScrollView { … }` so a long plan list scrolls inside the card. When false,
      render the content inline exactly as today (a plain `VStack`, no
      `ScrollView`), preserving the natural-height scroll-mode layout. Keep the
      header pinned at the top and the git footer pinned at the bottom in both
      modes (the footer remains outside the scrollable region).
- [x] Step 4: Guarantee the card never paints outside its own bounds. Add
      `.clipShape(RoundedRectangle(cornerRadius: 12))` to the card's root
      container (matching the existing `.background(… RoundedRectangle(cornerRadius: 12))`
      and `.overlay(RoundedRectangle(cornerRadius: 12).stroke(…))` corner radius)
      so even if content momentarily exceeds the frame during a resize, it is
      clipped to the card and can never overlap a neighbouring grid cell. Apply
      the clip in the same place for both modes (it is a no-op in scroll mode
      where the card is already content-sized).
- [x] Step 5: Run the targeted tests for the changed files
      (`swift test --filter ProjectCardTests` and
      `swift test --filter BrowserWindowTests`) and `swift build`. Ensure the new
      `shouldScrollContent` tests pass, the existing ProjectCard/BrowserWindow
      tests are unaffected, and the package builds.
- [x] 👁 Step 6: Build and run the app (`./build.sh`). Switch the card layout to
      "Fit to screen" (the #033 toolbar toggle) with at least one project that
      has many plans, and visually confirm: (a) the over-full card scrolls its
      plan list *inside* the card, (b) no card's content overlaps a neighbouring
      card / breaks out of the grid, and (c) "Scroll" mode is unchanged (cards
      hug their content, the whole grid scrolls as before).

## Verification
- `swift test --filter ProjectCardTests` passes, including the new
  `shouldScrollContent(constrainedHeight:)` cases (non-nil → true, nil → false).
- `swift test --filter BrowserWindowTests` is unaffected (the fit-height math is
  unchanged) and `swift build` succeeds.
- In the running app, with "Fit to screen" active, a project with more plans
  than fit in its cell scrolls its plan list inside the card.
- No card's content overlaps or paints outside its cell in fit-to-screen mode;
  every card stays within its grid cell.
- "Scroll" layout mode is visually unchanged — cards hug their content and the
  whole grid scrolls.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/ProjectCard.swift` — add `constrainedHeight` property + pure
      `shouldScrollContent(constrainedHeight:)` helper; conditionally wrap the
      card body content in a `ScrollView`; add `.clipShape(RoundedRectangle)`.
- [ ] `Sources/Plans/BrowserWindow.swift` — pass the computed `fitHeight` into
      `ProjectCard(constrainedHeight:)` in the grid `ForEach`.
- [ ] `Tests/PlansTests/ProjectCardTests.swift` — TDD unit tests for
      `shouldScrollContent(constrainedHeight:)`.

### Endpoints/UI Affected
- Browser window card grid (fit-to-screen mode) — over-full cards now scroll
  internally and are clipped to their cells instead of overflowing.

## Assumptions

### Initial (from elaboration)
- [low] "Cards should not break out of grid (when in gridmode)" is interpreted as
  the **fit-to-screen** card-layout mode from #033 (the only mode that imposes a
  fixed per-cell height and can therefore overflow). **Why:** #033 added exactly
  two modes — `.scroll` (natural height, whole-grid scroll) and `.fit`
  (fixed `fitHeight` per cell). Only `.fit` can make a card's natural content
  taller than its cell, which is the "breaking out of grid" symptom; "gridmode"
  maps to `.fit`.
- [low] The fix is an **internal ScrollView around the plan-list content** plus a
  **clip to the card bounds**, rather than (a) shrinking/eliding plan rows or
  (b) forcing `fitRowMinHeight` larger. **Why:** scrolling preserves access to
  every plan without hiding data, reuses the height the grid already computes,
  and is the smallest change; clipping is a belt-and-suspenders guarantee that
  content never paints outside the cell even mid-resize.
- [low] The card **header pins at top and the git footer pins at bottom**; only
  the capture rows + plan list scroll. **Why:** the header (project name + status
  counts) and footer (git branch) are the card's stable identity chrome — keeping
  them fixed while the variable-length plan list scrolls matches how list/detail
  cards conventionally behave and keeps the project identifiable while scrolling.
- [high] The decision is exposed as a pure
  `static func shouldScrollContent(constrainedHeight:) -> Bool` and unit-tested
  without a view. **Why:** every layout decision in this codebase
  (`columnCount(forWidth:)`, `fitColumnCount`, `effectiveLayoutMode`,
  `fitRowHeight`, `rowCount`) is a pure, view-free static helper with XCTest
  coverage; `ProjectCardTests` already asserts plain values rather than rendered
  views, so this matches the established testable-surface convention.
- [high] `constrainedHeight` is plumbed from the `fitHeight` the grid **already**
  computes, not recomputed in the card. **Why:** `BrowserWindow.cardGrid` is the
  single source of truth for the fit-mode per-row height (`fitRowHeight`); the
  card should consume that value, not duplicate the math.
- [low] `constrainedHeight` defaults to `nil` on `ProjectCard`. **Why:** keeps the
  initializer source-compatible for any preview/standalone call site and means
  the card defaults to natural (scroll) behavior unless the grid opts it into a
  fixed height.

### Discovered during execution
- [high] `shouldScrollContent` treats ANY non-nil `constrainedHeight` (including
  `0`) as "scroll", with the rule being a plain `constrainedHeight != nil`.
  **Why:** the grid only ever passes the non-nil `fitHeight` in fit mode (where
  the height is bounded below by `fitRowMinHeight = 160`) or `nil` in scroll
  mode; "constrained vs natural" is exactly the nil-ness, so no threshold/zero
  special-case is warranted. Added an explicit zero-height test to lock this in.
- [high] The scrollable middle content (capture rows + plan list) is factored
  into a single `@ViewBuilder private var scrollableContent` so the if/else in
  `body` doesn't duplicate it. **Why:** the segment prompt asked for a helper to
  avoid duplication; a computed `@ViewBuilder` property matches the file's
  existing style (`captureRows`, `captureControl`, `gitFooter`).
- [low] In the constrained (scroll-internal) branch the `ScrollView` wraps an
  inner `VStack(alignment: .leading, spacing: 10)` with `maxWidth: .infinity`
  leading alignment, mirroring the outer `VStack`'s spacing/alignment so the
  capture rows and plan list keep the same inter-element gap and left edge they
  have inline. **Why:** a bare `ScrollView { scrollableContent }` would collapse
  the 10pt spacing and lose the leading alignment the outer VStack provides.
- [high] No trailing `Spacer` inside the constrained branch — the `ScrollView`
  itself greedily fills the slack between the pinned header and footer. The
  natural-height (`nil`) branch keeps the existing `Spacer(minLength: 0)`
  byte-for-byte. **Why:** segment prompt's explicit instruction; preserves the
  unchanged scroll-mode layout while letting fit-mode cards fill their cell.
- [low] `.clipShape` (Step 4) and the final build/test gate (Step 5) were
  intentionally NOT done — they belong to a later segment per the segment prompt.
- [high] `.clipShape(RoundedRectangle(cornerRadius: 12))` (Step 4) is ordered
  `.background(...)` → `.clipShape(...)` → `.overlay(...stroke...)`. **Why:** the
  segment prompt's preferred ordering; clipping after the background means the
  card's content (including a scrolled body) is clipped to the rounded rect, and
  placing it before the overlay keeps the separator stroke rendering crisply on
  top of the clipped content rather than being clipped itself.

## Changes
- `Sources/Plans/ProjectCard.swift`:
  - Added pure `static func shouldScrollContent(constrainedHeight: CGFloat?) -> Bool`
    (`constrainedHeight != nil`) — the view-free, unit-tested scroll-vs-natural decision.
  - Added `var constrainedHeight: CGFloat? = nil` (declared before `onNewPlan` so the
    memberwise init is `ProjectCard(project:constrainedHeight:onNewPlan:)`).
  - Extracted the middle content (capture rows + plan list) into a
    `@ViewBuilder private var scrollableContent`. In `body`, when constrained the
    middle content is wrapped in a `ScrollView` (inner `VStack(.leading, spacing: 10)`,
    `maxWidth: .infinity`); header (+Divider) and trailing Divider+gitFooter stay
    pinned outside it. The `nil` (scroll) path is unchanged (keeps the trailing
    `Spacer(minLength: 0)`).
  - Added `.clipShape(RoundedRectangle(cornerRadius: 12))` ordered
    `.background(...)` → `.clipShape(...)` → `.overlay(...stroke...)` so content can
    never paint outside the card's rounded bounds (a no-op in scroll mode).
- `Sources/Plans/BrowserWindow.swift`: the card-grid `ForEach` now passes the
  already-computed `fitHeight` into `ProjectCard(project:constrainedHeight:onNewPlan:)`;
  the wrapper `.frame(height: fitHeight)` and the `if fitHeight == nil { Spacer }`
  scroll-mode logic are unchanged.
- `Tests/PlansTests/ProjectCardTests.swift`: 3 TDD unit tests for
  `shouldScrollContent(constrainedHeight:)` (non-nil → true, zero → true, nil → false).

**Tests:** `swift test --filter ProjectCardTests` → PASS (8). `swift test --filter
BrowserWindowTests` → PASS (54, unaffected). `swift build` → success.

**Observation (step 6):** deferred to `/plan-review` (yolo). Build + targeted tests
are green; a human should run the app, switch to "Fit to screen", and visually confirm
over-full cards scroll their plan list internally and no card breaks out of the grid.

## Notes
Autonomous (yolo) execution in an isolated git worktree on branch
`feature/038-add-scrolling-of-card-plans-when-needed`. Two plan-executor segments
(steps 1–3, then 4–5); the observation step (6) is deferred to review. All design
decisions recorded as assumptions above.
