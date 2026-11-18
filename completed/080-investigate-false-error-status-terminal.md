# Investigate False Error/Blocked Status Shown While Executing In The Terminal

**ID:** 080
**Created:** 2026-09-22T11:00
**Type:** bug
**Status:** completed
**Completed:** 2026-09-22T12:00
**Branch:** fix/080-investigate-false-error-status-terminal

## What
I suspect this might be a false error. I'm executing this plan in Claude Code via the terminal, not via the plans app, and this status popped up while I'm doing that now.

![pasted image](file://~/Library/Application%20Support/Plans/attachments/7183C5C6-2A5A-4F7B-89E3-F214BCD7C125.png)

The screenshot shows the Plans browser/menu-bar list, where task **849** ("Rethink The Ideal Mobile Dashboard (Stop Mirrorin…)") is rendered with the red alarm indicator (`exclamationmark.octagon.fill` in `#cc6666`) — the glyph the app uses for a **blocked** or **failed** task. The plan is in fact being actively executed in Claude Code via the terminal, so this red "error"/blocked state looks incorrect (a false positive) rather than a genuine block/failure.

## Why
The #079 run-failure overlay is firing a false positive: a task that is being *actively and healthily* executed in the terminal is painted with the alarm glyph, which erodes trust in the whole status vocabulary — a red "failed" badge that doesn't mean failed trains the user to ignore real failures. Fixing it restores the invariant that the alarm means "the latest run of *this* task failed," not "some earlier run failed and the task happens to still sit at in-progress."

## How Summary
The alarm is the `isFailed` overlay (#079), not `isBlocked`. Its origin is `PlansStore.applyFailureOverlay`, which stamps a `TaskFailure` onto **any** task at `.inProgress` whose latest `RunOutcome` is a failing classification — with **no recency check** tying that outcome to the current run. A terminal execution keeps the task pinned at `in-progress` but never writes the outcome log, so a *stale* failing outcome from a prior app-launched run keeps re-surfacing on every ~5s poll. The fix adds a liveness/recency guard in the overlay: suppress a failing outcome that predates the plan file's own last-modified time (a terminal run continually rewrites the plan file, advancing its mtime past the stale outcome). This requires threading the per-task file mtime — already captured for the change-gate as `ProjectSignature.Entry.modified` but not currently carried onto `Task` — through to the overlay.

**Files of note:**
- `Sources/Plans/PlansStore.swift` — `applyFailureOverlay` (~L802) is the overlay origin and the sole correct place for the recency guard; `refreshedOutcomeCache`/`OutcomeCache` (~L379, L778) feed it the latest outcomes.
- `Sources/Plans/RunOutcomeLog.swift` — `RunOutcome.timestamp` (ISO-8601, L19) is the outcome's age; `latestOutcomeByTask()` (~L230) supplies the per-task latest outcome.
- `Sources/Plans/TaskParser.swift` — `ProjectSignature.Entry.modified` (~L388) already captures each file's mtime during the directory scan; `Task` (~L110) currently has no mtime field and must carry one for the guard.
- `Sources/Plans/BrowserWindow.swift` — `indicator` (~L991) wires `isFailed: task.failure != nil` into `TaskStatusIndicator`; the render site (no change expected, referenced for tracing).
- `Sources/Plans/TaskStatus+Glance.swift` — `TaskStatusIndicator` (~L154) maps `isFailed` → the red `exclamationmark.octagon.fill`; documents the precedence (no change expected).

## Diagnosis

**Most likely:** A *stale* failing `RunOutcome` from a prior app-launched run is re-correlated onto the task on every poll, because the overlay gate is `status == .inProgress` + "latest outcome is failing" with **no** check that the outcome belongs to the current run (`Sources/Plans/PlansStore.swift:810-813`). A terminal execution keeps the task at `in-progress` (the open gate) but writes nothing to the log, so the old failing line stays "latest" and keeps lighting the alarm.
**Evidence:** `applyFailureOverlay` sets `failure` iff `task.status == .inProgress` (`PlansStore.swift:810`) and the latest outcome's classification is in `failingClassifications = {truncated, stranded, error, crashed}` (`PlansStore.swift:812-813`, `855-857`); there is no timestamp/recency comparison. `run-outcomes.log` is append-only, written **only** by the app-side `TaskRunner.writeOutcome()` (`TaskRunner.swift:666-684`) — the terminal executor (`Tools/work-task/run-task.ts`) has no outcome writer. Confirmed against the live log: for task `849` / project `~/Work/client-a`, the **latest** line is `classification:"stranded"`, `"Reached maximum budget ($20)"`, `stopReason:"stranded_at_in_progress"`, `mode:"execute"`, `2026-09-20T03:48:49Z` — a real prior *app* run that stranded, now re-surfacing while the task is re-run in the terminal.
**Confidence:** high

**Alternative:** The reported glyph is the `isBlocked` path rather than `isFailed`. (`TaskParser.swift:613-614`) — **Confidence:** low. ~~isBlocked cause~~ — disproved: `isBlocked` derives purely from unmet `**Blocked by:**` dependency ids and is unrelated to execution; `TaskParser` never derives failure from file content (`Task.failure` is always `nil` from parsing, `TaskParser.swift:702-704`). The alarm on 849 is the store overlay, not a parsed block.

**Alternative:** The overlay is technically "correct" about the last *recorded* run (a genuine prior app failure), and is only "false" from the user's point of view because the run they now see (terminal) is healthy (`PlansStore.swift:810-813`). — **Confidence:** medium. Same code path and same fix as the most-likely cause; distinguished only by intent, not mechanism.

**To confirm:** Inspect `~/.claude/plans-cc/run-outcomes.log` for the latest line where `taskID == "849"` and `projectPath` is the Client A project, and confirm it is a failing classification whose `timestamp` predates the current terminal run — while 849's plan file currently reads `**Status:** in-progress`. (Already run during elaboration: the latest 849 line is `stranded` at `2026-09-20T03:48:49Z`, predating the current run — most-likely cause confirmed.)

## How
- [x] Step 1: Add a failing unit test in `Tests/PlansTests/` that reproduces the false positive — a task at `.inProgress` whose latest `RunOutcome` is failing but whose plan-file mtime is *newer* than the outcome timestamp must NOT receive a `failure` overlay (confirms the Diagnosis; agent-verifiable via `swift test`, so untagged). Add a companion test asserting a failing outcome *newer than* the file mtime still overlays (guards against over-suppression).
- [x] Step 2: Thread the plan file's last-modified time onto `Task` — add a `modified: TimeInterval?` (or `Date?`) field populated from the same `contentModificationDate` already fetched during the directory scan in `Sources/Plans/TaskParser.swift` (see `ProjectSignature.Entry.modified`, ~L388/L474). Keep it optional so parse sites that lack an mtime compile unchanged.
- [x] Step 3: Add the recency/liveness guard in `applyFailureOverlay` (`Sources/Plans/PlansStore.swift`, ~L802): after confirming the latest outcome is a failing classification, suppress the overlay when the outcome's `timestamp` is older than the task's file mtime (parse `RunOutcome.timestamp` ISO-8601 → `Date` once and compare). Only stamp `TaskFailure` when the failing outcome is at least as recent as the last plan-file edit. When the mtime is unavailable (`nil`), fall back to current behavior so we never *hide* a genuine failure.
- [x] Step 4: Add unit tests covering the guard's edge cases: outcome timestamp exactly equal to mtime (treated as fresh → overlay shown), unparseable/`nil` outcome timestamp (fall back to showing overlay), and `nil` file mtime (fall back to current behavior). Ensure existing #079 overlay tests still pass unchanged for the genuine-failure case.
- [ ] 👁 Step 5: Build and run the app (`./build.sh`) with a task pinned at `in-progress` that has a stale failing outcome, then edit/touch its plan file (simulating terminal execution) and confirm the red alarm clears within one ~5s poll; conversely confirm a genuinely-just-failed task still shows the alarm. Visual confirmation in the running app, which the agent cannot observe.

## Verification
- `swift test` passes, including the new reproduction test (Step 1) and the guard edge-case tests (Step 4), and all pre-existing #079 overlay tests.
- In the running app, a task at `in-progress` with a *stale* failing outcome (outcome older than the plan file's mtime) shows **no** alarm glyph; the glyph clears within one poll (~5s) after the plan file is touched.
- A task whose *latest* run genuinely failed (outcome newer than the plan file's mtime) **still** shows the alarm — the fix suppresses only stale correlations, never real failures.
- No regression to `isBlocked` rendering or to the neutral/status glyph precedence in `TaskStatusIndicator`.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/TaskParser.swift` — add an optional `modified` mtime field to `Task` and populate it from the directory-scan `contentModificationDate`.
- [x] `Sources/Plans/PlansStore.swift` — add the recency/liveness guard in `applyFailureOverlay`; ensure the mtime reaches the overlay (via the `Task` field or the reload pipeline).
- [x] `Sources/Plans/RunOutcomeLog.swift` — added the shared ISO-8601 `timestamp → Date` parse helper (`RunOutcome.parseTimestamp` / `timestampDate`) used by the guard.
- [x] `Tests/PlansTests/` — new/updated tests for the stale-outcome suppression and its edge cases (alongside the existing #079 overlay tests).

### Related Files (may need updates)
- `Sources/Plans/RunOutcomeLog.swift` — if a shared ISO-8601 `timestamp → Date` parse helper is added for the comparison, it belongs here next to `RunOutcome`.
- `Sources/Plans/BrowserWindow.swift` / `Sources/Plans/TaskStatus+Glance.swift` — render sites; expected to need **no** change (referenced only for tracing), but verify the `isFailed` wiring still holds.

### Endpoints/UI Affected
- Surface B browser rows and Surface A menu-bar glance — a task actively executed in the terminal no longer shows a false red alarm; genuine failures are unchanged.

## Assumptions

### Initial (from elaboration)
- [high] The reported red glyph is the #079 `isFailed` run-failure overlay, not `isBlocked`. **Why:** Traced the alarm (`exclamationmark.octagon.fill` / `#cc6666`) to `TaskStatusIndicator`'s `isFailed` branch → `task.failure != nil` (`BrowserWindow.swift:991`) → `applyFailureOverlay`; `isBlocked` derives only from unmet `**Blocked by:**` deps and is execution-independent. The live log confirms a stale failing outcome exists for task 849.
- [high] Root cause is stale-outcome correlation in `applyFailureOverlay`, not the parser or the renderer. **Why:** `TaskParser` never derives failure from file content (`Task.failure` is always `nil` from parsing); the overlay gate is `status == .inProgress` + latest-outcome-failing with no recency check; the terminal executor writes nothing to the log. Confirmed by the live `run-outcomes.log` (latest 849 line = `stranded`, `2026-09-20`, predating the current terminal run).
- [low] The fix uses the plan file's mtime vs. the outcome timestamp as the liveness signal (suppress a failing outcome older than the last plan-file edit), rather than `TaskRunner.isRunning` (which only tracks app-launched runs, never terminal ones) or a fixed outcome-age TTL. **Why:** The app is read-only w.r.t. `.plans/` and cannot observe terminal runs directly; a terminal run continually rewrites the plan file, so file mtime is the most reliable already-available proxy for "this task is being actively worked." A fixed TTL would be arbitrary and could still hide a genuine recent failure. Chosen the first reasonable approach from research; worth review.
- [low] The plan file's mtime is threaded onto the `Task` model via a new optional field, populated from the `contentModificationDate` already fetched during the change-gate directory scan. **Why:** `Task` currently carries no mtime (`modified` lives only on `ProjectSignature.Entry`), so the guard needs the value plumbed through; reusing the already-fetched mtime avoids an extra `stat` per file. An alternative (correlating mtime in the reload pipeline without a `Task` field) is possible but less direct.
- [low] When the file mtime or the outcome timestamp is unavailable/unparseable, the guard falls back to *showing* the overlay (current behavior). **Why:** Failing safe means never *hiding* a genuine failure due to missing metadata; a false positive is less harmful than a silently-suppressed real failure. This is a scope/UX call the source description didn't specify.
- [low] No `**Build:**` route was added. **Why:** This is a native Swift/SwiftUI app with no `design-system/` directory, so the des-build routing trigger does not apply.

### Discovered during execution
- [high] Populated `Task.modified` inside `parseTaskFiles` by prefetching `.contentModificationDateKey` on the directory listing (batched enumeration) plus a per-file `resourceValues` read, rather than reusing the `projectSignature` scan. **Why:** `parseProject` and `projectSignature` are two independent passes; the parse pass already lists each subdir's files, so reading the mtime there keeps the value co-located with the `Task` it belongs to and avoids correlating two separately-ordered scans. Same reference-date basis (`timeIntervalSinceReferenceDate`) as `ProjectSignature.Entry.modified`.
- [high] Chose `TimeInterval?` for `Task.modified` (not `Date?`). **Why:** Matches the existing `ProjectSignature.Entry.modified` type exactly, so both mtime sources speak the same units and comparison is a plain numeric `<` against the outcome date's `timeIntervalSinceReferenceDate`.
- [low] Included `modified` in `Task`'s hand-written `Equatable`. **Why:** The `==` gates whether `reload` publishes a fresh `projects`; an mtime advance can flip the overlay from shown→suppressed even when no other field changed, so omitting it would drop that transition from both surfaces. Trade-off: a bare `touch` (content unchanged) also republishes, but a mtime change already forces a re-parse via `ProjectSignature`, so this adds no extra parse cost — only an extra (cheap) publish on ticks where the file genuinely changed.
- [low] Strict `<` comparison (outcome strictly older than mtime → suppress); an exact tie is treated as FRESH and shows the overlay. **Why:** Biases toward surfacing a failure on the boundary rather than hiding it, consistent with the fail-safe stance; covered by `testReloadShowsFailureWhenOutcomeEqualsFileMtime`.
- [low] Added two test-only seams: `PlansStore.applyFailureOverlayForTesting` (static) to exercise the `task.modified == nil` fallback in isolation, and reused the existing `*ForTesting` convention. **Why:** A real filesystem fixture always has an mtime, so the `nil` branch is only reachable by constructing a `Task` directly and calling the otherwise-`private` overlay. Mirrors the existing `performReloadForTesting` seam pattern.
- [high] Updated three pre-existing #079 tests (`testReloadCorrelatesFailureForInProgressTask`, `testFailedCountTotalsFailureOverlaysAcrossProjects`) to explicitly set each failing file's mtime OLDER than its outcome. **Why:** They previously relied on there being NO recency check — files written "now" (2026-09-22) with fixed past outcome timestamps (2026-06-04) are exactly the stale case the guard now suppresses. Setting mtime older makes their genuine-failure intent explicit and keeps them green.

## Changes
- `Sources/Plans/TaskParser.swift`: Added optional `modified: TimeInterval?` stored property to `Task` (with defaulted memberwise init param and Equatable comparison; updated the "fifteen stored properties" doc). Populated it in `parseTaskFiles` by prefetching `.contentModificationDateKey` on the directory listing and reading each file's `contentModificationDate?.timeIntervalSinceReferenceDate`. Threaded `modified` through `parse(...)` (new defaulted param) and `resolveBlocked(...)` so pending/backlog tasks keep the value.
- `Sources/Plans/RunOutcomeLog.swift`: Added `RunOutcome.timestampDate` (computed) and the shared static `RunOutcome.parseTimestamp(_:)` ISO-8601 → `Date` helper (tolerates fractional-seconds and plain internet-date-time forms, mirrors `BrowserWindow.parseLastSeen`).
- `Sources/Plans/PlansStore.swift`: Added the #080 liveness/recency guard inside `applyFailureOverlay`'s `overlay(_:)` — after confirming a failing latest outcome, suppresses the overlay when `task.modified` and `outcome.timestampDate` are both present AND the outcome is strictly OLDER than the file mtime. Falls back to showing the overlay when either is `nil` (fail-safe). The rebuilt `Task` now also carries `modified` forward. Added the `applyFailureOverlayForTesting` static seam.
- `Tests/PlansTests/PlansStoreTests.swift`: Added `setTaskFileMtime` / `date(fromISO:)` helpers. New tests: `testReloadSuppressesStaleFailureWhenFileNewerThanOutcome` (the false-positive reproduction), `testReloadShowsFailureWhenOutcomeNewerThanFile`, `testReloadShowsFailureWhenOutcomeEqualsFileMtime`, `testReloadShowsFailureWhenOutcomeTimestampUnparseable`, `testFailureOverlayShownWhenFileMtimeIsNil`. Updated two pre-existing #079 tests to pin file mtimes older than their outcomes.

## Notes
_Additional context_

Diagnostic evidence gathered during elaboration (discriminating observation, already run):
- Live `~/.claude/plans-cc/run-outcomes.log` latest line for task 849 / `~/Work/client-a`:
  `stranded` · `"Reached maximum budget ($20)"` · `stopReason:"stranded_at_in_progress"` · `mode:"execute"` · `2026-09-20T03:48:49Z`.
  This predates the current terminal run and is the stale failing outcome re-surfacing while task 849 sits at `in-progress`.
