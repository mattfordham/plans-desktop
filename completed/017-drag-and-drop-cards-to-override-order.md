# Drag And Drop Cards To Override Order

**ID:** 017
**Created:** 2026-06-05T00:00
**Type:** feature
**Status:** completed
**Branch:** feature/017-drag-and-drop-cards-to-override-order
**Completed:** 2026-06-06T09:35

## What
Drag and drop project cards in the browser grid to manually override their display order, replacing the automatic recency (staleness) sort.

## Why
Adds value by giving the user direct control over the project card order. The current `sortByStaleness` recency sort is automatic and can't be overridden, so the user can't pin frequently-used projects to a preferred position. Manual ordering makes the dashboard match the user's mental model.

## How
- [x] Step 1: Add persisted order state to `PlansStore` (`Sources/Plans/PlansStore.swift`): a `projectOrderOverride: [String]` array of project paths, plus `manualOrderActive: Bool`. Load/save to `UserDefaults` (key e.g. `cardOrderOverride`) following the existing `@Observable` pattern. New project paths not present in the saved order sort to the **top**.
- [x] Step 2: Replace the `sortedProjects` computed property in `Sources/Plans/BrowserWindow.swift:47` so that, when `manualOrderActive` and an override exists, it sorts `store.projects` by the override (unknown paths → top, stable fallback); otherwise it falls back to `BrowserViewModel.sortByStaleness(store.projects)` as today.
- [x] Step 3: Add drag-and-drop reordering to the `LazyVGrid` `ForEach` in `BrowserWindow.swift:85` using `.draggable`/`.dropDestination(for: String.self)` keyed on `project.projectPath`. On drop, compute the new ordering, set `manualOrderActive = true`, update `projectOrderOverride`, and persist.
- [x] 👁 Step 4: Add a "Sort by recency" revert toggle/indicator (e.g. a small control in the dashboard header) that clears `manualOrderActive` and reverts to staleness sort; show a subtle indicator when manual order is active.
- [x] 👁 Step 5: Build and run the app; drag cards to reorder, confirm order persists across restart, and confirm the revert toggle restores recency sort. _(Build verified clean in worktree; the run-and-observe portion is deferred to /plan-review.)_

## Verification
Verify drag-and-drop reorders project cards in the grid; the manual order persists across app restarts (via UserDefaults); newly-added projects appear at the top; the "sort by recency" toggle reverts to the automatic staleness sort; `.plans/` data is never written to. Build succeeds with no regressions.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/PlansStore.swift` — Add `projectOrderOverride: [String]` + `manualOrderActive: Bool`, UserDefaults load/save
- [x] `Sources/Plans/BrowserWindow.swift` — Conditional `sortedProjects`, drag/drop modifiers on grid cards, revert toggle in header

### Related Files (may need updates)
- `Sources/Plans/ProjectCard.swift` — Stays read-only; may need to expose nothing, but referenced as the dragged card view

### Endpoints/UI Affected
- Browser window dashboard grid — cards become draggable; new "sort by recency" control / manual-order indicator

## Assumptions

### Initial (from elaboration)
_Interactive elaboration — assumptions resolved with the user (scope: project cards only; persist + revert toggle; new items to top)._

### Discovered during execution
- [high] UserDefaults keys are `cardOrderOverride` (the `[String]` path array) and `cardOrderManualActive` (the bool flag), exactly as the segment prompt suggested. **Why:** matched the prompt's proposed keys; namespaced enough to avoid collision with existing app state.
- [high] Injected `UserDefaults` into `PlansStore.init` (default `.standard`); persisted state is loaded eagerly in `init` by assigning the `@Observable` backing fields (`_projectOrderOverride` / `_manualOrderActive`) to avoid the `didSet` writing the just-read value back. **Why:** mirrors the existing injected-readers testability pattern; eager load ensures the override is active before first grid layout.
- [low] `reorder(_:moving:before:)` semantics: remove the source path, then re-insert it immediately BEFORE the target path; a `nil` target appends to the END. No-op when source is absent from the order or equals the target. **Why:** SwiftUI's `.dropDestination` fires on the card being dropped ONTO, so "insert before that card" is the natural mapping; `nil` target supports a future drop-on-empty-space case. Chose "before target" over "swap" because it gives predictable list-insertion behavior.
- [high] `.dropDestination(for: String.self)` payload is the dragged card's `projectPath`; the drop computes the new order over the CURRENTLY displayed order (`sortedProjects.map(\.projectPath)`), not the raw `projectOrderOverride`, so the first drag from a recency-sorted state captures the visible order as the baseline. **Why:** the prompt specified computing over the current displayed order; this makes the first manual drag intuitive (what you see is the starting point).
- [high] New projects absent from a saved override sort to the TOP, ahead of all override-listed projects, preserving their mutual original (registry/staleness) order via a stable enumerate secondary key. **Why:** prompt requirement; mirrors the stable-fallback structure already used by `sortByStaleness`.
- [high] `clearManualOrder()` only flips `manualOrderActive = false` and intentionally RETAINS the saved `projectOrderOverride`. **Why:** lets a future "re-enable manual order" path restore the prior arrangement; the segment note explicitly asked for `clearManualOrder()` to exist for step 4.
- [high] (step 4) Placed the revert control in the window `.toolbar` (a `ToolbarItem(placement: .automatic)`) on `cardGrid` rather than adding an inline header row above the grid. **Why:** the prompt called this the cleaner, non-intrusive option for a macOS window; it keeps the dashboard body unchanged (still just `cardGrid.frame(...)`) and avoids stealing vertical grid space.
- [high] (step 4) The toolbar item is HIDDEN entirely when `store.manualOrderActive` is false (the `if` wraps the `ToolbarItem`), and only appears while manual order is active. **Why:** the control is only meaningful during manual order; hiding (vs. showing-disabled) keeps the header uncluttered when there's nothing to revert, per the prompt's "keep it subtle" guidance.
- [low] (step 4) Revert control copy is `"Sort by Recency"` with SF Symbol `arrow.uturn.backward` and a help tooltip "Discard the manual card order and sort by recency." **Why:** the label names the destination state (the automatic staleness/recency sort) so the action is self-explanatory; extracted as the testable `BrowserViewModel.manualOrderRevertLabel` constant. Exact wording/icon is a visual-review (👁) call.

## Changes
- `PlansStore.swift`: Added `projectOrderOverride: [String]` + `manualOrderActive: Bool` (UserDefaults-persisted via `didSet`, defaults `cardOrderOverride`/`cardOrderManualActive`); injected `UserDefaults` into `init` for testability; eager load in `init`; `setManualOrder(_:)` and `clearManualOrder()` mutators.
- `BrowserWindow.swift`: Pure `BrowserViewModel.applyManualOrder(_:order:)` (new paths to top, stable fallback) and `reorder(_:moving:before:)` (insert-before-target; nil appends); `sortedProjects` now uses `applyManualOrder` when `manualOrderActive && !projectOrderOverride.isEmpty`, else `sortByStaleness`; thin `.draggable`/`.dropDestination(for: String.self)` on grid items routing through `handleDrop` → `store.setManualOrder`.
- Tests: 6 new in `PlansStoreTests` (defaults, persistence round-trip across instances, per-property persistence, clearManualOrder), 10 new in `BrowserWindowTests` (applyManualOrder + reorder cases). `swift build` clean; both classes pass.
- `BrowserWindow.swift` (step 4): Window `.toolbar` revert control (`ToolbarItem`, hidden unless `manualOrderActive`) — "Sort by Recency" button (`arrow.uturn.backward` + help tooltip) calling `store.clearManualOrder()`; copy extracted to testable `BrowserViewModel.manualOrderRevertLabel` (1 new test). `swift build` clean; `BrowserWindowTests` 40 tests pass.

## Notes
- Native macOS SwiftUI app. Cards = project cards in a `LazyVGrid` (BrowserWindow.swift), one per registered project.
- App is **read-only** toward `.plans/` (per `desktop-app-spec.md` §2) — order override MUST be stored in app storage (UserDefaults), never written to task files or the plans-cc registry.
- Scope is **project cards only**. Reordering task rows within a card is a separate, more complex feature (per-project order map) and is explicitly out of scope here.
- `.draggable`/`.dropDestination` require macOS 14+; the app targets macOS 15+, so this is fine.
