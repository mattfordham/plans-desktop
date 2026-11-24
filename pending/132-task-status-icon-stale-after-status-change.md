# Task status icon stale after status change until navigating away

**ID:** 132
**Created:** 2026-11-24T12:21
**Type:** bug
**Status:** review
**Branch:** fix/132-task-status-icon-stale-after-status-change

## What
Plans are moving to the correct category when changed ("Review" in screenshot), but the status icons are getting stuck (showing the old status glyph) until I navigate away and back.

In the screenshot, two tasks sit under the "REVIEW" group header but their row icons still show the in-progress play glyph instead of the review status glyph. The grouping/category placement updates correctly, but the per-row status icon does not refresh in place — it only corrects after navigating away from the view and back.

## Why
Improves reliability of the browser's grouped task list: a status change should update a row's icon in place, not leave a stale glyph that misreports the task's real state until the user navigates away and back. The split between correct grouping and stale icon is actively misleading.

## How Summary
The grouped list renders each section as a SwiftUI `Section` inside a single `LazyVStack` (so every header and row is a separate lazy child — the perf win from commit `b912f56`). Row identity in the inner `ForEach` is `projectPath + "/" + task.id`, which is **status-independent**. When a task moves between status groups, SwiftUI matches the same id already realized elsewhere in the flat lazy-child stream and reuses that materialized row without re-evaluating its `row` value, so the icon stays stale until the whole `TaskListView` is torn down (navigate away/back). The fix composes the status-affecting fields into the row `ForEach` identity so a status change yields a fresh identity (forcing a rebuild and fresh icon) while keeping the rows lazy.

**Files of note:**
- `Sources/Plans/TaskListView.swift` — `sectionView` (the `Section`/`ForEach` with the status-independent row id) and `TaskListRow` (renders the status icon).
- `Sources/Plans/BrowserWindow.swift` — `TaskRow.id` (status-independent composite) and `TaskRow.indicator` (derives the glyph from `task.status` / blocked / failed).
- `Tests/PlansTests/` — a regression test asserting the row identity changes when a task's status-affecting state changes.

## Diagnosis

**Most likely:** The row `ForEach` identity in the grouped list is status-independent (`projectPath + "/" + task.id`), so when a task moves between status sections inside the single `LazyVStack`, SwiftUI reuses the already-realized lazy child for that id instead of rebuilding it, leaving the row's `indicator` glyph stale. (`Sources/Plans/TaskListView.swift:416`, `Sources/Plans/BrowserWindow.swift:565`)
**Evidence:** `sectionView` emits a `Section { ForEach(rows, id: \.element.id) { TaskListRow } }` inside `LazyVStack` (`TaskListView.swift:414-424`); a `Section` in a `LazyVStack` flattens its header + rows into the one linear lazy-child stream rather than scoping identity under a per-section container. The row id (`BrowserWindow.swift:565`) carries no status. The grouping array (`BrowserViewModel.groupRows`) is recomputed independently and correctly — which is exactly why the group placement updates but the icon does not. This was introduced by commit `b912f56` ("perf: make task list rows lazy"), which replaced the previous per-section `VStack` container (one opaque lazy child per section, which scoped row identity under the section and so tore down/rebuilt a moved row) with the flattened `Section`.
**Confidence:** high

**Alternative:** A captured/memoized `indicator` or `row` value on the row view (`Sources/Plans/TaskListView.swift`) — **Confidence:** low (ruled out by reading the code: `TaskListRow.body` reads `row.indicator` fresh each evaluation; nothing memoizes it, so the staleness is a view-reuse effect, not a literal cache).

**To confirm:** Reproduce by changing a task's status from `in-progress` to `review` while the browser shows the status-grouped list, and confirm the row moves to the REVIEW group but keeps the old amber play glyph until navigating away and back — captured as a failing unit test on the row identity (agent-verifiable, so untagged).

## How
- [x] Step 1: Add a failing XCTest in `Tests/PlansTests/` that reproduces the identity bug: build a `TaskRow` for a given task at status `in-progress` and the same task id/project at status `review`, and assert the two produce DIFFERENT list identities (confirms the Diagnosis; agent-verifiable, so untagged). This drives extracting the identity into a testable value.
- [x] Step 2: Make the grouped-list row identity status-aware — expose a `listIdentity` on `TaskRow` (in `BrowserWindow.swift`) composed of the existing `id` plus the status-affecting state that drives `indicator` (status, isBlocked, isFailed), and use it as the `ForEach(..., id:)` in `sectionView` (`TaskListView.swift`). A status change now yields a fresh identity so SwiftUI rebuilds the row with the correct glyph, while rows stay lazy (laziness is unchanged — only the identity key changes).
- [x] Step 3: Keep the stable `id` for selection and any state that must survive a status change (e.g. `isSelected: selectedRowID == row.id` stays keyed on `row.id`), so changing the identity does not break selection or re-introduce eager building. Verify no other consumer relied on the `ForEach` id being status-independent.
- [x] Step 4: Run the targeted tests for the changed files and confirm the new regression test passes.
- [ ] 👁 Step 5: Build and run the app, group the browser list by Status, change a task's status (or edit its `.plans` file's `**Status:**`), and confirm the row's icon updates in place to the new status glyph without navigating away and back. (Deferred to review in worktree/yolo mode.)

## Verification
- With the browser list grouped by Status, changing a task from in-progress to review updates both its group AND its row icon in place, with no navigate-away-and-back needed.
- The new regression test in `Tests/PlansTests/` passes, asserting a task's grouped-list identity differs across a status-affecting change.
- Scrolling, selection, and per-row state are unaffected; large sections (e.g. Completed) still build lazily (no eager-build regression of `b912f56`).

## Impact Scope
_Fewer than 3 files modified; section omitted._

## Assumptions

### Initial (from elaboration)
- [high] Root cause is the status-independent `ForEach` row identity flattened by the `Section`-in-`LazyVStack` structure introduced in commit `b912f56`. **Why:** Research traced the call path with `file:line` evidence, the grouping-correct-but-icon-stale split matches this mechanism exactly, and the parent commit `bdbc0aa`/`b912f56` boundary is the regression point.
- [low] Fix composes status-affecting fields (status, isBlocked, isFailed) into the row `ForEach` identity rather than reverting the structure or forcing a full-list rebuild. **Why:** Research recommended preserving the perf win (keep rows lazy) and warned against `.id(UUID())`/wholesale revert, which would re-introduce eager building and lose scroll/per-row state; a composite identity is the minimal change that restores correct teardown/rebuild on a cross-section move. Multiple plausible fixes exist (composite id vs. per-section lazy sub-list), and the first reasonable one was chosen.
- [low] Selection and other per-row state should remain keyed on the stable `id` (not the new status-aware identity). **Why:** Keeping `isSelected` on `row.id` is the conservative choice to avoid breaking selection when identity changes; the source description did not specify this interaction.

### Discovered during execution
- [low] Made `listIdentity` a `String` (the existing `id` plus a `#`-delimited suffix of status rawValue, a blocked flag, and a failure flag) rather than a `Hashable` struct. **Why:** `ForEach(id:)` just needs a stable `Hashable`; the existing `id` is already a `String`, so a string composite is the smallest, most readable change and avoids introducing a new nested type. A struct would work equally well.
- [low] Included BOTH `isBlocked` and `isFailed` (`task.failure != nil`) in `listIdentity`, not just `status`. **Why:** `TaskRow.indicator` is derived from all three (blocked/failed take precedence over status in the glyph), so any of them changing can change the icon without `status` changing — the identity must cover every field that drives the glyph to prevent an analogous stale-icon case.
- [high] Selection stays keyed on the stable `row.id` (`isSelected: selectedRowID == row.id` unchanged); only the `sectionView` inner `ForEach` diffing key moved to `listIdentity`. **Why:** The stable `id` is the selection/state-persistence key; changing identity on a status change must not drop the detail-column selection.

## Changes
- `Sources/Plans/BrowserWindow.swift` — added `TaskRow.listIdentity: String`, a status-aware list identity = the stable `id` plus a `#`-delimited suffix of `task.status.rawValue` (or `-` when nil), a blocked flag, and a failure flag. Documented why the grouped list must key on this (Section-in-LazyVStack flattening reuses a status-independent id and leaves the glyph stale). The stable `id` is unchanged and remains the selection/state key.
- `Sources/Plans/TaskListView.swift` — changed `sectionView`'s inner `ForEach(Array(rows.enumerated()), id: \.element.id)` to `id: \.element.listIdentity`, so a status change yields a fresh identity and SwiftUI rebuilds the row with the correct icon. Laziness (the `Section` inside `LazyVStack`) is unchanged; `isSelected: selectedRowID == row.id` still keys on the stable `id`.
- `Tests/PlansTests/BrowserWindowTests.swift` — added three regression tests under a `// MARK: - TaskRow.listIdentity (#132)` block: `testListIdentityChangesWhenStatusChanges`, `testListIdentityChangesWhenBlockedOrFailedChanges`, and `testStableIdUnchangedWhenStatusChanges`.
- Targeted tests: `swift test --filter BrowserWindowTests` → 155 tests, 0 failures (includes the 3 new tests). RED confirmed first via `swift build --build-tests` (`no member 'listIdentity'`).

## Notes
- Do NOT introduce `GeometryReader` / measured-size feedback (CLAUDE.md layout-loop warning #096/#063) — this is an identity/diffing bug, not a layout bug.
- Avoid `.id(UUID())` or `.id(section.title)` on the whole list, which forces a full rebuild every ~5s poll and destroys scroll position and per-row `@State`.
