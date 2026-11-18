# Add "Delete" button to delete plans

**ID:** 060
**Created:** 2026-08-14T20:54
**Type:** feature
**Status:** completed
**Branch:** feature/060-add-close-button-to-close-plans
**Completed:** 2026-08-17T12:05

## What
Add a "Delete" button to the plan detail view that deletes the plan itself by
invoking the `plan-delete` skill.

## Why
Deleting a plan currently requires leaving the app and running `/plan-delete NNN`
in a terminal. The detail header already surfaces every other plan lifecycle
action (Elaborate, Refine, Execute) as a button that hands off to the bundled
Agent-SDK runner, so plan deletion is the one lifecycle verb with no in-app
affordance. This closes that gap using the established hand-off pattern.

## How Summary
Add a destructive "Delete" button to the plan detail header's action row in
`PlanDetailView.swift`, gated by a new pure `canDelete(status:isBlocked:)`
predicate. Clicking it raises an `NSAlert` confirmation (the established pattern
from `PlansApp.swift:62`, with `hasDestructiveAction = true`); on confirm it calls
`runner.run(projectPath:taskID:mode:.delete)`, which spawns the bundled Node
runner in a new `delete` mode that invokes the `plan-delete` skill.

The window-dismiss "Close" button added earlier (wrong interpretation) is removed
along with its `@Environment(\.dismiss)` property.

**Critical constraint:** `run-task.ts` does NOT allowlist `AskUserQuestion`
(`run-task.ts:456-475`), but `plan-delete` has TWO interactive gates — step 6
(the yes/no delete confirm) and step 7c (an `AskUserQuestion` asking whether to
delete the task's git branch). The delete prompt MUST pre-answer both explicitly:
confirm the deletion, and KEEP the branch (the app must never delete git branches
— an in-app click should not destroy commits). The in-app `NSAlert` is the real
safety gate.

**Files of note:**
- `Sources/Plans/TaskRunner.swift` — add `.delete` to `RunMode` (usesTaskID true,
  usesDescription false); no `spawn` change needed (it is flag-driven).
- `Tools/work-task/run-task.ts` — add `"delete"` to the `Mode` union, arg
  validation, and a `buildDeletePrompt`; `buildPrompt` dispatch.
- `Sources/Plans/PlanDetailView.swift` — remove the dismiss Close button; add the
  Delete button, the `NSAlert` confirm, `canDelete`, and the run-label switches at
  lines 564 and 580 (they fall through to "Executing" otherwise).
- `desktop-app-spec.md` — the read-only claims at lines 66-71, 147, and 412.

**Build note:** the app loads `run-task.js` from its bundle Resources
(`TaskRunner.swift:626-632`), NOT from the repo. Verifying the Node-side change
requires `npm run build` in `Tools/work-task/` followed by `./build.sh` — a plain
`swift build` will run the stale bundled script.

## How

_Steps 1-4 below were executed against the WRONG interpretation (window dismiss)
and are superseded — step 5 reverts them. They are retained unchecked-in-spirit
for history; the live plan is steps 5-13._

- [x] ~~Step 1: Add `@Environment(\.dismiss)` to `PlanDetailView`.~~ (superseded)
- [x] ~~Step 2: Add a window-dismiss "Close" button to `detailHeader(_:)`.~~ (superseded)
- [x] ~~Step 3: Update the struct doc comment for the Close button.~~ (superseded)
- [x] ~~Step 4: Build + targeted tests.~~ (superseded)

### Rework (after reopen — corrected interpretation)
- [x] Step 5: In `Sources/Plans/PlanDetailView.swift`, revert the wrong-interpretation work: delete the "Close" `Button` (lines ~257-265, including `.keyboardShortcut(.cancelAction)` and its comment) and the `@Environment(\.dismiss) private var dismiss` property, and restore the struct doc comment to state the view carries no Close button (the native window control closes it).
- [x] Step 6: In `Sources/Plans/TaskRunner.swift`, add `case delete` to the `RunMode` enum (~line 133). Add it to `usesTaskID`'s true branch (it operates on an existing task id) and `usesDescription`'s false branch. Update the enum's doc comment to describe the delete mode. `spawn` needs NO change — it is driven by those two flags.
- [x] Step 7: In `Tools/work-task/run-task.ts`, add `"delete"` to the `Mode` union (~line 58), to the `--mode` validation chain (~lines 97-110, a hardcoded string-equality chain — an unlisted value returns null and the run dies), and to the usage error string (~line 429). Add a `buildDeletePrompt(taskId)` that invokes `/plan-delete <id>` and explicitly pre-answers BOTH of the skill's interactive gates, since `AskUserQuestion` is not allowlisted: confirm the deletion, and KEEP the associated git branch (never delete branches from the app). Wire it into `buildPrompt` (~line 350-367). **Hazard:** `buildPrompt`'s last line is an unguarded `return buildExecutePrompt(...)` fallback — a missed dispatch does NOT error, it silently EXECUTES the plan instead of deleting it. Add the `delete` branch before that fallback and verify it. No `parseArgs` branch is needed: delete takes only `--task-id`, so it falls through the existing execute/elaborate branch correctly.
- [x] Step 8: In `PlanDetailView.swift`, add a pure `static func canDelete(status:isBlocked:) -> Bool` next to `canWork`/`canElaborate` (~line 278). Deletion is valid for any resolvable plan regardless of status, so it should NOT gate on status the way Execute does — but it must be unavailable while a run for that task is in flight (the action row already branches on `runner.isRunning`).
- [x] Step 9: In `PlanDetailView.swift`'s `detailHeader(_:)` action row, add the "Delete" button after "Open in Markdown App" using `Label("Delete", systemImage: "trash")`. On click, raise an `NSAlert` modeled on `PlansApp.swift:58-79`: message "Delete plan #NNN?", informative text naming the plan title and stating deletion is permanent, a destructive primary "Delete" button (`hasDestructiveAction = true`) and a "Cancel" button. When the task status is `review` or `in-progress`, extend the informative text with `plan-delete`'s own warning (unmerged branch / uncommitted work will be lost). Only on `.alertFirstButtonReturn` call `runner.run(projectPath: row.projectPath, taskID: row.task.id, mode: .delete)`.
- [x] Step 10: In `PlanDetailView.swift`, update the two run-label switches. `modeVerb` (~line 564) is exhaustive with no `default:` — it will FAIL TO COMPILE until `.delete` is added, returning "Deleting". `title` (~line 580) HAS a `default:` so it compiles either way; the default branch yields "Deleting task #060", which is correct — verify rather than change it. (`usesTaskID`/`usesDescription` in TaskRunner.swift are likewise exhaustive and compile-break; that is covered by step 6.)
- [x] Step 11: Add unit tests in two files. (a) `Tests/PlansTests/PlanDetailViewTests.swift`: tests for `canDelete(status:isBlocked:)` following the existing pure-predicate pattern used for `canWork`/`canElaborate`. (b) `Tests/PlansTests/TaskRunnerTests.swift`: add `.delete` assertions to the EXISTING `testRunModeUsesTaskIDFlag` (~line 531) and `testRunModeUsesDescriptionFlag` (~line 514) — these list cases manually rather than switching, so a new case compiles untested unless added — plus a raw-value round-trip (`RunMode.delete.rawValue == "delete"`) matching `testReElaborateModeUsesBothTaskIDAndDescription` (~line 546).
- [x] Step 12: Correct the now-false read-only claims. In `desktop-app-spec.md`: lines 67-71 (the emphatic "The app is a pure viewer. It MUST NEVER write..." paragraph under the "## 2. Hard Constraint: Read-Only" heading at line 65 — the heading itself needs rewording too), line 412 (acceptance item 7), and line 147's "keeps the app read-only" aside (registry-only; the weakest — may just need a scope clarification). Also fix the in-code restatement at `Sources/Plans/PlanDetailView.swift:33-35`, which asserts the view "never writes, moves, or **deletes** any `.plans/` data (§2 read-only)" — directly contradicted by this feature. Accurate framing: the app never edits `.plans/` files in-process, but DOES drive plans-cc lifecycle skills (capture/elaborate/execute/delete) via the bundled Agent-SDK runner, which is the sole writer — the framing `run-task.ts:24-25` and `ProjectCard.swift:212-214` already use. This was already true before this task; the task corrects the record.
- [x] Step 13: Build and verify. Run `swift build` and `swift test --filter PlanDetailViewTests` for the Swift side. For the Node side, run `npm run build` in `Tools/work-task/` then `./build.sh` — the app loads `run-task.js` from its bundle Resources, so a plain `swift build` would leave the stale script in place.

## Verification
- Open a plan detail window: a "Delete" button appears in the header action row,
  and the old window-dismiss "Close" button is gone.
- Clicking "Delete" raises a confirmation alert naming the plan; Cancel does
  nothing at all (no run starts, plan still present).
- Confirming deletes the plan: the run spinner shows "Deleting", and when it
  finishes the plan disappears from the browser and menu bar without a manual
  refresh.
- The plan's git branch still exists after deletion (`git branch --list` shows
  it) — the app must never delete branches.
- Deleting a `review`-status plan shows the extra unmerged-branch warning in the
  confirmation alert before proceeding.
- `swift build` succeeds and `swift test --filter PlanDetailViewTests` passes.

## Impact Scope
- `Sources/Plans/PlanDetailView.swift` — remove Close button + dismiss property;
  add Delete button, NSAlert confirm, `canDelete`, run-label switch cases.
- `Sources/Plans/TaskRunner.swift` — `RunMode.delete` + the two flag branches.
- `Tools/work-task/run-task.ts` — `Mode` union, arg validation, `buildDeletePrompt`,
  `buildPrompt` dispatch.
- `Tests/PlansTests/PlanDetailViewTests.swift` — `canDelete` predicate tests.
- `desktop-app-spec.md` — correct read-only claims at lines 66-71, 147, 412.

## Assumptions

### Initial (from elaboration)

_The original elaboration's assumptions are void — they all rest on the
superseded window-dismiss reading. The first one is retained because its failure
is the reason this task was reopened._

- [VOID — caused the reopen] ~~Interpreted "Close button to close plans" as an in-view button that dismisses the per-plan detail window (not a write action). **Why:** the app is a strictly read-only viewer (§2).~~ **This was wrong on both counts:** the user meant deleting the plan via `plan-delete`, and the "read-only viewer" premise was already false — `TaskRunner.swift` drives lifecycle skills that mutate `.plans/`. Step 12 corrects the spec.

### Re-elaboration (corrected interpretation)
- [high] "Delete" invokes the existing `plan-delete` skill via the bundled runner rather than deleting the task file directly from Swift. **Why:** `plan-delete` does far more than unlink a file — state-file cleanup, PROGRESS.md stats, HISTORY.md rows, and the `.plans/` commit. Reimplementing that in Swift would duplicate and drift from the skill.
- [high] The in-app `NSAlert` is the real confirmation gate, not `plan-delete`'s own step-6 prompt. **Why:** `run-task.ts` does not allowlist `AskUserQuestion`, so the skill's interactive gates cannot reach the user; the prompt must pre-answer them, which means the only genuine user consent happens in-app before the run starts.
- [high] The delete prompt instructs the skill to KEEP the associated git branch (pre-answering step 7c). **Why:** a single in-app click must never destroy commits. Branch cleanup stays a deliberate terminal action.
- [low] `canDelete` does not gate on task status (any resolvable plan can be deleted), unlike `canWork`/`canElaborate` which gate on `elaborated`/`pending`. **Why:** deletion is valid at every lifecycle stage — that is precisely when you want it for an abandoned plan — with status-specific risk surfaced in the alert text instead. **Verify during execution:** confirm the button still hides while a run is in flight.
- [low] The Delete button sits last in the action row, after the file actions. **Why:** matches where the (removed) Close button sat and keeps the destructive action furthest from the commonly-used Execute/Elaborate buttons. **Verify during review:** the user may prefer it visually separated or right-aligned.
- [low] Deleting the plan currently open in a detail window leaves that window showing a "Plan not found" placeholder rather than auto-closing it. **Why:** the store reload drives the row away, and the existing placeholder branch already handles an unresolvable row; auto-closing would need the `dismiss` action this task is otherwise removing. **Verify during review** — this may be the one place a dismiss call is still warranted.

### Discovered during execution
- [high] Added `case .delete: return "Deleting"` to `modeVerb` in `PlanDetailView.swift` during step 6, ahead of its planned step 10. **Why:** `modeVerb` is a `default`-less exhaustive switch over `RunMode`, so adding the enum case broke `swift build` immediately. This is the minimal build-unblocking line, not the step-10 UI work; the sibling `title` switch has a `default:` and was left untouched.
- [low] Worded the delete prompt's step-6 pre-answer as "the user has ALREADY confirmed this deletion in the app", quoting the skill's exact `(yes/no)` question text back at the agent. **Why:** the skill requires an explicit "yes" and `AskUserQuestion` is not allowlisted, so an ambiguous instruction risks the agent stalling on the gate. Quoting the literal prompt makes the mapping unmistakable.
- [low] The delete prompt forbids `git branch -D` explicitly rather than only selecting "Keep branch". **Why:** step 7c's `AskUserQuestion` is unreachable, so the agent may improvise the branch cleanup by running the command directly; naming the forbidden command closes that path.
- [low] Left `parseArgs` with no dedicated `delete` branch. **Why:** delete carries only `--task-id`, so the existing execute/elaborate fall-through already returns the correct `{ projectRoot, taskId, mode }` shape; a fourth branch would be dead code. Updated that branch's comment to name `delete`.
- [high] Verified `run-task.ts`'s stranded-task guard is gated on `args.mode === "execute"`, so a delete run is not judged against `TERMINAL_TASK_STATUSES`. **Why:** a deleted task's file is gone, which would otherwise read as a false "stranded" signal.
- [low] Type-checked `run-task.ts` via a scratchpad tsconfig pointing at the main checkout's `node_modules`. **Why:** the worktree has no `node_modules`, so `npx tsc` and `-p tsconfig.json` both fail on unresolved `@types/node` / the Agent SDK — an environment artifact, not a code error. The main checkout type-checks clean as a baseline.
- [low] `canDelete` gates on neither `status` nor `isBlocked` and returns an unconditional `true`, keeping the `(status:isBlocked:)` signature anyway. **Why:** a blocked plan is *more* deletable, not less — being blocked is a common reason to abandon a plan — so gating on it would hide the button exactly when it's wanted. The parameters are kept for symmetry with `canWork`/`canElaborate`/`canReElaborate` and so the "always available" rule is an explicit, unit-testable assertion rather than an unstated absence of gating at the call site.
- [low] Kept the `if Self.canDelete(...)` wrapper around the button even though the predicate is currently always true. **Why:** it keeps the call site shaped like its three siblings, so a future decision to gate deletion is a one-line change in the predicate rather than a re-plumbing of the view. The dead-branch cost is zero at runtime.
- [low] Factored the confirmation into a `private static func confirmDelete(row:) -> Bool` rather than inlining the `NSAlert` in the button closure. **Why:** it keeps the action row readable and mirrors the pure-static-helper style already used for `canWork` / `taskFileURL`; the button body stays a two-line "confirm, then run".
- [low] Composed the status-specific warnings as a paragraph appended to a constant lead sentence ("… will be permanently deleted. This cannot be undone."), separated by a blank line, rather than writing three fully distinct `informativeText` strings. **Why:** the permanence warning applies at every status and should not be at risk of being dropped from one branch; the `switch` then only carries what is genuinely status-specific (unmerged branch for `.review`/`.inReview`, uncommitted work for `.inProgress`).
- [high] Modeled the alert directly on the quit-guard at `PlansApp.swift:58-84`: first button destructive + default, second Cancel, `switch runModal()` with `.alertFirstButtonReturn` confirming and `default:` cancelling. **Why:** it is the codebase's only destructive-confirm precedent, and `default:` (rather than an explicit `.alertSecondButtonReturn`) correctly treats Esc/window-close as a cancel — the safe direction for an irreversible action.
- [high] Confirmed step 10 needed no code change: `modeVerb` already returns "Deleting" for `.delete` (added in segment 1), and `title`'s `default:` branch yields "Deleting task #060" for a real task id. **Why:** `.delete` is a real-task-id mode, so it belongs in `title`'s default arm alongside execute/elaborate/reElaborate, not in the synthetic-id `capture` arm.
- [low] Did not re-add `dismiss`, and the earlier open-window prediction is unchanged by this segment. **Why:** the button only starts a run; the plan's disappearance from the store happens later, asynchronously, via the post-run `reload()`. Nothing in the click path knows when (or whether) the delete actually succeeded, so an eager `dismiss()` at click time would close the window even on a failed run. If auto-close is wanted, it belongs in a store-driven reaction to the row vanishing, not in the button.

## Changes

### Superseded (wrong interpretation — reverted by step 5)
- `Sources/Plans/PlanDetailView.swift`: added `@Environment(\.dismiss)` and a
  window-dismiss "Close" button with `.keyboardShortcut(.cancelAction)`; rewrote
  the struct doc comment. Committed as `a56f7b3`.

### Current (commit `df38f53`)
- `Sources/Plans/PlanDetailView.swift`: reverted the window-dismiss Close button and
  `@Environment(\.dismiss)`; added `canDelete(status:isBlocked:)` (unconditional true),
  a "Delete" button (`trash`) in the always-visible action block, and a
  `confirmDelete(row:)` `NSAlert` helper with a destructive primary button. The run
  fires only inside the confirm guard. Corrected the struct doc comment's read-only claim.
- `Sources/Plans/TaskRunner.swift`: added `RunMode.delete` (`usesTaskID` true,
  `usesDescription` false). `spawn` unchanged — it is flag-driven.
- `Tools/work-task/run-task.ts`: added `"delete"` to the `Mode` union, the `--mode`
  validation chain, and the usage string; added `buildDeletePrompt` dispatched BEFORE
  the unguarded `buildExecutePrompt` fallback. The prompt pre-answers both of
  plan-delete's gates (confirm YES; KEEP branch) and explicitly forbids `git branch -D`,
  since `AskUserQuestion` is not allowlisted and the agent could otherwise improvise
  branch deletion via Bash.
- `Tests/PlansTests/PlanDetailViewTests.swift`: `canDelete` asserted across every
  `TaskStatus` (+ nil) crossed with both `isBlocked` values.
- `Tests/PlansTests/TaskRunnerTests.swift`: `.delete` added to the two existing flag
  tests, plus a raw-value round-trip test.
- `desktop-app-spec.md`: rewrote §2 (heading + body), acceptance item 7, and the §4.3
  aside. Also corrected a pre-existing falsehood there — the app DOES write
  `projects.json` on project link via `RegistryWriter`.
- Build: `swift build` clean. Tests: `PlanDetailViewTests` 7/0 failures,
  `TaskRunnerTests` 52/0 failures. `npm run build` (esbuild) succeeded.

**Not yet done — required before manual verification:** a full `./build.sh`. The app
loads `run-task.js` from its bundle `Resources/`, not the repo, so a running Plans.app
still executes the OLD script and the Delete button will not work until the app is
rebuilt and reinstalled.

## Notes
_Additional context_

**Reopened:** Misinterpreted intent. "Close" was built as a window-dismiss button
(`@Environment(\.dismiss)`) on the detail view; it was meant to close/delete the
plan itself via the `plan-delete` skill. Button label corrected to "Delete".

The elaboration's `[low]` assumption justified the window reading with "the app is
a strictly read-only viewer (§2 — never writes `.plans/` data)". That premise is
stale: `TaskRunner.swift` already spawns the Agent SDK to drive `plan-execute` /
`plan-capture` / `plan-elaborate`, which mutate `.plans/`.

Blocking constraint at reopen time: `plan-delete` is `disable-model-invocation:
true`, so the runner cannot invoke it the way it invokes `plan-execute`. The user
is updating `plan-delete` to allow invocation. Deletion is irreversible and
destroys user data — unlike every existing `RunMode` — so an in-app confirmation
is required regardless of approach, and should be the real gate (the runner may
auto-answer the skill's own yes/no prompt).
- [high] Put the `canDelete` test in `PlanDetailViewTests.swift` as the segment named, even though its three siblings (`testCanWorkGating`, `testCanElaborateGating`, `testCanReElaborateGating`) actually live in `TaskRunnerTests.swift`, not in `PlanDetailViewTests.swift` as the plan assumed. **Why:** the sibling tests sit under a "Work this task button gating" MARK in the runner file because they gate *runner* actions; but `PlanDetailViewTests` is the file named for the type under test and already tests other `PlanDetailView` statics (`taskFileURL`). Following the instruction keeps the new test with its type. Noted as a deviation so the split is a deliberate choice, not an oversight.
- [high] Wrote the `canDelete` test as a loop over `TaskStatus.allCases + [nil]` crossed with both `isBlocked` values, rather than enumerating statuses by hand like the sibling gating tests do. **Why:** the contract being pinned is "unconditionally available", which is a statement about *all* inputs; `TaskStatus` is already `CaseIterable`, so a future new status is covered automatically. The sibling tests enumerate manually because they assert a different result per status, which a loop cannot express.
- [high] Rewrote spec §2's heading from "Hard Constraint: Read-Only" to "Hard Constraint: The App Never Writes `.plans/` Itself" and framed the correction as the spec having been *stale since the runner shipped*, not as delete introducing mutation. **Why:** capture/elaborate/execute already wrote `.plans/` before this task; wording it as a new change would misrepresent when the constraint actually lapsed. Verified no other file references the old heading text, so the rename dangles no cross-references.
- [high] Discovered the `(§4.3)` registry aside's neighbouring claim was false and corrected it beyond a scope note: `Sources/Plans/RegistryWriter.swift` DOES write `projects.json` when a project is linked. The old §2 parenthetical ("the app reads it but does not need to write it") and my first-draft replacement ("nothing in the app, runner included, writes `projects.json`") were both wrong. **Why:** the aside itself is still true — nothing rewrites the registry merely to prune stale entries — but the surrounding absolute claim was not, and leaving it would have replaced one stale assertion with another.
- [high] `Tools/work-task/dist/` is gitignored and untracked, so the regenerated `dist/run-task.js` listed in the segment's Impact Scope cannot appear in the commit. **Why:** `Tools/work-task/.gitignore` lists `dist/`, and `git ls-files` shows only the six sources. The bundle is a build artifact reproduced by `build.sh`; the committed change is `run-task.ts`.
- [low] Ran `npm install` in `Tools/work-task` to make the esbuild step runnable. **Why:** the worktree ships no `node_modules`, so `npm run build` failed with `ERR_MODULE_NOT_FOUND: esbuild`; the build also copies the platform-native SDK package, which must be installed on this platform. Both dirs are gitignored, so this leaves no repo footprint.
