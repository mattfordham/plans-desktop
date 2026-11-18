# Add Plan-Capture Option For Each Project

**ID:** 023
**Created:** 2026-06-06T14:23
**Type:** feature
**Status:** completed
**Completed:** 2026-06-06T16:05
**Branch:** feature/023-add-plan-capture-option-for-each-project

## What
Add a "plan-capture" option for each project. In the card header, next to the
project name, add a "+" button. Pressing the button opens a pop-over with an
input field. Submitting passes the entered description off to the plan-capture
agent in the background (similar to the existing elaborate/execute hand-off).

## Why
Adds value by letting a user capture a new plan for any project directly from the
browser window, without leaving the app or switching to a terminal. Today every
per-card/per-row action operates on an *existing* task (Elaborate, Execute); there
is no in-app way to create a brand-new task. A "+" button on the card header closes
that gap and makes the dashboard a capture surface, not just a viewer — while
preserving the strict read-only invariant (§2) by performing the actual file
creation inside the spawned agent process, never inline in the view.

## How
- [x] Step 1: Extend the Node runner contract in `Tools/work-task/run-task.ts` to
      support capture: add `"capture"` to the `Mode` type, add an optional
      `description` field to `Args`, and parse a new `--description <text>` flag in
      `parseArgs`. Require `--description` (and make `--task-id` optional) only when
      `mode === "capture"`; keep `--task-id` required for `execute`/`elaborate`.
- [x] Step 2: Add `buildCapturePrompt(description)` in `run-task.ts` that drives
      the `plan-capture` skill autonomously (`/plan-capture "<description>"`),
      instructing it to capture only (no chaining), record reasonable assumptions
      instead of asking, and leave the new task in `pending`. Wire it into
      `buildPrompt` via a 3-way branch (capture/elaborate/execute) and update the
      usage string in `main`'s missing-args error.
- [x] Step 3: Add `capture` to the `RunMode` enum in `Sources/Plans/TaskRunner.swift`
      and thread an optional `description: String?` through `TaskRun` (new stored
      `let description`, updated `init`) and into `spawn(...)`, appending
      `--description <text>` to `proc.arguments` only when `mode == .capture`. For
      capture runs (no real task id), make `--task-id` conditional so it is omitted.
- [x] Step 4: Add `TaskRunner.capture(projectPath:description:)` that creates a
      `TaskRun` with a synthetic identity key (`"capture:" + projectPath`) and mode
      `.capture`, stores it in `runs`, and starts it — reusing the existing
      `start(projectPath:onFinish:)` / `onAnyRunFinished` reload path so the new
      task surfaces on the next store reload. Guard against a second concurrent
      capture for the same project (mirror the `isRunning` no-op guard in `run(...)`).
- [x] Step 5: Add the "+" button to `ProjectCard.header` in
      `Sources/Plans/ProjectCard.swift`, placed after `Text(project.projectName)`
      (before the `Spacer`). Implement it as an `Image(systemName: "plus.circle")`
      tap target following the existing `RowActionGlyph` interaction pattern (hover /
      press feedback, `.help("Capture a new plan")`) — NOT a `Button` (consistent
      with the file's documented hit-testing note).
- [x] Step 6: Add `@State` to `ProjectCard` for the capture popover: a presented
      flag and the transient input `captureText`. Attach a `.popover` to the "+"
      button containing a `TextField` ("Describe the plan…") plus a submit affordance
      (Return key via `.onSubmit` and/or a small "Capture" button). On submit with
      non-empty trimmed text, call `runner.capture(projectPath:description:)`, clear
      the field, and dismiss the popover.
- [x] 👁 Step 7: Surface capture progress + completion. Reuse the existing
      `RunProgressSheet` popover machinery so an in-flight capture shows a spinner
      with live log, and on finish reload the store (`store.reload()`) so the newly
      created `pending` task appears in the card body. Run the app and confirm the
      "+" → popover → capture → new card row flow end-to-end (agent-unobservable UI).
- [x] Step 8: Add unit tests in `Tests/PlansTests/TaskRunnerTests.swift`:
      `RunMode.capture` round-trips its raw value; a `.capture` `TaskRun` carries
      its description and synthetic identity; and (Node side, if feasible without a
      real run) the capture arg shape includes `--description`. Run `swift test`.

## Verification
- `swift test` passes, including the new capture-mode tests.
- The Node runner accepts `--mode capture --description "<text>" --project-root <p>`
  and rejects capture with a missing `--description` (clear usage error), while the
  existing `execute`/`elaborate` invocations are unchanged.
- Launching the app (`./build.sh`): each project card header shows a "+" button next
  to the project name. Clicking it opens a popover with a text field; submitting a
  description spawns a background capture run, shows progress, and — on completion —
  a new `pending` task row appears in that project's card without any inline
  `.plans/` mutation from the view (read-only invariant intact, §2).

## Impact Scope

### Files to Modify
- [x] `Tools/work-task/run-task.ts` — add `capture` mode, `--description` flag,
      `buildCapturePrompt`, and 3-way prompt branch.
- [x] `Sources/Plans/TaskRunner.swift` — add `RunMode.capture`, optional
      `description` on `TaskRun`/`spawn`, and `TaskRunner.capture(...)`.
- [x] `Sources/Plans/ProjectCard.swift` — add the header "+" button, capture
      popover state, `TextField`, submit action, and progress/reload wiring.
- [x] `Tests/PlansTests/TaskRunnerTests.swift` — capture-mode unit tests.

### Related Files (may need updates)
- `Tools/work-task/dist/run-task.js` — regenerated by `npm run build` (esbuild via
  `build.mjs`); not hand-edited. `build.sh`/`install.sh` rebuild and re-bundle it.
- `Sources/Plans/PlanDetailView.swift` — source of the `canWork`/`canElaborate`
  gating predicates and `RunProgressSheet`; no change expected, but confirm the
  progress sheet renders acceptably for a capture run (no task id).

### Endpoints/UI Affected
- Project card header (Surface B browser) — gains a "+" capture button + popover.
- Background hand-off (`run-task.js`) — gains a third `--mode` value (`capture`).

## Assumptions

### Initial (from elaboration)
- [high] Extend the existing `run-task.js` hand-off with a new `capture` mode +
  `--description` flag rather than driving capture via a separate script. **Why:**
  the runner already centralizes every `.plans/`-writing hand-off behind one NDJSON
  contract keyed on `--mode`; adding a third mode reuses `TaskRun`/`TaskRunner`,
  the progress UI, and the read-only invariant with no new coupling surface. The
  task Notes explicitly flagged this as option (a) and to confirm the runner shape
  first — confirmed it is the natural fit.
- [low] Key the in-flight capture `TaskRun` by a synthetic identity
  (`"capture:" + projectPath`) since no real task id exists at capture time.
  **Why:** `TaskRunner.runs` is a `[String: TaskRun]` keyed by task id and the
  popover/spinner machinery assumes a stable key; a per-project synthetic key gives
  at most one capture in flight per project and reuses all existing plumbing. No
  prior example of a keyless run existed in the codebase, so this is a judgement call.
- [low] Render the "+" button using the existing `RowActionGlyph` interaction
  style (tap-gesture primitive, hover/press feedback) rather than a SwiftUI
  `Button`. **Why:** `ProjectCard.swift` documents that nested borderless `Button`s
  hit-test unreliably on macOS in this layout and uses the tap-gesture primitive
  everywhere; matching it keeps behavior consistent. The header is a slightly
  different context than a Grid row, hence flagged for review.
- [low] Capture popover uses SwiftUI `.popover` with a `TextField` whose presented
  state and transient text live as `@State` on `ProjectCard`. **Why:** matches the
  capture Notes' suggestion and the card's existing `@State`-driven popover pattern
  (`progressPopoverTaskID`); a heavier model/binding wasn't justified for a single
  transient input.
- [high] Actual task-file creation happens only inside the spawned agent process,
  never inline in the view. **Why:** `ProjectCard` is documented as strictly
  READ-ONLY (§2) with the bundled agent as the sole `.plans/` writer; the capture
  button preserves that by handing the description to `run-task.js`, mirroring the
  elaborate/execute path.

### Discovered during execution
- [high] Made `Args.taskId` optional and added optional `Args.description`, returning a `{projectRoot, mode, description}` shape for capture vs `{projectRoot, taskId, mode}` for execute/elaborate. **Why:** capture has no pre-existing task id; mirrors the plan's explicit instruction to require `--description` only for capture.
- [low] `buildCapturePrompt` issues `/plan-capture "<description>"` with explicit "capture only, no chaining, record assumptions instead of asking, leave in pending" instructions, closely modeled on the existing `buildElaboratePrompt` wording. **Why:** there is no plan-capture reference prompt in the repo to copy; chose to match the established autonomous-elaborate style for consistency.
- [low] In `spawn`, build `proc.arguments` incrementally and omit `--task-id` entirely for capture (passing `--description` instead when non-empty). **Why:** plan says omit task-id for capture; chose an incremental array over conditional placeholders to keep the argv clean and avoid sending an empty/synthetic task id to the runner.
- [high] `TaskRunner.capture` uses synthetic key `"capture:" + projectPath` as both the map key and the `TaskRun.taskID`, with a no-op guard mirroring `run(...)`. **Why:** directly specified by the plan.
- [high] Added a `.capture` case to the `modeVerb` switch in `PlanDetailView.swift` (a non-listed file) returning "Capturing". **Why:** the new enum case made an existing exhaustive switch fail to compile; minimal inline fix required to keep the build green. Noted as a deviation.
- [high] In `ProjectCard.header`, the capture control is a single `@ViewBuilder` `captureControl` that swaps between the "+" `RowActionGlyph` (with the capture `TextField` popover) and a tappable progress spinner when `runner.isRunning(taskID: captureKey)`. **Why:** the plan's preferred "+"/spinner swap; consolidating both states in one builder keeps the header HStack clean and mirrors `rowActions`.
- [high] Reused the existing single `progressPopoverTaskID` + `progressPopover(for:)` state for the capture progress popover, keyed on `captureKey` = `"capture:" + projectPath`. **Why:** plan prefers reuse; the synthetic key is a valid distinct id that won't collide with real 3-char task ids, so no dedicated state was needed.
- [low] The capture popover content shows a `"New plan for <projectName>"` caption above the `TextField`, a real `Button("Capture")` with `.keyboardShortcut(.defaultAction)`, and `.onSubmit`, both routed through a shared private `submitCapture()`. **Why:** plan allows a real Button inside popover content; the caption + default-action shortcut clarify context and let Return submit. Width fixed at 280 with 14pt padding per the plan.
- [low] Empty/whitespace capture submit is ignored (guard returns early) WITHOUT dismissing the popover, leaving the field open for correction. **Why:** plan offered the choice and preferred ignoring empty submit; keeping the popover open is the least surprising of the allowed behaviors.
- [low] The capture spinner uses `.padding(.leading, 0)` (vs `rowActions`'s `.padding(.leading, 8)`). **Why:** in the header the spinner sits right after the project name where the glyph's own leading inset is unwanted; the rowActions leading padding exists to separate it from the title text in the grid cell.
- [high] Step 8 added three characterization tests (GREEN-only, impl already exists): `testCaptureModeRoundTripsRawValue`, `testCaptureRunCarriesDescriptionAndSyntheticIdentity` (`@MainActor`), `testNonCaptureRunHasNilDescriptionByDefault` (`@MainActor`). **Why:** mirrors the existing `testCoordinatorTracksRunsPerTask` style; capture functionality was already implemented in segments 1-2, so the documented GREEN-only characterization path applies (no RED phase).
- [high] Skipped item 4 (Node-side `--description` arg-shape test) as a pure-test stand-in instead of a real test. **Why:** the Swift test target does not exercise `run-task.ts`/its bundle and there is no JS test harness; spawning a real `node` process would introduce flakiness. The arg shape is verified by inspection of `TaskRun.spawn`, and the synthetic-key contract is covered by the `TaskRun` identity test — documented in a code comment in the new MARK section rather than executed.

## Changes
Added a per-project "+" capture button to the browser card header. Clicking it
opens a popover with a multi-line description field, an "Execute" checkbox, and a
submit button (⌘↩ submits; plain Return inserts a newline). Submitting hands the
description to a background agent run: capture-only (`plan-capture`, leaves the
task `pending`) by default, or — when "Execute" is ticked — a
`plan-execute "<description>" yolo` run (new `executeYolo` mode) that
auto-captures, elaborates, and executes the new task in an isolated worktree,
leaving it in `review`. The read-only invariant (§2) is preserved: the spawned
Agent-SDK process is the sole `.plans/` writer.

- `Tools/work-task/run-task.ts`: added `capture` + `executeYolo` modes, the
  `--description` flag (required for both, with `--task-id` omitted), a 4-way
  `buildPrompt` branch (`buildCapturePrompt` / `buildExecuteYoloPrompt`), and
  `"Skill"` on the SDK `allowedTools` (without it the skill invocation was denied).
- `Sources/Plans/TaskRunner.swift`: added `RunMode.capture` + `.executeYolo`, the
  optional `TaskRun.description`, the description-vs-task-id arg split in `spawn`,
  a nonisolated `captureKey(projectPath:)` helper, and
  `TaskRunner.capture(projectPath:description:execute:)` with a per-project
  concurrent-run guard.
- `Sources/Plans/ProjectCard.swift`: header "+" `CaptureGlyph` (status-badge
  sized) placed right of the project name / left of the git status, swapping to a
  size-matched spinner (no layout shift) while a run is in flight; a `.popover`
  with a multi-line `TextEditor` (overlaid placeholder), an "Execute" checkbox,
  and a ⌘↩-submitting button; reuse of the `RunProgressSheet` progress machinery
  keyed on the synthetic capture id with reload-on-dismiss.
- `Sources/Plans/PlanDetailView.swift`: `modeVerb` cases for the new modes and a
  `title` that drops the "task #<id>" suffix for synthetic-key capture runs;
  reduced `RunProgressSheet` padding (20→12).
- `Tests/PlansTests/TaskRunnerTests.swift`: tests for `executeYolo` round-trip +
  description, and the mode-independent per-project `captureKey`.

## Notes
Implementation pointers gathered during capture (not yet elaborated):

- The "+" button belongs in `ProjectCard.header` (`Sources/Plans/ProjectCard.swift`),
  next to `Text(project.projectName)`. The header currently is not a tap target;
  the button would be a new, independent control there.
- The background hand-off should mirror the elaborate/execute path in
  `Sources/Plans/TaskRunner.swift`. Today `RunMode` has only `.execute` and
  `.elaborate`, and `TaskRun.spawn` invokes the bundled `work-task/run-task.js`
  with `--task-id`/`--mode`. plan-capture differs from those: it creates a NEW
  task rather than acting on an existing `--task-id`, so elaboration must work out
  whether to (a) add a `.capture` mode + a description argument to the Node runner,
  or (b) drive capture some other way. Confirm the bundled runner / underlying
  agent supports a capture entry point before assuming the existing arg shape fits.
- The pop-over should use SwiftUI `.popover` with a `TextField` and a submit
  action; consider where the transient input text and presented-state live
  (likely `@State` on `ProjectCard`).
- The card is documented as strictly READ-ONLY (§2 in `ProjectCard.swift`): the
  only writer of `.plans/` is the bundled agent process. A capture button keeps
  that invariant only if the actual file creation happens in the spawned agent,
  not inline in the view — call this out during elaboration.
- `project.projectPath` is available on the card for the spawn's `--project-root`.
