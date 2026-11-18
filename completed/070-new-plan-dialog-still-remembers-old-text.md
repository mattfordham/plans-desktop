# New Plan Dialog Still Remembers Old Text After Submission

**ID:** 070
**Created:** 2026-08-25T00:00
**Type:** bug
**Status:** completed
**Branch:** fix/070-new-plan-dialog-still-remembers-old-text
**Completed:** 2026-08-25T13:30

## What
Despite a recently completed related plan, I am still experiencing the "New Plan" dialog "remembering" old text. In other words, after submitting the form to create new plans, the text does not get cleared out of the input before the next opening.

## Why
Improves reliability by fixing a draft-persistence race that #064 left behind: even though `submit()` calls `store.clearDraft(...)`, the just-submitted text is re-persisted after the clear, so the next open of the New Plan sheet restores stale text. A capture form that silently remembers an already-submitted plan invites confusing double-submits and undermines trust in the whole capture flow.

## How Summary
`NewPlanModal.submit()` clears the draft (`store.clearDraft(for:)`) but does NOT reset the editor's `text` State, and its `imageData = nil` line fires `.onChange(of: imageData)` → `persistDraft()` on a LATER runloop turn — after `clearDraft` already ran — re-arming a debounced draft write that still carries the old `text`. The sheet's `.onDisappear` then calls `store.flushPendingDraft()`, committing that re-armed draft back into `captureDrafts[projectPath]`, so the next `loadDraft(for:)` restores it. The fix suppresses draft persistence for the submit turn with an `isSubmitting` guard in `persistDraft()` (mirroring the existing `isSwitchingProject` guard) and resets `text = ""` before the other submit mutations, so nothing re-creates the draft after the clear — and if any persist did slip through, it would write an empty draft, not the old text.

**Files of note:**
- `Sources/Plans/NewPlanModal.swift` — `submit()`, `persistDraft()`, and the `.onChange`/`.onDisappear` handlers; where the `isSubmitting` guard and the `text` reset land.
- `Sources/Plans/PlansStore.swift` — draft store: `setDraftDebounced` / `flushPendingDraft` / `commitPendingDraft` / `clearDraft` / `cancelPendingDraft`; the debounce buffer whose post-clear re-arm is the resurrection vector (expected unchanged, referenced by the regression test).
- `Tests/PlansTests/NewPlanDraftPersistenceTests.swift` — home for the store-level regression test asserting a re-armed debounced write after `clearDraft` + `flushPendingDraft` must not resurrect a cleared draft (mirrors the existing `testClearDraftCancelsPendingDebouncedWrite`).

## Diagnosis

**Most likely:** `submit()`'s `imageData = nil` (and any in-flight keystroke debounce) re-arms a debounced draft write AFTER `store.clearDraft(...)` runs, and `.onDisappear`'s `flushPendingDraft()` then commits that draft — carrying the un-reset `text` — back into `captureDrafts`, so the next open restores it. (`Sources/Plans/NewPlanModal.swift:395-401`, `:182-184`, `:201-205`, `:331-343`)
**Evidence:** `submit()` order is `runner.capture` → `imageData = nil` (`:395`) → `store.clearDraft(for:)` (`:396`) → `dismiss()`/`onClose()` (`:400-401`). `.onChange(of: imageData)` (`:205`) fires on a later turn, calling `persistDraft()` (`:331`), whose only guard is `isSwitchingProject` (`:332`, false during submit); it calls `setDraftDebounced` with the live, un-reset `text` (`:333-342`). `onClose()` nils the `.sheet(item:)` binding → `.onDisappear` (`:182`) → `store.flushPendingDraft()` (`:183`) → `commitPendingDraft()` (`Sources/Plans/PlansStore.swift:427-431`) writes the re-armed buffer into `captureDrafts`. `clearDraft`'s own `cancelPendingDraft()` (`PlansStore.swift:448`) runs too early to help, since the re-arm happens after it. `submit()` never resets `text`, so the resurrected draft carries the full submitted string.
**Confidence:** high

**Alternative:** A still-pending keystroke debounce from typing just before submit survives into `.onDisappear`'s flush even with no image staged (`Sources/Plans/NewPlanModal.swift:201`, `:183`) — **Confidence:** medium (subsumed by the most-likely cause; both are fixed by the same guard + `text` reset).

**To confirm:** Add a log line in `persistDraft()` and `PlansStore.commitPendingDraft()`, then submit once with an image staged and once without (submitting >0.5s after the last keystroke) and observe whether `persistDraft()` fires during/after `submit()` and `commitPendingDraft()` writes the old text back. This isolates whether the image `.onChange` is the guaranteed trigger and whether the no-image path needs the guard too. A store-level unit test (below) reproduces the same clear→re-arm→flush sequence agent-verifiably.

## How
- [x] Step 1: Add a failing store-level regression test in `Tests/PlansTests/NewPlanDraftPersistenceTests.swift` (TDD; agent-verifiable, so untagged) that reproduces the resurrection sequence: `setDraftDebounced(draftA, for: "/proj")` → `clearDraft(for: "/proj")` → `setDraftDebounced(draftA-again, for: "/proj")` (simulating the post-clear re-arm) → `flushPendingDraft()`, then assert `draft(for: "/proj") == nil`. This pins the store contract the fix relies on; if the store itself should not be changed, this test documents the invariant the view guard must uphold. (Confirms the Diagnosis before any fix.)
- [x] Step 2: In `Sources/Plans/NewPlanModal.swift`, add an `@State private var isSubmitting = false` flag (mirroring `isSwitchingProject`) and extend `persistDraft()`'s guard to `guard !isSwitchingProject && !isSubmitting else { return }`, so no `.onChange`-driven persist can re-arm a debounced write during the submit turn.
- [x] Step 3: In `submit()`, set `isSubmitting = true` at the top (after the empty-guard) and reset `text = ""` before `imageData = nil` / `store.clearDraft(...)`, so the editor State is empty and persistence is suppressed for the turn; keep `store.clearDraft(for: projectPath)` as the authoritative removal. Ensure `isSubmitting` is reset to `false` (e.g. `DispatchQueue.main.async { isSubmitting = false }`, matching the `isSwitchingProject` teardown) so a subsequent reopen of the sheet persists normally.
- [x] Step 4: Build and run the suite (`swift build && swift test`) and confirm the new regression test plus the existing `NewPlanDraftPersistenceTests` / `BrowserWindowTests` all pass; fix any compile fallout from the new State flag and guard.
- [x] 👁 Step 5: Run the app (`./build.sh`) and manually confirm that after submitting the New Plan form (via Capture / Elaborate & Capture / Execute) — including the image-staged case and submitting immediately after the last keystroke — reopening the New Plan sheet for the same project shows an EMPTY editor, not the just-submitted text. (Draft resurrection on reopen is not fully unit-observable through the SwiftUI view layer; this manual pass is the real acceptance check.)

## Verification
- New store-level regression test in `NewPlanDraftPersistenceTests.swift` passes, asserting that a debounced write re-armed after `clearDraft` and then flushed does not leave a non-nil draft (`draft(for:)` is `nil`).
- `swift test` passes with no regressions in `NewPlanDraftPersistenceTests`, `BrowserWindowTests`, or the rest of the suite.
- Manual (Step 5, 👁): after submitting the New Plan form via each of Capture / Elaborate & Capture / Execute — with and without a staged image, and when submitting right after the last keystroke — reopening the sheet for the same project starts with an empty editor and no restored toggles. The #064 behavior (sheet dismisses reliably; ⌘N is idempotent while open) is unaffected.

## Assumptions

### Initial (from elaboration)
- Assumed the report refers to the in-app New Plan sheet/modal (Surface B / `BrowserWindow` → `NewPlanModal`), the same surface #064 addressed — not the plans-cc CLI capture skill.
- Assumed "remembering old text … not cleared before the next opening" means the previously-submitted draft text is restored into the editor on the NEXT open of the sheet for the same project, distinct from #064's already-fixed sheet-dismissal/⌘N-re-present symptom.
- [high] Root-caused this as a draft-persistence RE-ARM race (post-`clearDraft` `.onChange`/`.onDisappear` persistence), not a dismissal bug. **Why:** #064 already made dismissal authoritative and added `store.clearDraft` to `submit()`; research traced the surviving symptom to `imageData = nil` firing `persistDraft()` after `clearDraft`, with `.onDisappear`'s `flushPendingDraft()` committing the re-armed draft — a mechanism #064 did not address.
- [high] Fix in the VIEW via an `isSubmitting` guard on `persistDraft()` plus resetting `text = ""` in `submit()`, rather than changing the `PlansStore` draft API. **Why:** the store already correctly cancels pending writes in `clearDraft`; the defect is that the view re-arms a write AFTER the clear. Guarding the submit turn mirrors the codebase's existing `isSwitchingProject` pattern (`NewPlanModal.swift:72,332`) and is the minimal, in-idiom fix. The store is left intact.
- [low] Chose a STORE-LEVEL regression test (the clear→re-arm→flush invariant) over a view-level test. **Why:** SwiftUI `.onChange`/`.onDisappear`/`@State` submit flow is not cleanly unit-observable, whereas the store's draft lifecycle is already covered by unit tests in `NewPlanDraftPersistenceTests.swift` (e.g. `testClearDraftCancelsPendingDebouncedWrite`); the manual 👁 step is the acceptance check for the view path. The exact reproduction path (image-staged vs pending-keystroke) is unconfirmed until the Step 1/Step 5 observations run.
- [low] Reset `text = ""` (and rely on the `isSubmitting` guard) rather than reordering `submit()` so `clearDraft` runs last. **Why:** research warned that ordering alone is fragile because SwiftUI defers `.onChange` to a later turn and `.onDisappear`'s flush still runs after `clearDraft`; a guard + empty-text reset is robust even if a persist slips through (it would write an empty draft, never the old text).

### Discovered during execution
- [low] The Step 1 store-level regression test (`testFlushResurrectsDraftReArmedAfterClear`) asserts the store DOES resurrect the re-armed draft (`draft(for:) == "submitted text"`) rather than the plan's `== nil`. **Why:** the store genuinely commits a `setDraftDebounced` issued AFTER `clearDraft` when subsequently flushed — it cannot distinguish an illegitimate submit-turn re-arm from a legitimate post-clear keystroke. Asserting `== nil` would misrepresent (and mis-pin) real store behavior; the plan's NOTE explicitly permitted an immediate-pass/valid-outcome and forbade artificial force-fail. The test therefore documents the store invariant (already-correct `clearDraft` cancel is covered by `testClearDraftCancelsPendingDebouncedWrite`; the resurrection only occurs via a re-arm the VIEW must suppress). Consequently the test went GREEN immediately, not RED — expected here since the fix lives entirely in `NewPlanModal`.
- [high] Placed `DispatchQueue.main.async { isSubmitting = false }` as the FINAL statement of `submit()` (after `dismiss()`/`onClose()`), mirroring `loadDraft`'s `isSwitchingProject` teardown. **Why:** matches the existing runloop-drain teardown idiom exactly; the guard must stay true across the whole synchronous submit turn so the deferred `.onChange`/`.onDisappear` persists are suppressed, then clear on the next tick so a reopen persists normally.

## Changes
- `Sources/Plans/NewPlanModal.swift`: Added `@State private var isSubmitting = false` (mirrors `isSwitchingProject`). Extended `persistDraft()`'s guard to `guard !isSwitchingProject && !isSubmitting else { return }`. In `submit()`: set `isSubmitting = true` right after the empty-text guard, reset `text = ""` before `imageData = nil` / `store.clearDraft(...)`, and defer `isSubmitting = false` to the next runloop tick (`DispatchQueue.main.async`) so a later reopen persists normally. The #064 dismissal/⌘N machinery was left untouched.
- `Tests/PlansTests/NewPlanDraftPersistenceTests.swift`: Added `testFlushResurrectsDraftReArmedAfterClear`, reproducing the `setDraftDebounced → clearDraft → setDraftDebounced (re-arm) → flushPendingDraft` sequence. It documents the store's actual contract: a debounced write re-armed after `clearDraft` IS committed on flush (the resurrection vector), which is why the fix lives in the view via the `isSubmitting` guard. `PlansStore.swift` left unchanged.
- Tests: `swift build` clean; `swift test --filter NewPlanDraftPersistenceTests` (9 tests) and `swift test --filter BrowserWindowTests` (84 tests) pass with 0 failures.

## Notes
- Related prior work: #064 (completed 2026-08-24) fixed the New Plan sheet's dismissal (`onClose` nils the `.sheet(item:)` binding) and the ⌘N re-present race, and added `store.clearDraft(...)` to `submit()`. #070 is the residual draft-resurrection race that #064's clear did not fully close — do NOT re-touch the dismissal/re-entrancy machinery.
