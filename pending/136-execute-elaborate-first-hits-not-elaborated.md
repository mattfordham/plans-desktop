# Execute with "elaborate first" enabled still hits the not-elaborated gate

**ID:** 136
**Created:** 2026-11-25T11:52
**Type:** bug
**Status:** review
**Branch:** fix/136-execute-elaborate-first-hits-not-elaborated

## What
I'm pretty sure I executed this with the "elaborate first" checkbox enabled. It seems to not have worked.

Evidence (screenshot): a `pending`, un-elaborated task was Executed from the browser. Instead of the run auto-elaborating first and then executing, the agent dock shows the run reaching the standard "Not elaborated" gate and parking on an `AskUserQuestion` ("Task #NNN hasn't been elaborated yet. … Elaborate now (recommended) / Execute anyway / Resolve for me"). So the pre-run "elaborate first" option did not take effect — the execute run behaved as if the checkbox were off.

![pasted image](file:///Users/matt/Library/Application%20Support/Plans/attachments/A429E818-6149-4D1A-AAA8-77B3392EBB66.png)

## Why
The "Elaborate first" checkbox (added in #133) silently fails to do what its label
promises: the user expects "Execute with elaborate-first ON" to auto-elaborate a
pending plan and then execute it with no interruption, but the run still stalls on
an interactive "Not elaborated" gate. A control that doesn't change the observable
outcome is worse than no control — it erodes trust in the hand-off and forces a
manual answer on exactly the runs that were meant to be fire-and-forget.

## How Summary
The #133 checkbox plumbing is correct end-to-end — the fault is that the
"elaborate-first" behaviour is delivered only as an *advisory* line inside
`buildExecutePrompt` ("if you reach the gate, choose Elaborate now"). The agent
still **calls** `AskUserQuestion` to present `plan-execute`'s not-elaborated gate,
and because #129 made every `.execute` run a `--session` process (`parksQuestions`
is true for sessions), that call now **parks interactively** in the dock instead of
being silently denied. The fix makes a hand-off execute resolve that gate
*autonomously* rather than merely suggesting an answer: harden the prompt so the
agent pre-resolves the not-elaborated decision WITHOUT invoking `AskUserQuestion`
(following the precedent that the yolo / delete prompts set for non-interactive
gate handling), and add a regression test that locks the default-path prompt to the
hardened wording. No change to the #133 checkbox wiring and no removal of
`AskUserQuestion` from the allowlist (which would revert to the #128/#129
silent-strand failure).

**Files of note:**
- `Tools/work-task/run-task.ts` — `buildExecutePrompt` (~550–617): the advisory
  not-elaborated instruction for both the ON (auto-elaborate) and OFF (execute-anyway)
  branches; the site to harden into a "resolve without asking" directive. Also
  `parksQuestions` (1778, 2057) — why a session execute parks rather than denies.
- `Tools/work-task/dist/run-task.js` — the compiled runner the app actually
  launches; must be rebuilt from the `.ts` change (the #133 note records that `dist/`
  was NOT rebuilt last time — a repeat of that omission would ship a no-op fix).
- `Plans.app/Contents/Resources/work-task/run-task.js` — the bundled runner inside
  the installed app; refreshed by the normal build/install, called out so the fix
  isn't verified against a stale bundle.
- `Sources/Plans/TaskRunner.swift` — `resumesHeldSession` / `launchesAsSession`
  (2285–2301) make `.execute` a session (the reason the gate parks); `buildExecute`
  argv / `--no-elaborate` threading (955–1043) confirmed correct, do NOT re-plumb.
- `Sources/Plans/ExecutePendingModal.swift` — hosts the `elaborateFirst` checkbox
  (defaults true) → `noElaborate: !elaborateFirst`; confirmed correct, context only.
- `Tools/work-task/run-task.modes.test.ts` — the runner's existing mode/prompt test
  file (tests live directly in `Tools/work-task/` as `run-task.*.test.ts`, run via
  `npm test` → `node --test`); home for a prompt-wording regression test asserting the
  hardened not-elaborated instruction.

## Diagnosis

**Most likely:** The not-elaborated "elaborate-first" behaviour is only an *advisory*
prompt instruction — the agent still calls `AskUserQuestion` at `plan-execute`'s gate,
and because a `.execute` run is a `--session` process (`parksQuestions` true), that
call parks interactively in the dock instead of auto-resolving. (`Tools/work-task/run-task.ts:597`, the default-branch "choose Elaborate now" text; `Tools/work-task/run-task.ts:1778` & `:2057` `parksQuestions = isInteractiveMode || args.session`)
**Evidence:** The checkbox is threaded correctly end-to-end (`ExecutePendingModal` `elaborateFirst` → `noElaborate` → `--no-elaborate` → `buildExecutePrompt`), and with the box ON `noElaborate` is *false*, so the prompt already emits the "Elaborate now, then execute" guidance — yet the run parks. `launchesAsSession(.execute)` returns true via `resumesHeldSession` (`Sources/Plans/TaskRunner.swift:2285`), and for a session run `parksQuestions` is true, so any `AskUserQuestion` the agent issues is surfaced as the dock's "Needs your answer" card rather than denied. The gate's ON/OFF state only changes which option the prompt *names*; it never suppresses the gate. #088's note (`.plans/completed/088-...:95`) already flags this exact fragility: the execute prompt "must pre-answer that gate" because the whole design relies on the agent NOT calling `AskUserQuestion`.
**Confidence:** high

**Alternative:** The installed `plan-execute` skill (in `~/.claude/...`, separate from the bundled JS runner) changed its gate wording or now unconditionally calls `AskUserQuestion`, so the prompt's pre-answer no longer "takes". — **Confidence:** low (the bundled JS runner is verified current; the skill version was not inspected and is the one remaining unknown — see To confirm).

**To confirm:** Re-run Execute on a pending task with the box ON and read the spawned
process's `runnerLog.notice("spawning: …")` argv (`Sources/Plans/TaskRunner.swift`
~1136) plus the agent transcript: confirm the argv is `--mode execute --session`
(no `--no-elaborate`) AND that the agent actually invoked `AskUserQuestion` at the
not-elaborated gate rather than auto-selecting. If both hold, candidates 1+2 are
confirmed and the fix target is autonomous gate resolution, not the #133 wiring.

## How
- [ ] 👁 Step 1: Reproduce and confirm the Diagnosis — Execute a `pending` task from the browser with "Elaborate first" ON, then read the app's unified log `spawning:` line (`TaskRunner.swift` ~1136) and the agent transcript. Confirm argv is `--mode execute --session` (no `--no-elaborate`) AND that the agent called `AskUserQuestion` at the not-elaborated gate (i.e. the pre-answer was ignored). Rule out the "resumed held session re-entered the gate" case. (Observation needed before the fix; confirms candidates 1+2.)
- [x] Step 2: Harden the default (auto-elaborate) branch of `buildExecutePrompt` in `Tools/work-task/run-task.ts` so the agent resolves the not-elaborated decision WITHOUT invoking `AskUserQuestion`: instruct it to auto-elaborate inline and proceed as if "Elaborate now" were already chosen, explicitly NOT to call `AskUserQuestion` / present the gate interactively. Mirror the robustness of the yolo / delete prompts (`buildExecuteYoloPrompt`, `buildDeletePrompt`) that already pre-resolve interactive gates for hand-off runs. Keep the OFF branch's intent (execute-anyway as-is) and harden it the same way.
- [x] Step 3: Do NOT remove `AskUserQuestion` from the execute allowlist and do NOT force `parksQuestions=false` for execute — leave the parking bridge intact (it is the safety net that prevents the #128/#129 silent-strand). Verify by inspection that `resolveAllowedTools` / `parksQuestions` (`run-task.ts` ~1778) are unchanged.
- [x] Step 4: Rebuild the compiled runner so the change actually ships: regenerate `Tools/work-task/dist/run-task.js` from the `.ts` source (the #133 note records `dist/` was NOT rebuilt last time — repeating that omission ships a no-op). Confirm the new wording is present in `dist/run-task.js`.
- [x] Step 5: Add/extend a prompt-snapshot regression test for `buildExecutePrompt` asserting the hardened not-elaborated wording in BOTH the default (`noElaborate=false`) and OFF (`noElaborate=true`) branches — so the advisory-only phrasing can't silently return. Place it in the runner's existing test suite — `Tools/work-task/run-task.modes.test.ts` (the `run-task.*.test.ts` files run via `npm test` → `node --test`), wiring the new file into `package.json`'s test script if a separate file is added.
- [x] Step 6: Rebuild/reinstall the app bundle so `Plans.app/Contents/Resources/work-task/run-task.js` carries the fix, then re-run the Step 1 reproduction with the box ON and confirm the run auto-elaborates and proceeds WITHOUT surfacing the "Not elaborated" gate in the dock. Spot-check the OFF path still executes-anyway without parking. (Bundle path confirmed: `build.sh`/`install.sh` run `npm run build` → regenerate `dist/run-task.js` from the hardened source → `cp -R` into the bundle, so a normal build/install ships the fix. The live-GUI reproduction is deferred to review — it can't run inside the isolated headless worktree; the user must run `./install.sh` and re-test in the app.)

## Impact Scope

### Files to Modify
- [x] `Tools/work-task/run-task.ts` — harden `buildExecutePrompt`'s not-elaborated instruction (both branches) to resolve the gate autonomously, without calling `AskUserQuestion`.
- [x] `Tools/work-task/dist/run-task.js` — regenerated from the `.ts` change (compiled artifact the app launches). NOTE: `Tools/work-task/dist/` is gitignored in this repo, so this artifact is rebuilt but not committed; the shipping copy is the bundled `Plans.app/Contents/Resources/work-task/run-task.js`, refreshed by the build/install in Step 6.
- [x] `Tools/work-task/run-task.modes.test.ts` — new/extended prompt-wording regression test for the hardened not-elaborated instruction (both branches), run via `npm test` (`node --test`).

### Related Files (may need updates)
- `Plans.app/Contents/Resources/work-task/run-task.js` — refreshed by the normal build/install step, not hand-edited; listed so verification runs against a current bundle.
- `Sources/Plans/TaskRunner.swift` — read-only context: `resumesHeldSession`/`launchesAsSession` (why execute is a session) and the `spawning:` log line used for confirmation. No change expected.
- `Sources/Plans/ExecutePendingModal.swift` — read-only context: confirms the checkbox→flag wiring is correct. No change expected.

### Behaviour Affected
- Hand-off **Execute** on a `pending` plan with "Elaborate first" ON — should auto-elaborate then execute with NO interactive gate in the dock.
- Hand-off **Execute** with "Elaborate first" OFF — should execute-anyway as-is with NO interactive gate.

## Verification
- The Step 1 reproduction confirms the Diagnosis (argv `--mode execute --session`; agent was calling `AskUserQuestion` at the gate).
- After the fix: executing a `pending` plan with "Elaborate first" ON auto-elaborates the plan inline and proceeds to execution WITHOUT the "Not elaborated" gate appearing in the agent dock.
- Executing a `pending` plan with "Elaborate first" OFF executes the plan as-is WITHOUT the gate appearing (the pre-existing OFF behaviour, now also non-interactive).
- The parking bridge is untouched: `AskUserQuestion` is still allow-listed for session runs and `parksQuestions` is unchanged, so genuine mid-run questions still park (no regression to the #128/#129 silent-strand).
- `dist/run-task.js` and the installed `Plans.app` bundle both contain the hardened wording (fix is not stranded in the `.ts` source).
- The new prompt-snapshot test passes and fails if the wording reverts to advisory-only; existing runner tests and `swift test` remain green.

## Assumptions

### Initial (from elaboration)
- [high] Root cause is advisory-only gate handling, not broken #133 plumbing. **Why:** Research traced the full checkbox path (`elaborateFirst → noElaborate → --no-elaborate → buildExecutePrompt`) as correct end-to-end with `file:line` evidence, and showed the default (ON) branch already emits the "Elaborate now, then execute" instruction — yet the run still parks because `parksQuestions` is true for `--session` execute runs. Two independent `high`-confidence candidates converge on this.
- [high] The fix should harden the prompt to resolve the gate autonomously, NOT remove `AskUserQuestion` from the allowlist or force `parksQuestions=false`. **Why:** The research "Approach Warnings" and #088's own note (`088.md:95`) warn that suppressing the park reverts to the #128/#129 silent-strand failure (the run denies the gate and strands at `in-progress`). Keeping the parking bridge intact is the safer target.
- [low] The fix lives in `buildExecutePrompt` (the bundled JS runner), not in the installed `plan-execute` skill. **Why:** The bundled runner is verified current, but the skill version in `~/.claude/...` was out of scope and is the one remaining unknown (captured as the Diagnosis "Alternative" and the Step 1 confirmation). If Step 1 shows the skill itself unconditionally calls `AskUserQuestion` regardless of prompt wording, the fix may also need a skill-side change — but prompt hardening is the first, lowest-risk move.
- [low] A prompt-wording regression test is the right guard, placed in the runner's existing `node --test` suite (`run-task.modes.test.ts`). **Why:** The runner is tested by `run-task.*.test.ts` files run via `npm test`; a direct assertion on both prompt branches is the lightest way to lock the wording, chosen over a heavier end-to-end harness. If a separate test file is added it must be wired into `package.json`'s test script.
- [low] Scope is limited to the pending-plan execute hand-off; the non-pending execute path and other gate-bearing modes (delete, review) are out of scope. **Why:** The reported symptom is specifically the not-elaborated gate on a pending execute. `buildDeletePrompt` has the same advisory-pre-answer shape and could deserve the same hardening later, but the user's bug is the execute path — widening now would be scope creep.

### Discovered during execution
- [high] Mirrored the yolo/delete precedent with the phrasing "Resolve this gate fully autonomously: do NOT call `AskUserQuestion` and do NOT present the gate interactively — there is no interactive UI to answer it, and parking on it would silently stall the run." in both branches, with a branch-specific tail ("Proceed as if \"Execute anyway\"/\"Elaborate now\" were already chosen …"). **Why:** The test constraint requires the literal `Elaborate now` only in the default branch and `Execute anyway` only in the OFF branch; the hardening wording deliberately avoids the phrase "Elaborate now" in the OFF branch while keeping the required literals intact.
- [high] The worktree's `Tools/work-task/node_modules` was absent, so `npm install` was run before `npm run build`. **Why:** esbuild (a devDependency) is needed by `build.mjs`; installing deps in the worktree is a prerequisite for regenerating `dist/`, not a source change.
- [high] The regression test asserts on the stable substrings `do NOT call` and `do NOT present the gate interactively` (plus the branch literals `Elaborate now` / `Execute anyway`) rather than a full prompt snapshot. **Why:** The segment prompt named these exact substrings; they are the distinctive autonomous-resolution phrasing that would vanish on a revert to advisory-only wording, while a full-prompt snapshot would be brittle against unrelated prompt edits.
- [high] Confirmed the bundle path reproduces the fix by re-running `npm run build` (not a full `swift build -c release`). **Why:** build.sh/install.sh both regenerate `dist/run-task.js` via `npm run build` then `cp -R Tools/work-task/dist` into the bundle, so re-running just the work-task build deterministically confirms the hardened wording lands in `Plans.app/Contents/Resources/work-task/run-task.js`; a full release swift build was unnecessary and heavy.

## Changes
- **`Tools/work-task/run-task.ts` — `buildExecutePrompt` hardened (both branches).**
  Requirement 2 in each of the `noElaborate` (OFF) and default (ON) branches was
  advisory-only — it told the agent *which* option to choose if it reached
  plan-execute's not-elaborated gate, but never forbade calling `AskUserQuestion`.
  For a `--session` execute run (`parksQuestions` true) that call parks in the app
  dock and silently stalls the run. Appended an explicit directive to each branch,
  mirroring the `buildExecuteYoloPrompt` / `buildDeletePrompt` precedent: "Resolve
  this gate fully autonomously: do NOT call `AskUserQuestion` and do NOT present the
  gate interactively … Proceed as if \"Execute anyway\"/\"Elaborate now\" were
  already chosen and continue without pausing." The required test-literal substrings
  are preserved (default branch keeps `Elaborate now`; OFF branch keeps `Execute
  anyway` and still contains no `Elaborate now`).
- **Parking bridge left intact (Step 3).** `AskUserQuestion` remains allow-listed and
  `parksQuestions = isInteractiveMode(args.mode) || !!args.session` is unchanged — no
  edit to `resolveAllowedTools` / `parksQuestions`. Genuine mid-run questions still
  park (no regression to the #128/#129 silent-strand). Confirmed: the `run-task.ts`
  diff touches only `buildExecutePrompt`.
- **`Tools/work-task/dist/run-task.js` rebuilt** via `npm run build` (`node build.mjs`);
  the hardened phrase "do NOT present the gate interactively" appears twice (one per
  branch). `dist/` is gitignored, so this artifact is not committed — the installed
  bundle is refreshed in Step 6.
- **Tests:** existing runner suite `cd Tools/work-task && npm test` → 72/72 pass
  (no regression to the `Elaborate now` / `Execute anyway` literal assertions).
- **`Tools/work-task/run-task.modes.test.ts` — regression test added (Step 5).** Two
  `#136` prompt-snapshot tests, one per branch, assert the autonomous-resolution
  directive is present (`do NOT call` + `do NOT present the gate interactively`) while
  preserving the branch literals (default keeps `Elaborate now`; OFF keeps `Execute
  anyway` and still has no `Elaborate now`). Verified the guard bites: stripping the
  directive from the source makes exactly these two tests fail (72 pass / 2 fail), and
  they pass again once restored. Suite: 74/74 pass.
- **Bundle path confirmed (Step 6).** `./build.sh` and `./install.sh` both run
  `(cd Tools/work-task && npm install && npm run build)` then `cp -R Tools/work-task/dist
  Plans.app/Contents/Resources/work-task`, so the bundled `run-task.js` is regenerated
  fresh from the hardened `run-task.ts` at build/install time — never a stale bundle.
  A full release `swift build` was not run in the worktree; the user refreshes the
  installed app with `./install.sh` (or `DEST_DIR=~/Applications ./install.sh`).
- `Step 1` (reproduction/observation) deferred to review per worktree-mode
  (diagnosis is high-confidence with file:line evidence; the live-GUI reproduction
  can't run inside the isolated headless worktree).

## Notes
_Additional context_
