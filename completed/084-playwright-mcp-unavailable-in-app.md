# Playwright MCP Unavailable in App-Launched Runs

**ID:** 084
**Created:** 2026-09-29T00:00
**Type:** bug
**Status:** completed
**Completed:** 2026-09-29T10:18
**Branch:** fix/084-playwright-mcp-unavailable-in-app

## What
Playwright MCP unavailable in app-launched runs: TaskRun.spawn (Sources/Plans/TaskRunner.swift) never sets proc.environment, so the Node runner and the Claude CLI it spawns inherit the bare GUI-app PATH (/usr/bin:/bin:/usr/sbin:/sbin). The stdio Playwright MCP server (`npx @playwright/mcp@latest`, npx under ~/.nvm) can't launch, so des-build / plan-execute visual comparison reports "Visual comparison NOT run: Playwright MCP unavailable in this session." (Figma works because it's an HTTP MCP server.) The a69de53 allowlist fix is already installed and isn't the issue. Fix: resolve the login-shell PATH once (zsh -lc 'echo $PATH', cached like resolveNodePath), falling back to prepending the resolved node binary's directory, and pass it via proc.environment. Test-first with a pure build-child-environment helper; rebuild with ./install.sh and confirm a des-build verify run reaches Playwright.

## Why
Improves reliability by giving app-launched runs the user's real shell PATH. At the moment, every stdio MCP server started through `npx`/`node` (Playwright, chrome-mcp-server, trello), every `node`-based hook, and the agent's `node`/`npm` in Bash silently fail in runs launched from Plans.app. That quietly turns design-fidelity checks into "NOT run".

## How Summary
Change `resolveNodePath` into a single `zsh -lc` login-shell lookup that returns both the `node` path and the login PATH, reading marked lines and with a timeout. Then give the spawned process an explicit environment: the inherited environment with PATH replaced, built by a pure, unit-tested helper. That helper falls back to node's own directory plus the common Homebrew prefixes. Also drain stderr into `runnerLog`, so spawn failures are visible and the child can't block once the pipe buffer fills.

**Files of note:**
- `Sources/Plans/TaskRunner.swift` — `resolveNodePath`/`NodePathCache` (login-shell lookup), `start()`'s detached resolve block, `spawn()` (sets `proc.environment`, drains stderr)
- `Tests/PlansTests/TaskRunnerTests.swift` — new tests for the child-environment builder and the parser for the marked shell output

## Diagnosis

**Most likely:** `TaskRun.spawn` never sets `proc.environment`, so the Node runner, and the Claude CLI that the Agent SDK starts with a copy of `process.env`, inherit the bare launchd GUI PATH (`/usr/bin:/bin:/usr/sbin:/sbin`). The stdio Playwright server's `npx` (under `~/.nvm`) therefore can't be found. (`Sources/Plans/TaskRunner.swift:451-487`)
**Evidence:** `resolveNodePath()` (`TaskRunner.swift:713`) uses a login shell but keeps only the node binary's path and discards the shell's PATH. `run-task.ts:682` passes no `env` to `query()`, and SDK 0.3.215 falls back to `{...process.env}`. `npx`'s first line is `#!/usr/bin/env node`, so even an absolute `npx` path would fail. Under `env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `command -v npx` finds nothing and `/usr/bin/env node` fails.
- Steps 2-4: added `LoginShellEnvironment` and `LoginEnvironmentCache` (replacing `NodePathCache`), plus `parseLoginShellOutput`, `buildChildEnvironment`, `resolveLoginEnvironment` (a single `zsh -lc` call with a 5s timeout; stdin/stderr go to /dev/null) and `cachedLoginPath`; `resolveNodePath()` is kept as a wrapper. `start()` now passes the login PATH into `spawn()`, which sets `proc.environment` and logs the child PATH. 8 new tests in `TaskRunnerTests.swift` (79/79 pass).
- Step 5: `spawn()` drains stderr through a `readabilityHandler`, and the new pure helper `stderrLogLines(from:)` turns each chunk into `runner stderr:` log lines; both handlers set themselves to nil at end of output (3 new tests).
- Step 6: `swift test --filter TaskRunnerTests` 82/82, `swift build` clean, `./install.sh` installed /Applications/Plans.app.
- Step 7 (simulated at the user's request, since no current plan needs Playwright): ran the installed app's bundled `claude mcp list` with the same zsh -lc lookup from a bare launchd environment. Bare PATH: playwright, chrome-mcp-server and trello fail to connect. Login PATH: all three connect; figma (HTTP) connects either way. Not yet checked: a real Dock-launched run and the `child PATH` unified-log line.
- Full `swift test` before completion: 500 tests, 0 failures. Figma works because it's an HTTP MCP server, which the CLI doesn't start as a process.
**Confidence:** high

**Alternative:** ~~Playwright tools denied by `permissionMode: "acceptEdits"`~~. Disproved: the a69de53 allowlist is present in the installed bundle (`/Applications/Plans.app/Contents/Resources/work-task/run-task.js`). (`Tools/work-task/run-task.ts:723-728`) — **Confidence:** low

**To confirm:** Launch the app from the Dock and run a task whose agent runs `echo $PATH; command -v npx` through Bash. Expect the bare PATH and no `npx`, and expect the same task to see the Playwright tools once the app is launched from a terminal.

## How
- [x] 👁 Step 1: Confirm the Diagnosis. Launch Plans.app from the Dock and run a throwaway task whose agent runs `echo $PATH; command -v npx` through Bash. Expect `/usr/bin:/bin:/usr/sbin:/sbin` and no `npx`. (This confirms the cause before the fix; the agent can't see how the GUI app was launched.)
- [x] Step 2: Write failing tests first in `Tests/PlansTests/TaskRunnerTests.swift`, next to the `usesTaskID`/`usesDescription` pure-helper tests:
  - `TaskRun.buildChildEnvironment(base:loginPath:nodePath:)`: the login PATH replaces the base PATH, and other base keys (HOME, USER, TMPDIR) are kept.
  - When `loginPath` is nil or empty, the fallback is `dirname(nodePath)`, then `/opt/homebrew/bin`, then `/usr/local/bin`, then the base PATH, with no duplicate entries.
  - Node's directory is put first when the login PATH doesn't already contain it.
  - A pure parser for the marked shell output takes the last `__NODE__`/`__PATH__` lines and ignores noise printed by profile scripts.
- [x] Step 3: In `Sources/Plans/TaskRunner.swift`, make the helpers from Step 2 pass. Merge the lookup into one `zsh -lc` call: `command -v node | sed 's/^/__NODE__/'; printf '__PATH__%s\n' "$PATH"`, with a timeout of a few seconds that terminates the shell. Cache the result as one node-plus-PATH value, generalizing `NodePathCache`, and keep `resolveNodePath()` returning `String?` for existing callers and log messages.
- [x] Step 4: Thread the resolved login PATH from `start()`'s `Task.detached` block into `spawn(...)`, and set `proc.environment = TaskRun.buildChildEnvironment(base: ProcessInfo.processInfo.environment, loginPath:, nodePath:)`. Log the PATH that's used (`runnerLog.notice`, public).
- [x] Step 5: Drain `stderrPipe` in `spawn()` with a `readabilityHandler` that logs each chunk to `runnerLog` (trimmed, public), mirroring the stdout handler. Clear both handlers on termination. This stops the child blocking once the stderr pipe buffer (about 64 KB) fills and makes spawn failures visible.
- [x] Step 6: Run `swift test`, all green, then `./install.sh`.
- [x] 👁 Step 7: Launch Plans.app from the Dock and run a des-build `verify <url>` or plan-execute visual-comparison task. Confirm the Playwright tools are called, no "Playwright MCP unavailable" line appears, and `/usr/bin/log show --predicate 'subsystem == "com.plans.desktop"' --info` shows the full PATH in the spawn log.

## Verification
- `swift test` passes, including the new `buildChildEnvironment` and marked-output parser tests.
- After `./install.sh`, a run from the Dock-launched app reaches the `mcp__playwright__*` tools, and the "Visual comparison NOT run: Playwright MCP unavailable" message no longer appears.
- The unified log shows the resolved PATH and any child stderr lines.
- Figma verification and normal execute/capture runs still work (no regression).

## Impact Scope
_To be filled during elaboration (if 3+ files affected)_

## Assumptions

### Initial (from elaboration)
_To be filled during elaboration_

### Discovered during execution
- [low] The cache holds a `LoginShellEnvironment` (node + PATH) and is only filled once node resolves; a failed or timed-out lookup is not cached. **Why:** this keeps the old `NodePathCache` behavior (installing node later works without relaunching), and a run can't start without node anyway.
- [low] On timeout (5s) the shell is terminated and resolution returns nil, so the run fails with "Could not locate node" instead of spawning with a fallback PATH. **Why:** it matches the old failure path; there is no node path to spawn with in that case.
- [low] Duplicate PATH entries are removed in both branches (login PATH and fallback), first occurrence wins. **Why:** removing later duplicates doesn't change lookup order, so a single dedup pass is simpler.
- [high] Stdout is read on a background queue with a `DispatchSemaphore` timeout, and stderr/stdin are set to `/dev/null`. **Why:** a hung or chatty profile can't block past the timeout or fill an unread stderr pipe, and there's no interactive stdin for a profile prompt to wait on.
- [high] New helpers are `nonisolated static` on the `@MainActor` `TaskRun`, and the `@unchecked Sendable` lock boxes match the existing `NodePathCache` pattern. **Why:** they are called from the `Task.detached` block and from tests under Swift 6 strict concurrency.
- [high] The stdout and stderr `readabilityHandler`s clear themselves when they read EOF (empty `availableData`), not in `terminationHandler`. **Why:** termination can fire before the last stdout bytes (possibly the final `done` event) are read, so clearing there could drop them. Clearing at EOF keeps all the data and stops the handlers firing repeatedly with empty data after the pipe closes.
- [high] Stderr is only logged (one `runnerLog.notice` per trimmed, non-empty line, privacy .public), not buffered. **Why:** nothing in the app reads the child's stderr (no failure banner or error message uses it), so there's no existing consumer to feed.
- [low] Stderr lines are logged at `.notice` rather than `.error`. **Why:** Node and the Agent SDK write warnings and progress noise to stderr too, so `.error` would over-report. `.notice` is persisted and visible in `log show`.

## Changes
- Step 1: Diagnosis confirmed. The Dock-launched Plans.app (pid 33209, ppid 1/launchd) has `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, and under that PATH `command -v npx`/`node` find nothing and `/usr/bin/env node` fails.

## Notes
_Additional context_
