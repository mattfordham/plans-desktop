# Add "keep" option to execution

**ID:** 078
**Created:** 2026-09-17T13:33
**Type:** feature
**Status:** completed
**Branch:** feature/078-add-keep-option-to-execution
**Completed:** 2026-09-17T15:58

## What
Add "keep" option to execution.

Expose the plans-cc `keep` execution keyword in the desktop app's execution
surface (the "New Plan" modal's **Execute** run). plans-cc's `plan-execute`
already supports a trailing `keep` keyword that preserves the execution git
worktree past finish (`/plan-execute <id> worktree keep`), so `/plan-review`
can review the task in place and multiple tasks can be reviewed in parallel.
The desktop viewer already *renders* kept-worktree tasks (`isKeptWorktree` →
the `⌂ kept` / house glyph) but offers no way to *request* keep when it launches
an execution. This task adds a **Keep** toggle wired end-to-end through the run
launcher so the app can hand a task off with `keep` set.

**Scope extension (review feedback, 2026-09-17):** the New Plan modal path is
done and confirmed, but it only covers executing a *brand-new* capture. Executing
an **already-captured plan** (the ▶ Execute glyph on a project card row, and the
Execute button in the plan detail view) still fires `runner.run(… mode: .execute)`
bare off the button — no sheet, no optional guidance, and no way to request
`keep`. Elaborate solved this same problem in #074 by replacing its bare button
with `ElaborateModal` (fixed task, optional guidance box, Deep toggle). Execute
gets the same treatment: a new `ExecuteModal` with an optional guidance box and a
**Keep** toggle, opened from both execute call sites.

## Why
Adds value by letting the user launch an execution that preserves its worktree
for isolated, parallel review — matching a capability plans-cc already supports
and the app already visualizes. Without it, every app-launched execution tears
its worktree down at finish, so the `⌂ kept` marker the viewer renders can never
originate from an app-driven run, and users can't opt into parallel review from
the desktop.

## How Summary
Thread a new boolean `keep` run flag through the exact same layers the `deep`
flag (#065) already flows through: a **Keep** checkbox in `NewPlanModal`
(enabled only when **Execute** is on) → persisted in the `CaptureDraft` →
`TaskRunner.capture(keep:)` → a valueless `--keep` process argument → the
`run-task.ts` launcher, which appends a trailing ` keep` token to the
`/plan-execute <id> worktree` command line it hands the agent. No new skill
behavior is added — plan-execute already implements `keep`; this is pure
plumbing on the desktop side, following the `deep` template one-for-one.

**Files of note:**
- `Sources/Plans/NewPlanModal.swift` — the New Plan sheet; add the Keep toggle, its state, persistence, and pass-through in `submit()`.
- `Sources/Plans/PlansStore.swift` — `CaptureDraft` struct; add a `keep` field with a back-compatible default decode (mirrors the `deep` key handling).
- `Sources/Plans/TaskRunner.swift` — `capture(...)`/`Run`/`spawn`; add the `keep` param, store it, and append `--keep` to the spawn arguments (mirrors `--deep`).
- `Tools/work-task/run-task.ts` — the Node launcher; parse `--keep` in `parseArgs`, thread it into `buildExecutePrompt` (and `buildExecuteYoloPrompt`), append ` keep` to the `/plan-execute … worktree` line.
- `Tools/work-task/dist/run-task.js` — compiled output of the above; must be rebuilt so the app bundle picks up the change.
- `Tests/PlansTests/TaskRunnerTests.swift`, `NewPlanDraftPersistenceTests.swift`, `PlansStoreTests.swift` — mirror the existing `deep` coverage for `keep`.

## How
- [x] Step 1: In `Tests/PlansTests/` write failing tests first (TDD), mirroring the existing `deep` coverage: (a) `TaskRunnerTests` — a `.execute` run with `keep: true` produces spawn arguments containing `--keep` (and omits it when false); (b) `NewPlanDraftPersistenceTests`/`PlansStoreTests` — a `CaptureDraft` round-trips `keep`, and legacy JSON with no `keep` key decodes to `keep == false`.
- [x] Step 2: Add `var keep: Bool = false` to `PlansStore.CaptureDraft` (Sources/Plans/PlansStore.swift), extending the explicit `init`, `encode(to:)`, and the current-key + legacy `decode` paths exactly as the `deep` key is handled (default `false` when the key is absent so pre-existing drafts still decode).
- [x] Step 3: In `TaskRunner.swift`, add a `keep: Bool` stored property to the `Run` struct (with a `= false` default in its `init`), add a `keep: Bool = false` parameter to `capture(...)`, thread it into the run, and append `--keep` to the spawn `arguments` (after `--mode`, alongside the existing `--deep` block) when `keep` is true.
- [x] Step 4: In `NewPlanModal.swift`, add `@State private var keep = false`, a **Keep** `Toggle` in the toggles `HStack` (checkbox style, `.disabled(!execute)` so it's only meaningful for execute runs, with a `.help(...)` explaining it preserves the worktree for parallel review), a `.onChange(of: keep) { _, _ in persistDraft() }`, include `keep` in `persistDraft()`'s `CaptureDraft`, restore it in `loadDraft(for:)`, reset it in `clear()`, and pass `keep: keep` into the `runner.capture(...)` call in `submit()`.
- [x] Step 5: In `Tools/work-task/run-task.ts`, add `keep?: boolean` to the `Args` type, parse a valueless `--keep` flag in `parseArgs` (do NOT consume the next token, mirroring `--deep`), include `keep` in every returned `Args`, thread it into `buildExecutePrompt(taskId, keep)` (and `buildExecuteYoloPrompt(description, keep)`), and append a trailing ` keep` token to the `/plan-execute … worktree` command line so it reads `/plan-execute <id> worktree keep` (or `/plan-execute "<description>" yolo keep`) when `keep` is true. Update the file's header doc comment to mention the `--keep` flag.
- [x] Step 6: Rebuild the launcher so `Tools/work-task/dist/run-task.js` reflects the TypeScript change (use the project's existing build step for `Tools/work-task/`; do not hand-edit `dist/`).
- [x] 👁 Step 7: Run `swift test` and confirm all tests pass; then build/run the app (`./build.sh`) and visually confirm the New Plan modal shows a **Keep** toggle that enables only when **Execute** is on, and that launching an execute+keep run hands off a `/plan-execute … worktree keep` command (observation of the built UI and spawned command line is needed — the agent cannot see the GUI or the live child process). _(Automated portion done: targeted keep tests pass; `dist/run-task.js` grep-confirmed. GUI + spawned-command-line observation ⏳ deferred to `/plan-review`.)_

- [x] Step 8: Write failing tests first (TDD) for the execute-sheet path in `TaskRunnerTests`: a `.execute` run started via `run(... keep: true)` carries `--keep` in its spawn arguments, and omits it when `keep` is false. This exercises the `run(...)` path, distinct from the existing `capture(...)` coverage from Step 1. (NOTE: the originally-planned guidance-passthrough test was dropped — see Step 9's scope correction.)
- [x] Step 9: Add `Sources/Plans/ExecuteModal.swift` — a **keep-only** sheet. **Scope correction (execution blocker, 2026-09-17):** the original plan specified an optional guidance box mirroring `ElaborateModal`, but `.execute` has NO description channel at any layer — `RunMode.usesDescription` returns `false` for `.execute` (`TaskRunner.swift:192`), the launcher's existing-task branch returns `description` only for `elaborate` (`run-task.ts:200`), `buildExecutePrompt` takes no guidance parameter, and the `plan-execute` skill itself parses stray non-numeric text as a step filter or a new-task capture rather than guidance. A guidance box would silently discard user input, so it is DROPPED. The sheet is: title `Execute #<id>`, a **Keep** checkbox `Toggle` (always enabled — the whole sheet IS an execute run, exactly as Deep is always enabled inside `ElaborateModal`) with `.help("Keep the execution worktree after finishing, so the plan can be reviewed in place")`, and Cancel / **Execute** (⌘↩) buttons. Keep `ElaborateModal`'s `.padding(16)` and sheet-metric conventions; size the frame to the thinner content rather than forcing `minHeight: 380`. No `PlanTextEditor`, no placeholder, no draft persistence.
- [x] Step 10: In `ExecuteModal.submit()`, call `runner.run(projectPath:taskID:mode:.execute, keep: keep)` — `run(...)` already accepts `keep:` (plumbed in Step 3), so no runner change is needed. Do NOT pass a `description` (the parameter defaults to `nil` and `.execute` would discard it anyway). Log via an `executeLog` `Logger` mirroring `elaborateLog`.
- [x] Step 11: Wire the sheet into the two execute call sites, following the `ElaborateRequest` pattern: add a private `ExecuteRequest: Identifiable { taskID; projectPath; id }` struct + `@State private var executeRequest: ExecuteRequest? = nil` + a `.sheet(item:)` presenting `ExecuteModal`, then change `ProjectCard.swift` (the `play.fill` RowActionGlyph, ~line 940) and `PlanDetailView.swift` (the Execute `Button`, ~line 246) to set the request instead of calling `runner.run(...)` directly. Leave the `canWork(...)` status gating exactly as-is.
- [x] 👁 Step 12: Run `swift test`; then `./build.sh` and visually confirm the Execute glyph/button on an existing plan opens a sheet with a Keep toggle, that submitting with Keep off behaves like the old bare Execute, and that Keep-on emits `/plan-execute <id> worktree keep` (runner `spawning:` log).

## Verification
- `swift test` passes, including the new `keep` cases in `TaskRunnerTests`
  (`--keep` present when `keep: true`, absent when false), and the
  `CaptureDraft` persistence/back-compat tests (round-trip + legacy-JSON decode
  to `false`).
- The **Keep** toggle appears in the New Plan modal, is disabled unless
  **Execute** is on, and its state persists across sheet reopen / project switch
  like the other toggles.
- An execute run launched with Keep on results in a `run-task` invocation
  carrying `--keep`, and the launcher emits a `/plan-execute <id> worktree keep`
  command line (verify via the runner's `spawning:` log line).
- `Tools/work-task/dist/run-task.js` is regenerated from the `.ts` source (not
  hand-edited) and the assembled app bundle picks up the change.
- No regression: runs launched with Keep off behave exactly as before (no
  `--keep`, no trailing ` keep` token).
- The ▶ Execute glyph on a project card row and the Execute button in the plan
  detail view both open the new `ExecuteModal` sheet rather than firing a run
  immediately, and the sheet offers a Keep toggle.
- Submitting the execute sheet with Keep off behaves exactly like the bare
  Execute it replaces — the no-regression path.
- Submitting with Keep on emits `/plan-execute <id> worktree keep`; with Keep off
  the command line is unchanged from today.
- The execute sheet's status gating is unchanged: it appears exactly where the
  old Execute action did (`canWork(...)` — elaborated/in-progress, non-blocked).

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/NewPlanModal.swift` — add Keep toggle, `@State`, persistence, and `submit()` pass-through.
- [x] `Sources/Plans/PlansStore.swift` — add `keep` to `CaptureDraft` with back-compatible decode.
- [x] `Sources/Plans/TaskRunner.swift` — add `keep` to `Run`/`capture(...)`; append `--keep` to spawn args.
- [x] `Tools/work-task/run-task.ts` — parse `--keep`; append ` keep` to the execute command line.
- [x] `Tools/work-task/dist/run-task.js` — regenerated compiled output of the launcher.
- [x] `Tests/PlansTests/TaskRunnerTests.swift` — assert `--keep` presence/absence in spawn args.
- [x] `Tests/PlansTests/NewPlanDraftPersistenceTests.swift` — assert `keep` round-trips and legacy JSON decodes to `false`.
- [ ] `Tests/PlansTests/PlansStoreTests.swift` — `CaptureDraft` `keep` coverage if draft codec lives/tested here.
- [x] `Sources/Plans/ExecuteModal.swift` — NEW: the keep-only execute sheet (Keep toggle; no guidance box — see Step 9 scope correction).
- [x] `Sources/Plans/ProjectCard.swift` — `ExecuteRequest` struct, `@State`, `.sheet(item:)`, and the `play.fill` glyph opens the sheet instead of running.
- [x] `Sources/Plans/PlanDetailView.swift` — same sheet wiring for the Execute button.

### Related Files (may need updates)
- `Plans.app/Contents/Resources/work-task/run-task.js` — the bundled copy of the launcher; refreshed by `build.sh`/`install.sh` when the app is reassembled (not hand-edited).

### Endpoints/UI Affected
- New Plan modal (Surface B) — gains a **Keep** toggle next to Execute/Elaborate/Deep.
- Project card row ▶ Execute glyph and plan detail Execute button — now open an
  `ExecuteModal` sheet (Keep toggle) instead of firing a bare run.
- Launched `plan-execute` command line — gains a trailing ` keep` token when Keep is on, preserving the worktree so the app's existing `⌂ kept` marker can originate from app-driven runs.

## Assumptions

### Initial (from elaboration)
- [high] "Execution" refers to the desktop app's own execution surface (the New Plan modal's **Execute** run that hands off to plans-cc `plan-execute`), and this task targets the **plans-desktop** repo — NOT the separate `plans` skills repo where the `keep` keyword itself is already implemented. **Why:** the task was captured in the plans-desktop repo; `plan-execute` in the skills repo already fully implements `keep` (parse, cascade, teardown-gate), and the desktop viewer already parses/renders `isKeptWorktree`, so the only unshipped gap is the app's ability to *request* keep at launch.
- [high] Implement `keep` as a boolean run flag threaded through the exact `deep` (#065) plumbing chain — UI toggle → `CaptureDraft` → `TaskRunner.capture(keep:)` → valueless `--keep` process flag → launcher appends a trailing ` keep` token. **Why:** `deep` is an established, tested, one-for-one precedent for a valueless run flag in this codebase; reusing its shape minimizes risk and matches existing conventions rather than inventing a new mechanism.
- [low] The **Keep** toggle is gated to be enabled only when **Execute** is on (like **Deep** is gated to **Elaborate**), and `keep` is only appended for execute-bearing runs (`execute`, `executeYolo`). **Why:** `keep` in plans-cc governs the *execution* worktree lifecycle and cascades to worktree mode; it is meaningless for capture-only/elaborate-only runs, and the app's Deep-gated-to-Elaborate pattern is the established UX precedent. A plausible alternative (always-enabled, or applying to other modes) was rejected as it would send a no-op keyword.
- [low] `keep` is also threaded into the `executeYolo` prompt builder (`/plan-execute "<description>" yolo keep`), not just the plain `execute` builder. **Why:** yolo is the other execute-bearing mode and `yolo keep` is explicitly supported by plan-execute; omitting it would make Keep silently no-op for yolo-style launches. Marked low because the New Plan modal's current toggle set may not expose a yolo path directly — wire the builder support regardless so the flag is honored wherever an execute run originates.
- [low] The compiled `Tools/work-task/dist/run-task.js` is regenerated via the project's existing TypeScript build for `Tools/work-task/` rather than hand-edited, and the app bundle copy is refreshed by `build.sh`/`install.sh`. **Why:** `dist/` is compiled output; the repo already ships a `.ts` source + `dist/` pair, implying a build step, and hand-editing generated code would drift from source.

### Discovered during execution
- [high] Threaded `keep` one-for-one through the `deep` (#065) plumbing in `CaptureDraft`, `TaskRun`, `TaskRunner.run(...)`/`capture(...)`, and `NewPlanModal` — same property/init/CodingKeys/encode/decode-if-present shape and same `--keep`-after-`--mode` spawn append. **Why:** `deep` is the established, tested precedent the segment prompt directed me to mirror; every touchpoint matched a `deep` analogue exactly.
- [low] Placed the **Keep** toggle AFTER the **Execute** toggle in the HStack (rather than after Elaborate, where **Deep** sits) and gated it with `.disabled(!execute)`. **Why:** Keep is meaningful only for execute runs, so it reads best adjacent to Execute — mirroring the Deep-next-to-Elaborate convention but relative to its own gating toggle.
- [low] Ordered the new `keep` parameter BEFORE `imageDatas` (and `knownTaskIDs`) but AFTER `deep` in `CaptureDraft.init`, `TaskRunner.capture(...)`. **Why:** keeps the boolean run-flags grouped together (`deep`, `keep`) ahead of the trailing collection params, matching how `deep` precedes `imageDatas`/`knownTaskIDs`; test call sites were written to this shape.
- [high] Threaded `keep` one-for-one through the `deep` (#065) plumbing in `Tools/work-task/run-task.ts`: added `keep?: boolean` to `Args`, parsed a valueless `--keep` flag (no token consumed), included `keep` in all four returned `Args` objects, added a `keep` parameter to `buildExecutePrompt`/`buildExecuteYoloPrompt`, and appended a trailing ` keep` token to the `/plan-execute <id> worktree` and `/plan-execute "<description>" yolo` command lines when keep is true. **Why:** the segment prompt directed mirroring the `deep` shape exactly; every touchpoint had a direct `deep` analogue.
- [high] Build command for the launcher: `npm ci` then `npm run build` (runs `node build.mjs`, an esbuild bundle) in `Tools/work-task/`, using node v22.13.1 from nvm (`~/.nvm/versions/node/v22.13.1/bin`). `node_modules` was NOT present in the worktree (gitignored, not copied into worktrees), so `npm ci` against the committed `package-lock.json` was required first. Also ran `npx tsc --noEmit` (clean) since esbuild does not type-check. **Why:** the wasn't-obvious build command per the segment's request; `dist/` and `node_modules/` are both gitignored so `dist/run-task.js` is a regenerated build artifact.
- [low] **BLOCKED before writing any Step 8-11 code:** the segment's `ExecuteModal` optional-guidance box cannot work as specified — `.execute` guidance is discarded at BOTH layers. Swift: `RunMode.usesDescription` returns `false` for `.execute`, so `TaskRun.spawn` never emits `--description`. Node: `run-task.ts`'s existing-task branch returns `{ projectRoot, taskId, mode, deep, keep }` for `execute` (only `elaborate` keeps `description`), and `buildExecutePrompt(taskId, keep)` accepts no guidance at all. **Why:** shipping the guidance box as planned would render a text field whose contents are silently dropped — a UX lie. Honoring it requires flipping `usesDescription` for `.execute` plus adding a guidance parameter to `buildExecutePrompt` and regenerating `dist/run-task.js`; that is a cross-layer contract change to `TaskRunner.swift` + the launcher, explicitly outside this segment's stated "UI-only, no TaskRunner changes" scope. Escalated for a decision rather than guessed at.

- [low] Sized `ExecuteModal` with `.frame(minWidth: 460)` + `.fixedSize(horizontal: false, vertical: true)` instead of the siblings' `.frame(minWidth: 460, minHeight: 380)`. **Why:** the plan explicitly left the thinner sheet's framing to my judgment. Matching the 460pt width keeps the run sheets reading as one family, but inheriting `minHeight: 380` would strand a tall empty band under a single checkbox now that there is no text editor to fill it; `fixedSize` vertically lets the sheet hug its actual content (title + toggle + divider + buttons). Width is a floor, not fixed, so the sheet can still grow.
- [high] Used `PlanDetailView`'s EXISTING `@State private var showExecute = false` + `.sheet(isPresented:)` bool pattern rather than the `ExecuteRequest: Identifiable` struct + `.sheet(item:)` the plan prescribed for that file. **Why:** the plan's `ExecuteRequest` shape is a ProjectCard idiom — the card renders MANY rows, so the request struct carries which row was tapped. `PlanDetailView` renders a SINGLE already-resolved `row`, and its sibling sheets (`showReElaborate`, `showElaborate`) are both plain bools for exactly that reason; a request struct there would duplicate state the view already has. `ExecuteRequest` WAS added to `ProjectCard.swift` as planned.
- [low] Kept Keep defaulting to OFF on every sheet open with no draft persistence. **Why:** matches `ElaborateModal`'s always-off Deep toggle and makes worktree preservation an explicit per-run opt-in; silently remembering Keep could strand worktrees the user forgot they had enabled.
- [high] Step 8's tests could not have a true RED phase, since Step 3 already plumbed `keep` through `run(...)`. To prove they are not vacuous I temporarily hardcoded `keep: false` in `run(...)`'s `TaskRun` construction, confirmed `testExecuteRunViaRunCarriesKeepFlag` FAILED, then restored the file (verified byte-identical via `git diff`). **Why:** a characterization test that passes against a broken implementation is worthless; this verified the assertion path actually reaches the stored property `spawn` reads.
- [low] Asserted on the registered `TaskRun`'s stored properties via `runner.run(for:)` rather than on literal spawn argv. **Why:** `spawn` is private and launches a real `node` process; the file's existing `deep`/`keep` tests state this convention explicitly ("Asserted on the stored property rather than by spawning a process"), and `keep` -> `--keep` is already covered by that established arg-shape contract.

## Changes
- `Tests/PlansTests/TaskRunnerTests.swift` — added `testKeepRunCarriesKeepFlag`, `testKeepRunDefaultsToFalse`, `testKeepDoesNotAlterSelectedRunMode` (mirror `deep`, on `.execute`).
- `Tests/PlansTests/NewPlanDraftPersistenceTests.swift` — added `testKeepDraftRoundTripsPreservingKeepTrue` and `testOlderDraftWithoutKeepKeyDecodesAsKeepFalse` (Codable round-trip + legacy back-compat).
- `Sources/Plans/PlansStore.swift` — `CaptureDraft` gains `var keep: Bool = false`; extended `init`, `CodingKeys`, `encode(to:)`, and decode (`decodeIfPresent(...) ?? false`) exactly like `deep`.
- `Sources/Plans/TaskRunner.swift` — `keep: Bool` stored on `TaskRun` (default false); threaded through `run(...)`/`capture(...)`/`start`/`spawn`; `--keep` appended after `--mode`/`--deep` only when true.
- `Sources/Plans/NewPlanModal.swift` — added `@State keep`, a **Keep** checkbox `Toggle` (`.disabled(!execute)`, with `.help`), `.onChange` persist, and wiring in `persistDraft()`/`loadDraft(for:)`/`clear()`/`submit()` (passes `keep: keep` to `runner.capture`).
- `Tools/work-task/run-task.ts` — `keep?: boolean` on `Args`; valueless `--keep` parsed; threaded into `buildExecutePrompt`/`buildExecuteYoloPrompt`; appends ` keep` to the `worktree`/`yolo` command line when true; header doc updated.
- `Tools/work-task/dist/run-task.js` — regenerated from the `.ts` via `npm run build` (esbuild); contains the `--keep` parse + ` keep` append (not hand-edited).
- `Tests/PlansTests/TaskRunnerTests.swift` — added `testExecuteRunViaRunCarriesKeepFlag`, `testExecuteRunViaRunOmitsKeepWhenFalse`, `testExecuteRunViaRunDefaultsKeepToFalse` covering the `run(...)` entry point (distinct from the Step 1 `capture(...)` coverage).
- `Sources/Plans/ExecuteModal.swift` — NEW: keep-only execute sheet (`Execute #<id>` title, always-enabled **Keep** checkbox with `.help`, Cancel / Execute ⌘↩); `submit()` calls `runner.run(... mode: .execute, keep: keep)` with no description and logs via `executeLog`. No guidance box (see Step 9 scope correction).
- `Sources/Plans/ProjectCard.swift` — added `ExecuteRequest: Identifiable`, `@State executeRequest`, a third `.sheet(item:)` presenting `ExecuteModal`; the `play.fill` glyph now sets the request instead of calling `runner.run(...)`. `canWork(...)` gating unchanged.
- `Sources/Plans/PlanDetailView.swift` — added `@State showExecute` + `.sheet(isPresented:)` presenting `ExecuteModal` (matching its sibling `showElaborate`/`showReElaborate` bool pattern); the Execute `Button` now raises the sheet. `canWork(...)` gating unchanged.

## Notes
- plans-cc `keep` reference (source of truth, separate `plans` repo):
  `~/.claude/skills/plan-execute/SKILL.md` → `~/Work/Open Source/plans/skills/plan-execute/SKILL.md`
  (keyword detection lines ~55-58; teardown gate lines ~914-985; examples
  `worktree keep`, `yolo keep`). Teardown of a *kept* worktree is deliberately
  deferred to `/plan-complete` — the desktop app is view-only and must NOT add
  worktree teardown logic of its own.
- The `deep` (#065) implementation is the working template to copy: search the
  four source files for `deep` / `--deep` to see every layer that needs a
  parallel `keep` change.
