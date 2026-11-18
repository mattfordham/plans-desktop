# Misc Card And Menu Bar Tweaks

**ID:** 014
**Created:** 2026-06-05T00:00
**Type:** chore
**Status:** completed
**Completed:** 2026-06-05T13:10
**Branch:** chore/014-misc-card-and-menu-bar-tweaks

## What
Some misc tweaks:
- Padding on the bottom of cards appears too big. Should be even compared to top.
- In card header, show all status icons with 0 if no plans with status. That said, if 0, make the color of both the icon and text 50% white.
- Remove persistent background from menu bar icon status output

## Why
Maintains project health by polishing the dashboard's visual consistency: cards get balanced top/bottom spacing, the card header gives an at-a-glance view of every status (dimmed when empty rather than disappearing), and the menu bar status badge loses its distracting pill background for a cleaner read.

## How
- [x] Step 1: Fix uneven card bottom padding in `Sources/Plans/ProjectCard.swift`. The card's VStack uses uniform `.padding(14)` (line 61), but each plan row carries `.padding(.vertical, 5)` (line 180), so the last row adds ~5pt below itself, making the bottom gap (~19pt) read larger than the header's 14pt top gap. Replace `.padding(14)` with explicit edge padding that compensates — keep top/leading/trailing at 14 and set bottom to 9 (`14 − 5`) so the visible space under the last row matches the space above the header.
- [x] Step 2: Show all statuses in the card header (including zero counts) in `ProjectCard.swift`. Change the `statusCounts` computed property (lines 34–39) to map over `TaskStatus.glanceOrder` returning `(status, project.counts[status] ?? 0)` for every status instead of `compactMap`-dropping zero/absent ones. Update the doc comment (lines 32–33 and the class-level comment at lines 8–11) to reflect that zero-count statuses are now shown dimmed rather than dropped.
- [x] Step 3: Dim zero-count status badges to 50% white in the header `ForEach` (lines 82–92 of `ProjectCard.swift`). For each entry, when `entry.count == 0` set the icon's `.foregroundStyle(Color.white.opacity(0.5))` and the count text's `.foregroundStyle(Color.white.opacity(0.5))`; otherwise keep the existing `entry.status.glanceColor` icon and `.secondary` count text. (Literal "50% white" per the request — `Color.white.opacity(0.5)`.)
- [x] Step 4: Remove the persistent pill background from the menu bar status output in `Sources/Plans/MenuBarLabel.swift`. In `MenuBarLabelContent` (lines 119–127) delete the `.background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08)))` modifier. Keep the `.padding(.horizontal, 5)` / `.padding(.vertical, 2)` so badge spacing is unchanged. Update the surrounding comments (lines 84–92 and 119–121) that describe the "pill background" so they no longer reference it.
- [x] 👁 Step 5: Build and run the app; verify (a) card top and bottom spacing look even, (b) the card header shows every status with zero-count ones dimmed to 50% white, and (c) the menu bar status badge no longer has a background pill.

## Verification
- Card top padding (above the project name) and bottom padding (below the last plan row) appear visually even.
- The card header shows all statuses from `glanceOrder`; statuses with 0 plans appear with both icon and count at 50% white opacity, non-zero ones unchanged.
- The menu bar icon's status badge renders with no rounded background behind it.
- `swift build` succeeds with no new warnings; no regressions in card/menu-bar layout.

## Impact Scope
_Not applicable — only 2 files affected._

## Assumptions

### Initial (from elaboration)
- [low] Tweak #1 fix is to reduce the card's bottom padding to 9pt (14 − the 5pt per-row vertical padding) rather than removing the trailing `Spacer` or changing row padding. **Why:** Research showed the asymmetry comes from the last row's `.padding(.vertical, 5)` stacking with the card's uniform `.padding(14)`; compensating the card bottom padding is the smallest, lowest-risk change and preserves the documented top-anchoring `Spacer` behavior. The exact value may need a small visual tweak during the observation step.
- [low] "50% white" is interpreted literally as `Color.white.opacity(0.5)` for both the dimmed icon and text, not appearance-adaptive `Color.primary.opacity(0.5)`. **Why:** The request explicitly said "50% white"; taken at face value. If it looks wrong in light mode this can be revisited during observation.
- [high] Tweak #3 is a straight deletion of the `.background(...)` pill modifier, keeping existing padding. **Why:** Research confirmed a single, clearly-identified `.background` modifier with no dependents; removal is the obvious fix and matches the request ("remove persistent background").

### Discovered during execution
- [high] Used `.padding(.top, 14)` + `.padding(.horizontal, 14)` + `.padding(.bottom, 9)` (chained modifier form) for the asymmetric card padding rather than an `EdgeInsets`. **Why:** The chained form is more readable and matches the per-edge padding style already used elsewhere (e.g. plan rows use `.padding(.vertical, 5)`); functionally identical to an `EdgeInsets`.
- [high] In the zero-count count-text ternary I used `Color.secondary` (a concrete `Color`) instead of the prior `.secondary` (`HierarchicalShapeStyle`). **Why:** A `?:` requires both branches to be the same type; `Color.white.opacity(0.5)` is a `Color`, so the non-zero branch had to be a `Color` too. `Color.secondary` is the direct equivalent of the previous `.secondary` foreground style.
- [low] Updated/removed two extra pill references beyond the two the task named (the `renderedImage` doc comment mentioning "the subtle pill background" and the empty-state inline comment "(no pill)"). **Why:** Leaving them would be stale/misleading after the pill removal; both are comment-only edits within the two in-scope files.

## Changes
- `Sources/Plans/ProjectCard.swift`:
  - Replaced uniform `.padding(14)` with `.padding(.top, 14)` + `.padding(.horizontal, 14)` + `.padding(.bottom, 9)` so bottom spacing (which previously stacked with each row's `.padding(.vertical, 5)`) reads even with the top.
  - `statusCounts` now maps over all of `TaskStatus.glanceOrder` (`project.counts[status] ?? 0`) instead of `compactMap`-dropping zero/absent statuses; doc comments updated.
  - Header `ForEach` dims zero-count icon and count text to `Color.white.opacity(0.1)` (lowered from 0.5 → 0.25 → 0.1 during review per user feedback); non-zero entries keep `glanceColor` / `Color.secondary`.
- `Sources/Plans/MenuBarLabel.swift`:
  - Removed the `.background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))` pill from `MenuBarLabelContent`; kept `.padding(.horizontal, 5)` / `.padding(.vertical, 2)`. Updated pill-reference comments.
- `swift build` succeeds (one pre-existing unrelated warning).

## Notes
Tech stack: native macOS app, Swift + SwiftUI. Build with `swift build`. Two files: `Sources/Plans/ProjectCard.swift` (tweaks 1–2) and `Sources/Plans/MenuBarLabel.swift` (tweak 3).
