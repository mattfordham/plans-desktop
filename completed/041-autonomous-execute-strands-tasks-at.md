# Autonomous Execute Runs Strand Tasks At In-Progress When Budget Cap Fires

**ID:** 041
**Created:** 2026-06-08T11:30
**Type:** bug
**Status:** completed
**Completed:** 2026-06-08T11:30
**Branch:** fix/041-autonomous-execute-strands-tasks-at

## What
Autonomous Execute runs strand tasks at in-progress when the $5 agent budget cap fires before the worktree-finish step.

Two fixes:
1. **Raise the budget cap** — `MAX_BUDGET_USD` in `Tools/work-task/run-task.ts` is currently `5.0`, which is too low for a full capture→elaborate→multi-segment-execute pipeline (auto-capture → auto-elaborate with a research sub-agent → a per-segment plan-executor sub-agent on Opus → commit → set review → remove worktree). Raise it to a more realistic value.
2. **Make truncation visible** — treat a result `stopReason` of `error_max_budget_usd` / `error_max_turns` as a non-success terminal event rather than a clean `done`, so the app surfaces that the run was cut short and the task was left at `in-progress` instead of reaching `review`.

Today `TaskRunner.handleTermination` only synthesizes an error when the process exits nonzero with no `done`/`error` line emitted. A budget-capped run emits a perfectly valid `done` event (the script faithfully forwards `stopReason: "error_max_budget_usd"`), so the app treats it as a successful completion and shows the summary — even though the task is frozen at the `in-progress` that `plan-execute` Step 7f set near the start, never reaching the Step 11e worktree-finish that flips it to `review`.

## Why
Improves reliability of autonomous (yolo) Execute runs. Today a run that exhausts the agent budget mid-pipeline is silently reported as a success, leaving the task stranded at `in-progress` with no signal that it never reached `review`. Raising the cap lets a realistic full pipeline finish, and surfacing truncation means that when a run *does* hit the ceiling, the user is told clearly instead of being misled by a green "done" summary.

## How
- [x] Step 1: Raise the budget cap in `Tools/work-task/run-task.ts` — change `MAX_BUDGET_USD` from `5.0` to `20.0` (line 38). Update the surrounding doc comment if it references the old figure.
- [x] Step 2: (TDD — RED) Add a failing test in `Tests/PlansTests/TaskRunnerTests.swift` asserting that ingesting a `done` event whose `stopReason` is a truncating value (`error_max_budget_usd`, then `error_max_turns`) causes the runner to expose a non-nil `error` (so the existing red banner fires), while a normal `stopReason` (e.g. `end_turn`) leaves `error` nil and only sets `summary`. Drive it through the public ingest path so `handle(_:)` is exercised (feed an NDJSON line via the same route `testParseLines*` / decode helpers use, then assert on the runner's `error`/`summary`).
- [x] Step 3: (TDD — GREEN) In `TaskRunner.handle(_:)` (`Sources/Plans/TaskRunner.swift:363`), stop discarding `stopReason` in the `.done` case. Still set `summary` from cost/turns as today, but when `stopReason` matches a truncation set (`error_max_budget_usd`, `error_max_turns`), also set `error` to a clear message, e.g. `"Run cut short — agent budget/turn cap hit before completion. The task was left at in-progress (it did not reach review). Re-run /plan-execute to resume, or raise the budget."`. Centralize the truncation-reason check in one small helper/`Set` so it's testable and reused. Leave `handleTermination` as-is (its `done`-less-nonzero-exit safety net is still correct).
- [x] Step 4: Confirm the UI needs no change — `PlanDetailView` already renders `errorBanner(run.error)` (line 328) above `summaryRow(run.summary)` (line 334), so setting `error` shows the banner *and* the cost/turns summary together. If the two read awkwardly stacked, adjust copy only (no structural UI change).
- [x] Step 5: Run the targeted Swift test (`swift test --filter TaskRunnerTests`) — confirm the new truncation tests pass and existing `testDecodesDone*` / decode tests stay green.
- [x] Step 6: Rebuild the bundled runner so the app picks up the new cap: recompile `run-task.ts` → `Tools/work-task/dist/run-task.js` and ensure the bundled copy at `Plans.app/Contents/Resources/work-task/run-task.js` is regenerated (via the project's normal build path — `./build.sh`, or the same tsc/copy step that produced today's `dist`). Verify `MAX_BUDGET_USD` reads `20.0` in the bundled `.js`.
- [x] 👁 Step 7: Smoke-test from the app — trigger an autonomous Execute (New Plan + Execute, or the detail-view Execute) and confirm: a run that completes reaches `review` as before, and a run that hits the cap now shows the red truncation banner (not a bare success summary). Observe the actual end state in the Plans UI.

## Verification
- Ingesting a `done` event with `stopReason: error_max_budget_usd` or `error_max_turns` sets `run.error` (red banner shows); a normal `stopReason` does not.
- `swift test --filter TaskRunnerTests` passes, including existing decode tests.
- `MAX_BUDGET_USD` is `20.0` in both `Tools/work-task/run-task.ts` and the bundled `Plans.app/Contents/Resources/work-task/run-task.js`.
- In the app: a capped run surfaces a clear "cut short / left at in-progress" message instead of a clean done summary; an uncapped run still lands in `review`.

## Impact Scope

### Files to Modify
- [x] `Tools/work-task/run-task.ts` — raise `MAX_BUDGET_USD` 5.0 → 20.0
- [x] `Sources/Plans/TaskRunner.swift` — `handle(_:)` maps truncating `stopReason` to `error`
- [x] `Tests/PlansTests/TaskRunnerTests.swift` — new truncation-surfacing tests

### Related Files (may need updates)
- `Sources/Plans/PlanDetailView.swift` — only if banner/summary copy needs adjusting; no structural change expected (already renders `run.error`)
- `Tools/work-task/dist/run-task.js` and `Plans.app/Contents/Resources/work-task/run-task.js` — regenerated bundle output (build artifacts, not hand-edited)

### UI Affected
- Plan detail run panel — red error banner now appears for budget/turn-capped runs (reuses existing `errorBanner`)

## Assumptions

### Initial (from elaboration)
_To be filled during elaboration_

### Discovered during execution
- [high] Did NOT hand-edit `Tools/work-task/dist/run-task.js` or `Plans.app/.../run-task.js` (still read `MAX_BUDGET_USD = 5`). **Why:** both are gitignored build artifacts regenerated from `run-task.ts` by `build.sh` (`npm run build`, tsc) per Impact Scope line 45 and Step 6 — editing the source `.ts` is the source of truth; the bundle is regenerated in the next segment's Step 6.
- [low] Added a `#if DEBUG` test seam `ingestForTesting(_:)` on `TaskRun` that feeds raw NDJSON through the real private `ingest` path. **Why:** the plan asked to "drive it through the public ingest path so `handle(_:)` is exercised," but `ingest`/`handle` are `private` and existing `testParseLines*` helpers only exercise the pure `RunEvent.parseLines`/decode, never a `TaskRun` instance. A DEBUG-only seam exercises the exact `ingest → parseLines → handle` chain on a real `TaskRun` without spawning a `Process`; it is not part of the shipping API.
- [high] Centralized truncation reasons in a `nonisolated static let truncatingStopReasons: Set<String>` plus a pure `nonisolated static func truncationError(for:)`. **Why:** mirrors the existing `static`-helper testability pattern (`RunMode.usesDescription`, `TaskRunner.captureMode`) the plan referenced for "centralize in one small helper/Set so it's testable and reused."
- [high] No change to `PlanDetailView`. **Why:** `RunProgressSheet.body` already renders `errorBanner(run.error)` above the log and `summaryRow(run.summary)` below it (lines 328/334); a truncating `done` sets both, so banner + cost/turns summary read naturally together. No structural or copy change needed.
- [high] Regenerated the bundle via `npm run build` (= `node build.mjs`) in `Tools/work-task`, then refreshed the app copy with `build.sh`'s exact `cp -R Tools/work-task/dist Plans.app/Contents/Resources/work-task` step, instead of full `./build.sh`. **Why:** these are the only two sanctioned commands that touch the JS bundle; full `./build.sh` additionally does a release `swift build` and `open`s the .app, which is heavier than needed to regenerate the runner. Both `dist/run-task.js` and `Plans.app/.../run-task.js` now verified at `MAX_BUDGET_USD = 20`.

## Changes
- **Tools/work-task/run-task.ts** — `MAX_BUDGET_USD` raised `5.0` → `20.0`; doc comment updated.
- **Sources/Plans/TaskRunner.swift** — added `nonisolated static let truncatingStopReasons: Set<String>` (`error_max_budget_usd`, `error_max_turns`) and pure `nonisolated static func truncationError(for:)`; `handle(_:)` `.done` case now also sets `error` (in addition to `summary`) when `stopReason` is truncating. Added `#if DEBUG ingestForTesting(_:)` seam. `handleTermination` unchanged.
- **Tests/PlansTests/TaskRunnerTests.swift** — added `testTruncationErrorMapsCapReasonsOnly` (pure helper) and `testTruncatingDoneEventSurfacesErrorAndSummary` (drives a `done` NDJSON line through a real `TaskRun`). 24 tests pass, 0 failures.
- **Sources/Plans/PlanDetailView.swift** — no change needed; `RunProgressSheet` already stacks `errorBanner(run.error)` above `summaryRow(run.summary)`.
- **Tools/work-task/dist/run-task.js** + **Plans.app/Contents/Resources/work-task/run-task.js** — regenerated via `npm run build` (esbuild) + `build.sh` copy step; both verified to read `MAX_BUDGET_USD = 20` (gitignored build artifacts, not hand-edited).

## Notes
Key code references:
- `Tools/work-task/run-task.ts:38` — `MAX_BUDGET_USD = 5.0`
- `Tools/work-task/run-task.ts:328` — `maxBudgetUsd: MAX_BUDGET_USD` passed to `query()`
- `Tools/work-task/run-task.ts:370-379` — `result` message handling emits `{kind:"done", stopReason}` for both success and `error_max_*` subtypes
- `Sources/Plans/TaskRunner.swift:379-393` — `handleTermination` only errors on nonzero exit with no done/error line
- `Sources/Plans/TaskRunner.swift:363-373` — `handle(_:)` fans `done`/`error` events to `summary`/`error`; does not inspect `stopReason`
- The `review` status is set ONLY in `plan-execute` Step 11e (worktree finish), which runs after ALL segments complete. Any early truncation strands the task at the `in-progress` set in Step 7f.

Remember to rebuild the bundled script (`Tools/work-task/dist/run-task.js` → `Plans.app/Contents/Resources/work-task/run-task.js`) after editing the `.ts` source — the app runs the bundled copy.
