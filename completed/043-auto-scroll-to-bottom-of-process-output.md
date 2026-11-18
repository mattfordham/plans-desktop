# Auto-scroll to bottom of process output when opening a running spinner

**ID:** 043
**Created:** 2026-06-09T09:15
**Type:** feature
**Status:** completed
**Branch:** feature/043-auto-scroll-to-bottom-of-process-output
**Completed:** 2026-06-09T09:30

## What
When clicking into a spinner to see running process output, automatically scroll to the bottom of the output.

## Why
Adds value by showing the user the latest process output immediately. The spinner's progress view (`RunProgressSheet`) already auto-scrolls to the bottom when *new* lines arrive (`.onChange(of: lines.count)`), but when the popover/sheet first opens against a run that already has buffered output, the scroll position defaults to the top — forcing the user to scroll down to find the latest activity. Scrolling to the bottom on first appearance makes the most relevant (newest) output visible without manual scrolling.

## How
- [x] Step 1: Add a pure, testable helper to `RunProgressSheet` (in `Sources/Plans/PlanDetailView.swift`) that, given the current `lines: [LoggedEvent]`, returns the id of the line to scroll to on appearance (the last line's id, or `nil` when empty). Add a unit test in `Tests/PlansTests/PlanDetailViewTests.swift` asserting it returns the last line's id for a non-empty list and `nil` for an empty list (TDD: write the failing test first).
- [x] Step 2: In `RunProgressSheet.logList`, add an `.onAppear` modifier on the `ScrollView` (alongside the existing `.onChange(of: lines.count)`) that uses the helper to scroll to the bottom line via `proxy.scrollTo(id, anchor: .bottom)` without animation (instant on first appearance), guarding against the empty case.
- [x] Step 3: Run the targeted test file (`swift test --filter PlanDetailViewTests`) and confirm it passes; build with `swift build` to confirm the view compiles.

## Verification
- Run `swift build` — the app compiles with no errors.
- Run `swift test --filter PlanDetailViewTests` — the new scroll-target helper test passes alongside existing tests.
- Behaviorally: open a spinner/popover for a running task that already has many output lines; the output view shows the bottom (latest) line immediately rather than starting at the top.

## Impact Scope
_Single file of production code (`Sources/Plans/PlanDetailView.swift`) plus its test (`Tests/PlansTests/PlanDetailViewTests.swift`); under the 3-file threshold, so no detailed Impact Scope table._

## Assumptions

### Initial (from elaboration)
- [high] The fix belongs in `RunProgressSheet.logList` in `Sources/Plans/PlanDetailView.swift`, which is the single shared output view used by both the card-row spinner popover and the detail sheet. **Why:** Research confirmed both the popover (ProjectCard.swift:464-502, :284-311) and the detail sheet (PlanDetailView.swift:70-94) present the same `RunProgressSheet`, and `logList` (PlanDetailView.swift:390-431) is the only view rendering the scrollable output. One change fixes both entry points.
- [high] Reuse the existing `ScrollViewReader` + `proxy.scrollTo(last.id, anchor: .bottom)` pattern already present for new-line auto-scroll, rather than introducing a new scrolling mechanism. **Why:** That exact pattern already exists at PlanDetailView.swift:425-429; mirroring it keeps the change minimal and consistent.
- [low] Use `.onAppear` (instant, no animation) for the initial scroll rather than `.task` with a sleep delay. **Why:** Research flagged both as options; `.onAppear` is simpler and the first appearance should feel instant (no animated scroll). If the scroll fails to land due to layout timing, `.task` with a tiny delay is the fallback. The source description did not specify animation behavior.
- [low] Extract the scroll-target decision into a pure helper to make it unit-testable under XCTest, since SwiftUI scroll behavior itself cannot be asserted without UI-testing infrastructure. **Why:** The project mandates TDD, but existing tests only cover pure helpers (e.g. `taskFileURL`); a pure helper is the testable seam for this view-internal behavior. This is a testing-strategy call the description didn't specify.

### Discovered during execution
- [high] Implemented `scrollTarget(for:)` as a `static func` on `RunProgressSheet` returning `lines.last?.id`. **Why:** Pure, view-construction-free seam; `RunProgressSheet`/`LoggedEvent` are already `internal`, so reachable via `@testable import Plans` without widening any access level.
- [high] Constructed test `LoggedEvent` values via the memberwise `LoggedEvent(event:)` init (its `id` is `let id = UUID()`, auto-assigned) and asserted against `lines.last?.id`. **Why:** Only the id needs to be checkable; no temp dir required for this pure test.
- [low] Initial `.onAppear` scroll calls `proxy.scrollTo(target, anchor: .bottom)` WITHOUT `withAnimation`, while the existing `.onChange(of: lines.count)` keeps its animated scroll. **Why:** First appearance should land instantly at the bottom; per-append updates stay animated as before.

## Changes
- `Sources/Plans/PlanDetailView.swift`: Added `static func scrollTarget(for lines: [LoggedEvent]) -> UUID?` to `RunProgressSheet` (returns the newest line's id, or `nil` when empty). Added an `.onAppear` modifier on the `logList` `ScrollView` that scrolls to that target with `proxy.scrollTo(target, anchor: .bottom)` and no animation, so opening the spinner against an already-running task jumps straight to the latest output instead of starting at the top. Existing animated `.onChange(of: lines.count)` new-line behavior is unchanged.
- `Tests/PlansTests/PlanDetailViewTests.swift`: Added `testScrollTargetReturnsLastLineIDForNonEmptyList` and `testScrollTargetReturnsNilForEmptyList` (written RED-first per TDD).
- Tests: `swift test --filter PlanDetailViewTests` → 6 tests, 0 failures. `swift build` → clean.

## Notes
- Existing new-line auto-scroll: `PlanDetailView.swift:425-429` (`.onChange(of: lines.count)`).
- Output line model: `LoggedEvent { id: UUID; event: RunEvent }` (`TaskRunner.swift:155-158`).
- No existing tests cover `RunProgressSheet`/`logList`.
