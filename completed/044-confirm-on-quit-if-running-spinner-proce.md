# Confirm On Quit If There Are Running Spinner Processes

**ID:** 044
**Created:** 2026-06-09T00:00
**Type:** feature
**Status:** completed
**Branch:** feature/044-confirm-on-quit-if-running-spinner-proce
**Completed:** 2026-06-09T00:00

## What
Confirm on Quit if there are running spinner processes.

When the user quits the app (⌘Q or the "Quit" menu item) while one or more task
runs ("spinner processes" — the `TaskRun`s in `TaskRunner` that wrap a live Node
`run-task.js` process) are still in flight, show a confirmation dialog before
terminating. Quitting outright kills those child processes mid-work, so the user
should get a chance to cancel.

## Why
Adds value by protecting in-flight background work: today `MenuBarView`'s Quit
button (and ⌘Q) call `NSApplication.shared.terminate(nil)` directly, immediately
killing any running `run-task.js` child processes with no warning. A confirmation
on quit prevents accidental loss of autonomous-execute / elaborate / capture work
that is still running.

## How
- [x] Step 1: Add a pure, unit-testable helper on `TaskRunner` (mirroring the existing `captureMode`/`captureKey` static-helper pattern) that answers "are spinners running?" — e.g. a computed `var runningRunCount: Int { runs.values.filter { $0.isRunning }.count }` (and/or `var hasRunningRuns: Bool`) on `TaskRunner` in `Sources/Plans/TaskRunner.swift`. This is the single source of truth the delegate hook queries.
- [x] Step 2: Implement `applicationShouldTerminate(_:)` in `AppDelegate` (`Sources/Plans/PlansApp.swift`). If `taskRunner.runningRunCount == 0`, return `.terminateNow`. Otherwise show a synchronous `NSAlert` ("You have N running task(s). Quit anyway? Running tasks will be stopped.") with "Quit" (destructive) and "Cancel" buttons. On "Quit": stop every running run (iterate `taskRunner.runs` and call `taskRunner.stop(taskID:)` for each `isRunning` run, logging via `runnerLog`) and return `.terminateNow`. On "Cancel": return `.terminateCancel`.
- [x] Step 3: Route the menu Quit button through the delegate. In `Sources/Plans/MenuBarView.swift` line ~53, change `NSApplication.shared.terminate(nil)` to `NSApp.terminate(nil)` so it consults `applicationShouldTerminate(_:)` (⌘Q already routes through the delegate automatically; confirm both paths hit the hook).
- [x] Step 4: Add unit tests in `Tests/PlansTests/TaskRunnerTests.swift` covering the new helper: zero running runs → count 0 / `hasRunningRuns == false`; and (using a `@MainActor` test like `testCoordinatorTracksRunsPerTask`) verify the count reflects the `runs` map state. Run only this file: `swift test --filter TaskRunnerTests`.
- [ ] 👁 Step 5: Build and run the app (`swift build` / `./build.sh`), start a task run so a spinner is active, then press ⌘Q and use the Quit menu item — confirm the dialog appears with both paths, "Cancel" keeps the app running, and "Quit" stops the run(s) and exits. Confirm that with NO runs active, quitting exits immediately with no dialog.

## Verification
- With no running task runs, ⌘Q and the Quit menu item quit the app immediately (no dialog).
- With one or more running task runs, ⌘Q and the Quit menu item both show a confirmation dialog naming the count.
- Choosing "Cancel" keeps the app running and leaves the runs untouched.
- Choosing "Quit" stops the running run(s) and terminates the app.
- `swift test --filter TaskRunnerTests` passes.

## Impact Scope
_Fewer than 3 source files modified (PlansApp.swift, TaskRunner.swift, MenuBarView.swift) plus tests — Impact Scope section not required._

## Assumptions

### Initial (from elaboration)
- [low] Use a two-button NSAlert ("Quit" / "Cancel") rather than a three-button "Stop & Quit" variant. **Why:** "Quit" already stops runs before terminating, so a separate stop button is redundant; research recommended the simpler UX and the source description only asked to "confirm on quit."
- [low] Stop running runs synchronously via `taskRunner.stop(taskID:)` (which calls `Process.terminate()`/SIGTERM) with no graceful-shutdown timeout, then return `.terminateNow`. **Why:** research found `stop(taskID:)` is the existing single-run stop path and the Node children clean up on SIGTERM; adding an async wait would complicate the synchronous `applicationShouldTerminate` contract.
- [high] Expose the "is anything running?" check as a pure helper on `TaskRunner` and unit-test it, rather than testing the delegate directly. **Why:** the codebase consistently extracts pure, `@MainActor`/`static` testable helpers (`captureMode`, `captureKey`, `runningCaptures`) with matching `TaskRunnerTests` cases; the delegate/NSAlert path is not unit-testable.
- [high] Route the menu Quit button through `NSApp.terminate(nil)` so it consults the delegate. **Why:** `applicationShouldTerminate(_:)` is the standard AppKit hook for both ⌘Q and programmatic terminate; the current direct `NSApplication.shared.terminate(nil)` already goes through the delegate, but switching the call site keeps the intent explicit.

### Discovered during execution
- [high] Exposed the helper as two computed properties on `TaskRunner`: `runningRunCount: Int` (filter over `runs.values` on `isRunning`) and `hasRunningRuns: Bool`. The delegate uses `runningRunCount` directly (it needs the count for the alert text). **Why:** matches the plan; computed properties are simplest and `@Observable` makes them reactive for any future UI use.
- [high] NSAlert button ordering: "Quit" added first (so it's `.alertFirstButtonReturn`, the default/primary, rightmost) with `hasDestructiveAction = true`; "Cancel" added second. **Why:** `hasDestructiveAction` is available unconditionally on macOS 11+ (target is macOS 15+), so no availability guard was needed; first button is the default per AppKit convention.
- [high] Did NOT touch `runnerLog` (it is `private` to TaskRunner.swift). Omitted logging from the terminate hook entirely rather than introducing a new `Logger` in PlansApp.swift. **Why:** the plan explicitly allowed omitting logging to keep it simple and avoid a new global; the `stop(taskID:)` path already logs internally if needed.
- [high] Only tested the empty (`runningRunCount == 0`, `hasRunningRuns == false`) case for a fresh `TaskRunner()`. Did NOT test the non-empty count case. **Why:** populating `runs` with an actually-running `TaskRun` requires spawning a real `node` process (no fake injection point exists); the helper is a trivial `isRunning` filter, and existing per-task tracking tests cover the map. Avoided over-engineering a fake per the plan's guidance.
- [high] Used `NSApp.terminate(nil)` in the menu Quit button (was `NSApplication.shared.terminate(nil)`). Both reference the same shared app instance and route through the delegate; the change is for explicit intent per the plan.

## Changes
- `Sources/Plans/TaskRunner.swift`: Added `runningRunCount: Int` and `hasRunningRuns: Bool` computed properties on `TaskRunner` (filter over `runs.values` on `isRunning`).
- `Sources/Plans/PlansApp.swift`: Implemented synchronous `applicationShouldTerminate(_:)` in `AppDelegate` — returns `.terminateNow` with no running runs; otherwise shows a modal `NSAlert` (count-aware text, "Quit" destructive default + "Cancel"). On Quit, stops every running run via `taskRunner.stop(taskID:)` then `.terminateNow`; on Cancel returns `.terminateCancel`.
- `Sources/Plans/MenuBarView.swift`: Changed Quit button action from `NSApplication.shared.terminate(nil)` to `NSApp.terminate(nil)` so it routes through the delegate hook.
- `Tests/PlansTests/TaskRunnerTests.swift`: Added `testRunningRunCountIsZeroForFreshCoordinator` (`@MainActor`). Build passes; `swift test --filter TaskRunnerTests` → 25 tests, 0 failures.

## Notes
- "Spinner processes" = `TaskRun` instances in `TaskRunner.runs` whose `isRunning == true`. Each wraps a `Foundation.Process` running the bundled `run-task.js`.
- The AppDelegate already owns `taskRunner` (`Sources/Plans/PlansApp.swift:23`), so it is directly reachable from `applicationShouldTerminate(_:)`.
- Closing a detail window deliberately does NOT stop its run (see `PlanDetailView.swift`); only app quit should stop all runs.
