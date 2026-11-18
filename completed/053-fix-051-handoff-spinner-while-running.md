# Fix #051 Hand-Off: Move Creating Spinner To Real Plan Row While Capture Process Is Still Running

**ID:** 053
**Created:** 2026-06-16T00:00
**Type:** bug
**Status:** completed
**Branch:** fix/053-fix-051-handoff-spinner-while-running
**Completed:** 2026-06-17T09:40

## What
Fix #051 hand-off: move the "creating" capture spinner to the real plan row while the capture process is still running.

Problem: The "creating" spinner row at the top of a project card is supposed to disappear and hand its spinner to the real plan row the moment the new plan file is parsed. This works for plain `.capture` mode but NOT for `.captureElaborate` (Elaborate checkbox) or `.executeYolo` (Execute checkbox). In those modes the spawned node process runs plan-capture (writing the plan file to disk early) and then keeps running plan-elaborate/plan-execute for minutes. The real plan row appears while the capture run is still `isRunning == true`, so reconciliation skips it (`TaskRunner.taskIDsToDismiss` has `guard !run.isRunning`) and the creating spinner stays pinned beside the real row — both rows show at once.

Root cause: reconciliation only dismisses FINISHED captures, and even if dismissed the real row's spinner only shows for `runner.isRunning(taskID: row.task.id)` while the capture run is keyed under the synthetic `capture:<path>:<UUID>` key, never the real id.

Fix (re-key approach): When reconciliation sees a still-running capture whose project gained a new task id, re-key the live `TaskRun` in place from its synthetic capture key to the real task id. This removes it from `runningCaptures` (creating row vanishes), makes `runner.isRunning(taskID: realID)` true (spinner moves to the real row), and keeps the live process tracked so the progress popover and quit-confirmation `runningRunCount` stay correct.

Changes are confined to `Sources/Plans/TaskRunner.swift` (make `taskID` a `private(set) var` with a `rekey(to:)` method; add a richer pure `reconcile(runs:projects:)` helper returning both `toDismiss` and `toRekey`, keeping `taskIDsToDismiss` delegating to it; rewrite `reconcileFinishedCaptures` to apply re-keys before dismisses atomically) plus new XCTest cases in `Tests/PlansTests/TaskRunnerTests.swift`. No view or PlansApp changes needed. Single in-flight capture is handled deterministically; true concurrent captures for one project are punted (re-key skipped while >1 running, no worse than today). Full design detail in `~/.claude/plans/plan-51-was-supposed-sparkling-taco.md`.

## Why
Improves reliability by fixing the #051 spinner hand-off for the Elaborate and Execute checkboxes: today the user sees two rows at once (a stuck "creating" spinner pinned above the already-parsed plan row) for the entire multi-minute elaborate/execute run, and the real plan row never gets the live spinner or progress popover. The re-key fix makes the hand-off atomic for these long-running modes and, as a bonus, associates the live progress (and the durable outcome record) with the real task id instead of the synthetic capture key.

## How Summary
Re-key the live capture `TaskRun` from its synthetic `capture:<path>:<UUID>` key to the real task id the moment reconciliation sees a new id appear in the project — instead of only dismissing *finished* captures. `TaskRun.taskID` becomes a `private(set) var` with a `rekey(to:)` mutator; the pure reconciliation core is widened to return both a `toDismiss` set and a `toRekey` map (`synthetic key -> real id`), with `taskIDsToDismiss` kept as a thin delegate so existing behavior/tests are unchanged; `reconcileFinishedCaptures` applies re-keys (moving the `runs` map entry) before dismisses, atomically. A `markRunningForTesting()` DEBUG seam lets tests construct a *running* capture without spawning `node`. The re-key only fires when exactly one capture is running for the project AND exactly one unclaimed new id exists, so concurrent captures are safely punted. No view/PlansApp edits — `ProjectCard.rowActions` and `runningCaptures` already key on the real id / synthetic prefix, so they react to the re-key for free.

**Files of note:**
- `Sources/Plans/TaskRunner.swift` — `taskID` `let`→`private(set) var` + `rekey(to:)`; `markRunningForTesting()` DEBUG seam; new `CaptureReconciliation` struct + `reconcile(runs:projects:)`; `taskIDsToDismiss` delegates; rewrite `reconcileFinishedCaptures` to apply re-keys then dismisses.
- `Tests/PlansTests/TaskRunnerTests.swift` — new re-key test cases (running-capture re-key, in-map re-key via instance method, no-new-id no-op, concurrent skip, quit-guard intact, identity-only change) plus regression coverage of the existing finished-path tests against `reconcile`.
- `Sources/Plans/ProjectCard.swift` — read-only: `rowActions` (spinner on `runner.isRunning(taskID:)`) and `runningCaptures` (synthetic-prefix filter) already react to the re-key; verify, do not edit.
- `Sources/Plans/PlansApp.swift` — read-only: `onDidReload` already drives `reconcileFinishedCaptures` every reload; verify wiring, do not edit.

## How
- [x] Step 1: Add failing tests in `Tests/PlansTests/TaskRunnerTests.swift` (RED). Add a `markRunningForTesting()`-backed `makeRunningCapture(...)` helper, then: `testRunningCaptureRekeysToNewTaskID` (running capture, baseline `["001"]`, project gains `"002"` → `reconcile().toRekey == [key: "002"]`, `toDismiss` empty); `testReconcileRekeysRunningCaptureInMap` (via `ingestRunForTesting` + `reconcileFinishedCaptures`: `run(for: "002")` is the SAME object, `isRunning(taskID: "002")`, `runningCaptures` empty, `runningRunCount == 1`); `testRunningCaptureNotRekeyedWithoutNewID` (project unchanged → `toRekey`/`toDismiss` empty, `reconcileAttempts` NOT advanced for a running run); `testConcurrentRunningCapturesAreNotRekeyed` (two running captures, one new id → `toRekey` empty); `testRekeyedRunStillCountsForQuitGuard` (after re-key, `hasRunningRuns`/`runningRunCount` unchanged); `testRekeyChangesIdentityOnly` (`rekey(to:)` changes only `taskID`; `mode`/`description`/`baselineTaskIDs`/`projectPath` intact).
- [x] Step 2: Make `TaskRun.taskID` re-keyable in `Sources/Plans/TaskRunner.swift` — change the `let taskID: String` to `private(set) var taskID: String` and add a `func rekey(to newID: String) { taskID = newID }` mutator (identity only; live process, `lines`, `isRunning`/`phase`, `onFinish`, baseline all retained). Add the `#if DEBUG func markRunningForTesting() { isRunning = true; phase = .running }` seam next to the other DEBUG test seams.
- [x] Step 3: Add the richer pure reconciliation core to `TaskRunner` — a `struct CaptureReconciliation: Equatable { var toDismiss: Set<String> = []; var toRekey: [String: String] = [:] }` and a `static func reconcile(runs:projects:)` that, per the plan: indexes ids by project, tracks a `claimed` set seeded with `runs.keys`, re-keys a running capture only when `runningHere == 1 && newIDs.count == 1` (subtracting baseline AND claimed), and preserves the FINISHED-capture dismiss + `reconcileAttempts` bounded-fallback behavior exactly. Re-point `taskIDsToDismiss(runs:projects:)` to `reconcile(runs:projects:).toDismiss` (thin delegate — keep the same signature and doc-comment intent).
- [x] Step 4: Rewrite `reconcileFinishedCaptures(against:)` to call `Self.reconcile(...)`, apply each `toRekey` entry atomically (`guard let run = runs[syntheticKey], runs[realID] == nil`; `run.rekey(to: realID)`; `runs[realID] = run`; `runs[syntheticKey] = nil`) BEFORE iterating `toDismiss` and calling `dismiss(taskID:)`. Keep the method name and the `onDidReload` call site untouched.
- [x] Step 5: Run the targeted suite — `swift test --filter TaskRunnerTests` — and confirm the new re-key tests pass (GREEN) and all existing reconciliation/regression tests (`testFinishedCaptureDismissedWhenNewTaskIDAppears`, `testBackToBackCapturesResolveIndependently`, `testBoundedFallbackDismissesAfterMaxAttempts`, etc.) still pass against the delegating `taskIDsToDismiss`.
- [x] 👁 Step 6: Build and manually verify the hand-off. `./build.sh`, then in a project with a `.plans/` dir submit a new plan with **Execute** (`.executeYolo`) or **Elaborate** (`.captureElaborate`) checked. While the node process is still running, confirm: (a) the creating spinner row disappears the moment the real plan row appears (one row, not two); (b) the real plan row shows the live spinner and its progress popover opens with the live log; (c) attempting to quit while the run is in flight still triggers the quit-confirmation alert (`runningRunCount` intact through the re-key).

## Verification
- `swift test --filter TaskRunnerTests` passes — new re-key cases plus all existing reconciliation/regression tests green.
- Submitting a plan with Execute or Elaborate checked: the "creating" spinner row vanishes the instant the real plan row appears (a single row, never two side-by-side) even though the node process keeps running.
- The real plan row carries the live spinner during the run; clicking it opens the progress popover with the live log streaming.
- Quitting while the re-keyed run is still in flight still shows the quit-confirmation alert reporting the running task.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/TaskRunner.swift` — `taskID` `let`→`private(set) var` + `rekey(to:)`; `markRunningForTesting()` DEBUG seam; `CaptureReconciliation` struct + `reconcile(runs:projects:)`; `taskIDsToDismiss` delegates; rewrite `reconcileFinishedCaptures`.
- [ ] `Tests/PlansTests/TaskRunnerTests.swift` — new re-key test cases + a running-capture fixture helper; existing reconciliation tests kept green.

### Related Files (may need updates)
- `Sources/Plans/ProjectCard.swift` — read-only verification: `rowActions` and `runningCaptures` already react to the re-key; should need no edits.
- `Sources/Plans/PlansApp.swift` — read-only verification: `onDidReload` already drives `reconcileFinishedCaptures`; should need no edits.

### Endpoints/UI Affected
- Project card "creating" capture spinner row — disappears on hand-off for `.captureElaborate`/`.executeYolo` while the run continues.
- Real plan row — gains the live spinner + progress popover for the still-running re-keyed capture.

## Assumptions

### Initial (from elaboration)
- [high] Implement the re-key approach from `plan-51-was-supposed-sparkling-taco.md` rather than the minimal "drop the `!isRunning` guard" alternative. **Why:** The plan documents that the minimal fix would either kill live process tracking or orphan the popover/quit count; the re-key keeps the live process tracked under the real id and was the explicitly chosen design.
- [high] Confine changes to `TaskRunner.swift` + tests with no view/`PlansApp` edits. **Why:** `ProjectCard.rowActions` keys on `runner.isRunning(taskID: row.task.id)` and `runningCaptures` filters on the synthetic prefix — both already react to a re-key, confirmed by reading the current source; the plan's read-only-verification list matches.
- [low] Re-key only when exactly one capture is running for the project AND exactly one unclaimed new id exists; punt true concurrent same-project captures (re-key skipped while >1 running). **Why:** Baseline subtraction can't deterministically attribute one new id to a specific run among concurrent captures; the plan accepts a brief duplicate-row worst case during genuine concurrency as "no worse than today." A rarer scope/UX call worth flagging for review.
- [high] Add a `markRunningForTesting()` DEBUG seam to construct a running capture in tests. **Why:** `isRunning` is `private(set)` and only flips inside `start()` (which spawns `node`); the existing test file already documents this limitation and uses analogous DEBUG seams (`ingestForTesting`, `finishForTesting`, `ingestRunForTesting`).

### Discovered during execution
- [low] Placed the new re-key fixture (`makeRunningCapture`) and 7 tests in a dedicated "Hand-off re-key (task #053)" MARK section, reusing the existing `makeTask`/`makeProject` fixtures from the #051 section. **Why:** keeps fixtures DRY and matches the file's existing section layout.
- [high] Precompute per-project running-capture counts in a pre-pass inside `reconcile(...)` so the "exactly one running capture" attribution guard is independent of `runs.values` iteration order. **Why:** dictionary iteration order is non-deterministic, so an order-dependent guard would be flaky; the pre-pass makes the concurrency punt deterministic.

## Changes
- `Sources/Plans/TaskRunner.swift`:
  - `TaskRun.taskID` changed from `let` to `private(set) var`; added `rekey(to:)` identity-only mutator (live process/lines/isRunning/phase/onFinish/baseline all retained) and a `#if DEBUG markRunningForTesting()` seam.
  - Added `TaskRunner.CaptureReconciliation` struct (`toDismiss: Set<String>`, `toRekey: [String:String]`) and `static func reconcile(runs:projects:)` carrying both halves; `taskIDsToDismiss(runs:projects:)` now delegates to `reconcile(...).toDismiss` (finished-path behavior byte-for-byte preserved, incl. `reconcileAttempts` bounded fallback).
  - `reconcile(...)` re-keys a still-running capture to the real id only when exactly one running capture exists for the project AND exactly one unclaimed new id appeared (running-capture count precomputed in a pre-pass for deterministic attribution; `claimed` set prevents re-attribution). Live runs never advance the bounded-fallback counter.
  - Rewrote `reconcileFinishedCaptures(against:)` to apply re-keys first (move `runs` map entry from synthetic key to real id, atomically) then dismisses. Method name unchanged (PlansApp `onDidReload` wiring untouched).
- `Tests/PlansTests/TaskRunnerTests.swift`: new "Hand-off re-key (task #053)" section with `makeRunningCapture(...)` fixture and 7 tests (re-key to new id, in-map re-key via instance method, no-new-id no-op, concurrent-capture skip, quit-guard intact, identity-only change). All existing #051 reconciliation/regression tests kept green.
- No view or `PlansApp.swift` edits needed (verified: `ProjectCard.rowActions` and `runningCaptures` already react to the re-key).
- Test status: `swift test --filter TaskRunnerTests` → 42 passed, 0 failures.

## Notes
A detailed root-cause analysis and recommended implementation plan already exist at `~/.claude/plans/plan-51-was-supposed-sparkling-taco.md` (produced in plan mode before capture).
