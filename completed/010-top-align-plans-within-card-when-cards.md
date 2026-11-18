# Top Align Plans Within Card When Cards Stretched By Grid Layout

**ID:** 010
**Created:** 2026-06-05T11:00
**Type:** refactor
**Status:** completed
**Completed:** 2026-06-05T11:12
**Branch:** refactor/010-top-align-plans-within-card-when-cards

## What
Top align plans within card when cards stretched by grid layout.

When project cards are laid out in the responsive `LazyVGrid`, a grid cell is sized to its row's tallest card. If a card's content (header + plan rows) is shorter than the cell, its plan list should stay pinned to the TOP of the card rather than drifting toward the vertical center. This is the in-card counterpart to the card-level top-anchoring already done in #009 (the `VStack { ProjectCard; Spacer }` wrapper in `BrowserWindow.cardGrid`).

## Why
Improves maintainability and visual consistency: plan rows should read as a top-anchored table in every card regardless of how the grid stretches the cell. Today the card's main `VStack` has no trailing slack-absorber, so if anything (now or a future change that lets the card fill its cell) gives the card extra vertical height, the header/divider/plan-rows would distribute through the available space instead of hugging the top. Adding an explicit top anchor makes the intent unambiguous and matches the proven pattern from #009.

## How
- [x] Step 1: In `Sources/Plans/ProjectCard.swift`, add a trailing `Spacer(minLength: 0)` as the last child of the card's main `VStack(alignment: .leading, spacing: 10)` (the one in `body`, around lines 45–50) so header + divider + plan body are pushed to the top and the spacer absorbs any extra card height. Keep `spacing: 10` between the real content; the spacer takes the slack.
- [x] Step 2: Confirm the card's `.frame(maxWidth: .infinity, alignment: .leading)` (line 52) does not need a `maxHeight` change — leave height unconstrained so the card still hugs content when the cell is content-sized; the new Spacer only does work when the card is given extra height. Add a short comment explaining the top-anchor intent (mirroring the comment in `BrowserWindow.cardGrid`).
- [x] Step 3: Verify the `body(for:)` plan `Grid` (lines 106–110) keeps `.topLeading` alignment and tight `verticalSpacing: 2`, so rows stay packed at the top under the header — no change expected, just confirm the Spacer is OUTSIDE/after the Grid, not interleaved with rows.
- [x] Step 4: Build the package (`swift build`) to confirm the SwiftUI view still compiles. Run only the existing `BrowserWindowTests` if any layout-related assertions exist; do not run the full suite.
- [x] 👁 Step 5: Run the app and resize the browser window so cards reflow into a multi-column grid with uneven card heights; visually confirm that in a stretched cell, the plan rows stay top-aligned directly under the header rather than centering vertically.

## Verification
- In a multi-column grid where one card is much taller than a sibling, the shorter card's header and plan rows hug the top of the (stretched) cell.
- A card whose content fits its cell looks unchanged from before (no extra gap introduced at the bottom of content-sized cards).
- `swift build` succeeds; no regression in plan-row selection/highlight behavior.

## Impact Scope
_Single file (`Sources/Plans/ProjectCard.swift`); Impact Scope section not required (<3 files)._

## Assumptions

### Initial (from elaboration)
- [low] Placing a single trailing `Spacer(minLength: 0)` inside `ProjectCard`'s main `VStack` is the right level to top-align plan content (vs. wrapping only the inner plan `Grid` in a VStack+Spacer). **Why:** Research recommended a VStack+Spacer around the Grid, but the whole card already lives in a content-sizing wrapper in `BrowserWindow.cardGrid`; anchoring at the card's main VStack is simpler, covers header+divider+body uniformly, and mirrors the #009 card-level pattern. If review prefers scoping the spacer to just the plan Grid, that's an easy local change.
- [high] Leave the card frame height unconstrained (no `maxHeight`). **Why:** `ProjectCard.body` deliberately sets no `maxHeight` (documented in #009 / BrowserWindow comments) — adding one would re-introduce stretch of the card chrome. A `Spacer` is the established slack-absorber here.
- [low] No automated test is added for this change. **Why:** It is a layout-only SwiftUI adjustment with no pure logic to assert; verification is visual (Step 5). The repo's tests cover `columnCount(forWidth:)` math, not view geometry.

### Discovered during execution
- [high] Anchored the Spacer at the card's main `VStack` (after `body(for: rows)`), not scoped to just the inner plan `Grid`. **Why:** Confirmed the initial-assumption choice — the card already sits in `BrowserWindow.cardGrid`'s content-sizing VStack+Spacer wrapper, so anchoring the whole card's content (header + divider + body) uniformly mirrors the #009 pattern and keeps the Spacer a clean sibling of the Grid rather than interleaved with them.

## Changes
- `Sources/Plans/ProjectCard.swift`: Added a trailing `Spacer(minLength: 0)` as the last child of the card's main `VStack(alignment: .leading, spacing: 10)` in `body`, after `body(for: rows)`, with an explanatory top-anchor comment mirroring `BrowserWindow.cardGrid`. Card frame left height-unconstrained (no `maxHeight`), so content-sized cards are unchanged while stretched cells now keep header + divider + plan rows pinned to the top.
- Verified `swift build` succeeds (one pre-existing unrelated `PlansStore.swift:70` Sendable warning) and `swift test --filter BrowserWindowTests` passes (28 tests, 0 failures).

## Notes
This is a SwiftUI/AppKit macOS app (Swift Package), not a web app. Card grid lives in `Sources/Plans/BrowserWindow.swift` (`cardGrid`), each card in `Sources/Plans/ProjectCard.swift`. Related prior work: #009 (responsive columns + card-level top-anchor) and commits "Responsive card grid…" / "Align plan rows into a Grid table…".
