# Add Cross-Project Smart-View Sidebar And Task List

**ID:** 094
**Created:** 2026-11-07T11:48
**Type:** feature
**Status:** completed
**Completed:** 2026-11-07T13:12
**Branch:** feature/094-add-cross-project-smart-view-sidebar

## What
Layout redesign step 1 (see `layout-redesign.md`): add a `NavigationSplitView` sidebar and a cross-project task list, next to the existing card grid.

- **Sidebar pinned area:**
  - (a) smart status views covering all projects: In Progress, Review (one row covering both `review` and `in-review`), Blocked, Failed, Backlog. Icons and labels come from `TaskStatus+Glance` / `filterLabel`.
  - (b) starred projects, shown as favourites.
  - (c) a summary strip of in-progress / review / failed totals, modelled on `iconSpaceCounts` / `failedCount`.
- **Projects section** below the pinned area, in staleness or manual order.
- **Middle column:** a flat `TaskRow` list, labelled by project, that can be grouped and sorted by status, project or staleness. Task staleness sorts on `Task.modified`, falling back to `created`.
- Picking a project shows that project's flat list. The card grid stays reachable as its own "All projects" entry.
- Add a pure `BrowserViewModel` helper (e.g. `rows(in:matchingStatus:)`), test-first.
- View state persists to UserDefaults through `PlansStore`, never to `.plans/`.

This closes the spec gap in `desktop-app-spec.md` §1 Surface B and §8 item 5.

## Why
Closes the spec gap in `desktop-app-spec.md` §1 Surface B and §8 item 5. Today you can't filter by status across every project at once, e.g. "show me everything in review." This adds that as a set of always-present sidebar views.

## How Summary
Wrap `BrowserWindow.body` in a `NavigationSplitView` with two columns:
- **Sidebar:** a summary strip, smart status views, Favourites, an "All projects" entry, and Projects.
- **Content column:** for "All projects", the existing `cardGrid`, unchanged. For anything else, a flat, grouped and sortable `TaskListView`.

Filtering, staleness, sorting, grouping and totals live in pure `BrowserViewModel` helpers. `PlansStore` saves the sidebar selection and the sort/group setting to UserDefaults. The row action buttons and their sheets move out of `ProjectCard` into a shared component, so card rows and list rows offer the same actions. The detail overlay stays as it is; #095 moves it.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — `body` becomes the split view; new `BrowserViewModel` helpers.
- `Sources/Plans/PlansStore.swift` — saved `browserSelection` and task-list sort/group settings.
- `Sources/Plans/ProjectCard.swift` — `rowActions` and the five action sheets move into the shared component.
- `Sources/Plans/TaskStatus+Glance.swift` / `TaskType+Glyph.swift` — labels and icons for the smart views (`filterLabel`, `symbolName`, `TaskStatusIndicator`).
- `Tests/PlansTests/BrowserWindowTests.swift`, `Tests/PlansTests/PlansStoreTests.swift` — new tests for the helpers and saved settings.

## How
- [x] Step 1: Test-first: add the smart-view helpers to `BrowserViewModel`.
  - A `SmartView` enum: `inProgress`; `review`, which matches both `.review` and `.inReview`; `blocked` (`isBlocked`, active rows only); `failed` (`failure != nil`); and `backlog`, which collects `backlogRows`.
  - Each case gets a label, icon and colour from the existing vocabulary (`filterLabel`, `symbolName`, `glanceColor`, `TaskStatusIndicator` blocked/failure). Add any new labels in `TaskType+Glyph.swift`, not inline in views.
  - Add `rows(in:matching:)` and `summaryCounts(in:)`. The in-progress/review/failed totals must agree with `iconSpaceCounts` and `failedCount`.
  - Extend the `makeTask` fixture with `failure:`, `modified:` and `created:`.
- [x] Step 2: Test-first: task staleness, sorting and grouping.
  - `taskStalenessDate(_:)` uses `Task.modified` (`Date(timeIntervalSinceReferenceDate:)`). It falls back to `created`, parsed with a POSIX `yyyy-MM-dd'T'HH:mm` formatter and then date-only `yyyy-MM-dd`. `parseLastSeen`'s ISO8601 parsing can't read `created`.
  - `sortRows(_:by:)` sorts by `.status` (`activePriority`), `.project`, or `.staleness`: newest first, undated last, stable.
  - `groupRows(_:by:)` returns titled sections.
- [x] Step 3: Test-first: add a `SidebarSelection` enum (`allProjects`, `smart(SmartView)`, `project(path)`).
  - Give it a string encoding that splits on the first `:` only, so paths containing `:` or `/` survive.
  - A selection pointing at a project that no longer exists falls back to `.allProjects`.
  - Add `PlansStore.browserSelection` (default `.allProjects`) and the task-list sort/group setting (one setting shared by every list). Follow the `projectViewMode` pattern: `didSet` write, a static key, and a backing-field load in `init`. Add round-trip tests through `makeDefaults()`.
- [x] Step 4: Move `ProjectCard.rowActions`, the five request structs and their `.sheet(item:)` modifiers into a shared `PlanRowActions` view that holds its own sheet state.
  - `ProjectCard` switches to it. Keep `ProjectCard`'s init signature unchanged.
  - `ProjectCardTests` and the DEBUG preview must keep compiling and passing.
- [x] Step 5: Build `TaskListRow` and `TaskListView`.
  - `TaskListRow` reuses `ProjectCard.rowColumns`, `rowStyling`, `titleSizing` and `failureTooltip`. It adds a project label when the list spans projects, uses `PlanRowActions`, and opens detail on tap via `detailRowID`.
  - `TaskListView` shows the grouped/sorted rows, has a sort/group control, and has an empty state.
  - A project's list is its `activeRows`, plus `backlogRows` when `showBacklog` is on.
- [x] Step 6: Restructure `BrowserWindow.body` into a two-column `NavigationSplitView`, from the top of the sidebar down:
  - A summary strip whose counts select the matching smart view when clicked.
  - The smart views.
  - Favourites: starred projects.
  - "All projects", which shows the unchanged `cardGrid`.
  - Projects, in manual order (`applyManualOrder`) or by staleness (`sortByStaleness`), and not filtered by view mode or focus.

  Keep `.sheet(newPlanRequest)`, the detail `.overlay` (covering the whole window), the ⌘N `.onChange` and the main `.toolbar` on the outer view. The menu-bar drill-down (`store.selectedProjectPath`) now selects `.project(path)` in the sidebar. Raise the window minimum width and add a `defaultSize` on the `Window` scene in `PlansApp.swift`.
- [x] 👁 Step 7: Run `./build.sh` and check by hand: _(✓ user confirmed at review)_
  - The Review view lists `review` and `in-review` tasks from every project, each labelled with its project.
  - Sorting and grouping work.
  - Favourites match the stars.
  - Summary counts match the menu bar.
  - The row action buttons open their sheets from list rows.
  - "All projects" behaves exactly as the grid does today.
  - The sidebar selection survives a relaunch.
  - Clicking a project in the menu bar lands on that project's list.

## Verification
- `swift test` passes, including new tests for: smart-view filtering (the Review view combines `review` and `in-review`; Blocked/Failed/Backlog), summary totals matching `iconSpaceCounts`/`failedCount`, task staleness (with the `created` fallback), sorting and grouping, the `SidebarSelection` string round-trip and its fallback for missing projects, and saving the store settings.
- Existing `BrowserWindowTests`, `ProjectCardTests` and `PlansStoreTests` still pass unchanged.
- The manual check in Step 7 passes.

## Impact Scope
### Files to Modify
- [ ] `Sources/Plans/BrowserWindow.swift` — split-view `body`, sidebar, `BrowserViewModel` helpers, `SidebarSelection`.
- [ ] `Sources/Plans/PlansStore.swift` — `browserSelection` and sort/group settings, with keys and `init` loading.
- [ ] `Sources/Plans/ProjectCard.swift` — row actions and sheets move out to `PlanRowActions`.
- [ ] `Sources/Plans/TaskType+Glyph.swift` — labels for Blocked/Failed/Backlog, if needed.
- [ ] `Sources/Plans/PlansApp.swift` — `defaultSize` on the browser `Window`.
- [ ] New: `PlanRowActions`, `TaskListRow`/`TaskListView` (new files in `Sources/Plans/`).
- [ ] `Tests/PlansTests/BrowserWindowTests.swift`, `Tests/PlansTests/PlansStoreTests.swift` — new tests.

### Related Files (may need updates)
- `Sources/Plans/MenuBarView.swift` — sets `selectedProjectPath` for the drill-down.
- `Sources/Plans/TaskStatus+Glance.swift` — reused icons and colours.
- `Sources/Plans/PlanDetailView.swift` — its `can*` action checks are reused by `PlanRowActions`.

### Endpoints/UI Affected
- Browser window: a new sidebar and task list. The card grid can be reached through "All projects"; it isn't changed.

## Assumptions

### Initial (from elaboration)
_To be filled during elaboration_

### Discovered during execution
- [high] `SidebarSelection` is encoded as a plain string splitting on the FIRST `:` only: `"all"`, `"smart:<rawValue>"`, `"project:<path>"`. **Why:** a project path can contain `:` or `/`; splitting on the first colon keeps the path verbatim in the suffix, so the round trip is lossless for arbitrary paths.
- [high] `SmartView`, `TaskSort`, `TaskGroup` are `String`-rawValue enums; `SidebarSelection` is a top-level `enum` in `BrowserWindow.swift` (kept with the browser code, not nested in `BrowserViewModel`). **Why:** matches the existing placement of `TaskRow`/`NewPlanRequest` as top-level browser types; rawValue gives free stable persistence for the sort/group settings and the smart-view component of the selection.
- [high] Default sort is `.staleness`; default group is `.project`. Sort and group are TWO separate settings (`taskSort`, `taskGroup`), not one. **Why:** the segment spec suggested `.staleness` default and allowed either one or two settings; two reads more clearly because grouping-by-status while sorting-by-staleness is a sensible combination that a single enum could not express. Both persist independently via the `rawValue` + `didSet` + `static key` + init-backing-field idiom.
- [high] `TaskGroup` has only `.status` and `.project` cases (no staleness bucket). `.status` grouping COMBINES `.review` + `.inReview` into one "Review" section and puts `nil`-status rows in a trailing "Other" section. **Why:** a staleness bucket needs date-bucketing policy the spec did not pin down; status/project cover the useful grouping dimensions and reuse existing `filterLabel`/`projectName` vocabulary directly. Section order and within-section order are stable (first-appearance order).
- [high] `summaryCounts` counts over each project's full `tasks` array (not `activeRows`), mirroring `PlansStore.iconSpaceCounts` (which sums `project.counts`) and `failedCount` (which filters `project.tasks` on `failure != nil`). **Why:** the spec requires the summary strip to AGREE with the store's semantics; counting over `tasks` is the same population the store uses, so the numbers line up exactly. (Review = review + in-review, as `iconSpaceCounts` treats them.)
- [low] The "Backlog" smart-view label/icon/color were added as static vocabulary: `TaskStatus.backlogFilterLabel`/`backlogSymbolName` in `TaskType+Glyph.swift` (where `filterLabel` lives) and `TaskStatus.backlogGlanceColor` in `TaskStatus+Glance.swift` (where the palette lives). Icon reuses `archivebox` (the #077 toolbar toggle glyph); color reuses the muted `.pending` gray. **Why:** backlog is a source directory, not a `TaskStatus`, so it has no existing vocabulary; reusing the archivebox glyph keeps it consistent with the existing backlog affordance, and the spec forbids inline labels/icons in views.
- [high] (Segment 2) The five per-row request structs (`ReElaborateRequest`/`ElaborateRequest`/`ExecuteRequest`/`ExecutePendingRequest`/`ReviewReElaborateRequest`) AND `RowActionGlyph` moved out of `ProjectCard.swift` into the new `Sources/Plans/PlanRowActions.swift`, changing visibility from `private` to internal (file-scoped `struct`, module-visible). The five `.sheet(item:)` modals and their `@State` request vars moved there too; `PlanRowActions` owns its own action-sheet state and reads `PlansStore`/`TaskRunner` from the environment itself. **Why:** both `ProjectCard.planRow` and the new `TaskListRow` need the identical action control + its consent-gate modals; one shared `View` that owns its state avoids duplicating the branch logic and keeps the card and the cross-project list byte-identical. The request structs had no other reference site, so moving (not copying) them is lowest-churn.
- [high] (Segment 2) `RunProgressSheet` was NOT moved — it is already a top-level non-`private` struct in `PlanDetailView.swift`, so it is module-visible to both `PlanRowActions` (running branch) and `ProjectCard` (capture rows). No visibility change needed. **Why:** it was never private; leaving it in place is zero-churn.
- [high] (Segment 2) `OpenDetailOnTap` STAYED in `ProjectCard.swift` but changed from `private` to internal so `TaskListRow` reuses the same tap-to-open-detail seam. `ProjectCard`'s per-row spinner-toggle popover state (`progressPopoverTaskID` / `progressPopover(for:)`) stayed on `ProjectCard` because `captureRow` still needs it; `PlanRowActions` uses its own row-local `@State progressPopoverOpen` bool instead (one actions view per row, so no id disambiguation is needed). **Why:** lowest-churn placement; the card's capture-row popover is unrelated to the per-row action control.
- [high] (Segment 2) `TaskListView` accepts PRE-RESOLVED `rows: [TaskRow]` plus `showsProjectLabel: Bool` and `onOpenDetail:` — it does NOT take `projects` + a selection. The active+backlog resolution (and the `showProjectLabel` decision) is left to Segment 3 wiring. **Why:** the spec allowed either; pre-resolved rows is the flexible, testable shape and keeps the selection→rows mapping in one place upstream rather than split across the view.
- [low] (Segment 2) The sort/group control is TWO `Menu`s (not `Picker`s) mirroring the `ProjectViewMode` toolbar idiom: each lists all cases as `Label(..)` buttons and its own label renders the current choice as `.titleAndIcon` text ("Sort: Recent" / "Group: Project"). Display strings live in file-scoped `TaskSort.menuLabel`/`menuSymbol` + `TaskGroup.menuLabel`/`menuSymbol` extensions in `TaskListView.swift` (sort labels: Status/Project/Recent; group labels: Status/Project). **Why:** `TaskSort`/`TaskGroup` are pure value enums with no view vocabulary; keeping the strings in the view file avoids widening the enums, and `Menu` matches the existing toolbar select pattern (named options up front, visible current selection).
- [low] (Segment 2) `TaskListRow` adds a fixed-width 120pt leading project-label column (shown only when `showsProjectLabel`); the status/id/type/title columns and trailing `PlanRowActions` reuse `ProjectCard.rowColumns`/`rowStyling`/`titleSizing`/`failureTooltip`. Hover is tracked row-locally (no shared hovered-id) and `TaskListView` renders titled sections from `sortRows` → `groupRows`, with section-local zebra indexing and a centered "No tasks" empty state. **Why:** reusing the card's pinned metrics keeps a task visually identical across card and list; 120pt is a reasonable fixed project-name budget pending Segment 3 visual review.
- [high] (Segment 3, step 6) `BrowserWindow.body` is now a `NavigationSplitView { sidebar } detail: { contentColumn }`. The sidebar is a single SwiftUI `List(selection:)` of `Section`s; selection round-trips with `store.browserSelection` via a computed `Binding<SidebarSelection?>` whose getter runs `BrowserViewModel.resolve(...)` and whose setter ignores a nil (clear) so a click into empty space never drops the selection. Each row carries a `.tag(SidebarSelection...)`. **Why:** a selectable `List` is the idiomatic macOS sidebar; one binding keeps the persisted selection and the highlighted row in sync without a second source of truth.
- [high] (Segment 3, step 6) `SmartView` and `SidebarSelection` gained `Hashable` conformance (in addition to `Equatable`). **Why:** `List(selection:)` / `.tag(_:)` require `Hashable`; both are pure value enums over `String`/`SmartView` so synthesis is free and `Hashable` strictly widens `Equatable`.
- [low] (Segment 3, step 6) The summary strip renders as a `List` row (an `HStack` of capsule pills) at the TOP of the sidebar rather than above the `List`; the smart-view counts are shown as a trailing number on each smart-view row. **Why:** keeping the strip inside the `List` means one scrollable column with consistent insets; pills reuse each `SmartView.color`/`symbolName` so the strip needs no new vocabulary.
- [high] (Segment 3, step 6) Summary-strip zero totals ARE suppressed (a pill renders nothing when its count is 0, so an all-zero strip collapses to an empty row), matching the menu-bar glance's empty-count suppression. Smart-view row counts are likewise hidden at zero. **Why:** the spec made suppression optional and pointed at the menu-bar behaviour; suppressing avoids a wall of zeros.
- [high] (Segment 3, step 6) The sidebar "Projects" section (and the Favourites subset) is ordered by the SAME rule as the card grid — `applyManualOrder` when `manualOrderActive && !projectOrderOverride.isEmpty`, else `sortByStaleness` — but is DELIBERATELY NOT filtered by `projectViewMode` or focus. Favourites = that ordered list filtered to `starredProjectPaths`; the section is omitted when empty. **Why:** the sidebar must expose every project regardless of the all-projects view's filters, while still honouring the user's manual order.
- [high] (Segment 3, step 6) Menu-bar drill-down is wired via `.onAppear` + `.onChange(of: store.selectedProjectPath)` on the OUTER split view calling `selectDrillDownProjectIfLive()`, which sets `store.browserSelection = .project(path)` only when the path names a live project. The existing `cardGrid` scroll-to-project `.onChange` is left intact for the all-projects case. **Why:** the drill-down's primary effect is now selecting the project's task list; guarding on a live project prevents stranding the selection on a dead path.
- [high] (Segment 3, step 6) Window sizing: `.frame(minWidth: 820, minHeight: 520)` on the `NavigationSplitView` (up from the old single-pane `minWidth: 480`) and `.defaultSize(width: 1100, height: 720)` on the `Window("Plans", id: "browser")` scene in `PlansApp.swift`. The sidebar `List` also carries `.frame(minWidth: 220)`. **Why:** 820 comfortably fits a ~220–240pt sidebar plus a usable content column; 1100×720 opens roomy without dominating a laptop screen.
- [high] (Segment 3, step 6) No new sidebar file was created — the sidebar, summary strip, content-column dispatch, and drill-down helper are private members added to `BrowserWindow` in `BrowserWindow.swift`. **Why:** they are tightly coupled to `BrowserWindow`'s `@State` (`detailRowID`) and `cardGrid`; keeping them in the same type avoids threading state through a separate view.

## Changes

### Segment 1 (steps 1–3) — pure helpers + persisted settings (test-first)
- `Sources/Plans/BrowserWindow.swift`: added `SmartView` enum (`.inProgress`, `.review` [review+in-review], `.blocked`, `.failed`, `.backlog`) with label/icon/colour from the existing vocabulary; `BrowserViewModel.rows(in:matching:)`, `summaryCounts(in:)` (totals agree with `iconSpaceCounts`/`failedCount`); `taskStalenessDate(_:)` (uses `Task.modified`, falls back to POSIX `yyyy-MM-dd'T'HH:mm` then `yyyy-MM-dd` parse of `created`); `TaskSort` + `sortRows(_:by:)` (.status/.project/.staleness, newest-first/undated-last/stable); `TaskGroup` + `groupRows(_:by:)` (.status [review combined], .project); `SidebarSelection` enum (`.allProjects`/`.smart`/`.project`) with first-`:`-split string encoding; `BrowserViewModel.resolve(_:in:)` (missing-project → `.allProjects`).
- `Sources/Plans/PlansStore.swift`: added persisted `browserSelection` (default `.allProjects`), `taskSort` (default `.staleness`), `taskGroup` (default `.project`) — each via the `didSet`/static-key/init-backing-field idiom.
- `Sources/Plans/TaskType+Glyph.swift` / `TaskStatus+Glance.swift`: added Backlog vocabulary statics (`backlogFilterLabel`, `backlogSymbolName` = `archivebox`, `backlogGlanceColor`).
- `Tests/PlansTests/BrowserWindowTests.swift`: extended `makeTask` with `failure:`/`modified:`/`created:`; tests for smart-view rows/summary totals, staleness (`created` fallback), sort/group, `SidebarSelection` round-trip (incl. path with `:`/`/`) and fallback.
- `Tests/PlansTests/PlansStoreTests.swift`: default + persistence round-trip tests for the three new settings.
- Tests: `swift test --filter BrowserWindowTests` → 134 pass; `swift test --filter PlansStoreTests` → 119 pass.

### Segment 2 (steps 4–5) — shared actions component + task list views
- NEW `Sources/Plans/PlanRowActions.swift`: `PlanRowActions` view encapsulating the 5-branch row-action logic (`.frame(height: 22)`), the five request structs, five `@State` request vars + five `.sheet(item:)` modals, and `RowActionGlyph`; reads `PlansStore`/`TaskRunner` from the environment. Card rows and list rows now share identical actions.
- `Sources/Plans/ProjectCard.swift`: `planRow` renders `PlanRowActions(row:)`; removed the dead `rowActions(_:)`, five request vars/structs, five sheets, and `RowActionGlyph`; `OpenDetailOnTap` made internal. Init signature and all static helpers unchanged (ProjectCardTests + DEBUG preview still compile).
- NEW `Sources/Plans/TaskListView.swift`: `TaskListRow` (flat cross-project row reusing the card's `rowColumns`/`rowStyling`/`titleSizing`/`failureTooltip`, optional project-label column, `PlanRowActions`, tap-to-open via `OpenDetailOnTap`) and `TaskListView` (pre-resolved rows + `showsProjectLabel` + `onOpenDetail`; sorts via `sortRows(_:by: store.taskSort)`, groups via `groupRows(_:by: store.taskGroup)`, titled sections, two-`Menu` sort/group control, centered "No tasks" empty state).
- Tests: `swift build` clean; `swift test --filter ProjectCardTests` → 37 pass; `swift test --filter BrowserWindowTests` → 134 pass.

### Segment 3 (steps 6–7) — NavigationSplitView sidebar + wiring
- `Sources/Plans/BrowserWindow.swift`: `body` is now `NavigationSplitView { sidebar } detail: { contentColumn }`. Sidebar is a single `List(selection:)` bound to `SidebarSelection` (getter resolves via `BrowserViewModel.resolve`): a clickable summary strip (in-progress/review/failed pills → matching smart view; zero totals suppressed), a "Smart Views" section (one row per `SmartView` case, tinted icon + label + trailing count), an optional "Favourites" section (starred projects; omitted when none), an "All Projects" entry, and a "Projects" section (all projects, manual-order-or-staleness, unfiltered by view mode/focus). Content column dispatches on the resolved selection: `.allProjects` → the unchanged `cardGrid`; `.smart(view)` → `TaskListView(rows: rows(in:matching:), showsProjectLabel: true, …)`; `.project(path)` → `TaskListView` over `activeRows(project)` (+ `backlogRows` when `showBacklog`), `showsProjectLabel: false`. The outer view keeps the `newPlanRequest` sheet, the `detailOverlay` + its animation, the ⌘N `onChange`, and the main `.toolbar`; the card grid retains its own inner toolbar/drill-down scroll. Menu-bar drill-down (`store.selectedProjectPath`) now selects `.project(path)` via `.onAppear`/`.onChange`. Split view min-width raised to 820. Added `Hashable` to `SmartView`/`SidebarSelection` (required by `List(selection:)`/`.tag`).
- `Sources/Plans/PlansApp.swift`: added `.defaultSize(width: 1100, height: 720)` to the `Window("Plans", id: "browser")` scene.
- Step 7 (👁 manual observation) is DEFERRED to review per worktree mode — the implementation compiles and is wired, but the by-hand checks (and `./build.sh`) were not performed.
- Tests: `swift build` clean; `swift test --filter BrowserWindowTests` → 134 pass; `swift test --filter PlansStoreTests` → 119 pass; `swift test --filter ProjectCardTests` → 37 pass.

## Notes
Decisions made while discussing this task:
- All three readings of "pinned" are in scope.
- One combined Review row.
- Picking a project shows a flat list.
- List rows get the full shared action buttons.
- Only the sidebar selection is saved (default "All projects").
- The menu-bar drill-down selects the project's list.

Defaults I chose (change them if you want):
- Blocked and Failed look at active rows only.
- One sort/group setting is shared across all lists.
- The Projects section ignores the view-mode filter and focus.
- Summary counts select their smart view when clicked.

Watch out: `Task` shadows Swift Concurrency's `Task` in this module. Don't make sidebar project rows draggable as `String`; the cards' `.dropDestination(for: String.self)` would accept them.

First of three tasks (#094 → #095 → #096).
