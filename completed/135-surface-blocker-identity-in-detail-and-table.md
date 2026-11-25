# Surface Which Plan Is Blocking In Detail And Table Views

**ID:** 135
**Created:** 2026-11-25T10:00
**Type:** feature
**Status:** completed
**Branch:** feature/135-surface-blocker-identity-in-detail-and-table
**Completed:** 2026-11-25T10:07

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
- [x] Step 1: TDD red — add `BlockerIdentityTests.swift` (or extend an existing BrowserViewModel/vocabulary test file) asserting the NEW pure helpers before they exist. Cover: (a) `BrowserViewModel.blockers(for:in:)` returns `(id, title)` pairs for a task's UNMET blockers only (a `blockedBy` id present in the project's completed set is excluded), preserves `blockedBy` order, and returns `title == nil` when the id isn't found in the project; (b) a not-blocked task (`blockedBy` empty, or all blockers completed) yields an empty list; (c) the centralized tooltip/label string builder in `TaskStatus+Glance.swift` renders e.g. `Blocked by #001 — Add auth, #002` (title when known, bare `#id` fallback when not) and returns `nil`/empty for a task with no unmet blockers. Build fixtures with the existing per-test temp-dir pattern or in-memory `Task`/`ProjectTasks` values as the surrounding tests do.
- [x] Step 2: In `Sources/Plans/TaskStatus+Glance.swift`, add a centralized blocked-identity vocabulary: a static that builds the "Blocked by …" label/tooltip string from an ordered list of `(id: String, title: String?)` blocker pairs (title shown as `#id — Title`, bare `#id` when title is nil, comma-joined), returning `nil`/`""` when the list is empty. Keep ALL new blocked-label literals here (do not scatter them across the views), mirroring how `blockedColor`/`blockedSymbol`/filter labels already live centrally.
- [x] Step 3: In `Sources/Plans/BrowserWindow.swift`, add the pure static `BrowserViewModel.blockers(for task: Task, in project: ProjectTasks) -> [(id: String, title: String?)]`: filter `task.blockedBy` to the UNMET ids (exclude ids whose task in `project.tasks` is in the completed dir / completed set — reuse the same completed-set logic the parser uses so the UI and `isBlocked` agree), then map each remaining id to its title via `project.tasks.first { $0.id == id }?.title` (reusing the existing by-id lookup pattern), keeping `blockedBy` order. No I/O, no SwiftUI — pure value work, so it's unit-testable.
- [x] Step 4: In `Sources/Plans/PlanDetailView.swift`, under the status-capsule `HStack` (after ~line 405), when `row.task.isBlocked` render a secondary text line "Blocked by #NNN — Title, …" built from `BrowserViewModel.blockers(for: row.task, in:)` (find the owning project in `store.projects` by `row.projectPath`) and the Step-2 string builder, tinted in the blocked/secondary color. Add nothing that measures its own size (respect the #096 layout-loop rule). When the blocker list is empty (edge: isBlocked but no resolvable unmet blocker) render nothing extra.
- [x] Step 5: In `Sources/Plans/TaskListView.swift` (`TaskListRow`) and `Sources/Plans/ProjectCard.swift` (the shared card row), add a blocked `.help()` tooltip on the status `Image` alongside the existing `failureTooltip`, so hovering a blocked row's red octagon reveals "Blocked by #NNN — Title, …". Build the tooltip from the same Step-2/Step-3 helpers; resolve the owning `ProjectTasks` the row belongs to. Combine with the failure tooltip (blocked tooltip when blocked, failure tooltip otherwise, matching the blocked→failed→status precedence already in `TaskStatusIndicator`). This is the minimal, convention-matching "somehow" for the table — the red octagon already flags blocked visually; the tooltip supplies the "by what."
- [x] Step 6: Run `swift build` and the targeted tests (`swift test --filter BlockerIdentity` or the test file/class added in Step 1). Confirm the new helper and string-builder tests pass, the build is warning-free, and no blocked vocabulary was added inline outside `TaskStatus+Glance.swift`.

## Verification
- `swift test --filter` for the new test file/class passes: the `blockers(for:in:)` helper returns only unmet blockers with correct `(id, title?)` pairs and order, and the centralized "Blocked by" string builder renders titles-with-id, `#id` fallback, and empty for no blockers.
- `swift build` succeeds with no new warnings; no new blocked-label string literals appear inline in `PlanDetailView.swift` / `TaskListView.swift` / `ProjectCard.swift` (all vocabulary stays in `TaskStatus+Glance.swift`).
- Manual (optional, 👁): in the running app, select a blocked plan in the browser detail column and confirm a "Blocked by #NNN — Title" line appears beneath the "Blocked" capsule; in the cross-project list and a project card, hover a blocked row's status icon and confirm the tooltip names the blocking plan(s).
- No layout-loop regression (#096): the new detail line/tooltip must not measure its own size.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/TaskStatus+Glance.swift` — add centralized "Blocked by" label/tooltip string builder.
- [x] `Sources/Plans/BrowserWindow.swift` — add pure `BrowserViewModel.blockers(for:in:)` helper.
- [x] `Sources/Plans/PlanDetailView.swift` — render blocker-identity line under the Blocked capsule.
- [x] `Sources/Plans/TaskListView.swift` — add blocked tooltip on the status icon in the flat list row.
- [x] `Sources/Plans/ProjectCard.swift` — add the same blocked tooltip on the card row's status icon.
- [x] `Tests/PlansTests/` — new/extended tests for the helper and string builder.

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
- [high] `blockers(for:in:)` returns an "unmet" blocker even when its id matches NO task in the project (title nil, still listed). **Why:** An id with no matching task can't be proven completed, so it stays unmet — matches the parser's `isBlocked` logic (`blockedBy.contains { !completedIds.contains($0) }`) and the Step 1 test for a not-found id.
- [high] The "Blocked by …" label uses em dash `—` as the id/title separator and trims whitespace-only titles to a bare `#id`. **Why:** Matches the segment's stated example `Blocked by #001 — Add auth, #002`; trimming guards against a parsed-but-blank title rendering a dangling `#001 — `.
- [low] Rendered the detail blocked line as `.subheadline` tinted in `TaskStatusIndicator.blockedColor` with `.help()` + `.textSelection`, placed below the capsule row with `.padding(.bottom, 16)` mirroring the capsule block. **Why:** The segment offered `.subheadline`/`.caption` and `blockedColor`/`.secondary`; chose the blocked tint at subheadline scale so it reads as a continuation of the blocked capsule, and matched the existing padding rhythm. No self-measuring container (#096).
- [high] Added a pure `TaskStatusIndicator.rowStatusTooltip(blockedLabel:failureTooltip:)` in `TaskStatus+Glance.swift` that applies the blocked → failure → `""` precedence, and used it in BOTH row views' `.help(…)`. **Why:** Keeps the empty-fallback selection (and thus any string vocabulary) out of the views and makes the precedence unit-testable; mirrors the precedence already in `TaskStatusIndicator.init`. Returns `""` (not `nil`) to match the existing `.help(…?? "")` call-site contract.
- [high] ProjectCard's card `planRow` resolves the owning `ProjectTasks` DIRECTLY from its `let project: ProjectTasks` stored property (already in scope) — no new environment/param. **Why:** The card view already holds its single project, so `BrowserViewModel.blockers(for: row.task, in: project)` needs nothing threaded.
- [high] `TaskListRow` (the cross-project flat-list leaf) resolves the owning `ProjectTasks` by adding `@Environment(PlansStore.self) private var store` and looking it up by `row.projectPath` (mirroring how `PlanDetailView` resolves it), exposed via a private `blockedLabel` computed property. **Why:** A cross-project row carries only `TaskRow` (no full `ProjectTasks`), and a smart-view list spans multiple projects, so a single threaded `project` wouldn't suffice; the store is the existing cross-project source. No test constructs `TaskListRow` directly, so adding the environment broke no call sites/tests. This touches only the two in-scope view files — no parent view needed modification.

## Changes
Surfaces *which* plan(s) block a blocked task, in both the detail view and the cross-project list/card rows — no parser/model change (`Task` already carries `blockedBy` + `isBlocked`).

- **`Sources/Plans/TaskStatus+Glance.swift`** — Added two pure statics to `TaskStatusIndicator`, keeping all new blocked-label vocabulary centralized:
  - `blockedByLabel(_ blockers: [(id: String, title: String?)]) -> String?` — builds `Blocked by #001 — Add auth, #002` (em-dash between id and title; bare `#id` when the title is nil/whitespace; comma-joined); returns `nil` for an empty list.
  - `rowStatusTooltip(blockedLabel:failureTooltip:) -> String` — applies the blocked → failure → `""` precedence (mirroring `TaskStatusIndicator.init`), returning `""` to match the existing `.help(… ?? "")` call-site contract.
- **`Sources/Plans/BrowserWindow.swift`** — Added the pure `BrowserViewModel.blockers(for task: Task, in project: ProjectTasks) -> [(id: String, title: String?)]`: filters `task.blockedBy` to the UNMET ids (excludes ids whose task in `project.tasks` is `isCompletedDir`; a not-found id stays listed with `title == nil`, matching the parser's `isBlocked` logic), preserving `blockedBy` order, mapping each to its title. No I/O, no SwiftUI.
- **`Sources/Plans/PlanDetailView.swift`** — Under the status capsule, when `row.task.isBlocked` renders a `.subheadline` "Blocked by …" line tinted in `TaskStatusIndicator.blockedColor`, built from `BrowserViewModel.blockers(for:in:)` (owning project resolved from `store.projects` by `row.projectPath`) + `blockedByLabel`. Renders nothing when the project isn't found or there are no unmet blockers. No self-measuring container (#096).
- **`Sources/Plans/ProjectCard.swift`** — The card `planRow` status icon's `.help(…)` now shows the blocked tooltip (via `rowStatusTooltip`), resolving blockers from the card's in-scope `let project: ProjectTasks`; falls back to the failure tooltip otherwise.
- **`Sources/Plans/TaskListView.swift`** — `TaskListRow` gained `@Environment(PlansStore.self)` and a private `blockedLabel` computed property that resolves the owning `ProjectTasks` by `row.projectPath` (needed because a cross-project smart-view list spans projects and `TaskRow` carries no full `ProjectTasks`). The status icon's `.help(…)` now shows the blocked tooltip, falling back to the failure tooltip.
- **Tests:** `Tests/PlansTests/BrowserWindowTests.swift` — new tests for `blockers(for:in:)` (unmet-only filtering, order preservation, title nil when not found, empty for not-blocked); extended the private `makeTask` fixture with defaulted `blockedBy`/`isCompletedDir` params (existing call sites unaffected). `Tests/PlansTests/TaskStatusGlanceTests.swift` — new tests for `blockedByLabel` (title-with-id, `#id` fallback, empty) and `rowStatusTooltip` (prefers blocked, falls back to failure, empty when neither).
- **Tests run (targeted):** `swift test --filter BrowserWindowTests` → 160/0; `--filter TaskStatusGlanceTests` → 24/0; `--filter ProjectCardTests` → 37/0. `swift build` → clean, warning-free. Grep confirmed no "Blocked by" string literal outside `TaskStatus+Glance.swift`.

## Notes
_Additional context_
