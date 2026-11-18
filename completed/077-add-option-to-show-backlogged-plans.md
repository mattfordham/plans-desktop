# Add Option To Show Backlogged Plans

**ID:** 077
**Created:** 2026-09-15T10:16
**Type:** feature
**Status:** completed
**Completed:** 2026-09-15T13:36
**Branch:** feature/077-add-option-to-show-backlogged-plans

## What
Add option to show backlogged plans.

Surface plans that plans-cc has moved into `.plans/backlog/` (the "holding pen"
for consciously deferred work, populated by the `plan-backlog` skill and emptied
by `plan-restore`). Today the desktop app is structurally blind to that
directory — `TaskParser` only scans `pending/` and `completed/`, so a task moved
into `backlog/` silently vanishes from both surfaces. This task adds a read-only
option to reveal backlogged plans in the browser.

## Why
Adds value by making deferred work visible on demand. Backlogged plans currently
disappear entirely from the desktop app (they are neither "active" nor
"completed"), so a user cannot see what they have parked without dropping to the
CLI. A persisted, default-off toggle lets them reveal that parked work inside the
existing browser without changing the at-a-glance active/outstanding view.

## How Summary
Teach the read-only parser about a third source directory, `.plans/backlog/`,
carrying its tasks in a **separate** `backloggedTasks` collection on
`ProjectTasks` so they never leak into `activeTasks`, `counts`, or
`hasOutstandingWork` (deferred work must not read as outstanding). Add `backlog`
to the change signature so backlog/restore actions trigger a reload. Add a
persisted, default-off `showBacklog` toggle to `PlansStore` following the exact
`projectViewMode` UserDefaults idiom, expose it as a toolbar control in the
browser, and — when on — render each project's backlogged rows in `ProjectCard`
with a dimmed/deferred visual treatment via a new pure `BrowserViewModel`
helper. Strictly display-only: no file moves (§2 read-only).

**Files of note:**
- `Sources/Plans/TaskParser.swift` — scan `backlog/`; add `isBacklogged` to `Task` (+ its hand-written `==`); add `backloggedTasks` to `ProjectTasks` + its explicit `init`; add `"backlog"` to `projectSignature`.
- `Sources/Plans/PlansStore.swift` — new persisted `showBacklog: Bool` (didSet→UserDefaults), its key, `init` load; thread `backloggedTasks` through both `ProjectTasks(...)` reconstruction sites (~L652, ~L958).
- `Sources/Plans/BrowserWindow.swift` — new pure `BrowserViewModel.backlogRows(_:)` helper; a toolbar `Toggle`/menu item bound to `store.showBacklog`.
- `Sources/Plans/ProjectCard.swift` — when `showBacklog` is on, append backlogged rows below active rows with a deferred/dimmed treatment.
- `desktop-app-spec.md` — document `.plans/backlog/` in §5.1 (directory layout) and note the status/source distinction in §5.4/§5.5.
- `Tests/PlansTests/` — parser, signature, `ProjectTasks`-exclusion, view-model, and `PlansStore` persistence tests.

## How
- [x] Step 1: In `TaskParser.swift`, add a `let isBacklogged: Bool` stored property to `Task` (mirroring `isCompletedDir`), thread an `isBacklogged` argument through `parse(filename:text:...)` and `parseTaskFiles(in:isCompletedDir:)` (or a parallel `isBacklogged` flag), and **add `isBacklogged` to the hand-written `Task.==`** (lines ~147–161) — the header comment is explicit that any added property MUST be compared there or on-disk changes are silently dropped. Backlogged files keep their real `**Status:**` (`pending`/`elaborated`); do NOT force a status.
- [x] Step 2: In `TaskParser.parseProject(at:lastSeen:)`, scan `.plans/backlog/` via the existing generic `parseTaskFiles` scanner (backlog files are not completed), resolve `isBlocked` against `completedIds` as pending tasks are, and build a `backloggedTasks` array sorted like `activeTasks` (status priority then id ascending). Do NOT add backlogged tasks to `tasks`, `counts`, or `activeTasks`.
- [x] Step 3: Add `let backloggedTasks: [Task]` to `ProjectTasks` and to its explicit memberwise `init` (default `[]` so existing call sites/tests keep compiling), and return it from `parseProject`. Confirm `hasOutstandingWork` (`!activeTasks.isEmpty`) is unaffected.
- [x] Step 4: In `TaskParser.projectSignature(at:)`, add `"backlog"` to the `["pending", "completed"]` subdir list (line ~344) so backlog/restore file moves change the signature and trigger a reload.
- [x] Step 5: In `PlansStore.swift`, thread `backloggedTasks` through BOTH `ProjectTasks(...)` reconstruction sites (git-info merge ~L652 and the merged-result ~L958) by copying `parsed.backloggedTasks` / `existing.backloggedTasks`, so backlog data survives the reload/cache path.
- [x] Step 6: In `PlansStore.swift`, add a persisted `var showBacklog: Bool = false { didSet { defaults.set(showBacklog, forKey: Self.showBacklogKey) } }`, a `private static let showBacklogKey = "showBacklog"`, and load it in `init` by assigning the backing field `_showBacklog = defaults.bool(forKey: Self.showBacklogKey)` (defaults to `false`, avoiding a didSet re-write). Follows the exact `projectViewMode` idiom; NEVER written to `.plans/` (§2).
- [x] Step 7: In `BrowserWindow.swift`, add a pure `BrowserViewModel.backlogRows(_:)` helper that maps a `ProjectTasks`' `backloggedTasks` to `[TaskRow]` (mirroring `activeRows`), and add a toolbar control (a `Toggle` in a `Menu`, or a labelled toolbar item) bound to `store.showBacklog` to reveal/hide backlogged plans.
- [x] Step 8: In `ProjectCard.swift`, when `store.showBacklog` is true, append the project's backlog rows (via `BrowserViewModel.backlogRows(project)`) below the active `rows`, rendered with a distinct deferred treatment (e.g. dimmed opacity + a "Backlogged" section label/badge). Keep header `statusCounts` and the "No outstanding plans" active empty-state unchanged; show backlog rows only when the toggle is on and the project has backlogged tasks.
- [x] Step 9: Update `desktop-app-spec.md`: add `.plans/backlog/` to the §5.1 directory layout and add a note in §5.4/§5.5 that a backlogged task is defined by its source directory, not a status (it retains `pending`/`elaborated`), and is excluded from active counts.
- [x] Step 10: Add/adjust tests in `Tests/PlansTests/` (TDD — write first): a `TaskParser` test parsing a `backlog/` fixture into `backloggedTasks` with preserved status; a test that backlogged tasks are excluded from `activeTasks`/`counts`/`hasOutstandingWork`; a `projectSignature` test that a change under `backlog/` alters the signature; a `BrowserViewModel.backlogRows` test; and a `PlansStore` test that `showBacklog` persists to and loads from UserDefaults (default false). Run `swift test` until green.

## Verification
- `swift test` passes, including new tests for: backlog parsing, exclusion of
  backlogged tasks from `activeTasks`/`counts`/`hasOutstandingWork`, signature
  sensitivity to `backlog/` changes, `backlogRows`, and `showBacklog`
  persistence.
- Manual (via `./build.sh`): with a project that has a `.plans/backlog/`
  directory containing at least one task, the browser shows NO backlog rows by
  default; enabling the new toggle reveals the backlogged plans as visually
  distinct (dimmed/labelled) rows within that project's card, and the choice
  survives an app restart.
- Regression: with the toggle OFF (default), the browser, project cards, active
  counts, and the menu bar glance are byte-for-byte unchanged from today; a
  project with no `backlog/` directory is a no-op in both toggle states.
- The app never writes/moves/deletes any file under `.plans/` (§2 read-only) —
  the feature only reads `backlog/` and toggles a UserDefaults-backed preference.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/TaskParser.swift` — add `isBacklogged` to `Task` (+ `==`); scan `backlog/` in `parseProject`; add `backloggedTasks` to `ProjectTasks` + `init`; add `"backlog"` to `projectSignature`.
- [ ] `Sources/Plans/PlansStore.swift` — persisted `showBacklog` toggle (var + key + `init` load); thread `backloggedTasks` through both `ProjectTasks(...)` reconstruction sites.
- [ ] `Sources/Plans/BrowserWindow.swift` — pure `BrowserViewModel.backlogRows(_:)`; toolbar control bound to `store.showBacklog`.
- [ ] `Sources/Plans/ProjectCard.swift` — render backlog rows (dimmed/labelled) below active rows when the toggle is on.
- [ ] `desktop-app-spec.md` — document `.plans/backlog/` in §5.1 and the status-vs-source distinction in §5.4/§5.5.
- [ ] `Tests/PlansTests/` — new/adjusted tests (`TaskParserTests`, `BrowserWindowTests`, `ProjectCardTests`, `PlansStoreTests`).

### Related Files (may need updates)
- `Sources/Plans/MenuBarView.swift` — reviewed and intentionally unchanged (Surface A stays active-only); confirm it does not regress once `ProjectTasks` gains `backloggedTasks`.
- `Sources/Plans/TaskStatus+Glance.swift` — intentionally unchanged (backlog is a directory/source, NOT a `TaskStatus`); no new enum case.

### UI Affected
- Browser toolbar (Surface B) — new "Show Backlogged" toggle control.
- `ProjectCard` body — optional dimmed/labelled "Backlogged" rows below active plans when the toggle is on.

## Assumptions

### Initial (from elaboration)
_Elaborated autonomously (no interactive user available); every design decision
below was resolved by the elaborator and should be reviewed._

- [high] Scope is display-only: reveal already-backlogged plans; do NOT add backlog/restore actions that move files. **Why:** the app is strictly read-only per desktop-app-spec.md §2 — the entire codebase (`TaskParser` "only ever READS from disk … never writes") is built on this; adding file-moving actions would break that contract, so a mutation feature must be an explicit, separate request.
- [high] Backlog is NOT a new `TaskStatus`; it is a third source directory (`.plans/backlog/`), and backlogged files retain their real `pending`/`elaborated` status. **Why:** confirmed against the `plan-backlog`/`plan-restore` skills and the six-case `TaskStatus` enum; adding an enum case would force churn across every exhaustive `switch` for a concept that is a directory, not a status, and would misrepresent the data.
- [high] Backlogged tasks are kept in a SEPARATE `backloggedTasks` collection and excluded from `activeTasks`, `counts`, and `hasOutstandingWork`. **Why:** deferred work must not read as "outstanding"; leaking it into active state would silently change the `.active` view mode (#072), the menu bar glance, and card badges — the opposite of "deferred".
- [high] The `showBacklog` toggle is persisted (UserDefaults) and defaults to OFF (backlog hidden). **Why:** mirrors plans-cc, where backlog is hidden by default from `/plan-status`/`/plan-list`, and matches the existing persisted-preference pattern (`projectViewMode`, `cardLayoutMode`, starred/focus) — all UserDefaults-backed, never written to `.plans/`.
- [high] With no `.plans/backlog/` directory present (the current state of this repo), the feature is a no-op — nothing shown, no error. **Why:** the generic `parseTaskFiles` scanner already tolerates a missing directory (returns `[]`), so an absent backlog dir naturally yields an empty `backloggedTasks`.
- [low] Backlogged plans render as dimmed/labelled rows INLINE within each `ProjectCard` (below active rows), rather than as a separate dedicated view/pane or a fourth `ProjectViewMode` case. **Why:** research flagged that a view mode is a *project*-level filter whereas backlog is a *row/plan*-level concern, so a boolean row-reveal composes more cleanly and is the smaller surface; but the exact visual placement is a UX judgement the one-line source description did not specify — worth review.
- [low] The toggle is surfaced as a toolbar control (a `Toggle` inside a `Menu`, or a labelled toolbar item) in the browser window, not a menu-bar (Surface A) control or an app-wide menu command. **Why:** matches the existing browser toolbar idiom (view-mode `Menu`, card-layout toggle), but the precise control style/placement is a design choice not specified by the description.
- [low] The menu bar glance (Surface A) is left unchanged and stays active-only; backlog is a browser-only reveal. **Why:** the glance is an at-a-glance *outstanding-work* summary and backlog is deferred (non-outstanding) work, so surfacing it there would dilute the glance's purpose — but whether the user wants a backlog count in the menu bar is a scope decision worth confirming.

### Discovered during execution
- [high] `Task` has no explicit initializer; it relies on Swift's synthesized memberwise init where every stored property is a required argument. Adding the required `isBacklogged` property therefore breaks EVERY `Task(...)` construction site, not just the parser. Fixed three affected sites: `Sources/Plans/ProjectCard.swift` (a `#Preview` fixture) plus two test-fixture builders (`Tests/PlansTests/TaskRunnerTests.swift` `makeTask`, `Tests/PlansTests/BrowserWindowTests.swift`). **Why:** the segment prompt's default-`[]` guidance covers `ProjectTasks` (which DOES have an explicit init) but not `Task`, which cannot get a default without an explicit init; adding `isBacklogged: false` at each site is the minimal, non-structural fix.
- [high] `backloggedTasks` is sorted with the exact same comparator as `activeTasks` (status `activePriority` descending, then id ascending), inlined in `parseProject` rather than extracted to a shared helper. **Why:** matches the segment spec ("sorted exactly like activeTasks") and keeps the change localized; a shared sort helper would be a broader refactor outside this segment's scope.
- [high] Backlogged tasks resolve `isBlocked` against the same `completedIds` set as pending tasks and keep their real `**Status:**` (no forced status). **Why:** backlog is a source directory, not a `TaskStatus`; only `completed/` is directory-authoritative for status (§5.4).
- [high] `PlansStore.swift` has EXACTLY two `ProjectTasks(...)` reconstruction sites (git-info merge ~L652 and `applyGitInfo` merged-result ~L958); both now pass `backloggedTasks` (`parsed.backloggedTasks` / `existing.backloggedTasks`). A full-file grep confirmed no third site. **Why:** the `init` default `[]` would silently erase backlog data on the reload/git-merge path if any site were missed.
- [high] `showBacklog` persistence tests mirror the `projectViewMode`/`cardLayoutMode` tests exactly, using the existing `makeDefaults()` helper (a per-test `UserDefaults(suiteName:)`) and the two-store round-trip pattern — no new injection mechanism introduced. **Why:** segment prompt required mirroring the existing idiom; `makeDefaults()` is the established suite-defaults injection point.
- [low] The backlog toolbar control (Step 7) is a plain `Button` that flips `store.showBacklog` (NOT a button-styled `Toggle` or a `Menu`), matching the `cardLayoutMode` button idiom the segment prompt flagged as simplest/most consistent. It uses the `archivebox` / `archivebox.fill` SF Symbol pair (outline when off, filled when on), a mode-aware label ("Show Backlog" / "Hide Backlog") rendered via `Label`, is accent-tinted (`.tint`) while ON and `.primary` while OFF, and carries `.help("Show or hide backlogged (deferred) plans")`. **Why:** a two-state reveal reads more clearly as a single accent-tinted button peer of the other filter controls than a menu; the archivebox glyph is the conventional "deferred/parked" metaphor. Exact glyph, label wording, and tint are UX judgement calls open to review.
- [high] Step 10 test-completeness audit: all 5 required tests were ALREADY present from prior segments — no test files were modified in this segment. `testBackloggedTasksPreserveRealStatus`, `testBackloggedTasksDoNotLeakIntoActiveCountsOrOutstanding`, `testProjectSignatureChangesWhenBacklogFileAdded` (TaskParserTests); the `backlogRows` cluster (BrowserWindowTests); `testShowBacklogDefaultsToFalse` + `testSettingShowBacklogPersistsAcrossStoreInstances` (PlansStoreTests). **Why:** the segment instruction to add only if missing/weak; each is a direct, non-redundant assertion of its contract, so nothing was added.
- [low] Step 9 spec edits placed backlog under the EXISTING §5.1/§5.4/§5.5 headings (no new numbered sections): a `backlog/` row in the §5.1 layout block, a "holding pen / plan-backlog / plan-restore" bullet, a directory-vs-status note in §5.4's "Directory ↔ status relationship" list, `backlog/` added to the §5.5 step-1 file listing, and a new step 9 in the §5.5 numbered list describing the separate `backloggedTasks` collection + exclusion from active counts/`activeTasks`/`hasOutstandingWork`. **Why:** the segment prompt forbade inventing section numbers and required matching the doc's existing voice; extending the current lists/blocks is the least-invasive fit. Exact wording is an editorial judgement call open to review.
- [low] The backlog section (Step 8) renders in `ProjectCard.scrollableContent` BELOW the active `body(for:)` as a `VStack` with a small uppercase secondary "Backlogged" section label (an `archivebox` glyph + caption-weight text), then the backlog rows reusing the existing `planRow(_:index:)` renderer; the whole section is dimmed with `.opacity(0.55)`. The backlog rows are indexed from zero INDEPENDENTLY of the active rows so their zebra parity does not interleave with the active list. The section is gated on `store.showBacklog && !project.backloggedTasks.isEmpty`, so with the toggle off (default) the card is byte-for-byte unchanged, and a project with ONLY backlog still shows the active "No outstanding plans" empty state above the section. The header type filter deliberately does NOT narrow backlog (the toggle is a whole-card reveal). **Why:** the segment spec required an additive, dimmed/labelled section that leaves `statusCounts` and the active empty-state untouched; the exact label styling (uppercase caption + archivebox), the `0.55` opacity, and excluding backlog from the type filter are UX judgement calls open to review.

## Changes
- `Sources/Plans/TaskParser.swift`: added `let isBacklogged: Bool` to `Task`
  (threaded through `parse`, `parseTaskFiles`, `resolveBlocked`; added to the
  hand-written `Task.==` and its load-bearing doc comment). `parseProject` now
  scans `.plans/backlog/` into a new `ProjectTasks.backloggedTasks: [Task]`
  (sorted like `activeTasks`, `isBlocked` resolved against `completedIds`,
  excluded from `tasks`/`counts`/`activeTasks`). Added `"backlog"` to the
  `projectSignature` subdir list so backlog/restore moves trigger a reload.
- `Sources/Plans/PlansStore.swift`: threaded `backloggedTasks` through both
  `ProjectTasks(...)` reconstruction sites (reload git-info merge and
  `applyGitInfo`). Added a persisted, default-off `showBacklog: Bool` preference
  (var + `showBacklogKey` + `init` backing-field load) following the exact
  `projectViewMode`/UserDefaults idiom — never written to `.plans/`.
- `Sources/Plans/BrowserWindow.swift`: added pure
  `BrowserViewModel.backlogRows(_:)` (mirrors `activeRows`), and a toolbar
  `Button` (archivebox glyph, accent-tinted when on) bound to
  `store.showBacklog`.
- `Sources/Plans/ProjectCard.swift`: when `showBacklog` is on and the project
  has backlogged tasks, renders a dimmed (opacity 0.55) "Backlogged" section
  below the active rows (own indexing; reuses `planRow`). Header `statusCounts`
  and the active empty-state are unchanged; the off state is byte-for-byte
  identical to before.
- `desktop-app-spec.md`: documented `.plans/backlog/` in §5.1 and the
  directory-vs-status distinction plus `backloggedTasks` exclusion from active
  counts in §5.4/§5.5.
- Tests: `TaskParserTests` (backlog parsing + status preserved, exclusion from
  active/counts/outstanding, signature sensitivity, empty when no dir),
  `BrowserWindowTests` (`backlogRows` order/identity/empty/independence),
  `PlansStoreTests` (`showBacklog` default-false + persistence round-trip). Also
  added `isBacklogged: false` at three pre-existing `Task(...)` fixture/preview
  sites to keep the build compiling.
- Targeted tests green: `TaskParserTests` (36), `BrowserWindowTests` (103),
  `PlansStoreTests` (68) — all 0 failures; `swift build` clean.

## Notes
- Research confirmed there is currently NO `.plans/backlog/` directory in this
  repo and no occurrence of "backlog" anywhere in `Sources/` or
  `desktop-app-spec.md` — this feature is net-new plumbing.
- The generic `parseTaskFiles(in:isCompletedDir:)` scanner is reused as-is for
  the backlog directory (it already tolerates a missing directory), keeping the
  new parsing minimal.
- Guardrail: when adding `isBacklogged` to `Task`, it MUST also be added to the
  hand-written `Task.==` (TaskParser.swift ~L147–161) — the comment there warns
  that an omitted field causes real on-disk changes to be silently dropped from
  both surfaces.
