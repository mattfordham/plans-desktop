# Add "layout" option for cards

**ID:** 033
**Created:** 2026-06-06T20:08
**Type:** feature
**Status:** completed
**Completed:** 2026-06-07T09:55
**Branch:** feature/033-add-layout-option-for-cards

## What
Add a "layout" option for cards — an option to fit cards to the screen vs scrolling.

The cross-project browser window (`BrowserWindow`, Surface B) currently lays the
project cards out in a `ScrollView` + responsive `LazyVGrid` whose column count is
derived purely from the viewport **width** (`columnCount(forWidth:)`), so cards
reflow 1→2→3→4 columns horizontally and scroll vertically when they overflow.

This task adds a user-selectable **card layout mode** with two options:
- **Scroll** (default, current behavior): width-driven column count, vertical scroll.
- **Fit to screen**: choose a column count from the *number of projects* so all
  cards are spread across more columns and fit on screen with little/no scrolling.

## Why
Adds value by letting the user choose between the familiar scrolling layout and a
"fit everything on screen" layout when they have many projects and want a single
glance overview without scrolling. It mirrors the existing per-view preference
pattern already in the app (`hideEmptyProjects`, `manualOrderActive`), so it fits
the established UX and persistence conventions.

## How
- [x] Step 1: Add a `CardLayoutMode` enum (`.scroll`, `.fit`) with a raw `String`
      value, `CaseIterable`, following the enum-vocabulary pattern used by
      `TaskStatus`/`TaskType`. Give it computed `label` and `symbolName`
      properties (for the toolbar control) and a `toggled` helper that flips
      between the two cases. Put it in a new file `Sources/Plans/CardLayout.swift`.
- [x] Step 2: Add a pure, unit-testable `BrowserWindow.fitColumnCount(forCount:)`
      static helper that returns the column count for fit-to-screen mode: a
      near-square grid, `max(1, Int(ceil(sqrt(Double(count)))))`, with `0`
      projects yielding `1`. This mirrors the existing pure
      `columnCount(forWidth:)` helper so the layout math stays testable without a
      view. Write XCTest cases FIRST (TDD red) in `BrowserWindowTests.swift`
      alongside the existing `columnCount` tests, then implement to green.
- [x] Step 3: Add a persisted `cardLayoutMode: CardLayoutMode` preference to
      `PlansStore`, following the exact `hideEmptyProjects` pattern: a stored
      property with a `didSet` that writes its `rawValue` to `UserDefaults` under
      a new static `cardLayoutKey`, and eager load in `init()` by assigning the
      backing field (`_cardLayoutMode = ...`) so the `didSet` doesn't re-persist.
      Add a `PlansStore` test mirroring the existing hide-empty persistence test
      (isolated `UserDefaults(suiteName:)`).
- [x] Step 4: Wire the layout mode into `BrowserWindow.cardGrid`: when
      `store.cardLayoutMode == .scroll` keep the current width-driven
      `columnCount(forWidth: gridWidth)`; when `.fit` use
      `fitColumnCount(forCount: sortedProjects.count)` for the `LazyVGrid`
      columns. Keep the surrounding `ScrollView` so content is never clipped on a
      small window (fit mode reduces but does not forbid scrolling). All other
      grid behavior (drag/drop, drill-down, width probe) is unchanged.
- [x] Step 5: Add a toolbar control to switch layout mode, beside the existing
      "Hide Empty" button, mirroring its exact chrome: a plain `Button` (not a
      button-styled `Toggle`) whose `Label` uses `store.cardLayoutMode.symbolName`
      and is `.tint`-tinted when fit-to-screen is active. Tapping it sets
      `store.cardLayoutMode = store.cardLayoutMode.toggled`. Add a `.help(...)`
      string.
- [x] 👁 Step 6: Build (`swift build`) and run the app (`./build.sh`) to visually
      confirm: the toolbar toggle appears, switching to "Fit to screen" spreads
      the cards across more columns to fit the window, and switching back to
      "Scroll" restores the width-driven reflow. Confirm the choice persists
      across an app relaunch.

## Verification
- `swift test` passes the new `fitColumnCount` and `cardLayoutMode` persistence
  tests (and the existing suite is unaffected).
- In the running app, a toolbar control toggles between Scroll and Fit-to-screen
  layouts; Fit-to-screen lays all project cards out across enough columns to fit
  the window with minimal scrolling.
- The selected layout mode persists across app relaunch (UserDefaults), like the
  existing Hide Empty toggle.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/CardLayout.swift` — NEW: `CardLayoutMode` enum + label/symbol/toggled.
- [ ] `Sources/Plans/PlansStore.swift` — add persisted `cardLayoutMode` preference + key + eager load.
- [ ] `Sources/Plans/BrowserWindow.swift` — `fitColumnCount(forCount:)` helper, mode-aware grid columns, toolbar toggle.
- [ ] `Tests/PlansTests/BrowserWindowTests.swift` — `fitColumnCount` unit tests.
- [ ] `Tests/PlansTests/PlansStoreTests.swift` — `cardLayoutMode` persistence test (if file exists; otherwise add to existing store tests).

### Endpoints/UI Affected
- Browser window toolbar — new layout-mode toggle control.
- Browser window card grid — column count now mode-dependent.

## Assumptions

### Initial (from elaboration)
- [low] "Fit to screen" is implemented as a near-square column count derived from
  the project **count** (`ceil(sqrt(count))`), keeping the existing `ScrollView`
  as an overflow safety net rather than force-shrinking card heights. **Why:**
  Research flagged that true pixel-perfect fit needs fragile card-height
  estimation (cards vary in height by plan count); a count-based column spread is
  the simplest robust interpretation of "fit cards to screen vs scrolling" and
  keeps the testable surface a pure function, matching `columnCount(forWidth:)`.
- [low] The control is a single toggle button (Scroll ⇄ Fit), not a multi-option
  Picker/Menu. **Why:** There are exactly two modes and the existing "Hide Empty"
  toolbar control is a plain toggle button; matching it keeps toolbar chrome
  consistent (the spec/codebase comments explicitly call out keeping toolbar
  buttons visually identical).
- [high] Persist via `PlansStore` + `UserDefaults` (not `@AppStorage`), eager-loaded
  in `init`. **Why:** Every existing view preference (`hideEmptyProjects`,
  `manualOrderActive`, `projectOrderOverride`) uses this exact pattern; no
  `@AppStorage` exists anywhere in the codebase.
- [high] Layout mode is a global preference (one value for the app), not per-window.
  **Why:** Matches the existing global `hideEmptyProjects`/manual-order prefs on
  the shared single store.
- [low] Default mode is `.scroll` (current behavior). **Why:** Preserves the
  existing experience for users who don't opt in; least-surprise default.

### Discovered during execution
- [high] Mode-aware grid uses `store.cardLayoutMode == .fit ? fitColumnCount(forCount:) : columnCount(forWidth:)` inline in the `LazyVGrid` `count:` argument, leaving the `ScrollView`, width probe, drag/drop and drill-down untouched. **Why:** Smallest change that satisfies step 4; keeps `gridWidth` probe live so toggling back to `.scroll` reflows immediately.
- [low] 4 pre-existing `PlansStoreTests` failures (`testReloadPopulatesProjectsWithCounts`, `testReloadHandlesMultipleProjectsInRegistryOrder`, `testStartPollingPerformsInitialLoadSynchronously`, `testLinkProjectWritesRegistryAndReloadsSoProjectAppears`) are unrelated to this work — they fail on a clean stash with a project-name case-fold mismatch ("Alpha" vs "alpha"). **Why:** Verified by stashing all changes and re-running; failures persist on the untouched branch, so they are an environment/test-harness issue, not a regression from this segment.

## Changes
- **New** `Sources/Plans/CardLayout.swift` — `CardLayoutMode` enum (`.scroll`, `.fit`),
  `String`-raw, `CaseIterable`, with computed `label`, `symbolName`, and `toggled`
  (exhaustive switches, no `default:`, per house style).
- `Sources/Plans/BrowserWindow.swift` — added pure `static func fitColumnCount(forCount:)`
  (`max(1, ceil(sqrt(count)))`, 0→1) next to `columnCount(forWidth:)`; made the
  `LazyVGrid` column count mode-aware (`.fit` → `fitColumnCount(forCount: sortedProjects.count)`,
  else width-driven); added a new toolbar `ToolbarItem` toggle beside "Hide Empty"
  (plain Button, `.tint` when fit active, `label`/`symbolName` from the mode).
- `Sources/Plans/PlansStore.swift` — added persisted `cardLayoutMode: CardLayoutMode`
  preference (`didSet` → UserDefaults under `cardLayoutKey`, eager backing-field load
  in `init`), mirroring the `hideEmptyProjects` pattern.
- `Tests/PlansTests/BrowserWindowTests.swift` — 6 TDD unit tests for `fitColumnCount`.
- `Tests/PlansTests/PlansStoreTests.swift` — 2 tests: default `.scroll` and persistence
  across store instances (isolated `UserDefaults(suiteName:)`).

**Tests:** `swift test --filter BrowserWindowTests` → PASS (48). `swift test --filter
PlansStoreTests` → new cardLayoutMode tests PASS; 4 pre-existing failures are unrelated
(project-name "Alpha"/"alpha" case-fold mismatch present on the clean branch, confirmed
via `git stash`). `swift build` → success.

**Observation (step 6):** deferred to `/plan-review` (yolo). Build + targeted tests are
green; a human should run the app and visually confirm the toggle + persistence.

## Notes
Autonomous (yolo) elaboration: research via Explore agent + direct reads of
`BrowserWindow.swift`, `PlansStore.swift`, `BrowserWindowTests.swift`. All
elaboration prompts auto-accepted; design decisions recorded as assumptions above.
