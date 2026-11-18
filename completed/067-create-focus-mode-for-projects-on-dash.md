# Create "Focus" Mode for Projects on Dash

**ID:** 067
**Created:** 2026-08-23T18:50
**Type:** feature
**Status:** completed
**Branch:** feature/067-create-focus-mode-for-projects-on-dash
**Completed:** 2026-08-24T10:35

## What
Create "Focus" mode for projects on dash

Add a "Focus" mode to the cross-project browser window (Surface B, "the dash")
that lets the user isolate a single project — collapsing the grid to just that
project's card so they can concentrate on one project's plans without the visual
noise of every other registered project. A per-card focus glyph enters focus; a
persistent toolbar control exits it (returns to all projects).

## Why
Adds value by letting the user cut the cross-project dashboard down to the one
project they're actively working in. With many registered projects the grid gets
noisy; a single-project "Focus" view removes that distraction on demand while
leaving the underlying read-only/polling model untouched.

## How Summary
Add UI-only focus state to the single shared `PlansStore`
(`focusedProjectPath: String?`, persisted to UserDefaults exactly like
`starredProjectPaths` / `hideEmptyProjects`), a pure filter predicate in
`BrowserViewModel` mirroring `visibleUnderHideEmpty`, and wire it into the
existing derived `sortedProjects` so focus collapses the grid to the matching
card without ever mutating `store.projects` (polling stays unaffected). Add a
per-card focus glyph in `ProjectCard`'s footer next to the star, and a persistent
"Show All Projects" toolbar exit button in `BrowserWindow` (disabled when nothing
is focused), following the "Sort by Recency" / "Hide Empty" toolbar precedents.
Focus auto-clears in the derived getter when the focused path is no longer a live
project, so the grid can never get stuck empty.

**Files of note:**
- `Sources/Plans/PlansStore.swift` — add persisted `focusedProjectPath: String?` + `focusedProjectKey`, load in `init`, add `toggleFocus(_:)` / `clearFocus()` helpers (mirrors `starredProjectPaths` and `setManualOrder`/`clearManualOrder`)
- `Sources/Plans/BrowserWindow.swift` — add `BrowserViewModel.visibleUnderFocus(...)` pure predicate; apply it in `sortedProjects`; add the "Show All Projects" toolbar exit button
- `Sources/Plans/ProjectCard.swift` — add a `focusToggle` footer glyph (new `FocusToggleGlyph`, mirroring `StarToggleGlyph`) that toggles `store.focusedProjectPath`
- `Tests/PlansTests/PlansStoreTests.swift` — persistence tests for `focusedProjectPath` (template: `testStarredProjectPathsPersistAcrossStoreInstances`)
- `Tests/PlansTests/BrowserWindowTests.swift` — pure-value tests for `visibleUnderFocus` (template: `visibleUnderHideEmpty` block, lines 329–382)

## How
- [x] Step 1: In `Tests/PlansTests/PlansStoreTests.swift`, add failing tests for the new focus state (template: the `starredProjectPaths` persistence tests ~lines 831–865): `focusedProjectPath` defaults to `nil`; setting it persists across a second `PlansStore` instance sharing the same injected `UserDefaults` suite; `clearFocus()` sets it back to `nil` and that persists; `toggleFocus(path)` sets it when unfocused and clears it when the same path is already focused.
- [x] Step 2: In `Tests/PlansTests/BrowserWindowTests.swift`, add failing pure-value tests for `BrowserViewModel.visibleUnderFocus(_:focusedProjectPath:)` (template: the `visibleUnderHideEmpty` block ~lines 329–382): `nil` focus ⇒ every project visible; a set focus ⇒ only the project whose `projectPath` matches is visible; a non-matching project is hidden.
- [x] Step 3: In `Sources/Plans/PlansStore.swift`, add `var focusedProjectPath: String?` with a `didSet { defaults.set(focusedProjectPath, forKey: Self.focusedProjectKey) }`, a `private static let focusedProjectKey = "focusedProject"`, and load it in `init` via `_focusedProjectPath = defaults.string(forKey: Self.focusedProjectKey)` (backing-field assignment to avoid re-persisting, matching the other prefs). Add `func toggleFocus(_ path: String)` (set to `path`, or `nil` if already `path`) and `func clearFocus()` (set to `nil`), styled like `setManualOrder`/`clearManualOrder`. Add a doc comment noting it is UI-only, never written to `.plans/`.
- [x] Step 4: In `Sources/Plans/BrowserWindow.swift`, add `static func visibleUnderFocus(_ project: ProjectTasks, focusedProjectPath: String?) -> Bool` to `BrowserViewModel` next to `visibleUnderHideEmpty` — `pure`, returning `true` when `focusedProjectPath == nil`, else `project.projectPath == focusedProjectPath`. Make Step 2's tests pass.
- [x] Step 5: In `BrowserWindow.sortedProjects`, apply the focus filter to the ordered list. First resolve an effective focus: if `store.focusedProjectPath` is set but no live `store.projects` element has that path, treat focus as `nil` (auto-clear stale focus so the grid never collapses to empty). Then filter the (already order- and hide-empty-resolved) list with `visibleUnderFocus`, keeping order. Do NOT mutate `store.projects`.
- [x] Step 6: In `Sources/Plans/ProjectCard.swift`, add a `focusToggle` footer view (a new private `FocusToggleGlyph` mirroring `StarToggleGlyph`, using SF Symbol `viewfinder`, tinted/opaque when this project is focused) placed in the `footer` HStack next to `starToggle`. Tapping calls `store.toggleFocus(project.projectPath)`; the help text reads "Focus project" / "Exit focus" depending on state.
- [x] Step 7: In `BrowserWindow`'s toolbar, add a persistent "Show All Projects" exit `Button` following the "Sort by Recency" revert precedent (~lines 325–343): always present, `.disabled(store.focusedProjectPath == nil)`, tinted when focus is active, systemImage `rectangle.3.group` (or similar), calling `store.clearFocus()`. This guarantees the user can always leave focus even when the grid shows a single card.
- [x] 👁 Step 8: Build and run the app (`./build.sh`), open the dash, click a card's focus glyph, and confirm the grid collapses to that project; confirm the toolbar exit button restores all projects; confirm focus survives an app relaunch; confirm unlinking the focused project (or it disappearing) restores all projects instead of showing an empty grid.

## Verification
- `swift test` passes, including the new `PlansStoreTests` persistence tests and the new `BrowserWindowTests` `visibleUnderFocus` tests.
- Manually (Step 8): clicking a card's focus glyph collapses the dash to that
  single project's card; the "Show All Projects" toolbar button (disabled until a
  project is focused) restores the full grid; focus persists across an app
  relaunch; and if the focused project is unlinked/removed the dash falls back to
  showing all projects rather than an empty grid.
- No regressions: "Hide Empty", manual card order, and the menu bar glance
  (Surface A) behave exactly as before; `store.projects` is never mutated and the
  ~5s polling refresh is unaffected.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/PlansStore.swift` — add persisted `focusedProjectPath` + key + `init` load + `toggleFocus`/`clearFocus`
- [x] `Sources/Plans/BrowserWindow.swift` — add `visibleUnderFocus` predicate, apply focus filter (with stale-path auto-clear) in `sortedProjects`, add the "Show All Projects" toolbar exit button
- [x] `Sources/Plans/ProjectCard.swift` — add the `focusToggle` footer glyph + `FocusToggleGlyph` view
- [x] `Tests/PlansTests/PlansStoreTests.swift` — persistence tests for `focusedProjectPath`
- [x] `Tests/PlansTests/BrowserWindowTests.swift` — pure-value tests for `visibleUnderFocus`

### Related Files (may need updates)
- `Sources/Plans/TaskParser.swift` — no change expected; source of `ProjectTasks.projectPath`, the stable id focus keys on (reference only)
- `Sources/Plans/MenuBarView.swift` / `MenuBarLabel.swift` — intentionally NOT changed; focus is Surface B only (menu bar glance stays a whole-machine aggregate)

### Endpoints/UI Affected
- Browser window (Surface B) toolbar — new persistent "Show All Projects" exit button
- Project card footer — new focus glyph next to the star toggle
- Browser grid — collapses to the focused project's single card while focus is active

## Assumptions

### Initial (from elaboration)
- [low] Focus is **single-project** (`focusedProjectPath: String?`), collapsing the grid to one card, rather than a multi-select subset. **Why:** the task framing ("concentrate on one project") and research both favor single; multi-select adds machinery without a stated need. The title's plural "projects" is read as "the projects area of the dash", not "focus many at once."
- [low] Focus state is **persisted across app launches** (UserDefaults, mirroring `starredProjectPaths` / `hideEmptyProjects` / `cardLayoutMode`). **Why:** consistency with every other browser preference in `PlansStore`; the potential "why is only one project showing on relaunch" confusion is mitigated by the always-visible, tinted "Show All Projects" toolbar exit button.
- [high] Focus affects **Surface B (browser) only**, not the menu bar glance (Surface A). **Why:** research recommended this; `iconSpaceCounts` is deliberately a whole-machine aggregate and is a separate concern from the browser's view state.
- [high] Focus is **independent of the existing `selectedProjectPath`** drill-down anchor rather than reusing it. **Why:** `selectedProjectPath` means "scroll to this project" (Surface A → B handoff); conflating it with "filter to this project" would break the drill-down semantics.
- [low] A **stale focus auto-clears**: if `focusedProjectPath` names a project no longer in `store.projects`, `sortedProjects` treats focus as `nil` and shows all projects. **Why:** prevents the grid collapsing to an empty "No projects" state and getting stuck; fail-safe resolution lives in the derived getter, not persisted state, so the saved path can recover if the project returns.
- [low] The focus affordance is a **footer glyph next to the star** using the `viewfinder` SF Symbol, with a persistent "Show All Projects" toolbar exit button. **Why:** the footer is the established home for per-project affordances (`starToggle`, `gitFooter`); `viewfinder` reads as "focus"; the toolbar exit mirrors the "Sort by Recency" revert precedent so the exit is always discoverable.

### Discovered during execution
- [high] `focusedProjectPath` declared as a plain observable `var` with a `didSet` persist, exactly matching `hideEmptyProjects` / `cardLayoutMode` (the store is `@Observable`, so no `@Published` — those macros are Combine-era). **Why:** direct pattern-match to the sibling browser prefs; assigning `_focusedProjectPath` in `init` avoids the load re-persisting.
- [high] `toggleFocus`/`clearFocus` mutate the observable property (which triggers the persist `didSet`) rather than calling `defaults` directly, mirroring `setManualOrder`/`clearManualOrder`. **Why:** keeps the single persistence sink in the property's `didSet`.
- [high] `visibleUnderFocus` uses `guard let focusedProjectPath else { return true }` then path equality, keeping it a pure static predicate alongside `visibleUnderHideEmpty`. **Why:** direct template match; no I/O, no SwiftUI.
- [high] Stale-focus auto-clear lives in the derived `sortedProjects` getter (via `flatMap` over live `store.projects`), NOT by mutating persisted state. **Why:** the plan explicitly wanted fail-safe resolution in the getter so the saved path recovers if the project returns; `store.projects` is never mutated.
- [high] Focus filter applied as the LAST stage of the `sortedProjects` pipeline (after order + hide-empty resolution), preserving order. **Why:** focus is a view-collapse concern orthogonal to ordering/hide-empty; layering it last keeps each stage independent and order-stable.
- [low] `FocusToggleGlyph` mirrors `StarToggleGlyph` exactly (solid `viewfinder`, white-opacity state, same hover chrome) rather than `RowActionGlyph`. **Why:** it sits beside the star in the footer, so matching the star's affordance keeps the two footer glyphs visually consistent; `viewfinder` reads as "focus".
- [low] The "Show All Projects" toolbar exit button mirrors the recency-revert control's chrome (`.borderless`, `.titleAndIcon`, always-present/disabled) plus the tinted-when-active treatment from "Hide Empty" (`AnyShapeStyle(.tint)`), using SF Symbol `rectangle.3.group`. **Why:** combines the two established toolbar precedents the plan pointed at — persistent-revert placement and tint-when-active state — so the exit is always discoverable.
- [low] Placed `focusToggle` BEFORE `starToggle` in the footer HStack (focus left of star, both trailing-aligned after the `Spacer`). **Why:** the plan said "next to `starToggle`" without a side; grouping the two trailing glyphs with focus first keeps the star as the outermost/rightmost established affordance.

## Changes
- `Sources/Plans/PlansStore.swift`: added UI-only `focusedProjectPath: String?` (persist `didSet` → `focusedProjectKey = "focusedProject"`), `init` backing-field load to avoid re-persist, and `toggleFocus(_:)` / `clearFocus()` helpers styled after `setManualOrder`/`clearManualOrder`.
- `Sources/Plans/BrowserWindow.swift`: added pure `BrowserViewModel.visibleUnderFocus(_:focusedProjectPath:)` predicate next to `visibleUnderHideEmpty`.
- `Tests/PlansTests/PlansStoreTests.swift`: 4 focus-state persistence tests (default nil, persist across instances, clearFocus, toggleFocus set/clear/switch).
- `Tests/PlansTests/BrowserWindowTests.swift`: 3 `visibleUnderFocus` pure-value tests.
- `Sources/Plans/BrowserWindow.swift`: `sortedProjects` now applies the focus filter as its final stage — resolves an effective focus (auto-clears a stale `focusedProjectPath` not present in live `store.projects`) then filters with `visibleUnderFocus`, order-preserving, without mutating `store.projects`. Added a persistent "Show All Projects" toolbar exit `Button` (`rectangle.3.group`, disabled when no focus, tinted when active, calls `clearFocus()`) beside the recency-revert control.
- `Sources/Plans/ProjectCard.swift`: added `focusToggle` in the footer HStack (left of `starToggle`) backed by a new private `FocusToggleGlyph` mirroring `StarToggleGlyph`, SF Symbol `viewfinder`, opaque/tinted when this project is focused, calls `toggleFocus(project.projectPath)`, help "Focus project" / "Exit focus".
- `Sources/Plans/BrowserWindow.swift` (review-time fix, commit 9b0886f): added `columnCount(forWidth:cardCount:)` — the width-driven count clamped by the number of cards actually rendered — and used it in `cardGrid`. A focused single card previously kept the 400pt `cardMinWidth` beside three empty columns; it now fills the viewport. Only ever narrows the count, so cards never shrink below `cardMinWidth`, and the `max(1, …)` floor is preserved for an empty grid.
- `Tests/PlansTests/BrowserWindowTests.swift` (review-time fix): 6 `columnCount(forWidth:cardCount:)` clamp tests (single card, two cards, no widening with extra cards, exact match, zero-card floor, narrow viewport).

## Notes
- Reuse the established patterns rather than inventing new machinery: persisted
  pref = `starredProjectPaths` (Set→array round-trip is the template, but focus is
  a single `String?` so use `defaults.string(forKey:)`); pure filter predicate =
  `visibleUnderHideEmpty`; toolbar exit = the "Sort by Recency" revert control;
  footer glyph = `StarToggleGlyph`.
- Do NOT introduce a second store, do NOT filter `store.projects` itself (filter
  only the derived `sortedProjects`), and do NOT add inline status/type glyph
  vocab — focus adds no status/type vocabulary (`viewfinder` is a plain SF Symbol
  used inline like the other toolbar/footer glyphs).
- The existing snapshot-once grid (`fitCardGrid`/`variableCardGrid`, #040) already
  handles a shrinking `sortedProjects` safely, so collapsing to one card needs no
  new index guards.
