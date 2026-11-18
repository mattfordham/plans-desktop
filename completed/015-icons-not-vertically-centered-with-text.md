# Icons Are Not Vertically Centered With Text

**ID:** 015
**Created:** 2026-06-05T17:06
**Type:** bug
**Status:** completed
**Completed:** 2026-06-05T17:30
**Branch:** fix/015-icons-not-vertically-centered-with-text

## What
Icons are not vertically centered with text... they should be. (See task row layout: the status circle icon sits slightly above/below the baseline of the row's text such as "008 [feature] Mobile-Capture Auto-Ingest Inbox".)

## Why
Improves visual polish by fixing the misaligned status icon: the leading circle currently sits above the visual center of the row text because the plan-row `Grid` is `.topLeading`-aligned and the `.imageScale(.large)` icon is taller than the body text, so its top pins to the text's top instead of centering on the text line.

## How
- [x] Step 1: In `Sources/Plans/ProjectCard.swift` (the `Grid(...)` at line 125), change the Grid alignment from `.topLeading` to `.firstTextBaseline` so each plan row's icon aligns to the first line of text rather than the top of the cell. Update the adjacent comment (lines 118–120) to reflect that rows now baseline-align the icon to the first text line (still top-anchored for multi-line titles, since `.firstTextBaseline` uses the first line).
- [x] Step 2: Verify the icon `Image` in `planRow` (lines 160–164) keeps its `.frame(width: 20, alignment: .center)` (horizontal sizing only) and that no explicit height fights the new baseline alignment. If `.firstTextBaseline` leaves the large circle optically high/low, add a small `.alignmentGuide(.firstTextBaseline)` or `.baselineOffset` tweak on the icon only, tuned to sit it on the text's optical center.
- [x] 👁 Step 3: Build and run the app; confirm in a plan card that each status circle (hollow, dotted, filled variants) is vertically centered with its row text (e.g. "008 [feature] Mobile-Capture Auto-Ingest Inbox"), and that multi-line titles still top-anchor sensibly. (Observation — visual check the agent cannot perform.)

## Verification
- Status circle icons appear vertically centered with the adjacent row text in plan cards.
- All status symbol variants (e.g. `circle`, `circle.dotted`, filled) center consistently.
- Multi-line plan titles still align the icon to the first line (no regression in the table look).
- App builds cleanly via `./build.sh`.

## Impact Scope
_Single file (`Sources/Plans/ProjectCard.swift`); Impact Scope section not required._

## Assumptions

### Initial (from elaboration)
- [low] Use `.firstTextBaseline` Grid alignment (rather than `.center`) as the centering fix. **Why:** It's the SwiftUI idiom for aligning an SF Symbol icon with text and preserves the existing intentional top-anchor behavior for multi-line titles noted in the line 118–120 comment; `.center` would center the icon against the whole multi-line block, regressing that intent. A `.baselineOffset` fallback is included in Step 2 in case the large icon still looks optically off.
- [low] Scope limited to `ProjectCard.swift` plan rows only. **Why:** The reported screenshot shows the plan-card row layout; `PlanDetailView.swift` and `MenuBarView.swift` use similar icon+text patterns but were not reported as misaligned, so they're left unchanged to keep the fix minimal. The reviewer can widen scope if the same issue appears there.

### Discovered during execution
- [low] Used an `.alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }` on the icon (mapping its vertical center onto the row's first-text-baseline) rather than a plain `.firstTextBaseline` or a tuned `.baselineOffset`. **Why:** The `.large` SF Symbol circle is taller than `.body` text; a bare `.firstTextBaseline` pins the glyph's own baseline to the text baseline, leaving the circle sitting optically high. Center-on-baseline is self-documenting and avoids a magic-number offset. Tagged low-confidence because this is an empirical visual call that could not be observed in this agent (GUI render) — needs review.
- [high] `Grid(alignment:)` takes an `Alignment`, which has no `.firstTextBaseline` member; used `Alignment(horizontal: .leading, vertical: .firstTextBaseline)`. **Why:** Build error confirmed `.firstTextBaseline` is a `VerticalAlignment`, not an `Alignment`, so the composite initializer is required to preserve leading horizontal alignment.
- [high] Switched from `.firstTextBaseline` Grid alignment + a center-on-baseline `.alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }` on the icon (which pushed the icon BELOW the text center) to plain `Alignment(horizontal: .leading, vertical: .center)` Grid alignment with the icon's alignment guide removed entirely. **Why:** The text baseline sits near the BOTTOM of the glyphs, not the text's vertical center; mapping the icon's center onto that baseline drops the circle low. `.center` is the correct primitive for vertically centering the icon with the row text. **Tradeoff:** multi-line titles now center the icon on the whole title cell rather than the first line — acceptable for the predominantly short, single-line titles, and correct single-line centering is the reported priority.

## Changes
- `Sources/Plans/ProjectCard.swift`:
  - Changed the plan-row `Grid` vertical alignment from `.topLeading` to `Alignment(horizontal: .leading, vertical: .center)` so each GridRow centers the leading status icon vertically with its row text. Updated the leading comment block to describe `.center` centering (kept the `horizontalSpacing: 0` explanation).
  - Icon `Image` in `planRow` keeps `.frame(width: 20, alignment: .center)` (horizontal sizing only); no alignment guide or height added.
- Review-time correction: a first attempt used `.firstTextBaseline` Grid alignment plus an `.alignmentGuide(.firstTextBaseline) { d[VerticalAlignment.center] }` on the icon, which pushed the circle BELOW the text center (the baseline sits near the bottom of the glyphs, not the text's vertical center). Replaced with plain `.center` alignment, which centers correctly. User confirmed visually.
- Build: `./build.sh` → Build complete (3.65s). No new warnings (one pre-existing unrelated `PlansStore` Sendable warning).
- Commits on branch: 6f82c22 (initial baseline attempt), aa17e93 (`.center` correction). (An `install.sh` file the fix commit accidentally swept in was removed during review; it remains untracked at the repo root, unrelated to this task.)

## Notes
Reported with a screenshot showing three task rows where the leading status circle icons appear misaligned vertically relative to the row text.
