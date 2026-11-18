# Allow Multiple Back-to-Back Plan Captures

**ID:** 029
**Created:** 2026-06-06T00:00
**Type:** feature
**Status:** completed
**Branch:** feature/029-allow-multiple-back-to-back-plan-captures
**Completed:** 2026-06-06T16:25

## What
Allow multiple plans to be captured back-to-back without waiting for the previous capture to complete. Currently blocked because the "+" new-plan button is replaced by a spinner while a capture is in flight: captures are keyed by a single synthetic per-project key `TaskRunner.captureKey(projectPath:)` (`"capture:" + projectPath`), and `captureControl` swaps the "+" `CaptureGlyph` for that spinner whenever a run exists under that key. With one key per project, only one capture can be tracked at a time and the "+" disappears.

Fix: give each capture submission its own unique run key (the per-project `captureKey` prefix plus a `UUID` suffix), drop the "already running a capture" no-op guard in `TaskRunner.capture`, keep the "+" `CaptureGlyph` always present (delete the `isRunning`/spinner branch in `captureControl`), and render each in-flight capture as a stacked compact mini-row between the header `Divider` and the plan rows (small `ProgressView` + truncated description, tappable to toggle its own progress popover via the existing `progressPopover(for:)`/`RunProgressSheet` machinery, with per-row `onDisappear` → `runner.dismiss` + `store.reload`).

Scope: capture only; per-row task execute spinners stay single-run (a task can legitimately only run once at a time, so that guard is correct).

## Why
Adds value by letting users queue several new plans on one project in quick succession (the common "brain-dump" capture flow) instead of being forced to wait for each capture's Agent-SDK process to finish before the "+" returns. Captures are already independent, fire-and-forget child processes — the only thing serializing them is the single-key UI model, so this removes an artificial bottleneck.

## How
- [x] Step 1: In `Sources/Plans/TaskRunner.swift` `capture(...)`, build a per-run key as `Self.captureKey(projectPath: projectPath) + ":" + UUID().uuidString` and use it as the `TaskRun.taskID` / `runs` key. Remove the `if let existing = runs[key], existing.isRunning { return }` guard so every submission starts a fresh, independently-tracked run. (`UUID()` needs no new import — `Foundation` is already imported and `LoggedEvent.id = UUID()` already uses it.) Keep the existing `captureKey(projectPath:)` helper as the prefix source.
- [x] Step 2: Add an instance method `func runningCaptures(projectPath: String) -> [TaskRun]` to `TaskRunner` that returns the `runs` values whose `taskID` has prefix `captureKey(projectPath:) + ":"` AND are `isRunning`, sorted by `taskID` for a stable render order across polls. (Filtering on the prefix + `:` separator avoids matching a different project whose path is a string-prefix of this one.)
- [x] Step 3: In `Sources/Plans/ProjectCard.swift` `captureControl`, delete the `if runner.isRunning(taskID: captureKey) { spinner-popover } else { ... }` branch and the now-unused `captureKey` computed property; always render the `CaptureGlyph` + capture popover so the "+" stays put and is reusable immediately after a submit.
- [x] Step 4: Add a `captureRows` view to `ProjectCard` and insert it in `body` between `Divider()` and `body(for: rows)`, rendered only when `runner.runningCaptures(project.projectPath)` is non-empty (no empty gap when idle). For each running capture render a compact row: small `ProgressView()` (`.controlSize(.small)`) + the run's `description` text (`.lineLimit(1)`, truncating), tappable (same `contentShape`/`onTapGesture` primitive as the existing row spinner) to toggle `progressPopover(for: run.taskID)`. Attach `.popover` showing `RunProgressSheet(run: run, taskID: run.taskID).frame(width: 480)` with `.onDisappear { runner.dismiss(taskID: run.taskID); store.reload() }`. Keep `progressPopoverTaskID` a single `String?` (one popover open at a time, matching the per-row spinner behavior).
- [ ] 👁 Step 5: `swift build` then `./build.sh`, open the app, and on one project submit 2–3 captures in quick succession — confirm the "+" stays live, each capture shows its own stacked mini-row with its description, the rows run concurrently, and each row's popover/dismiss surfaces its new task on completion without disturbing the others.

## Verification
- `swift test` passes, including new `TaskRunnerTests` cases for the unique-key contract and the `runningCaptures` prefix filtering (process-free — see below).
- Manual (Step 5): submitting multiple captures back-to-back on one card keeps the "+" present, stacks one mini-row per in-flight capture with its description, runs them concurrently, and resolves each independently.
- No regression to per-row task execute spinners (still single-run per task).

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/TaskRunner.swift` — unique per-run capture key; remove capture guard; add `runningCaptures(projectPath:)`.
- [x] `Sources/Plans/ProjectCard.swift` — always-present "+"; new stacked `captureRows`; drop `captureKey` computed property.
- [x] `Tests/PlansTests/TaskRunnerTests.swift` — add unique-key + `runningCaptures` filtering tests.

### Endpoints/UI Affected
- Project card header "+" capture control (no longer swaps to a spinner) and the new stacked in-flight-capture rows below the header divider.

## Assumptions

### Initial (from elaboration)
- [low] Keep `captureKey(projectPath:)` as the prefix and append `":" + UUID()` inline in `capture(...)` (rather than a new `captureKeyPrefix` helper). **Why:** user-selected; minimizes API churn and keeps the existing `captureKey` test meaningful. Trade-off: the prefix-filter in `runningCaptures` is the only place that re-derives the boundary, so it must use the `+ ":"` separator to stay unambiguous.
- [low] `runningCaptures` filters to `isRunning` only (finished-but-undismissed captures drop out of the stack immediately on completion, surfacing via `store.reload`). **Why:** matches the per-row spinner model where the spinner reflects live runs; the progress/summary remains reachable until `onDisappear` dismisses it. The source description didn't specify whether finished-pending-dismissal captures keep a visible row.
- [low] Concurrent-capture and prefix-filter behavior is tested via pure helpers/identity assertions, NOT by calling `capture(...)`. **Why:** the existing `TaskRunnerTests` deliberately never calls `capture()`/`run()` because they spawn a `node` `Process` (see the file's closing comment); tests assert the key-construction contract (`captureKey` prefix + distinct `UUID` suffixes yield distinct keys sharing the prefix) and, where a pure filter seam exists, the `runningCaptures` prefix logic — keeping the suite process-free and non-flaky.
- [high] Single open progress popover per card (`progressPopoverTaskID: String?` unchanged). **Why:** user-selected; mirrors the existing per-row spinner popover exactly, requiring no change to shared popover machinery.

### Discovered during execution
- [low] `captureRow` falls back to "Capturing…" when a run's `description` is `nil`. **Why:** `TaskRun.description` is `String?`; in practice `capture(...)` always passes a non-empty trimmed description (the submit guard rejects empty), so this fallback is defensive-only, but `Text` needs a non-optional value. Plan said render "the run's `description` text" without specifying the nil case.
- [low] Used a `VStack(spacing: 4)` + `ForEach` for `captureRows` and a plain `HStack(spacing: 8)` (spinner + description + trailing `Spacer(minLength: 0)`) for each row, rather than reusing the `Grid`/`GridRow` layout of the plan rows. **Why:** capture rows are a distinct, simpler vocabulary (no id/type/title columns) and live above `body(for:)`; keeping them in their own VStack avoids entangling them with the plan-row Grid's cross-row column sizing. The trailing `Spacer` widens the tap target across the card.
- [high] Kept the existing `testCaptureKeyIsModeIndependentAndPerProject` test (only updated its doc comment from "key" to "prefix") and added the two new pure tests alongside it. **Why:** the helper is still the prefix source and the assertions remain valid; per the plan's test contract the new uniqueness/boundary tests assert key-construction logic directly without calling `capture()`/`run()`.

## Changes
- `Sources/Plans/TaskRunner.swift`: `capture(...)` now keys each submission under `captureKey(projectPath:) + ":" + UUID().uuidString` so every capture is an independently-tracked run; removed the `if let existing = runs[key], existing.isRunning { return }` no-op guard (captures are no longer serialized). Added `func runningCaptures(projectPath:) -> [TaskRun]` returning `isRunning` runs whose `taskID` has prefix `captureKey + ":"`, sorted by `taskID` for stable render order. Doc comments updated.
- `Sources/Plans/ProjectCard.swift`: `captureControl` always renders the `CaptureGlyph` + capture popover (deleted the `isRunning` spinner branch), so the "+" stays live and is reusable immediately after a submit; removed the now-unused `captureKey` computed property and updated the related doc/inline comments. Added a `captureRows` view (a `VStack` of one compact `ProgressView` + truncated description row per running capture) inserted in `body` between `Divider()` and `body(for: rows)`, shown only when `runningCaptures` is non-empty. Each row is tappable to toggle its own `RunProgressSheet` popover (single shared `progressPopoverTaskID`), with `onDisappear { runner.dismiss; store.reload() }`.
- `Tests/PlansTests/TaskRunnerTests.swift`: added `testUniqueCaptureKeysForSameProjectAreDistinctAndSharePrefix` and `testRunningCapturesPrefixBoundaryRejectsStringPrefixProject` (both process-free); updated the existing `testCaptureKeyIsModeIndependentAndPerProject` doc comment.
- Tests: `swift test --filter TaskRunnerTests` → 20 tests, 0 failures. `swift build` succeeds (only pre-existing unrelated `PlansStore` Sendable warnings).
- Step 5 (👁 manual multi-capture verification) deferred to `/plan-review` per worktree mode.

## Notes
- `TaskRunner` and `TaskRun` are both `@MainActor @Observable`; `runs` is `private(set)`, so tests cannot seed it directly — another reason the new tests target pure key/filter logic rather than runtime `runs` state.
- No other surface iterates `runner.runs` or assumes one capture per project (menu bar / store / browser confirmed clear), so the change is contained to the two source files + tests.
- The existing `testCaptureKeyIsModeIndependentAndPerProject` stays valid (the helper is now the prefix source, not the full key); a new test adds the uniqueness-of-suffix contract alongside it.
