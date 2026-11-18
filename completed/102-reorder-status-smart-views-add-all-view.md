# Reorder Status Smart Views And Add An All Plans View

**ID:** 102
**Created:** 2026-11-07T17:01
**Type:** feature
**Status:** completed
**Completed:** 2026-11-07T19:05
**Branch:** feature/102-reorder-status-smart-views-add-all-view

## What
At the top for status...

- move review to the top
- pending
- add and "all" view, to see all plans across all projects.

## Why
Adds value by making the browser sidebar's cross-project "Status" smart views match how work is actually triaged: review items — the plans waiting on a human — surface first, then pending (unstarted) work, and a single "All Plans" lens lets you see every active plan across all projects in one flat list instead of jumping between status filters.

## How Summary
The sidebar's "Status" section renders `SmartView.allCases` in declaration order, so the reorder is purely moving the `case` lines in the `SmartView` enum. A new `pending` case and a new `all` case are added, each handled in the four exhaustive switches (`label`, `symbolName`, `color`, `rows(in:matching:)`) — reusing the existing shared status vocabulary for `pending` and adding static "All Plans" vocabulary (label/symbol/neutral color) in the glyph files, mirroring how `backlog` is handled. The `all` view returns every active row across projects.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — defines `SmartView` (cases = sidebar order), its `label`/`symbolName`/`color` switches, and the `rows(in:matching:)` cross-project filter.
- `Sources/Plans/TaskType+Glyph.swift` — status `filterLabel` + static `backlog*` vocabulary; new static `allPlansFilterLabel`/`allPlansSymbolName` go here.
- `Sources/Plans/TaskStatus+Glance.swift` — status glance palette; `TaskStatusIndicator.neutralColor` reused for the "All Plans" tint.
- `Tests/PlansTests/BrowserWindowTests.swift` — smart-view row/vocabulary tests to extend for the new ordering, `pending`, and `all` cases.

## How
- [x] Step 1: Write failing XCTest cases in `Tests/PlansTests/BrowserWindowTests.swift`: (a) `SmartView.allCases` order is `[.review, .pending, .inProgress, .blocked, .failed, .backlog, .all]`; (b) `rows(in:matching: .pending)` returns only active rows whose status is `.pending` across projects; (c) `rows(in:matching: .all)` returns all active rows across projects (every non-completed status, in project+parser order); (d) vocabulary: `SmartView.pending.label == TaskStatus.pending.filterLabel` and `SmartView.all.label == "All Plans"`.
- [x] Step 2: Reorder and extend the `SmartView` enum in `Sources/Plans/BrowserWindow.swift` — put `case review` first, then `case pending`, then `inProgress`, `blocked`, `failed`, `backlog`, and add `case all` last. Update the doc comment to mention the pending and all lenses.
- [x] Step 3: Add static "All Plans" vocabulary: `allPlansFilterLabel` ("All Plans") and `allPlansSymbolName` (a neutral stack glyph, e.g. `"square.stack.3d.up.fill"`) in `Sources/Plans/TaskType+Glyph.swift` alongside the `backlog*` statics. Reuse `TaskStatusIndicator.neutralColor` for the tint (no new color needed).
- [x] Step 4: Handle the two new cases in the three presentation switches in `BrowserWindow.swift`: `label` (`.pending` → `TaskStatus.pending.filterLabel`, `.all` → `TaskStatus.allPlansFilterLabel`), `symbolName` (`.pending` → `TaskStatus.pending.symbolName`, `.all` → `TaskStatus.allPlansSymbolName`), and `color` (`.pending` → `TaskStatus.pending.glanceColor`, `.all` → `TaskStatusIndicator.neutralColor`). Keep the exhaustive switches with no `default:`.
- [x] Step 5: Handle the two new cases in `rows(in:matching:)`: `.pending` → `projects.flatMap { activeRows($0) }.filter { $0.task.status == .pending }`; `.all` → `projects.flatMap { activeRows($0) }` (every active row across all projects).
- [x] Step 6: Run the targeted test file (`swift test --filter BrowserWindowTests`) and confirm the new/updated tests pass and nothing in that file regressed.

## Verification
- `swift test --filter BrowserWindowTests` passes, including the new ordering, `pending`, and `all` assertions.
- Building and running the app shows the sidebar "Status" section ordered Review, Pending, In progress, Blocked, Failed, Backlog, All Plans.
- Selecting "Pending" shows only pending plans across projects; selecting "All Plans" shows every active plan across all projects in one flat list.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/BrowserWindow.swift` — reorder + add `pending`/`all` cases to `SmartView` and its four switches.
- [ ] `Sources/Plans/TaskType+Glyph.swift` — add static "All Plans" label/symbol vocabulary.
- [ ] `Tests/PlansTests/BrowserWindowTests.swift` — new/updated smart-view tests.

### Related Files (may need updates)
- `Sources/Plans/TaskStatus+Glance.swift` — only if a dedicated "All Plans" tint is preferred over reusing `TaskStatusIndicator.neutralColor` (default: reuse, no change).

### Endpoints/UI Affected
- Browser window sidebar "Status" section — reordered, two new rows (Pending, All Plans).

## Assumptions

### Initial (from elaboration)
- [low] "pending" means a NEW `pending` smart view (there is none today — current cases are inProgress/review/blocked/failed/backlog). **Why:** the description lists "review" then "pending" as the desired top of the Status list, and no pending lens currently exists, so it reads as an addition rather than a reference to the existing inProgress view.
- [low] Status order will be Review → Pending → In progress → Blocked → Failed → Backlog → All Plans. **Why:** the description explicitly asks to move review to the top and lists pending next; inProgress/blocked/failed/backlog keep their relative order, and the catch-all "All Plans" view is placed last by convention (matching how backlog sits at the end of the active lenses).
- [low] The "All Plans" view shows all ACTIVE plans across projects (the five non-completed statuses via `activeRows`), not completed or backlog tasks. **Why:** completed tasks are not surfaced by any existing smart view and live only in `project.tasks`; "all plans across all projects" in the active-work sidebar reads as the active set, consistent with the other status lenses. A separate decision could later widen it to include backlog/completed.
- [low] The new view is labelled "All Plans" (not "All"). **Why:** the sidebar already has an "All Projects" entry (the card stack); "All Plans" disambiguates a flat cross-project task list from that project-card stack.
- [high] New smart-view label/symbol/color live as shared static vocabulary (in `TaskType+Glyph.swift` / reusing `TaskStatusIndicator.neutralColor`), not inline in the view, and the exhaustive `switch`es keep no `default:`. **Why:** the `SmartView` doc comment and the existing `backlog*` statics establish this convention; the no-`default:` switches are an intentional compile-time guard.

### Discovered during execution
- none — no low-confidence decisions arose during execution. All vocabulary names were confirmed up front, the specified `square.stack.3d.up.fill` SF Symbol is valid on macOS 15+, and the switch-arm placement followed the existing enum declaration order.

## Changes

- `Tests/PlansTests/BrowserWindowTests.swift` — added 4 XCTest cases (`testSmartViewAllCasesOrder`, `testSmartViewPendingActiveRowsAcrossProjects`, `testSmartViewAllReturnsEveryActiveRowAcrossProjects`, `testSmartViewPendingAndAllLabels`) covering the new ordering, the `.pending` and `.all` cross-project row filters, and the `.pending`/`.all` labels.
- `Sources/Plans/BrowserWindow.swift` — reordered the `SmartView` enum to `review, pending, inProgress, blocked, failed, backlog, all` (review first, all last); added `case pending` and `case all`; updated the enum doc comment.
- `Sources/Plans/TaskType+Glyph.swift` — added `TaskStatus.allPlansFilterLabel = "All Plans"` and `TaskStatus.allPlansSymbolName = "square.stack.3d.up.fill"` statics alongside the `backlog*` vocabulary.
- `Sources/Plans/BrowserWindow.swift` (segment 2) — added `.pending`/`.all` arms to the `SmartView` `label`, `symbolName`, and `color` switches (no `default:`), and to `BrowserViewModel.rows(in:matching:)`: `.pending` filters active rows by `.pending` status; `.all` returns every active row across all projects.

**Tests:** `swift test --filter BrowserWindowTests` → 130 tests, 0 failures. Build green.

### Review feedback (46cb4a4)
- Split the combined Review lens into "Ready for review" (`.review`, star/blue) and "In review" (`.inReview`, eye/pink); `TaskStatus.review.filterLabel` is now "Ready for review".
- Failed now uses `xmark.octagon.fill` (distinct from blocked's `exclamationmark.octagon.fill`) everywhere the failure indicator renders.
- Sidebar hides zero-count status lenses via `BrowserViewModel.visibleSmartViews`; All Plans and the current selection are always listed.
- Full suite: 751 tests, 0 failures.

### Visual comparison
Not applicable — no `**Build:**` route and no Figma frames referenced; visual-comparison stage is a no-op for this task.

## Notes
_Additional context_
