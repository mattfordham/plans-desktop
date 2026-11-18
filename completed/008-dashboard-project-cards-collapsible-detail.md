# Dashboard of project cards with collapsible plan-detail panel

**ID:** 008
**Created:** 2026-06-05T11:00
**Type:** feature
**Status:** completed
**Branch:** feature/008-dashboard-project-cards-collapsible-detail
**Completed:** 2026-06-05T12:30

## What
Re-architect Surface B (the browser window, #005) from its current 3-pane
status-filter / task-list / detail `NavigationSplitView` into a **heads-up
dashboard**: the default and primary view is a single pane of **project cards**,
and a task/plan detail panel on the right is **collapsed by default** and only
opens when a specific plan is clicked.

The shift in mental model: the main surface is about **projects**, not plans.
The user scans projects first; plans are a drill-in.

Concretely:

- **Main panel (left, default = full-width):** a layout of **cards**, one card
  per registered project.
  - Projects are **sorted by recency of changes** (most recently changed first),
    so active projects float to the top of the grid.
  - Each card shows the project name and a compact summary of its **outstanding
    plans grouped/counted by status** — pending, in-progress, ready-for-review,
    in-review, blocked, etc. — each with its status glyph/color (reuse the
    existing TUI-matched `TaskStatusIndicator` / `glanceGlyph` / `glanceColor`).
  - Within a card, the user sees the individual outstanding plans (status
    indicator + id + title) — these are the click targets that open the detail
    panel.

- **Right panel (plan detail):** **collapsed/closed by default.** The default
  view is just the single pane of project cards. The detail panel opens only
  when one of the plans (inside a card) is clicked, showing that plan's full
  rendered body (title, status line, markdown sections, read-only `## How`
  checklist — exactly the existing detail renderer from #005). The panel can be
  **closed/collapsed** again to return to the pure card view.

This replaces the current sidebar (global status filter + flat project list) and
the flat middle task list as the *primary* navigation. The cross-project status
filtering and staleness sort from #005 are folded into the card layout
(sort = recency; status grouping = on each card) rather than thrown away.

## Why
Adds value by turning Surface B into a true heads-up dashboard: the primary view
becomes project-centric ("what's happening across all my projects, freshest
first") instead of task-centric (a flat, filter-driven task list). Cards give an
at-a-glance status summary per project, and the detail panel stays out of the way
until the user deliberately drills into a specific plan — making the default
state a clean overview rather than a 3-pane interface that always shows a task
list and an empty detail placeholder.

## How
- [x] Add `BrowserViewModel.activeRows(_ project:)` (pure, SwiftUI-free) in
  `Sources/Plans/BrowserWindow.swift` returning the project's clickable plan
  rows as `[TaskRow]` built from `project.activeTasks` (already non-completed and
  sorted by status priority then id in `TaskParser`). Reuse the existing
  `TaskRow` type (composite id `projectPath/task.id`). This is the per-card plan
  list. Keep `sortByStaleness` for ordering the cards themselves.
- [x] Add a `ProjectCard` view (new file `Sources/Plans/ProjectCard.swift`)
  rendering one project: a header (project name + a per-status count summary
  iterating `TaskStatus.glanceOrder`, showing the status icon
  (`Image(systemName: status.symbolName)`) + `glanceColor` + count for each
  status with count > 0, dropping zeros — mirroring `ProjectGlanceRow` in
  `MenuBarView.swift`), and a body listing each active plan row (the
  `TaskStatusIndicator` icon/color + `task.id` + optional `[type]` tag +
  title). Each plan row is a tap target that sets the selected row. Cards never
  show completed tasks (use `activeTasks`/`glanceOrder`, both of which exclude
  completed). A card with no active plans shows a muted "No outstanding plans".
  The card is read-only — no toggles, no status pickers, no How checkboxes (§2).
- [x] Replace the body of `BrowserWindow` (`Sources/Plans/BrowserWindow.swift`):
  drop the sidebar (global status filter + project list) and the flat middle
  task list. Build the primary view as a `ScrollView` containing a `LazyVGrid`
  (adaptive columns) of `ProjectCard`s over `BrowserViewModel.sortByStaleness(store.projects)`
  (recency-sorted). Remove the now-unused `selectedStatus`/`selectedProjectPath`
  filter state and the `sidebar`/`taskList`/`statusRow`/`taskRow` view code and
  the `visibleTasks`/`visibleRows` plumbing that only served the flat list.
- [x] Make the detail panel a **collapsible right column** that is closed by
  default and opens on plan click. Use `NavigationSplitView` with the card grid
  as the primary/content column and the existing detail renderer as the
  `detail` column, driving column visibility from selection: keep
  `@State selectedRowID` (resolve it across all projects' active rows, not just
  one project) — when it's `nil`, collapse the detail column
  (`columnVisibility = .detailOnly`'s inverse, i.e. show only the content
  column / `.doubleColumn` collapsed to content); when a plan is clicked, set
  `selectedRowID` and reveal the detail column. Add a close control (toolbar
  button or header "✕ / Close") in the detail pane that sets `selectedRowID = nil`
  to return to the pure card view.
- [x] Reuse the existing detail renderer verbatim for the right panel: the
  `detail`, `detailHeader`, `sectionView`, markdown-paragraph rendering, and the
  read-only `## How` checklist (`Label` with `checkmark.square`/`square`, never
  interactive). Resolve the selected `TaskRow` by scanning all projects' active
  rows for `selectedRowID`. Show which **project** the selected plan belongs to
  in the detail header (project name line) since the card context is no longer a
  selected sidebar item.
- [x] Preserve the §004 drill-down handoff: in `onAppear`, if
  `store.selectedProjectPath` matches a live project, scroll/anchor the card grid
  to that project's card (via `ScrollViewReader` + the project path as the id) so
  opening the window from the menu bar lands on that project. Do NOT auto-open
  the detail panel (it stays collapsed by default; the user clicks a plan to open
  it). Confirm `MenuBarView.swift` still only sets `selectedProjectPath` + opens
  the window (no change expected there).
- [x] Update `Sources/Plans/PlansApp.swift` if needed: confirm the
  `Window("Plans", id: "browser")` min-size suits a card grid + collapsible
  detail (widen `minWidth` if the grid needs it); keep `.defaultLaunchBehavior(.presented)`.
- [x] Update/extend tests in `Tests/PlansTests/BrowserWindowTests.swift`
  (XCTest, plain-value style — no SwiftUI instantiation): (a) `activeRows(project)`
  returns the project's active tasks as rows in `activeTasks` order, excluding
  completed; (b) card grid ordering uses `sortByStaleness` (recency desc,
  absent/garbage `lastSeen` last) — keep/adapt the existing staleness tests;
  (c) selected-row resolution finds the right `TaskRow` across multiple projects'
  active rows and returns nil when the id is absent/closed. Remove or adapt
  `visibleTasks` tests that assumed the flat global filter list if that helper is
  deleted. Keep `howSteps`/`paragraphs` tests (detail renderer unchanged).
- [x] Verify the read-only invariant end to end: grep the new/changed code to
  confirm no write/create/move/delete FS calls were introduced; the dashboard
  and detail only READ from `store`. Confirm `swift build`, `swift test`, and
  `./build.sh` (release bundle) all succeed with no new warnings.

### Added: intentional status iconography & a clear, consistent color palette
- [x] Replace the text glyphs with real iconography. In
  `Sources/Plans/TaskStatus+Glance.swift`, add `var symbolName: String` to
  `TaskStatus` giving each status a deliberate **SF Symbol** (vector icon, not a
  text glyph) that reads as its meaning, e.g. pending →
  `circle.dotted`/`tray`, elaborated/ready → `circle`, in-progress →
  `play.circle.fill`/`arrow.triangle.2.circlepath`, review (ready for review) →
  `star.circle.fill`, in-review → `eye.circle.fill`, completed →
  `checkmark.circle.fill`. Add a matching blocked symbol
  (`exclamationmark.octagon.fill` / `nosign`) as a static on
  `TaskStatusIndicator`. Keep the `switch` exhaustive with no `default:` so a new
  status forces a compile error. KEEP the existing `glanceGlyph` (text) for now
  as a fallback OR delete it once all call sites migrate — decide during
  execution based on whether any non-SwiftUI consumer needs the text form.
- [x] Extend `TaskStatusIndicator` to carry `symbolName: String` alongside
  `color` (built with the same blocked-takes-precedence rule as today: blocked →
  blocked symbol + blocked color; else status symbol + status color; nil →
  neutral symbol like `circle.dashed` + neutral color). This keeps ONE source of
  truth for a task's status visual so every surface renders the same icon+color.
- [x] Render the icons as real shapes wherever a status currently shows a text
  glyph: in `ProjectCard` (per-card status-count summary + each plan row), in the
  `BrowserWindow` detail header, and in `MenuBarView`'s `ProjectGlanceRow` — swap
  `Text(indicator.glyph)` / `Text(status.glanceGlyph)` for
  `Image(systemName: indicator.symbolName)` (or `status.symbolName`) with
  `.foregroundStyle(indicator.color)` and a consistent `.imageScale`/frame so
  icons align in a fixed-width slot. Apply this to the card and detail steps above
  (they currently reference `glanceGlyph`).
- [x] Make the color palette consistent and clear. Review the current Gruvbox hex
  values in `glanceColor` (pending `0x665c54`, elaborated `0xd5c4a1`,
  in-progress `0xebdbb2`, review `0x458588`, in-review `0xd3869b`, completed
  `0x8ec07c`, blocked `0xcc6666`) for legibility as **icon fills** on the app's
  window background (they were tuned for a dark TUI). Adjust toward a clearly
  distinguishable, accessible set where two statuses currently read too similarly
  (e.g. elaborated `0xd5c4a1` vs in-progress `0xebdbb2` are near-identical
  tans) — pick distinct hues per status and document the chosen palette as a
  short comment table in `TaskStatus+Glance.swift`. Decide during execution
  whether to support light/dark by using semantic/asset colors vs. fixed hex;
  prefer a single clear palette that works on the actual window chrome. Note: the
  TUI parity rationale in the file header no longer fully holds once colors
  diverge — update that doc comment to say the palette is intentionally curated
  for the desktop app rather than verbatim TUI.
- [x] Update the visual tests: in `Tests/PlansTests/TaskStatusGlanceTests.swift`
  add assertions that `symbolName` is total and correct per status (mirror the
  existing `glanceColor`/`glanceGlyph` totality tests), that
  `TaskStatusIndicator` resolves the right `symbolName` (status passthrough,
  blocked precedence, nil → neutral symbol), and update any `glanceColor` hex
  assertions to the new palette values. Keep tests asserting against concrete
  expected values so the palette stays pinned.

## Verification
1. `swift build` and `./build.sh` (release bundle) succeed with no new warnings.
2. `swift test` passes: the adapted `BrowserWindowTests` (activeRows ordering &
   completed-exclusion, staleness card-sort incl. garbage/absent last, selected-
   row resolution across projects) plus the updated `TaskStatusGlanceTests`
   (`symbolName` totality + correctness, `TaskStatusIndicator` symbol resolution
   with blocked precedence and nil fallback, new `glanceColor` palette values)
   plus unchanged `howSteps`/`paragraphs` and the other suites stay green.
3. 👁 Launch via `./build.sh` and manually confirm: (a) the default view is a
   single pane of project cards with NO detail panel showing; (b) cards are
   ordered by recency (most-recently-seen project first); (c) each card shows a
   per-status count summary and lists its outstanding plans (no completed);
   (d) clicking a plan inside a card opens the right detail panel with that
   plan's full markdown body and read-only How checklist; (e) closing the detail
   returns to the pure card view; (f) opening the window from the menu-bar glance
   lands on / scrolls to that project's card; (g) every status indicator renders
   as a real vector icon (SF Symbol), NOT a text glyph, and the same icon+color
   appears consistently across the menu bar glance, the cards, and the detail
   header; (h) the status colors are clearly distinguishable from one another at
   a glance on the actual window background.
4. No mutation of any `.plans/` data occurs (§2 read-only) — confirmed by code
   inspection (no FS-mutator calls; detail How list is `Label`-only) and by the
   app never writing during the manual run.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/BrowserWindow.swift` — replace the 3-pane sidebar/flat-list
  structure with a `LazyVGrid` of project cards + a collapsible detail column;
  add `activeRows(_:)`, keep `sortByStaleness`/detail renderer/`howSteps`/`paragraphs`,
  remove the sidebar/flat-list/global-filter code.
- [ ] `Sources/Plans/PlansApp.swift` — confirm/adjust the "browser" window
  min-size for the card grid; keep `.defaultLaunchBehavior(.presented)`.
- [ ] `Sources/Plans/TaskStatus+Glance.swift` — add `TaskStatus.symbolName`
  (SF Symbol per status) + a blocked symbol on `TaskStatusIndicator`, extend the
  indicator to carry `symbolName`, and re-tune `glanceColor` into a clearer,
  consistent palette (with a documented comment table); update the file's
  TUI-parity doc comment to note the palette is now intentionally curated.
- [ ] `Sources/Plans/MenuBarView.swift` — `ProjectGlanceRow` now renders status
  as a real `Image(systemName:)` vector icon instead of `Text(status.glanceGlyph)`,
  in the re-tuned colors. (Also the consumer-side anchor for the `onAppear`
  scroll-to-card behavior.)
- [ ] `Tests/PlansTests/BrowserWindowTests.swift` — add `activeRows` and
  selected-row-resolution tests; keep/adapt staleness sort tests; remove/adapt
  `visibleTasks` flat-filter tests if that helper is deleted.
- [ ] `Tests/PlansTests/TaskStatusGlanceTests.swift` — add `symbolName` totality
  + correctness and `TaskStatusIndicator` symbol-resolution tests; update
  `glanceColor` hex assertions to the new palette.

### New Files
- `Sources/Plans/ProjectCard.swift` — the per-project card view (status-count
  summary header + clickable active-plan rows), reusing the symbol-based
  `TaskStatusIndicator`, `glanceColor`/`glanceOrder`, and `TaskType.glyph/label`.

### Related Files (may need updates)
- `Sources/Plans/TaskParser.swift` — `ProjectTasks` already exposes `counts`,
  `activeTasks`, `projectName`, `projectPath`, `lastSeen`; no change expected
  (per-task mtime for finer recency stays deferred to #006).

### UI Affected
- Surface B browser window — primary view changes from a 3-pane task browser to
  a project-card dashboard with a collapsible plan-detail panel.

## Assumptions

### Initial (from elaboration)
- [low] Task is complex (Path B): full re-architecture of the primary view, a new
  card view file, and a changed navigation model — auto-walked the interactive
  flow in skip mode rather than auto-generating. **Why:** Type is `feature`,
  research surfaced 3+ files and several genuine UX decisions with open questions.
- [low] "Outstanding" plans on a card = non-completed tasks; cards never show
  completed (consistent with the existing browser and the menu-bar glance, which
  both hide completed). **Why:** Research flagged this as an open question;
  matching existing surfaces is the least-surprising choice. Reuses
  `activeTasks`/`glanceOrder`, both of which already exclude completed.
- [low] Card layout = a `LazyVGrid` of cards (adaptive columns) inside a
  `ScrollView`, not a single-column list. **Why:** The source description says
  "a layout of cards"; a grid reads as a dashboard. A single-column list was the
  simpler alternative but less dashboard-like.
- [low] "Sorted by recency of changes" = project-level `lastSeen` via the existing
  `sortByStaleness`; per-task file-mtime recency is NOT introduced here. **Why:**
  Per-task mtime is explicitly deferred to #006 by existing code comments;
  `lastSeen` is the available project-level signal.
- [low] Collapsible detail = `NavigationSplitView` with the card grid as content
  and the detail renderer as a right column whose visibility is driven by
  `selectedRowID` (nil → collapsed/closed by default; a plan click reveals it;
  a close control sets it back to nil). **Why:** Research offered NavigationSplitView
  column-visibility vs. HSplitView/overlay vs. a state machine; the native
  column-visibility approach maps most directly to "closed by default, opens on
  selection, closable" and reuses the existing detail pane unchanged.
- [low] The clickable unit is an individual plan row inside a card (sets
  `selectedRowID`); clicking the card header/project itself does NOT open a
  separate per-project filtered view. **Why:** The card already shows everything
  for that project; an extra project-level drill mode wasn't in the description
  and would add the sidebar-style filtering back that this task removes.
- [low] The global status filter and the flat cross-project task list from #005
  are removed as the primary navigation (folded into per-card status grouping +
  recency sort). **Why:** The description makes the default view "a single pane of
  cards representing projects" — a persistent global filter sidebar contradicts
  that. Per-card status counts preserve the status-at-a-glance value.
- [low] The §004 menu-bar drill-down scrolls/anchors the card grid to the target
  project's card on open but does NOT auto-open the detail panel. **Why:** The
  panel is "collapsed by default"; auto-opening detail would violate the default
  pure-card view the description specifies.

### Added (re-elaboration: iconography & color, user-directed)
- [low] Real iconography = **SF Symbols** (`Image(systemName:)`), not bundled
  SVG assets. **Why:** The user asked for "actual icons/svg/shapes" instead of
  text glyphs; SF Symbols are the native, vector, theme-aware way to get real
  icons in SwiftUI with zero asset pipeline, and the codebase already uses them
  (`checkmark.square`/`square` in the How checklist). Custom SVGs were the
  alternative but add an asset catalog for no clear benefit here.
- [low] Proposed per-status symbols (pending `circle.dotted`/`tray`, elaborated
  `circle`, in-progress `play.circle.fill`, review `star.circle.fill`, in-review
  `eye.circle.fill`, completed `checkmark.circle.fill`, blocked
  `exclamationmark.octagon.fill`). **Why:** Maps each status to an icon whose
  meaning is legible and keeps the family visually consistent (mostly
  `*.circle.fill`); exact symbols are a judgement call to be finalized in
  execution against how they render.
- [low] One source of truth: extend `TaskStatusIndicator` to carry `symbolName`
  alongside `color` (same blocked-precedence rule), and migrate ALL surfaces
  (cards, detail header, menu bar glance) to it. **Why:** Avoids per-surface
  icon drift; the indicator already centralizes glyph+color, so symbol belongs
  there too.
- [low] The status color palette will be **re-tuned for the desktop window**
  rather than kept verbatim from the TUI, specifically to separate
  currently-near-identical tans (elaborated `0xd5c4a1` vs in-progress
  `0xebdbb2`). **Why:** The user asked for a "consistent and clear" palette; the
  existing hexes were tuned for a dark terminal and two of them read as the same
  color as icon fills. This diverges from the #005 "verbatim TUI parity"
  rationale — flagged so the reviewer can veto if TUI parity matters more than
  on-window clarity. Exact new hexes are deferred to execution (and pinned by
  updated tests).
- [low] Kept this as further elaboration of #008 (Path C, "add steps") rather
  than a new task. **Why:** The icon/color work is the visual layer of the same
  dashboard redesign and shares its files (`ProjectCard`, `BrowserWindow`,
  `TaskStatus+Glance`); splitting it would fragment one coherent change.

### Discovered during execution
- [low] SF Symbols per status: pending → `circle.dotted`, elaborated → `circle`, inProgress → `play.circle.fill`, review → `star.circle.fill`, inReview → `eye.circle.fill`, completed → `checkmark.circle.fill`. **Why:** Judgement call on what reads as each meaning while keeping a consistent `*.circle` family; play = active, star = ready-for-review, eye = under review, checkmark = done.
- [low] Blocked indicator symbol = `exclamationmark.octagon.fill`; neutral/`nil`-status symbol = `circle.dashed`. **Why:** Octagon reads as a strong stop/halt that should take precedence over any status; dashed circle reads as "unknown/empty" without implying a real status.
- [low] Curated hex palette: pending `0x928374` (neutral gray, lifted from old `0x665c54` for clearer icon legibility), elaborated `0x83a598` (teal/aqua), inProgress `0xfabd2f` (amber/yellow), review `0x458588` (blue, kept), inReview `0xd3869b` (pink, kept), completed `0x8ec07c` (green, kept). **Why:** Old TUI tans for elaborated (`0xd5c4a1`) and inProgress (`0xebdbb2`) were near-identical as fills; split them into a cool teal vs a strong amber so all six hues are mutually distinguishable, while preserving the already-distinct review/inReview/completed.
- [high] Kept `glanceGlyph` (on `TaskStatus`) and `glyph` (on `TaskStatusIndicator`) in place alongside the new `symbolName`. **Why:** Segment scope keeps the text fallbacks for not-yet-migrated view call sites; deletion is decided in segment 5.
- [high] (Segment 2) Selection mechanism for `ProjectCard` is a `@Binding var selectedRowID: TaskRow.ID?` (not a closure). **Why:** Matches the existing `BrowserWindow` convention (`@State private var selectedRowID: TaskRow.ID?`) so the parent dashboard can share one selection source across all cards and drive the collapsible detail panel directly; bindings compose more naturally with SwiftUI selection than a closure callback.
- [low] (Segment 2) Each plan row is a `Button` with `.buttonStyle(.plain)` (not `.onTapGesture`) wrapping the row content. **Why:** Buttons get keyboard/accessibility/hover affordances for free and read as the natural tap target; `.plain` keeps the row visually custom. The header/project name is deliberately NOT wrapped, so only rows are tappable.
- [low] (Segment 2) The selected row is highlighted with a `RoundedRectangle` fill of `Color.accentColor.opacity(0.15)`. **Why:** A subtle accent wash reads as "selected" without competing with the status icon colors; opacity keeps it legible in both light/dark.
- [low] (Segment 2) Card container = `padding(14)` + `.background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))` + a 1pt `.separator` `RoundedRectangle` stroke overlay, with a `Divider()` between header and body. **Why:** The secondary background + rounded corners + hairline border read as a discrete card in a grid while staying neutral against the window; chosen over `Material` for flatter, more predictable contrast behind the colored status icons.
- [low] (Segment 2) Header status-count icons use `.imageScale(.small)` + a fixed `width: 14` slot; plan-row status icons likewise use `.imageScale(.small)` + `width: 14`. **Why:** Fixed-width slots keep icons/counts vertically aligned regardless of which SF Symbol renders, per the segment's alignment requirement.
- [high] (Segment 3) Collapsible detail mechanism = **conditional view composition**, NOT `NavigationSplitView(columnVisibility:)`. `body` is an `HStack(spacing: 0) { cardGrid; if selectedRow != nil { Divider(); detail } }` with `.animation(.default, value: selectedRowID)` and a `.move(edge: .trailing).combined(with: .opacity)` transition on the detail column. **Why:** A two-column `NavigationSplitView`'s visibility enum only exposes `.doubleColumn` (both) and `.detailOnly` (detail only) — there is NO "content-only" case, so the enum literally cannot express "detail pane fully hidden by default." Conditionally inserting the detail column is the only reliable way to get a true "closed by default → opens on plan click → closable back to pure cards" behavior; it also keeps the card grid full-width in the default state and animates the reveal/collapse cleanly. The detail column is width-bounded (`minWidth: 320, idealWidth: 380, maxWidth: 460`) so the cards keep the majority of the window.
- [low] (Segment 3) Close-control placement = an **inline header button** at the top-right of the detail column (`Label("Close", systemImage: "xmark")`, `.borderless`), not a window/navigation toolbar item. **Why:** The detail column isn't hosted inside a `NavigationStack`, so a `.toolbar { ToolbarItem(...) }` has no reliable host; an inline header button is self-contained, always renders, and sits naturally above the rendered plan body. Tapping it sets `selectedRowID = nil`, which removes the detail column and returns to the pure card view.
- [low] (Segment 3) Card grid = `ScrollViewReader { ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) } }` with each card `.id(project.projectPath)` and `.padding(16)`. **Why:** Adaptive 320pt-minimum columns give a responsive dashboard that reflows to window width; the `ScrollViewReader` + per-card `.id` is the seam segment 4 uses to scroll to a drill-down target (its proxy is intentionally unused this segment). An empty-state overlay shows "No projects" when the registry is empty.
- [low] (Segment 3) `selectedRow` resolves across ALL projects via `store.projects.flatMap { BrowserViewModel.activeRows($0) }.first { $0.id == selectedRowID }`. **Why:** There is no longer a single selected sidebar project, so the selected plan must be found among every project's active rows; returns `nil` when the id is absent/closed, which collapses the detail.
- [high] (Segment 4) Drill-down scroll fires from BOTH `.onAppear` AND `.onChange(of: store.selectedProjectPath)` on the `ScrollView`, via a shared `scrollToSelectedProject(_ proxy:)` helper. The helper calls `proxy.scrollTo(path, anchor: .top)` directly AND once more inside `DispatchQueue.main.async` (next runloop tick). **Why:** On `.onAppear` the `LazyVGrid` may not have laid out the target card yet, so a single synchronous `scrollTo` can no-op; the deferred second call reliably anchors after first layout. `.onChange` covers the case where the window is already open and the user drills into a different project from the menu bar (the path changes without a fresh `onAppear`). The guard requires the path to match a live project (`store.projects.contains`), and the helper never touches `selectedRowID`, so the detail panel stays collapsed (pure-card default) — read-only, scroll-only.
- [low] (Segment 4) Status-icon alignment slot = `.imageScale(.small)` + `.frame(width: 14, alignment: .center)` for both the `MenuBarView.ProjectGlanceRow` icons and the `BrowserWindow.detailHeader` icon. **Why:** Matches the exact slot already established in `ProjectCard` (segment 2), so every surface — menu bar, cards, detail header — renders the same `symbolName` at the same size in the same fixed-width slot, keeping icons aligned with adjacent text/counts.
- [low] (Segment 4) `Sources/Plans/PlansApp.swift` was left UNTOUCHED. **Why:** The browser window min-size is set inside `BrowserWindow` as `.frame(minWidth: 820, minHeight: 520)` (segment 3) — already ≥720 wide, enough for one ≥320 card column plus the ≥320 detail column when open, so no widening was needed. `.defaultLaunchBehavior(.presented)` already present.
- [high] (Segment 5) DELETED `BrowserViewModel.visibleTasks` from `Sources/Plans/BrowserWindow.swift` AND its tests (the six `testVisibleTasks*` methods). **Why:** The card-grid `body` no longer calls `visibleTasks` (the flat cross-project filter list was replaced by per-project `activeRows` cards in segment 3), so leaving the public helper would be dead, untested code. The task's How step + Impact Scope name deletion as the intended path; nothing blocked it. The `twoProjectFixture` helper was REPURPOSED (not deleted) to drive the new `activeRows`/selected-row-resolution tests.
- [low] (Segment 5) Test-fixture design: extended `makeProject` with an explicit `activeTasks: [Task] = []` param (keeping `counts:` defaulting to `[:]`) so `activeRows` tests populate active tasks directly; the `tasks:` and `activeTasks:` params are independent in the fixture (a completed task can live in `tasks` but be absent from `activeTasks`, which is exactly how the completed-id resolution test proves the detail can't open on finished work). **Why:** PLAIN-VALUE test style forbids instantiating views, so the cross-project selected-row resolution is replicated via a private `resolveSelectedRow(_:_:)` test helper that does `projects.flatMap { BrowserViewModel.activeRows($0) }.first { $0.id == targetID }` — mirroring the view's `selectedRow` computed property exactly.

## Changes
- **Segment 1 (icon + color foundation)** — `Sources/Plans/TaskStatus+Glance.swift`:
  - Added `TaskStatus.symbolName` (SF Symbol per status, exhaustive switch, no `default:`): pending `circle.dotted`, elaborated `circle`, inProgress `play.circle.fill`, review `star.circle.fill`, inReview `eye.circle.fill`, completed `checkmark.circle.fill`. Kept `glanceGlyph` as text fallback.
  - Extended `TaskStatusIndicator` with `symbolName` (blocked-precedence rule), plus `static blockedSymbol = "exclamationmark.octagon.fill"` and `static neutralSymbol = "circle.dashed"`. Struct stays `Equatable`/pure-value.
  - Re-tuned `glanceColor` palette for on-window icon legibility: pending `0x928374`, elaborated `0x83a598`, inProgress `0xfabd2f`, review `0x458588`, inReview `0xd3869b`, completed `0x8ec07c` — split the formerly near-identical elaborated/in-progress tans into teal vs amber. Documented as a comment table.
  - Updated file doc comment: palette is now intentionally curated for the desktop app, not verbatim TUI parity.
- **Segment 2 (data + card view)**:
  - `Sources/Plans/BrowserWindow.swift`: added `BrowserViewModel.activeRows(_ project: ProjectTasks) -> [TaskRow]` mapping `project.activeTasks` 1:1 to rows (preserving TaskParser order). `visibleTasks`/`sortByStaleness` untouched.
  - New `Sources/Plans/ProjectCard.swift`: `struct ProjectCard: View { let project: ProjectTasks; @Binding var selectedRowID: TaskRow.ID? }`. Header = project name (`.headline`) + per-status count summary (real `Image(systemName: status.symbolName)` in `glanceColor`, zero counts dropped). Body = one tappable `Button(.plain)` row per `activeRows(project)` (status icon + id + optional `[type]` tag + title), tap sets `selectedRowID = row.id`, selected row highlighted. Empty → "No outstanding plans". Card container: padding + secondary background + rounded rect + separator stroke. Read-only (§2).
- **Segment 3 (BrowserWindow body rewrite)** — `Sources/Plans/BrowserWindow.swift`:
  - Replaced the 3-pane `NavigationSplitView` body. New body: `ScrollViewReader` → `ScrollView` → `LazyVGrid` (adaptive `minimum: 320`, spacing 16) of `ProjectCard(project:selectedRowID:)` over `sortByStaleness(store.projects)`; each card `.id(project.projectPath)` for the seg-4 scroll handoff. Removed `sidebar`/`statusRow`/`taskList`/`taskRow`, the `selectedStatus`/`selectedProjectPath` filter `@State`, and `visibleRows`. Kept `@State selectedRowID`.
  - Collapsible detail: NOT `NavigationSplitView(columnVisibility:)` (two-column `NavigationSplitViewVisibility` has no content-only case). Used a conditional `HStack` — card grid full-width; the detail column (320–460pt) inserted only when `selectedRow != nil`, animated slide-in. Default (`selectedRowID == nil`) → pure card view. Inline "Close" (`xmark`) button in the detail header clears `selectedRowID`.
  - `selectedRow` resolves cross-project: `store.projects.flatMap { activeRows($0) }.first { $0.id == selectedRowID }`.
  - `detailHeader` now shows the owning `row.projectName` line above the title. Left the detail-header status text-glyph for segment 4.
  - Left `BrowserViewModel.visibleTasks` defined (unused by view) so its tests still compile; segment 5 decides deletion.
- **Segment 4 (handoff + remaining icon migrations + window config)**:
  - `Sources/Plans/BrowserWindow.swift`: wired the §004 scroll handoff — bound the `ScrollViewReader` proxy, added `scrollToSelectedProject(_:)` (guards `store.selectedProjectPath` against live projects, then `proxy.scrollTo(path, anchor: .top)` directly + once more in `DispatchQueue.main.async` for post-layout reliability), invoked from `.onAppear` and `.onChange(of: store.selectedProjectPath)`. Detail stays collapsed (`selectedRowID` untouched). Migrated `detailHeader` status visual from `Text(indicator.glyph)` to `Image(systemName: indicator.symbolName).imageScale(.small).foregroundStyle(indicator.color)` in a 14pt slot.
  - `Sources/Plans/MenuBarView.swift`: `ProjectGlanceRow` now renders the real per-status icon `Image(systemName: entry.status.symbolName)` in `glanceColor` (was a generic `circle.fill` dot), same 14pt/`.imageScale(.small)` slot. Drill behavior unchanged. Refreshed two stale "colored dot" doc comments.
  - `Sources/Plans/PlansApp.swift`: confirmed unchanged — BrowserWindow's `.frame(minWidth: 820, minHeight: 520)` already fits a ≥320 card column + ≥320 detail column; `.defaultLaunchBehavior(.presented)` present.
  - All three surfaces (menu bar, cards, detail header) now render the SAME icon+color per status (single source: `symbolName`/`glanceColor`), aligned in a consistent 14pt slot.
- **Segment 5 (tests + final verification)**:
  - `Tests/PlansTests/TaskStatusGlanceTests.swift`: repointed all 6 `glanceColor` hex assertions to the new pinned palette; added `symbolName` per-status correctness + totality tests; added `TaskStatusIndicator` symbol-resolution tests (pass-through, blocked precedence with non-nil & nil status, nil-status neutral fallback).
  - `Tests/PlansTests/BrowserWindowTests.swift`: extended `makeProject` with `activeTasks:`; added `activeRows` tests (order-preserving, composite ids, empty case); added cross-project selected-row-resolution tests (finds row in 2nd project, disambiguates shared id "001", nil for absent/completed id); repurposed `twoProjectFixture`; deleted the six `testVisibleTasks*` tests.
  - `Sources/Plans/BrowserWindow.swift`: deleted the now-unused `BrowserViewModel.visibleTasks` helper (no dead untested code left).
  - **Verification:** `swift build` clean (no warnings); `swift test` → **71 passed, 0 failed**; `./build.sh` release bundle built + launched cleanly (no warnings); read-only grep over all 5 changed Swift files → no FS-mutating calls; `## How` list is `Label`-only; sole `Button` is the in-memory "Close" control. §2 read-only invariant intact.

## Notes
Follow-on from #005 (Surface B — cross-project browser window), which built the
current 3-pane `NavigationSplitView` in `Sources/Plans/BrowserWindow.swift`.

Existing building blocks this task reuses rather than reinvents:
- `ProjectTasks` carries `projectName`, `projectPath`, `lastSeen`, `tasks`,
  `counts: [TaskStatus: Int]` (excludes nil-status, includes completed), and
  `activeTasks: [Task]` (non-completed, sorted by status priority then id) — the
  ideal source for the per-card plan list and status summary.
- `BrowserViewModel.sortByStaleness(_:)` sorts projects by `lastSeen` descending
  (absent/garbage last) — the basis for "sorted by recency of changes."
- `TaskStatusIndicator`, `TaskStatus.glanceGlyph/glanceColor/glanceOrder/filterLabel`,
  and `TaskType.glyph/label` give the status/type visuals; the `ProjectGlanceRow`
  pattern in `MenuBarView.swift` is the model for the card's status-count header.
- The right-pane detail renderer (`detail`, `detailHeader`, `sectionView`,
  markdown paragraph render, read-only How checklist) lifts as-is for the
  collapsible panel.
- §2 read-only invariant holds: cards and detail only READ from `PlansStore`;
  no writes/creates/moves/deletes of `.plans/` data.
