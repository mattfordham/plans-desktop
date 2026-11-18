# Open Plan Detail In New Window

**ID:** 011
**Created:** 2026-06-05T11:00
**Type:** feature
**Status:** completed
**Branch:** feature/011-open-plan-detail-in-new-window
**Completed:** 2026-06-05T11:30

## What
Instead of drawer, let's open the plan detail in another/new window.

Currently the Surface B browser window (`BrowserWindow`) shows the project-card
dashboard and, when a plan row is tapped, inserts a collapsible detail panel (the
"drawer") beside the grid via an `HSplitView`. Replace that drawer with a separate
window: tapping a plan row opens its detail in a new top-level window, leaving the
browser as a pure full-width card grid.

## Why
Adds value by letting the plan detail live in its own independently sized and
positioned window — users can keep the dashboard full-width and view (or compare)
plan details side-by-side or on another screen, instead of squeezing both into one
window's split. It also decouples the detail rendering from the browser layout.

## How
- [x] Step 1: Promote the cross-project row resolution into a reusable helper. Add `static func resolveRow(in projects: [ProjectTasks], id: TaskRow.ID) -> TaskRow?` to `BrowserViewModel` in `Sources/Plans/BrowserWindow.swift` (flatMap `activeRows` over all projects, first matching `id`). `BrowserWindow.selectedRow` and the `BrowserWindowTests` local `resolveSelectedRow` both delegate to it.
- [x] Step 2: Add a `resolveRow` unit test to `Tests/PlansTests/BrowserWindowTests.swift` (TDD — mirror the existing `resolveSelectedRow*` cases against `BrowserViewModel.resolveRow`), and repoint the existing `resolveSelectedRow` helper to call it so the cross-project / absent-id / completed-id behavior is covered for the shared helper.
- [x] Step 3: Create `Sources/Plans/PlanDetailView.swift` — a standalone `View` that takes the window value `rowID: TaskRow.ID?`, reads `PlansStore` from the environment, resolves its `TaskRow` via `BrowserViewModel.resolveRow`, and renders the detail body (header + `## ` sections + read-only `How` checklist). Move `detailHeader`, `sectionView`, `markdownBody`, `markdownParagraph`, and `howChecklist` out of `BrowserWindow` into this view. Show a muted "Plan not found" placeholder when the id resolves to nil. NO Close button (the window's own close control replaces it).
- [x] Step 4: Declare the detail window scene in `Sources/Plans/PlansApp.swift`: `WindowGroup("Plan", id: "plan-detail", for: TaskRow.ID.self) { $rowID in PlanDetailView(rowID: rowID).environment(store) }`. Value-based `WindowGroup` (macOS 15) gives each plan its own window keyed by `TaskRow.ID`.
- [x] Step 5: Change `Sources/Plans/ProjectCard.swift` to open the window instead of selecting: drop the `@Binding var selectedRowID`, add `@Environment(\.openWindow) private var openWindow`, remove the `isSelected` highlight, and change `planRow`'s tap to `openWindow(id: "plan-detail", value: row.id)`.
- [x] Step 6: Strip the drawer from `Sources/Plans/BrowserWindow.swift`: remove the `HSplitView` conditional composition so `body` renders `cardGrid` only (full-width), delete `selectedRowID` state, the `selectedRow` computed property, the `detail` view and the moved detail helpers, and update the `ProjectCard(project:)` call site to drop the `selectedRowID:` binding. Update the file's doc comment to describe the new window-based detail.
- [x] 👁 Step 7: Build and run the app (`./build.sh` then launch `Plans.app`); from the browser window click a plan row and confirm a new "Plan" window opens showing that plan's detail, the browser stays a full-width card grid (no drawer), and clicking another row opens/updates a detail window.

## Verification
- Build succeeds (`./build.sh`) with no warnings about the removed drawer code.
- Targeted tests pass: `swift test --filter BrowserWindowTests`.
- Clicking a plan row in the browser opens the plan detail in a separate window (not an inline drawer).
- The browser window shows only the card grid at full width — no split/detail column.
- The detail window renders the same content the drawer did (title, project/status header, markdown sections, read-only How checklist).

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/BrowserWindow.swift` — remove drawer (`HSplitView`, `selectedRowID`, `selectedRow`, `detail` + helpers); add `BrowserViewModel.resolveRow`; keep `cardGrid` as sole view.
- [ ] `Sources/Plans/PlanDetailView.swift` — NEW standalone detail view bound to the window value, with the moved rendering helpers.
- [ ] `Sources/Plans/PlansApp.swift` — add the `WindowGroup(id: "plan-detail", for: TaskRow.ID.self)` scene.
- [ ] `Sources/Plans/ProjectCard.swift` — replace `selectedRowID` binding with `openWindow(id:value:)` on tap; drop selection highlight.
- [ ] `Tests/PlansTests/BrowserWindowTests.swift` — add `BrowserViewModel.resolveRow` coverage; repoint local helper.

### Endpoints/UI Affected
- Surface B browser window — loses the inline detail drawer; becomes pure card grid.
- New "Plan" detail window — shows a single plan's rendered body.

## Assumptions

### Initial (from elaboration)
- [low] Use a value-based `WindowGroup(id:for: TaskRow.ID.self)` + `openWindow(id:value:)` rather than a shared `@Observable` selection state. **Why:** macOS 15 target supports it; it lets SwiftUI own each detail window's lifecycle and lets each plan open in its own window, which is simpler than syncing a single shared selection across windows. Alternative (single shared-state window that follows selection) was the research agent's lean; chose per-plan windows for less cross-window state coupling.
- [low] Allow multiple detail windows (one per plan) rather than a single reused window. **Why:** Falls out naturally from value-based `WindowGroup`; matches the "view details side-by-side" motivation in Why. The source description ("another/new window") doesn't specify single vs. multiple.
- [low] Drop the plan-row selection highlight from `ProjectCard`. **Why:** With no inline drawer there is no persistent "selected" row to mirror; the tap now just opens a window. A pressed/hover affordance could be added later but wasn't requested.
- [high] Resolve the detail window's row from the live `PlansStore` by id (via the promoted `BrowserViewModel.resolveRow`) rather than passing the whole `TaskRow`. **Why:** `TaskRow.ID` is a `String` (codable, valid `WindowGroup` value); `Task`/`TaskRow` are not set up as window values, and resolving by id keeps the detail live as polling refreshes the store — mirrors the existing `selectedRow` resolution pattern (3 existing tests already cover this scan).
- [high] Keep the detail strictly read-only (no How toggling), matching the current drawer and spec §2. **Why:** The existing `howChecklist` is read-only by design and the task only changes *where* detail is shown, not its interactivity.

### Discovered during execution
- [high] Kept `selectedRowID`, `selectedRow`, the `detail` property, and the `HSplitView` body in `BrowserWindow` for this segment; made `BrowserWindow.detail` delegate its resolved-row content to `PlanDetailView(rowID: selectedRowID)` (wrapped by the existing inline Close-button HStack). **Why:** Segment scope says a later segment strips the drawer; delegating keeps the moved helpers unreferenced by `BrowserWindow` so the build stays green between segments, as instructed.
- [low] `PlanDetailView.body` returns the bare `ScrollView` (no outer `VStack`) for the resolved-row case, since it has no Close control to stack above it. **Why:** The Close button stays in `BrowserWindow.detail`'s wrapper; the standalone view only needs the scrollable body, so an extra container would be redundant.
- [high] Passed `PlanDetailView(rowID: rowID)` (the binding's unwrapped value) inside the value-based `WindowGroup` closure rather than the `$rowID` binding. **Why:** `PlanDetailView` takes a plain `TaskRow.ID?`; the closure param `$rowID` is `Binding<TaskRow.ID?>` whose `.wrappedValue` is read as `rowID`. Compiled clean.
- [low] Removed the `.background(RoundedRectangle...)` selection-highlight from `ProjectCard.planRow` entirely (rather than keeping a `.clear` fill). **Why:** With no selection state there is nothing to highlight; `.contentShape(Rectangle())` alone keeps the full-row tap target, so the empty background modifier was dead weight.

## Changes
- Added `BrowserViewModel.resolveRow(in:id:)` (shared cross-project row lookup); `BrowserWindow.selectedRow` now delegates to it. (`Sources/Plans/BrowserWindow.swift`)
- Repointed the `resolveSelectedRow` test helper to the shared helper and added `testResolveRowFindsRowInSecondProject` + `testResolveRowReturnsNilForAbsentId`. (`Tests/PlansTests/BrowserWindowTests.swift`)
- New `Sources/Plans/PlanDetailView.swift`: standalone detail view bound to a `TaskRow.ID?` window value, resolving its row from the store and rendering header + sections + read-only How checklist (no Close button). Detail render helpers moved here from `BrowserWindow`.
- Added a value-based detail window scene `WindowGroup("Plan", id: "plan-detail", for: TaskRow.ID.self)` rendering `PlanDetailView`. (`Sources/Plans/PlansApp.swift`)
- `ProjectCard` now opens the detail window on row tap (`openWindow(id: "plan-detail", value: row.id)`) instead of mutating a selection binding; dropped the `selectedRowID` binding and the selection-highlight background. (`Sources/Plans/ProjectCard.swift`)
- Stripped the inline drawer from `BrowserWindow`: `body` renders only the full-width `cardGrid`; removed `selectedRowID` state, `selectedRow`, the `detail` view + its `HSplitView`, and updated the doc comments to describe separate-window detail. (`Sources/Plans/BrowserWindow.swift`)

## Notes
_Additional context_
