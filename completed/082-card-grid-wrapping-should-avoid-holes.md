# Card Grid Wrapping Should Avoid Holes

**ID:** 082
**Created:** 2026-09-23T20:10
**Type:** bug
**Status:** completed
**Branch:** fix/082-card-grid-wrapping-should-avoid-holes
**Completed:** 2026-09-24T09:35

## What
Wrapping should always prefer to not have holes. So in this case, I would expect it to remain a 2x2 grid.

(Screenshot: the browser window shows 4 project cards laid out as a 3-column top row plus a single card wrapped onto a second row, leaving a "hole" — three empty column slots in the last row. With 4 cards, a balanced 2x2 grid would avoid the hole.)

## Why
Improves the browser dashboard's visual balance by never leaving a sparsely-filled last row when a more balanced grid (e.g. 2x2 for four cards) fits the same viewport. A lone card stranded beside three empty slots reads as broken; keeping the grid balanced makes the layout feel intentional.

## How Summary
The bug lives in a single pure decision: `BrowserWindow.columnCount(forWidth:cardCount:)` maximizes the column count to whatever the viewport width allows (then clamps down only to the card count), with no notion of "does this leave a sparse last row?". The fix adds a balancing step inside that same pure function: among candidate column counts from the width-capacity down to a near-square floor (`ceil(sqrt(cardCount))`), pick the largest count whose last row is completely full; if none is completely full, keep the width-capacity count. Both layout modes (`fitCardGrid` and the masonry `variableCardGrid`) consume this one integer, so the single change fixes both. Driven by TDD via `Tests/PlansTests/BrowserWindowTests.swift`.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — `columnCount(forWidth:cardCount:)` (the fix site) and `cardGrid` (its sole consumer); also `rowIndices`, used to evaluate last-row fill.
- `Tests/PlansTests/BrowserWindowTests.swift` — existing `columnCount` assertions to keep green + new balancing assertions to add.

## Diagnosis

**Most likely:** `columnCount(forWidth:cardCount:)` maximizes columns to the width capacity and only ever clamps *down* to the card count, never asking whether a smaller column count would fill the last row — so 4 cards in a viewport with width-capacity 3 render as 3+1 (`Sources/Plans/BrowserWindow.swift:99-101`).
**Evidence:** `max(1, min(columnCount(forWidth:), cardCount))` picks the largest count the width allows. For width in `[1280, 1696)` capacity is 3; `min(3, 4) = 3`; `rowIndices(count: 4, columns: 3) = [[0,1,2],[3]]` — a top row of 3 and a last row of 1. Downstream `fitCardGrid` even pads the short last row with `Color.clear`, cementing the hole.
**Confidence:** high

**Alternative:** The imbalance is rendered by `rowIndices` / `columnAssignments` / `fitCardGrid` padding (`Sources/Plans/BrowserWindow.swift:770`, `:201`, `:702`) — **Confidence:** low. These faithfully render whatever `columns` implies; they are where the hole becomes visible, not where it is decided. Fixing them would treat the symptom and desync the two layout modes.

**To confirm:** A pure unit test asserting the current (buggy) behavior `columnCount(forWidth: 1400, cardCount: 4) == 3` — every downstream path derives from that single integer, so this discriminates the "maximize columns" cause from any downstream-helper hypothesis.

## How
- [x] Step 1: Add a failing/characterization test in `Tests/PlansTests/BrowserWindowTests.swift` that reproduces the hole (`columnCount(forWidth: 1400, cardCount: 4)` currently returns 3), confirming the Diagnosis before any fix (agent-verifiable, so untagged).
- [x] Step 2: Write the desired-behavior tests first (RED): `columnCount(forWidth: 1400, cardCount: 4) == 2` (2x2, no hole), plus regression assertions that the existing pinned values still hold — `cardCount: 1 → 1` (focus), `cardCount: 4` at 2000pt → 4 (already a full single row), `cardCount: 10` at 2000pt → 4 (never widen; near-square floor == capacity so no reduction), `cardCount: 0 → 1`, `cardCount: 2` at 2000pt → 2. Add a 5-card case documenting that a 1-slot hole at capacity 3 is kept (near-square floor prevents over-collapse).
- [x] Step 3: Implement the balancing step in `BrowserWindow.columnCount(forWidth:cardCount:)` (GREEN): compute the width capacity as today, then among candidate counts from that capacity down to `ceil(sqrt(cardCount))`, return the largest count whose last row is completely full; if none is completely full, return the width-capacity count. Preserve the `max(1, …)` floor and the `cardCount`-clamp / focus-mode invariant.
- [x] Step 4: Run the targeted test file (`swift test --filter BrowserWindowTests`) and confirm all `columnCount` tests pass, then refactor for clarity (extract a small pure helper if it reads cleaner) while keeping tests green.

## Verification
- New unit test `columnCount(forWidth: 1400, cardCount: 4)` returns 2 (a 2x2 grid, no hole).
- All pre-existing `columnCount` / `columnCount(forWidth:cardCount:)` tests still pass (focus-mode single card, never-widen-past-capacity, zero cards, exact-fit-single-row).
- `swift test --filter BrowserWindowTests` passes.
- (Manual, deferred to review) Resize the browser window to ~1400pt wide with 4 registered projects and confirm the cards render as a balanced 2x2 rather than 3+1.

## Impact Scope
_Fewer than 3 files affected — Impact Scope omitted._

## Assumptions

### Initial (from elaboration)
- [low] Balance policy: reduce the column count to the largest value (from width-capacity down to a `ceil(sqrt(cardCount))` near-square floor) whose LAST ROW IS COMPLETELY FULL; keep the width-capacity count if none is full. **Why:** The user's stated case (4 cards → 2x2) and the "prefer to not have holes" principle both demand it; research flagged this as an open question with two divergent rules ("fewer trailing empties" vs "exact rectangle"). This rule satisfies the given example, keeps the existing pinned tests green (4@2000→4, 10@2000→4), and avoids the over-collapse failure mode (never turns a full wide row into an unnecessarily narrow one).
- [low] Near-square floor of `ceil(sqrt(cardCount))` as the lower bound for balancing. **Why:** Answers research's "minimum-columns floor" open question — it prevents a legitimately wide window from collapsing cards far below the width capacity (e.g. it declines to reduce 5 cards@capacity-3 to a jagged 2-column layout with a bigger hole), while still permitting the 4→2 reduction the user wants.
- [low] Bug task drafted and auto-accepted in skip mode without interactive confirmation of the balance policy. **Why:** yolo/skip mode — no interactive UI available; recorded here for review.

### Discovered during execution
- [high] Extracted the balancing scan into a separate pure `static func balancedColumnCount(capacity:cardCount:)` rather than inlining it. **Why:** Reads cleaner and is directly unit-testable in isolation; `columnCount(forWidth:cardCount:)` now just computes the clamped capacity and delegates.
- [high] Implemented the near-square floor with `Int(ceil(Double(cardCount).squareRoot()))` (Swift's `Double.squareRoot()` + `ceil`) rather than importing `sqrt`/`Foundation.ceil` free functions. **Why:** Avoids float free-function ambiguity, is exact for the perfect-square boundary (e.g. cardCount 4 → 2.0 → ceil 2), and needs no extra import beyond what SwiftUI already provides.
- [high] Guard `cardCount > 1` short-circuits balancing to return `capacity` directly for 0 and 1 cards. **Why:** Preserves the `cardCount == 0 → 1` and `cardCount == 1 → 1` focus-mode invariants without special divisor math (0 % n and the sqrt floor for 1 would otherwise need care).
- [high] The divisor check `cardCount % candidate == 0` is always valid because `capacity` is pre-clamped to `min(widthCapacity, cardCount)`, so every scanned candidate is `<= cardCount`. **Why:** A single full row (candidate == cardCount) satisfies the modulo, correctly counting as "full" per the policy.
- [high] The Step 1 characterization assertion (`== 3`) was added temporarily, run to confirm it passed against unmodified code (diagnosis confirmed: the maximize-columns decision is the origin), then removed so the final suite has no contradictory assertion for input `1400 × 4`. **Why:** Step 2 required no duplicate/conflicting assertions for the same input.

## Changes
- `Sources/Plans/BrowserWindow.swift`: `columnCount(forWidth:cardCount:)` now computes the clamped width capacity as before, then delegates to a new pure `static func balancedColumnCount(capacity:cardCount:)`. The balancer scans candidate column counts from the clamped capacity down to the near-square floor `ceil(sqrt(cardCount))` and returns the largest whose last row is completely full (`cardCount % candidate == 0`), falling back to the capacity when none divides evenly. `guard cardCount > 1` preserves the empty-grid (`0 → 1`) and focus-mode (`1 → 1`) invariants. Doc comments updated to explain the no-holes balancing. Net effect: 4 cards at ~1400pt now render as a 2x2 grid instead of 3+1.
- `Tests/PlansTests/BrowserWindowTests.swift`: added `testColumnCountBalancesFourCardsToTwoByTwo` (1400×4 == 2) and `testColumnCountKeepsThreeForFiveCardsAtCapacityThree` (1400×5 == 3, near-square floor prevents over-collapse). Existing `columnCount(forWidth:cardCount:)` regression tests (focus single card, never-widen-past-capacity, exact-fit single row, zero cards) remain unchanged and green.
- Tests: `swift test --filter BrowserWindowTests` → 109 tests, 0 failures.

## Notes
- Stale doc comment in `CardLayout.swift:17` references a nonexistent `fitColumnCount(forCount:)`; both modes actually use the same `columnCount`. Not load-bearing for this bug — leave unless trivially adjacent while editing.
