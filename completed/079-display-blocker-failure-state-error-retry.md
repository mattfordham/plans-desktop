# Display Blocker/Failure State With Error Details And Retry

**ID:** 079
**Created:** 2026-09-20T00:00
**Type:** bug
**Status:** completed
**Branch:** fix/079-display-blocker-failure-state-error-retry
**Completed:** 2026-09-21T11:45

## What
When plans git a blocker or fail in some way, we should display something. Maybe and exclaimation mark in list and panel, details about error in panel? , retry button

(Read as: when a plan **hits a blocker or its run fails**, the viewer should show
something distinct — an exclamation-mark indicator in the list and panel, the
error details in the detail panel, and a retry button.)

## Why
Improves reliability triage by surfacing failure state that already exists on
disk but is currently invisible. When an execute run fails (budget/turn cap,
strand-at-in-progress, streamed error, or crash) the task file is left at
`in-progress` and the failure is only shown in the live `RunProgressSheet`. Once
that sheet or the app closes the durable `RunOutcome` written to
`~/.claude/plans-cc/run-outcomes.log` is never read back, so a failed plan is
indistinguishable from a healthy in-progress one. Users cannot see which plans
need attention, why they failed, or re-run them from the app.

## How Summary
Add a **reader** for `run-outcomes.log` (mirroring `RegistryReader`'s injectable
`fileURL`/`FileManager` pattern), thread a "latest failure outcome" overlay onto
the task model the same way `isBlocked` is already threaded, extend
`TaskStatusIndicator` so a failed task renders the existing
`exclamationmark.octagon.fill` / `#cc6666` treatment (with failure taking
precedence like blocked does), add an error-details section + a Retry button to
`PlanDetailView`, mirror the existing `captureRow` failure treatment on
`planRow`, and surface a failed count/glyph on the menu-bar surface. "Retry"
re-runs the plan through the existing `TaskRunner` execute path (same consent
flow), not a silent refresh.

**Files of note:**
- `Sources/Plans/RunOutcomeLog.swift` — durable `RunOutcome`/`Classification`; currently write-only, needs a reader.
- `Sources/Plans/TaskParser.swift` — `Task`/`TaskRow` model; add a `failure` overlay field alongside `isBlocked`.
- `Sources/Plans/PlansStore.swift` — `reload()`/poll; load outcomes and correlate the latest failure per task.
- `Sources/Plans/TaskStatus+Glance.swift` — `TaskStatusIndicator`; add a failure branch with precedence.
- `Sources/Plans/PlanDetailView.swift` — detail header/actions; add error-details section + Retry button (reuse `errorBanner`).
- `Sources/Plans/ProjectCard.swift` — `planRow`; mirror the `captureRow` failure indicator + `RowActionGlyph` retry.
- `Sources/Plans/MenuBarView.swift` / `MenuBarLabel.swift` — Surface A; surface a failed count/glyph.

## Diagnosis

**Most likely:** The durable failure record is written but never read back into the model or UI — `RunOutcomeLog` has an `append` writer and no reader, and neither `Task`/`TaskRow` nor `PlansStore.reload()` carries a failure signal, so a failed run's classification lives only on disk (`Sources/Plans/RunOutcomeLog.swift:117-156` — writer only; `Sources/Plans/PlansStore.swift:586` — `reload()` re-parses only the `.md`; `Sources/Plans/TaskParser.swift:81` — `Task` has no failure field). **Confidence:** high

**Contributing (design fact, not itself a bug):** `TaskStatus` is a fixed six-case data contract (`pending`, `elaborated`, `in-progress`, `review`, `in-review`, `completed`) with no `failed`/`error` case (`Sources/Plans/TaskParser.swift:8-14`; `desktop-app-spec.md` §5.4). A failed run therefore leaves the file at `in-progress`, so failure can only be modelled as an overlay flag (like `isBlocked`), never as a seventh status. **Confidence:** high

**Alternative:** The concern is purely dependency-`blocked` tasks — but that state is already largely surfaced (`Sources/Plans/TaskStatus+Glance.swift:139-153` renders `exclamationmark.octagon.fill` for `isBlocked`; `PlanDetailView.swift:193-195` shows a "Blocked" label), so it does not match "fail in some way / error details / retry." — **Confidence:** low

**To confirm:** Execute a plan that hits the budget cap (or otherwise fails), close the progress sheet, quit and relaunch the app, and inspect that task's row — if it shows an ordinary amber in-progress icon with no failure hint, the failure signal is being written to `run-outcomes.log` but never read (the high-confidence cause above). This is agent-verifiable via a unit test asserting `PlansStore` surfaces a failure overlay when a matching failed `RunOutcome` exists on disk and the task file is still `in-progress`.

## How
- [x] Step 1: Add a failing unit test (per plans-cc TDD) that reproduces the bug — a `RunOutcomeLogReader` fed a temp `run-outcomes.log` containing a `truncated`/`error`/`crashed` outcome for a task, plus a `PlansStore`/parse test asserting a task still at `in-progress` with a matching latest failed outcome surfaces a `failure` overlay. Confirms the Diagnosis before any fix (agent-verifiable, so untagged).
- [x] Step 2: Add a reader to `Sources/Plans/RunOutcomeLog.swift` — an NDJSON line reader over the injectable `fileURL` returning `[RunOutcome]` (tolerating malformed lines), plus a helper to select the **latest** outcome per `(projectPath, taskID)`. Mirror `RegistryReader`'s injectable-`fileURL`/`FileManager` pattern; do not add a new dependency.
- [x] Step 3: Add a `failure` overlay to the task model in `Sources/Plans/TaskParser.swift` — a value carrying `classification`, `errorMessage`, `stopReason`, `timestamp` (nil = healthy), threaded onto `Task`/`TaskRow` alongside `isBlocked`. Do NOT add a `TaskStatus` case — the enum is a fixed data contract.
- [x] Step 4: Correlate outcomes to tasks in `Sources/Plans/PlansStore.swift` — during `reload()`/`reloadAsync()`, read the outcomes log (mtime/signature-gated to avoid re-reading every ~5s poll) and set a task's `failure` overlay when its latest outcome is a failure classification (`truncated`/`stranded`/`error`/`crashed`) AND the file is still `in-progress` (so since-completed tasks don't show stale badges).
- [x] Step 5: Extend `TaskStatusIndicator` in `Sources/Plans/TaskStatus+Glance.swift` with a failure branch that reuses `exclamationmark.octagon.fill` + `#cc6666`, taking precedence over plain status (mirror the existing `isBlocked` precedence rule). Add unit tests for the precedence ordering.
- [x] Step 6: Add an error-details section + a Retry button to `Sources/Plans/PlanDetailView.swift` — surface `failure.classification`/`errorMessage`/`stopReason` in a persistent panel section reusing the `errorBanner` style (PlanDetailView.swift:894-902), and add a "Retry" action that re-runs the plan via the existing `TaskRunner.run(projectPath:taskID:mode:.execute)` path + consent flow (not a silent refresh).
- [x] Step 7: Mirror the failure indicator on the Surface B list in `Sources/Plans/ProjectCard.swift` `planRow` — reuse the `captureRow` red-indicator + `help` tooltip pattern (ProjectCard.swift:612-647) and a `RowActionGlyph` retry glyph (ProjectCard.swift:1105-1154).
- [x] Step 8: Surface a failed count/glyph on Surface A in `Sources/Plans/MenuBarView.swift` and `MenuBarLabel.swift` so failed plans are visible in the menu bar glance (they currently iterate only the 5 active statuses).
- [x] 👁 Step 9: Build and run the app (`./build.sh`), reproduce a failed run, close the sheet and relaunch, and visually confirm the exclamation indicator (list + panel), the error-details section, and a working Retry button across both surfaces. — ✓ User confirmed during /plan-review.

## Verification
- `swift test` passes, including the new reader test, the outcome↔task correlation test, and the `TaskStatusIndicator` precedence tests.
- A task left at `in-progress` with a matching failed `RunOutcome` on disk renders the `exclamationmark.octagon.fill` failure indicator in the Surface B list row and the detail-panel header — and persists across app restart (the original bug).
- The detail panel shows an error-details section with the classification and error message/stop reason for a failed task.
- A Retry button is present for a failed task and re-runs it via the existing execute path (respecting the consent/modal flow).
- A task that has since advanced past `in-progress` (or has a newer successful outcome) shows NO failure indicator (no stale badges).
- Surface A menu bar shows a failed count/glyph when any project has a failed plan.
- No regression to existing status/blocked rendering; `./build.sh` produces a working `Plans.app`.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/RunOutcomeLog.swift` — add an NDJSON reader + latest-per-task selector (currently write-only).
- [ ] `Sources/Plans/TaskParser.swift` — add a `failure` overlay field to `Task`/`TaskRow` alongside `isBlocked`.
- [ ] `Sources/Plans/PlansStore.swift` — read outcomes on reload (mtime-gated) and correlate the latest failure per task.
- [ ] `Sources/Plans/TaskStatus+Glance.swift` — add a failure branch to `TaskStatusIndicator` with precedence.
- [ ] `Sources/Plans/PlanDetailView.swift` — add an error-details section + Retry button.
- [ ] `Sources/Plans/ProjectCard.swift` — add a failure indicator + retry glyph to `planRow`.
- [ ] `Sources/Plans/MenuBarView.swift` — surface a failed count/glyph (Surface A panel).
- [ ] `Sources/Plans/MenuBarLabel.swift` — surface a failed glyph in the menu-bar icon label (Surface A).

### Related Files (may need updates)
- `Sources/Plans/TaskRunner.swift` — `RunOutcome`/`Classification` source of truth and the `run(...)` execute entry the Retry action reuses; likely read-only reference but confirm the retry re-entry.
- `desktop-app-spec.md` — §5.4 status vocabulary; if the failure overlay is documented, note it here (do NOT add a status case).
- `Tests/PlansTests/` — new tests for the reader, correlation, and indicator precedence.

### Endpoints/UI Affected
- Surface B project card `planRow` — new exclamation indicator + retry glyph on failed plans.
- Surface B plan detail panel — new error-details section + Retry button.
- Surface A menu bar glance (panel + icon label) — new failed count/glyph.

## Assumptions

### Initial (from elaboration)
- [high] The subject is **run-failure/errored plans**, not dependency-`blocked` plans. **Why:** the description says "fail in some way," "details about error," and "retry button" — all run-failure language; dependency-blocked state is already surfaced (`TaskStatusIndicator` blocked branch + detail "Blocked" label), so it does not match the report. Research candidate #1 (durable `RunOutcome` written but never read) is high-confidence and matches this reading.
- [high] Failure is modelled as an **overlay flag on the task** (like `isBlocked`), NOT a new `TaskStatus` enum case. **Why:** `TaskStatus` is a fixed six-case data contract mirrored from plans-cc (`TaskParser.swift:8-14`, spec §5.4); a plan file cannot express "failed," and the research explicitly warns against adding an enum case.
- [high] The exclamation indicator reuses the existing `exclamationmark.octagon.fill` / `#cc6666` blocked vocabulary and follows the existing blocked-takes-precedence rule. **Why:** that vocabulary already exists in `TaskStatusIndicator` (lines 118-153) and is exactly the glyph the description asks for; reusing it avoids inventing a parallel treatment.
- [low] "Retry" means **re-run the plan** via the existing `TaskRunner.run(...:mode:.execute)` path and consent/modal flow — not a silent `store.reload()` refresh. **Why:** "retry" beside a failed run reads as "run it again"; the research flagged both interpretations and warned a retry must not re-execute silently. Chosen the re-run reading and kept the existing consent gate. Reversible if the intent was "refresh."
- [low] A failure indicator shows only while the task's **latest** outcome is a failure classification AND the file is still at `in-progress`; it clears when the task advances or a newer successful outcome arrives. **Why:** the research flagged outcome↔task correlation as ambiguous (log keys by `(taskID, projectPath, timestamp)`); this rule avoids stale failure badges on since-completed tasks. A UX/scope decision the description did not specify.
- [low] Reading `run-outcomes.log` is **mtime/signature-gated** rather than re-read on every ~5s poll. **Why:** the existing `ProjectSignature` change-detection exists to avoid per-tick re-reads; a naive full re-read would undo that. An implementation-efficiency call.
- [low] `deep` reasoning-sub-agent drafting was not available (`.plans/config.json` has no `models.reasoning`), so this bug was drafted inline. **Why:** step 9.5 capability gate — no reasoning model configured; noted per the fallback rule.
- [low] Ran non-interactively in skip mode: this is a complex task (5+ files, open research questions) that normally uses the Path B interactive flow, but the run is autonomous, so the approach/design/verification picks above were made on the user's behalf and recorded here for review.

### Discovered during execution
- [low] Named the reader `RunOutcomeLogReader` (a separate struct, not a `read()` method on the existing `RunOutcomeLog` writer), with a `RunOutcomeKey(projectPath, taskID)` `Hashable` key type and two methods: `read() -> [RunOutcome]` and `latestOutcomeByTask() -> [RunOutcomeKey: RunOutcome]`. **Why:** keeps the append-only writer and the reader as separate single-responsibility types (writer stays on the run-finish path; reader on the store-reload path) while mirroring `RegistryReader`'s injectable `fileURL`/`FileManager` shape. Segment 2 (PlansStore correlation) will call `RunOutcomeLogReader(...).latestOutcomeByTask()` and key into it with `RunOutcomeKey`.
- [low] "Latest per key" compares the `timestamp` STRING lexicographically rather than parsing to `Date`. **Why:** the writer stamps ISO-8601 `...Z` timestamps, which sort correctly as strings; avoids a `DateFormatter` and keeps the type Foundation-only with no locale/clock access. On an exact-timestamp tie, the later line in file order wins. Reversible to real `Date` parsing if non-ISO or mixed-offset timestamps ever appear.
- [low] Modelled the failure overlay as a dedicated `TaskFailure` value (`classification`, `errorMessage`, `stopReason`, `timestamp`; `Equatable`) stored as `Task.failure: TaskFailure?` (nil = healthy), rather than reusing the full `RunOutcome`. **Why:** carries only the fields the failure banner/retry UI needs; keeps run bookkeeping (cost, turns, mode) out of the parsed model. `nil` on parse (a plan file cannot express failure); the store correlates it in during reload.
- [low] Added an explicit memberwise `init` to `Task` with `failure: TaskFailure? = nil` defaulted, instead of updating ~48 `Task(...)` call sites. **Why:** mirrors the same defaulted-field pattern `ProjectTasks` already uses for its git fields, so existing parser/tests compile unchanged while the store can supply `failure`. Also updated the load-bearing hand-written `==` to compare `failure` (required — omission would silently drop failure-state changes from reload publishing).
- [high] `TaskRow.failure` is a computed passthrough of `task.failure`. **Why:** `TaskRow` is a thin `Identifiable` wrapper over `Task`; the overlay lives on the model and the row just exposes it, matching the existing `type`/`title` passthroughs.
- [high] Failure-vs-blocked precedence in `TaskStatusIndicator`: **blocked → failed → status → neutral** (blocked wins). **Why:** the existing TUI invariant (mirrored in the desktop indicator) is that the blocked check is the FIRST branch; adding failure just below it preserves that invariant. Since failure REUSES the same symbol/color as blocked (`exclamationmark.octagon.fill` + `#cc6666`, exposed as `failureSymbol`/`failureColor` aliasing the blocked literals), a task that is both blocked and failed renders identically either way — the ordering only pins which branch claims it. The new `isFailed:` init param defaults to `false` so the one existing call site (`BrowserWindow.TaskRow.indicator`) compiles unchanged; segment 3 wires `isFailed: task.failure != nil`.
- [low] Correlation lives in `PlansStore.performReload` as a static pure `applyFailureOverlay(to:latestOutcomes:)` applied AFTER the parse-cache lookup (so a NEW outcome badges its task even on a tick where the `.plans/` file itself did not change) and AFTER the git carry-over rebuild. Overlays ONLY tasks whose effective `status == .inProgress` with a latest FAILING classification (`truncated`/`stranded`/`error`/`crashed`); rebuilds `tasks` + `activeTasks` (backlog tasks are never in-progress). **Why:** matches the "no stale badge" requirement — a task past in-progress or with a `completed` latest outcome gets no overlay. Mirrors how `resolveBlocked` rebuilds the `let`-field `Task`.
- [low] The run-outcomes log read is **mtime-gated** (not signature-gated): a `PlansStore.OutcomeCache(mtime:latestByTask:)` value threaded through `performReload` like the `parseCache`; the log is re-read + `latestOutcomeByTask()` recomputed ONLY when the log file's `contentModificationDate` differs from the cached mtime (both-`nil` missing-file case reuses the empty cached map). Installed back on main under the same #059 generation guard as the parse cache. **Why:** the log is a single append-only file, so a one-`stat` mtime check is the minimal analogue of the `ProjectSignature` directory-listing gate; avoids re-decoding the whole NDJSON log on every idle ~5s poll.
- [low] PlansStore test seam for #079: added an injected `outcomeLogReader: RunOutcomeLogReader = RunOutcomeLogReader()` constructor param (defaulting to the real `~/.claude/plans-cc/run-outcomes.log` reader). **Why:** `RunOutcomeLogReader` already takes an injectable `fileURL`, so tests point the store at a temp-fixture log — consistent with the existing `registryReader`/`taskParser` injection seam; no separate seam type was needed.

#### Segment 3 (UI surfacing: detail section, card indicator/retry, menu bar)
- [high] Retry reuses the EXACT Execute consent gate, not a bespoke path. In `PlanDetailView` the Retry button sets `showExecute = true` (the same state the "Execute" header button raises), presenting the existing `ExecuteModal` sheet which hands `.execute` mode (+ Keep toggle) to `TaskRunner`. On the card, the Retry `RowActionGlyph` sets `executeRequest = ExecuteRequest(...)`, driving the card's existing `.sheet(item: $executeRequest)` → `ExecuteModal`. **Why:** the segment prompt requires mirroring the existing execute action's consent flow exactly (never a silent `store.reload()`); reusing the modal is the least-divergence way to do that and inherits its consent gate verbatim.
- [high] Retry is offered regardless of the task's `status` (not gated by `canWork`, which is `.elaborated`-only). A separate pure predicate `PlanDetailView.canRetry(failure:)` returns `failure != nil`. **Why:** a failed run typically strands the task at `in-progress` (truncated/stranded), which `canWork`/`canElaborate` surface NO action for; re-running `plan-execute` on that in-progress task is exactly the actionable step. Retry hides while a run is already in flight for the task (detail: `!runner.isRunning`; card: the running-spinner branch wins first).
- [high] Failure section layout/copy: a PERSISTENT panel inserted directly below `detailHeader` (before the `## ` sections), reusing the `errorBanner` visual style — white-on-`Color.red.opacity(0.85)` rounded (corner 8) panel. Rows: (1) `failureSymbol` alarm glyph + a semibold one-line summary from `PlanDetailView.failureSummary(_:)`; (2) the run's `errorMessage` (when non-empty); (3) a "Retry" button (`arrow.clockwise`). **Why:** the prompt asked for a persistent section (not the transient sheet banner) reusing the errorBanner treatment; the classification/stop-reason/message are all surfaced.
- [high] Failure copy source of truth: added `RunOutcome.Classification.failureLabel` (pure) — `truncated`→"Run cut short (budget/turn cap)", `stranded`→"Stranded at in-progress", `error`→"Run errored", `crashed`→"Run crashed". `PlanDetailView.failureSummary(_:)` = `failureLabel` + (when present) ` · <stopReason>`. **Why:** one pure, unit-tested string builder shared by the detail section header and the card tooltip so copy can't drift.
- [high] Card tooltip: `ProjectCard.failureTooltip(for:) -> String?` returns `nil` when healthy (caller passes empty `help`), else the `failureSummary` plus a second line with the `errorMessage` when present. Applied via `.help(...)` on the plan-row status glyph, mirroring the `captureRow` failed-help pattern. The glyph itself already turns red via `row.indicator` (now `isFailed: task.failure != nil`). **Why:** matches the requested captureRow red-indicator + help tooltip pattern; classification + error message both surfaced on hover.
- [high] `TaskRow.indicator` now passes `isFailed: task.failure != nil` (the segment-2 handoff item). This lights the shared `failureSymbol`/`failureColor` alarm indicator on BOTH the card `planRow` and the `PlanDetailView` header (both read `row.indicator`), so no separate header wiring was needed. **Why:** the indicator is the single call site the whole app resolves through; wiring it once covers header + card.
- [high] Menu-bar failed treatment (Surface A). Added `PlansStore.failedCount` (total tasks with `failure != nil` across all projects) and a per-project `failedCount` in `MenuBarView.ProjectGlanceRow`. Panel rows: a red alarm badge (`failureSymbol` in `failureColor` + count) appended AFTER the per-status count badges, with a "N failed run(s)" tooltip. Icon label (`MenuBarLabel`): threads `store.failedCount` into `MenuBarLabelContent`, rendering a trailing `⊘N` badge (shared `blockedGlyph` in `failureColor`, count in the adaptive label color) after the in-motion status badges; the empty-state bare-icon check now also requires `failedCount == 0` so a failure shows even with nothing in motion. **Why:** kept minimal and consistent with the existing per-status glyph/count rendering; the icon-label uses the text `blockedGlyph` (`⊘`) rather than an SF Symbol because that view renders text glyphs (`glanceGlyph`), while the panel/cards use the SF Symbol (`failureSymbol`).
- [low] No unit tests were added for the pure view WIRING itself (the `failureSection` layout, the Retry button's `showExecute`/`executeRequest` assignment, the menu-bar badge views) — these are SwiftUI view bodies with no extractable pure logic beyond the helpers already tested. Pure helpers added and unit-tested: `Classification.failureLabel`, `PlanDetailView.failureSummary`/`canRetry`, `ProjectCard.failureTooltip`, `PlansStore.failedCount`. **Why:** per the segment's "targeted tests for NEW pure helpers; do not snapshot-test SwiftUI views" instruction.

## Changes
Executed in worktree on branch `fix/079-display-blocker-failure-state-error-retry` (commit `f6d9250`). 14 files changed, +959/-34. `swift build` clean; 191 targeted tests pass (0 failures) across RunOutcomeLog, TaskParser, PlansStore, TaskStatusGlance, PlanDetailView, ProjectCard.

- **`Sources/Plans/RunOutcomeLog.swift`** — added `RunOutcomeLogReader(fileURL:fileManager:)` (tolerant NDJSON `read() -> [RunOutcome]`, skips malformed/blank lines, empty on missing file) + `latestOutcomeByTask() -> [RunOutcomeKey: RunOutcome]` selecting the newest outcome per `RunOutcomeKey(projectPath:taskID:)` (Hashable, lexicographic ISO-8601 timestamp). Added pure `RunOutcome.Classification.failureLabel` as the single source of truth for failure copy. Existing append-only writer untouched.
- **`Sources/Plans/TaskParser.swift`** — added `TaskFailure` (Equatable: `classification`, `errorMessage`, `stopReason`, `timestamp`) and `Task.failure: TaskFailure?` (nil = healthy), threaded through an explicit defaulted `Task` init, `resolveBlocked`, and the hand-written `==`. No `TaskStatus` case added (fixed contract).
- **`Sources/Plans/BrowserWindow.swift`** — `TaskRow.failure` passthrough; wired `isFailed: task.failure != nil` at the `TaskRow.indicator` call site (lights the shared failure indicator on both card and detail header).
- **`Sources/Plans/PlansStore.swift`** — mtime-gated outcomes-log read (`OutcomeCache`) threaded through `performReload` under the #059 generation guard; static pure `applyFailureOverlay(to:latestOutcomes:)` badges only in-progress tasks whose latest outcome is a failing classification (no stale badges). Injectable `outcomeLogReader` test seam. Added `PlansStore.failedCount`.
- **`Sources/Plans/TaskStatus+Glance.swift`** — `TaskStatusIndicator` failure branch reusing `exclamationmark.octagon.fill` + `#cc6666` via `failureSymbol`/`failureColor`; new `isFailed:` init param (default false). Precedence: blocked → failed → status → neutral.
- **`Sources/Plans/PlanDetailView.swift`** — persistent `failureSection` below the header (errorBanner style) showing classification/stop-reason/error message; Retry button reusing the existing Execute consent gate (`showExecute = true` → `ExecuteModal`). Pure helpers `canRetry(failure:)`, `failureSummary(_:)`.
- **`Sources/Plans/ProjectCard.swift`** — `planRow` failure tooltip via `failureTooltip(for:)` (captureRow help pattern) + a Retry `RowActionGlyph` (`arrow.clockwise`) driving the existing `executeRequest` → `ExecuteModal` path.
- **`Sources/Plans/MenuBarView.swift` / `MenuBarLabel.swift`** — Surface A failed count/glyph: panel red alarm badge (`failureSymbol`) per project; icon label trailing `⊘N` badge (empty-state check now also requires `failedCount == 0`).
- **Tests** — new targeted tests in `RunOutcomeLogTests`, `TaskParserTests` (reader + overlay), `PlansStoreTests` (failure correlation, no-stale-badge, `failedCount`), `TaskStatusGlanceTests` (precedence), `PlanDetailViewTests` (`canRetry`/`failureSummary`/`failureLabel`), `ProjectCardTests` (`failureTooltip`).

Step 9 (👁 visual confirmation of the failure indicator/error section/Retry across both surfaces + failed-run repro across relaunch) is deferred to `/plan-review` per worktree-mode execution.

## Notes
- Root insight from research: `RunOutcomeLog` is currently **write-only** — the durable failure record exists on disk (`~/.claude/plans-cc/run-outcomes.log`) but no code reads it, which is why a failed plan shows nothing distinct after the progress sheet closes.
- No `**Build:**` route added: this is not a design-system component build and there is no `design-system/` directory in this project.
