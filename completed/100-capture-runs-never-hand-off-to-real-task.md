# Capture Runs Never Hand Off To Real Task ID When Captures Overlap

**ID:** 100
**Created:** 2026-11-07T14:53
**Type:** bug
**Status:** completed
**Completed:** 2026-11-07T16:32
**Branch:** fix/100-capture-runs-never-hand-off-to-real-task

## What
Capture runs never hand off to the real task id when a second capture's plan lands during the run. Two captures submitted close together (e.g. 098 at 14:38, 099 at 14:39): 099's run baseline (`knownTaskIDs` snapshot at submit, `NewPlanModal.swift:419`) lacks 098, so `TaskRunner.reconcile` (`TaskRunner.swift:1293`) sees `newIDs = {098, 099}` forever, the `newIDs.count == 1` re-key guard never fires, and the still-running captureElaborate/executeYolo run keeps its synthetic `capture:<path>:<UUID>` key — the card shows a stuck "Capturing" spinner row beside the real in-progress 099 row until the process exits.

Fix: have the run learn its real task id from the run's own output (the created task file lands on disk, and the capture skill prints a `🟢 CAPTURED · Task #NNN` marker) and re-key to that id directly, instead of inferring it from the baseline diff. Keep the baseline-diff inference only as a fallback when no id is reported.

## Why
Overlapping captures are a normal thing a user does (fire off two ideas a minute apart). Today the UI strands a phantom "Capturing" spinner next to the real plan row for the entire multi-minute run, which reads as a hang and erodes trust in the live-run display. Making each run learn its own real id removes the ambiguity that baseline-diffing can never resolve between concurrent captures.

## How Summary
Give each new-task run (`captureElaborate` / `executeYolo`) an authoritative, per-run id signal that does not depend on sibling captures. The bundled Node runner (`run-task.ts`) snapshots the project's existing task ids at launch, then — as the run streams — detects the single new id that appeared *for this run* and emits a new structured `captured` NDJSON event carrying it. Swift decodes that into a new `RunEvent.captured(taskID:)` case, stores the reported id on the `TaskRun`, and `reconcile` prefers that reported id to re-key the live spinner to the real plan row — bypassing the `newIDs.count == 1` / single-running-capture guard entirely, which only ever governed the now-fallback baseline-diff path. The baseline-diff inference stays exactly as-is as the fallback for when no id is reported (older launcher, stream decode skew).

**Files of note:**
- `Sources/Plans/TaskRunner.swift` — `RunEvent` contract (add `.captured` case + Codable), `TaskRun` (store `reportedTaskID`), `handle(_:)` fan-out, `reconcile` (prefer reported id), test seams.
- `Tools/work-task/run-task.ts` — snapshot baseline ids at launch for new-task modes, detect the single new id as the run streams, `emit({kind:"captured", taskId})`.
- `Tests/PlansTests/TaskRunnerTests.swift` — revise `testConcurrentRunningCapturesAreNotRekeyed`; add tests for the reported-id re-key path and the baseline-diff fallback.

## Diagnosis

**Most likely:** The live-capture re-key only fires on an unambiguous baseline diff (`runningCapturesByProject[projectPath] == 1` AND `newIDs.count == 1`), a condition two overlapping captures can never satisfy — each run's `newIDs` contains BOTH new ids and two running captures exist — so neither run re-keys and both keep their synthetic `capture:` key until the process exits (`TaskRunner.swift:1293`).
**Evidence:** `reconcile` computes `newIDs = currentIDs.subtracting(run.baselineTaskIDs).subtracting(claimed)` (`TaskRunner.swift:1284-1287`); the re-key guard at `TaskRunner.swift:1293` requires both counts to equal 1; the baseline is a `let baselineTaskIDs` frozen at submit (`TaskRunner.swift:281`, snapshotted `NewPlanModal.swift:419`) and never learns sibling ids.
**Confidence:** high

**Alternative:** The deeper origin is a contract gap — the NDJSON `RunEvent` enum has no case carrying the created id (`TaskRunner.swift:28-40`) and `run-task.ts` explicitly does not emit it, stating the id "is not known at parse time" and deferring to Swift baseline-diff (`run-task.ts:1008-1017`). This is not a competing cause so much as *why* baseline-diff is the only signal today. — **Confidence:** high

**To confirm:** Add a failing XCTest that feeds two overlapping running captures through `reconcile` (via the `ingestForTesting` / `markRunningForTesting` seams) and asserts that, once a `captured` event reports each run's real id, both live runs re-key off their synthetic keys — which fails on today's code because no such event or preference exists.

## How
- [x] Step 1: Add a failing test to `Tests/PlansTests/TaskRunnerTests.swift` that reproduces the bug — two overlapping *running* captures for one project, each reporting its own real id via a new `captured` event — and asserts both re-key to their real ids (fails today; confirms the Diagnosis; agent-verifiable via `swift test`).
- [x] Step 2: Extend the `RunEvent` contract in `Sources/Plans/TaskRunner.swift` with a `case captured(taskID: String)` — add the `taskId` coding key, its decode branch (`kind == "captured"`), and its encode branch — keeping the existing graceful unknown-kind skip so older/newer streams stay compatible.
- [x] Step 3: Store the reported id on the run: add a `reportedTaskID: String?` field to `TaskRun` and set it in `handle(_:)` when a `.captured` event arrives (leave `summary`/`error` untouched — `.captured` is non-terminal, like `.denied`).
- [x] Step 4: Make `reconcile` prefer the reported id for the live-capture hand-off — when a running run has a non-nil `reportedTaskID` that is a genuinely new, unclaimed id for the project, add it to `toRekey` directly (bypassing the `runningCapturesByProject == 1` / `newIDs.count == 1` guard, which now governs only the baseline-diff fallback); keep the existing baseline-diff branch unchanged as the fallback when `reportedTaskID` is nil. Reuse the existing `claimedByProject` machinery so two runs never claim the same id in one pass.
- [x] Step 5: Emit the id from the Node runner in `Tools/work-task/run-task.ts` for the new-task modes (`captureElaborate`, `executeYolo`): snapshot the project's existing `.plans` task ids at launch, and as the run streams detect the single new task id that appeared for this run, then `emit({ kind: "captured", taskId })` exactly once (guard against double-emit). Prefer the on-disk directory diff over scraping assistant prose for the `🟢 CAPTURED · Task #NNN` marker; fall back to the marker only if a directory diff is ambiguous.
- [x] Step 6: Revise `testConcurrentRunningCapturesAreNotRekeyed` to reflect the new contract (overlapping captures that each report a real id DO now re-key), and add a regression test for the baseline-diff fallback path (a run with no `reportedTaskID` still re-keys only under the single-capture/single-new-id guard). Run the targeted `swift test` filter for `TaskRunnerTests` and make all pass.

## Verification
- `swift test --filter TaskRunnerTests` passes, including the new reproduction test and the revised `testConcurrentRunningCapturesAreNotRekeyed`.
- Two overlapping running captures, each reporting its real id, both re-key off their synthetic `capture:` keys (no stranded spinner).
- A run with no reported id still re-keys via the baseline-diff fallback only when exactly one running capture and one new id exist (guard behavior preserved).
- Unknown/newer NDJSON `kind` values still decode-skip gracefully (contract addition degrades safely on version skew).

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/TaskRunner.swift` — add `RunEvent.captured` case + Codable, `TaskRun.reportedTaskID`, `handle(_:)` wiring, reconcile preference for reported id.
- [x] `Tools/work-task/run-task.ts` — snapshot baseline ids at launch, detect the new id as the run streams, emit the `captured` event for new-task modes.
- [x] `Tests/PlansTests/TaskRunnerTests.swift` — new reproduction + fallback tests; revise `testConcurrentRunningCapturesAreNotRekeyed`.

### Related Files (may need updates)
- `Sources/Plans/NewPlanModal.swift` — only if the baseline snapshot needs to pass through anything new; expected unchanged (baseline-diff stays as fallback).

### Endpoints/UI Affected
- The "Capturing" spinner row (`runningCaptures` → `ProjectCard`) — hands off to the real plan row promptly for overlapping captures instead of stranding.

## Assumptions

### Initial (from elaboration)
- [low] The Node runner will detect the run's created id by diffing the project's `.plans` task-id set at launch against the set as the run streams, rather than scraping the `🟢 CAPTURED · Task #NNN` prose marker. **Why:** research warned prose-scraping is brittle across plans-cc versions/localization (`TaskRunner.swift:1202-1206` already rejected title-matching for the same reason); a directory-id diff is machine-readable and gives each run its own signal. Prose marker kept only as a secondary fallback.
- [low] The reported-id re-key should fire on first report mid-run (not at run end), including for `executeYolo` where the process keeps running for minutes after the id appears. **Why:** `rekey(to:)` is explicitly designed for mid-run hand-off (`TaskRunner.swift:480-487`); firing early is the whole point of removing the stranded spinner.
- [high] Keep the baseline-diff inference and its `newIDs.count == 1` guard intact as the fallback rather than removing them. **Why:** research explicitly warned against relaxing that guard as the primary fix — it prevents cross-attribution among concurrent captures; the reporter's framing makes the stream-reported id authoritative and demotes baseline-diff to fallback.

### Discovered during execution
- [high] Reconcile's reported-id branch gates on `currentIDs.contains(reportedID) && newIDs.contains(reportedID)` (present in the project now, not already claimed/in-baseline) rather than blindly trusting `reportedTaskID`. **Why:** the reported id must still be a genuinely new, unclaimed id for the project to avoid re-keying onto a stale/claimed id or an id a sibling run already took; reuses the existing per-pass `claimedByProject` machinery, and distinct reported ids make dict-iteration order irrelevant.
- [low] Rendered the new `.captured` case as `EmptyView()` in `PlanDetailView.lineView` (grouped with `.done`/`.error` as out-of-band / non-log events). **Why:** `.captured` is an internal reconciliation signal carrying the real task id, not user-facing stream text; the Swift switch must be exhaustive so this was a required compile fix, not a scope expansion. Noted as a deviation (PlanDetailView.swift was outside the listed segment impact scope).
- [low] (Segment 2) The runner's `readPlansTaskIDs` parses the leading digit run via `/^(\d+)-/` and keeps ids as RAW STRINGS (not zero-padded/normalized) in the `Set<string>`. **Why:** the Swift `baselineTaskIDs` / reconcile compare ids as plain strings, so byte-for-byte string ids match on both sides and 3- vs 4-digit ids (#090) work without special-casing; `\d+` (not `\d{3}`) covers ids past 999.
- [low] (Segment 2) `maybeEmitCaptured()` is called after each `assistant` message (not inside the `result` handler or after tool_result). **Why:** assistant turns are where the agent has just issued the tool calls that write the new task file, so a re-scan there surfaces the created id earliest for a mid-run hand-off; the one-shot `capturedEmitted` guard makes the call site's exact frequency harmless.
- [low] (Segment 2) On an ambiguous scan (more than one new id), the runner emits NOTHING and does not attempt the `🟢 CAPTURED · Task #NNN` prose-marker fallback (the directory diff is the only source). **Why:** the step allowed the prose marker as optional; keeping to the directory diff alone is simpler and robust, and Swift's baseline-diff fallback already handles the ambiguous case — adding prose-parsing would be redundant surface area.
- [low] (Segment 2) TypeScript validated via `node --experimental-strip-types --check run-task.ts` (exit 0) rather than a full strict `tsc` pass. **Why:** `Tools/work-task/node_modules` is not installed and `--no-install npx tsc` resolves to the system stub; a full `tsc` needs `npm install` (network). The node type-strip check confirms the edit parses as valid TS, and the edit uses only already-imported modules and existing typed patterns, so no new type errors are plausible.

## Changes

### Segment 1 (steps 1-4) — Swift side
- `Sources/Plans/TaskRunner.swift`:
  - `RunEvent`: added `case captured(taskID: String)` with a `taskId` CodingKey and its decode (`kind == "captured"`) / encode branches; the graceful unknown-kind skip in `parseLines` is untouched so streams degrade safely on version skew.
  - `TaskRun`: added `var reportedTaskID: String?` (default nil); set in `handle(_:)` on `.captured` — non-terminal (like `.denied`): does not touch `summary`/`error`, still appended to `lines`.
  - `reconcile`: running runs now prefer `reportedTaskID` — when it is non-nil, present in the project now, and still unclaimed (`currentIDs.contains && newIDs.contains`), the run is re-keyed to it directly, bypassing the `runningCapturesByProject == 1 && newIDs.count == 1` baseline-diff guard. That guard is unchanged and remains the fallback for runs with a nil reported id. Reuses `claimedByProject` so two runs never claim the same id in one pass; reported-id and fallback paths are mutually exclusive per run.
- `Sources/Plans/PlanDetailView.swift`: added a `.captured` arm (`EmptyView()`) to `lineView`'s switch for exhaustiveness (`.captured` is an internal signal, not user-facing log text). Required compile fix; no behavior change. (Deviation — outside the listed segment impact scope.)
- `Tests/PlansTests/TaskRunnerTests.swift`: added `testConcurrentRunningCapturesRekeyViaReportedTaskID` — two overlapping running captures, each reporting its own real id via a `captured` event, both re-key off their synthetic keys. `swift test --filter TaskRunnerTests` → 106 tests, 0 failures.

### Segment 2 (steps 5-6) — Node emitter + tests
- `Tools/work-task/run-task.ts`:
  - Added `readPlansTaskIDs(projectRoot)` beside `readTaskStatus`: scans `.plans/{pending,review,completed}`, parses the leading id from each `*.md` filename via `/^(\d+)-/`, returns a `Set<string>`. Nested try/catch like `readTaskStatus` — a read failure returns ids-so-far, never throws.
  - In `main`, for the NEW-TASK modes only (`captureElaborate`, `executeYolo`): snapshot `capturedBaseline` before the stream loop, plus a one-shot `capturedEmitted` guard and a `maybeEmitCaptured()` closure that re-scans, diffs against the baseline, and `emit({kind:"captured", taskId})` exactly once when exactly one new id appears. Ambiguous (multi-id) scans emit nothing, deferring to Swift's baseline-diff fallback. Called after each `assistant` message. Every other mode is inert. Top-of-file output-contract doc comment updated to document the `captured` line.
- `Tests/PlansTests/TaskRunnerTests.swift`:
  - Renamed `testConcurrentRunningCapturesAreNotRekeyed` → `testConcurrentRunningCapturesWithoutReportedIDAreNotRekeyed`, re-documented as the demoted ambiguous baseline-diff fallback, with explicit `reportedTaskID == nil` preconditions.
  - Added `testSingleRunningCaptureWithoutReportedIDRekeysViaBaselineDiff` — regression proving the fallback still re-keys a single running capture (no reported id) under the single-capture + single-new-id guard.
- Test status: `swift test --filter TaskRunnerTests` → **107 tests, 0 failures**. TypeScript: `node --experimental-strip-types --check run-task.ts` → exit 0 (parses/type-strips cleanly; full strict `tsc` not run — `Tools/work-task/node_modules` not installed, no network).

## Notes
_Additional context_
