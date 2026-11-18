# Add "Starred" Functionality To Keep Plans Visible

**ID:** 035
**Created:** 2026-06-07T19:23
**Type:** feature
**Status:** completed
**Branch:** feature/035-add-starred-functionality
**Completed:** 2026-06-08T09:45

## What
Add "Starred" functionality at the PROJECT level, which keeps a project's card visible
even when it has "no outstanding plans".

A user can "star" a PROJECT from its card header in the browser dashboard. A starred
project's card stays visible in the dashboard even when it has no outstanding work and
the "Hide Empty" filter is on. (Reworked from an initial plan-level interpretation — see
Assumptions: the intent is to keep empty *projects* visible, not to pin individual plans.)

## Why
Adds value by letting users pin projects they care about so those project cards remain
reachable from the dashboard even after all their plans are done, without being swept out
by the "Hide Empty" project filter.

## How
- [x] Step 1: Add a persisted `starredProjectPaths: Set<String>` to `PlansStore.swift`, keyed by `ProjectTasks.projectPath`. Follow the existing `hideEmptyProjects` pattern: a `didSet` that writes `Array(starredProjectPaths)` to `defaults` under a new `starredProjectsKey`, a `private static let starredProjectsKey = "starredProjects"`, and an eager load in `init()` (`_starredProjectPaths = Set(defaults.stringArray(forKey:) ?? [])`). Never write to `.plans/`.
- [x] Step 2: Add a unit test in `Tests/PlansTests/PlansStoreTests.swift` that stars a project path, then constructs a fresh `PlansStore` over the same isolated `UserDefaults` suite and asserts the star is restored; also assert unstar removes it.
- [x] Step 3: Add `BrowserViewModel.visibleUnderHideEmpty(_ project:starredProjectPaths:)` in `BrowserWindow.swift` returning `project.hasOutstandingWork || starredProjectPaths.contains(project.projectPath)`. Use it in `BrowserWindow.sortedProjects` for the hide-empty filter. Add unit tests in `Tests/PlansTests/BrowserWindowTests.swift` covering: starred-empty kept, unstarred-empty hidden, outstanding-work always kept, another-project-starred doesn't rescue.
- [x] Step 4: Keep `ProjectCard.swift`'s `rows` computed property on `BrowserViewModel.activeRows(project)` — starring is a project-visibility concern, NOT a plan-injection one, so the card body is unchanged.
- [x] Step 5: Add a project star/unstar toggle button to the `ProjectCard` header (`StarToggleGlyph`, `star` / `star.fill`, `.buttonStyle(.plain)`, `.help(...)`), placed right of the project name, toggling membership of `project.projectPath` in `store.starredProjectPaths`.
- [x] Step 6: (folded into Step 3) `BrowserWindow.sortedProjects` hide-empty filter keeps a project when `visibleUnderHideEmpty` is true.
- [x] Step 7: 👁 Build (`swift build`) and run the targeted test files to confirm green, then run the app to visually confirm: star a project, clear its outstanding work, enable "Hide Empty", and confirm the starred project's card stays visible while unstarred empty projects disappear. (User-verified in-app during review; star UI iterated to a white-only, bottom-right footer glyph.)

## Verification
- Star a project from its card header; the header star fills (yellow) and the state persists across app restarts (UserDefaults).
- With "Hide Empty" enabled, a starred project with no outstanding work keeps its card visible, while unstarred empty projects disappear.
- Unstarring an empty project (with "Hide Empty" on) makes its card disappear.
- Targeted tests in `PlansStoreTests.swift` and `BrowserWindowTests.swift` pass; `swift build` succeeds.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/PlansStore.swift` — add persisted `starredProjectPaths: Set<String>` (property, key, init load).
- [x] `Sources/Plans/BrowserWindow.swift` — add `BrowserViewModel.visibleUnderHideEmpty(...)`; use it in `sortedProjects` hide-empty filter to keep starred projects.
- [x] `Sources/Plans/ProjectCard.swift` — add a project star/unstar toggle button to the card header; `rows` stays on `activeRows`.
- [x] `Tests/PlansTests/PlansStoreTests.swift` — persistence round-trip test for `starredProjectPaths`.
- [x] `Tests/PlansTests/BrowserWindowTests.swift` — `visibleUnderHideEmpty` survival/hide tests.

### Related Files (may need updates)
- `Sources/Plans/TaskParser.swift` — `ProjectTasks.activeTasks` / `hasOutstandingWork` are the inputs the starred logic layers on; no change expected, read-only reference.

### Endpoints/UI Affected
- Browser dashboard `ProjectCard` header — new project star toggle glyph (right of the project name).
- "Hide Empty" project filter — starred projects stay visible even with no outstanding work.

## Assumptions

### Initial (from elaboration)
- [high] Persist starred state in UserDefaults (via `PlansStore`), NOT in `.plans/` markdown files. **Why:** `.plans/` is read-only per spec §2; every existing per-user preference (`hideEmptyProjects`, `manualOrderActive`, `projectOrderOverride`, `cardLayoutMode`, `captureDrafts`) already follows this exact pattern.
- [high] Key starred state by the composite `TaskRow.ID` (`projectPath + "/" + task.id`) as a `Set<String>`. **Why:** that composite is already the app's unique cross-project task identity, and a Set matches the existing `stringArray` persistence idiom and gives O(1) membership for row rendering.
- [low] "Keep visible" means: include starred COMPLETED plans in the card body and keep their project visible under "Hide Empty". **Why:** the source description ties starring to the "no outstanding plans" empty state; active plans are already visible, so the only behavior change is surfacing starred non-active (completed) plans. Other interpretations (e.g. pinning to top, separate "Starred" section) were not specified and would be larger scope.
- [low] Starred-completed rows are appended after active rows in `TaskParser` order rather than sorted into a dedicated section or pinned to the top. **Why:** MVP simplicity; preserves the existing parser ordering and avoids introducing a new ordered-store. A dedicated section can be added later if desired.
- [low] No change to the menu bar glance (Surface A) counts or to `MenuBarView`. **Why:** starring is a dashboard/detail concern; the glance is intentionally focused on in-motion work, and the description references the dashboard empty state specifically.
- [low] Stale starred ids (for tasks later deleted from disk) are left in UserDefaults and simply never render. **Why:** harmless, avoids adding a filesystem-deletion listener; matches the app's polling/reload model.

### Discovered during execution
- [high] (Rework during review) The original implementation starred PLANS (individual task rows); the actual intent is to star PROJECTS (cards) so an empty project's card stays visible under "Hide Empty". Reworked: `starredTaskIDs`→`starredProjectPaths` (keyed by `projectPath`), removed `BrowserViewModel.starredRows` and `projectHasStarredTask`, reverted `ProjectCard.rows` to `activeRows`, moved the star toggle from each plan row to the card header, and replaced the hide-empty filter with `BrowserViewModel.visibleUnderHideEmpty`. **Why:** the user clarified the intent at review; the plan-level notes below predate that correction and are kept for history.
- [high] `starredRows` filters starred-completed candidates from `project.tasks` by `status == .completed`, then excludes any id already present in `activeRows` to avoid duplication. **Why:** the plan said "do not duplicate a task already in activeTasks"; deriving `activeIDs` from the active rows and subtracting is the simplest correct dedup and reuses the existing composite-id identity.
- [low] Persistence test inserts/removes ids via direct mutation of `store.starredTaskIDs` (insert/remove/assignment) rather than introducing star/unstar helper methods. **Why:** the segment scope only specified the persisted property (no helper API was requested); the later UI steps can add toggling helpers if desired. Mirrors how `projectOrderOverride` is exercised directly in its persistence tests.
- [low] Pre-existing PlansStoreTests failures (`testReloadPopulatesProjectsWithCounts`, `testReloadHandlesMultipleProjectsInRegistryOrder`, `testStartPollingPerformsInitialLoadSynchronously`, `testLinkProjectWritesRegistryAndReloadsSoProjectAppears`) assert lowercase `projectName` ("alpha") but get capitalized ("Alpha") from the macOS case-insensitive temp filesystem. **Why:** unrelated to this segment (those lines were never edited); flagged as a pre-existing environment-dependent issue, not introduced here.
- [low] (Segment 2) The star toggle + Elaborate/Execute action share ONE trailing GridRow cell via an `HStack(spacing: 0)` (`starToggle(row)` then `rowActions(row)`), rather than adding a second trailing GridRow column. **Why:** keeps Grid's cross-row column count/alignment intact (the step offered either layout); a single trailing column avoids re-aligning every existing row and keeps the action cell's behavior unchanged.
- [low] (Segment 2) `StarToggleGlyph` is a `Button(.buttonStyle(.plain))` with only hover-background feedback, dropping `RowActionGlyph`'s min-distance-0 drag-gesture press/scale feedback. **Why:** the step's contract explicitly asked for a `Button` with `.buttonStyle(.plain)`; combining a Button action with the drag gesture would double-fire the toggle, so the Button alone owns the tap and hover conveys interactivity.
- [low] (Segment 2) The toggle action mutates `store.starredTaskIDs` directly (`.insert`/`.remove`) from the view that holds `@Environment(PlansStore.self)`, without `@Bindable`. **Why:** `PlansStore` is an `@Observable` reference type, so mutating a `var` property in place works and triggers the persisted `didSet`; no binding wrapper is needed.
- [high] (Segment 2) `projectHasStarredTask` scans `project.tasks` (all tasks, not just active) for a composite id in `starredIDs`. **Why:** the hide-empty filter must keep a project visible when its ONLY starred plan is completed (absent from `activeTasks`), so the predicate must consider the full task set.

## Changes
- Segment 1 (steps 1-3):
  - `PlansStore.swift`: added persisted `starredTaskIDs: Set<String>` (property + `starredTasksKey` + eager `init()` load), matching the `hideEmptyProjects` persistence pattern.
  - `BrowserWindow.swift`: added pure `BrowserViewModel.starredRows(_:starredIDs:)` returning active rows plus starred-completed rows (deduped, appended after active rows).
  - `PlansStoreTests.swift`: persistence round-trip tests for `starredTaskIDs` (insert/remove across fresh stores) — pass.
  - `BrowserWindowTests.swift`: `starredRows` tests (inclusion, exclusion of unstarred-completed, append ordering, no-duplicate) — pass.

## Notes
_Additional context_
