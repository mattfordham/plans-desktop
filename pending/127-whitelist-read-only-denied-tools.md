# Whitelist read-only denied tool calls from the "incomplete information" warning

**ID:** 127
**Created:** 2026-11-20T14:11
**Type:** bug
**Status:** in-progress
**Branch:** fix/127-whitelist-read-only-denied-tools
**Worktree:** /Users/matt/Work/Open Source/plans-desktop/.worktrees/127-whitelist-read-only-denied-tools

## What
This should be whitelisted.

(Captured from a pasted screenshot of the Plans app's own plan-detail view. The
screenshot shows the orange caution banner:

> ⚠️ **1 tool call denied — the plan may be built on incomplete information**
> `mcp__plugin_figma_figma__get_variable_defs`

with the plan body below it reading "What: Update color NAMES to match Figma
frame below.")

The denied tool is `mcp__plugin_figma_figma__get_variable_defs` — a **read-only**
Figma MCP tool. Being denied a read-only inspection tool does not mean "the plan
may be built on incomplete information" in the alarming sense the banner implies,
and surfacing it as a caution is noise. Certain tools like this should be
whitelisted so that a denial of them is not counted toward, or surfaced by, the
denied-tools warning in the plan-detail view.

## Why
The right way to "whitelist" this tool is to make it succeed, not to hide its
denial. The banner is correct that a denied Figma read means the plan may be
built on incomplete information — so the fix is to allow the read, exactly as
task #122 did for the Dev-Mode Figma read tools. The Figma workflow now uses the
`plugin_figma_figma` MCP server, whose read tools were never added to the
launcher allowlist; adding them stops the spurious banner AND lets des-build
actually read Figma variables/metadata instead of flying blind.

## How Summary
The denial is decided in the Node launcher `Tools/work-task/run-task.ts`, not in
the Swift app: under `permissionMode: "acceptEdits"` any MCP tool absent from
`BASE_ALLOWED_TOOLS` is hard-denied and emitted as a `{"kind":"denied",...}`
event that the Swift app merely displays. #122 added the `figma-dev-mode-mcp-server`
flavour of the read tools plus the plugin-flavoured `create_session`, but never the
plugin-flavoured *read* tools. Add the plugin twins of the four already-trusted
Dev-Mode read tools (`get_variable_defs`, `get_screenshot`, `get_metadata`,
`get_design_context`) to the allowlist — enumerated explicitly, no wildcard, no
write tools — so the reads succeed and no denial is ever emitted. No Swift change
is needed: once allowlisted, the event never reaches `deniedTools` or the banner.

**Files of note:**
- `Tools/work-task/run-task.ts` — `BASE_ALLOWED_TOOLS` (~line 1346); the Figma read-tool block (~1357–1376) is where the new plugin-flavoured entries go.
- `Tools/work-task/run-task.allowlist.test.ts` — the allowlist guard test; its `PRESENT` array (lines 14–21) is the TDD RED home.
- `Tools/work-task/package.json` — `test` script runs the three launcher tests via `node --test`.

## Diagnosis

**Most likely:** The plugin-flavoured Figma read tool `mcp__plugin_figma_figma__get_variable_defs` is absent from `BASE_ALLOWED_TOOLS`, so the SDK hard-denies it under `acceptEdits` and the launcher emits a `denied` event; #122 added only the `figma-dev-mode-mcp-server` flavour of that read tool and the `plugin_figma_figma` flavour of `create_session`, never the plugin read tools. (`Tools/work-task/run-task.ts:1370-1376`)
**Evidence:** `BASE_ALLOWED_TOOLS` contains `mcp__figma-dev-mode-mcp-server__get_variable_defs` (1373) and `mcp__plugin_figma_figma__create_session` (1376) but no `mcp__plugin_figma_figma__get_variable_defs`; the unconditional `emit({kind:"denied",tool:resolvedName})` (~1825) fires for any non-allowlisted MCP tool; the Swift `.denied` decode → `deniedTools` append → orange banner path (`TaskRunner.swift:135,1109`; `PlanDetailView.swift:837`) only displays what the launcher emits. Matching is exact-string `Array.includes`, not prefix — so the Dev-Mode entry does not cover the plugin tool.
**Confidence:** high

**Alternative:** A Swift-side display/accumulation filter that suppresses benign denials after they are emitted (`TaskRunner.handle(.denied)` or the banner computed property). — **Confidence:** low — rejected: it would hide the warning while the Figma read still fails, so the plan really would be built on incomplete info; it also risks desyncing the raw count, the distinct `deniedToolNames`, and the persisted `RunOutcome`. Fixing at the allowlist source avoids all of this.

**To confirm:** Grep `BASE_ALLOWED_TOOLS` in `run-task.ts` and confirm `mcp__plugin_figma_figma__get_variable_defs` is not present (only the `figma-dev-mode-mcp-server` flavour and the plugin `create_session` are). This is agent-verifiable, so Step 1 is untagged.

## How
- [ ] Step 1: Confirm the Diagnosis by extending `Tools/work-task/run-task.allowlist.test.ts`: add the four plugin-flavoured Figma read tools to the `PRESENT` array (`mcp__plugin_figma_figma__get_variable_defs`, `__get_screenshot`, `__get_metadata`, `__get_design_context`) and run `node --test run-task.allowlist.test.ts` — it must FAIL (RED), proving they are not yet on the allowlist. (agent-verifiable, so untagged)
- [ ] Step 2: Add the same four plugin-flavoured read-tool entries to `BASE_ALLOWED_TOOLS` in `Tools/work-task/run-task.ts`, placed in the Figma read-tool block beside `mcp__plugin_figma_figma__create_session`. Enumerate each explicitly — no wildcard, no write/edit tools.
- [ ] Step 3: Refresh the Figma allowlist comment (~1357–1376) so it names the plugin-flavoured read tools alongside the Dev-Mode flavours and still says "Do NOT add any Figma write/edit tools here" — mirror how #122 kept the comment's "complete set" wording current.
- [ ] Step 4: Re-run the allowlist test (`node --test run-task.allowlist.test.ts`) and confirm it now PASSES (GREEN), including the unchanged `ABSENT` assertions (dangerous tools stay excluded). Also run the full launcher test group (`npm test` in `Tools/work-task/`, i.e. the three `node --test` files) to confirm no regression.

## Verification
- `node --test run-task.allowlist.test.ts` passes: the four plugin-flavoured Figma read tools are present on `BASE_ALLOWED_TOOLS`, and `mcp__playwright__browser_fill_form` / `__browser_run_code_unsafe` remain absent.
- The `Tools/work-task/` test group (`npm test`) passes with no regression in `run-task.denials.test.ts` / `run-task.modes.test.ts`.
- Behaviourally: a plan run that invokes `mcp__plugin_figma_figma__get_variable_defs` no longer produces a `denied` event, so the orange "the plan may be built on incomplete information" banner no longer appears for that tool and des-build can read the Figma variables.

## Impact Scope
_Fewer than 3 files modified (run-task.ts + its test) — section omitted._

## Assumptions

### Initial (from elaboration)
- [low] Scope: add the plugin twins of all four already-allowlisted Dev-Mode read tools (`get_variable_defs`, `get_screenshot`, `get_metadata`, `get_design_context`), not just the single `get_variable_defs` named in the screenshot. **Why:** the allowlist's own comment frames the Dev-Mode entries as "the complete set of read-only tools des-build needs"; the Figma workflow now uses the `plugin_figma_figma` server (per the active Figma MCP), so the other three plugin reads would reproduce the identical banner on the next Figma read. Matching is exact-string, so each must be enumerated. Kept strictly to read-only twins of already-trusted tools — no new categories, no write tools, no wildcard.
- [low] Fix at the launcher allowlist (the #122 mechanism), not via a Swift-side display filter. **Why:** "whitelist" + the explicit prior-art reference both point at the allowlist; a Swift filter would hide the banner while the Figma read still fails (the plan really would be incomplete) and risks desyncing the banner count, `deniedToolNames`, and the persisted `RunOutcome`. Allowlisting makes the tool succeed, so there is genuinely nothing to warn about.
- [high] TDD RED-first in `run-task.allowlist.test.ts` by extending the existing `PRESENT` array, then GREEN by extending `BASE_ALLOWED_TOOLS`. **Why:** this is exactly #122's test structure and the project's TDD convention; the guard test already exists for this array.

### Discovered during execution
_To be filled during execution_

## Changes
_To be filled during execution_

## Notes
Prior art: task #122 "Allow Benign Playwright And Figma MCP Tools" (completed) —
same mechanism, extended `BASE_ALLOWED_TOOLS` + the `PRESENT` guard test. This
task closes the plugin-flavoured-read-tool gap #122 left. A per-project stopgap
without code is to add the tool to a project's `.plans/config.json`
`extraAllowedTools` (read at `run-task.ts:1521-1527`), but the base allowlist is
the right home for a universally-benign read tool.
