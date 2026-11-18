# Fold Card Grid Into Sidebar As All Projects View

**ID:** 096
**Created:** 2026-11-07T11:48
**Type:** refactor
**Status:** completed
**Completed:** 2026-11-07T14:31
**Branch:** refactor/096-fold-card-grid-into-sidebar

## What
Layout redesign step 3 (see `layout-redesign.md`): make the existing card grid one selectable "All projects" entry in the sidebar, so project-based and status-based browsing share one window.

Keep the card behaviours intact: `.fit` and masonry layouts, focus mode, drag reorder, zebra rows, the backlog section, the git footer and capture. Picking a single project still shows the flat task list from #094, not a card.

## Why
After #094 and #095 the grid works under "All projects", but it still acts like the root of the window. Its toolbar items show up everywhere, the Starred view mode duplicates the sidebar's Favourites, and the drill-down's scroll-to-card code is dead. This task makes the grid a clean citizen of the split view without losing any card behaviour.

## How Summary
Pull the grid out of `BrowserWindow` into its own `CardGridView`, used as the "All projects" content. Grid-only toolbar items move with it, so they only appear when the grid is showing. `ProjectViewMode.starred` is dropped because sidebar Favourites cover it. The old drill-down scroll path is removed. Fit and focus sizing are checked inside a column.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — `cardGrid` and its grid helpers, `cardCell`, `handleDrop`, `sortedProjects`, and both `.toolbar` blocks (L333–434, L600–641).
- New `Sources/Plans/CardGridView.swift` — the extracted grid.
- `Sources/Plans/ProjectViewMode.swift` — drop `.starred`.
- `Sources/Plans/PlansStore.swift` — `projectViewMode` loading falls back to `.all`.
- `Tests/PlansTests/BrowserWindowTests.swift` — the `visibleUnderViewModeStarred*` tests and the layout tests that must keep passing.

## How
- [x] Step 1: Test-first: drop `ProjectViewMode.starred`.
  - A saved `"starred"` value loads as `.all` (add a `PlansStoreTests` case).
  - Remove or rewrite `testVisibleUnderViewModeStarred*` in `BrowserWindowTests` on purpose, so they don't just fail.
  - Update `visibleUnderViewMode` and the menu labels.
- [x] Step 2: Move the grid into `CardGridView`.
  - Move: `cardGrid`, `fitCardGrid`, `focusCardGrid`, `variableCardGrid`, `cardCell`, `handleDrop`, `sortedProjects`, `effectiveFocusPath`, the `gridWidth`/`gridHeight`/`dropTargetPath` state, and `GridWidthKey`/`GridHeightKey`.
  - Pass `onNewPlan` and `onOpenDetail` (setting #095's `selectedRowID`) in as closures.
  - Leave the static layout helpers on `BrowserWindow`, or add forwarding wrappers, so existing tests compile unchanged.
- [x] Step 3: Make the toolbar depend on what's showing.
  - Always on the root view: New Plan, Link Project, and the backlog toggle (it also affects the project lists).
  - On `CardGridView`'s own `.toolbar`: the All/Active view-mode menu, the layout toggle, "Sort by Recency", and "Show All Projects" (exit focus).
  - Check where these land on macOS 15.
- [x] Step 4: Remove `scrollToSelectedProject` and the `selectedProjectPath` scroll handling in the grid. #094 already makes the drill-down select the project in the sidebar. Make sure the ⌘N `.onChange(of: store.newPlanTrigger)` stays on the root view, not the grid.
- [x] Step 5: Check fit and focus inside a column.
  - `focusCardGrid` must account for toolbar and safe-area insets.
  - Set a content-column minimum width so fit mode doesn't fall back to scroll at the default window size.
  - "Show All Projects" must stay visible after relaunching into a saved focus.
  - Opening a card's sheet and then switching the sidebar away closes it. That's acceptable; just confirm nothing crashes.
- [x] Step 6: Update `CLAUDE.md` (the Surface B description) and the doc comments in `BrowserWindow.swift` and `ProjectCard.swift` that still describe a full-window dashboard.
- [x] Step 6a: (scope change, 2026-11-07) Replace the grid with a single vertical scrolling stack. Two layout loops (fit-mode inset probe, then drag reorder in the masonry column) showed the column-measuring grid was fragile inside a split-view column. Decisions:
  - "All projects" is a plain `ScrollView` + `VStack` of full-width, natural-height cards.
  - No grid, masonry, fit mode, layout toggle or width/height probes.
  - Focus mode is dropped (sidebar project selection covers it).
  - Drag reorder is kept, sharing the manual order with the sidebar.
  - Zebra rows, backlog, git footer, capture, action sheets, Sort by Recency and the All/Active menu are kept.
- [x] 👁 Step 7: Run `./build.sh` and check by hand under "All projects":
  - The vertical card stack scrolls, and drag reorder works without hanging, including at a narrow content column. Manual order is shared with the sidebar's Projects list, so reordering in one should reorder the other.
  - Zebra rows, the backlog section, the git footer, capture, and the card action sheets.
  - The grid-only toolbar items disappear when you select a smart view or a project.

## Verification
- `swift test` passes. Tests for grid-only helpers that were removed (`columnCount`, `columnAssignments`, `evenRowHeights`, `isFocusedSingleCard`, `focusedCardHeight`, `rowIndices`, `visibleUnderFocus`, layout-mode persistence) are deleted along with the code. Manual order/`reorder`, `shouldOpenNewPlan`, `ProjectCardTests`, the view-mode tests and the stale-`"starred"` test still pass. Stale saved `cardLayoutMode` and focus values are ignored harmlessly.
- The manual check in Step 7 passes, and the app doesn't hang when reordering or resizing.

## Impact Scope
### Files to Modify
- [ ] `Sources/Plans/BrowserWindow.swift` — grid moved out, toolbar split.
- [ ] `Sources/Plans/CardGridView.swift` (new) — the extracted grid and its toolbar.
- [ ] `Sources/Plans/ProjectViewMode.swift` — drop `.starred`.
- [ ] `Sources/Plans/PlansStore.swift` — fallback when loading a stale value.
- [ ] `Tests/PlansTests/BrowserWindowTests.swift`, `Tests/PlansTests/PlansStoreTests.swift` — view-mode tests.
- [ ] `CLAUDE.md` — Surface B description.

### Related Files (may need updates)
- `Sources/Plans/ProjectCard.swift` — doc comments; its init signature is unchanged.
- `Sources/Plans/MenuBarView.swift` — drill-down (behaviour already moved in #094).

### Endpoints/UI Affected
- The toolbar changes with the sidebar selection. The view-mode menu loses Starred.

## Assumptions

### Initial (from elaboration)
_To be filled during elaboration_

### Discovered during execution
- [high] Dropped the `starredProjectPaths:` parameter from `BrowserViewModel.visibleUnderViewMode` instead of leaving it unused. **Why:** with `.starred` gone nothing reads it. The only callers were the grid and the view-mode tests, and both are in scope.
- [high] Removed the three starred view-mode tests (`ActiveFiltersStarredButEmptyProject`, `StarredKeepsStarredProject`, `StarredFiltersUnstarredProjectWithWork`) and replaced them with `testProjectViewModeCasesAreAllAndActive` and `testProjectViewModeNextCyclesBetweenAllAndActive`. **Why:** the Active-starred test only meant something while the starred-paths input existed. The two Starred tests exercise a case that no longer exists.
- [low] Kept the view mode as a `Menu` even though it now has only two options, rather than switching to a toggle button. **Why:** this keeps the readable "All"/"Active" text label and the control's shape unchanged. The task only says "update the menu labels", so a different control was out of scope.
- [low] Changed the view-mode help text to "Show all projects or only those with outstanding work". **Why:** the old text mentioned starred projects. The new wording is a guess.
- ~~[high] Made the grid's project derivation a static, pure `CardGridView.gridProjects(_:manualOrderActive:order:viewMode:focusedProjectPath:)` plus `CardGridView.effectiveFocusPath(_:in:)`. **Why:** `BrowserWindow.displayedRows` still needs the grid's visible projects to keep the detail-selection valid. A shared static gives one source of truth and avoids duplicating the code or hoisting grid state back into the root view. Covered by two new `BrowserWindowTests` cases.~~ **Superseded (Step 6a):** focus is gone, so this is now `ProjectStackView.stackProjects(_:manualOrderActive:order:viewMode:)` with no focus parameter, and `effectiveFocusPath` is removed.
- [low] Moved `scrollToSelectedProject` and its `.onAppear`/`.onChange(of: store.selectedProjectPath)` into `CardGridView` along with `cardGrid`, without changing them. **Why:** they depend on the grid's `ScrollViewReader` proxy, so the extraction required the move. Step 4 deletes them. The ⌘N `.onChange(of: store.newPlanTrigger)` stays on the root view.
- [low] The grid-only toolbar items use `ToolbarItem` with the default `.automatic` placement, attached to the grid's `ScrollView` inside `CardGridView`. **Why:** on macOS 15, `.automatic` items on a NavigationSplitView content-column view merge into the window toolbar above that column and go away when the view is replaced. Where they actually land and in what order still needs the Step 7 manual check.
- ~~[high] `rowIndices` stays on `BrowserWindow` next to the other static layout helpers, and `CardGridView` calls `BrowserWindow.*` for all layout math. **Why:** the existing layout tests then compile without changes.~~ **Superseded (Step 6a):** `rowIndices` and every other grid layout helper were deleted with the grid.
- [high] Kept `.id(project.projectPath)` on each card when removing the drill-down scroll, and only changed its comment. **Why:** the grid `ForEach`es iterate indices, so the id is what keys a card's `@State` (type filter, hover, open popover) to its project across reorder, filter and focus changes. It was never only a scroll target. **Step 6a note:** the stack's `ForEach` is now keyed by `projectPath` rather than indices; the explicit `.id` stays as a belt-and-braces identity.
- [high] `store.selectedProjectPath` stays. `BrowserWindow.selectDrillDownProjectIfLive` (from #094) still reads it to select the project in the sidebar. Only the grid's scroll consumer was removed, along with its `ScrollViewReader`, since nothing else used the proxy.
- ~~[low] Focus and fit heights now subtract the probe's `safeAreaInsets.top`/`.bottom` through a pure `BrowserWindow.availableViewportHeight(measured:topInset:bottomInset:)`. **Why:** on macOS 15 a ScrollView in a split-view column extends under the toolbar, so the frame height overshoots by the toolbar height. If the frame turns out to sit inside the safe area, the insets are 0 and nothing changes. Step 7 should confirm that the focused card's bottom edge sits at the window's bottom padding.~~ **Superseded (see below):** this was not safe — it caused a layout feedback loop.
- ~~[high] Reverted the inset subtraction: `GridHeightKey` reports the raw `geo.size.height` again, and `BrowserWindow.availableViewportHeight` and its three tests were removed. **Why:** the probe's safe-area insets depend on the layout that the height feeds (fit row heights, focus card height), so the value never converged. The release build hung at 100% main-thread CPU re-running AttributeGraph/NavigationStackLayout/ScrollViewLayoutComputer layout with `cardLayoutMode = fit`, `browserSelection = all`. With the raw height the app sits near 0% CPU. No fixed-constant toolbar padding was added either. If the focused card turns out to overshoot under the toolbar, any fix must use a constant, never a measured inset.~~ **Superseded (Step 6a):** the height/width probes, `GridHeightKey` and `GridWidthKey` are gone entirely; nothing in the card stack measures its own size.
- ~~[low] The content column's MINIMUM width stays at 420. Its IDEAL becomes `contentWidth(forColumns: 2) + gridSpacing` (880), and `defaultSize` grows from 1300 to 1620 (all three ideals plus 10 for dividers). **Why:** a two-column minimum would raise the window minimum to about 1460, which doesn't fit a 1440pt screen. AppKit clamps the default frame to the screen, so on small displays the grid opens with one column, as before. The column, window and default-size numbers are now static constants on `BrowserWindow` with tests. This touches `PlansApp.swift`, which is outside the listed impact scope.~~ **Superseded (Step 6a):** the content column is back to min 420 / ideal 560 (as on `main`), `contentWidth(forColumns:)` is gone, and the default window is 1300x800 again (230 + 560 + 500 + 10).
- ~~[high] "Show All Projects" survives a relaunch. **Why:** it is gated on `effectiveFocusPath`, derived from `store.focusedProjectPath` (loaded from UserDefaults in `PlansStore.init`) and the observable `store.projects`. No interaction-only state is involved.~~ **Superseded (Step 6a):** focus mode and "Show All Projects" were removed.
- [high] Switching the sidebar away while a card's action sheet is open is safe. **Why:** all five row-action sheets are `.sheet(item:)` on `PlanRowActions`'s own `@State`. When the card leaves the hierarchy they are torn down with it, and nothing force-unwraps the request.
- [high] Renamed `CardGridView` to `ProjectStackView` (new file `Sources/Plans/ProjectStackView.swift`; `CardGridView.swift` deleted) and `BrowserViewModel.displayedRows`'s `gridProjects:` parameter to `stackProjects:`. **Why:** with no grid left, "grid" names would mislead. Both were introduced by this task and are uncommitted, so nothing outside it depends on the old names.
- [high] The stack's toolbar sits on the outer `ProjectStackView`, whose body reads only `store.projectViewMode` / `store.manualOrderActive`. A private inner `ProjectStackContent` owns `dropTargetPath` and the `ScrollView`. **Why:** a drag-hover change then invalidates only the inner view and never rebuilds the toolbar content, which was a suspected contributor to the second layout loop.
- [low] The drop indicator moved from a vertical bar on the card's LEADING edge to a horizontal bar on its TOP edge, offset into the gap above the card. **Why:** in a single vertical stack "insert before" means "above". It is an overlay with an `.offset`, so it adds no layout. Step 7 should confirm it looks right.
- [high] Removed `ProjectCard.constrainedHeight`, `shouldScrollContent`, the card's inner fit-mode `ScrollView` and its slack-absorbing `Spacer`, along with the three `shouldScrollContent` tests in `ProjectCardTests`. **Why:** all of it existed only for fit/focus rows that imposed a fixed height. No caller passed `constrainedHeight` other than the deleted grid, so `ProjectCard(project:selectedRowID:onNewPlan:onOpenDetail:)` still works for every caller. The card's `.clipShape` stays (it keeps the edge-to-edge row bands inside the rounded corners).
- [high] Removed the card footer's focus (`viewfinder`) toggle and `FocusToggleGlyph`, plus `PlansStore.focusedProjectPath`/`toggleFocus`/`clearFocus`, `cardLayoutMode`, `CardLayout.swift`, and `BrowserViewModel.visibleUnderFocus`. **Why:** focus mode and the layout toggle were dropped in Step 6a.
- [high] `PlansStore.init` removes the stale `cardLayoutMode` and `focusedProject` UserDefaults keys on load. Covered by `testStoreLoadsNormallyWithStaleLayoutAndFocusKeys` and `testStoreRemovesStaleLayoutAndFocusKeysOnLoad`. **Why:** nothing reads them any more, and removing them stops dead preferences lingering. It is a removal only, so it can't affect any live setting.
- [high] Deleted `Tests/PlansTests/BrowserGridIndexBoundsTests.swift`. **Why:** it only covered `rowIndices` and `columnAssignments`, both removed.
- [low] Kept a trailing `scrollerClearance` (15pt) inset on the stack, now a constant on `ProjectStackView`. **Why:** the overlay scroller still floats over the trailing edge of the full-width cards and their per-row action buttons. It is a constant, never measured, so it can't feed back into layout.
- [low] Kept `.scrollBounceBehavior(.basedOnSize)` on the stack's ScrollView. **Why:** it only changes bounce behaviour, it doesn't feed any measured value back into layout, and it was on `main` before the grid work.
- [high] The sidebar's Projects section reorders with `.onMove` on its `ForEach`, mapped through a new pure `BrowserViewModel.moveOrder(_:fromOffsets:toOffset:)` over the displayed `sidebarProjects` paths and persisted with `store.setManualOrder` (the call card drops use). **Why:** `sidebarProjects` is the recency order when manual order is off, so the first sidebar move seeds manual order from what is displayed, exactly like a first card drag. Out-of-range offsets are a no-op, not a trap. Covered by four `testMoveOrder*` tests.
- [low] `.onMove` on a macOS `List(selection:)` keeps click selection working and allows drag-reorder without edit mode. **Why:** I confirmed this by reading, not by test. `.onMove` only adds a row drag handler, and the `.tag`/selection binding is untouched. It needs the Step 7 manual check. If it fails, the fallback is `.draggable`/`.dropDestination` on the rows. Favourites rows have no `.onMove`, so they don't reorder.
- [high] A card drop now reorders over the FULL ordered project list (`stackProjects(..., viewMode: .all)`, which is the same list the sidebar shows) instead of only the visible cards. **Why:** under the Active filter, the old code wrote an order without the hidden projects. `applyManualOrder` then treated those as new and floated them to the top of the sidebar, which broke the shared order. Inserting "before the target card" is the same in both lists because the target is always visible.
- [high] Edge auto-scroll works without any geometry. The stack's ScrollView uses `.scrollTargetLayout()` + `.scrollPosition(id: $scrolledPath, anchor: .top)`, so the scroll view itself reports the top-visible card. Two invisible 28pt drop strips are overlays pinned to the top and bottom of the visible area. While one is targeted, a MainActor task steps `scrolledPath` one card every 350ms (animated), using a pure `ProjectStackView.autoScrollTarget(in:current:direction:)`. **Why:** the overlays sit outside the scroll content and add no layout, and nothing measured feeds back into layout. All of this state lives on the inner `ProjectStackContent`, never on the toolbar-owning outer view. Covered by five `testAutoScrollTarget*` tests.
- [low] Auto-scroll steps one card at a time, not pixel by pixel. **Why:** pixel stepping needs the current content offset, which means measuring scroll geometry, and that is the pattern we are avoiding. With very tall cards each step is a big jump. Drops target whole cards, so reordering still works.
- [high] The edge strips only exist while a drag is in progress (`dragInProgress`). **Why:** if they were always present they would block clicks on the top and bottom 28pt of the visible area, such as the first card's header. `.draggable` has no drag-ended callback, so `dragInProgress` turns on whenever a card or strip is targeted. It turns off on any drop, on disappear, or after a 1.5s grace period with nothing targeted (gaps between cards briefly target nothing). If the strips have just hidden, they come back as soon as a card is hovered.
- [low] Dropping on the top strip moves the card to the very start of the order. Dropping on the bottom strip moves it to the end. **Why:** the strips cover the first or last card's top or bottom edge, so a drop there must still do something sensible. Once auto-scroll reaches either end, "start" or "end" is what the user is aiming for. Mid-stack, a drop on a strip also jumps to the start or end. That is a trade-off the user should check by hand.
- [high] The auto-scroll task always stops. **Why:** it is cancelled when its strip loses the target, on any drop (cards and strips both call `endDrag()`), on `.onDisappear`, and when the grace period ends. It also exits on its own when `autoScrollTarget` returns nil at the end of the stack, and it sleeps 350ms between steps, so it never busy-loops.

## Changes
### Segment 1 (steps 1–3)
- Dropped `ProjectViewMode.starred` (now `.all`/`.active`). A stale saved `"starred"` loads as `.all`, covered by `testStaleStarredProjectViewModeLoadsAsAll`. The starred view-mode tests were replaced, and `visibleUnderViewMode` lost its `starredProjectPaths:` parameter.
- New `Sources/Plans/CardGridView.swift`. The grid, cells, drop handling, sizing state and preference keys moved in. It takes `onNewPlan`/`onOpenDetail` closures. `CardGridView.gridProjects(...)` and `effectiveFocusPath(_:in:)` are shared with `BrowserWindow.displayedRows`. The static layout helpers stay on `BrowserWindow`.
- Toolbar split: the root has New Plan, Link Project and the backlog toggle. `CardGridView` has view mode, layout, Sort by Recency and Show All Projects.
- Files: BrowserWindow.swift, CardGridView.swift (new), ProjectViewMode.swift, PlansStore.swift, BrowserWindowTests.swift, PlansStoreTests.swift.

### Segment 2 (steps 4–6, plus the step 7 prerequisites)
- Removed the grid's `scrollToSelectedProject`, its `selectedProjectPath` onAppear/onChange and the `ScrollViewReader`. ⌘N `newPlanTrigger` stays on the root.
- Focus and fit height: this first subtracted safe-area insets via `BrowserWindow.availableViewportHeight`. That caused an endless SwiftUI layout loop (beachball at 100% CPU in fit mode), so it was reverted. `GridHeightKey` reports the raw `geo.size.height` again, and the helper and its tests are removed.
- Column sizing: added `BrowserWindow.contentWidth(forColumns:)` and named column/window constants. Content column min stays 420, ideal is now 880 (two cards). Default window is 1620 wide. `PlansApp.swift` uses `BrowserWindow.defaultWindowWidth/Height`.
- Confirmed by reading: Show All Projects survives relaunch (it depends on the saved focus and the live project list), and the row-action sheets are `.sheet(item:)` on view-local state, so nothing force-unwraps.
- Docs: updated CLAUDE.md (Surface B and the Layout entry for CardGridView), .plans/CONTEXT.md, and the header and stale comments in BrowserWindow/CardGridView/ProjectCard.
- Files: CardGridView.swift, BrowserWindow.swift, PlansApp.swift, ProjectCard.swift, BrowserWindowTests.swift, CLAUDE.md.

### Step 6a: grid replaced with a vertical stack (scope change)
- `CardGridView.swift` became `ProjectStackView.swift`. The outer view holds the toolbar (All/Active, Sort by Recency) and reads only store settings. The inner `ProjectStackContent` owns the ScrollView + `VStack` of natural-height cards, plus the drag/drop state.
- Removed:
  - fit and masonry layouts, the layout toggle, `CardLayout.swift`, `cardLayoutMode`;
  - focus mode, "Show All Projects" and the card focus button;
  - every grid sizing helper and GeometryReader probe.
- `gridProjects` became `stackProjects`. The content column is back to 420/560 and the default window to 1300×800. `ProjectCard` is natural-height only.
- Stale `cardLayoutMode` and `focusedProject` defaults are removed on load (tested).
- The drop indicator is now a horizontal bar above the target card.
- Deleted `BrowserGridIndexBoundsTests.swift` and the tests of removed helpers. Added stack, column and stale-key tests.
- Docs updated: CLAUDE.md, CONTEXT.md, doc comments.

### Sidebar reorder and drag auto-scroll (fixes from testing)
- The sidebar's Projects section gets `.onMove`. The pure `BrowserViewModel.moveOrder(_:fromOffsets:toOffset:)` computes the new order, and `store.setManualOrder` saves it, the same call a card drop uses. The first move turns manual order on, starting from the displayed order.
- Card drops now reorder the full list the sidebar shows, not just the visible (Active-filtered) cards. That stops hidden projects from jumping in the sidebar.
- Edge auto-scroll in `ProjectStackView`:
  - Uses `.scrollPosition(id:anchor: .top)` with no geometry.
  - Adds two 28pt drop strips as overlays during a drag. They step one card every 350ms using the pure `autoScrollTarget(in:current:direction:)`.
  - Dropping on a strip moves the card to the start or end.
  - The timer stops when a strip loses the drag, on drop, on disappear, after a 1.5s idle grace period, or at the end of the stack.
- Tests: 4 `testMoveOrder*`, 5 `testAutoScrollTarget*`. Targeted run: 267 pass.

### Sidebar summary strip removed; "Smart Views" renamed "Status"
- Removed `summaryStrip`, `summaryPill`, `BrowserViewModel.summaryCounts`/`SummaryCounts` and `testSummaryCountsAgreeWithStoreSemantics`. The pills only duplicated the smart-view rows.
- The visible section header is now "Status". The internal `SmartView` type is unchanged. CLAUDE.md is updated. Targeted run: 266 pass.

### Issues
- [x] App hung with a beachball in fit mode under All projects, caused by the inset-subtracting height probe. Reverted to the raw height. The release build now idles at about 0% CPU with the window open.
- [x] App hung again while drag-reordering in the masonry column. Resolved by Step 6a (the grid was removed).
- [x] The sidebar's Projects list should be drag-reorderable, using the same shared manual order as the All projects stack.
- [x] Dragging a card toward the top or bottom edge of the All projects stack doesn't auto-scroll the view.
- [x] The sidebar's summary pills (In progress/Review/Failed counts above the smart views) duplicate the smart-view rows; remove them. Rename the "Smart Views" section header to "Status".

## Notes
Depends on #094 and #095. Last of three tasks.

Decisions:
- Starred is dropped from the view-mode menu and All/Active stay.
- The drill-down goes to the project's list (done in #094), so the grid's scroll-to-card path goes.
- Focus mode stays grid-only and doesn't navigate the sidebar.
- The backlog toggle stays global.
