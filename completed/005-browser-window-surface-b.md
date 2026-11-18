# Surface B — cross-project browser window

**ID:** 005
**Created:** 2026-06-04T14:41
**Type:** feature
**Status:** completed
**Completed:** 2026-06-05T10:00
**Branch:** feature/005-browser-window-surface-b
**Source:** Imported from desktop-app-spec.md

## What
The full window for actually reading and triaging work. Must let the user:

- **Read full task bodies** — title and markdown sections (What, Why, How with its checklist, Verification, etc.) for any task in any project, rendered as markdown.
- **Filter by status across ALL projects at once** — global, not scoped to one project (e.g. show everything `in-progress` everywhere).
- **Sort by staleness** — use registry `lastSeen` as the project-level staleness signal; for finer-grained task staleness use the task file mtime and/or the `**Created:**` field, so stale/forgotten work floats up.
- **Drill down from the glance** — opening the window from a project in the menu bar lands on that project's tasks.

Per-task **type** badge (§6 type glyphs) is most useful here.

Spec references: §1 (Surface B), §6 (Type Glyphs).

## Why
Surface A (the menu bar glance, #004) answers "what's hot, everywhere" but is
counts-only — it deliberately omits task bodies and completed work. Surface B is
where the user actually reads and triages: full markdown bodies, a status filter
that spans every project at once, and a staleness ordering so forgotten work
floats up. It also redeems the drill-down seam already built in #004
(`PlansStore.selectedProjectPath`), which currently opens an empty placeholder
window. This task turns that placeholder into the real triage surface and
completes acceptance items §8.5 (browser window) and the §6 type-badge use case.

## How
- [x] Add `Sources/Plans/TaskType+Glyph.swift` — a SwiftUI extension on `TaskType` giving each case a per-task badge (glyph + short label, §6 type table: 🐞 bug / ✨ feature / ♻️ refactor / 🔧 chore). Mirror the structure of `TaskStatus+Glance.swift` (exhaustive `switch` with no `default:` so a new type forces a compile error). Add a parallel `TaskStatus` display helper (glyph/short-label per §6) if the status filter UI needs labels beyond the existing `glanceColor`.
- [x] Thread project `lastSeen` into the view model so staleness sort is possible. Today `PlansStore.reload()` maps `registryReader.readProjects()` → `taskParser.parseProject(at:)`, which **drops** `RegistryProject.lastSeen`. Add a `lastSeen: String` (raw, parsed to `Date` at sort time) to `ProjectTasks` (or carry a small pairing type in the store) and populate it in `reload()`. Keep the parser Foundation-only; do the ISO→`Date` parse where the sort happens. Do NOT add per-task file mtime here — that is deferred to #006 (per the `RegistryReader`/`Task` "deferred to #006" comments); task-level order within a project stays the existing parser order.
- [x] Build the 3-pane browser in `Sources/Plans/BrowserWindow.swift` using `NavigationSplitView`. **Left (sidebar):** a global status filter (All + the six §5.4 statuses, including `completed`) and the project list sorted by `lastSeen` descending (most-recently-seen first; entries with an unparseable/absent `lastSeen` sort last). **Middle:** the task list. **Right:** the selected task's rendered body. Replace the 14-line placeholder entirely.
- [x] Implement the **global, cross-project status filter**: the middle list shows tasks from ALL live projects (flattened across `store.projects`), filtered to the selected status (or all when "All"). When a project is selected in the sidebar, additionally scope to that project (drill-down); selecting "All projects" / clearing returns to cross-project. Each task row shows the §6 type badge, the id, and the title. Honor `store.selectedProjectPath` on open: pre-select that project so drilling in from the menu bar lands on its tasks (then the user can widen to all).
- [x] Render the selected task body on the right: title (`Task.title`), a status line, and each `## ` section (`Task.sections`) as markdown via `Text(AttributedString(markdown:))` per paragraph (tolerate parse failures by falling back to plain `Text`). Render the `## How` section specially as a read-only checklist (per `Task.howProgress` / parsing How lines): each step as a `Label` with `checkmark.square`/`square` — never interactive (§2 read-only; no toggles, no writes). Make body text selectable.
- [x] Add unit tests in `Tests/PlansTests/` (XCTest, matching existing conventions): (a) `TaskType` glyph/label mapping is total and correct (mirror `TaskStatusGlanceTests`); (b) project staleness sort orders by parsed `lastSeen` descending with absent/garbage timestamps sorting last; (c) the cross-project status-filter + drill-down scoping selects the expected task set from fixture `ProjectTasks`. Pull filter/sort logic into a small pure helper (view-model level) so it is testable without instantiating SwiftUI views, following the pattern where view logic is unit-tested as plain values.
- [x] Verify read-only invariant end to end: grep the new code to confirm no write/create/move/delete FS calls were introduced; the browser only reads from `store`. Confirm `build.sh` still builds the bundle.

## Verification
1. `swift build` (and `swift build -c release` via `./build.sh`) succeed with no warnings introduced.
2. New unit tests pass (`swift test`): type-glyph totality, project staleness sort (incl. garbage/absent `lastSeen` last), and cross-project filter + drill-down scoping. Existing tests stay green.
3. 👁 Launch via `./build.sh` and manually confirm: (a) task bodies render as markdown with the How checklist shown read-only; (b) selecting a status in the sidebar filters tasks across ALL projects at once; (c) the project list is ordered by staleness (most-recently-seen first); (d) clicking a project in the menu bar glance opens the browser pre-focused on that project's tasks.
4. No mutation of any `.plans/` data occurs (read-only §2 / §8.7) — confirmed by code inspection and by the app never writing during the manual run.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/BrowserWindow.swift` — replace placeholder with the full 3-pane `NavigationSplitView` (sidebar filter + project list, task list, rendered body).
- [x] `Sources/Plans/PlansStore.swift` — thread `lastSeen` through `reload()` into the per-project view model so staleness sort has a signal.
- [x] `Sources/Plans/TaskParser.swift` — add `lastSeen` to `ProjectTasks` (the model lives here); no change to parse logic.

### New Files
- [x] `Sources/Plans/TaskType+Glyph.swift` — per-task type badge (glyph + label), mirroring `TaskStatus+Glance.swift`.
- [x] `Tests/PlansTests/BrowserWindowTests.swift` (or similarly named) — filter/sort/glyph view-model tests.

### Related Files (may need updates)
- `Sources/Plans/PlansApp.swift` — the `Window("Plans", id: "browser")` scene already hosts `BrowserWindow` and injects `store`; likely no change, but confirm window sizing/min-size suits a 3-pane layout.
- `Sources/Plans/MenuBarView.swift` — already sets `selectedProjectPath` and opens the window; no change expected, but it is the drill-down producer #005 consumes.

### UI Affected
- Surface B browser window — net-new content (was a placeholder); becomes the primary read/triage surface.

## Assumptions

### Discovered during execution
- [high] Added `lastSeen` param to `parseProject(at:lastSeen:)` defaulted to `""` rather than carrying a separate pairing type in the store. **Why:** The task explicitly offered this as the preferred option ("Add a `lastSeen` parameter ... defaulting to ''"), and a default keeps all existing call sites/tests compiling without edits.
- [low] Added a `filterLabel: String` display helper on `TaskStatus` (in `TaskType+Glyph.swift`) for the sidebar status names ("In progress", "In review", etc.) instead of showing raw values. **Why:** The sidebar filter needs human-readable labels; the task allowed adding a minimal exhaustive status label "ONLY IF" the UI needs it. Kept distinct from `rawValue` so the hyphenated wire form ("in-progress") doesn't leak into the UI.
- [low] Used `TaskStatus.allCases` (which is in enum declaration order: pending → elaborated → in-progress → review → in-review → completed) for the sidebar status filter list. **Why:** `glanceOrder` excludes `.completed`, and the filter must include completed; `allCases` already yields a sensible §5.4 order including completed.
- [low] Placed the pure staleness-sort/parse logic in a `BrowserViewModel` enum namespace inside `BrowserWindow.swift` (`sortByStaleness`, `parseLastSeen`). **Why:** Keeps it SwiftUI-free and unit-testable as plain values per the task's "pure static helper / free function" guidance; segment 2 tests it. Used `ISO8601DateFormatter` with both fractional-seconds and plain options to tolerate registry timestamp variants.
- [low] Staleness sort treats absent/unparseable `lastSeen` as sorting LAST, with a stable secondary key on original index (via `enumerated()`). **Why:** Task requires unparseable/absent entries last; the stable secondary key keeps equal-date / both-unparseable entries in registry order deterministically.
- [low] `onAppear` only adopts `store.selectedProjectPath` when it matches a live project. **Why:** Avoids leaving the sidebar selection pointing at a project no longer present; defensive against a stale drill-down handoff. Full task pre-selection wiring is deferred to segment 2 per the task.
- [high] Middle (task list) and right (detail) panes are structural placeholders only. **Why:** The task scopes full filter/render logic to segment 2 and asks here only for a compilable 3-pane skeleton with a functional sidebar.
- [high] Introduced a local `TaskRow: Identifiable` wrapper in `BrowserWindow.swift` (composite id `projectPath + "/" + task.id`) rather than making `Task` itself `Identifiable`. **Why:** The segment brief preferred a local conformance over modifying the model; the composite id keeps the same task id unique across different projects for `List(selection:)`.
- [low] `visibleTasks` deliberately preserves the store's registry order (does NOT call `sortByStaleness`), filtering by project then status and flattening in `projects`→`tasks` order. **Why:** The brief required deterministic registry order in the middle list, independent of the sidebar's staleness sort; covered by a dedicated test.
- [low] Status filter excludes `nil`-status tasks when a status is selected and includes them only under "All". **Why:** Matches the brief's filter semantics; a `nil`-status task can't match a concrete status.
- [low] Added pure helpers `BrowserViewModel.paragraphs` (blank-line paragraph split) and `howSteps` (read-only checklist parse mirroring `TaskParser.howProgress`) so markdown/checklist rendering is testable as plain values and SwiftUI-free. **Why:** Keeps the per-paragraph markdown render and read-only How checklist logic unit-testable and out of the view.
- [low] Markdown paragraphs render via `AttributedString(markdown:options:)` with `interpretedSyntax: .inlineOnlyPreservingWhitespace`, wrapped in `try?` with a plain-`Text` fallback. **Why:** Inline-only preserves whitespace/newlines for task bodies and avoids block-grammar surprises; `try?` tolerates parse failures per the brief.
- [low] The `## How` section is rendered with `Label(_, systemImage:)` (`checkmark.square`/`square`) and NO `Toggle`/`Button`/binding. **Why:** §2 read-only — the checklist must never be interactive or write to `.plans/`.

## Changes
- **New `Sources/Plans/TaskType+Glyph.swift`** — `TaskType.glyph` (🐞/✨/♻️/🔧) and `TaskType.label`, plus `TaskStatus.filterLabel` for the sidebar. Exhaustive switches, no `default:` (mirrors `TaskStatus+Glance.swift`).
- **`Sources/Plans/TaskParser.swift`** — added `let lastSeen: String` to `ProjectTasks`; `parseProject(at:lastSeen:)` gained a defaulted `lastSeen` param that populates it. Parser stays Foundation-only (no ISO parse).
- **`Sources/Plans/PlansStore.swift`** — `reload()` now threads `project.lastSeen` into `parseProject` so the browser has a staleness signal.
- **`Sources/Plans/BrowserWindow.swift`** — replaced the 14-line placeholder with a 3-pane `NavigationSplitView`: sidebar (global status filter incl. `completed` + projects sorted by staleness, drill-down pre-selection from `store.selectedProjectPath`), middle cross-project filtered task list (type badge + id + title), and a right detail pane rendering the title, status line, per-paragraph markdown sections, and the `## How` section as a read-only `Label` checklist (`checkmark.square`/`square`, never interactive). Body is scrollable + selectable. Pure SwiftUI-free helpers `BrowserViewModel.{sortByStaleness, parseLastSeen, visibleTasks, paragraphs, howSteps}` carry the testable logic; `TaskRow: Identifiable` (composite id `projectPath/task.id`) backs `List(selection:)`.
- **New `Tests/PlansTests/BrowserWindowTests.swift`** — 15 XCTest cases: `TaskType` glyph/label totality, `sortByStaleness` (descending, garbage/absent last, fractional-seconds, stable), `visibleTasks` (no filter / status across projects excluding nil-status / drill-down scope / intersection / registry-order), and `howSteps`/`paragraphs` parsing.
- **Verification:** `swift build`, `swift build --build-tests`, and `./build.sh` (release bundle) all succeed with no new warnings. `swift test --filter BrowserWindowTests` → 16 tests, 0 failures. Read-only invariant confirmed by grep (no FS-mutator calls in the new/modified code; the How checklist uses `Label` only).

### Post-review revisions (user feedback)
- **Task id, not full path, in the table** — the middle row was rendering `row.id` (the composite `projectPath + "/" + task.id`); it now shows `row.task.id` (the 3-char id).
- **Completed omitted entirely** — the sidebar status filter now iterates `TaskStatus.glanceOrder` (which excludes `.completed`), and `visibleTasks` always drops completed tasks (even under "All"). Added a test asserting completed never appears.
- **Browser shown at launch** — added `.defaultLaunchBehavior(.presented)` to the `Window` scene so the browser opens automatically on app launch (previously only opened via menu-bar drill-down).

### Second-round revision (status indicators match the TUI dashboard)
The first-round "colored dots" used per-TYPE colors, which didn't line up with any consistent category. Replaced them with **status** indicators taken verbatim from the plans-cc TUI dashboard (`lib/render-dashboard.js` `glyphFor`/`colorForTask`):
- Added `TaskStatus.glanceGlyph` — the TUI shapes: pending `·`, elaborated/ready `○`, in-progress `▶`, review/ready-for-review `★`, in-review `◉`, completed `✓`.
- Added a pure `TaskStatusIndicator(status:isBlocked:)` value type that resolves the (glyph, color) for a task, with **blocked taking precedence** over status (`⊘` in `#cc6666`), mirroring the TUI where the blocked check is first. `nil` status falls back to a blank glyph in the neutral id color.
- The leading indicator in the task rows, the sidebar status-filter rows, and the detail header all now render the same status glyph in the same status color, so every category lines up. Task **type** is shown as a muted `[type]` tag (matching the TUI's `[type]`), not a colored dot.
- Removed the dead per-type `badgeColor` added in the first round.
- Added tests: status glyph mapping + totality, and `TaskStatusIndicator` (status passthrough, blocked precedence, nil fallback, blocked+nil). Full suite for touched files: 29 tests (22 browser + 7 glance), 0 failures. `swift build` and `./build.sh` clean.

## Notes
_Imported from desktop-app-spec.md_
