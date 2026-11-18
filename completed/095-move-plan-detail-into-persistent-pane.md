# Move Plan Detail Into Persistent Split-View Pane

**ID:** 095
**Created:** 2026-11-07T11:48
**Type:** refactor
**Status:** completed
**Completed:** 2026-11-07T13:55
**Branch:** refactor/095-move-plan-detail-into-persistent-pane

## What
Layout redesign step 2 (see `layout-redesign.md`): replace the modal `detailOverlay` (scrim, Esc to dismiss, 900×600 size clamp) with the `NavigationSplitView` detail column. The column is driven by the task list's selection, which takes over from `detailRowID`.

- `PlanDetailView` stays unchanged; only the view that hosts it changes.
- With no selection, the column shows an empty placeholder.
- Also update the outdated "Value-based detail windows" convention in `CLAUDE.md`, which still describes `WindowGroup(for: TaskRow.ID.self)`.

## Why
The modal overlay covers the list you're browsing, so you can't look at one plan and then the next. A permanent detail column gives the Mail/Linear pattern: pick a row, read it, pick the next one.

## How Summary
Rename `detailRowID` to `selectedRowID` (not saved across launches). Bind it to the task list's selection and to the card grid's `onOpenDetail`. The window becomes a three-column `NavigationSplitView` whose detail column shows `PlanDetailView(rowID:)`, keyed with `.id(selection)`, or a placeholder when nothing is selected.

The overlay, scrim, Esc handler and size limits are removed. A pure helper clears the selection when its row no longer exists. The outdated "detail window" documentation is updated.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — `detailRowID`/`detailOverlay` (L78, L319–326, L437–484), `cardCell` `onOpenDetail` (L865–880), and a new `validSelection` helper.
- `Sources/Plans/PlanDetailView.swift` — unchanged except doc comments. It's keyed by `.id` so its sheet state and progress auto-open reset for each plan.
- `Sources/Plans/ProjectCard.swift` — a highlight for the selected row, plus doc comments.
- `Sources/Plans/PlansApp.swift` — window `defaultSize`; stale comment at L146–149.
- `CLAUDE.md`, `.plans/CONTEXT.md` — outdated "Value-based detail windows" and "standalone detail window" text.

## How
- [x] Step 1: Test-first: add `BrowserViewModel.validSelection(_:in:)`. It returns the id when `resolveRow` finds it, and nil when the plan has completed, been deleted, or its project is gone. Cover backlog rows as well.
- [x] Step 2: Turn the split view into three columns (sidebar / content / detail).
  - Rename `detailRowID` to `selectedRowID`. Keep it `@State` and unsaved.
  - Bind `TaskListView` via `List(selection:)`, or an equivalent tap, plus the card grid's `onOpenDetail`, to that one selection.
  - Add an `isSelected` highlight to card rows and list rows.
- [x] Step 3: The detail column shows `PlanDetailView(rowID: selectedRowID).id(selectedRowID)`. Keying it with `.id` stops sheet flags carrying over between plans and lets `shouldAutoOpenProgress` fire for each plan.
  - When nothing is selected, show `ContentUnavailableView("No Plan Selected", systemImage: "doc.text")`.
  - Set column widths with `.navigationSplitViewColumnWidth`, and a window `defaultSize` of about 1300×800.
- [x] Step 4: Remove `detailOverlay`, the `.overlay`, `.animation(value: detailRowID)` and `.onExitCommand`. Esc no longer clears the selection, which is standard split-view behaviour.
  - Add `.onChange(of: store.projects)` that clears `selectedRowID` through `validSelection`.
  - Keep the NewPlan sheet, the ⌘N handler and the main toolbar on the root view.
- [x] Step 5: Update the docs.
  - `CLAUDE.md`: L16–17 (Surface B) and L60–61, replacing "Value-based detail windows" with the detail-column convention.
  - `.plans/CONTEXT.md`: L14–15, L38, L65–66.
  - Overlay-era doc comments in `BrowserWindow.swift`, `ProjectCard.swift`, `PlanDetailView.swift` and `PlansApp.swift`.
- [x] 👁 Step 6: Run `./build.sh` and check by hand:
  - Selecting a row in the list and in the grid fills the detail column.
  - Switching plans while a sheet is up doesn't carry it over.
  - A running task opens its progress automatically.
  - Deleting or completing the selected plan returns to the placeholder.
  - Backlog rows open.
  - All three columns are usable at the default window size.

## Issues
- [x] The selected plan should clear when the sidebar view changes and the content column no longer lists it, so the detail column never shows a plan the left column doesn't show as selected.
- [x] Clicking a plan row in the task list sometimes doesn't select it in the detail column. Cause unknown (possibly hit area).
- [x] Task-list row bands (hover/selection highlight) leave a small gap on the left, next to the sidebar divider. The band should run flush to the column's left edge.

## Verification
- `swift test` passes, including new `validSelection` tests and the existing `resolveRow` tests (including #073's `testResolveRowReturnsNilWhenEveryProjectDisappears`).
- No `detailOverlay`, `.onExitCommand` or `WindowGroup(for: TaskRow.ID.self)` references remain in `Sources/`, `CLAUDE.md` or `.plans/CONTEXT.md` (check with grep).
- The manual check in Step 6 passes.

## Impact Scope
### Files to Modify
- [x] `Sources/Plans/BrowserWindow.swift` — three columns, selection, overlay removed, `validSelection`.
- [x] `Sources/Plans/ProjectCard.swift` — selected-row highlight, doc comments.
- [x] `Sources/Plans/PlanDetailView.swift` — doc comments only.
- [x] `Sources/Plans/PlansApp.swift` — `defaultSize`, stale comment.
- [x] `CLAUDE.md`, `.plans/CONTEXT.md` — conventions.
- [x] `Tests/PlansTests/BrowserWindowTests.swift` — `validSelection` tests.

### Related Files (may need updates)
- The task-list view from #094 — its selection binding.

### Endpoints/UI Affected
- Plan detail moves from a modal overlay to a permanent third column.

## Assumptions

### Initial (from elaboration)
_To be filled during elaboration_

### Discovered during execution
- [high] `validSelection(_:in:)` takes an optional `TaskRow.ID?` and returns `nil` for `nil`, delegating existence to `resolveRow` (active first, then backlog). **Why:** matches the optional `selectedRowID` state directly so the Step 4 `.onChange` can assign the result without unwrapping.
- [low] Bound `TaskListView` selection with the existing tap seam (`onOpenDetail` + a new `selectedRowID` param) rather than `List(selection:)`. **Why:** `TaskListView` is a `ScrollView` + `LazyVStack` with custom zebra rows and per-cell `OpenDetailOnTap`; converting it to `List` would restyle the rows and fight the trailing `PlanRowActions` hit target. The task explicitly allows "an equivalent tap". Trade-off: no arrow-key navigation through the list.
- [low] Selected-row highlight is `Color.accentColor.opacity(0.18)`, which overrides the zebra/hover tint, via a new `ProjectCard.RowStyling.background(isEven:isHovered:isSelected:)` shared by card and list rows. **Why:** keeps one styling source of truth (as #068 does); the exact alpha is a UX guess to confirm in the Step 6 check.
- [low] Column widths are sidebar 200/230/320, content min 420 / ideal 560, detail min 380 / ideal 500. The split-view `minWidth` went from 820 to 1000, and `defaultSize` went from 1100×720 to 1300×800. **Why:** the task only said "about 1300×800"; these ideals add up to about 1290 so all three columns fit at the default size. Check this in Step 6.
- [high] Removed the `.overlay { detailOverlay }`, the `.animation(value:)` and `detailOverlay` (including its `.onExitCommand`) in this segment instead of Step 4. **Why:** after the rename, both the overlay and the new detail column would have shown the same plan from the same `selectedRowID`. The `.onChange(of: store.projects)` clear is still left for Step 4.
- [high] ProjectCard and TaskListView take `selectedRowID` as a defaulted `var` (`nil`), so existing call sites such as the ProjectCard preview still compile. **Why:** this follows the existing `constrainedHeight` defaulted-property pattern.
- [high] `.onChange(of: store.projects)` works directly because `ProjectTasks` is already `Equatable` (`TaskParser.swift`), so no substitute key was needed. It uses the new value from the closure and assigns only when `validSelection` differs, so polls that leave the selection valid don't invalidate the view. **Why:** the task asked for the assignment to happen only on change; the closure's new value avoids reading stale state.
- [low] Historical mentions (for example "replaces the #073 modal overlay pane", "former standalone detail window") stay in the rewritten doc comments as provenance. Only wording that described the current behaviour was updated. **Why:** the Verification grep looks only at `detailOverlay` / `.onExitCommand` / `WindowGroup(for: TaskRow.ID.self)`, and keeping the history matches how the codebase records superseded designs.
- [low] Doc comments in `TaskListView.swift` (two `onOpenDetail` comments) still said "overlay pane" and were updated too. **Why:** it is listed under related files; this was only a comment change.
- [high] Testing fix: the detail column now unloads a plan the content column no longer lists. A new pure `BrowserViewModel.displayedRows(for:in:gridProjects:showBacklog:)` is the single source of truth for the content column's rows (the smart/project task lists now render from it), and `validSelection(_:visibleIn:)` keeps the selection only while those rows contain it. **Why:** the user wants the invariant "detail shows only a plan the left list highlights"; deriving both rendering and the check from one function keeps them from drifting.
- [high] The single `.onChange(of: store.projects)` was replaced by `.onChange(of: displayedRows.map(\.id))`, rather than adding a separate onChange on `store.browserSelection`. **Why:** the displayed-ID list changes on a sidebar switch, on a poll (completed, deleted, moved out of the smart view, project unlinked), AND on backlog / view-mode / star / focus toggles, so one observer covers every trigger. It still assigns only when the result differs.
- [low] For `.allProjects`, the displayed rows are every `sortedProjects` card's active rows (+ backlog when `showBacklog`). The per-card type filter (#076, `ProjectCard`'s local `@State typeFilter`) is NOT taken into account, so a plan hidden only by a card's type filter stays loaded. **Why:** that filter is card-local view state the browser can't see; lifting it into the store would be a structural change outside this fix.
- [low] `validSelection(_:in:)` is kept (and its tests kept) even though the app no longer calls it; `validSelection(_:visibleIn:)` subsumes it. **Why:** keeps the existing tested helper stable; it can be removed in a cleanup if wanted.
- [high] Testing fix ("clicking a plan sometimes doesn't select it"): the cause was hit-testing, not selection state. Only each cell's own frame (`OpenDetailOnTap`) was tappable, while the row's 5pt vertical padding, 8pt column gaps, 8pt horizontal inset and the blank space above/below shorter cells were dead, even though they are painted as part of the hovered row. The row's background band now also carries `OpenDetailOnTap`, in both `ProjectCard.planRow` and `TaskListRow`. **Why:** the band sits behind the row content, so it only gets clicks that hit nothing in front of it. It can't take a click from `PlanRowActions`, and the per-cell gestures stay as they are.
- [low] The selection logic was checked and ruled out as a cause. `TaskRow.id` is `projectPath + "/" + task.id`, which doesn't include status, so it stays the same across polls. Both lists build their rows from the same `displayedRows`, and a tap only ever assigns `selectedRowID` (it never toggles it). There's no `onTapGesture(count: 2)` anywhere in the rows. **Why:** these were the other likely causes, and checking them showed no ID mismatch or reset race, so no logic test was added.
- [low] Two small spots still don't select: the 2pt `VStack(spacing: 2)` strip between rows, and the card grid's `.draggable` card, where a click that moves a few points can start a card drag instead of a tap. **Why:** closing the strip would change the zebra layout, and the drag is the #017 reorder feature. Both are small next to the padding and gap areas that are now fixed.
- [low] Testing fix (gap between the sidebar divider and the list row band): the only inset was `TaskListRow`'s outer `.padding(.leading, rowBandLeadingMargin)` (6pt), copied from the card row, where it keeps the band off the card's rounded left border. In the list, the band now runs flush to the content column's left edge, and the whole 14pt gutter (`cardHorizontalPadding`) sits inside the band as leading padding, so the row text still lines up with the "IN PROGRESS" header and the control bar. **Why:** the user wants the band to run edge to edge. Only the list row changed; `ProjectCard.planRow` and the shared `RowColumns` metrics are untouched, so card rows keep their 6pt margin.
- [low] The right edge was already flush. The list's `ScrollView`/`LazyVStack` has no horizontal padding, and the flexible title column stretches the band to the column's trailing edge, so nothing changed there and the internal trailing inset stays `rowHorizontalPadding` (8pt). **Why:** macOS overlay scrollbars draw over the content without taking layout space, so a flush band doesn't collide with them. While scrolling, the scroller may briefly cover part of the trailing `PlanRowActions` glyph, but that was already the case before this fix.

## Changes
### Segment 1 (steps 1-3)
- Added `BrowserViewModel.validSelection(_:in:)` plus 7 tests in `BrowserWindowTests.swift` (active, backlog, completed, deleted, deleted backlog, project gone / no projects, nil).
- Turned `BrowserWindow.swift` into a three-column `NavigationSplitView`. `detailRowID` became `selectedRowID`, and the task lists (in `TaskListView.swift`) and card grid's `onOpenDetail` share that one selection. The detail column shows `PlanDetailView(rowID:).id(selectedRowID)`, or a "No Plan Selected" placeholder. Column widths are set and the split-view minimum width is now 1000.
- Added `ProjectCard.RowStyling.background(isEven:isHovered:isSelected:)`, which highlights the selected row in both card rows and list rows.
- Set the `PlansApp.swift` window `defaultSize` to 1300×800.
- Removed the overlay (`detailOverlay`, `.overlay`, `.animation`, `.onExitCommand`) early, in this segment instead of Step 4, so it wouldn't open the same plan as the new detail column.

### Segment 2 (steps 4-5)
- Added `.onChange(of: store.projects)` to the root split view in `BrowserWindow.swift`. It clears `selectedRowID` through `validSelection`, and only reassigns the value when it actually changes.
- Updated the docs:
  - `CLAUDE.md` and `.plans/CONTEXT.md`: "Value-based detail windows" is now "Selection-driven detail column", and the Surface B text was updated.
  - Doc comments in `BrowserWindow.swift`, `PlansApp.swift`, `ProjectCard.swift`, `PlanDetailView.swift` and `TaskListView.swift`.
- Grep check: no `detailOverlay`, `onExitCommand` or `WindowGroup(for: TaskRow.ID.self)` references remain.
### Issue fix: selection clears when the content column stops showing the plan
- Added `BrowserViewModel.displayedRows(for:in:gridProjects:showBacklog:)`, the one function that decides which rows the content column shows. The task lists now render from it.
- Added `validSelection(_:visibleIn:)`. A single `.onChange(of: displayedRows.map(\.id))` replaces the `store.projects` observer, so a sidebar switch, a poll that moves a plan between views, or a backlog/filter toggle all clear a plan that's no longer shown.
- 8 new tests in `BrowserWindowTests.swift` (149 tests, 0 failures).
- Known gap: in All Projects, a plan hidden only by a card's own type filter stays loaded, because that filter state belongs to the card.
### Issue fix: unreliable row clicks
- Cause: only the individual cells responded to clicks (`OpenDetailOnTap`). The row's vertical padding, the gaps between columns and the edge insets did nothing, even though the hover band covers all of them.
- Fix: the row's band now carries `OpenDetailOnTap` too, in both `TaskListView.swift` and `ProjectCard.swift`. It sits behind the content, so the action buttons and per-cell taps still win.
- Remaining small gaps: the 2pt spacing between rows, and the drag-to-reorder cards in All Projects, where a click that moves a few points can start a drag.
### Issue fix: left gap on task-list rows
- `TaskListRow` in `TaskListView.swift` had a 6pt outer leading margin (`rowBandLeadingMargin`, copied from the card rows). I removed it, so the row band now runs flush to the content column's left edge.
- The inset moved inside the band: the leading padding is now `cardHorizontalPadding` (14pt), so the text still lines up with the section header. The right edge was already flush, and the card-grid rows are unchanged.

## Notes
Depends on #094 (the list and the split view). Second of three tasks.

Decisions:
- The selected task isn't saved across launches. Only the sidebar selection is, in #094.
- The selection clears itself when its row disappears.
- Esc does not clear the selection.
- One selection is shared by list and card rows.
