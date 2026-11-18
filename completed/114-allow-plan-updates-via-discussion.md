# Allow Plan Updates Via Discussion

**ID:** 114
**Created:** 2026-11-09T13:48
**Type:** feature
**Status:** completed
**Branch:** feature/114-allow-plan-updates-via-discussion
**Completed:** 2026-11-10T10:35

## What
Plan discussion is currently read-only. It should allow for updates to plan via discussion

## Why
Adds value by letting the user turn a discussion into an edit: today a plan's discussion can only *answer questions* about a plan, never change it, even though the underlying `plan-discuss` skill already supports applying agreed changes on request. Un-suppressing that capability — behind an explicit, opt-in affordance — lets a user refine a plan (tweak the How checklist, Why, Verification, …) in-app through conversation instead of dropping to the CLI.

## How Summary
The app is **not** a read-only viewer — it already shells out to a bundled Node Agent-SDK runner (`Tools/work-task/run-task.ts`) that drives plans-cc skills and writes `.plans/` files for execute/elaborate/capture/etc. Discussion is the *one* mode deliberately locked read-only, in two enforcement points inside the runner (an edit-forbidding prompt + a read-only tool allowlist). This change adds an **opt-in "apply" variant of a discuss turn**: a new orthogonal flag threaded Swift → runner that (a) swaps the discuss prompt for one that *permits* applying the agreed change and (b) swaps the read-only allowlist for a write-capable one, while the default discuss path stays byte-for-byte read-only. On the Swift side the applying turn's `onFinish` additionally triggers a `store.reload()` so the detail column repaints the edited plan, and a new tighter gate restricts the apply affordance to quiescent statuses. Scope is the **per-plan** detail discussion only; the whole-project/backlog discuss (#110) stays read-only.

**Files of note:**
- `Tools/work-task/run-task.ts` — the sole writer of `.plans/`; holds the two read-only enforcement points (`buildDiscussPrompt`/`buildDiscussFollowUpPrompt` ~797–857; `DISCUSS_ALLOWED_TOOLS`/`DISCUSS_DISALLOWED_TOOLS` ~1084–1096, wired ~1145–1163) and the `parseArgs` flag table (~170–191).
- `Sources/Plans/TaskRunner.swift` — `RunMode`/`usesTaskID`/`usesDescription` (~185–266), `TaskRun.arguments` argv builder (~652), the `mode != .discuss` reload-skip in `finish()` (~989), and `ask`/`launchDiscuss` (~1498–1549) whose `onFinish` must reload for an applying turn.
- `Sources/Plans/PlanDetailView.swift` — per-plan composer (`discussFooter` ~605), `submitDiscussion` (~663) calling `runner.ask`, the `canDiscuss` gate (~1241), and the `store.reload()` hook already used by lifecycle actions (~814).
- `Sources/Plans/ProjectDiscussionView.swift` — the whole-project discuss sheet; verify it stays read-only (out of scope for writes).
- `Tools/work-task/build.mjs` — esbuild step that regenerates the gitignored `dist/run-task.js` from the `.ts`; the edited runner has no runtime effect until this runs.
- `Tests/PlansTests/TaskRunnerTests.swift` — arg-shape unit tests (`TaskRun.arguments`, ~2259); add the new-flag cases here TDD-first.

## How
- [x] Step 1: **(TDD, red)** Add failing arg-shape tests to `Tests/PlansTests/TaskRunnerTests.swift` mirroring `testArgumentsForProjectDiscussEmitsTaskIDWhenIDNonEmpty`: a `.discuss` run with the new apply flag set emits the apply flag (e.g. `--apply`) after `--mode discuss`, and a normal `.discuss` run omits it entirely (default read-only path unchanged). Decide the flag's surface: either a new valueless `--apply` flag threaded through `TaskRun.arguments` (preferred — orthogonal, mirrors `--deep`/`--keep`), or a distinct `RunMode` case. Keep it unit-testable without spawning a process.
- [x] Step 2: **(green)** Thread the apply flag through the Swift launch path in `Sources/Plans/TaskRunner.swift`: extend `TaskRun.arguments(...)` (append the valueless flag AFTER `--mode`, only when `mode == .discuss` and apply is set, matching the `--resume`/`--deep` pattern), and carry it on `TaskRun` + through `ask`/`launchDiscuss`. Add an `apply:` parameter (defaulting false) so every existing call site stays read-only unchanged.
- [x] Step 3: In `Tools/work-task/run-task.ts`, teach `parseArgs` the new flag (follow the `--deep`/`--keep` valueless-flag pattern ~185–191) and add it to the `Args` type. Guard it: it is only meaningful alongside `--mode discuss`.
- [x] Step 4: In `run-task.ts`, when the discuss run is apply-enabled: (a) build a discuss prompt variant (parallel to `buildDiscussPrompt`/`buildDiscussFollowUpPrompt`) that *permits* applying the agreed change to the plan file via `plan-discuss` instead of forbidding it; and (b) in the allowlist wiring (~1145–1163) use a write-capable allowlist (reuse `BASE_ALLOWED_TOOLS` + `Skill`, plus `readExtraAllowedTools`) and DROP the `DISCUSS_DISALLOWED_TOOLS` block for that run only. Leave the default (non-apply) discuss branch byte-for-byte unchanged — verify the read-only path still omits Write/Edit/Bash.
- [x] Step 5: In `Sources/Plans/TaskRunner.swift`, make an applying discuss turn reconcile on completion: extend `launchDiscuss`'s `onFinish` (or the `finish()` path) so that when the turn was apply-enabled it triggers a `store.reload()` (the same hook lifecycle actions use, e.g. `PlanDetailView.swift:814`) after `completeTurn`, so the `.id(selectedRowID)`-keyed detail column repaints the edited plan. A plain read-only turn must still trigger NO reload (preserve the `mode != .discuss` intent). Thread the store/reload closure in the same way existing mutating runs do; do not introduce a second `PlansStore`.
- [x] Step 6: Add the opt-in UI affordance to the per-plan composer in `Sources/Plans/PlanDetailView.swift` (`discussFooter` ~605 / `submitDiscussion` ~663): an explicit "Apply changes" control (toggle or a second send action) that routes through `runner.ask(..., apply: true)` only when deliberately engaged — the default send stays read-only Q&A. Gate the apply affordance behind a new, tighter pure predicate (e.g. `canApplyViaDiscussion(status:isBlocked:isBacklogged:)`) that mirrors `canBacklog`'s safety reasoning: permit `pending`/`elaborated` only; block `in-progress`/`in-review`/`completed`/blocked/backlogged so a single click can never rewrite a plan mid-execution. Add pure-predicate unit tests for it (TDD) alongside the existing `canDiscuss`/`canBacklog` tests. Follow the #096 layout constraint — no self-measuring/`GeometryReader`-into-layout in the new control.
- [x] Step 7: Rebuild the bundled runner (`node Tools/work-task/build.mjs` or the app-build step) so `dist/run-task.js` reflects the `.ts` edits, then `swift build` and `swift test` — confirm all new and existing tests pass and the default discuss path is unchanged. Confirm `Sources/Plans/ProjectDiscussionView.swift` (whole-project discuss) still has no apply path and remains read-only.

## Verification
- `swift test` passes, including the new arg-shape tests (apply flag emitted only when set; default discuss run emits no apply flag) and the new `canApplyViaDiscussion` predicate tests.
- Default (non-apply) discuss behavior is unchanged: the read-only allowlist still omits Write/Edit/Bash, the prompt still forbids edits, and a plain discuss turn triggers no `store.reload()`.
- With apply engaged on a `pending`/`elaborated` plan, a discussion that agrees a change writes the edit to the `.plans/*.md` file (via the plans-cc skill, never a Swift writer) and the detail column repaints the updated plan after the turn finishes.
- The apply affordance is NOT offered for `in-progress`/`in-review`/`completed`/blocked/backlogged plans, and the whole-project/backlog discuss sheet remains read-only (no apply control, no write allowlist).
- `dist/run-task.js` is rebuilt from the edited `.ts` (the change has no runtime effect otherwise).

## Impact Scope

### Files to Modify
- [ ] `Tools/work-task/run-task.ts` — add apply flag to `parseArgs`/`Args`; add an apply-permitting discuss prompt variant; use a write-capable allowlist and drop `DISCUSS_DISALLOWED_TOOLS` for apply runs only.
- [ ] `Sources/Plans/TaskRunner.swift` — thread the apply flag through `TaskRun`/`arguments`/`ask`/`launchDiscuss`; trigger `store.reload()` on an applying turn's finish while keeping plain discuss reload-free.
- [ ] `Sources/Plans/PlanDetailView.swift` — opt-in "Apply changes" composer control; new `canApplyViaDiscussion` gate; route through `runner.ask(..., apply: true)`.
- [ ] `Tests/PlansTests/TaskRunnerTests.swift` — new arg-shape tests for the apply flag (and predicate tests, unless placed in a PlanDetailView-focused test file).

### Related Files (may need updates)
- `Tools/work-task/build.mjs` — no code change, but must run to regenerate `dist/run-task.js`.
- `Sources/Plans/ProjectDiscussionView.swift` — verify it stays read-only (no apply path); no change intended.
- `Sources/Plans/DiscussionThread.swift` — reused as-is; only touched if the transcript needs to surface an "applied" indicator (optional, not required for the core feature).

### Endpoints/UI Affected
- Per-plan detail column discuss composer (Surface B) — gains an opt-in "Apply changes" control, gated to quiescent statuses.
- Whole-project/backlog discuss sheet (#110) — unchanged, stays read-only.

## Assumptions

### Initial (from elaboration)
- [high] Scope of "update via discussion" = applying agreed edits to the **plan markdown** (How/Why/Verification/etc.), the natural reading of the title. **Why:** `plan-discuss`'s own description says it can "apply agreed changes on request," and the runner's existing comment notes `plan-discuss` "can apply changes to a plan on request, but it must NOT here" — so the capability already exists and is merely suppressed.
- [high] All writes route through the existing Node runner / plans-cc skills — no Swift-side `.plans/*.md` writer is added. **Why:** `run-task.ts` is the app's sole writer of `.plans/` and git by firm convention (CLAUDE.md spirit); `RegistryWriter.swift` writes only the registry, never task content. A Swift markdown writer would fork the plans-cc contract.
- [low] The apply capability is **opt-in via an explicit UI control** (toggle/second send action), not inferred by the agent from question phrasing. **Why:** skip-mode auto-pick of the safer option; matches the app's established "a deliberate click is the human gate" pattern (delete/backlog), and keeps the read-only default intact. Alternative (agent decides from phrasing) was rejected as less safe.
- [low] Scope is the **per-plan** detail discussion only; the whole-project/backlog discuss (#110) stays read-only. **Why:** skip-mode scope decision; a backlog-wide apply could rewrite many plan files at once (#110 flagged this risk as `[high]`), so writes are deliberately narrowed to a single, selected plan first.
- [low] The apply affordance is gated by a new predicate permitting `pending`/`elaborated` only, blocking `in-progress`/`in-review`/`completed`/blocked/backlogged. **Why:** skip-mode auto-pick mirroring `canBacklog`'s safety reasoning — prevents a single click from rewriting a plan mid-execution or after review. `canDiscuss` is intentionally permissive and reused unchanged for read-only Q&A.
- [low] The flag is implemented as a valueless `--apply` flag orthogonal to mode (like `--deep`/`--keep`), rather than a new `RunMode` case. **Why:** skip-mode auto-pick; it keeps `TaskRun.arguments` unit-testable and reuses the established orthogonal-flag pattern. A dedicated `RunMode` is a viable alternative if the prompt/allowlist branch grows large.
- [low] No `**Build:**` route is seeded: the project has no `design-system/` directory, so the design-system build-skill routing trigger does not apply. **Why:** `/plan-execute` routing to `des-build` only applies to design-system component work; this is a Swift/TypeScript app feature.

### Discovered during execution
- [high] `apply` is appended as the LAST parameter of `TaskRun.arguments(...)` with a default `apply: Bool = false` (after `resume:`). **Why:** every existing test and caller passes the prior parameters positionally through `resume:`; appending a defaulted trailing param keeps all positional call sites compiling unchanged, while new call sites use the `apply:` label. Inserting it earlier would shift `resume` positionally and break callers.
- [high] In the argv builder, `--apply` is emitted only when `mode == .discuss && apply`, placed AFTER the `--deep`/`--keep` block and BEFORE `--resume`. **Why:** matches the spec'd arg order and the orthogonal-flag pattern; keeps a resumed apply turn emitting `--apply` ahead of `--resume` so ordering is stable/predictable.
- [low] Added BOTH an apply first-turn prompt (`buildApplyDiscussPrompt`) AND an apply follow-up prompt (`buildApplyDiscussFollowUpPrompt`), dispatched by the resume/first-turn split just like the read-only pair. **Why:** a resumed apply discuss turn needs the may-apply constraints restated every turn so they can't drift; mirroring the existing read-only pair is the least-surprising structure.
- [low] Apply-prompt wording: the agent MAY apply the agreed change via `plan-discuss` ONLY when the user's message asks for it; a pure question still leaves the plan untouched; it must only ever touch the single scoped task's file, works fully autonomously, and asks no questions. **Why:** keeps the opt-in write narrowly scoped to the per-plan file and preserves the unattended/no-questions contract shared with the read-only prompt.
- [high] Apply-discuss allowlist reuses the non-discuss `BASE_ALLOWED_TOOLS` + `readExtraAllowedTools(projectRoot)` (deduped) and applies NO `DISCUSS_DISALLOWED_TOOLS` block; the default read-only discuss branch is left byte-for-byte unchanged (`DISCUSS_ALLOWED_TOOLS` + `DISCUSS_DISALLOWED_TOOLS`). **Why:** the spec requires the apply path be write-capable (incl. `Skill`) while the default discuss stays exactly read-only. `baseExtraAllowed` is now computed unconditionally (a harmless extra config read for read-only discuss) but is not passed into the read-only discuss's options, so that path's behavior is unchanged.
- [high] Reload-on-apply is threaded as an optional `onApplied: (() -> Void)? = nil` closure parameter on `ask`/`launchDiscuss` rather than giving `TaskRunner` a `PlansStore` reference. **Why:** `TaskRunner` holds no store (single-shared-store rule), so the view supplies the reconcile action; the view passes `onApplied: { store.reload() }` only on the apply path. `onApplied` fires in `onFinish` ONLY when `apply == true` AND `taskRun.error == nil`, so a read-only turn and a failed apply turn both stay reload-free — today's read-only behavior is byte-for-byte preserved. `askProject` keeps the defaults (no apply, no onApplied) and so remains read-only.
- [low] The Apply affordance is a SECOND button in the composer (`square.and.pencil` glyph, help "Apply changes to this plan"), rendered only when `canApplyViaDiscussion(...)` is true and the composer is not showing Stop, enabled on the same `canSend` predicate as Send. **Why:** a dedicated explicit control (vs. a mode toggle) keeps the default Return/Send strictly read-only and makes the write opt-in unmistakable; it routes through a separate `submitApplyDiscussion(row)` that re-guards `canApplyViaDiscussion` so a stale click can't fire for a now-ineligible plan, mirroring how `submitDiscussion` re-guards `canDiscuss`.
- [high] `canApplyViaDiscussion(status:isBlocked:isBacklogged:)` mirrors `canBacklog`'s gating (pending/elaborated only) but ALSO withholds on blocked/backlogged (guards first, like `canExecutePending`). Its predicate tests live in `Tests/PlansTests/PlanDetailViewTests.swift` alongside the `canBacklog`/`canDiscuss` tests. **Why:** an applying turn is write-capable, so it follows the work gates (blocked/backlogged withheld) rather than the deferral gate; the test file is where every sibling predicate is already covered.

## Changes

### Swift launch path (`Sources/Plans/TaskRunner.swift`)
- Added an orthogonal valueless `--apply` flag (mirrors `--deep`/`--keep`), gated to `mode == .discuss`.
- `TaskRun.arguments(...)` now appends `--apply` after `--deep`/`--keep` and before `--resume`, only when `mode == .discuss && apply`. Added `apply: Bool = false` as the LAST parameter so every existing positional call site is unchanged.
- Added a stored `let apply: Bool` on `TaskRun` with `apply: Bool = false` in `init`; threaded it through `start()`'s local capture and `spawn(...)` into the `arguments(...)` call.

### Node runner (`Tools/work-task/run-task.ts`)
- `parseArgs` learns the `--apply` valueless flag (follows `--deep`/`--keep`); `Args` gains `apply?: boolean`.
- Added `buildApplyDiscussPrompt` / `buildApplyDiscussFollowUpPrompt` — parallel to the read-only pair but PERMITTING the agent to apply the agreed change to this single plan's file via `plan-discuss`, while staying autonomous and asking no questions. `buildPrompt`'s discuss branch dispatches to the apply variants when `args.apply` (honoring the resume/first-turn split).
- Allowlist wiring: `const isApplyDiscuss = isDiscuss && !!args.apply;` — apply discuss uses the write-capable base allowlist (`BASE_ALLOWED_TOOLS` + `readExtraAllowedTools`, deduped) and drops `DISCUSS_DISALLOWED_TOOLS`. The default (non-apply) read-only discuss branch is byte-for-byte unchanged (still `DISCUSS_ALLOWED_TOOLS` + disallowed Write/Edit/Bash).

### Tests (`Tests/PlansTests/TaskRunnerTests.swift`)
- 4 new arg-shape tests: apply SET emits `--apply` after `--mode discuss`; apply + resume emits `--apply` before `--resume`; apply false omits it; apply ignored for non-discuss modes.
- `swift test --filter TaskRunnerTests`: 139 tests, 0 failures.

### Reload reconciliation (`Sources/Plans/TaskRunner.swift`)
- `ask(...)` and `launchDiscuss(...)` gain `apply: Bool = false` and `onApplied: (() -> Void)? = nil`. `launchDiscuss` passes `apply` into the `TaskRun(... apply: apply)` constructor so `--apply` reaches the process, and in `onFinish` (after `thread.completeTurn(...)`) invokes `onApplied?()` ONLY when `apply == true && error == nil`. A plain read-only turn triggers no reload (unchanged). `askProject(...)` is untouched — the whole-project discuss stays read-only.

### UI affordance + gate (`Sources/Plans/PlanDetailView.swift`)
- New pure predicate `static func canApplyViaDiscussion(status:isBlocked:isBacklogged:)` — permits `.pending`/`.elaborated` only, withholds on blocked/backlogged/nil (mirrors `canBacklog`'s safety reasoning).
- `discussFooter` gains an explicit "Apply changes" button (`square.and.pencil`), rendered/enabled only when `canApplyViaDiscussion(...)` is true and not showing Stop. It routes through a new `submitApplyDiscussion(_ row:)` that re-guards the gate and calls `runner.ask(..., apply: true, onApplied: { store.reload() })`. The default Send/Return stays read-only via `submitDiscussion`. No GeometryReader/self-measuring (#096 honored).

### Bundle rebuild + verification (Step 7)
- Regenerated the gitignored `Tools/work-task/dist/run-task.js` via `node Tools/work-task/build.mjs` (esbuild) so the bundle reflects the `--apply` `.ts` edits; confirmed `--apply`, `isApplyDiscuss`, and `buildApplyDiscussPrompt` are present in the output.
- `Sources/Plans/ProjectDiscussionView.swift` confirmed read-only (no `apply`/`onApplied` path).
- Final: `swift build` clean; `swift test --filter TaskRunnerTests` 139/0; `swift test --filter PlanDetailViewTests` 71/0 (incl. 3 new `canApplyViaDiscussion` tests).

## Notes
Research correction: the task title's premise ("plan discussion is currently read-only") is accurate, but the broader framing that the app is a read-only viewer with no write path is **false**. The app already writes `.plans/` files for execute/elaborate/capture/delete via the bundled Node runner; discussion is the single mode deliberately locked read-only. This feature therefore un-suppresses an existing capability behind a safety gate, rather than building a new write path.
