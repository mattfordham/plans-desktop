# New Plan Dialogue Doesn't Clear After Capture/Create

**ID:** 064
**Created:** 2026-08-21T11:11
**Type:** bug
**Status:** completed
**Completed:** 2026-08-24T10:48
**Branch:** fix/064-new-plan-dialogue-doesnt-clear-after-capture

## What
Sometimes the new plan dialogue doesn't clear out after capture/create.

## Why
Improves reliability by fixing the intermittent case where the "New Plan" capture
sheet stays open (or re-presents) after a successful submit — leaving the user
looking at a stale form, unsure whether the plan was captured, and prone to
double-submitting. A capture surface that doesn't reliably dismiss undermines
trust in the whole capture flow.

## How Summary
The sheet is presented by `BrowserWindow` via `.sheet(item: $newPlanRequest)`, but
`NewPlanModal.submit()` dismisses it only through `@Environment(\.dismiss)` — which
is not the authoritative teardown for an `item:`-driven sheet and can drop its
write-back to `newPlanRequest` when `submit()` fires observable mutations
(`runner.capture`, `store.clearDraft`) on the same runloop turn, so the binding
stays non-nil and the sheet stays up. Separately, `openNewPlanForRecentProject()`
unconditionally reassigns a fresh `NewPlanRequest` on every ⌘N, so a repeated
trigger while the sheet is open re-presents it. The fix makes dismissal explicit
(the presenter nils `newPlanRequest`, threaded into the modal as a close closure)
and guards the open path against re-entrancy via a pure, unit-testable static
helper.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — owns `newPlanRequest` @State, `.sheet(item:)`, the ⌘N `.onChange`, and `openNewPlanForRecentProject()`; where the close closure and re-entrancy guard land.
- `Sources/Plans/NewPlanModal.swift` — the sheet content; `submit()` / Cancel must route through the presenter-supplied close closure instead of relying solely on `@Environment(\.dismiss)`.
- `Tests/PlansTests/BrowserWindowTests.swift` — home for the regression test over the extracted static open-decision helper (mirrors the existing `columnCount`/`effectiveLayoutMode` static-helper tests).
- `Sources/Plans/PlansStore.swift` — `requestNewPlan()`/`newPlanTrigger` (⌘N source) and `clearDraft` (referenced by the flow, unchanged).

## How
- [x] Step 1: Extract the open-decision into a pure static helper on `BrowserWindow`, e.g. `static func shouldOpenNewPlan(currentRequest:sortedProjects:) -> NewPlanRequest?` — returns `nil` when a request is already active (re-entrancy guard) or there are no projects, otherwise a fresh `NewPlanRequest` for the most-recently-touched project. Add its regression test FIRST in `Tests/PlansTests/BrowserWindowTests.swift` (TDD; make `NewPlanRequest` module-visible/`internal` if the test needs to assert on it) covering: no projects → nil; active request present → nil (guards the ⌘N re-present race); no active request + projects → a request for the staleness-sorted first project.
- [x] Step 2: Rewrite `openNewPlanForRecentProject()` to delegate to the Step 1 helper (`newPlanRequest = BrowserWindow.shouldOpenNewPlan(currentRequest: newPlanRequest, sortedProjects: BrowserViewModel.sortByStaleness(store.projects))`), so the toolbar button and the `store.newPlanTrigger` `.onChange` both no-op when the sheet is already open.
- [x] Step 3: Add an explicit close closure to `NewPlanModal` (e.g. `var onClose: () -> Void`) and have `BrowserWindow`'s `.sheet(item:)` builder pass `{ newPlanRequest = nil }` — niling the `item:` binding is the authoritative dismissal for `.sheet(item:)` rather than depending on `@Environment(\.dismiss)` writing it back.
- [x] Step 4: Route both `submit()` and the Cancel button through `onClose()` in `NewPlanModal` (keep the existing `dismiss()` call too as harmless belt-and-suspenders). In `submit()`, keep `store.clearDraft(...)` and `imageData = nil` before the close so a reopen never restores the just-submitted draft, and make `onClose()` (the binding-nil) the final mutation of the turn.
- [x] Step 5: Build and run the test suite (`swift build && swift test`) and confirm the new helper test and the existing `NewPlanDraftPersistenceTests` / `BrowserWindowTests` all pass; fix any compile fallout from the new `NewPlanModal` parameter and the helper extraction.
- [x] 👁 Step 6: Run the app (`./build.sh`) and manually confirm the sheet reliably dismisses after Capture / Elaborate & Capture / Execute across repeated submits, and that pressing ⌘N repeatedly while the sheet is open does not stack or re-present it. (Sheet dismissal is not unit-observable; this manual pass is the real acceptance check.)

## Verification
- New static-helper regression test in `BrowserWindowTests.swift` passes, asserting the re-entrancy guard (active request → nil) and the no-projects → nil / projects → fresh-request cases.
- `swift test` passes with no regressions in `NewPlanDraftPersistenceTests` and the rest of the suite.
- Manual (Step 6, 👁): after submitting the New Plan form via each of Capture / Elaborate & Capture / Execute, the sheet dismisses every time (repeated attempts), the form does not linger or reappear, and a fresh open starts empty (the submitted draft was cleared). Hammering ⌘N while the sheet is open neither stacks nor re-presents it.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/BrowserWindow.swift` — add the `shouldOpenNewPlan` static helper + re-entrancy guard; pass a `{ newPlanRequest = nil }` close closure into `NewPlanModal`; route `openNewPlanForRecentProject()` through the helper.
- [x] `Sources/Plans/NewPlanModal.swift` — add an `onClose` closure parameter; route `submit()` and Cancel through it (keeping `dismiss()` as a fallback); ensure draft clear precedes the close.
- [x] `Tests/PlansTests/BrowserWindowTests.swift` — add the TDD regression test for the extracted static open-decision helper.

### Related Files (may need updates)
- `Sources/Plans/PlansStore.swift` — `requestNewPlan()`/`newPlanTrigger` (⌘N source) and `clearDraft`; referenced by the flow, expected to need no change.
- `Sources/Plans/PlansApp.swift` — the ⌘N `CommandGroup` that calls `store.requestNewPlan()`; referenced only, no change expected.

### Endpoints/UI Affected
- New Plan capture sheet (Surface B / `BrowserWindow`) — dismisses reliably after submit; ⌘N is idempotent while the sheet is open.

## Assumptions

### Initial (from elaboration)
- Assumed "new plan dialogue" refers to the in-app new-plan form/modal (Surface B / browser window) used to quick-capture a plan, not the plans-cc CLI skill.
- Assumed "doesn't clear out" means the form's input fields (and/or the modal itself) retain their previous content or stay open after a successful capture/create action, when they should reset/dismiss.
- Assumed "sometimes" indicates an intermittent/race-condition-style bug rather than a consistent, always-reproducible failure.
- [low] Fix BOTH candidate root causes in one pass — the unreliable `@Environment(\.dismiss)` write-back on the `.sheet(item:)` binding AND the ⌘N re-present race — rather than one. **Why:** research identified two independent plausible causes and could not confirm from the "sometimes" report which one the user hit; both fixes are small, complementary, and low-risk, so shipping both removes the ambiguity. (Discovered assumption — the exact reproduction path is unconfirmed.)
- [high] Make dismissal authoritative by threading the `$newPlanRequest` binding into `NewPlanModal` as a close closure (`onClose`) that the presenter sets to `{ newPlanRequest = nil }`, keeping `@Environment(\.dismiss)` only as a fallback. **Why:** niling the `item:` binding is the documented source-of-truth teardown for `.sheet(item:)`, and closure-injection into a child view is the pattern already used for `onNewPlan` in `BrowserWindow`/`ProjectCard`.
- [high] Implement the re-entrancy guard as a pure `static func` open-decision helper on `BrowserWindow` and cover it with a TDD regression test in `BrowserWindowTests.swift`. **Why:** SwiftUI sheet dismissal isn't unit-observable, but the codebase already factors view logic into testable `static func`s (`columnCount`, `effectiveLayoutMode`, `visibleUnderHideEmpty`) each with matching tests — extracting the decision follows that established, verifiable pattern.
- [low] Keep the existing `dismiss()` call alongside the new explicit binding-nil rather than removing it. **Why:** both are idempotent so calling both is harmless, and retaining it avoids regressing any dismissal path (e.g. Escape/Cancel) not exercised by the manual check.

### Discovered during execution
- [low] `shouldOpenNewPlan` returns `nil` in the active-request case (matching the Step 1 test spec), and `openNewPlanForRecentProject()` guards the assignment — it only writes `newPlanRequest` when the helper returns non-nil. **Why:** the plan's Step 2 snippet (`newPlanRequest = shouldOpenNewPlan(...)`) would, if the helper returned `nil` for an active request, assign `nil` back and CLOSE an open sheet on a second ⌘N rather than no-op. Guarding the assignment preserves the intended "both no-op when the sheet is already open" behavior while keeping the helper's contract exactly as the Step 1 test asserts (active → nil).

## Changes
- **`Sources/Plans/BrowserWindow.swift`**: Made `NewPlanRequest` `internal` (was `private`) so it's unit-testable. Added pure `static func shouldOpenNewPlan(currentRequest:sortedProjects:) -> NewPlanRequest?` (re-entrancy guard: returns `nil` when a request is already active or there are no projects; otherwise a fresh request for the staleness-sorted first project). Rewrote `openNewPlanForRecentProject()` to delegate to the helper and only assign `newPlanRequest` when it returns non-nil (so a repeat ⌘N while the sheet is open no-ops instead of nil-ing/closing it). The `.sheet(item:)` builder now passes an `onClose: { newPlanRequest = nil }` closure into `NewPlanModal`.
- **`Sources/Plans/NewPlanModal.swift`**: Added `var onClose: () -> Void` (with init param). Routed both `submit()` and the Cancel button through `onClose()` (keeping `dismiss()` as belt-and-suspenders). In `submit()`, `imageData = nil` and `store.clearDraft(...)` run before `onClose()`, which is the final mutation of the turn — so niling the `item:` binding is the authoritative dismissal and a reopen never restores the just-submitted draft.
- **`Tests/PlansTests/BrowserWindowTests.swift`**: Added 3 TDD regression tests for `shouldOpenNewPlan` (no projects → nil; active request → nil; idle + projects → request for staleness-sorted first project).

## Notes
_Additional context_
