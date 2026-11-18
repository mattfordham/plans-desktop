# Map "Command-N" to new plan form

**ID:** 034
**Created:** 2026-06-06T22:01
**Type:** feature
**Status:** completed
**Branch:** feature/034-map-command-n-to-new-plan-form
**Completed:** 2026-06-07T14:15

## What
Map "Command-N" to new plan form

Bind the ⌘N keyboard shortcut so it opens the shared "New Plan" capture modal
(`NewPlanModal`, added in #031) from anywhere in the app, matching the behavior
of the browser's global "New Plan" toolbar button.

## Why
The "New Plan" modal added in #031 can only be opened by clicking the toolbar
button or a card's "+" glyph. ⌘N is the universal macOS shortcut for "create a
new thing"; wiring it to the new plan form makes capture faster and meets user
expectation. Because SwiftUI reserves ⌘N for "New Window" by default, the app
should explicitly take over that menu slot so the shortcut opens the plan form
instead of spawning a blank browser window.

## How
- [x] Step 1: Add a non-persisted "open new plan" trigger to `PlansStore.swift`
      (a plain observable property — e.g. `var newPlanTrigger: Int = 0` — with NO
      `didSet` persistence, distinct from the UserDefaults-backed properties).
      Add a small `func requestNewPlan() { newPlanTrigger &+= 1 }` helper that
      bumps it. This bridges the scene-level menu command to the view-level sheet
      state through the existing single shared store, avoiding any new global
      singletons.
- [x] Step 2: In `BrowserWindow.swift`, observe the trigger with
      `.onChange(of: store.newPlanTrigger)` on `cardGrid` (alongside the existing
      `.sheet(item:)`). In the handler, run the SAME selection logic the toolbar
      button uses — `if let first = BrowserViewModel.sortByStaleness(store.projects).first
      { newPlanRequest = NewPlanRequest(projectPath: first.projectPath) }` — so
      the menu command and the button open the modal identically. Extract that
      shared logic into a private `openNewPlanForTopProject()` method and call it
      from both the toolbar button and the `.onChange` handler to keep one source
      of truth.
- [x] Step 3: In `PlansApp.swift`, add a `.commands { CommandGroup(replacing:
      .newItem) { Button("New Plan") { store.requestNewPlan() }
      .keyboardShortcut("n", modifiers: .command) .disabled(store.projects.isEmpty) } }`
      modifier on the `Window("Plans", id: "browser")` scene. `replacing:
      .newItem` takes over the default ⌘N "New Window" slot so the shortcut opens
      the plan form app-wide; disabling it when there are no projects mirrors the
      toolbar button.
- [x] Step 4: Add XCTest coverage in `Tests/PlansTests/` (extend
      `BrowserWindowTests.swift` or add a focused test): assert that
      `requestNewPlan()` increments `newPlanTrigger` on a store backed by an
      isolated `UserDefaults(suiteName:)`, and that the trigger is NOT persisted
      (a freshly reloaded store starts at 0). Run only the touched test file.
- [x] 👁 Step 5: Build and run the app (`./build.sh`); with at least one project
      registered, press ⌘N from the browser window and confirm the New Plan modal
      opens pre-selected to the top-of-grid project, and that ⌘N no longer spawns
      a blank "New Window". (User-confirmed during review.)

## Verification
- Press ⌘N in the browser window → the New Plan modal opens, pre-selected to the
  top-of-grid (most-recently-seen) project — identical to clicking the toolbar
  "New Plan" button.
- ⌘N no longer opens a blank/extra browser window (the default "New Window"
  command is replaced).
- With no projects registered, the New Plan menu item / ⌘N is disabled.
- The targeted `PlansStore` test for `requestNewPlan()` / `newPlanTrigger`
  passes; `swift build` succeeds.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/PlansStore.swift` — add non-persisted `newPlanTrigger` and `requestNewPlan()`.
- [ ] `Sources/Plans/BrowserWindow.swift` — observe the trigger, extract shared open-modal logic.
- [ ] `Sources/Plans/PlansApp.swift` — add `.commands` with a ⌘N `CommandGroup(replacing: .newItem)`.

### Related Files (may need updates)
- `Tests/PlansTests/BrowserWindowTests.swift` — add/extend test coverage for the trigger.

### Endpoints/UI Affected
- File menu "New" command and global ⌘N shortcut — now opens the New Plan modal.

## Assumptions

### Initial (from elaboration)
- [high] Used a `CommandGroup(replacing: .newItem)` ⌘N menu command rather than a button-level `.keyboardShortcut`. **Why:** macOS convention reserves ⌘N for "New" via the File menu; replacing `.newItem` overrides the default "New Window" and works app-wide even when a detail window is focused, whereas a toolbar-button shortcut only fires when the browser is focused.
- [low] Bridged the scene-level command to the view's `newPlanRequest` sheet state via a non-persisted `newPlanTrigger` counter on the shared `PlansStore` (incremented by `requestNewPlan()`, observed by `.onChange` in `BrowserWindow`). **Why:** the `.commands` block lives in the `App` scene and cannot directly mutate `BrowserWindow`'s private `@State`; routing through the single shared store matches the app's established pattern and avoids a new global. A counter (vs. a Bool) re-fires reliably on repeated ⌘N presses.
- [high] ⌘N opens the modal pre-selected to the top-of-grid project, reusing the toolbar button's exact `sortByStaleness(...).first` logic. **Why:** keeps the menu command and toolbar button behaviorally identical; the toolbar button already established this default.
- [low] Disabled the ⌘N command when `store.projects.isEmpty`, mirroring the toolbar button's `.disabled(...)`. **Why:** opening the capture modal with no project to capture against is not useful; matching the button keeps behavior consistent. The source description didn't specify empty-state behavior.

### Discovered during execution
- [high] Placed the `newPlanTrigger` test coverage in `PlansStoreTests.swift` (not `BrowserWindowTests.swift`). **Why:** the trigger is store behavior, and `PlansStoreTests` already exposes the exact `makeDefaults()` / `makeReader(projectPaths:)` isolation helpers the plan asked to reuse; `BrowserWindowTests` only tests pure `BrowserViewModel` helpers with no store init.
- [high] Used `PlansStore(registryReader:defaults:)` for the isolated-store tests, matching the established pattern in the existing capture-draft / manual-order tests. **Why:** that is the documented test-injectable initializer; no new init was invented.
- [low] Observed 4 pre-existing, unrelated test failures in `PlansStoreTests` (`"alpha"` vs `"Alpha"` project-name titleization in `testReloadPopulatesProjectsWithCounts` and `testStartPollingPerformsInitialLoadSynchronously`). **Why:** these exercise the `reload()`/`projectName` path which this segment does not touch; my two added trigger tests pass in isolation. Flagging so the orchestrator is aware they predate this work.

## Changes
- `Sources/Plans/PlansStore.swift`: added non-persisted `var newPlanTrigger: Int = 0`
  (no `didSet`, not loaded in `init`) and `func requestNewPlan()` that bumps it via
  `&+= 1`. Bridges the scene-level ⌘N command to the browser's sheet state.
- `Sources/Plans/BrowserWindow.swift`: extracted `private func openNewPlanForTopProject()`
  (the `sortByStaleness(...).first` → `newPlanRequest` logic); the toolbar "New Plan"
  button now calls it, and `.onChange(of: store.newPlanTrigger)` on `cardGrid` calls it
  too — so the menu command and button open the modal identically.
- `Sources/Plans/PlansApp.swift`: added `.commands { CommandGroup(replacing: .newItem)
  { Button("New Plan") { store.requestNewPlan() }.keyboardShortcut("n", modifiers:
  .command).disabled(store.projects.isEmpty) } }` on the browser `Window` scene,
  replacing the default ⌘N "New Window" so ⌘N opens the plan form app-wide.
- `Tests/PlansTests/PlansStoreTests.swift`: added `testRequestNewPlanIncrementsTrigger`
  (0 → 1 → 2) and `testNewPlanTriggerIsNotPersisted` (fresh store on same isolated
  suite → 0), reusing the existing `PlansStore(registryReader:defaults:)` isolation
  pattern. Both pass; `swift build` succeeds.

## Notes
The New Plan modal infrastructure (`NewPlanModal`, `NewPlanRequest`, draft
persistence) was built in completed task #031. This task only adds the ⌘N
entry point.
