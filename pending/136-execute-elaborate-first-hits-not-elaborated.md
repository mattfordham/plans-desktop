# Execute with "elaborate first" enabled still hits the not-elaborated gate

**ID:** 136
**Created:** 2026-11-25T11:52
**Type:** bug
**Status:** elaborated

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
- [ ] Step 2: Harden the default (auto-elaborate) branch of `buildExecutePrompt` in `Tools/work-task/run-task.ts` so the agent resolves the not-elaborated decision WITHOUT invoking `AskUserQuestion`: instruct it to auto-elaborate inline and proceed as if "Elaborate now" were already chosen, explicitly NOT to call `AskUserQuestion` / present the gate interactively. Mirror the robustness of the yolo / delete prompts (`buildExecuteYoloPrompt`, `buildDeletePrompt`) that already pre-resolve interactive gates for hand-off runs. Keep the OFF branch's intent (execute-anyway as-is) and harden it the same way.
- [ ] Step 3: Do NOT remove `AskUserQuestion` from the execute allowlist and do NOT force `parksQuestions=false` for execute — leave the parking bridge intact (it is the safety net that prevents the #128/#129 silent-strand). Verify by inspection that `resolveAllowedTools` / `parksQuestions` (`run-task.ts` ~1778) are unchanged.
- [ ] Step 4: Rebuild the compiled runner so the change actually ships: regenerate `Tools/work-task/dist/run-task.js` from the `.ts` source (the #133 note records `dist/` was NOT rebuilt last time — repeating that omission ships a no-op). Confirm the new wording is present in `dist/run-task.js`.
- [ ] Step 5: Add/extend a prompt-snapshot regression test for `buildExecutePrompt` asserting the hardened not-elaborated wording in BOTH the default (`noElaborate=false`) and OFF (`noElaborate=true`) branches — so the advisory-only phrasing can't silently return. Place it in the runner's existing test suite — `Tools/work-task/run-task.modes.test.ts` (the `run-task.*.test.ts` files run via `npm test` → `node --test`), wiring the new file into `package.json`'s test script if a separate file is added.
- [ ] Step 6: Rebuild/reinstall the app bundle so `Plans.app/Contents/Resources/work-task/run-task.js` carries the fix, then re-run the Step 1 reproduction with the box ON and confirm the run auto-elaborates and proceeds WITHOUT surfacing the "Not elaborated" gate in the dock. Spot-check the OFF path still executes-anyway without parking.

## Impact Scope

### Files to Modify
- [ ] `Tools/work-task/run-task.ts` — harden `buildExecutePrompt`'s not-elaborated instruction (both branches) to resolve the gate autonomously, without calling `AskUserQuestion`.
- [ ] `Tools/work-task/dist/run-task.js` — regenerated from the `.ts` change (compiled artifact the app launches).
- [ ] `Tools/work-task/run-task.modes.test.ts` — new/extended prompt-wording regression test for the hardened not-elaborated instruction (both branches), run via `npm test` (`node --test`).

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
_To be filled during execution_

## Changes
_To be filled during execution_

## Notes
_Additional context_
