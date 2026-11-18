# Support Plans With IDs >999

**ID:** 090
**Created:** 2026-10-07T00:00
**Type:** bug
**Status:** completed
**Completed:** 2026-10-07T16:07
**Branch:** fix/090-support-plans-with-ids-999

## What
Update to support plans with IDs >999.

Fix: task IDs ≥ 1000 are truncated to 3 digits. plans-cc task IDs are zero-padded to a
**minimum** of 3 digits, not exactly 3. Past task 999, filenames look like
`1000-some-slug.md` / `1001-other.md`. The app reads the ID as the first 3 characters of
the filename, so both display as `100`; distinct tasks collapse onto one ID and anything
keyed on the ID (list identity, blocked-by resolution, drill-down selection) can mix them
up. IDs 001–999 are unaffected.

The source-of-truth parser (`lib/parse-tasks.js` in plans-cc) has been fixed — mirror it
exactly. Spec: `~/Work/Open Source/plans/.plans/artifacts/desktop-app-spec.md`
(§5.2, §5.3, §5.5).

Required changes:
1. **ID extraction** (pending + completed task files): leading digit run before the first
   `-` — regex `^(\d+)-`, capture group 1. Fallback when it doesn't match: first 3
   characters, as before. `1000-foo.md` → `"1000"`; `042-bar.md` → `"042"`. Keep the ID a
   **string** (preserves zero padding for display).
2. **Completed-ID set** (blocked computation): built with the same extraction.
3. **`**Blocked by:**` parsing**: split on commas and whitespace; a token is a valid ID only
   if it matches `^#?(\d{3}|[1-9]\d{3,})$` (exactly 3 digits, or 4+ digits with no leading
   zero). `#0430` rejected as malformed; `#1000` and `1000` accepted. A task is blocked if
   any of its blocker IDs is not in the completed-ID set.
4. **Sorting**: compare IDs **numerically**, never as strings.
   - Active tasks: status priority (`in-progress > in-review > review > elaborated >
     pending`), then ID ascending numerically.
   - Any "recently completed" list: date descending, ties broken by ID descending,
     numerically.
   - Check every other place the app sorts by task ID.
5. **Identity and keys**: wherever the ID is used as a list/row identity, cache key,
   selection key, etc., use the full untruncated ID together with the project path.
6. **Display**: if the ID column is fixed-width or truncates, let it fit 4+ digits without
   clipping. 3- and 4-digit IDs side by side should line up reasonably; clipping is the bug.
7. **`**ID:**` header field**, if read: treat it as a string of 3+ digits, never a number.

Tests:
- `1000-a.md` and `1001-b.md` → `"1000"` and `"1001"`, distinct, no collision.
- `998`, `999`, `1000` sort in that order.
- `**Blocked by:** #1000` is blocked while `1000-*.md` is in `pending/`, unblocked once in
  `completed/`.
- `**Blocked by:** #0430` yields no blocker.
- Regression: `001`–`999` extract, display and sort exactly as before.

Manual check: in a registered project, add `.plans/pending/1000-test-a.md` and
`1001-test-b.md` with matching `**ID:**` lines; confirm the menu bar and browser window show
two distinct, untruncated IDs ordered after 999. Remove the files afterwards.

Out of scope: ID allocation (`next_id`) — already produces `1000` correctly.

## Why
Improves reliability by fixing ID truncation for tasks numbered 1000+. Projects past task 999
(e.g. Client A already has `1000-*.md` / `1001-*.md` alongside a completed `100-*.md`) show
colliding `100` rows, open the wrong detail, share spinners, and — worst — send
`/plan-execute 100` / `/plan-delete 100` at an unrelated real task #100.

## How Summary
Replace the fixed 3-character filename slice in `TaskParser` with the plans-cc leading-digit-run
rule (ASCII digits before the first `-`, 3-char fallback), validate `**Blocked by:**` tokens with
`^#?(\d{3}|[1-9]\d{3,})$` (which also fixes `#`-prefixed blockers never resolving), and switch
ID tiebreaks to a total numeric compare. Then make `TaskRunner`'s run map key on project path +
full ID, harden the ID column for wider IDs, and bring the local spec in line with plans-cc.

**Files of note:**
- `Sources/Plans/TaskParser.swift` — ID extraction (:751), completed set (:591), blocked-by (:841), sorts (:621, :640)
- `Sources/Plans/TaskRunner.swift` — `runs` keyed by bare task ID (:939–1214)
- `Sources/Plans/ProjectCard.swift` — ID cell (:1004) and `RowColumns.idWidth` (:300)
- `desktop-app-spec.md` — §5.2/§5.3/§5.5 still describe `filename[0..<3]`
- `Tests/PlansTests/TaskParserTests.swift` — fixture pattern to extend

## Diagnosis
**Most likely:** `TaskParser.parse` derives the ID as `String(filename.prefix(3))`
(`Sources/Plans/TaskParser.swift:751`), so `1000-a.md` and `1001-b.md` both become `"100"`.
Every downstream consumer (row identity, completed set, runs, file lookup, CLI `--task-id`) reads
`Task.id`, so the truncation propagates everywhere.
**Evidence:** `TaskParser.swift:751`; doc comments at :111 / :749–750 and local spec §5.2 codify the
3-char rule; live data in `~/Work/client-a/.plans/pending/1000-*.md`, `1001-*.md` render as `100`.
**Confidence:** high
**Alternative:** independent existing bug — `parseBlockedBy` (:841–847) keeps raw tokens with no
`#` stripping/validation, so `#043`-style blockers never match `completedIds` (confidence: high;
fixed by the same requirement-3 change).
**Alternative:** string-compare ID sorts (:621, :640) would mis-order `1000` before `998` even
after the extraction fix (confidence: high; must change in the same edit).
**To confirm:** a unit test asserting `parse(filename: "1000-a.md", …).id == "1000"` fails today with `"100"`.

## How
- [x] Step 1: Write failing `TaskParserTests` that confirm the diagnosis and pin the new contract: `1000-a.md`/`1001-b.md` → `"1000"`/`"1001"` (distinct); `998`,`999`,`1000` sort ascending numerically in `activeTasks` (and backlog); `**Blocked by:** #1000` blocked while `1000-*.md` in `pending/`, unblocked once in `completed/`; `**Blocked by:** #0430` yields no blocker; `#043`/`043` blockers resolve against `completed/043-*.md`; regression — `001`/`042`/`999` extract and sort exactly as before; non-matching filename falls back to first 3 chars. Run `swift test --filter TaskParserTests` and confirm the new cases fail.
- [x] Step 2: Fix `Sources/Plans/TaskParser.swift`: extract the ID as the leading ASCII-digit run before the first `-` (fallback `prefix(3)`), keep it a `String`; `completedIds` inherits it; rewrite `parseBlockedBy` to split on commas/whitespace and keep group 1 of `^#?([0-9]{3}|[1-9][0-9]{3,})$` (ASCII only); add a total numeric ID comparator (leading-zero-stripped length, then string — safe for non-numeric fallbacks/huge runs) and use it for the active (:621) and backlog (:640) tiebreaks, keeping the existing status-priority order. Update the stale doc comments (:111, :144, :729–750, :838). Make Step 1's tests pass.
- [x] Step 3: Re-key `TaskRunner.runs` (and `run(for:)`, `isRunning`, `stop`, `dismiss`, `reconcile`'s claimed set) on project path + full task ID so `1000` vs `100` and same-ID-across-projects never share a run entry; update call sites in `ProjectCard.swift`, `PlanDetailView.swift`, `PlansApp.swift`, `NewPlanModal.swift`. TDD in `TaskRunnerTests` (cross-project same ID independent; `1000` and `100` independent; capture reconcile detects a new `1002` task).
- [x] Step 4: Display/lookup hardening: give the ID `Text` in `ProjectCard.planRow` `.lineLimit(1)` and size `RowColumns.idWidth` to at least the measured monospaced width of a 5-digit ID (add a `ProjectCardTests` measurement test mirroring `testTypeColumnFitsMeasuredWidestLabel`); add `PlanDetailViewTests` cases that `taskFileURL` for `1000` finds `1000-*.md` and for `100` does NOT match `1000-*.md`.
- [x] Step 5: Update the local `desktop-app-spec.md` §5.2 / §5.3 / §5.5 to match the plans-cc spec (`~/Work/Open Source/plans/.plans/artifacts/desktop-app-spec.md`): min-3-digit IDs, digit-run extraction, blocked-by token regex, numeric ID ordering — preserving this app's backlog extension (§5.5 step 9) and the deliberate #028 status-priority order note.
- [x] Step 6: 👁 Manual check: in a scratch registered project (NOT Client A — its real completed `100-*` makes actions on 1000/1001 dangerous pre-fix), add `.plans/pending/1000-test-a.md` and `1001-test-b.md` with matching `**ID:**` lines; confirm the browser window shows two distinct untruncated IDs ordered after 999, hover/selection/detail are independent. (The menu bar shows counts only, no IDs.) Remove the files afterwards.

## Verification
- `swift test --filter TaskParserTests`, `TaskRunnerTests`, `ProjectCardTests`, `PlanDetailViewTests` pass, including new 1000+ cases
- `1000-a.md` / `1001-b.md` parse to `"1000"` / `"1001"`; `998, 999, 1000` order ascending
- `**Blocked by:** #1000` blocked until `1000-*.md` is in `completed/`; `#0430` never a blocker
- Browser window shows two distinct, unclipped rows `1000` and `1001` after `999`; each opens its own detail

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/TaskParser.swift` — ID extraction, blocked-by validation, numeric sorts, comments
- [ ] `Sources/Plans/TaskRunner.swift` — run map keyed on (project path, task ID)
- [ ] `Sources/Plans/ProjectCard.swift` — run lookups by path+ID; ID column lineLimit/width
- [ ] `Sources/Plans/PlanDetailView.swift` — run lookups by path+ID
- [ ] `Sources/Plans/PlansApp.swift` — run lookup call site
- [ ] `Sources/Plans/NewPlanModal.swift` — capture baseline/reconcile call site
- [ ] `desktop-app-spec.md` — §5.2/§5.3/§5.5
- [ ] `Tests/PlansTests/TaskParserTests.swift`, `TaskRunnerTests.swift`, `ProjectCardTests.swift`, `PlanDetailViewTests.swift` — new cases

### Related Files (may need updates)
- `Sources/Plans/BrowserWindow.swift` — `TaskRow.id` already `path + "/" + id`; correct once ID is full
- `Sources/Plans/PlansStore.swift` — `RunOutcomeKey(projectPath:taskID:)` already path-scoped
- `Tools/work-task/run-task.ts` — passes `--task-id` through verbatim; correct once ID is full

### Endpoints/UI Affected
- Browser window plan rows — distinct, unclipped 4+ digit IDs, correct ordering/hover/selection
- Plan detail window, run spinners/progress, Execute/Delete actions — target the right task

## Assumptions

### Initial (from elaboration)
- [low] Kept the existing #028 active status order (in-review > review > in-progress > elaborated > pending) and changed only the ID tiebreak to numeric, rather than adopting plans-cc's in-progress-first order. **Why:** the current order was a deliberate user decision locked by `testActiveTasksSortedByStatusPriorityThenId`; the >999 bug only requires the numeric tiebreak.
- [low] Re-key `TaskRunner.runs` on project path + task ID in this task. **Why:** requirement 5 asks for full ID + project path on every key; `runs` is the only key lacking the path, though it widens the change across several views.
- [low] Size the ID column for 5-digit IDs and add `.lineLimit(1)`. **Why:** 40pt already fits 4 digits; small widening makes 10000+ safe without a layout redesign.
- [high] No "recently completed" list exists in the app, so the date-desc/ID-desc requirement is a no-op. **Why:** research found completed tasks appear only in counts.
- [high] `**ID:**` header is not read anywhere; nothing to change. **Why:** `frontmatterValue` callers are only Created/Type/Status/Branch/Worktree/Blocked by.
- [high] Use ASCII-only digit matching. **Why:** Swift `\d` matches non-ASCII digits, JS `\d` doesn't — mirroring plans-cc exactly requires `[0-9]`.
- [low] `taskFileURL` not searching `backlog/` is left out of scope. **Why:** separate existing gap unrelated to >999.
- [low] Update local `desktop-app-spec.md` in this task. **Why:** it codifies the 3-char rule and is the authoritative spec per CLAUDE.md.

### Discovered during execution
- [low] `TaskParser.idPrecedes` orders all-ASCII-digit ids before non-numeric fallback ids (e.g. `"rea"`), and breaks same-value/different-padding ties (`"42"` vs `"042"`) by raw string. **Why:** the comparator must be total for `sorted`; plans-cc's `Number(a) - Number(b)` yields NaN for fallbacks, so there is no source behavior to mirror — numeric-first is the least surprising choice.
- [low] Kept `TaskRunner.runs` as `[String: TaskRun]` with a `"path\u{0}id"` string key (`runKey(projectPath:taskID:)`) rather than a Hashable struct. **Why:** the static `reconcile(runs:)` / `taskIDsToDismiss(runs:)` test surface passes `[run.taskID: run]` dictionaries for synthetic capture runs; leaving synthetic `capture:<path>:<UUID>` ids as their own key keeps all existing reconcile/rekey tests source-compatible.
- [low] New lookup API is `run(for:in:)`, `isRunning(taskID:in:)`, `stop(taskID:in:)`, `dismiss(taskID:in:)` (old single-arg forms removed). **Why:** `run(projectPath:taskID:)` would collide with the existing launcher `run(projectPath:taskID:mode:...)`; removing the old forms makes the compiler catch every unscoped call site.
- [low] Synthetic capture ids are detected by the bare `capture:` prefix (`isSyntheticCaptureID`), not the full `captureKey(projectPath:)` prefix. **Why:** real task ids are digit runs or ≤3-char fallbacks, so they can never start with `capture:`; the simpler check is robust to test fixtures whose synthetic id path differs from the run's `projectPath`.
- [low] Reconcile's "claimed" id set is now per project (from each run's `runProjectPath`), not global. **Why:** requirement 5 — an existing run for `002` in another project previously blocked this project's capture from handing off to its new `002`.
- [high] Run keys use the raw project path (no standardization). **Why:** matches `RunOutcomeKey`, and launcher and lookup call sites both pass `TaskRow.projectPath` / `ProjectTasks.projectPath` from the same registry source.
- [high] Added `TaskRunner.stopAllRunning()` for the quit path instead of iterating `runs` keys in `PlansApp`. **Why:** the keys are now composite and opaque to callers.
- [high] `NewPlanModal.swift` needed no change. **Why:** its `knownTaskIDs` baseline is built from `Task.id`, which is now the full id; the run-map key isn't involved.
- [low] `RowColumns.idWidth` set to `5 * 8.5` (42.5pt), up from 40, using the same nominal `monospaceCharacterWidth` the type column uses. **Why:** a 5-digit id measures 40.18pt at the 13pt monospaced body face, just over 40; 42.5 adds ~2.3pt of slack and shifts the type/title columns right by only 2.5pt. 3-digit ids stay leading-aligned. 6+ digit ids are not budgeted (`.lineLimit(1)` keeps them on one line; they would overflow the frame rather than wrap).
- [low] The local spec's §5.2 documents the 3-char fallback for non-matching filenames, even though the plans-cc spec §5.2 doesn't mention it. **Why:** the task's requirement 1 and `parse-tasks.js` both define the fallback, and the app implements it, so the local spec should describe what the app does.
- [high] `PlanDetailView.taskFileURL` needed no change. **Why:** it matches on `taskID + "-"`, so the dash already keeps `100` from matching `1000-*.md`. New tests pin that behavior.

## Changes
### Segment 1 (steps 1-3)
- `TaskParser.swift`: new `extractId(fromFilename:)` (leading ASCII-digit run before `-`, 3-char fallback); `parseBlockedBy` strips `#` and validates `^#?([0-9]{3}|[1-9][0-9]{3,})$`; new total `TaskParser.idPrecedes` numeric comparator for active/backlog tiebreaks (status priority unchanged); stale 3-char doc comments updated.
- `TaskRunner.swift`: runs keyed by `runKey(projectPath:taskID:)` (`path + "\u{0}" + id`); capture keys unchanged; lookups now `run(for:in:)`, `isRunning(taskID:in:)`, `stop(taskID:in:)`, `dismiss(taskID:in:)`; added `stopAllRunning()`; capture hand-off claims IDs per project.
- Call sites updated: `ProjectCard.swift`, `PlanDetailView.swift`, `PlansApp.swift` (quit path uses `stopAllRunning()`).
- Tests: 11 new `TaskParserTests`, 4 new `TaskRunnerTests`.

### Segment 2 (steps 4-6)
- `ProjectCard.swift`: `RowColumns.idWidth` 40 → `5 * 8.5` (fits a measured 5-digit ID); ID `Text` gets `.lineLimit(1)`; left alignment unchanged.
- `desktop-app-spec.md`: §5.2/§5.3/§5.5 updated to min-3-digit IDs, digit-run extraction (3-char fallback), blocked-by token regex, numeric ID ordering; notes this app's deliberate #028 status order; backlog rule kept.
- Tests: `ProjectCardTests.testIdColumnFitsMeasuredFiveDigitId`; two `PlanDetailViewTests` `taskFileURL` cases (`1000` vs `100-`); `TaskParserTests.testThousandPlusPendingFilesListDistinctAfter999` as a programmatic stand-in for step 6.
- Step 6 (👁 manual check) deferred to review — not run.
- Review note: `activeTasks` doc comment in `TaskParser.swift` (~line 307) still lists the plans-cc status order rather than the app's in-review-first order (pre-existing).

## Notes
_Additional context_
