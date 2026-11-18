# Hand Off Creating Spinner To New Plan Row When It Appears

**ID:** 051
**Created:** 2026-06-12T00:00
**Type:** feature
**Status:** completed
**Branch:** feature/051-hand-off-creating-spinner-to-new-plan-row
**Completed:** 2026-06-15T00:00

## What
When creating new plan, can the spinner show when the new plan appears in list? ... or can the "creating" row go away when the new plan appears? It would be the same process... it's more of a hand-off

## Why
Adds polish to the new-plan creation flow by making the "creating" spinner row hand off cleanly to the real plan row. Today the in-flight capture row is rendered only while `TaskRun.isRunning` is true (`ProjectCard.runningCaptures` filters on `isRunning`), so the moment the Node process exits the spinner row disappears — but the freshly written plan only becomes visible once `store.reload()` re-parses `.plans/pending/`. Those two events are not atomic, so the user sees the spinner vanish and then the plan pop in a beat later (or, if the file write lags process exit, a brief gap where neither is shown). Closing that seam removes the flicker and makes creation feel like a continuous hand-off rather than a disappear-then-reappear.

## How
- [x] Step 1: Confirm the seam by reading the current lifecycle: `TaskRun.finish()` sets `isRunning = false` then synchronously fires `onFinish` → `TaskRunner.onAnyRunFinished` → `store.reload()` (`Sources/Plans/TaskRunner.swift:439-446`, `Sources/Plans/PlansApp.swift:30`). Note that `runningCaptures(projectPath:)` filters on `isRunning` (`TaskRunner.swift:572-577`), so the row is dropped *before* the reload renders the new plan.
- [x] Step 2: Add a reconciliation helper to `TaskRunner` — `func reconcileFinishedCaptures(against projects: [ProjectTasks])` — that, for each finished (`!isRunning`) capture/executeYolo run still in `runs`, checks whether a matching real task now exists in `projects` for that run's project, and only then calls `dismiss(taskID:)`. Keep matching conservative: same `projectPath`, and the task's `created` timestamp is newer than any task seen before the run started (anchor on "a new task id appeared in this project since the run began"). Fall back to dismissing on the next reconcile pass if no match is found within a bounded number of reloads, so a row can never get stuck forever.
- [x] Step 3: Change the hand-off ordering so removal is atomic with appearance. In the `onAnyRunFinished` callback (`PlansApp.swift:30`), reload the store FIRST (the synchronous parse pass in `PlansStore.reload()` populates `activeTasks` immediately), THEN call `taskRunner.reconcileFinishedCaptures(against: store.projects)` within the same main-actor turn, so SwiftUI paints one atomic transition (spinner row out, plan row in) instead of two frames.
- [x] Step 4: Stop dropping the capture run at process exit alone. The capture row should remain visible (spinner still spinning) from process exit until reconciliation confirms the plan is present. Decide the minimal change: either keep `runningCaptures` filtering on `isRunning` but delay clearing `isRunning`/keep the row alive via a short post-finish "settling" flag, OR have `ProjectCard` render finished-but-unreconciled capture runs too. Prefer the smallest change that keeps the spinner on screen across the hand-off without leaking rows.
- [x] Step 5: Preserve the existing manual-dismiss path. The capture row's progress popover `onDisappear` already calls `runner.dismiss(taskID:)` + `store.reload()` (`ProjectCard.swift:310-313`); ensure the new reconciliation does not double-dismiss or fight that path (dismiss is idempotent — it no-ops when the run is missing or still running).
- [x] Step 6: Add unit tests in `Tests/PlansTests/` for `reconcileFinishedCaptures` as a pure-ish function: a finished capture run IS dismissed once a matching new task appears in `projects`; it is NOT dismissed while still running; back-to-back captures for one project each resolve to the correct row (no cross-dismiss); and a run with no match is not dismissed prematurely. Follow the existing `TaskRunner`/`@MainActor` test patterns.
- [x] Step 7: 👁 Build and run the app (`./build.sh`), create a new plan from a project card, and visually confirm the spinner row stays put through the hand-off and is replaced by the real plan row with no flicker or gap. Repeat with two captures submitted back-to-back for the same project to confirm each hands off to its own plan.

## Verification
- `swift test` passes, including the new `reconcileFinishedCaptures` tests covering: dismiss-on-appearance, no-dismiss-while-running, back-to-back captures resolving independently, and no premature dismiss when unmatched.
- Manual (👁): creating a new plan shows the spinner row continuously until the real plan row appears; the transition is a single atomic swap with no visible flicker or empty gap, and no orphaned "creating" row lingers after the plan appears.
- No regression to the manual popover-close dismiss path or to concurrent/back-to-back captures for the same project.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/TaskRunner.swift` — add `reconcileFinishedCaptures(against:)`; adjust the finished-capture retention so the row survives until reconciled (settling flag or equivalent); keep `dismiss(taskID:)` idempotent.
- [x] `Sources/Plans/PlansApp.swift` — reorder the `onAnyRunFinished` callback to reload the store, then reconcile finished captures against `store.projects` in the same turn.
- [x] `Sources/Plans/ProjectCard.swift` — keep the capture spinner row visible across the hand-off window (handled in `TaskRunner.runningCaptures` predicate; `ProjectCard.swift` left unchanged — popover-close dismiss path intact).
- [x] `Tests/PlansTests/TaskRunnerTests.swift` — add reconciliation unit tests (extended the existing file).

### Related Files (may need updates)
- `Sources/Plans/PlansStore.swift` — `reload()` is invoked by the reordered callback; verify the synchronous parse pass (line 302) is what reconciliation reads against (no change expected, but confirm timing).
- `Sources/Plans/TaskParser.swift` — `Task.created` / `Task.id` are the anchors used for matching; no change expected, referenced only.

### UI Affected
- Project card (Surface B) in-flight capture rows — the spinner-to-plan hand-off transition.

## Assumptions

### Initial (from elaboration)
- [low] The fix is framed as a hand-off via reload-then-reconcile ordering rather than description→title string matching. **Why:** research flagged description/title matching as race-prone for back-to-back captures and unreliable when plans-cc rewrites the title; anchoring on "a new task id appeared in this project since the run began" plus atomic reload-then-dismiss is more robust and uses existing `dismiss`/`reload` plumbing.
- [low] The capture row should remain visible (spinner running) from process exit until the new plan is confirmed present, instead of immediately transferring the spinner onto the real plan row. **Why:** the source description offers both framings ("spinner show when the new plan appears" vs "creating row go away when the new plan appears") and calls it "the same process… a hand-off"; keeping the existing capture-row spinner until reconciliation is the smaller, lower-risk change that satisfies the no-flicker intent without restructuring per-row spinner identity.
- [high] Reconciliation runs synchronously in the `onAnyRunFinished` main-actor turn, after `store.reload()`'s synchronous parse pass. **Why:** `PlansStore.reload()` populates `activeTasks` synchronously (only git enrichment is async, `PlansStore.swift:302` vs `:339`), so the new plan is readable immediately in the same turn — making an atomic swap achievable without waiting on a later poll.
- [high] A finished capture run that never finds a match must still be dismissable (bounded fallback) so a row can't get stuck. **Why:** robustness; mirrors the existing manual popover-close `dismiss` safety valve (`ProjectCard.swift:310-313`).
- [low] New/extended tests live in `Tests/PlansTests/TaskRunnerTests.swift`. **Why:** matches the project's `*Tests.swift` XCTest convention; exact filename may differ if an existing `TaskRunner` test file is already present.

### Discovered during execution
- [high] Plumbed the reconciliation baseline as stored state on `TaskRun` (`projectPath: String?` + `baselineTaskIDs: Set<String>`) rather than recomputing it later, and pass it into `capture(...)` via a new defaulted `knownTaskIDs: Set<String> = []` parameter. **Why:** `TaskRunner` holds no `store` reference, so the baseline must be snapshotted by the caller at submit time; storing it on the run keeps reconciliation a pure function of (runs, projects). Defaulting the param keeps existing call sites compiling.
- [high] Matched purely on "a task id present now but absent from the run's per-run baseline set" — dropped the `created`-timestamp comparison the elaboration's Step 2 mentioned. **Why:** per-run baseline id-diffing already isolates back-to-back captures (each carries its own baseline) and is simpler/less race-prone than comparing ISO `created` strings; `Task.created` is optional and format-fragile.
- [low] Bounded fallback ceiling = `TaskRun.maxReconcileAttempts = 3`, incremented once per reconcile pass (each subsequent run-finish triggers one pass). **Why:** small enough to clear a stuck row quickly, large enough to ride out a slow filesystem flush; the exact bound is a judgment call flagged for review.
- [high] Test seam = a pure `static func taskIDsToDismiss(runs:projects:) -> Set<String>` (primary surface) plus a `#if DEBUG func ingestRunForTesting(_:)` to insert a pre-built `TaskRun` into the `private(set)` `runs` map. **Why:** the live map is only populable by `capture()`/`run()` (which spawn `node`); the pure helper lets segment-2 tests verify the matching/fallback without a process. NOTE: the pure helper MUTATES `reconcileAttempts` on examined runs (needed for the bounded fallback), so it is not side-effect-free — tests must account for that.
- [low] Wired the real baseline at the call site in `NewPlanModal.swift` (NOT in this segment's listed impact scope) by snapshotting `store.projects.first { $0.projectPath == projectPath }?.tasks.map(\.id)`. **Why:** without a real baseline the hand-off would only ever resolve via the 3-attempt fallback, defeating the atomic swap; the modal already has `store`. Flagged as a deviation for review.
- [high] Step-4 visibility predicate: `runningCaptures(projectPath:)` now returns EVERY capture run still present in `runs` for the project (dropped the `&& $0.isRunning` filter), keeping the prefix/`:`-boundary match and `taskID` sort intact. **Why:** "row visible" == "run still in `runs`"; reconciliation/dismiss is what removes the run, so the spinner-out / plan-row-in swap is atomic. The run already lingers in the map after finishing (per segment 1), so this is the smallest change that holds the spinner across the hand-off window.
- [high] Errored captures stay visible until cleared rather than being special-cased out. **Why:** keeping them in `runningCaptures` is acceptable because the bounded 3-pass reconcile fallback AND the manual popover-dismiss path both clear them, so an errored capture cannot spin forever; special-casing `error != nil` would add complexity for no behavioral gain (the `captureRow` UI shows a plain `ProgressView` either way during the brief hand-off).
- [high] Still-running assertion limitation: a unit test cannot force `TaskRun.isRunning == true` (it flips only inside `start()`, which spawns `node`), so step 6.2 is covered from the other side — a finished run with NO new id is not dismissed on the first pass, and the pure helper's `guard !run.isRunning` is the sole gate, documented in a test comment (mirroring the file's existing limitation notes for `runningRunCount`).
- [high] No `ProjectCard.swift` change was needed for steps 4/5. **Why:** the `TaskRunner.runningCaptures` predicate change alone keeps the row visible, and the existing popover `onDisappear` manual-dismiss path is already idempotent-safe against reconciliation (verified by `testManualDismissAndReconcileAreIdempotent`), so the manual path was left untouched.

## Changes
- `Sources/Plans/TaskRunner.swift`: Added reconciliation. `TaskRun` gained `projectPath: String?`, `baselineTaskIDs: Set<String>`, `reconcileAttempts`, `static maxReconcileAttempts = 3`. `capture(...)` gained defaulted `knownTaskIDs: Set<String> = []`. Added pure `static func taskIDsToDismiss(runs:projects:) -> Set<String>` (anchor: a task id present now but absent from the run's per-run baseline; bounded 3-pass fallback) and `func reconcileFinishedCaptures(against:)` delegating to it + idempotent `dismiss`. Added `#if DEBUG func ingestRunForTesting(_:)`.
- `Sources/Plans/PlansApp.swift`: Reordered `onAnyRunFinished` — `store.reload()` first, then `taskRunner.reconcileFinishedCaptures(against: store.projects)` in the same main-actor turn for an atomic swap.
- `Sources/Plans/NewPlanModal.swift`: At the `capture(...)` call site, snapshot the project's current task ids as the baseline so reconciliation matches on a genuinely-new id (not just the fallback).
- `Sources/Plans/TaskRunner.swift` (step 4): `runningCaptures(projectPath:)` now returns finished-but-not-yet-dismissed capture runs (dropped the `&& $0.isRunning` filter), keeping the spinner row visible across the hand-off window; reconciliation's `dismiss` removes it atomically when the new plan appears. `ProjectCard.swift` unchanged.
- `Tests/PlansTests/TaskRunnerTests.swift`: Added 8 tests — dismiss-on-new-id (pure + instance seam), no-dismiss-without-new-id, back-to-back per-run isolation, bounded fallback after `maxReconcileAttempts` (pure + instance), `runningCaptures` visibility-until-dismiss, and manual-dismiss/reconcile idempotency. `swift test --filter TaskRunnerTests`: 33 tests, 0 failures.

## Notes
Skip-mode elaboration: ran fully autonomously (no interactive prompts); design and scope decisions above were made on the user's behalf and recorded as assumptions for review before execution.
