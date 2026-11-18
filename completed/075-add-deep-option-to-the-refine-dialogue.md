# Add Deep Option To The "Refine" Dialogue

**ID:** 075
**Created:** 2026-09-01T19:45
**Type:** feature
**Status:** completed
**Branch:** feature/075-add-deep-option-to-the-refine-dialogue
**Completed:** 2026-09-02T12:06

## What
Add a "deep" option to the "Refine" dialogue.

## Why
The "Refine Plan" sheet (`ReElaborateModal`, #056) hands the user's guidance to
`TaskRunner.run(... mode: .reElaborate)`, which drives plan-elaborate's Path-C
further-elaboration pass. The backend already supports a `deep` mode end-to-end:
`TaskRun` carries a `deep` flag, `spawn` appends the valueless `--deep` process
flag, and `TaskRunner.run(...)` accepts a `deep:` parameter that composes
orthogonally with ANY elaborate-bearing mode — including `.reElaborate` (see the
doc comment on `TaskRun.deep` and the `spawn` `--deep` block in TaskRunner.swift).

The "New Plan" capture sheet (`NewPlanModal`) already exposes this via a "Deep"
checkbox (#065/#074: "Draft the elaboration via a reasoning sub-agent"). The
Refine sheet is the one remaining elaborate-driving surface that cannot request
a deep pass, even though the plumbing is fully in place. This task closes that
gap so a user refining an already-elaborated plan can opt into the deeper
reasoning pass, matching the New Plan sheet's affordance.

## How Summary
Add an unconditional "Deep" checkbox to `ReElaborateModal` (mirroring
`NewPlanModal`'s toggle, minus the `.disabled(!elaborate)` gate since the Refine
sheet has no Elaborate toggle), back it with a `@State` flag, and pass that flag
through the existing `runner.run(... deep:)` parameter on submit. No backend
changes — the `deep` plumbing already exists through `.reElaborate`. Add a unit
test at the `TaskRun` layer proving a `.reElaborate` run built with `deep: true`
carries the flag.

## How
- [x] Add a failing unit test in `Tests/PlansTests/TaskRunnerTests.swift`:
      `testReElaborateRunCarriesDeepFlag` — construct
      `TaskRun(taskID: "075", mode: .reElaborate, description: "…", deep: true)`
      and assert `run.mode == .reElaborate`, `run.deep == true`, plus a companion
      assertion that a `.reElaborate` run defaults `deep` to `false` when omitted.
      Mirror the structure of the existing
      `testElaborateRunCarriesDescriptionAndDeepTogether` /
      `testReElaborateRunCarriesTaskIDAndDescription` tests. Run ONLY this test
      file and confirm the new test compiles/passes (the backend already supports
      it, so this codifies the contract the UI relies on).
- [x] In `Sources/Plans/ReElaborateModal.swift`, add `@State private var deep = false`
      alongside the existing `text` state, with a doc comment mirroring
      `NewPlanModal`'s `deep` comment (referencing plans-cc `deep` mode / #065).
- [x] Add a "Deep" `Toggle(isOn: $deep)` to the sheet — checkbox style, with the
      same help text as `NewPlanModal` ("Draft the elaboration via a reasoning
      sub-agent (plans-cc `deep` mode)"). Because the Refine sheet has no Elaborate
      toggle, the Deep toggle is UNCONDITIONAL — do NOT add a `.disabled(...)`
      modifier. Place it in the button `HStack` (before the `Spacer()` so it sits
      left of Cancel/Refine), or in a small row above the Divider; keep the sheet's
      existing frame/min-size.
- [x] In `submit()`, pass `deep: deep` into the existing `runner.run(...)` call so
      `.reElaborate` runs with the flag. Include `deep` in the existing
      `reElaborateLog.notice(...)` submit log line for parity with `NewPlanModal`.
- [x] Build (`swift build`) and run the targeted test file
      (`swift test --filter TaskRunnerTests`) to confirm the new test passes and
      nothing in that file regressed.

## Verification
- `swift build` succeeds with no warnings introduced by the change.
- `swift test --filter TaskRunnerTests` passes, including the new
  `testReElaborateRunCarriesDeepFlag`.
- Open the app, open a plan's Refine sheet, and confirm a "Deep" checkbox appears;
  toggling it on and submitting a refinement drives a `.reElaborate` run with the
  `--deep` flag (observable in the run log / os_log `modal Refine submitted` line
  showing `deep=true`).
- With Deep unchecked, behaviour is unchanged from today (no `--deep`).

## Impact Scope
- `Sources/Plans/ReElaborateModal.swift` — add `deep` state, the Deep toggle, and
  pass `deep:` on submit.
- `Tests/PlansTests/TaskRunnerTests.swift` — add `testReElaborateRunCarriesDeepFlag`.

(`Sources/Plans/TaskRunner.swift` needs NO change: `run(... deep:)`, the `TaskRun.deep`
property, and the `--deep` spawn flag already exist and compose with `.reElaborate`.)

## Assumptions

### Initial (from elaboration)
- [low] The "Refine" dialogue refers to `ReElaborateModal` ("Refine Plan #NNN").
  **Why:** It is the only sheet titled "Refine" in the codebase and the only
  elaborate-driving surface (via `.reElaborate`) that lacks a Deep option; #074
  added the identical option to the sibling New Plan / Elaborate flow, making this
  the natural follow-up.
- [low] The Deep toggle is UNCONDITIONAL on this sheet (no `.disabled` gate).
  **Why:** `NewPlanModal` disables Deep unless Elaborate is on, but the Refine
  sheet always drives an elaborate pass (`.reElaborate`) and has no Elaborate
  toggle, so Deep is always meaningful here.
- [high] No backend changes are needed. **Why:** `TaskRunner.run(...)` already
  accepts `deep:`, `TaskRun` stores it, and `spawn` emits `--deep` for any mode
  including `.reElaborate` (confirmed in TaskRunner.swift docs + code).

### Discovered during execution
- [low] Placed the Deep checkbox inside the bottom button `HStack`, immediately
  after the leading `Spacer()` (so it sits left of the Cancel/Refine buttons)
  rather than in a separate row above the `Divider()`. **Why:** The task offered
  both placements; the in-HStack option keeps the sheet's existing frame/min-size
  and vertical rhythm untouched (no new row/spacing), and the `Spacer()` pushes
  Deep flush-left of the action buttons, which reads as a modifier for the Refine
  action — consistent with a compact single-field sheet.

## Changes
- `Sources/Plans/ReElaborateModal.swift`:
  - Added `@State private var deep = false` (doc-commented, referencing plans-cc
    `deep` mode / #075; unconditional since the sheet has no Elaborate toggle).
  - Added an unconditional `Toggle("Deep", isOn: $deep)` (`.toggleStyle(.checkbox)`,
    help text matching `NewPlanModal`) into the bottom button `HStack`, inline with
    the Cancel/Refine actions. No `.disabled(...)` modifier.
  - `submit()` now passes `deep: deep` as the final argument to `runner.run(...)`,
    so a checked box drives the `.reElaborate` run's `--deep` flag; the
    `reElaborateLog.notice(...)` submit line now includes `deep=…` for parity.
- `Tests/PlansTests/TaskRunnerTests.swift`:
  - Added `testReElaborateRunCarriesDeepFlag` (a `.reElaborate` run with
    `deep: true` carries the flag alongside its description) and
    `testReElaborateRunDefaultsDeepToFalse` (omitting `deep:` defaults to false,
    preserving the pre-#075 arg shape).
- `Sources/Plans/TaskRunner.swift`: unchanged — `run(... deep:)`, `TaskRun.deep`,
  and the `--deep` spawn flag already exist and compose with `.reElaborate`.

**Verification:** `swift build` clean (no new warnings); `swift test --filter
TaskRunnerTests` → 61 tests, 0 failures (includes the 2 new tests).

## Notes
Precedent: #074 ("Elaborate Button: Use Dialog With Input and 'Deep' Option") and
#065 introduced the Deep affordance and the full `--deep` backend plumbing. This
task extends that same affordance to the Refine sheet. SwiftUI views are not
unit-tested in this repo; the testable contract lives at the `TaskRun`/`TaskRunner`
layer, which is where the new test belongs.
