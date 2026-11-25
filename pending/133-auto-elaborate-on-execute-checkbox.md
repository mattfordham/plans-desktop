# Add Checkbox To Auto-Elaborate On Execute When Not Already Elaborated

**ID:** 133
**Created:** 2026-11-24T17:11
**Type:** feature
**Status:** review
**Branch:** feature/133-auto-elaborate-on-execute-checkbox

## What
When executing a plan add a checkbox to automatically elaborate it if it's not already.

## Why
Today a pending plan's Execute *always* auto-elaborates inline before running (shipped as
#088) — the behaviour is unconditional and invisible. This task surfaces that behaviour as an
explicit, toggleable checkbox in the Execute sheet so the user can choose to execute a pending
plan *without* a prior elaboration pass when they want to (e.g. a trivial throwaway task, or a
plan they'll elaborate differently). It turns a hidden always-on policy into a visible,
defaulted opt-out — matching how Deep and Keep are already exposed as checkboxes in the same
sheet.

## How Summary
Add an "Elaborate first" checkbox to `ExecutePendingModal` (the sheet a *pending* plan's
Execute opens), defaulting ON so existing behaviour is unchanged. When the user turns it OFF,
thread a valueless flag end-to-end — through `TaskRunner.run` → `TaskRun` → `TaskRun.arguments`
(emitting `--no-elaborate` only in the OFF case, so the default argv stays byte-identical) →
`run-task.ts`'s `buildExecutePrompt`, which then instructs the agent to choose "Execute anyway"
at `plan-execute`'s not-elaborated gate instead of "Elaborate now". The existing `Deep` toggle
(which only tunes the inline elaboration) is gated behind the new checkbox — hidden/disabled
when elaboration is off — mirroring how `NewPlanModal` gates Deep behind its Elaborate toggle.
The checkbox is shown only for the pending case, never for the `forReview` variant (already
elaborated, nothing to gate), exactly as Deep already is.

**Files of note:**
- `Sources/Plans/ExecutePendingModal.swift` — hosts the new `@State` checkbox + Toggle; gates Deep behind it; passes the flag to `runner.run`
- `Sources/Plans/TaskRunner.swift` — `run(...)` param, `TaskRun` stored field + init, and `TaskRun.arguments(...)` `--no-elaborate` emission
- `Tools/work-task/run-task.ts` — `RunInput` field, arg parse, and `buildExecutePrompt` branch that picks "Execute anyway" vs "Elaborate now"
- `Tests/PlansTests/TaskRunnerTests.swift` — argument-shape assertions to mirror for the new flag
- `Tools/work-task/run-task.modes.test.ts` — prompt-builder assertions for the new branch

## How
- [x] Step 1: In `Tests/PlansTests/TaskRunnerTests.swift`, add a failing argument-shape test: a `.execute` run with the new "elaborate first" flag OFF emits `--no-elaborate` (appended alongside `--deep`/`--keep`, before `--session`/`--resume`), and a run with it ON (the default) emits NO such flag — asserting the default argv stays byte-identical to today.
- [x] Step 2: In `Tools/work-task/run-task.modes.test.ts`, add a failing prompt test: `buildExecutePrompt` with elaboration OFF instructs the agent to choose "Execute anyway" at the not-elaborated gate (and never silently elaborate), while the default (ON) keeps the current "Elaborate now" wording.
- [x] Step 3: Thread the flag through `run-task.ts`: add an optional field to `RunInput` (default-true semantics via its absence, e.g. `noElaborate?: boolean`), parse a valueless `--no-elaborate` arg in the arg loop next to `--deep`/`--keep`, carry it into the `finish({...})` calls for the execute path, and pass it into `buildExecutePrompt`. Branch `buildExecutePrompt` so the not-elaborated-gate instruction reads "Execute anyway" (skip elaboration) when set, else the existing "Elaborate now" text. Keep the `deep` wording only on the Elaborate-now branch.
- [x] Step 4: Thread the flag through `Sources/Plans/TaskRunner.swift`: add the stored `let` on `TaskRun` (document it like `deep`/`keep`), add it to `TaskRun.init` (defaulted so no caller breaks), add a parameter to `TaskRunner.run(...)` (defaulted to the ON/auto-elaborate value), pass it into the `TaskRun(...)` construction, add a parameter to `TaskRun.arguments(...)`, and emit `--no-elaborate` there ONLY in the OFF case, positioned alongside `--deep`/`--keep` (after `--mode`, before `--session`/`--resume`). Make it a no-op for non-execute modes, matching how `--keep`/`--apply` are mode-scoped.
- [x] Step 5: In `Sources/Plans/ExecutePendingModal.swift`, add `@State private var elaborateFirst = true` and a `Toggle("Elaborate first", isOn: $elaborateFirst).toggleStyle(.checkbox)` in the existing toggle `HStack`, with a `.help(...)` explaining it auto-elaborates a pending plan before executing. Show it only in the pending case (hide it when `forReview`, like Deep). Gate the existing `Deep` toggle behind it (hide or disable Deep when `elaborateFirst` is false), and pass the resolved flag into the `runner.run(... mode: .execute)` call in `submit()`.
- [ ] 👁 Step 6: Build and run the app (`./build.sh`), open a pending plan's Execute sheet, and visually confirm: "Elaborate first" shows checked by default; unchecking it hides/disables Deep; the sheet is absent for a review-state Execute; and executing a pending plan with the box unchecked runs without an elaboration pass (agent chooses "Execute anyway").

## Verification
- `swift test` passes, including the new argument-shape test (`--no-elaborate` present only when elaboration is OFF; default argv unchanged).
- The TypeScript prompt tests pass (`npm test` / the configured test runner in `Tools/work-task/`), including the new `buildExecutePrompt` branch assertions.
- Manual (Step 6): in the running app, the pending-plan Execute sheet shows an "Elaborate first" checkbox, defaulted on; turning it off hides/disables Deep and executes the pending plan without an inline elaboration pass; the checkbox never appears on a review-state Execute.
- No regression: an Execute with the box left checked behaves exactly as today (auto-elaborates, Deep still tunable).

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/ExecutePendingModal.swift` — add the "Elaborate first" checkbox + state, gate Deep behind it, thread the flag into `submit()`'s `runner.run` call
- [x] `Sources/Plans/TaskRunner.swift` — `run(...)` parameter, `TaskRun` stored field + init default, `TaskRun.arguments(...)` parameter + `--no-elaborate` emission
- [x] `Tools/work-task/run-task.ts` — `RunInput` field, `--no-elaborate` arg parse, `finish({...})` plumbing, `buildExecutePrompt` branch
- [x] `Tests/PlansTests/TaskRunnerTests.swift` — new argument-shape test for the flag
- [x] `Tools/work-task/run-task.modes.test.ts` — new prompt-builder branch test

### Related Files (may need updates)
- `Sources/Plans/ExecuteModal.swift` — the *elaborated*-plan Execute sheet; intentionally NOT touched (an already-elaborated plan has nothing to auto-elaborate), but review if a shared toggle row is ever factored out
- `Sources/Plans/AgentDock.swift` — `route(for:status:)` already sends a pending Execute to `ExecutePendingModal`; no change expected, verify routing still holds
- `Sources/Plans/PlanDetailView.swift` — hosts the sheet (`showExecutePending`) and status predicates (`canExecutePending`); no change expected

### Endpoints/UI Affected
- The pending-plan (and review-state) Execute sheet (`ExecutePendingModal`) — gains one checkbox row control
- The `run-task.js` CLI argv contract — gains an optional `--no-elaborate` flag (execute mode only)

## Assumptions

### Initial (from elaboration)
- [high] The checkbox lives in `ExecutePendingModal.swift` (the sheet a *pending* plan's Execute
  opens), alongside the existing Deep/Keep `.toggleStyle(.checkbox)` toggles — NOT in
  `ExecuteModal.swift` (which is for already-elaborated plans and has nothing to elaborate).
  **Why:** research showed the pending-plan Execute path already auto-elaborates inline here, and
  this sheet is the single place where a pending plan's execute options are chosen; the Deep/Keep
  toggle row is the established pattern to extend.
- [low] The checkbox defaults ON (auto-elaborate), making the control an opt-OUT that preserves
  today's always-on behaviour; turning it off is the new capability. **Why:** the literal #088
  behaviour is unconditional auto-elaboration; defaulting on keeps every existing Execute
  byte-for-byte unchanged, but "default on vs off" is a genuine UX call the one-line description
  did not specify.
- [low] Wording is "Elaborate first" with a help tooltip. **Why:** matches the terse one-word
  sibling labels ("Deep", "Keep"); exact copy is a UX choice not specified by the source.
- [low] When "Elaborate first" is OFF, the existing `Deep` toggle is gated (hidden/disabled)
  because Deep only tunes the inline elaboration and is meaningless with no elaboration pass.
  **Why:** mirrors how `NewPlanModal` gates Deep behind its Elaborate toggle; research flagged
  this as an open question (parent-gate relationship), and gating is the consistent precedent —
  but it is a design decision, not a forced one.
- [low] The flag is threaded as a valueless `--no-elaborate`, emitted ONLY in the OFF case, so
  the default (ON) argv stays byte-identical to today. **Why:** inverting to a
  default-emitted `--elaborate-first` flag would change every existing execute argv and break
  the stable argument-shape tests; emitting only in the non-default case follows the orthogonal
  valueless-flag precedent of `--deep`/`--keep`/`--apply`, but the specific flag name/polarity
  was chosen here, not specified.
- [low] The checkbox is hidden for the `forReview` variant of `ExecutePendingModal` (a
  review-state plan is already elaborated, so there is nothing to gate), exactly as the Deep
  toggle already is. **Why:** `offersDeep(forReview:)` already establishes this hide-for-review
  precedent; applying it to the new checkbox is consistent, though not explicitly requested.

### Discovered during execution
- [high] Named the flag `--no-elaborate` / `noElaborate`, polarity = "present means SKIP",
  emitted ONLY in the OFF case. **Why:** matches the plan's byte-identical-default invariant and
  the orthogonal valueless-flag precedent of `--deep`/`--keep`/`--apply`; the default (absent)
  keeps the execute argv and prompt byte-for-byte as today.
- [high] Positioned `--no-elaborate` in `TaskRun.arguments(...)` AFTER the `--keep` block and
  BEFORE `--apply`/`--session`/`--resume`, and gated its emission on `mode == .execute` (a no-op
  for every other mode). **Why:** mirrors how `--keep` (execute-only) and `--apply` (discuss-only)
  are mode-scoped and ordered; keeps the argv order stable and predictable.
- [high] In `run-task.ts`, carried `noElaborate` only on the execute-capable `finish({...})`
  branch (`elaborate || execute || reElaborateReview`). It is inert for elaborate /
  reElaborateReview because only `buildExecutePrompt` (reached for execute mode) reads it.
  **Why:** matches how `deep`/`keep` are threaded on that same branch without special-casing.
- [low] In the `--no-elaborate` prompt branch I rephrased the gate reference from
  `"Execute anyway / Elaborate now"` to `the elaborate-first / execute-anyway question` so the
  OFF-case prompt never contains the literal substring "Elaborate now". **Why:** the Step-2 test
  asserts the OFF prompt does NOT contain "Elaborate now"; keeping the two-option label verbatim
  would have leaked that substring. The "Execute anyway" instruction is preserved and the ON-case
  prompt is byte-identical.
- [low] Did NOT run `npm run build` for `Tools/work-task/`. **Why:** `dist/` is gitignored and
  produced by `build.sh`/`install.sh` at release time (it needs the full SDK + a ~224M native
  package installed); the committed source is `run-task.ts`, and the sibling flags
  (`--deep`/`--keep`/`--apply`) ship the same way with no tracked `dist/`. The build step from the
  plan ("IF that is how the other flags are shipped") does not apply here.
- [low] Symlinked `Tools/work-task/node_modules` in the worktree to the main checkout's installed
  modules so the Node test's `import "./run-task.ts"` (which transitively imports the Agent SDK)
  resolves. The worktree had no `node_modules`; it is gitignored, so this is not committed.
  **Why:** running the touched Node test file requires the SDK import to resolve; a symlink is
  faster than a fresh `npm install` and the dependency tree is identical.
- [high] Gated the Deep toggle behind "Elaborate first" by DISABLING it (`.disabled(!elaborateFirst)`),
  not hiding it. **Why:** `NewPlanModal` gates its own Deep behind Elaborate with
  `.disabled(!elaborate)` (and Keep behind Execute the same way); matching that idiom keeps the
  sibling sheets consistent — Deep stays visible so the user sees it exists but greys out when
  there is no elaboration pass to tune.
- [high] Stale-Deep guard: `submit()` passes `deep: elaborateFirst ? deep : false` so a Deep that
  was toggled on and then orphaned by unchecking "Elaborate first" does NOT ride along into the
  run. **Why:** with no inline elaboration pass, Deep is meaningless; `.disabled` greys the control
  but leaves the stored `@State` value as-is, so the submit path must neutralise it explicitly.
  With the checkbox ON (default) `deep` is passed unchanged → byte-for-byte today's behaviour.
- [low] Both "Elaborate first" and Deep share the single `Self.offersDeep(forReview:)` predicate
  (two separate `if` blocks guarding the two toggles) rather than a new predicate. **Why:** both
  are pending-only and hidden for a review plan for the identical reason (a review plan is already
  elaborated); reusing the existing predicate keeps the hide-for-review condition in one place, as
  the plan's "reuse that same predicate" guidance preferred.

## Changes

### Segment 1 (steps 1–4) — flag plumbing + tests (TDD)
- **`Tests/PlansTests/TaskRunnerTests.swift`** (Step 1, RED→GREEN): added three argument-shape
  tests — `testArgumentsForExecuteWithNoElaborateEmitsFlagAfterKeep` (OFF case emits
  `--no-elaborate` after `--keep`, before `--session`/`--resume`),
  `testArgumentsForExecuteDefaultOmitsNoElaborate` (default ON → argv byte-identical to today),
  and `testArgumentsIgnoreNoElaborateForNonExecuteModes` (flag is execute-only, inert elsewhere).
- **`Tools/work-task/run-task.modes.test.ts`** (Step 2, RED→GREEN): added a test that a
  `--mode execute --no-elaborate` parse builds a prompt instructing "Execute anyway" and NOT
  "Elaborate now", plus a companion asserting the default execute prompt keeps "Elaborate now".
- **`Tools/work-task/run-task.ts`** (Step 3): added `noElaborate?: boolean` to `Args`; parse a
  valueless `--no-elaborate` alongside `--deep`/`--keep`; threaded it onto the execute-capable
  `finish({...})` branch; added a `noElaborate` parameter to `buildExecutePrompt` that branches
  requirement #2 between "Execute anyway" (skip elaboration) and the existing "Elaborate now"
  text (with `deep` wording only on the Elaborate-now branch); dispatcher passes
  `args.noElaborate ?? false`. Default (flag absent) prompt is byte-identical to today.
- **`Sources/Plans/TaskRunner.swift`** (Step 4): added `let noElaborate` to `TaskRun` (+ `init`
  default false); added `noElaborate: Bool = false` to `TaskRunner.run(...)` (passed into
  `TaskRun(...)`); added `noElaborate: Bool = false` to `TaskRun.arguments(...)`, emitting
  `["--no-elaborate"]` only when `mode == .execute && noElaborate`, positioned after `--keep` and
  before `--apply`/`--session`/`--resume`; threaded through the live spawn path
  (`start(...)` → `spawn(...)` → `arguments(...)`).
- **Tests:** `swift test --filter TaskRunnerTests` → 227 pass, 0 fail; `node --test
  run-task.modes.test.ts` → 28 pass, 0 fail. Default execute argv and prompt remain byte-identical.

### Segment 2 (steps 5–6) — the "Elaborate first" checkbox UI
- **`Sources/Plans/ExecutePendingModal.swift`** (Step 5): added `@State private var elaborateFirst
  = true` (defaults ON → #088's always-on auto-elaboration preserved; off is the opt-out). Added a
  `Toggle("Elaborate first", isOn: $elaborateFirst).toggleStyle(.checkbox)` with a `.help(...)`
  tooltip, placed in the existing Deep/Keep `HStack` BEFORE the Deep toggle so the gating parent
  reads left-to-right. Both "Elaborate first" and Deep are guarded by the existing
  `Self.offersDeep(forReview:)` predicate (hidden for the `forReview` variant). Gated Deep behind
  the new checkbox with `.disabled(!elaborateFirst)` — matching `NewPlanModal`'s
  `.disabled(!elaborate)` idiom (disable, not hide). `submit()` now passes
  `noElaborate: !elaborateFirst` into the existing `runner.run(... mode: .execute)` call, passes
  `deep: elaborateFirst ? deep : false` as the stale-Deep guard, and records `elaborateFirst` in
  the `executePendingLog.notice(...)` line. With the box left ON the call is byte-for-byte today's
  behaviour (`noElaborate: false`, `deep` unchanged).
- **Build (Step 6 prerequisite):** `swift build` → `Build complete!`, no errors. Provenance SHA
  unchanged before/after (`feature/133-auto-elaborate-on-execute-checkbox` @ `32f5653`). The live
  visual confirmation of Step 6 is DEFERRED to /plan-review (headless worktree hand-off).

## Notes
_Additional context_
