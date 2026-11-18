# Adjust Card Right Padding So Action Buttons Don't Interfere With Scroll Bar

**ID:** 046
**Created:** 2026-06-10T00:00
**Type:** bug
**Status:** completed
**Branch:** fix/046-adjust-card-right-padding-scrollbar
**Completed:** 2026-06-11T00:00

## What
Adjust the right padding of cards so the action buttons don't interfere with the scroll bar in the panel.

When the panel's scroll bar appears (macOS overlay scroller), it renders at the window's right edge and overlaps the action buttons (`RowActionGlyph`) on the trailing edge of the rightmost column of cards. The grid needs additional trailing inset so the cards — and their buttons — sit clear of where the scroll bar renders, keeping the buttons fully visible and clickable.

## Why
Improves reliability and usability: the per-row action glyphs in the rightmost card column are currently overlapped by the overlay scroll bar when the browser panel scrolls, making them hard to see and click. Reserving horizontal space for the scroller restores full visibility and a clean hit target.

## How
- [x] Add a trailing inset to the scrollable grid content in `BrowserWindow.swift` so the rightmost cards clear the overlay scroller. The outer `ScrollView` (line ~409) wraps `fitCardGrid`/`variableCardGrid`, which apply `.padding(Self.gridPadding)` (16pt, line ~555). Add ~`15pt` extra trailing padding (the macOS overlay scroller width) — e.g. apply `.padding(.trailing, scrollerClearance)` to the grid content (or bump the trailing component of `gridPadding`), keeping the existing 16pt on the other three edges.
- [x] Define a named constant for the scroller width (e.g. `private static let scrollerClearance: CGFloat = 15`) near `gridPadding` in `BrowserWindow.swift` rather than hard-coding the literal, matching the existing `gridPadding` convention.
- [x] Apply the same trailing clearance to the inner card `ScrollView` in `ProjectCard.swift` (lines ~138–143), which only appears in fit-to-screen mode when `constrainedHeight != nil`: add `.padding(.trailing, …)` to its content so the card-internal overlay scroller also clears the per-row action buttons.
- [ ] 👁 Build and run the app, open the browser window, and scroll so the overlay scroll bar appears in both scroll mode and fit-to-screen mode; confirm the action buttons in the rightmost column (and inside an over-full card) are no longer overlapped and remain clickable.

## Verification
Verify the overlay scroll bar no longer overlaps the trailing-edge action buttons in the browser panel: with enough projects to force scrolling, the rightmost column's `RowActionGlyph` buttons stay fully visible and clickable in both scroll mode and fit-to-screen mode. No regression to card spacing when no scroll bar is present. Existing tests pass (`swift test`).

## Impact Scope
_Fewer than 3 files affected — section skipped._

## Assumptions

### Initial (from elaboration)
- [low] The "panel" refers to the browser window's outer scrollable grid (`BrowserWindow` `ScrollView`), not the menu bar panel. **Why:** The cards with per-row action buttons (`RowActionGlyph`) and the scrollable grid both live in the `BrowserWindow`/`ProjectCard` surface; the menu bar panel does not render these action-button cards.
- [low] 15pt is the right clearance value for the macOS overlay scroller. **Why:** macOS overlay scrollers are conventionally ~15pt wide; research found no existing constant, so this is the standard value, exposed as a named constant for easy tuning if it looks off when observed.
- [high] Add trailing inset to the grid content rather than per-card padding. **Why:** The outer `ScrollView` scroller overlaps the rightmost column at the window edge, so reserving space once at the grid's trailing edge clears all affected cards uniformly without altering inter-card spacing; the inner card `ScrollView` gets the same treatment for the fit-mode internal scroller (parallels the #038 internal-scroll fix).

### Discovered during execution
- [high] Used a separate `.padding(.trailing, scrollerClearance)` modifier applied AFTER the symmetric `.padding(Self.gridPadding)`, rather than bumping `gridPadding`'s trailing component. **Why:** `gridPadding` is a single symmetric value consumed in several places (including the pure column-count math `(width - 2 * gridPadding)` and the row-height chrome helpers in tests). Splitting it into per-edge components would ripple into that math and the tests; a separate additive trailing modifier keeps the existing 16pt on all four edges semantically intact and isolates the #046 change to a purely visual trailing inset.
- [high] Defined a single shared constant `BrowserWindow.scrollerClearance` (internal `static let`, default access) and referenced it from `ProjectCard` rather than duplicating a constant. **Why:** Matches the existing pattern where `ProjectCard` already reaches into `BrowserWindow` static helpers/constants; a single source of truth keeps the inner card scroller and the outer grid scroller clearance in lockstep. The existing `gridPadding`/`gridSpacing` are also default-access `static let`s, so `scrollerClearance` follows the same convention (no `private`).
- [high] Did NOT add the trailing clearance to the hidden `measurementLayer` (the third `.padding(Self.gridPadding)` site, at opacity 0 / no hit-testing). **Why:** That parallel layer exists solely to measure cards' natural heights at the visible column widths; adding asymmetric trailing padding there would shift the measured widths and could desync the natural-height measurement from the visible grid. Only the two visible grids (`fitCardGrid`, `variableCardGrid`) received the inset.

## Changes
- `BrowserWindow.swift`: Added `static let scrollerClearance: CGFloat = 15` next to `gridPadding`. Applied `.padding(.trailing, Self.scrollerClearance)` after the symmetric `.padding(Self.gridPadding)` on both visible grids — `fitCardGrid` (~line 555) and `variableCardGrid` (~line 676). Left the hidden `measurementLayer` untouched so card height measurement stays in sync with the visible column widths.
- `ProjectCard.swift`: Added `.padding(.trailing, BrowserWindow.scrollerClearance)` to the inner fit-mode `ScrollView` content (~lines 138–143, active when `constrainedHeight != nil`), so the card-internal overlay scroller also clears the per-row action buttons. References the single shared constant rather than duplicating the value.
- `swift build` succeeds. No new tests added — this is a visual trailing-inset change not covered by the existing layout/row-height unit tests.

## Notes
- Outer scroll bar: `BrowserWindow.swift` `ScrollView` at ~line 409; grid padding `gridPadding = 16` at ~line 31, applied at ~line 555.
- Action buttons: `RowActionGlyph` in `ProjectCard.swift` (~line 595), 22pt glyph + `.padding(.leading, 8)`, positioned in the trailing grid column.
- Inner card scroll (fit mode only): `ProjectCard.swift` ScrollView at ~lines 138–143, active when `constrainedHeight != nil`.
