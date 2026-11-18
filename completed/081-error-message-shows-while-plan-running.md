# Error Message Shows While Plan Appears To Be Running Happily

**ID:** 081
**Created:** 2026-09-22T00:00
**Type:** bug
**Status:** completed
**Completed:** 2026-09-22T12:00
**Branch:** fix/081-error-message-shows-while-plan-running

## What
This message shows up despite the plan appearing to be running happily/currently. Related to plan 80?

![pasted image](file://~/Library/Application Support/Plans/attachments/10D3215F-B5E4-419F-91D4-D9D999125D14.png)

The screenshot is the **in-app live execution modal** (`RunProgressSheet`, titled "Executing task #023" with a spinning progress indicator, a **Stop** button, live streaming tool-call log lines, and a climbing `$3.34 · 36 turns` counter). At the top of that modal a **red failure banner** reads:

> "Run ended but the task never reached review — it was left stranded at in-progress. Re-run /plan-execute to finish it."

…even though the run is **still actively and healthily executing** (spinner spinning, Stop button present rather than Close-only, tool calls still streaming, cost/turns still climbing). So the "Run ended … stranded at in-progress" banner is a **false positive shown mid-run**.

**Relationship to #080:** Sibling, not duplicate. #080 is the red **list-row glyph** (`exclamationmark.octagon.fill`) in the browser/menu-bar list, caused by a *stale prior-run outcome* re-correlated from `run-outcomes.log`. #081 is the **banner text inside the live execution modal**, caused by the banner's gate ignoring run liveness. Different surface, different code path, different root cause — but both are "a healthy run looks failed." This one does **not** read `RunOutcomeLog`; it reads the live `TaskRun.error`.

## Why
The live execution modal exists to give confidence that a run is progressing. Painting a red "Run ended … stranded at in-progress. Re-run to finish it." banner while the run is demonstrably still going (spinner up, turns climbing) directly contradicts what the user sees and tells them to re-run a task that is already running — eroding trust in the failure banner exactly the way #080 erodes trust in the alarm glyph. Fixing it restores the invariant that a "run ended with a failure" banner means the run has actually ended.

## How Summary
The red banner is gated **only** on `run?.error != nil` (`Sources/Plans/PlanDetailView.swift:822`), with no liveness check — unlike the sheet's own spinner and footer, which both gate on `run?.isRunning == true` (L878, L984). Meanwhile `TaskRun.handle(_:)` latches `error` from a `.done` event's failing stop reason (`stranded_at_in_progress` / cap truncation) at `TaskRunner.swift:587-589`, but a `.done` event does **not** clear `isRunning`; only `finish()` does (L651). So the instant a failing `done` line is ingested the banner arms, while `isRunning` stays `true` until the child process actually terminates — a window that is sustained (not a one-frame flash) whenever the SDK stream yields further messages after that `done`. The fix: gate the `done`-derived failure banner on the run having actually ended (`run?.isRunning == false`), mirroring the footer, while still letting a genuine mid-run `.error(message)` event surface immediately (a real crash *should* show while `isRunning`). No new state is introduced — `isRunning` + `error` already express "ended-with-failure."

**Files of note:**
- `Sources/Plans/PlanDetailView.swift` — `RunProgressSheet.body` banner block (L822-824) is the render site and the fix locus; `errorBanner` (L971), `summaryRow` (L965), and the `isRunning`-gated spinner (L878) / footer (L984) are the consistency references.
- `Sources/Plans/TaskRunner.swift` — `TaskRun.handle(_:)` `.done` branch (L587-589) latches `error`; `truncationError(for:)` (L560-570) owns the exact banner copy; `isRunning` is set in `start()` (L385) / `markRunningForTesting()` (L620) and cleared only in `finish()` (L651). `feedForTesting` NDJSON seam + `markRunningForTesting()` make the fix unit-testable without a `Process`.
- `Tests/PlansTests/PlanDetailViewTests.swift` — where a view-level banner-visibility test belongs.
- `Tests/PlansTests/TaskRunnerTests.swift` — where the `error`-set-while-`isRunning` ordering is asserted.

## Diagnosis

**Most likely:** The failure banner is shown whenever `run?.error != nil` with **no** liveness guard (`Sources/Plans/PlanDetailView.swift:822`), but `TaskRun.error` is latched by a `.done` event carrying a failing stop reason (`TaskRunner.swift:587-589`) while `isRunning` remains `true` (a `.done` does not call `finish()`; only process termination does, at L651). Thus the banner arms mid-run and stays armed for as long as the run keeps streaming after the failing `done` line.
**Evidence:** The banner block `if let error = run?.error { errorBanner(error) }` (`PlanDetailView.swift:822-824`) has no `isRunning` condition, whereas the spinner (`L878`) and Stop/Close footer (`L984`) both branch on `run?.isRunning == true`. `handle(_:)` sets `error` from `truncationError(for: stopReason)` on a `.done` event (`TaskRunner.swift:587-589`) and separately records `summary`/`lastStopReason`, but never touches `isRunning`; `isRunning` is only cleared in `finish()` (`L651`), invoked from `stop()` / process-termination — not from a `done` line. The banner copy in the screenshot is produced verbatim by `truncationError` for `stranded_at_in_progress` (`L568-569`). The screenshot itself is the confirming evidence: spinner + Stop button + climbing `$3.34 · 36 turns` counter prove `isRunning == true` at the same instant `error != nil`.
**Confidence:** high

**Alternative:** The launcher (`Tools/work-task/run-task.ts:787`) emits the `done{stranded_at_in_progress}` NDJSON line from *inside* the streaming `for await` loop (after re-reading task status), so if the Agent SDK yields any messages after that `result`, the failing `done` is emitted while the agent is still working — widening the window from a sub-frame blip to a sustained multi-second banner. — **Confidence:** medium. This is a *contributing* factor to how visible the bug is, not an independent root cause; it shares the exact same fix (the UI must not show an ended-with-failure banner while live) and the launcher's classification is itself correct and should not be changed.

**Alternative:** Stale prior-run outcome re-correlated from `run-outcomes.log` (the #080 mechanism). — **Confidence:** low. ~~stale-outcome cause~~ — disproved: `RunProgressSheet` reads the live `run?.error` published by `TaskRun`, **not** `RunOutcomeLog` / latest `RunOutcome` / `applyFailureOverlay` (that path feeds the list glyph #080, not this modal). Ruled out by tracing the banner binding to `TaskRun.error`.

**To confirm:** Watch `TaskRun` state ordering during a stranded execute run (log-stream `subsystem == "com.plans.desktop"`, or the on-screen counters): confirm `error` becomes non-nil while `isRunning` is still `true` — specifically, that the `$X · N turns` counter keeps climbing (new `done`/`text`/`activity` events arriving) *after* the red banner appears. If the counter advances after the banner shows, the failing `done` is demonstrably not the last event and the mid-run false positive is proven. (The screenshot already shows a live spinner + Stop button + `36 turns` alongside the banner, strongly indicating this; the guard test in Step 1 nails it deterministically.)

## How
- [x] Step 1: Add a failing unit test that reproduces the false positive at the state level (confirms the Diagnosis; agent-verifiable via `swift test`, so untagged). In `Tests/PlansTests/TaskRunnerTests.swift`, drive a `TaskRun` through the DEBUG seams: `markRunningForTesting()` then `feedForTesting` a `done` NDJSON line with `stopReason:"stranded_at_in_progress"`, and assert BOTH `run.error != nil` AND `run.isRunning == true` simultaneously — proving `error` latches while the run is still live. Then add a `PlanDetailViewTests.swift` assertion (or a small testable predicate) that the banner is *hidden* under `error != nil && isRunning == true` and *shown* once `isRunning == false`.
- [x] Step 2: Introduce the banner-visibility rule as a single testable predicate rather than an inline `if`, so both the view and the test share it. Add a computed helper (e.g. on `RunProgressSheet` or as a `static func shouldShowFailureBanner(error:isRunning:stopReason:)`) that returns true only when there is an error AND the run has ended — with the deliberate carve-out below. Keep it next to the existing `shouldAutoOpenProgress` static helper for consistency.
- [x] Step 3: Distinguish a `done`-derived *truncation/stranded* failure (must wait for `isRunning == false`) from a genuine mid-run `.error(message)` event (a real crash/launch failure, which SHOULD show immediately even while `isRunning`). Use `run.lastStopReason` / `TaskRun.truncationError(for:)` to tell them apart: suppress the banner while `isRunning` **only** when the error text equals the truncation/stranded message (i.e. it came from a `done` classification); always show a non-`done` `.error` immediately. This prevents the fix from hiding a real crash banner.
- [x] Step 4: Apply the predicate at the render site in `Sources/Plans/PlanDetailView.swift:822-824`, replacing `if let error = run?.error { errorBanner(error) }` with the liveness-aware guard. Leave `summaryRow` (L829-831) rendering as-is (the `$X · N turns` counter is *expected* to climb live) unless Step 5 observation shows a partial-summary problem. Confirm the banner now appears only once the run has ended.
- [ ] 👁 Step 5: Build and run the app (`./build.sh`), execute a task that will strand at in-progress, and confirm the red banner does NOT appear while the spinner is up / Stop is showing / turns are climbing — it appears only after the run ends and the footer flips to Close. Conversely, confirm a genuinely-stranded *finished* run (task #058 behavior) still shows the banner, and that a real mid-run error (e.g. a launch/precondition failure) still surfaces immediately. Visual confirmation in the running app, which the agent cannot observe.

## Verification
- `swift test` passes, including the new reproduction test (Step 1: `error != nil` while `isRunning == true` after a stranded `done`) and the banner-predicate tests (hidden while live, shown once ended), plus all pre-existing `TaskRunnerTests` / `PlanDetailViewTests`.
- In the running app: during a live execute run (spinner up, Stop button present, turns climbing) the red "Run ended … stranded at in-progress" banner is **not** shown; it appears only after the run actually ends (footer shows Close, spinner gone).
- A run that genuinely ended stranded/truncated (task #058 case) **still** shows the banner after ending — the fix suppresses only the *premature* display, never the legitimate one.
- A genuine mid-run `.error(message)` (crash / precondition failure) **still** surfaces its banner immediately even while `isRunning`, per the Step 3 carve-out.
- No change to `summaryRow`, the spinner, the footer buttons, or `run-outcomes.log`; #080's list-glyph path is untouched.

## Impact Scope
_Fewer than 3 files modified (PlanDetailView.swift plus test files) — Impact Scope section omitted per elaboration convention._

## Assumptions

### Initial (from elaboration)
- [high] The reported "message" is the `RunProgressSheet` red **failure banner** inside the live execution modal, not the #080 list-row glyph and not a stale `run-outcomes.log` outcome. **Why:** The screenshot is unambiguously the "Executing task #023" modal (spinner, Stop button, streaming log, `$3.34 · 36 turns` footer); the banner copy matches `TaskRunner.truncationError(for: "stranded_at_in_progress")` verbatim; the banner binds to live `run?.error`, and research confirmed this modal does not read `RunOutcomeLog`/`applyFailureOverlay`.
- [high] Root cause is the banner's missing liveness guard: it shows on `run?.error != nil` with no `isRunning` check, while `error` is latched by a `.done` event that leaves `isRunning == true`. **Why:** Traced `PlanDetailView.swift:822-824` (no `isRunning` condition) vs L878/L984 (both gate on `run?.isRunning == true`); `handle(_:)` sets `error` on `.done` (`TaskRunner.swift:587-589`) but only `finish()` clears `isRunning` (L651). The screenshot's live spinner + climbing counter alongside the banner corroborates `error != nil && isRunning == true`.
- [low] The fix gates the banner on `run?.isRunning == false` (mirroring the footer) rather than introducing a new published "did-finish-failing" flag on `TaskRun`, changing the launcher's stranded detection, or delaying when `handle(_:)` sets `error`. **Why:** `isRunning` + `error` already express "ended-with-failure"; the render-site guard is the smallest correct change and keeps the banner consistent with the Stop/Close footer. The launcher's classification is correct and durably logged, so it must not be altered. Chosen the research's recommended locus; worth review.
- [low] A genuine mid-run `.error(message)` event (real crash/launch failure) must STILL show immediately while `isRunning`, so the liveness guard is scoped to *`done`-derived truncation/stranded* errors only (distinguished via `lastStopReason` / `truncationError`). **Why:** Blanket-gating *all* errors on `isRunning == false` would hide a real crash until the process exits — failing unsafe. This is a UX/scope call the one-line source description did not specify; erring toward never hiding a genuine failure.
- [low] `summaryRow` (the `$X · N turns` line) is left rendering live and is not gated, unlike the failure banner. **Why:** The cost/turns counter is *expected* to climb during a run, so a live summary is informative rather than misleading; only the "Run ended" banner contradicts the visible live state. Deliberate scope boundary; flagged for the Step 5 observation to confirm no partial-summary confusion.
- [low] Impact Scope section omitted because the change touches fewer than 3 source files (`PlanDetailView.swift` plus test files). **Why:** Elaboration convention only generates Impact Scope at 3+ modified files.
- [low] No `**Build:**` route was added. **Why:** This is a native Swift/SwiftUI app with no `design-system/` directory, so the des-build routing trigger does not apply.

### Discovered during execution
- [high] Predicate signature chosen as `RunProgressSheet.shouldShowFailureBanner(error: String?, isRunning: Bool, stopReason: String?)`. **Why:** These are the minimum inputs to express the rule and all are cheaply available at the render site (`run?.error`, `run?.isRunning`, `run?.lastStopReason`); making it a `static func` sibling to `scrollTarget(for:)` keeps it pure/unit-testable without constructing the view, matching the established precedent.
- [high] "done-derived" is detected by string-equality of the error text against `TaskRun.truncationError(for: stopReason)`. **Why:** `truncationError(for:)` is already the single source of truth for cap/stranded banner copy, and `handle`'s `.done` branch sets `error` to exactly that value. So `error == truncationError(for: lastStopReason)` uniquely identifies a done-classification failure; any other error text (a genuine `.error(message)` crash/launch failure) never matches and therefore shows immediately even while running. No change to `TaskRunner.swift` was needed.

## Changes
- **`Sources/Plans/PlanDetailView.swift`** — Added `RunProgressSheet.shouldShowFailureBanner(error:isRunning:stopReason:)`, a pure `static func` sibling to `scrollTarget(for:)`. Rule: no error → hidden; run ended (`isRunning == false`) → always show; still running → suppress *only* a `done`-derived truncation/stranded failure (identified by the error text equalling `TaskRun.truncationError(for: stopReason)`), while any other error (a genuine mid-run crash/launch failure) surfaces immediately. Rewired the banner render site in `body` from the unguarded `if let error = run?.error { errorBanner(error) }` to gate on this predicate, passing `run?.error`, `run?.isRunning == true`, and `run?.lastStopReason`. `summaryRow`, the spinner, the footer, and `errorBanner` are unchanged; the live `$X · N turns` summary still climbs as before.
- **`Tests/PlansTests/TaskRunnerTests.swift`** — Added `testDoneDerivedErrorLatchesWhileStillRunning`: via `markRunningForTesting()` + `ingestForTesting` of a `stranded_at_in_progress` `done` line, asserts `error != nil` AND `isRunning == true` co-exist — the state-level reproduction of the mid-run false positive.
- **`Tests/PlansTests/PlanDetailViewTests.swift`** — Added 5 banner-predicate tests: hidden while a done-derived failure is still running, shown once the run ends, a genuine (non-truncation) mid-run error shown even while running, and the no-error case.
- **Test seam note:** the plan referenced `feedForTesting`; the actual DEBUG seam is `ingestForTesting` — used that. `TaskRunner.swift` was not modified (`truncationError(for:)` was already `nonisolated static`).
- **Targeted tests (green):** `swift test --filter TaskRunnerTests` (71 tests, 0 failures), `swift test --filter PlanDetailViewTests` (27 tests, 0 failures). Full suite intentionally not run.
- **Remaining:** Step 5 is a `👁` observation step (build + run the app, visually confirm the banner is suppressed mid-run yet still shows on a genuinely-ended stranded run and on a real mid-run error). Deferred to review (worktree mode) — verify during `/plan-review 081`.

## Notes
Sibling to #080 (in-progress on branch `fix/080-…`). #080 fixes the stale-outcome **list glyph**; #081 fixes the premature **execution-modal banner**. They share the theme "a healthy run looks failed" but touch disjoint code paths (`applyFailureOverlay`/`RunOutcomeLog` vs `RunProgressSheet`/`TaskRun.error`) — coordinate but do not merge. If #080's branch is active, land #081 independently to avoid a false conflict.

Diagnostic evidence gathered during elaboration:
- Banner render site `Sources/Plans/PlanDetailView.swift:822-824` has no `isRunning` guard; spinner (L878) and footer (L984) do.
- `TaskRun.handle(_:)` `.done` branch sets `error` via `truncationError` (`TaskRunner.swift:587-589`); `isRunning` cleared only in `finish()` (L651).
- Banner copy source: `truncationError(for:)` returns the exact "Run ended but the task never reached review — it was left stranded at in-progress. Re-run /plan-execute to finish it." for `stranded_at_in_progress` (`TaskRunner.swift:568-569`).
