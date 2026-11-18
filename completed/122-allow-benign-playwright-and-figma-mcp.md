# Allow the benign Playwright and Figma MCP tools plans-cc task #057 added to skills in run-task.ts BASE_ALLOWED_TOOLS

**ID:** 122
**Created:** 2026-11-17T12:00
**Type:** feature
**Status:** completed
**Completed:** 2026-11-17T19:06
**Branch:** feature/122-allow-benign-playwright-and-figma-mcp

## What
Allow the benign Playwright and Figma MCP tools plans-cc task #057 added to skills (browser_close, browser_click, browser_type, browser_console_messages, figma-dev-mode get_variable_defs, plugin_figma_figma create_session) in run-task.ts BASE_ALLOWED_TOOLS so des-build verify runs from the desktop app stop being denied

## Why
Desktop runs execute under `permissionMode: "acceptEdits"`, where MCP tools are
NOT auto-approved — any tool absent from `BASE_ALLOWED_TOOLS` (or the project's
`extraAllowedTools`) is hard-denied. plans-cc task #057 added six benign tools to
the `plan-execute` / `des-build` skill frontmatter so des-build's `verify <url>`
visual-comparison stage can drive the rendered review page (close/click/type/read
console) and read Figma variable defs within a file session. Because those six
are not in this app's `BASE_ALLOWED_TOOLS`, des-build `verify` runs launched from
the desktop app get those tools denied and the stage fails. Allowlisting the six
read/interaction tools keeps the desktop allowlist in sync with the skill
frontmatter. The interactive Playwright tools `fill_form` and `run_code_unsafe`
stay EXCLUDED — only the narrow close/click/type/console set des-build actually
declares is added.

## How Summary
Export `BASE_ALLOWED_TOOLS`, add a unit test pinning the six new entries present
and `fill_form`/`run_code_unsafe` absent, then add the four Playwright tools and
two Figma tools to the array and refresh the two now-stale guiding comments.

## How
- [x] Export `BASE_ALLOWED_TOOLS` from `run-task.ts` (change `const` to `export const`) so it can be asserted on; add a new test file `run-task.allowlist.test.ts` that imports it and asserts the six new tools (`browser_close`, `browser_click`, `browser_type`, `browser_console_messages`, `get_variable_defs`, `create_session`) are present AND that `fill_form` / `run_code_unsafe` are absent. Add it to the `test` script's file list in `package.json`. (TDD red — test fails before the array is updated.)
- [x] Add the four Playwright tools to `BASE_ALLOWED_TOOLS`: `mcp__playwright__browser_close`, `mcp__playwright__browser_click`, `mcp__playwright__browser_type`, `mcp__playwright__browser_console_messages`.
- [x] Add the two Figma tools: `mcp__figma-dev-mode-mcp-server__get_variable_defs` and `mcp__plugin_figma_figma__create_session`.
- [x] Update the two guiding comments: the Figma comment's "these three / complete set" wording (now four Dev Mode tools, plus the plugin `create_session`), and the Playwright comment that forbade click/type — it must now permit close/click/type/console while still explicitly forbidding `fill_form` and `run_code_unsafe`.
- [x] Run the targeted test file(s) and make them pass (TDD green).

## Verification
- `node --test run-task.allowlist.test.ts` passes (six tools present, fill_form/run_code_unsafe absent).
- The existing `run-task.modes.test.ts` / `run-task.denials.test.ts` still pass.
- `BASE_ALLOWED_TOOLS` contains the six new entries and the two comments no longer contradict the array.

## Impact Scope
- `Tools/work-task/run-task.ts` — export + six new allowlist entries + two comment updates.
- `Tools/work-task/run-task.allowlist.test.ts` — new test file.
- `Tools/work-task/package.json` — add the new test file to the `test` script.

## Assumptions

### Initial (from elaboration)
- [high] Add a new `run-task.allowlist.test.ts` rather than bolting onto the mode/denials tests — the allowlist is an independent concern. **Why:** matches the existing one-concern-per-file test layout.
- [high] `click`/`type` are permitted here (relaxing #057's old "do not add interactive Playwright tools" note) because des-build Step 8a drives the local `/review/<slug>` page. `fill_form`/`run_code_unsafe` stay excluded. **Why:** stated directly in the task Notes and keeps the allowlist in sync with plans-cc #057.

### Discovered during execution
- [high] Ran `npm install` in the worktree's `Tools/work-task/` because `node_modules` was absent there (fresh worktree), so `run-task.ts`'s `@anthropic-ai/claude-agent-sdk` import resolves and all three test files load. **Why:** the tests type-strip and import the real module; without deps every test file (not just the new one) fails with ERR_MODULE_NOT_FOUND. `node_modules` is gitignored, so this is a local setup step, not a committed change.
- [high] Placed `mcp__plugin_figma_figma__create_session` on its own line right after the Dev Mode Figma block with a one-line comment, rather than interleaving it among the `figma-dev-mode-mcp-server__*` entries. **Why:** it is a different MCP server prefix (`plugin_figma_figma`) and a session-setup handshake, so a distinct line keeps the grouping honest while still sitting with the Figma tools.

## Changes
- `Tools/work-task/run-task.ts`: changed `const BASE_ALLOWED_TOOLS` → `export const BASE_ALLOWED_TOOLS` (now importable for tests). Added six benign MCP tools to the array:
  - Playwright (after `browser_wait_for`): `mcp__playwright__browser_close`, `mcp__playwright__browser_click`, `mcp__playwright__browser_type`, `mcp__playwright__browser_console_messages`.
  - Figma: `mcp__figma-dev-mode-mcp-server__get_variable_defs` (grouped with the Dev Mode entries) and `mcp__plugin_figma_figma__create_session` (own line + comment — different MCP server prefix, a session-setup handshake).
  - Reworded the Figma comment: no longer claims "three / complete set"; now describes the four Dev Mode read tools plus the plugin `create_session`, keeping the "Do NOT add any Figma write/edit tools" guidance.
  - Reworded the Playwright comment: close/click/type/console are now deliberately allowed for driving the local `/review/<slug>` page (des-build Step 8a), while `mcp__playwright__browser_fill_form` and `mcp__playwright__browser_run_code_unsafe` are explicitly called out to stay excluded.
- `Tools/work-task/run-task.allowlist.test.ts` (new): two tests — the six benign tools are present on `BASE_ALLOWED_TOOLS`, and `fill_form` / `run_code_unsafe` are absent.
- `Tools/work-task/package.json`: appended `run-task.allowlist.test.ts` to the `test` script's `node --test` file list.
- Tests: `node --test run-task.allowlist.test.ts run-task.modes.test.ts run-task.denials.test.ts` → 12 pass, 0 fail (verified RED on the new file before the array change, then GREEN).

## Notes
Context from reviewing plans-cc task #057 (branch `fix/057-allow-playwright-browser-close-from-plans-desktop`):

- Desktop runs execute under `permissionMode: "acceptEdits"`, where MCP tools are not auto-approved. A tool missing from `BASE_ALLOWED_TOOLS` (`Tools/work-task/run-task.ts:1345`), or from the project's `extraAllowedTools`, is denied. The denials #057 reported (`mcp__playwright__browser_close`, `mcp__figma-dev-mode-mcp-server__get_variable_defs`, `mcp__plugin_figma_figma__create_session`) are surfaced by this app's `denied` event path (task #092).
- Tools to add (to match the plans-cc `plan-execute` / `des-build` frontmatter after #057):
  - `mcp__playwright__browser_close`
  - `mcp__playwright__browser_click`
  - `mcp__playwright__browser_type`
  - `mcp__playwright__browser_console_messages`
  - `mcp__figma-dev-mode-mcp-server__get_variable_defs`
  - `mcp__plugin_figma_figma__create_session`
- Two comments in `BASE_ALLOWED_TOOLS` need updating:
  - The Figma comment says the three Dev Mode tools are "the complete set des-build declares". After #057 there are four.
  - The Playwright comment says "Do NOT add interactive Playwright tools (click, type, fill_form, run_code_unsafe, etc.)". Adding click/type deliberately relaxes that rule. They are justified because des-build Step 8a says to "click toggles, open menus, type into search" on the local `/review/<slug>` page. `fill_form` and `run_code_unsafe` must stay excluded.
- Decision to confirm during elaboration: if click/type should stay forbidden here, plans-cc #057 should drop them too, so the two allowlists stay in sync.
- Stopgap until this ships: add the six tools to `extraAllowedTools` in the affected project's `.plans/config.json`.
