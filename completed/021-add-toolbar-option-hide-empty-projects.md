# Add Toolbar Option To Hide Projects With No Outstanding Plans

**ID:** 021
**Created:** 2026-06-06T00:00
**Type:** feature
**Status:** completed
**Branch:** feature/021-add-toolbar-option-hide-empty-projects
**Completed:** 2026-06-06T13:20

## What
Add tool bar option to hide projects with no outstanding plans.

The browser window (Surface B) lists every registered project as a card. Add a
toolbar toggle that hides projects with no outstanding plans (no
pending/elaborated/in-progress/review/in-review tasks) so the dashboard focuses
on projects that still have work remaining. The toggle state persists across
launches via UserDefaults, mirroring the #017 manual-order pattern.

## Why
Adds value by letting the user declutter the cross-project dashboard, focusing
the view on projects that still have outstanding work instead of scrolling past
fully-completed projects.

## How
- [x] Step 1: Add a `hasOutstandingWork` computed property to `ProjectTasks` in `Sources/Plans/TaskParser.swift` — returns `!activeTasks.isEmpty` (the parser already excludes `.completed`/nil-status tasks from `activeTasks`). Add a unit test in `Tests/PlansTests/` (TDD: write the failing test first) covering a project with active tasks (true) and one with only completed/no tasks (false), using the existing `ProjectTasks` fixture pattern from `BrowserWindowTests.swift`.
- [x] Step 2: Add a persisted `hideEmptyProjects: Bool` to `Sources/Plans/PlansStore.swift` following the `manualOrderActive` pattern — `didSet { defaults.set(hideEmptyProjects, forKey: Self.hideEmptyKey) }`, a `private static let hideEmptyKey = "hideEmptyProjects"`, and load it in `init()` via `_hideEmptyProjects = defaults.bool(forKey: Self.hideEmptyKey)`.
- [x] Step 3: Filter in `BrowserWindow.sortedProjects` (`Sources/Plans/BrowserWindow.swift`) — after computing the sorted list, apply `store.hideEmptyProjects ? sorted.filter(\.hasOutstandingWork) : sorted`. Keep `store.projects` untouched (filtering is view state, not store data).
- [x] Step 4: Add a second `ToolbarItem` to `BrowserWindow`'s `.toolbar` with a `Toggle` bound to `store.hideEmptyProjects`, labeled "Hide Empty" using `eye.slash` SF Symbol, with a `.help(...)` string. Place it alongside the existing "Link Project…" button.
- [ ] 👁 Step 5: Build and run the app (`./build.sh`); toggle the toolbar control and confirm projects with no outstanding plans disappear/reappear and that the choice survives an app restart.

## Verification
- Toggling the toolbar control hides projects whose tasks are all completed (or that have no tasks) and shows them again when toggled off.
- The toggle state persists across app restarts.
- Projects with at least one outstanding (pending/elaborated/in-progress/review/in-review) task always remain visible.
- `swift test` passes the new `hasOutstandingWork` tests.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/TaskParser.swift` — add `ProjectTasks.hasOutstandingWork` computed property
- [x] `Sources/Plans/PlansStore.swift` — add persisted `hideEmptyProjects` toggle state
- [x] `Sources/Plans/BrowserWindow.swift` — toolbar toggle + filter in `sortedProjects`
- [x] `Tests/PlansTests/` — unit test for `hasOutstandingWork`

### UI Affected
- Browser window toolbar — new "Hide Empty" toggle
- Project card grid — filtered list when toggle is on

## Assumptions

### Initial (from elaboration)
- [high] `hasOutstandingWork` is `!activeTasks.isEmpty`. **Why:** The parser already pre-filters `activeTasks` to exclude `.completed` and nil-status tasks (TaskParser.swift), and `glanceOrder` defines exactly these as outstanding; matches the "No outstanding plans" wording already in ProjectCard.
- [high] Filtering lives in the view (`sortedProjects`), not the store. **Why:** Mirrors the existing #017 manual-order pattern — the store is the data source of truth, UI filter state belongs in the view.
- [high] Persist the toggle globally via UserDefaults. **Why:** Single browser window; identical to the existing `manualOrderActive`/`projectOrderOverride` persistence pattern.
- [low] Toolbar control is a `Toggle` labeled "Hide Empty" with the `eye.slash` symbol. **Why:** A UX/icon choice the source description didn't specify; `eye.slash` reads as hide-semantics and the description omitted exact label/icon.

### Discovered during execution
- [low] Obtained the `$store.hideEmptyProjects` binding via a local `@Bindable var store = store` declared at the top of `body` (changing `body` to `return cardGrid…`), rather than redeclaring the environment property. **Why:** The view holds `store` as `@Environment(PlansStore.self)`, which is not directly bindable; the local `@Bindable` shadow is the standard SwiftUI idiom for binding into an environment `@Observable` while still reading the single shared instance. No second store is introduced.
- [low] Implemented the toolbar control as a `Toggle` wrapping a `Label("Hide Empty", systemImage: "eye.slash")` (matching the elaboration's icon choice). **Why:** A label-based toggle renders cleanly in the macOS toolbar and self-documents the action; a plain text toggle was acceptable but the labeled form matches the adjacent "Link Project…" button's Label style.
- [high] Added the `hasOutstandingWork` test cases to the existing `BrowserWindowTests.swift` instead of a new `ProjectTasksTests.swift`. **Why:** That file already owns the `makeProject`/`makeTask` `ProjectTasks` fixture builders, so extending it avoids duplicating fixtures and keeps the model's view-facing assertions co-located.

## Changes
- `Sources/Plans/TaskParser.swift`: added `ProjectTasks.hasOutstandingWork` computed property (`!activeTasks.isEmpty`).
- `Sources/Plans/PlansStore.swift`: added persisted `hideEmptyProjects: Bool` (UserDefaults key `hideEmptyProjects`), loaded in `init()`, mirroring the `manualOrderActive` pattern.
- `Sources/Plans/BrowserWindow.swift`: `sortedProjects` now filters out projects without outstanding work when `store.hideEmptyProjects` is on; added a "Hide Empty" toolbar `Toggle` (`eye.slash`) bound via a local `@Bindable var store`.
- `Tests/PlansTests/BrowserWindowTests.swift`: added two `hasOutstandingWork` test cases (active → true, empty/completed → false).
- Verified: `swift test --filter BrowserWindowTests` passes (42 tests); `swift build` clean.

## Notes
_Additional context_
