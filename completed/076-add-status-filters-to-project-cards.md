# Add Status Filters To Project Cards

**ID:** 076
**Created:** 2026-09-12T20:14
**Type:** feature
**Status:** completed
**Branch:** feature/076-add-status-filters-to-project-cards
**Completed:** 2026-09-14T15:20

## What
Add status filters to project cards. Example: show only bugs.

## Why
Adds value by letting a user narrow a project card's plan list to just the plans
they care about (e.g. only bugs), so a busy card with many active plans becomes
scannable without opening every row. Cards today show every active plan with no
way to filter in place.

## How Summary
Add a per-card filter that narrows the card body's plan rows by task **type**
(`bug` / `feature` / `refactor` / `chore`), reusing the existing `TaskType`
vocabulary. The filter lives in local `@State` on `ProjectCard` (matching every
other transient card-UI concern already there), is driven by a small header
`Menu` control modelled on the `ProjectViewMode` toolbar pattern, and applies
through a new pure, unit-tested filtering helper in `BrowserViewModel` so the
logic is tested as plain values, never by rendering the view. Header status
counts stay unfiltered (they describe the whole project); only the body rows are
filtered, with a distinct "No matching plans" empty state.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — hosts `BrowserViewModel` (new pure filter
  helper) and the `TaskRow` model; the unit-tested seam.
- `Sources/Plans/ProjectCard.swift` — the card UI: adds the filter `@State`, the
  header filter control, drives `rows` off the filtered helper, and adds the
  filtered-empty state.
- `Sources/Plans/TaskType+Glyph.swift` — reused `TaskType.label` / `.glyph`
  vocabulary for the filter menu options.
- `Tests/PlansTests/BrowserWindowTests.swift` — tests for the new pure filter helper.
- `Tests/PlansTests/ProjectCardTests.swift` — tests for any pure card-level decision.

## How
- [x] Step 1: Add a pure filtering helper to `BrowserViewModel` in
      `Sources/Plans/BrowserWindow.swift`, e.g.
      `static func activeRows(_ project: ProjectTasks, matchingType: TaskType?) -> [TaskRow]`
      (or a `filter(_ rows: [TaskRow], byType: TaskType?) -> [TaskRow]` companion to
      the existing `activeRows(_:)`). A `nil` filter returns all active rows
      unchanged; a non-nil filter keeps only rows whose `task.type == matchingType`.
      Keep it SwiftUI-free and total.
- [x] Step 2: Write failing tests FIRST (TDD) in
      `Tests/PlansTests/BrowserWindowTests.swift` for the new helper: nil filter →
      all active rows; a type filter → only matching rows; a filter matching nothing
      → empty array; ordering preserved. Build fixtures via a per-test temp dir per
      the suite convention. Run `swift test` to confirm they fail (red).
- [x] Step 3: Implement the helper (Step 1) so the tests pass (green). Run
      `swift test`.
- [x] Step 4: In `Sources/Plans/ProjectCard.swift`, add
      `@State private var typeFilter: TaskType? = nil` (alongside the other card-local
      `@State`), and change the `rows` computed property to feed `typeFilter` through
      the new `BrowserViewModel` helper.
- [x] Step 5: Add a filter control to the card `header` in `ProjectCard.swift` — a
      small `Menu` (mirroring the `ProjectViewMode` toolbar `Menu` pattern) with an
      "All" reset plus one entry per `TaskType.allCases` (using `TaskType.label` /
      `.glyph`). Place it in the header near the count badges; keep the card's
      read-only contract intact (filter is view state only, never mutates `.plans/`).
- [x] Step 6: Update the card body empty state in `ProjectCard.body(for:)` so a
      filter that matches nothing shows a distinct "No matching plans" message while
      an unfiltered empty card keeps "No outstanding plans".
- [x] 👁 Step 7 (✓ confirmed during review at `93c69de`): Build and run the app (`./build.sh`), open the browser window, and
      visually confirm: the filter menu appears on cards, selecting "bug" shows only
      bug rows, "All" restores every row, header counts are unaffected, and the
      filtered-empty message reads "No matching plans". (Requires visual observation
      in the running macOS app — the agent cannot see this.)

## Verification
- `swift test` passes, including the new `BrowserViewModel` filter-helper tests
  (nil → all, type → subset, no-match → empty, ordering preserved).
- Building the package succeeds (`swift build`), proving `ProjectCard` and any new
  view code compile.
- Manual (Step 7): in the running app, a card's filter menu narrows its body to the
  chosen type, "All" restores the full list, header status counts stay unchanged,
  and a no-match filter shows "No matching plans".

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/BrowserWindow.swift` — add the pure `BrowserViewModel` type-filter helper.
- [x] `Sources/Plans/ProjectCard.swift` — add `typeFilter` state, header filter `Menu`, filtered `rows`, and the filtered-empty state.
- [x] `Tests/PlansTests/BrowserWindowTests.swift` — tests for the new filter helper.

### Related Files (may need updates)
- `Tests/PlansTests/ProjectCardTests.swift` — add a test if any new pure card-level decision is introduced.
- `Sources/Plans/TaskType+Glyph.swift` — reused (read-only) for `TaskType.label` / `.glyph`; no change expected unless a filter-specific label is wanted.

### Endpoints/UI Affected
- Project card header (Surface B) — gains a per-card filter menu control.
- Project card body (Surface B) — plan rows filtered by type; new "No matching plans" empty state.

## Assumptions

### Initial (from elaboration)
- [low] Interpret the feature as a **type** filter (bug/feature/refactor/chore), not a status filter. **Why:** The title says "status filters" but the only concrete example given ("show only bugs") is a task *type*, not a `TaskStatus`; types are what card rows display as `[type]` badges, so a type filter matches the stated example most directly. Research flagged this title-vs-example mismatch as the central open question.
- [low] Scope the filter **per-card** via local `@State`, not a global/dashboard-wide or persisted control. **Why:** "show only bugs" reads as a per-card action, and every other transient card-UI concern in `ProjectCard` already uses local `@State`; a global filter would require keying state by project path on the store — more complexity than an MVP warrants. Research explicitly warned against store-level state here.
- [low] Do **not** persist the filter across launches. **Why:** Following the per-card local-state decision, the filter resets each session like other ephemeral card state (`hoveredRowID`, sheet requests); persistence (à la `ProjectViewMode`) is only justified for a shared/global control.
- [high] Header **status counts remain unfiltered**; only the body rows are filtered. **Why:** `statusCounts` describes the whole project's outstanding work and is derived from `project.counts` (all statuses), independent of the body rows; filtering it would misrepresent the project. Research confirmed counts are computed independently of the row list.
- [high] **Reuse the existing `TaskType` enum** and its `label`/`glyph` for the filter options rather than introducing a new filter-vocabulary enum. **Why:** `TaskType` is already `CaseIterable` with display strings; research flagged it as directly reusable, and adding a parallel enum would duplicate the vocabulary.
- [high] Put the filter logic in a **pure `BrowserViewModel` helper** and unit-test it as plain values (no view rendering). **Why:** The test suite convention (confirmed in research) is to test pure value helpers and never instantiate SwiftUI views; `activeRows(_:)` is the established seam to extend.
- [low] Use a header **`Menu`** control (mirroring the `ProjectViewMode` toolbar menu) rather than the never-built "status-filter sidebar" hinted at by the stale `TaskStatus.filterLabel` doc-comment. **Why:** An inline header menu is the lightest MVP and matches an existing in-app pattern; a sidebar is a larger surface change the description does not ask for. The stale `filterLabel` comment references a sidebar that was never implemented, so it is not a binding constraint.
- [low] A filter matching nothing shows a distinct **"No matching plans"** empty state (vs the existing "No outstanding plans"). **Why:** Research warned that reusing the "no outstanding work" message when a filter simply hides rows would mislead users into thinking work vanished.

### Discovered during execution
- [high] Implemented the filter as the `activeRows(_:matchingType:)` overload (delegating to the existing `activeRows(_:)` for the `nil` pass-through and filtering on `$0.task.type == matchingType` otherwise) rather than the alternative `filter(_ rows:byType:)` companion the plan offered. **Why:** the segment prompt pinned this exact signature, and the overload keeps the pass-through case honest by reusing the established `activeRows(_:)` seam, so an unfiltered card and a `nil` filter provably agree.
- [low] ~~Placed the filter `Menu` at the TRAILING edge of the header, immediately AFTER the (unfiltered) `statusCounts` ForEach~~ **Superseded during review:** the filter sits immediately after the `Spacer` and BEFORE the `statusCounts` ForEach — to the LEFT of the count badges. **Why:** the badges keep the right edge they occupy on every card (so counts stay comparable across the grid at a glance), and the filter reads as a control rather than a fifth readout appended to a row of numbers.
- [low] ~~Menu label shows the selected type's `glyph + label` when filtering and an icon-only neutral filter glyph (`line.3.horizontal.decrease.circle`) when unfiltered~~ **Superseded during review:** the menu now mirrors the `ProjectViewMode` ("All / Active / Starred") select properly — SF Symbols (new `TaskType.symbolName`) instead of emoji glyphs, and the label always renders as visible text beside the symbol (`.titleAndIcon`), reading "All" when unfiltered rather than an icon-only control. Accent-tinted only while a filter is active (unchanged). **Why:** an icon-only idle state can't say which type is active — the same reasoning that drove #072's labelled view-mode control — and emoji read as foreign next to native toolbar chrome.
- [low] Used `.menuStyle(.borderlessButton)` + `.fixedSize()` on the header menu so it renders as a compact inline control rather than a full-width bordered picker. **Why:** the header is a tight `HStack`; a bordered/expanding menu would crowd the count badges and project name.
- [low] Distinguished the two empty states purely by `typeFilter == nil` inside `body(for:)` ("No outstanding plans" when unfiltered, "No matching plans" when a filter is active), keeping identical muted-subheadline styling. **Why:** `body(for:)` only sees already-filtered rows, so it cannot tell a genuinely-empty project from a filter hiding all rows; the local `typeFilter` is the only available signal and matches the plan's `[low]` "No matching plans" assumption.

## Changes
- Step 1–3 (segment 1): Added pure helper `BrowserViewModel.activeRows(_:matchingType:)` in
  `Sources/Plans/BrowserWindow.swift` — a `nil` filter delegates to the existing
  `activeRows(_:)` (all rows unchanged); a non-nil filter keeps only rows whose
  `task.type == matchingType`, order preserved. SwiftUI-free and total.
- Added 4 TDD tests in `Tests/PlansTests/BrowserWindowTests.swift` (`(c2)` section):
  nil → all rows; `.bug` filter → only bug row; absent type → empty; multi-match order
  preserved. `swift test --filter BrowserWindowTests` → 99 tests, 0 failures; `swift build` clean.
- Step 4–6 (segment 2): In `Sources/Plans/ProjectCard.swift` — added
  `@State private var typeFilter: TaskType? = nil`; changed `rows` to
  `BrowserViewModel.activeRows(project, matchingType: typeFilter)`; added a header
  `typeFilterMenu` (`Menu` at the trailing edge after the unfiltered `statusCounts`
  badges) with an "All" reset (`typeFilter = nil`) plus one entry per
  `TaskType.allCases` (labelled `glyph + label`), accent-tinted while a filter is
  active, `.menuStyle(.borderlessButton)`; and updated `body(for:)` so an empty list
  reads "No matching plans" when `typeFilter != nil` and "No outstanding plans" when
  `typeFilter == nil`. Header `statusCounts` left unfiltered (read-only card contract
  intact — no `.plans/` mutation). `swift build` clean; `BrowserWindowTests` 99/0,
  `ProjectCardTests` 23/0.
- Review rework (commit `0f9a579`): reworked the filter control to properly mirror the
  `ProjectViewMode` ("All / Active / Starred") toolbar select, per review feedback.
  Added `TaskType.symbolName` in `Sources/Plans/TaskType+Glyph.swift` (bug →
  `ladybug.fill`, feature → `sparkles`, refactor → `arrow.triangle.2.circlepath`,
  chore → `wrench.fill`) as the SF Symbol counterpart to the emoji `glyph`, with a
  new `Tests/PlansTests/TaskTypeGlyphTests.swift` (5 tests, written first — red on
  missing `symbolName`, then green) pinning the symbols, glyphs, labels, totality and
  distinctness. `typeFilterMenu` in `ProjectCard.swift` now builds every entry as
  `Label(type.label, systemImage: type.symbolName)` and renders its own label as
  visible text beside the symbol (`.labelStyle(.titleAndIcon)`), reading "All" when
  unfiltered instead of an icon-only glyph; accent tint while narrowed unchanged.
  Full suite: 420 tests, 0 failures; `swift build` clean.

## Notes
- Deep mode was requested (`/plan-elaborate 076 deep`), but `.plans/config.json`
  defines no `models.reasoning` entry, so drafting fell back to inline elaboration
  (per the skill's deep-mode fallback rule). Research was still performed via an
  Explore sub-agent.
- The title/example mismatch (status vs type) is the single most important thing to
  re-confirm before or during execution; the type-filter interpretation is recorded
  as a `[low]` assumption above and can be revisited via `/plan-clarify 076`.
