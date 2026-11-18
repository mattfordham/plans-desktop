# Make The Plan Rows Full Width/Bleed

**ID:** 087
**Created:** 2026-09-30T15:30
**Type:** feature
**Status:** completed
**Completed:** 2026-09-30T16:30
**Branch:** feature/087-make-the-plan-rows-full-width-bleed

## What
Make the plan rows full width/bleed

## Why
Adds visual polish by letting each plan row's zebra/hover band bleed edge-to-edge
within its project card. Today every row is held 14pt short of the card's rounded
edge by the card's outer horizontal gutter, so the tinted band floats in a channel
rather than reading as a full-width table row. Bleeding the band to the card edge
makes the list read as a cohesive, scannable table.

## How Summary
The plan rows already flex to full width and own a single continuous `.background`
band (`ProjectCard.planRow`), but the card wraps ALL its content — header, rows,
footer — in one `.padding(.horizontal, 14)` (`ProjectCard.swift:394`), which insets
the row band. The fix removes that card-wide horizontal gutter and re-applies the
14pt inset individually to the non-row elements (header, footer, empty-state text,
"Backlogged" label, capture rows) so ONLY the plan-row band bleeds to the card's
rounded inner edge. The 14pt value is promoted to a single `cardHorizontalPadding`
constant, and the per-row internal inset (`rowHorizontalPadding`) is bumped from 8
to 14 so the bled band's text stays vertically aligned with the header/footer
content instead of sitting flush against the card edge. The card's existing
`.clipShape(RoundedRectangle(cornerRadius: 12))` clips the full-bleed band to the
rounded corners for free.

**Files of note:**
- `Sources/Plans/ProjectCard.swift` — card layout; holds the outer 14pt gutter, the
  `RowColumns` constants, and every element that must be re-inset.
- `Tests/PlansTests/ProjectCardTests.swift` — value-based tests over the layout
  constants (`rowHorizontalPadding`, new `cardHorizontalPadding`).

## How
- [x] Step 1: Add value-based tests in `ProjectCardTests.swift` (RED): assert a new `ProjectCard.rowColumns.cardHorizontalPadding > 0`, and assert `rowColumns.rowHorizontalPadding >= rowColumns.cardHorizontalPadding` so the bled row band's text stays aligned with the re-inset header/footer content.
- [x] Step 2: In `ProjectCard.swift`, add a `cardHorizontalPadding: CGFloat = 14` field to the `RowColumns` struct (single source of truth for the card gutter) and bump `rowHorizontalPadding` from `8` to `14` so the bled band keeps a comfortable text inset. (GREEN for Step 1.)
- [x] Step 3: In `ProjectCard.body`, remove the card-wide `.padding(.horizontal, 14)` (`ProjectCard.swift:394`), leaving `.padding(.top, 14)` and `.padding(.bottom, 14)` in place, so the plan-row band can extend to the card's rounded inner edge.
- [x] Step 4: Re-apply `.padding(.horizontal, ProjectCard.rowColumns.cardHorizontalPadding)` to every non-row element so only the rows bleed: `header`, `footer`, the empty-state `Text` in `body(for:)`, the "Backlogged" section label in `backlogSection`, and `captureRows`. Leave the `Divider()`s and the plan-row `VStack` un-inset.
- [x] 👁 Step 5: Build and run the app; confirm in the browser window that the plan-row zebra/hover bands now reach the card's rounded edges while the project name, count badges, git footer, and star/focus toggles remain inset and aligned with the row text — in both scroll mode and fit-to-screen (inner ScrollView) mode.

## Verification
- `swift test --filter ProjectCardTests` passes (the new constant + alignment assertions).
- In the running app, each plan row's tinted band bleeds to the card's rounded
  inner edges (clipped to the corners) rather than stopping 14pt short.
- The card header (project name, count badges), footer (git branch, star/focus
  toggles), empty-state text, and "Backlogged" label stay inset by 14pt and remain
  horizontally aligned with the plan-row text.
- No regression to fit-to-screen mode: rows still clear the card-internal overlay
  scroller (trailing `scrollerClearance` untouched).

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/ProjectCard.swift` — remove card-wide horizontal gutter; add `cardHorizontalPadding`; bump `rowHorizontalPadding`; re-inset header/footer/empty-state/backlog-label/captureRows.
- [ ] `Tests/PlansTests/ProjectCardTests.swift` — add constant + alignment tests.

### Related Files (may need updates)
- `Sources/Plans/BrowserWindow.swift` — hosts the card grid; NOT changed (grid padding / scroller clearance left intact per the chosen interpretation).

### Endpoints/UI Affected
- Surface B browser window project cards — plan rows render full-bleed within each card.

## Assumptions

### Initial (from elaboration)
- [low] Interpreted "plan rows full width/bleed" as the per-row zebra/hover BAND bleeding to the card's inner rounded edges (removing the card's 14pt horizontal gutter around rows), NOT making the cards themselves edge-to-edge in the window (which would mean removing `BrowserWindow.gridPadding`). **Why:** "plan rows" most literally names the rows, and the rows already flex to full width — only the card gutter holds the band in; this is the lower-risk change the research recommended as interpretation (a).
- [low] Kept the card header and footer inset by 14pt while only the rows bleed, rather than making all card content flush. **Why:** a card with flush header/footer content looks broken; research flagged this as the main pitfall, so re-insetting non-row elements is the intended shape.
- [low] Bumped `rowHorizontalPadding` from 8 to 14 (matching the card gutter) so the bled row text aligns with the re-inset header/footer content instead of sitting flush against the card edge. **Why:** aligning the row text with the header/footer keeps the layout looking deliberate; the existing `testBandHasHorizontalPaddingOnBothEdges` asserts only `> 0`, so this stays green.
- [high] Followed the project's value-based test convention (assert layout constants, do not instantiate the SwiftUI view). **Why:** `ProjectCardTests.swift` establishes this pattern for the whole card — the view's rendered output is impractical to assert directly.

### Discovered during execution
- [high] Applied the card-gutter re-inset to each non-row element via a trailing `.padding(.horizontal, ProjectCard.rowColumns.cardHorizontalPadding)` on the element's own container (`header` HStack, `footer` HStack, empty-state `Text`, the "Backlogged" label HStack, and the `captureRows` VStack), leaving the two `Divider()`s and both plan-row `VStack(spacing: 2)`s (active + backlog) un-inset so only the bands bleed. **Why:** matches the segment's explicit element list and keeps the backlog rows bleeding like the active rows; the actual code structure matched the research notes exactly, so no adaptation was needed.

## Changes

### `Sources/Plans/ProjectCard.swift`
- Added `cardHorizontalPadding: CGFloat = 14` to the `RowColumns` struct as the single
  source of truth for the card's horizontal gutter, with an explanatory doc comment.
- Bumped `rowHorizontalPadding` from `8` to `14` so the now-bled row band keeps a
  comfortable text inset aligned with the re-inset header/footer content.
- Removed the card-wide `.padding(.horizontal, 14)` from `body` (kept `.padding(.top, 14)`
  and `.padding(.bottom, 14)`), letting the plan-row band bleed to the card's rounded
  inner edge (clipped to the corners by the existing `clipShape`).
- Re-applied `.padding(.horizontal, ProjectCard.rowColumns.cardHorizontalPadding)` to the
  non-row elements only: `header`, `footer`, the empty-state `Text` in `body(for:)`, the
  "Backlogged" label HStack in `backlogSection` (label only, so backlog rows still bleed),
  and the `captureRows` VStack. The two `Divider()`s and both plan-row `VStack(spacing: 2)`s
  (active + backlog) were left un-inset.

### `Tests/PlansTests/ProjectCardTests.swift`
- Added `testCardHorizontalPaddingIsPositive` and
  `testRowInsetKeepsBandTextAlignedWithCardContent` (value-based, matching the file's
  no-view-instantiation convention).

### Test status
- `swift test --filter ProjectCardTests`: 29 executed, 0 failures. `swift build`: succeeded.

### Review fix
- Step 5 observation: the band sat flush against the card's left border. Added
  `rowBandLeadingMargin` (6pt, applied outside the band in `planRow`) and reduced
  `rowHorizontalPadding` back to 8 so margin + inset = the 14pt card gutter; tests
  updated (`testRowBandHasLeadingMargin`, alignment now asserts equality). User confirmed.

## Notes
_Additional context_
