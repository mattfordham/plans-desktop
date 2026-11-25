# Surface Which Plan Is Blocking In Detail And Table Views

**ID:** 135
**Created:** 2026-11-25T10:00
**Type:** feature
**Status:** in-progress
**Branch:** feature/135-surface-blocker-identity-in-detail-and-table
**Worktree:** /Users/matt/Work/Open Source/plans-desktop/.worktrees/135-surface-blocker-identity-in-detail-and-table

## What
A recent plan allowed "blocked" plans to be elaborated/executed. This is good, but we still need to see if a plan is blocked and by what plan. Add this information to the plan detail view and also to the table view somehow.

## Why
Task #134 relaxed the work gates so a blocked plan can be elaborated/executed/discussed, but the UI still only shows the bare word "Blocked" — it never says *which* plan holds it up. Without the blocker's identity you can't tell whether to go unblock it first or just proceed, so you end up opening the `**Blocked by:**` field by hand to find out. Surfacing the blocking plan(s) in both the detail view and the cross-project list closes that gap and makes the relaxed "work while blocked" flow actually actionable.

## How Summary
`Task` already carries the raw blocker IDs (`blockedBy: [String]`) and the derived `isBlocked: Bool`; the parser needs no change. Add a pure static helper on `BrowserViewModel` that maps a task's *unmet* blocker IDs (those not in the owning project's completed set) to `(id, title?)` pairs by looking them up in the project's `tasks`, reusing the existing `#id` fallback. Surface those blockers in two places — a secondary text line beneath the "Blocked" capsule in `PlanDetailView`, and a `.help()` tooltip on the status icon in the shared list/card row (`TaskListView` / `ProjectCard`) — with the label vocabulary centralized in `TaskStatus+Glance.swift`.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — hosts `TaskRow` and `BrowserViewModel`; add the pure `blockers(for:in:)` static helper here (same file as the existing task-by-id lookup pattern).
- `Sources/Plans/PlanDetailView.swift` — the detail column; the "Blocked" capsule is at ~364–405. Add the blocker-identity line under it, resolving blockers from `store.projects`.
- `Sources/Plans/TaskListView.swift` — the cross-project list row (`TaskListRow`); status icon + `.help()` at ~98–103. Add a blocked tooltip alongside the failure tooltip.
- `Sources/Plans/ProjectCard.swift` — the per-project card row renders the same status icon with `failureTooltip` at ~608; apply the same blocked tooltip so a task reads identically in both the card and the flat list.
- `Sources/Plans/TaskStatus+Glance.swift` — centralized blocked vocabulary (`blockedColor`/`blockedSymbol`); add the "Blocked by" label/tooltip string builder here, not inline in views.
- `Tests/PlansTests/` — unit tests for the pure `blockers(for:in:)` helper and the tooltip string builder (TDD red first).

## How
- [ ] Step 1: TDD red — add `BlockerIdentityTests.swift` (or extend an existing BrowserViewModel/vocabulary test file) asserting the NEW pure helpers before they exist. Cover: (a) `BrowserViewModel.blockers(for:in:)` returns `(id, title)` pairs for a task's UNMET blockers only (a `blockedBy` id present in the project's completed set is excluded), preserves `blockedBy` order, and returns `title == nil` when the id isn't found in the project; (b) a not-blocked task (`blockedBy` empty, or all blockers completed) yields an empty list; (c) the centralized tooltip/label string builder in `TaskStatus+Glance.swift` renders e.g. `Blocked by #001 — Add auth, #002` (title when known, bare `#id` fallback when not) and returns `nil`/empty for a task with no unmet blockers. Build fixtures with the existing per-test temp-dir pattern or in-memory `Task`/`ProjectTasks` values as the surrounding tests do.
- [ ] Step 2: In `Sources/Plans/TaskStatus+Glance.swift`, add a centralized blocked-identity vocabulary: a static that builds the "Blocked by …" label/tooltip string from an ordered list of `(id: String, title: String?)` blocker pairs (title shown as `#id — Title`, bare `#id` when title is nil, comma-joined), returning `nil`/`""` when the list is empty. Keep ALL new blocked-label literals here (do not scatter them across the views), mirroring how `blockedColor`/`blockedSymbol`/filter labels already live centrally.
- [ ] Step 3: In `Sources/Plans/BrowserWindow.swift`, add the pure static `BrowserViewModel.blockers(for task: Task, in project: ProjectTasks) -> [(id: String, title: String?)]`: filter `task.blockedBy` to the UNMET ids (exclude ids whose task in `project.tasks` is in the completed dir / completed set — reuse the same completed-set logic the parser uses so the UI and `isBlocked` agree), then map each remaining id to its title via `project.tasks.first { $0.id == id }?.title` (reusing the existing by-id lookup pattern), keeping `blockedBy` order. No I/O, no SwiftUI — pure value work, so it's unit-testable.
- [ ] Step 4: In `Sources/Plans/PlanDetailView.swift`, under the status-capsule `HStack` (after ~line 405), when `row.task.isBlocked` render a secondary text line "Blocked by #NNN — Title, …" built from `BrowserViewModel.blockers(for: row.task, in:)` (find the owning project in `store.projects` by `row.projectPath`) and the Step-2 string builder, tinted in the blocked/secondary color. Add nothing that measures its own size (respect the #096 layout-loop rule). When the blocker list is empty (edge: isBlocked but no resolvable unmet blocker) render nothing extra.
- [ ] Step 5: In `Sources/Plans/TaskListView.swift` (`TaskListRow`) and `Sources/Plans/ProjectCard.swift` (the shared card row), add a blocked `.help()` tooltip on the status `Image` alongside the existing `failureTooltip`, so hovering a blocked row's red octagon reveals "Blocked by #NNN — Title, …". Build the tooltip from the same Step-2/Step-3 helpers; resolve the owning `ProjectTasks` the row belongs to. Combine with the failure tooltip (blocked tooltip when blocked, failure tooltip otherwise, matching the blocked→failed→status precedence already in `TaskStatusIndicator`). This is the minimal, convention-matching "somehow" for the table — the red octagon already flags blocked visually; the tooltip supplies the "by what."
- [ ] Step 6: Run `swift build` and the targeted tests (`swift test --filter BlockerIdentity` or the test file/class added in Step 1). Confirm the new helper and string-builder tests pass, the build is warning-free, and no blocked vocabulary was added inline outside `TaskStatus+Glance.swift`.

## Verification
- `swift test --filter` for the new test file/class passes: the `blockers(for:in:)` helper returns only unmet blockers with correct `(id, title?)` pairs and order, and the centralized "Blocked by" string builder renders titles-with-id, `#id` fallback, and empty for no blockers.
- `swift build` succeeds with no new warnings; no new blocked-label string literals appear inline in `PlanDetailView.swift` / `TaskListView.swift` / `ProjectCard.swift` (all vocabulary stays in `TaskStatus+Glance.swift`).
- Manual (optional, 👁): in the running app, select a blocked plan in the browser detail column and confirm a "Blocked by #NNN — Title" line appears beneath the "Blocked" capsule; in the cross-project list and a project card, hover a blocked row's status icon and confirm the tooltip names the blocking plan(s).
- No layout-loop regression (#096): the new detail line/tooltip must not measure its own size.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/TaskStatus+Glance.swift` — add centralized "Blocked by" label/tooltip string builder.
- [ ] `Sources/Plans/BrowserWindow.swift` — add pure `BrowserViewModel.blockers(for:in:)` helper.
- [ ] `Sources/Plans/PlanDetailView.swift` — render blocker-identity line under the Blocked capsule.
- [ ] `Sources/Plans/TaskListView.swift` — add blocked tooltip on the status icon in the flat list row.
- [ ] `Sources/Plans/ProjectCard.swift` — add the same blocked tooltip on the card row's status icon.
- [ ] `Tests/PlansTests/` — new/extended tests for the helper and string builder.

### Related Files (may need updates)
- `Sources/Plans/TaskParser.swift` — referenced only to confirm `Task.blockedBy` / `isBlocked` / completed-set logic; no change expected.

### Endpoints/UI Affected
- Plan detail column (Surface B) — new "Blocked by …" line beneath the status capsule for blocked plans.
- Cross-project task list and project cards (Surface B) — new blocked tooltip on the status icon.

## Assumptions

### Initial (from elaboration)
- [low] Show blocker **titles with the `#id`**, falling back to the bare `#id` when the blocker task can't be found in the project. **Why:** research recommended title-with-id as the friendliest readable form, and the `#id` fallback matches the existing `"#\(id)"` convention in BrowserWindow. A blocker in another project or a deleted one simply shows as `#id`.
- [low] Surface only the **UNMET** blockers (ids not in the project's completed set), not every id ever listed in `**Blocked by:**`. **Why:** `isBlocked` is already true only when *some* blocker is incomplete; showing already-completed deps would mislead ("blocked by #001" when #001 is done). Listing only the unmet ones matches the derived blocked signal. Flagged low because the alternative (list all deps, struck-through completed ones) is defensible — chose the simpler, less-cluttered reading.
- [low] The table/list surface uses a **`.help()` tooltip** on the existing status icon rather than a new visible column or pill. **Why:** the task says "somehow"; the red octagon already flags blocked visually, and a tooltip mirrors the existing `failureTooltip` pattern exactly with zero layout risk to the shared, pinned row column metrics (`ProjectCard.rowColumns`). A persistent visible pill was the richer alternative but risks disturbing both card and list layouts (and #096 layout loops); the tooltip is the convention-matching minimum. The detail view, which has room, gets the fuller inline text line.
- [high] Blocker-identity resolution lives in a **pure view-model helper** (`BrowserViewModel.blockers(for:in:)`), NOT in `TaskParser`/`Task`. **Why:** research explicitly warned against making the Foundation-only, single-project parser cross-task-aware; the store already holds the project's task set, and a pure static keeps it unit-testable without inflating `Task.==`/`resolveBlocked`. Clear single-option call from the codebase conventions.
- [high] All new blocked-label strings are centralized in `TaskStatus+Glance.swift`. **Why:** CLAUDE.md and the research both mandate keeping the glyph/label vocabulary centralized; inline literals across two views would violate that convention.
- [low] Blockers are resolved **within the owning project only** (same-project ids). **Why:** `**Blocked by:**` ids are project-local in the plans-cc data contract; cross-project blocking isn't modeled, so a not-found id falls back to `#id` rather than scanning other projects.

### Discovered during execution
_To be filled during execution_

## Changes
_To be filled during execution_

## Notes
_Additional context_
