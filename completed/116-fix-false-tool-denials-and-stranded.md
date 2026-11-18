# Fix False Tool Denials And Stranded Background-Subagent Runs

**ID:** 116
**Created:** 2026-11-10T13:54
**Type:** bug
**Status:** completed
**Completed:** 2026-11-10T14:32
**Branch:** fix/116-fix-false-tool-denials-and-stranded

## What
Fix two headless-run bugs surfaced by task #083's stranded execute run (2026-11-10).

1. **False-positive tool denials.** `Tools/work-task/run-task.ts` (~line 1419) flags any `tool_result` whose text merely *contains* `haven't granted it yet` as a permission denial. Successful Reads of files containing that phrase (run-task.ts's own comments at ~1145/1416, plan #083 Step 2) were reported as "4 tool calls denied" (`deniedTools: ["Read"]` in `~/.claude/plans-cc/run-outcomes.log`). Fix: only count results that are errors (`block.is_error === true`) and whose text starts with the SDK's `Claude requested permissions to use` wording. Add a regression test with a successful Read whose content contains the marker.

2. **Stranded runs from background subagents.** In a headless SDK execute run the orchestrator spawned a background `plan-executor` subagent, said it would "await the completion notification", and ended its turn. Ending the turn ends the `query`, so the subagent was killed (task-notification `<status>killed</status>`) and the task stranded at in-progress after Step 1 ($9.26). Fix: ensure unattended runs (execute prompt in `run-task.ts` and/or `plan-execute` guidance) run subagents in the foreground and never end the turn while awaiting background work.

Evidence: session transcript `~/.claude/projects/-Users-<user>-Work-Open-Source-plans-desktop/cd836312-8580-4a22-ae05-2ed6f7840da8.jsonl` (+ its `subagents/` directory).

## Why
Both bugs corrupt the fidelity of unattended (headless Agent SDK) runs:

1. **False-positive denials pollute `run-outcomes.log` and mislead triage.** The
   denial detector in `run-task.ts` treats *any* `tool_result` text containing the
   substring `haven't granted it yet` as a permission denial, regardless of whether
   the tool call actually failed. A successful `Read` of a file whose content
   happens to include that phrase (run-task.ts's own explanatory comments, or a
   plan file quoting the SDK wording) is wrongly logged as a denied tool call. Task
   #083's run recorded `deniedTools: ["Read"]` with "4 tool calls denied" purely
   because the agent read files describing this very marker. That makes the
   outcomes log untrustworthy for diagnosing real allowlist gaps.

2. **Background subagents strand the run.** In a headless run the orchestrator can
   spawn a `plan-executor` subagent in the background, announce it will "await the
   completion notification", and end its turn. Ending the turn ends the SDK
   `query`, which kills the in-flight subagent (`<status>killed</status>`) and
   leaves the task stranded at `in-progress` after only the first step — burning
   cost with no result. Unattended runs must keep subagents in the foreground and
   never yield the turn while real work is still pending.

## How Summary
Tighten the denial detector so it only fires on genuine permission errors
(`block.is_error === true` **and** the SDK's `Claude requested permissions to use`
wording), extracted into a small pure predicate so it can be unit-tested; add a
`node:test` regression test proving a successful Read containing the marker is NOT
counted; and strengthen the `execute` hand-off prompt so unattended runs run
subagents in the foreground and never end the turn while background work is pending.

## How
- [x] Add a pure, exported predicate `isPermissionDenial(block)` in `run-task.ts`
      that returns true ONLY when `block.type === "tool_result"`,
      `block.is_error === true`, and `toolResultText(block.content)` includes the
      SDK wording `Claude requested permissions to use`. Keep `toolResultText`
      exported/accessible so the test can build realistic blocks. Guard the
      bottom-of-file `main()` auto-invocation so importing the module for tests
      does not launch a run (run `main()` only when executed as the entry script).
- [x] Rewire the `user`-message loop (~line 1419) to call `isPermissionDenial(block)`
      instead of the bare `text.includes("haven't granted it yet")` check. Preserve
      the existing id→name resolution and `emit({ kind: "denied", tool })` behavior
      for blocks that ARE real denials. Update the nearby comment to describe the
      `is_error` + wording contract.
- [x] 👁 Add a `node:test` regression test (`run-task.denials.test.ts`, run via
      `node --import tsx --test` or compiled, no new runtime deps beyond a dev test
      runner already resolvable) covering: (a) a successful Read `tool_result`
      (`is_error: false`) whose text contains `haven't granted it yet` →
      NOT a denial; (b) a real denial `tool_result` (`is_error: true`, text
      `Claude requested permissions to use Bash, but you haven't granted it yet.`)
      → IS a denial; (c) an error result with unrelated text → NOT a denial.
      Wire a `test` script into `Tools/work-task/package.json`.
- [x] Strengthen `buildExecutePrompt` (and, where the same risk applies,
      `buildExecuteYoloPrompt`) so the hand-off prompt explicitly instructs the
      agent: when it delegates to a subagent, run it in the FOREGROUND and wait for
      it inline; never spawn a background subagent and end the turn while awaiting
      a completion notification (ending the turn kills the subagent and strands the
      task). Keep the instruction concise and additive — do not alter the existing
      elaboration/worktree/review requirements.
- [x] Run the targeted denial test and `tsc --noEmit` type-check for the tool; make
      them pass. Confirm the bundle still builds (`node build.mjs`) if the test
      runner is not already present as a dev dependency.

## Verification
- `isPermissionDenial` returns false for a successful Read result containing
  `haven't granted it yet`, and true only for an `is_error` result with the
  `Claude requested permissions to use` wording (new test passes).
- The `user`-loop no longer emits a `denied` line for successful reads — a run that
  reads files mentioning the marker records no false `deniedTools`.
- `buildExecutePrompt` output contains an explicit foreground-subagent / do-not-end-
  the-turn instruction.
- `tsc --noEmit` passes for `Tools/work-task`.

## Impact Scope
- `Tools/work-task/run-task.ts` — denial predicate + execute-prompt wording.
- `Tools/work-task/run-task.denials.test.ts` — new regression test (new file).
- `Tools/work-task/package.json` — add `test` script (and dev test runner if needed).

## Assumptions

### Initial (from elaboration)
- [high] The fix belongs entirely in `Tools/work-task/` (TypeScript Agent SDK
  hand-off tool), NOT in the Swift app or in `~/.claude/plans-cc`. The task text and
  evidence point exclusively at `run-task.ts`. **Why:** both bugs are described with
  file/line references into `run-task.ts`.
- [high] `tool_result` content blocks carry a boolean `is_error` field (standard
  Anthropic API `ToolResultBlockParam` shape), so `block.is_error === true` is the
  correct discriminator. **Why:** matches the SDK/API message contract and the
  task's explicit instruction.
- [low] A `node:test`-based regression test (with `tsx`/`esbuild` to load TS, or a
  compiled JS variant) is acceptable here even though the repo's primary suite is
  XCTest — this tool has no existing test harness and the task explicitly asks for a
  regression test. **Why:** the bug is in TypeScript the Swift suite cannot reach;
  `node:test` adds no heavy dependency. If adding a loader proves disruptive, fall
  back to a compiled-JS test or a pure-function test file runnable with the existing
  esbuild toolchain.

### Discovered during execution
- [high] Used Node's built-in TypeScript type-stripping (`node --test run-task.denials.test.ts`) as the test runner instead of adding `tsx` as a devDependency. **Why:** `tsx` was not resolvable in `Tools/work-task/node_modules`, and the local Node is v23.6.1, whose native type-stripping runs `.ts` test files and imports `./run-task.ts` directly with zero new dependencies. This keeps the devDependency footprint unchanged (plan option (b) would have added `tsx`; native stripping is strictly lighter and was verified green). It emits an `ExperimentalWarning: Type Stripping` line to stderr but runs all 5 cases to pass.
- [high] Guarded `main()` with an ESM entry check using `fileURLToPath(import.meta.url)` vs `path.resolve(process.argv[1])`. **Why:** the test must import `run-task.ts` without launching a real agent run; verified that importing the module no longer invokes `main()` and still exposes `isPermissionDenial`/`toolResultText`.
- [low] The worktree had no `Tools/work-task/node_modules`; ran `npm install` there so the test and `tsc` could resolve `@anthropic-ai/claude-agent-sdk` and `@types/node`. **Why:** `node_modules` is gitignored, so this is a local build artifact and not a committed change.
- [high] Edited BOTH prompt builders (`buildExecutePrompt` AND `buildExecuteYoloPrompt`), not just one. **Why:** both drive autonomous, headless, single-turn `/plan-execute` runs that can delegate to subagents, so the same stranding risk applies to yolo mode; a one-sided fix would leave yolo runs exposed.
- [high] Placed the foreground-subagent instruction as a new trailing numbered requirement (item `6.` in `buildExecutePrompt`, item `5.` in `buildExecuteYoloPrompt`), immediately before the existing "Work autonomously to completion. Do not ask for confirmation." line, matching the existing array-of-strings line style. **Why:** keeps the constraint additive and adjacent to the autonomy directive it qualifies, without altering items 1-5 or their meaning.
- [low] `buildExecuteYoloPrompt`'s actual signature is `(description, keep)`, not the `(description, keep, deep)` the segment prompt named; it carries no `deep` param. **Why:** adapted to the actual codebase — the instruction text needs no `deep` reference, so the discrepancy did not affect the edit.

## Changes

**Bug #1 — false-positive denial detection** (`Tools/work-task/run-task.ts`):
- Added exported pure predicate `isPermissionDenial(block: unknown): boolean`
  (next to `toolResultText`, which is now also exported). Returns true ONLY when
  the block is a `tool_result` with `is_error === true` whose flattened text
  includes the SDK wording `Claude requested permissions to use`. Defensive about
  the unknown block shape; never throws.
- Rewired the `case "user":` loop (the former `~line 1419` bare-substring check)
  to gate on `!isPermissionDenial(block)` instead of
  `text.includes("haven't granted it yet")`. Id→name resolution via `toolUseNames`
  and the `emit({ kind: "denied", tool })` behavior for genuine denials are
  unchanged. Updated the explanatory comment to describe the new contract: a
  successful read whose content merely quotes the phrase is no longer flagged.
- Guarded the bottom-of-file `main()` auto-invocation with an ESM entry check
  (`path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)`; added
  `import { fileURLToPath } from "node:url"`) so importing the module for tests
  does not launch a run. Verified the shipped bundle still auto-runs:
  `node build.mjs` succeeds and `node dist/run-task.js` still fires `main()`.

**Regression test** (`Tools/work-task/run-task.denials.test.ts`, new):
- `node:test` + `node:assert/strict`, 5 cases: successful Read mentioning the
  marker → NOT a denial (string content and content-block-array forms); a real
  `is_error` denial with the SDK wording → IS a denial; an `is_error` result with
  unrelated text → NOT a denial; a non-`tool_result` block → NOT a denial.
- Added `"test": "node --test run-task.denials.test.ts"` to
  `Tools/work-task/package.json`. Runner = Node native TypeScript type-stripping
  (no new dependency; local Node 23.x). No `tsx`/other devDependency added.
- Result: `node --test` → tests 5, pass 5, fail 0. `npx tsc --noEmit` clean.

**Bug #2 — stranded background subagents** (`Tools/work-task/run-task.ts`):
- Added a new trailing Requirements item to BOTH execute-prompt builders
  (`buildExecutePrompt` item 6; `buildExecuteYoloPrompt` item 5) instructing the
  unattended agent: any delegation to a subagent (e.g. plan-executor) MUST run in
  the FOREGROUND and be awaited inline within the same turn; it must NEVER spawn a
  background subagent and end the turn to await a completion notification, because
  ending the turn ends the run and kills the in-flight subagent, stranding the task
  at `in-progress`. Both builders now carry a `#116` JSDoc note in the existing
  `#NNN:` style. The existing elaboration/worktree/review requirements and the
  trailing autonomy line are unchanged.
- Both builders were edited (not just `buildExecutePrompt`): the yolo builder drives
  the same autonomous single-turn `/plan-execute … yolo` path and had no equivalent
  guard, so the same stranding risk applied.

**Final verification (all green):**
- `npm test` (`node --test run-task.denials.test.ts`) → tests 5, pass 5, fail 0.
- `npx tsc --noEmit` → clean (exit 0).
- `node build.mjs` → bundle builds; `dist/run-task.js` still auto-runs `main()`.

## Notes
_Additional context_
