# Typing Lag/Freeze In Input Fields Recurs Despite Prior Fix

**ID:** 059
**Created:** 2026-07-27T00:00
**Type:** bug
**Status:** completed
**Completed:** 2026-07-30T13:04
**Branch:** fix/059-typing-lag-freeze-in-input-fields-recurs

## What
When typing in the input fields, I experience a lag/freeze when typing periodically. This was a previous issue/plan that was supposedly fixed.... it is not.

## Why
Improves reliability and perceived quality by eliminating the *remaining* cause of
intermittent input lag that two prior fixes (#036, #052) did not address. Those
fixes are both intact in the current source — #036 snapshots the project list so
the New Plan body no longer re-renders on every poll, and #052 debounces
per-keystroke draft persistence — yet the freeze recurs *periodically*. The
untouched culprit is `PlansStore.reload()`: it re-reads the registry and runs
`TaskParser.parseProject` for **every** registered project (directory listings +
full `String(contentsOf:)` reads + markdown parse of every pending *and*
completed task file) **synchronously on the main thread**, on both the initial
load and every ~5s poll tick. Only the git second pass is offloaded; the parse
pass is not. That main-thread stall scales with project count and `.plans/` file
sizes, and while it runs the main run loop is blocked — so ANY focused text
control (the New Plan editor and the Refine-Plan editor both use the same
`PlanTextEditor` NSTextView) hitches on the poll boundary. Both #036 and #052
explicitly *deferred* moving this parse off-main as "an optional deeper fix";
this task does it. Mirroring the existing git-pass GCD offload keeps the change
low-risk and consistent with the store's deliberate main-thread-only design.

## How Summary
Move `PlansStore.reload()`'s registry-read + `parseProject` pass off the main
thread for the *timer-driven poll only*, mirroring the existing git second-pass
GCD offload (global `.userInitiated` queue → hop back to main to assign
`projects`, carry over prior git info, kick the async git pass, then fire
`onDidReload?()`). The initial launch load and the `linkProject` reload stay
**synchronous** so `startPolling()`'s "populated before this returns" contract
(relied on by `PlansApp` and the reload tests) is preserved. Extract the parse
loop into a pure `performReload() -> [ProjectTasks]` helper called by both the
sync and async paths, and guard against a slow background poll clobbering a newer
synchronous load with a monotonic generation counter.

**Files of note:**
- `Sources/Plans/PlansStore.swift` — `reload()`, `startPolling()`, `linkProject()`; add `performReload()`, an async poll path, and a generation guard.
- `Sources/Plans/TaskParser.swift` — `parseProject` is the per-project cost being moved off-main; unchanged, but confirms the work is a pure value-returning read.
- `Tests/PlansTests/PlansStoreTests.swift` — reload tests assert `store.projects` synchronously after `reload()`; add coverage for the sync contract + generation guard.

## How
- [x] Step 1: Extract the parse pass into a pure helper. In `Sources/Plans/PlansStore.swift`, pull the `registryReader.readProjects().map { taskParser.parseProject(...) + git carry-over }` block (currently `reload()` lines ~408–421) into a private `performReload(priorGitInfo:) -> [ProjectTasks]` that takes the prior-git snapshot and RETURNS the built array without mutating `projects`. It must have no side effects so it is safe to call on any thread.
- [x] Step 2: Keep an explicitly synchronous reload path. Refactor `reload()` so it builds `priorGitInfo`, calls `performReload(...)` on the calling (main) thread, assigns `projects`, then runs the existing async git second pass and `onDidReload?()` — i.e. `reload()` stays synchronous and behavior-identical. This preserves `startPolling()`'s "projects populated before this returns" contract (lines ~499–503) and the `linkProject` immediate-appear UX. Have `startPolling()`'s initial load and `linkProject()` continue to call this synchronous `reload()`.
- [x] Step 3: Add an async poll path that runs the parse OFF the main thread. Add `private func reloadAsync()` that snapshots `priorGitInfo` on the main thread, then dispatches `performReload(...)` to `DispatchQueue.global(qos: .userInitiated)`, and hops back via `DispatchQueue.main.async` to: assign `projects`, run the async git second pass, and fire `onDidReload?()` (preserving the #051 reconciliation ordering — it must fire AFTER the main-thread `projects` assignment). Mirror the existing git-pass offload idiom verbatim: `nonisolated(unsafe) let unsafeSelf = self` with value-type captures only, and reuse the documented GCD-over-structured-concurrency rationale (lines ~430–442).
- [x] Step 4: Point the repeating timer at the async path. In `startPolling(interval:)`, change the `Timer.scheduledTimer` closure to call `reloadAsync()` instead of `reload()`, so only the 5s poll goes off-main while the initial `reload()` (line ~506) stays synchronous. Do NOT change the interval.
- [x] Step 5: Guard against out-of-order results. Add a monotonic `private var reloadGeneration: Int` bumped at the start of each reload; capture it into the background closure and, on the main-thread hop, drop the result if a newer synchronous or async reload has since started (`captured != reloadGeneration`). This prevents a slow poll's stale parse from clobbering a newer `linkProject`/initial load (the transient-state risk flagged in #036 Notes). Preserve the git carry-over so cards don't flash their branch/dirty row to `nil`.
- [x] Step 6: Write failing-first tests in `Tests/PlansTests/PlansStoreTests.swift`. (a) Assert `reload()` / the initial `startPolling()` load still populates `store.projects` synchronously before returning (guards the launch contract — extends the existing `testStartPollingPerformsInitialLoadSynchronously`). (b) Assert `performReload(priorGitInfo:)` returns the same `[ProjectTasks]` (paths, counts, ordering, carried-over git) whether invoked directly or off a background queue — proving the offload is behavior-preserving. (c) Assert the generation guard: an older-generation result does not overwrite `projects` after a newer reload. Use the existing injected-`UserDefaults`/temp-dir fixture pattern from `setUpWithError`.
- [x] Step 7: Run `swift test` and confirm the new tests pass with no regressions to the existing reload / draft / snapshot suites (note: some pre-existing `PlansStoreTests` reload cases fail on `main` due to a macOS temp-dir path-capitalization quirk — "Alpha" vs "alpha" — unrelated to this change; verify they are unchanged, not newly broken).
- [ ] 👁 Step 8: Confirm the fix by running the app — `./build.sh`, open the New Plan sheet (⌘N) and the Refine-Plan sheet, and type continuously through several 5s poll cycles (ideally with several projects registered / large `.plans/` dirs to amplify the parse cost). Confirm the periodic hitch on the poll boundary is gone. If a hang is still perceptible, capture a Time Profiler trace correlating the stall with the 5s tick before pursuing incremental/mtime-gated parsing. (requires running the GUI app — the parse-thread stall is only observable at runtime)

## Verification
- The parse pass no longer runs on the main thread on the 5s poll: `reloadAsync()` dispatches `performReload(...)` to a background queue and only assigns `projects` back on the main thread. The initial launch load and `linkProject` reload remain synchronous.
- New tests pass (`swift test`): the synchronous-initial-load contract holds; `performReload` is thread-agnostic and behavior-preserving; the generation guard drops stale results.
- No regressions: the #036 snapshot tests (`BrowserWindowTests`) and #052 debounce tests (`NewPlanDraftPersistenceTests`) still pass; the git carry-over (#024) and reconciliation ordering (#051) are preserved (no card flash, `onDidReload` still fires after the main-thread `projects` assignment).
- 👁 Typing continuously in the New Plan and Refine-Plan editors no longer produces a perceptible freeze on the ~5s poll boundary (observed by running `./build.sh`), especially with many/large registered projects.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/PlansStore.swift` — Extract `performReload(priorGitInfo:)`; keep `reload()` synchronous; add `reloadAsync()` (off-main parse + main-thread assign, mirroring the git offload); add a `reloadGeneration` guard; point the poll timer at `reloadAsync()`.
- [ ] `Tests/PlansTests/PlansStoreTests.swift` — Add tests for the synchronous-load contract, the thread-agnostic `performReload`, and the generation guard.

### Related Files (may need updates)
- `Sources/Plans/TaskParser.swift` — `parseProject` is the per-project cost being moved off-main; not modified, but its purity (value-returning, no shared state) is what makes the offload safe — confirm no hidden main-thread/UI assumptions.
- `Sources/Plans/PlansApp.swift` — Calls `store.startPolling()` at launch (line ~40) and relies on the synchronous initial load; verify launch determinism is unchanged.
- `Sources/Plans/NewPlanModal.swift` / `Sources/Plans/ReElaborateModal.swift` — The two `PlanTextEditor` consumers whose typing responsiveness this fixes; no code change expected, used for the Step 8 observation.

### Endpoints/UI Affected
- New Plan capture sheet (`NewPlanModal`) and Refine-Plan sheet (`ReElaborateModal`) — typing responsiveness improves; behavior otherwise unchanged.
- All project cards / menu-bar counts — refreshed a moment later than today on each poll (background parse then main-thread assign) instead of blocking the main thread; git carry-over prevents any visible flash.

## Assumptions

### Initial (from elaboration)
- [high] Root cause of the *recurring* freeze is `PlansStore.reload()`'s synchronous main-thread parse pass (registry read + `TaskParser.parseProject` for every project, on both initial load and every 5s poll), not a New-Plan-form-specific issue. **Why:** Direct read of `PlansStore.swift:408–421` confirms the parse runs on the main thread while only the git pass (443–455) is offloaded; both #036 (snapshot) and #052 (debounce) fixes are verifiably still wired in current source, and both explicitly deferred this parse-offload as "an optional deeper fix." A main-thread parse that scales with project/file count precisely matches "lag/freeze when typing periodically."
- [high] Fix by moving the parse OFF the main thread for the timer-driven poll only, mirroring the existing git second-pass GCD offload, while keeping the initial/`linkProject` load synchronous. **Why:** `startPolling()` (lines 499–515) and the reload tests both depend on `reload()` populating `projects` before returning; the git offload at 443–455 is an established, documented in-repo pattern for exactly this non-`Sendable` main-thread-only store. Research recommended this "option 1" split as lowest-risk over a uniformly-async `reload()` that would touch ~10 tests.
- [low] Add a monotonic generation guard so a slow background poll can't clobber a newer synchronous load. **Why:** Off-main assignment introduces a transient-state ordering risk flagged in #036 Notes; the source description didn't specify concurrency behavior, so guarding is a defensive judgement call. A simpler alternative (rely on natural ordering) was rejected because a `linkProject` during a slow poll could regress the project list.
- [low] Do NOT change the 5s poll interval, and do NOT add snapshot/debounce protection to `ReElaborateModal`. **Why:** Both prior tasks flagged the cadence as synchronized with #006 (watch poll), #024 (git refresh), #051 (reconciliation); lengthening it only papers over the freeze. Once the parse is off-main, no focused field hitches, so `ReElaborateModal` needs no form-specific mitigation. Research explicitly warned against these as over-engineering.
- [low] Structure the parse pass as a pure `performReload(priorGitInfo:) -> [ProjectTasks]` helper shared by the sync and async paths, rather than duplicating the map block. **Why:** Keeps a single authoritative parse-and-carry-over definition and makes the offload directly unit-testable (thread-agnostic purity assertion); mirrors how #036 factored `refreshProjectsSnapshot()` to avoid duplicating sort logic. The exact helper shape is not specified by the source description.
- [low] Deferred incremental / mtime-gated parsing (only re-parse changed files) as out of scope, noting it in Step 8 as a follow-up only if a Time Profiler trace shows the offloaded parse still stalls perceptibly. **Why:** Research judged a straight off-main offload likely sufficient and warned against over-engineering; the deeper optimization is unnecessary unless profiling proves otherwise, and it can't be confirmed without running the GUI app.

### Discovered during execution
- [high] Extracted the #024 async git second pass out of the inline `reload()` block into a shared private `startGitSecondPass()` and had both `reload()` and `reloadAsync()` call it, rather than duplicating the GCD offload verbatim in `reloadAsync()`. **Why:** The plan said "mirror the existing git-pass offload idiom verbatim"; a shared helper preserves the exact same code path for both reload flavors (no drift risk) while avoiding a copy-paste of the whole block. Behavior in `reload()` is unchanged.
- [high] Snapshotted `priorGitInfo` on the main thread inside `reloadAsync()` (reading the observable `projects`) and captured only that value-type dictionary into the background closure; the background closure never reads `self`'s mutable state — `performReload` is called via `unsafeSelf` but only touches the stateless injected readers. **Why:** The plan required the git-pass `nonisolated(unsafe) let unsafeSelf = self` idiom with value-type captures only; taking the snapshot main-side keeps the off-main work pure and Sendability-clean.
- [low] Typed `priorGitInfo` as `[String: (String?, Bool?)]` in `performReload`'s signature to match the existing inline `Dictionary(...)` shape. **Why:** Keeps the carry-over tuple identical to the pre-refactor code; no new named type introduced for a one-off internal snapshot.
- [high] Marked `reloadGeneration` `@ObservationIgnored` and placed it beside `pollTimer`. **Why:** It is internal race bookkeeping, not observable UI state; excluding it from `@Observable` avoids spurious SwiftUI invalidations, matching how `pollTimer`/`pendingDraft*` are treated. It is only read/written on the main thread (both `reload()` and the `reloadAsync()` main-thread hop), with the async path comparing a captured snapshot value.
- [high] The `reloadAsync()` guard drops the ENTIRE stale result — `projects` assignment, `startGitSecondPass()`, and `onDidReload?()` all skipped via a single early `return` before the assignment. **Why:** Plan Step 5 specified dropping the result without assigning `projects`, running the git second pass, or firing `onDidReload?()`; a newer reload already fired its own git pass + reconciliation, so re-running them from a stale poll would be redundant and could reconcile against superseded data.
- [low] Both synchronous `reload()` and `reloadAsync()` bump `reloadGeneration` with `+= 1` at their very start (before any snapshot). A synchronous `reload()` in flight during an async poll thus supersedes it, and vice-versa. **Why:** Matches the plan's "bumped at the START of each reload" and "reload() bumping the counter is what lets it win the race" requirements; the counter is single-threaded (main) so a plain increment is sufficient — no atomics needed.
- [high] For the test hooks (Step 6), extracted `reloadAsync()`'s main-thread-hop tail into a private `applyReloadResult(_:generation:)` that the real closure AND the test-only `applyReloadResultForTesting(_:generation:)` both call, rather than giving the test a copy of the guard. Added three tiny `/// Test-only hook:` members mirroring the `isPolling` precedent: `performReloadForTesting(priorGitInfo:)`, `reloadGenerationForTesting`, `applyReloadResultForTesting(_:generation:)`. Production methods (`performReload`, `applyReloadResult`) and `reloadGeneration` stayed `private`. **Why:** The plan explicitly preferred exercising the REAL guard path with least duplication; the extraction means the stale-drop test asserts the exact code the poll runs. Wrappers document test intent and keep the production API private (only what tests need is exposed `internal`).
- [low] The generation-guard tests drive the guarded tail directly via the test-only applier with hand-built `ProjectTasks` fixtures (a "/stale/ghost" array vs the real reloaded projects) rather than racing a real background dispatch. **Why:** Determinism — a real background race would be timing-dependent and flaky; the applier runs the identical `applyReloadResult` guard, so the contract is still locked in. Added a complementary `testCurrentGenerationReloadResultIsApplied` so both guard branches (drop vs apply) are covered.
- [high] No macOS temp-dir path-capitalization ("Alpha" vs "alpha") pre-existing failures appeared: all 38 `PlansStoreTests` passed on this machine/run. **Why:** Reporting per Step 7's instruction to distinguish pre-existing flakiness from regressions — none observed, so nothing to attribute or "fix".

## Changes
- `Sources/Plans/PlansStore.swift`:
  - Extracted the registry-read + `parseProject` + git carry-over map into a pure, thread-agnostic `performReload(priorGitInfo:) -> [ProjectTasks]` helper (no side effects; safe on any thread).
  - `reload()` refactored to call `performReload(...)` on the main thread and assign `projects`; remains synchronous and behavior-identical (preserves the `startPolling()` / `linkProject` "populated before return" contract).
  - Added `private func reloadAsync()`: snapshots `priorGitInfo` on main, dispatches `performReload` to `DispatchQueue.global(qos: .userInitiated)`, hops back to main to assign `projects`, run the git second pass, and fire `onDidReload?()` after the assignment (#051 ordering).
  - Factored the #024 git second pass into a shared `startGitSecondPass()` used by both reload paths.
  - Pointed the repeating poll `Timer` at `reloadAsync()`; the pre-timer initial `reload()` stays synchronous. Interval unchanged (5s).
  - Added `@ObservationIgnored private var reloadGeneration: Int` bumped at the start of both `reload()` and `reloadAsync()`. `reloadAsync()` captures the bumped value and drops its result (early `return` before assigning `projects`, running the git pass, or firing `onDidReload?()`) when a newer reload has since started — preventing a stale poll from clobbering a newer `linkProject`/initial load. Git carry-over snapshot preserved.
  - Extracted `reloadAsync()`'s main-thread-hop tail into a private `applyReloadResult(_:generation:)` (guard → assign `projects` → git second pass → `onDidReload?()`), shared by the real closure and the test hook so tests exercise the real guard path.
  - Added three internal test-only hooks (matching the `isPolling` precedent): `performReloadForTesting(priorGitInfo:)`, `reloadGenerationForTesting`, `applyReloadResultForTesting(_:generation:)`.
- `Tests/PlansTests/PlansStoreTests.swift`: added 4 tests — `testReloadPopulatesProjectsSynchronouslyBeforeReturning`, `testPerformReloadIsThreadAgnosticAndCarriesGitInfo`, `testStaleAsyncReloadResultIsDroppedByGenerationGuard`, `testCurrentGenerationReloadResultIsApplied`.

**Tests:** `swift test --filter PlansStoreTests` → 38 tests, 0 failures (independently re-run). Regression suites `BrowserWindowTests` (#036) + `NewPlanDraftPersistenceTests` (#052) → 78 tests, 0 failures. No pre-existing path-capitalization failures manifested on this machine.

## Notes
- Prior art (both fixes verified still wired in current source, so NOT regressions to reopen):
  - `.plans/completed/036-typing-in-new-plan-is-sometimes-laggy.md` — snapshotted the project list (`orderedProjectsSnapshot`) so the New Plan body stops re-rendering on every poll. Its Notes already describe the exact deeper fix this task implements (move `reload()`'s parse pass off-main, mirroring the #024 git offload at ~lines 298–330 of that era).
  - `.plans/completed/052-typing-in-new-plan-form-sometimes-lags.md` — debounced per-keystroke draft persistence (`setDraftDebounced`/`flushPendingDraft`, ~300ms); also deferred the parse-offload as an optional follow-up.
- Key code locations (current source): synchronous parse pass `PlansStore.swift:408–421`; git offload template `PlansStore.swift:443–455` (with the `nonisolated(unsafe) let unsafeSelf = self` rationale at 430–442); reconciliation hook `onDidReload?()` at 463; synchronous-load contract in `startPolling()` at 499–515; `applyGitInfo` merge-by-path at 480–497; the per-project cost `TaskParser.parseProject` at `TaskParser.swift:253–305` (reads pending AND completed files).
- Input fields in the app are exactly two `PlanTextEditor` NSTextView instances — `NewPlanModal` and `ReElaborateModal` (Refine Plan, #056). No `TextField`/`.searchable`/search/filter field exists, so "input fields" = these two editors; both are cured by the shared off-main parse.
- Diagnosis aids: correlate keystroke timing against poll ticks via the `NewPlanModal` OSLog category (`subsystem: com.plans.desktop`) in Console.app, and/or Instruments (Time Profiler + Core Animation) to confirm the main-thread hang aligns with the 5s tick.
- Impact scales with registered project count and `.plans/` file sizes, so the effect is most pronounced for users with many/large projects — relevant when reproducing in Step 8.
