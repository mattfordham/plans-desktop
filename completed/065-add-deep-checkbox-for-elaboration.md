# Add "deep" checkbox for elaboration

**ID:** 065
**Created:** 2026-08-21T00:00
**Type:** feature
**Status:** completed
**Branch:** feature/065-add-deep-checkbox-for-elaboration
**Completed:** 2026-08-24T10:43

## What
Add "deep" checkbox for elaboration.

Surface a "Deep" checkbox in the New Plan modal that, when checked, makes the
app tell plans-cc's `plan-elaborate` skill to draft via its reasoning sub-agent
("deep mode"). The checkbox threads a new boolean through the capture draft,
`TaskRunner`, and the Node launcher, which appends the trailing `deep` keyword
to the `/plan-elaborate <id>` line it emits.

## Why
Adds value by exposing plans-cc's `deep` elaboration mode from the desktop app.
Today the app can only trigger a plain elaboration; `deep` (which drafts the
plan via a reasoning sub-agent for higher-quality How/Verification on complex
tasks) is reachable only from the CLI. A checkbox next to the existing
"Elaborate" toggle lets a user opt into deeper drafting without leaving the app.

## How Summary
Add a single orthogonal `deep: Bool` that rides alongside the existing
`elaborate`/`execute` toggles: a new checkbox in `NewPlanModal` persists it in
`CaptureDraft`, `TaskRunner.capture` forwards it onto the `TaskRun`, and `spawn`
emits a `--deep` flag when set. On the Node side, `run-task.ts` parses `--deep`
and appends the END-ANCHORED trailing token ` deep` to the `/plan-elaborate <id>`
line in the elaborate-bearing prompt builders. It is NOT a new `RunMode` — deep
composes with the existing modes exactly as the skill treats `deep`/`skip` as
independent keywords.

**Files of note:**
- `Sources/Plans/NewPlanModal.swift` — the New Plan sheet; new `@State deep`
  + `Toggle`, wired into load/persist/clear/submit and passed to `capture`.
- `Sources/Plans/PlansStore.swift` — `CaptureDraft` struct gains a defaulted
  `deep` field so older persisted drafts still decode.
- `Sources/Plans/TaskRunner.swift` — `capture(...)` gains a `deep` param;
  `TaskRun` stores it; `spawn` appends `--deep` to the process arguments.
- `Tools/work-task/run-task.ts` — `Args`/`parseArgs` learn `--deep`;
  `buildCaptureElaboratePrompt` / `buildElaboratePrompt` / `buildReElaboratePrompt`
  append the trailing ` deep` token when set.
- `Tests/PlansTests/NewPlanDraftPersistenceTests.swift` &
  `Tests/PlansTests/TaskRunnerTests.swift` — round-trip + plumbing coverage.

## How
- [x] Step 1: Add `var deep: Bool` to `PlansStore.CaptureDraft` (in `PlansStore.swift`, alongside `execute`/`elaborate`) with a doc comment, and add `deep: Bool = false` to its memberwise `init` (defaulted so older drafts decode with the key absent — mirror the `imageData` precedent).
- [x] Step 2: In `NewPlanModal.swift`, add `@State private var deep = false`; add a `Toggle("Deep", isOn: $deep).toggleStyle(.checkbox).help("Draft the elaboration via a reasoning sub-agent (plans-cc `deep` mode)")` to the toggles `HStack`; add `.onChange(of: deep) { _, _ in persistDraft() }`; and include `deep` in `loadDraft` (both the draft branch and the reset `else` branch), `persistDraft`, and `clear`. Disable the Deep toggle unless `elaborate` is on (`.disabled(!elaborate)`), since `deep` only affects an elaboration pass (Execute's yolo path does not accept a `deep` keyword).
- [x] Step 3: In `NewPlanModal.submit()`, pass `deep: deep` into the `runner.capture(...)` call, and add `deep` to the `modalLog.notice(...)` line for parity with `execute`/`elaborate`.
- [x] Step 4: In `TaskRunner.swift`, add `deep: Bool = false` to `func capture(...)` (defaulted to keep existing call sites compiling); store it on `TaskRun` (new `let deep: Bool`, threaded through the `TaskRun` initializer with a default); and in `spawn(...)` append `["--deep"]` to `arguments` when `self.deep` is true. Leave `captureMode` unchanged — `deep` is orthogonal to mode.
- [x] Step 5: In `Tools/work-task/run-task.ts`, add `deep?: boolean` to the `Args` interface, parse a valueless `--deep` flag in `parseArgs` (set `deep = true`; thread it into every `return { ... }` branch), and in `buildCaptureElaboratePrompt`, `buildElaboratePrompt`, and `buildReElaboratePrompt` append the bare trailing token ` deep` to the `/plan-elaborate <id>` line ONLY when `args.deep` is set (END-ANCHORED — it must be the final token on that line, never mid-string). Update `buildPrompt` to pass `args.deep` into those three builders. Rebuild the bundled `run-task.js` per the project's build step so the app ships the updated launcher.
- [x] Step 6: Add a round-trip assertion for `deep` in `NewPlanDraftPersistenceTests.swift` (encode a draft with `deep: true`, decode, assert it survives; and assert an older draft JSON with no `deep` key decodes to `deep == false`).
- [x] Step 7: Add a `TaskRunnerTests.swift` case asserting a `deep`-carrying capture surfaces `--deep` in the spawned argument shape (mirror the existing arg-shape / `captureMode` precedence tests), and confirming `deep` does NOT alter the selected `RunMode`.
- [x] Step 8: Run `swift build` and `swift test`; confirm all tests pass and the app compiles.

## Verification
- `swift build` succeeds and `swift test` passes (including the new draft
  round-trip and `TaskRunner` `--deep` arg-shape tests).
- Manually (or by inspection): with "Elaborate" on, the "Deep" checkbox is
  enabled; checking it and capturing a plan causes `run-task.js` to be invoked
  with `--deep`, and the emitted prompt's `/plan-elaborate <new-id>` line ends
  with the trailing ` deep` token.
- With "Elaborate" off, the "Deep" checkbox is disabled (or a no-op), and no
  `--deep` flag is passed.
- An existing/older persisted draft (saved before this change, with no `deep`
  key) still decodes cleanly with `deep == false` — no regression to draft
  restore.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/PlansStore.swift` — add defaulted `deep` field to `CaptureDraft` + its `init`.
- [x] `Sources/Plans/NewPlanModal.swift` — new `@State`, `Toggle`, and wiring into load/persist/clear/submit.
- [x] `Sources/Plans/TaskRunner.swift` — `deep` param on `capture`, stored on `TaskRun`, emitted as `--deep` in `spawn`.
- [x] `Tools/work-task/run-task.ts` — `--deep` in `Args`/`parseArgs`/`buildPrompt` and the three elaborate-bearing builders.
- [x] `Tests/PlansTests/NewPlanDraftPersistenceTests.swift` — `deep` round-trip + backward-compat decode test.
- [x] `Tests/PlansTests/TaskRunnerTests.swift` — `--deep` arg-shape test.

### Related Files (may need updates)
- `Tools/work-task/run-task.js` (bundled build output) — must be regenerated from `run-task.ts` so the shipped launcher understands `--deep`.
- `Sources/Plans/ReElaborateModal.swift` — deliberately has no toggles today; the `--deep` support is wired at the `run-task.ts` layer so a future "Deep" control there would work, but this task does NOT add a checkbox to it (see Assumptions).

### UI Affected
- New Plan modal — a new "Deep" checkbox in the Elaborate/Execute toggle row, enabled only when "Elaborate" is on.

## Assumptions

### Initial (from elaboration)
- [low] The "Deep" checkbox lives in the New Plan modal (`NewPlanModal`) next to the existing Elaborate/Execute toggles, and is enabled only when "Elaborate" is on. **Why:** "for elaboration" most naturally means the capture→elaborate path, and `NewPlanModal` is the only capture dialogue with toggles to mirror; `deep` is a `/plan-elaborate` keyword, so it is meaningless for a plain capture or the Execute/yolo path (`/plan-execute … yolo` accepts no `deep` argument).
- [low] `deep` is threaded as an independent boolean flag (`--deep`), NOT a new `RunMode`. **Why:** research + the skill both treat `deep`/`skip` as composable, orthogonal keywords; adding `.captureElaborateDeep` etc. would combinatorially explode the `RunMode` enum. A single defaulted bool keeps existing call sites and tests compiling.
- [low] `--deep` support is wired into all three elaborate-bearing prompt builders (`captureElaborate`, standalone `elaborate`, `reElaborate`) at the `run-task.ts` layer, but this task adds the actual checkbox ONLY to `NewPlanModal`. **Why:** the flag is cheap to honor everywhere a `/plan-elaborate <id>` line exists and keeps the launcher consistent; `ReElaborateModal` deliberately ships with no toggles (per its doc comment), so adding a control there is out of scope for "add a checkbox for elaboration" and would be a separate UI decision.
- [high] The trailing `deep` token is appended END-ANCHORED as the final bare token on the `/plan-elaborate <id>` line, never mid-string. **Why:** the `plan-elaborate` skill's deep detection is explicitly end-anchored — only a trailing bare `deep` sets deep mode; a mid-string `deep` is ignored (and, with a description, would corrupt it). Since the app passes an id (not free text) to `/plan-elaborate`, `/plan-elaborate <id> deep` is safe.
- [high] The new `CaptureDraft.deep` field is defaulted (`deep: Bool = false` in `init`, decoded as `false` when the key is absent). **Why:** the `imageData` field is the exact in-repo precedent for adding a `Codable` draft field without breaking older UserDefaults-persisted drafts; the synthesized decoder reads an absent bool key via the defaulted init.
- [low] The checkbox is accepted as potentially a no-op for projects without `models.reasoning` configured (the skill silently falls back to inline drafting). **Why:** the app has no visibility into a target project's plans-cc model config, and the skill handles the missing-config case gracefully — surfacing/guarding that in the UI is out of scope and would require reading each project's config.

### Discovered during execution
- [high] `CaptureDraft.deep` needs a property-level default (`var deep: Bool = false`), not only an init default. **Why:** Swift's synthesized `Codable` decoder does NOT route through the memberwise `init`; a non-optional `Bool` with no property default would throw `keyNotFound` when decoding an older draft missing the `deep` key. `imageData` tolerated absence only because it is `Data?` (optionals decode absent as nil). Added `= false` at the stored-property level so absent-key decode yields `false` — this is what actually delivers the backward-compat the plan intends (plan line 96 assumed the init default suffices; it does not).
- [low] Toggle order is Elaborate → Deep → Execute in the HStack. **Why:** Deep modifies the Elaborate pass, so it reads best immediately after Elaborate; `.disabled(!elaborate)` gates it.
- [high] `buildElaboratePrompt` (which previously had NO literal `/plan-elaborate <id>` command line — only prose "…task with id ${taskId}") was changed to emit an explicit `/plan-elaborate ${taskId}${deep ? " deep" : ""}` command line, matching the other two elaborate-bearing builders. **Why:** the plan explicitly PREFERRED this approach for consistency and to keep the trailing ` deep` token END-ANCHORED as the final token on a real command line (a prose-only mention gives no clean end-anchored place for the token). The surrounding prose was lightly adjusted (trailing `.` → `:`) so the command line reads coherently.
- [low] The bundled launcher artifact is `Tools/work-task/dist/run-task.js` (esbuild output), which is gitignored and regenerated by `npm run build`; there is no committed top-level `run-task.js`. **Why:** `build.mjs` writes to `dist/` and `build.sh`/`install.sh` copy `dist/` into `Plans.app/Contents/Resources/work-task`. Rebuilding `dist/run-task.js` (confirmed to contain `--deep` handling) is the correct regeneration step; it is not staged because `dist/` is intentionally ignored.
- [low] npm/node were not on the sandbox PATH; used the nvm install at `~/.nvm/versions/node/v23.6.1/bin` to run `npm install` + `npm run build`. **Why:** the environment ships node only via nvm; esbuild compiled the TS cleanly (type-checking the `deep` threading), confirming Step 5's TypeScript is valid.
- [high] The backward-compat test (older draft JSON with no `deep` key) FAILED against the property-level default alone (`keyNotFound`). Swift's SYNTHESIZED `init(from:)` does not consult property defaults for a non-Optional key. Fixed by adding an explicit `init(from:)` on `CaptureDraft` using `decodeIfPresent(Bool.self, forKey: .deep) ?? false` (encode stays synthesized). This is required for pre-#065 drafts to survive an app upgrade. **Why:** proven by the failing test in Step 6; corrected the earlier segment's misleading comment claiming the property default handles the absent key.
- [high] Step 7 asserted the `deep` flag via the stored property on `TaskRun` (not by extracting a pure arg-builder helper). **Why:** `spawn` already emits `--deep` inline from the stored `deep` bool, matching the `usesTaskID`/`usesDescription` stored/flag precedent; a helper would be over-engineering for a single valueless flag.

## Changes
Implemented the "Deep" elaboration checkbox end to end (branch
`feature/065-add-deep-checkbox-for-elaboration`, worktree run):

- `Sources/Plans/PlansStore.swift` — `CaptureDraft` gained a `deep: Bool`
  field (property-level default `= false`) plus an explicit `init(from:)`
  decoding `deep` via `decodeIfPresent(...) ?? false` so pre-#065 persisted
  drafts (no `deep` key) still decode as `deep == false`. Memberwise init also
  takes `deep: Bool = false`.
- `Sources/Plans/NewPlanModal.swift` — new `@State private var deep`, a
  `Toggle("Deep")` (`.disabled(!elaborate)`) placed Elaborate → Deep → Execute,
  `deep` wired into `loadDraft`/`persistDraft`/`clear` and `.onChange`, and
  `submit()` passes `deep: deep` into `runner.capture(...)` (+ logged for parity).
- `Sources/Plans/TaskRunner.swift` — `TaskRun` stores `let deep: Bool`
  (init default `false`), threaded through `start`→`spawn`; `spawn` appends a
  valueless `--deep` process arg after `--mode` when set. `TaskRunner.capture(...)`
  gained a defaulted `deep:` param forwarded into the `TaskRun`. `captureMode`
  unchanged — `deep` is orthogonal to `RunMode`.
- `Tools/work-task/run-task.ts` — `Args.deep?`, a valueless `--deep` flag in
  `parseArgs` threaded into every return branch, and an END-ANCHORED trailing
  ` deep` token appended to the `/plan-elaborate <id>` line in
  `buildElaboratePrompt` / `buildReElaboratePrompt` / `buildCaptureElaboratePrompt`
  (wired via `buildPrompt`). Bundled launcher regenerated to
  `Tools/work-task/dist/run-task.js` (esbuild output, gitignored).
- Tests: `NewPlanDraftPersistenceTests.swift` — `deep:true` Codable round-trip
  + legacy-JSON-without-`deep` decodes to `false` (this test caught the
  synthesized-decoder backward-compat bug fixed above).
  `TaskRunnerTests.swift` — `TaskRun` carries `deep`, defaults to `false`, and
  `deep` does not alter the selected `RunMode`.

Verification: `swift build` PASS; `swift test --filter NewPlanDraftPersistenceTests`
PASS (8/8); `swift test --filter TaskRunnerTests` PASS (55/55); `npm run build`
PASS (regenerated `dist/run-task.js` with `--deep`).

## Notes
Reference: the `plan-elaborate` skill's `deep` keyword is END-ANCHORED and
composes with `skip`; deep mode drafts via a reasoning sub-agent and falls back
to inline drafting when `models.reasoning` is unset in the target project's
`.plans/config.json`.
