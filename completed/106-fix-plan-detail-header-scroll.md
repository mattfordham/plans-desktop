# Fix plan detail header to stay fixed while body scrolls

**ID:** 106
**Created:** 2026-11-07T22:21
**Type:** feature
**Status:** completed
**Completed:** 2026-11-08T08:28
**Branch:** feature/106-fix-plan-detail-header-scroll

## What
In the planned detail view, the header should be fixed at the top, and the body should scroll underneath.

## Why
Keeps the plan's identity and action bar (title, status/type, Elaborate/Execute/Refine actions) always visible while the user scrolls through a long plan body. Today the header scrolls off the top with the content, so on a long plan the user loses the title and the action buttons until they scroll back up.

## How Summary
Lift the detail header (and its full-bleed `Divider()` seam plus the `#105` progress panel) out of the plan `ScrollView` so they become a pinned banner at the top of the plan area, and leave only the body sections (`What`/`Why`/`How`/… plus the failure and denied-tools notes) inside the `ScrollView`. This is a pure view-hierarchy restructure within `planScrollView(_:)` — no builder bodies change and nothing measures its own size (respecting the #096 no-self-measurement rule).

**Files of note:**
- `Sources/Plans/PlanDetailView.swift` — `planScrollView(_:)` (the ScrollView boundary moves); reuses the unchanged `detailHeader(_:)`, `progressPanel(_:)`, `sectionView(_:)` builders and the `showsProgressPanel(status:howProgress:)` gate.
- `Tests/PlansTests/PlanDetailViewTests.swift` — existing pure-helper tests (e.g. `showsProgressPanel`) must keep passing unchanged; add a test only if a pure helper is introduced.

## How
- [x] Step 1: In `planScrollView(_:)`, restructure the method to return a `VStack(spacing: 0)` that holds a pinned top region followed by a `ScrollView`. Move `detailHeader(row)` (with its existing `.frame`/`.padding(28)` modifiers), the full-bleed `Divider()`, and the gated `progressPanel(row)` (still guarded by `Self.showsProgressPanel(...)`) into the pinned region ABOVE the `ScrollView`.
- [x] Step 2: Leave only the body inside the `ScrollView` — the inner `VStack(alignment: .leading, spacing: 28)` containing the failure section, denied-tools note, and the `ForEach` of `sectionView(section)` — keeping its per-block width cap (`PlanType.readingWidth`) and `.padding(28)` unchanged. Keep `.textSelection(.enabled)` applied so body text stays selectable.
- [x] Step 3: Give the pinned top region an opaque background (window/`.bar` surface consistent with the rest of the view) so scrolled body content does not show through behind the header edges; ensure the `Divider()` reads as the bottom rule of the pinned banner.
- [x] Step 4: Preserve the `ScrollView`'s structural identity in the hierarchy (do not conditionally rebuild it) so scroll position does not reset when the discussion panel appears (#181–186). Confirm the header no longer scrolls and that pinning did not change the discussion-panel / composer layout below.
- [x] 👁 Step 5: Build and run the app (`./build.sh`), open the browser window, select a long plan, and visually confirm the header + progress panel stay pinned at the top while the body scrolls underneath, with no content bleeding behind the header. _(Observation deferred to review — worktree/yolo mode. Prerequisites implemented; runtime visual check to be performed at `/plan-review 106`.)_

## Verification
- `swift build` succeeds and `swift test` (targeted: `PlanDetailViewTests`) passes with no regressions.
- In the running app, opening a long plan in the detail column shows the title/status/action bar pinned at the top; scrolling moves only the body sections beneath it.
- The `#105` progress panel (for in-progress plans) stays visible/pinned with the header rather than scrolling away.
- No visual seam or content bleed behind the pinned header; the discussion panel/composer at the bottom is unaffected.

## Impact Scope
_Fewer than 3 files affected — single-file restructure in PlanDetailView.swift._

## Assumptions

### Initial (from elaboration)
- [low] The `#105` progress panel stays PINNED with the header (not scrolling with the body). **Why:** its own doc comment states it exists so an active plan "reads its progress at a glance without scrolling" — pinning preserves that intent. Research flagged this as the one real design decision.
- [low] The full-bleed `Divider()` is pinned WITH the header as the banner's bottom rule (rather than left as the first scrolling element). **Why:** a divider that scrolls away from a pinned header reads as broken; pinning it keeps the banner a clean fixed region.
- [low] The pinned region gets an opaque background so scrolled content does not bleed behind it. **Why:** once the header floats over a scrolling body, body content can show through the header's padding edges; an opaque surface (matching the view's existing surface) avoids that. Low-confidence because with an already-opaque window background it may be a visual no-op.
- [low] Kept the plain `VStack` header + `ScrollView` body idiom rather than `safeAreaInset(edge:.top)` or pinned `Section` headers. **Why:** research recommended the plain VStack as the clearest fit for this codebase's "nothing measures itself" rule (#096); the alternatives add indirection or wrong-tool semantics.

### Discovered during execution
- [high] Followed the elaborated plan's restructure as specified: a `VStack(spacing: 0)` with a pinned banner (header + Divider + gated progressPanel) given `.background(.bar)`, above a single `ScrollView` holding only the body, with `.textSelection(.enabled)` on the ScrollView. **Why:** matches the segment's exact instructions and the view's existing `.bar` surface vocabulary; no new choices beyond what elaboration recorded.

## Changes
- `Sources/Plans/PlanDetailView.swift` — Restructured `planScrollView(_:)` (lines ~717-777). The method now returns an outer `VStack(alignment: .leading, spacing: 0)` with two parts:
  1. A **pinned banner** `VStack(spacing: 0)` holding `detailHeader(row)` (its existing width-cap/padding modifiers unchanged), the full-bleed `Divider()`, and the gated `progressPanel(row)` (`if Self.showsProgressPanel(...)`). The banner is given `.background(.bar)` so scrolled body content does not show through behind the header edges.
  2. A single, stable **`ScrollView`** containing only the body — the inner `VStack(spacing: 28)` with the failure section, denied-tools note, and the `ForEach` of `sectionView(section)` — keeping its `PlanType.readingWidth` cap and `.padding(28)`. `.textSelection(.enabled)` stays on the `ScrollView`.
  - Updated the method doc comment to describe the pinned banner + scrolling body shape (#106).
  - No `GeometryReader`/self-measurement introduced (respects #096). No other files touched.
- Build: `swift build` succeeds (one pre-existing unrelated ViewBuilder warning, not introduced here).
- Tests: `swift test --filter PlanDetailViewTests` → 59 tests, 0 failures. Existing pure-helper tests unchanged and passing.

## Notes
_Additional context_
