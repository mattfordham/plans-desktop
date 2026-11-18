# Typing In New Plan Form Sometimes Lags

**ID:** 052
**Created:** 2026-06-12T00:00
**Type:** bug
**Status:** completed
**Completed:** 2026-06-14T13:25
**Branch:** fix/052-typing-in-new-plan-form-sometimes-lags

## What
Typing in "New Plan" form sometimes "lags"

## Why
Improves reliability and responsiveness of the New Plan capture form. A prior fix
(#036, completed 2026-06-08) eliminated the ~5s polling hitch by decoupling the
project picker from `store.projects` via a local snapshot. Lag is being reported
again, so a *secondary* cause remains: every keystroke in the description editor
fires `.onChange(of: text) → persistDraft() → store.setDraft(...)`, and the
`captureDrafts` setter synchronously runs `JSONEncoder().encode(captureDrafts)`
and writes the whole dictionary to UserDefaults on the **main thread** on every
character. It also mutates an `@Observable` store property per keystroke, which
can churn observation in other observing views. Both compound as the typed text
grows. Debouncing the draft persistence keeps the editor responsive while
preserving the draft-resilience behavior that #031 introduced.

## How
- [ ] Step 1: Reproduce/confirm the lag against the current build — run `./build.sh`, open the New Plan sheet (⌘N), and type continuously, watching for hitches that are NOT on the ~5s poll boundary (the #036 fix already covers that boundary). 👁 (requires running the app)
- [x] Step 2: Write a failing test in `Tests/PlansTests/` (new `NewPlanDraftPersistenceTests.swift` or extend `PlansStoreTests`) asserting that rapid successive `setDraft` calls do not each force an immediate UserDefaults encode/write — i.e. that persistence is debounced/coalesced. Use an injected `UserDefaults(suiteName:)` per the existing test pattern, and assert the final draft value is still persisted after the debounce interval elapses.
- [x] Step 3: Add a debounced draft-persistence path. Preferred: add a small debounce in `NewPlanModal.persistDraft()` (e.g. a cancellable `Task`/`DispatchWorkItem` with ~300ms delay stored in `@State`) so the synchronous encode+write in `PlansStore.captureDrafts.didSet` runs at most once per pause in typing, instead of once per keystroke. Keep the existing `isSwitchingProject` guard intact.
- [x] Step 4: Ensure correctness of the debounce edges — flush the pending draft write synchronously on `submit()`, `clear()`, project switch (`onChange(of: projectPath)`), and sheet dismissal, so no in-flight text is lost if the sheet closes before the debounce fires. `clear()`/`submit()` already call `clearDraft`/`setDraft` directly; cancel any pending debounced write in those paths so a stale write can't resurrect a cleared/submitted draft.
- [ ] Step 5: Verify draft-resilience still works — dismiss and reopen the sheet, and relaunch the app, confirming the in-flight text/toggles are restored (the #031 behavior must be preserved). 👁 (requires running the app)
- [ ] Step 6: Run `swift test` and confirm the new test passes and no regressions; build with `./build.sh` and re-type in the form to confirm the hitch is gone. 👁 (final observation requires running the app)

## Verification
- The new debounce test passes (`swift test`), proving rapid `setDraft` calls are coalesced into at most one UserDefaults encode/write per typing pause, and the final value is still persisted.
- Typing continuously in the New Plan editor no longer produces perceptible hitches between poll boundaries (observed by running `./build.sh`). 👁
- Draft resilience is preserved: dismiss/reopen and app relaunch restore the in-flight text and toggles; project-switch still swaps to that project's draft. 👁
- No regressions: full `swift test` suite passes, including the existing #036 snapshot guards in `BrowserWindowTests.swift`.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/NewPlanModal.swift` — Add debounced persistence around `persistDraft()`; flush/cancel on submit, clear, project switch, and dismiss.
- [x] `Sources/Plans/PlansStore.swift` — (If needed) expose a way to coalesce/flush draft writes, or confirm the `captureDrafts.didSet` encode is the synchronous main-thread cost being debounced.
- [x] `Tests/PlansTests/PlansStoreTests.swift` (or new `NewPlanDraftPersistenceTests.swift`) — Add the failing-first debounce/coalescing test.

### Related Files (may need updates)
- `Sources/Plans/BrowserWindow.swift` — Presents the modal via `.sheet(item:)`; verify dismissal flushes the pending draft write.
- `Tests/PlansTests/BrowserWindowTests.swift` — Houses the #036 snapshot guards; must continue to pass unchanged.

### Endpoints/UI Affected
- New Plan modal description editor (`PlanTextEditor`) — typing responsiveness improves; behavior otherwise unchanged.

## Assumptions

### Initial (from elaboration)
- [low] Treated #052 as a *secondary* cause rather than a duplicate of the completed #036, and scoped the fix to debouncing per-keystroke draft persistence. **Why:** Research found #036 already decoupled the picker from the 5s poll via a snapshot (and tests guard it), so the remaining per-keystroke cost is the synchronous `JSONEncoder().encode(captureDrafts)` + UserDefaults write fired by `.onChange(of: text) → persistDraft()` on every character (`NewPlanModal.swift:158`, `PlansStore.swift:82-88`). This is the most plausible re-report cause visible in the code without a live profile.
- [low] Chose a ~300ms debounce on `persistDraft()` in `NewPlanModal` (view-side) rather than throttling inside `PlansStore` or moving the encode off-main. **Why:** Keeps the change minimal and local to the form, preserves the store's single-sink persistence contract, and avoids touching the polling/reload path; research warned against over-engineering (debounce/throttle the poll cycle) unless profiling proves a deeper bottleneck. Debounce interval is a judgement call not specified by the source description.
- [high] Preserve the existing `isSwitchingProject` guard and #031 draft-resilience semantics (restore on reopen/relaunch, swap on project switch). **Why:** These are documented, tested behaviors central to the form; the fix must not regress them, and flushing on submit/clear/switch/dismiss keeps them intact.
- [low] Did not change the 5s poll interval or move `PlansStore.reload()` parsing off the main thread. **Why:** Research flagged the poll cadence as synchronized with other workflows (#006 watch poll, #024 git refresh, #051 reconciliation); the deeper background-parse change is an optional follow-up only if Instruments shows the parse pass itself blocks, so it is deferred out of this task's scope.
- [low] If, on running the app (Step 1), the hitch is genuinely absent (i.e. #036 fully resolved it and this is a stale re-report), the executor should confirm via observation and close #052 as resolved/duplicate of #036 rather than forcing a code change. **Why:** The lag could not be observed from static analysis alone; the debounce is a defensible improvement regardless, but the executor should not invent a regression that isn't reproducible.

### Discovered during execution
- [low] Implemented the debounce inside `PlansStore` (a new `setDraftDebounced(_:for:interval:)` + `flushPendingDraft()` pair) rather than view-side in `NewPlanModal` as the elaboration suggested. **Why:** Keeping the debounce in the store preserves the single-sink persistence contract (the synchronous `captureDrafts.didSet` encode stays the one place writes happen), makes the coalescing behavior directly unit-testable against the injected UserDefaults suite, and avoids spreading timer/`@State` lifecycle across the view. The view just swaps `setDraft` → `setDraftDebounced` and flushes on edges.
- [high] Default debounce interval is 0.3s (300ms), matching the elaboration's suggested value, exposed as a parameter so tests can pass a short/long interval. **Why:** Balances responsiveness against write coalescing; configurable so tests stay fast and deterministic.
- [high] `draft(for:)` now returns the in-flight `pendingDraft` when its path matches, falling back to the persisted `captureDrafts` map. **Why:** Without this, a `loadDraft`/reopen between a keystroke and the debounce fire could read a stale persisted value; returning the pending value keeps the form self-consistent. The existing `testCaptureDraftRoundTripsAcrossStoreInstances` still passes since synchronous `setDraft` commits immediately.
- [high] `setDraft` and `clearDraft` both cancel any pending debounced write before mutating `captureDrafts`. **Why:** Prevents a stale timer from resurrecting a cleared/submitted draft (`clear()`/`submit()` call these directly). Project switch and sheet dismissal instead FLUSH (commit) the pending write so an in-flight keystroke isn't lost.
- [low] Used `DispatchWorkItem` + `DispatchQueue.main.asyncAfter` for the debounce (stored in `@ObservationIgnored` properties), mirroring the existing GCD/timer style in `PlansStore` (poll timer, #024 git refresh). **Why:** No external deps, main-thread-only store, consistent with the file's existing concurrency approach.
- [high] Pre-existing, UNRELATED test failures observed in `PlansStoreTests` (4 of 27): `testReloadPopulatesProjectsWithCounts`, `testReloadHandlesMultipleProjectsInRegistryOrder`, `testReloadPopulatesProjectsWithCounts`, `testStartPollingPerformsInitialLoadSynchronously` fail with project-name capitalization mismatch ("Alpha" vs "alpha") — the macOS temp dir resolves a capitalized path component. **Why:** These are environment/path-derivation failures unrelated to draft persistence; my diff touches only draft methods + view wiring. The draft round-trip test and all 6 new debounce tests pass.

## Changes
- **`Sources/Plans/PlansStore.swift`** — Added a debounced/coalescing draft-persistence path so per-keystroke draft saves no longer each force a synchronous `JSONEncoder().encode(captureDrafts)` + UserDefaults write on the main thread (the secondary cause of the typing lag, with #036 having already removed the 5s-poll cause):
  - `setDraftDebounced(_:for:interval:)` (default `interval: 0.3`s) — buffers the latest draft in a new `@ObservationIgnored pendingDraft: (path, draft)?` and schedules a cancellable `DispatchWorkItem` (`pendingDraftWorkItem`) on the main run loop that commits to `captureDrafts` (still the single encode/write sink). Each call cancels+replaces the prior work item → rapid keystrokes coalesce into at most one write per typing pause.
  - `flushPendingDraft()` — commits any pending draft immediately and cancels the timer (no-op when nothing pending). Used on the edges that must not drop an in-flight keystroke.
  - `draft(for:)` now returns the in-flight `pendingDraft` when its path matches, so a reopen/load between a keystroke and the debounce fire never reads a stale value.
  - `setDraft`/`clearDraft` now cancel any pending debounced write first (via private `cancelPendingDraft()`), so a stale timer can't resurrect a cleared/overwritten draft. Added private `commitPendingDraft()`/`cancelPendingDraft()` helpers.
- **`Sources/Plans/NewPlanModal.swift`** — `persistDraft()` now calls `store.setDraftDebounced(...)` instead of `store.setDraft(...)`. Added `flushPendingDraft()` on the edge paths: project switch (`onChange(of: projectPath)`, before `loadDraft`) and sheet dismissal (`.onDisappear`). `submit()`/`clear()` already cancel the pending write through their existing `store.clearDraft(...)` calls, so the subsequent `.onDisappear` flush is a no-op (no stale resurrection). The `isSwitchingProject` guard is preserved unchanged.
- **`Tests/PlansTests/NewPlanDraftPersistenceTests.swift`** (new) — 6 XCTest cases over an injected `UserDefaults(suiteName:)` suite: rapid debounced updates don't write until the interval elapses; the final value persists after the interval; `flushPendingDraft()` persists immediately; `draft(for:)` reflects the pending value before flush; `setDraft`/`clearDraft` each cancel a pending debounced write. (Written failing-first against the not-yet-existent API, then made to pass.)

### Tests run
- `swift test --filter NewPlanDraftPersistenceTests` → 6 tests, 0 failures.
- `swift test --filter PlansStoreTests/testCaptureDraftRoundTripsAcrossStoreInstances` → passes (#031 draft round-trip preserved).
- Note: 4 unrelated `PlansStoreTests` (`reload`/project-name derivation, e.g. `"Alpha" != "alpha"`) fail on a clean `main` too — a macOS temp-dir path-capitalization quirk in the test fixtures, NOT a regression from this change (verified against the untouched base branch).

## Notes
- Prior art: `.plans/completed/036-typing-in-new-plan-is-sometimes-laggy.md` — fixed the ~5s polling-boundary lag by snapshotting the project list (`orderedProjectsSnapshot`) so the body no longer reads live `store.projects`. Guarded by `BrowserWindowTests.swift` (path-identity-key tests).
- Key code locations: per-keystroke persistence `NewPlanModal.swift:158` → `persistDraft()` (237) → `store.setDraft` → `PlansStore.swift:82-88` `captureDrafts.didSet` (synchronous `JSONEncoder().encode` + UserDefaults write). `PlanTextEditor` NSTextView wrapper at `NewPlanModal.swift:279-327`.
- Reusable patterns: `isSwitchingProject` runloop-deferred guard (NewPlanModal:51, 219-231); OSLog category `NewPlanModal` (NewPlanModal:4) for correlating keystroke timing against poll ticks in Console.app / Instruments.
- Related pending work that touches this form: #048 (image paste — adds `imageData` to `CaptureDraft`, would increase per-keystroke encode cost, reinforcing the debounce), #051 (creating-spinner handoff).
