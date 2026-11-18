# Fix Build-Route Handoff Leaving Tasks Stuck In-Progress

**ID:** 058
**Created:** 2026-06-24T12:46
**Type:** bug
**Status:** completed
**Completed:** 2026-06-24T13:16
**Branch:** fix/058-fix-build-route-handoff-stuck-in-progress

## What
A headless `work-task` execute run (the bundled `run-task.js` Agent-SDK launcher,
`entrypoint: sdk-ts`) can leave a task frozen at `in-progress` even though the
implementation completed successfully.

Observed on Client B task #051 (a component-build task):
- The launcher issued `/plan-execute 051 worktree`.
- `plan-execute` set up the worktree + state file (status → in-progress) and
  delegated the build to `des-build`.
- `des-build` completed successfully: `yarn lint` exit 0, `yarn build` exit 0,
  self-verified the prerendered HTML — and emitted its own "🟢 BUILT · 🔵 VERIFIED"
  closing report.
- The SDK session then ended on that des-build report. `plan-execute` never
  resumed its own terminal lifecycle steps: commit the worktree, update
  `state/NNN-state.md`, flip the task `in-progress → review`, update PROGRESS.md,
  write HISTORY.md.
- Result: task frozen at `in-progress`, with orphaned uncommitted work in the
  worktree (HEAD still at the prior task's commit, zero HISTORY entries).

This was **not a crash**: no error, budget fine ($5.67 / $20), clean voluntary
exit. It is a control-flow boundary bug — the run stopped one layer too early,
treating the inner build skill's report as the whole job being done.

Two contributing factors, both rooted in this repo's `run-task.ts`:
1. **Denied Figma MCP permission.** Late in the build, des-build tried
   `mcp__figma-dev-mode-mcp-server__get_screenshot` for a visual diff. That tool
   is NOT in `run-task.ts`'s `allowedTools`, and `permissionMode: "acceptEdits"`
   does not auto-approve it, so it was hard-denied. The agent correctly deferred
   the visual check but the denial nudged it into a "wrap up and report" posture.
2. **No post-run terminal-state check.** `run-task.ts`'s `main()` streams the
   `query()` response until the SDK emits `result`, emits `done`, and exits
   (`run-task.ts:372-389`). It never verifies the task actually reached `review`.
   When `plan-execute` returns with the task still `in-progress`, the launcher
   faithfully reports `done` and exits — nothing re-drives the lifecycle.

(`.plans` is gitignored, so `plan-execute` correctly skips a *start* commit; that
means the ONLY thing that would advance the task past in-progress is the
post-build handoff — exactly the part that didn't run.)

Related: sibling task #053 ("fix-051-handoff-spinner-while-running") tracks the
UI-side symptom of this same #051 incident.

## Why
The Plans app's whole execute hand-off is only trustworthy if a "done" run
guarantees the task reached a real terminal state (`review`). Today a run can
report success while silently leaving the task stranded at `in-progress` with
uncommitted work — invisible until a human notices the task never moved. This
recurs on every build-route (`des-build`) task, not just #051, because the
failure is structural in the launcher, not bad luck.

## How Summary
Make the launcher detect when an execute run ends with the task still
`in-progress` and surface that as a non-success outcome instead of a silent
`done`, and stop the Figma-screenshot denial that pushed des-build into
early-wrap. In `run-task.ts`, after the SDK `result`, re-read the task's
`**Status:**` and emit a distinct `stranded_at_in_progress` stop reason when it
didn't reach `review`; on the Swift side, `TaskRunner` and `RunOutcomeLog` already
carry a "stranded at in-progress" notion — extend their stop-reason mapping and
`classify()` to bucket it as non-`completed`. Add the read-only Figma MCP tools to
`allowedTools`. New-task modes defer their check to the existing #051
reconciliation. Re-prompting the SDK to auto-finish the lifecycle is deferred to a
follow-up (idempotency unverified). The launcher must be rebuilt (`npm run build`)
and re-bundled (`build.sh`). `des-build` itself needs no change.

**Files of note:**
- `Tools/work-task/run-task.ts` — launcher; post-`result` status check + new stop reason + Figma allowlist (`:335-389`).
- `Sources/Plans/TaskRunner.swift` — map the new stop reason to non-success (`truncatingStopReasons`/`truncationError()`, `:448-465`); new-task deferral (`~:776-917`).
- `Sources/Plans/RunOutcomeLog.swift` — `classify()` buckets the stranded signal (`:79-94`).
- `Tools/work-task/build.mjs` + `build.sh` — rebuild + re-bundle path into `Plans.app`.
- `Tests/PlansTests/{RunOutcomeLogTests,TaskRunnerTests}.swift` — coverage seams.

## How
Primary fix is **detect-and-surface** in the launcher (lower-risk than
re-prompting, idempotent, and reuses the existing outcome machinery), plus the
Figma allowlist. Re-prompting the SDK to "finish the lifecycle" is explicitly
NOT chosen for the first cut — see the assumption note.

- [x] Step 1: In `Tools/work-task/run-task.ts`, after the SDK `result` message
      and before emitting `done` (around `run-task.ts:372-389`), for
      `execute` / `executeYolo` runs read the task's current `**Status:**` from
      its `.plans/{pending,review,completed}/NNN-*.md` file and detect whether it
      reached a terminal state (`review`/`in-review`). Use a simple regex
      (`/^\*\*Status:\*\*\s*([a-z-]+)/mi`) — no new dep.
- [x] Step 2: When a clean SDK exit (no error, no budget/turn cap) leaves the
      task NOT at a terminal state, emit a distinct signal instead of a vanilla
      success — set a custom `stopReason` (e.g. `stranded_at_in_progress`) on the
      `done` line (and/or an explanatory `error` line). Keep the single-`done`
      NDJSON contract intact.
- [x] Step 3: In `Sources/Plans/TaskRunner.swift`, recognize the new stop reason
      so the run is treated as non-success — extend the existing
      `truncatingStopReasons` / `truncationError()` path (`TaskRunner.swift:448-465`)
      or add a sibling, mapping it to a user-facing "stranded at in-progress"
      message consistent with the budget-cap wording already there.
- [x] Step 4: In `Sources/Plans/RunOutcomeLog.swift`, ensure `RunOutcome.classify()`
      (`RunOutcomeLog.swift:79-94`) buckets the new signal as a non-`completed`
      classification (reuse `error`, or add a dedicated `.incomplete`/`.stranded`
      case) so the durable `~/.claude/plans-cc/run-outcomes.log` records *why* the
      task stranded — the file already documents this exact scenario.
- [x] Step 5: Add the read-only Figma verification MCP tools to `allowedTools`
      in `run-task.ts` (`run-task.ts:335-346`) —
      `mcp__figma-dev-mode-mcp-server__get_screenshot` and `…get_metadata` — so
      des-build's self-verification doesn't hit the interactive denial wall that
      nudged it into early-wrap. Confirm whether `permissionMode: "acceptEdits"`
      needs MCP tools explicitly allowlisted (the code shape implies yes).
- [x] Step 6: For new-task modes (`captureElaborate`/`executeYolo`) the resulting
      id isn't known at parse time — do NOT timestamp-scan in the launcher.
      Defer their terminal-state check to the Swift side, reusing the existing
      #051 capture-reconciliation pattern in `TaskRunner.swift` (~lines 776-917)
      that already detects the newly-created id post-`store.reload()`. Document
      this as the accepted fallback for new-task modes in the first cut.
- [x] Step 7: Add/extend tests in `Tests/PlansTests/RunOutcomeLogTests.swift`
      (new classification) and `Tests/PlansTests/TaskRunnerTests.swift` (new stop
      reason → non-success outcome) using the existing `finishForTesting` /
      arg-shape seams, so the change is covered without spawning a process. TDD:
      write the failing tests first.
- [x] Step 8: Rebuild the launcher and re-bundle:
      `cd Tools/work-task && npm install && npm run build` (produces
      `dist/run-task.js`), then `swift test` for the Swift changes, then
      `./build.sh` to re-embed `dist/` into `Plans.app/Contents/Resources/work-task/`.
- [x] 👁 Step 9: Run a real build-route task through the app's execute hand-off
      and confirm (a) a stranded run now surfaces as an error / non-success in the
      UI and the outcome log rather than a silent "done", and (b) the Figma
      screenshot tool is no longer denied mid-build. _(✓ User confirmed during
      /plan-review — worktree mode deferral.)_

## Verification
- A build-route execute run that ends with the task still `in-progress` is
  reported as a **non-success** outcome (UI error surface + a non-`completed`
  entry in `~/.claude/plans-cc/run-outcomes.log`), not a clean `done`.
- A normal run that does reach `review` still reports success unchanged (no
  false positives).
- The Figma `get_screenshot`/`get_metadata` tools are no longer permission-denied
  during a des-build verification step.
- `swift test` passes (including the new/extended RunOutcomeLog + TaskRunner
  tests); the launcher rebuilds cleanly and the app bundle embeds the updated
  `run-task.js`.

## Impact Scope

### Files to Modify
- [x] `Tools/work-task/run-task.ts` — post-`result` terminal-state check + new stop-reason signal; Figma MCP tools added to `allowedTools`.
- [x] `Sources/Plans/TaskRunner.swift` — recognize the new stop reason as non-success (extend `truncatingStopReasons`/`truncationError()`); new-task-mode deferral via existing reconciliation.
- [x] `Sources/Plans/RunOutcomeLog.swift` — classify the stranded signal as non-`completed`.
- [x] `Tests/PlansTests/RunOutcomeLogTests.swift` — cover the new classification.
- [x] `Tests/PlansTests/TaskRunnerTests.swift` — cover the new stop reason → outcome mapping.

### Related Files (may need updates)
- `Tools/work-task/dist/run-task.js` — build artifact (regenerated, not hand-edited; gitignore status to confirm in step 8).
- `build.sh` / `install.sh` — no change expected; they already copy `dist/` into the bundle.

### Endpoints/UI Affected
- The execute hand-off sheet / plan-row status in `PlanDetailView` / `TaskRunner`-driven UI — a stranded run now shows an error instead of an apparent success.

## Assumptions

### Initial (from elaboration)
- [low] Primary launcher fix is **detect-and-surface** (read post-run status, emit a non-success signal) rather than **re-prompting** the SDK to finish the lifecycle. **Why:** research flagged re-prompting as higher-risk (a second `query()` likely starts a fresh context, may re-hit the budget cap, and depends on plan-execute's terminal steps being idempotent — all unverified). Surfacing is idempotent, debuggable, and extends the outcome machinery that already exists for exactly this "stranded at in-progress" case. Re-prompting can be a follow-up once idempotency is confirmed.
- [low] New-task modes (`captureElaborate`/`executeYolo`) defer their terminal-state check to the Swift side via the existing #051 reconciliation pattern, rather than the launcher timestamp-scanning `.plans/pending/` for a new id. **Why:** the launcher has no reliable id at parse time and timestamp-scanning is race-fragile; `TaskRunner` already detects newly-created ids post-reload (#051). Flagged because it leaves new-task modes leaning on the fallback path in the first cut.
- [low] Read-only Figma MCP tools must be explicitly added to `allowedTools` (not auto-approved by `permissionMode: "acceptEdits"`). **Why:** the current code allowlists every non-edit tool explicitly and the #051 denial occurred with `acceptEdits` active, implying MCP tools aren't covered — to be confirmed against the SDK behavior in step 5.
- [low] A new/extended `RunOutcome.Classification` signal is the surfacing mechanism (reuse `error` or add `.stranded`/`.incomplete`). **Why:** `RunOutcomeLog.swift` already exists to answer "why did this task strand at in-progress?" and has the classify() seam — extending it is the lowest-friction path. Exact case name is an implementation detail for execution.

### Discovered during execution
- [low] Stranded user-facing message wording: "Run ended but the task never reached review — it was left stranded at in-progress. Re-run /plan-execute to finish it." **Why:** the plan suggested this exact phrasing as an example; kept it nearly verbatim to match the actionable, re-run-prompting tone of the existing `truncationError` budget message. Easy to retune if product wants different copy.
- [low] Single source of truth for the `"stranded_at_in_progress"` literal in Swift lives as `TaskRun.strandedStopReason` (in `TaskRunner.swift`), reused by `RunOutcome.classify` in `RunOutcomeLog.swift`. **Why:** mirrors the existing `TaskRun.truncatingStopReasons` pattern that `classify` already references, so both stop-reason concepts live next to each other in one file. The TS launcher (`run-task.ts`) hardcodes the same literal independently since it is a separate runtime with no shared module — that cross-language duplication is unavoidable and documented by comment.
- [low] Precedence in `classify()`: `stranded` is checked immediately after `truncated` and before `crashed`/`error`. **Why:** plan guidance — truncated (real cap) should win if both somehow present, but they are mutually exclusive since the launcher only emits the stranded reason when the stopReason is NOT a cap reason. Placing it second keeps the "didn't finish the task" reasons grouped at the top.
- [low] Folded the stranded mapping INTO the existing `TaskRun.truncationError(for:)` helper (returning the stranded message for `strandedStopReason`) rather than adding a separate sibling function. **Why:** `handle(_:)` already calls `truncationError` and sets `error` from its non-nil result, so a single helper means `handle` needs no change beyond a comment; both failure reasons share the identical "set error when nil" wiring. The helper name is now slightly broader than "truncation" but its doc-comment was updated to cover both cases.
- [high] Stranded detection reads the task `**Status:**` from `.plans/{pending,review,completed}/{taskId}-*.md` via `fs.readdirSync` + regex `/^\*\*Status:\*\*\s*([a-z-]+)/im`, treating `review`/`in-review` as terminal. **Why:** matches the plan's contract exactly; unknown/unreadable status falls through to a normal `done` so a missing file never produces a false stranded signal.
- [high] `permissionMode: "acceptEdits"` does NOT auto-approve MCP tools — the two read-only Figma tools had to be added explicitly to `allowedTools`. **Why:** the code shape confirms it: every non-edit tool (Skill, Agent, Task, Read, Write, Edit, Bash, Glob, Grep, TodoWrite) is enumerated explicitly in `allowedTools`, and the #051 hard-deny of des-build's visual diff occurred while `acceptEdits` was active. `acceptEdits` clearly only auto-approves edit-class operations, not arbitrary MCP server tools; so `get_screenshot`/`get_metadata` must be allowlisted by name (segment-2 step 5).
- [low] Only the two read-only Figma verification tools were added (`get_screenshot`, `get_metadata`) — no write/edit Figma tools. **Why:** per step-5 instruction these are safe read-only verification tools; granting Figma write access to an autonomous run is out of scope for the #058 fix.
- [high] `build.sh`'s final `open Plans.app` step was deferred to the human in this headless run. **Why:** the script's last line launches the GUI app, which is not meaningful in a headless agent environment and can block. The release compile (`swift build -c release`) and full bundle assembly (Info.plist, icon, `dist/` → `Contents/Resources/work-task`, executable copy into `Contents/MacOS`) were all run successfully by replicating build.sh lines 1-42; only the trailing `open` was skipped. The bundled `Plans.app/Contents/Resources/work-task/run-task.js` was verified to contain the `stranded_at_in_progress` string and both Figma tool entries, confirming the re-bundle embedded the new launcher.
- [high] `Tools/work-task/dist/run-task.js` is gitignored (confirmed via `git check-ignore`). **Why:** the built launcher artifact is regenerated by `npm run build` / `build.sh`, so it is intentionally not tracked — only the `run-task.ts` source and the bundle assembly are version-controlled.

## Changes

### Segment 1 (steps 1-4)
- `Tools/work-task/run-task.ts`:
  - Added module-level `truncatingStopReasons` set (`error_max_budget_usd`, `error_max_turns`) near `MAX_BUDGET_USD`.
  - Added `readTaskStatus(projectRoot, taskId)` helper (`node:fs`/`node:path`) that searches `.plans/{pending,review,completed}/${taskId}-*.md`, extracts `**Status:**` via `/^\*\*Status:\*\*\s*([a-z-]+)/im`, returns lowercased status or `undefined` on miss.
  - Added `TERMINAL_TASK_STATUSES` set (`review`, `in-review`).
  - In `case "result":`, for `execute` runs only and only when stopReason is not a cap reason, overrides `stopReason` → `stranded_at_in_progress` when the on-disk status is known but non-terminal. Single `done` line preserved.
- `Sources/Plans/TaskRunner.swift`: added `nonisolated static let strandedStopReason = "stranded_at_in_progress"`; `truncationError(for:)` now returns a stranded-specific message for that reason; `handle(_:)` unchanged beyond comment (already routes through the helper).
- `Sources/Plans/RunOutcomeLog.swift`: added `Classification.stranded`; `classify()` returns `.stranded` for `TaskRun.strandedStopReason` (precedence: after `truncated`, before `crashed`/`error`); doc-comment precedence list updated.
- `swift build` → Build complete (clean compile).
- Note: launcher scoped to `execute` mode only (not `executeYolo`) — new-task modes lack `args.taskId` at parse time and defer to the Swift side per step 6.

### Segment 2 (steps 5-8)
- `Tools/work-task/run-task.ts`: added `mcp__figma-dev-mode-mcp-server__get_screenshot` + `…get_metadata` to `allowedTools` (read-only verification tools; #051 denial root cause) with explanatory comment. Added a deferral comment in the `case "result":` stranded-check block noting new-task modes (`captureElaborate`/`executeYolo`) are intentionally not checked there — id unknown at parse time, so they defer to the Swift `reconcileFinishedCaptures` (#051/#053) path.
- `Sources/Plans/TaskRunner.swift`: one-line doc-comment above `reconcileFinishedCaptures` linking it to #058's new-task deferral (behavior unchanged).
- Tests:
  - `Tests/PlansTests/RunOutcomeLogTests.swift`: `testClassifyStrandedAtInProgress` (asserts `.stranded` mapping), `testStrandedOutcomeRoundTrips` (writer encode/decode of a `.stranded` outcome).
  - `Tests/PlansTests/TaskRunnerTests.swift`: `testTruncationErrorMapsStrandedReason` (stranded reason → non-nil message), `testFinishWritesStrandedOutcomeFromStrandedReason` (NDJSON `stranded_at_in_progress` done → `error` set + `RunOutcome` `.stranded`).
- Build/test: `swift test --filter RunOutcomeLogTests` 11/11, `--filter TaskRunnerTests` 44/44 (0 failures). `npm install` + `npm run build` → `dist/run-task.js` (gitignored; contains stranded + Figma strings). `swift build -c release` clean. `build.sh` release compile + bundle copy succeeded (trailing `open` deferred headless); bundled `Plans.app/.../work-task/run-task.js` embeds the new launcher.
- Step 9 (👁 manual end-to-end UI check) deferred to /plan-review (worktree mode).

## Notes
Root-cause diagnosis was done by reading the #051 session transcript
(`~/.claude/projects/-Users-<user>-Work-client-b/<session-id>.jsonl`)
and the launcher source `Tools/work-task/run-task.ts`. Key source anchors:
- `run-task.ts:156-173` — `buildExecutePrompt` (says "move to review" but no
  guard / re-drive if the run stops short).
- `run-task.ts:335-346` — `allowedTools` (no Figma MCP tool present).
- `run-task.ts:372-389` — the `result` → `done` exit path (no terminal-state
  check).
- `run-task.ts:329` — `permissionMode: "acceptEdits"`.
