# Spacing A Little Tight Around The Spinner Row

**ID:** 032
**Created:** 2026-06-06T00:00
**Type:** refactor
**Status:** completed
**Completed:** 2026-06-07T00:00
**Branch:** refactor/032-spacing-a-little-tight-around-the-spinner

## What
Spacing a little tight around the spinner row.

The in-flight capture row (small `ProgressView` spinner + run description, e.g. "New Plans tweaks….") in a `ProjectCard` sits cramped against the divider above it and the plan-rows body below it. Give the spinner row a bit more breathing room vertically so it doesn't feel crowded against its neighbors.

Reference: the row is rendered by `captureRow(_:)` / `captureRows` in `Sources/Plans/ProjectCard.swift`, stacked between the header `Divider()` and `body(for: rows)` inside the card's main `VStack(alignment: .leading, spacing: 10)`.

## Why
Improves maintainability and visual polish: the in-flight capture row currently
has no vertical padding while sibling plan rows carry `.padding(.vertical, 5)`,
so the spinner row reads as cramped and visually inconsistent with the rest of
the card. Matching the established row-padding convention makes the card layout
uniform and gives the spinner row breathing room against the divider above and
the plan-rows body below.

## How
- [x] Add `.padding(.vertical, 5)` to the `captureRow(_:)` `HStack` in `Sources/Plans/ProjectCard.swift` (place it on the modifier chain before `.contentShape(Rectangle())`), mirroring the `.padding(.vertical, 5)` already used by `planRow`
- [x] Build the app (`swift build`) to confirm it compiles cleanly

## Verification
- The spinner/capture row ("New Plans tweaks….") has visibly more vertical space above and below it, no longer crowding the divider or the "No outstanding plans" body.
- The capture row's vertical breathing room matches the plan rows' spacing.
- `swift build` succeeds; no layout regressions in the card.

## Impact Scope
_Single file (`Sources/Plans/ProjectCard.swift`) — Impact Scope section not required (<3 files)._

## Assumptions

### Initial (from elaboration)
- [high] Fix by adding `.padding(.vertical, 5)` to the `captureRow` HStack rather than changing the `captureRows` container's `spacing`. **Why:** Research found `planRow` uses the exact same `.padding(.vertical, 5)` (line 452) and the card's bottom-padding logic explicitly accounts for that 5pt convention — per-row padding is the established pattern, and bumping container spacing would only space stacked capture rows from each other, not from the divider/body.
- [high] 5pt vertical padding (matching plan rows) is the right amount of breathing room. **Why:** The capture row is a visual peer of the plan rows; matching their padding keeps the card uniform and avoids introducing a new magic number.

### Discovered during execution
_To be filled during execution_

## Changes
- `Sources/Plans/ProjectCard.swift`: Added `.padding(.vertical, 5)` to the `captureRow(_:)` `HStack` (after its closing brace, before `.contentShape(Rectangle())`), matching the `.padding(.vertical, 5)` on `planRow`. The in-flight capture/spinner row now has the same vertical breathing room as the plan rows instead of sitting flush against the divider and body. Verified with `swift build` (clean compile).

## Notes
Captured from a screenshot of the menu bar / project card showing the "New Plans tweaks…." spinner row above "No outstanding plans".
