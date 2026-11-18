# Add Project Wide "Discuss" Option

**ID:** 110
**Created:** 2026-11-08T14:38
**Type:** feature
**Status:** completed
**Completed:** 2026-11-08T15:08
**Branch:** feature/110-add-project-wide-discuss-option

## What
Add Project wide "Discuss" option. This would open a conversation using plan-discuss but with no provided ID.

## Why
Adds value by letting the user hold a free-form, whole-project conversation with
`plan-discuss` — which supports a no-ID "discuss the whole backlog" mode — directly
from the desktop app. Today the app can only discuss a single plan (#099): the
discuss pipeline hard-wires a `--task-id`, so the whole-backlog mode plans-cc already
supports is unreachable in the UI. This closes that gap with a per-project affordance.

## How Summary
Extend the existing #099 discuss pipeline end-to-end to allow a discussion with no
task id (the whole-project / backlog case), rather than inventing a new mechanism.
The bundled Node runner is taught to accept a `discuss` run that carries only a
`--description` (the question) with no `--task-id`, emitting a bare `/plan-discuss`
(whole-backlog) prompt in that case. The Swift argument builder omits `--task-id`
for an empty id. `TaskRunner`'s discussion API gains a project-scoped thread (keyed
by project path with an empty task id) via a thin `askProject`/`projectThread`
pair that reuse all the existing per-task plumbing. The UI surfaces a "Discuss"
button in the single-project `TaskListView` header that opens a sheet reusing the
existing transcript + composer so the whole-project conversation renders identically
to the per-plan one — keeping the three-column layout (and its #096 layout-loop
history) untouched.

**Files of note:**
- `Tools/work-task/run-task.ts` — make `--task-id` optional for `discuss`; emit a bare `/plan-discuss` when absent.
- `Sources/Plans/TaskRunner.swift` — omit `--task-id` for empty id in `arguments`; add project-scoped discussion helpers.
- `Sources/Plans/ProjectDiscussionView.swift` — new sheet reusing the transcript + composer for a whole-project conversation.
- `Sources/Plans/TaskListView.swift` — add a "Discuss" button to the single-project header that raises the sheet.
- `Sources/Plans/PlanDetailView.swift` — reuse its pure discuss predicates (`discussSubmission` / `canSendDiscussion`) and transcript/turn views; extract shared pieces if needed.
- `Tests/PlansTests/TaskRunnerTests.swift` — arg-shape + project-thread unit tests.

## How
- [x] Step 1: (TDD) Add failing tests in `Tests/PlansTests/TaskRunnerTests.swift` for the new arg shape: `TaskRun.arguments(... mode: .discuss, taskID: "")` must omit `--task-id` (producing `--project-root <p> --description <q> --mode discuss`), while a non-empty id still emits it. Add a test that `TaskRunner.askProject(projectPath:question:)` creates a project-scoped `DiscussionThread` resolvable via `projectThread(projectPath:)`, distinct from a per-task thread.
- [x] Step 2: In `Sources/Plans/TaskRunner.swift`, change `TaskRun.arguments` so the `--task-id` flag is emitted only when `mode.usesTaskID` AND `!taskID.isEmpty` (guarding the empty-id project-discuss case; all existing non-empty-id call sites are unchanged). Keep `--description` behaviour as-is.
- [x] Step 3: In `TaskRunner`, add a project-scoped discussion API that reuses the existing plumbing: a `projectThread(projectPath:)` read-only accessor and an `askProject(projectPath:question:)` that key the thread on `runKey(projectPath:taskID: "")` (empty id = whole-project), launch a `.discuss` `TaskRun` with an empty `taskID` + the question as `description`, hold it on the thread exactly like `ask(...)`, and never enter `runs`. Factor the shared body of `ask`/`askProject` to avoid duplication where clean.
- [x] Step 4: In `Tools/work-task/run-task.ts`, split the `discuss` branch of `parseArgs` out of the combined `reElaborate || discuss` check so `discuss` requires only a `--description` with `taskId` OPTIONAL (reElaborate still requires both). Thread the optional `taskId` through to the returned `Args`.
- [x] Step 5: In `run-task.ts`, update `buildDiscussPrompt` / `buildDiscussFollowUpPrompt` to emit a bare `/plan-discuss` (whole-backlog) and whole-project read-only wording when `taskId` is empty/undefined, and the existing `/plan-discuss ${taskId}` per-task wording when present. Leave `DISCUSS_ALLOWED_TOOLS` (already project-wide read-only) unchanged. Rebuild the bundled JS via `Tools/work-task/build.mjs`.
- [x] Step 6: Add `Sources/Plans/ProjectDiscussionView.swift` — a sheet view that renders the whole-project discussion: the existing transcript (reusing `PlanDetailView`'s turn rendering / `MarkdownStyle.compact`) above the existing composer, bound to `runner.projectThread(projectPath:)` and sending via `runner.askProject(projectPath:question:)`. No GeometryReader / self-measurement (#096). A title naming the project.
- [x] Step 7: In `Sources/Plans/TaskListView.swift`, add a "Discuss" button to the single-project `projectHeader` (beside "New Plan", shown only when `project != nil`) that raises a view-local `@State` sheet presenting `ProjectDiscussionView` for `project.projectPath`.
- [ ] 👁 Step 8: Build and run the app (`./build.sh`), open a single project in the browser, click "Discuss", ask a whole-project question, and confirm a reply streams back and renders — verifying the end-to-end no-ID discuss works and nothing in the plan files is modified. _(Observation deferred to review — compilation verified via `swift build`.)_

## Verification
- `swift test` passes for the new and existing `TaskRunnerTests` (arg shape omits `--task-id` for empty id; project thread is created and resolvable).
- The bundled `run-task.js` rebuilds cleanly and `parseArgs` accepts a `discuss` run with `--description` but no `--task-id`.
- In the running app, a single project's header shows a "Discuss" button that opens a conversation; asking a question streams a reply and leaves all `.plans/` files unchanged (read-only).
- Per-plan discuss (#099) still works unchanged.

## Impact Scope

### Files to Modify
- [ ] `Tools/work-task/run-task.ts` — optional `--task-id` for discuss; bare `/plan-discuss` prompt when absent.
- [ ] `Sources/Plans/TaskRunner.swift` — omit `--task-id` for empty id; project-scoped discussion helpers.
- [ ] `Sources/Plans/TaskListView.swift` — "Discuss" button + sheet in the single-project header.
- [ ] `Tests/PlansTests/TaskRunnerTests.swift` — new arg-shape and project-thread tests.

### New Files
- [ ] `Sources/Plans/ProjectDiscussionView.swift` — whole-project discussion sheet.

### Related Files (may need updates)
- `Sources/Plans/PlanDetailView.swift` — source of the reusable pure discuss predicates and transcript/turn views; may need a small extraction so both surfaces share them.
- `Sources/Plans/DiscussionThread.swift` — reused verbatim (no task id baked in); no change expected.

### UI Affected
- Single-project content view header (`TaskListView.projectHeader`) — gains a "Discuss" button.
- A new project-discussion sheet rendering the whole-project conversation.

## Assumptions

### Initial (from elaboration)
- [low] Surface the project-wide Discuss as a button in the single-project `TaskListView.projectHeader` that opens a sheet (not an inline split like the per-plan panel). **Why:** research named three candidate homes (single-project header/footer, ProjectCard in the stack, menu bar) and recommended the single-project view; a sheet reuses the existing conversation UI with the least risk and deliberately avoids the card stack's documented #096 layout-loop hazard (ProjectStackView must never measure its own size). Keyword order/product polish deferred to review.
- [low] Key the project thread on `runKey(projectPath:taskID: "")` (empty task id = whole-project). **Why:** `runKey` joins path + NUL + id and a real task id is always digits, so an empty id can never collide with a real plan's thread or run; this reuses the existing keying/plumbing rather than adding a parallel map. An alternative sentinel string (e.g. "project") would work equally but empty-string is the minimal, least-surprising choice.
- [high] Extend the existing #099 discuss pipeline end-to-end rather than adding a clipboard/terminal/URL-scheme mechanism. **Why:** the app already runs `plan-discuss` via the bundled Node runner and has a full in-app conversation UI (research confirmed the only gap is the forced `--task-id`); reusing it matches the sole established precedent and the task's own wording ("open a conversation using plan-discuss").
- [high] Keep the whole-project discuss strictly read-only, matching the per-task hand-off. **Why:** `DISCUSS_ALLOWED_TOOLS` is already project-wide read-only (`Skill`/`Read`/`Glob`/`Grep`) and the per-task prompt already forbids applying changes; the whole-backlog prompt must carry the same constraint so a project-wide conversation can never mutate many plans at once.

### Discovered during execution
- [high] Factored the shared body of `ask`/`askProject` into a private `launchDiscuss(thread:projectPath:taskID:question:)` helper; `ask` and `askProject` became thin wrappers that only differ in which thread they resolve (per-task vs project, keyed on empty id) and which id they pass. **Why:** the plan's Step 3 explicitly asked for this extraction to avoid duplication; `ask`'s observable behaviour is byte-identical because the helper is the verbatim old body with `thread`/`taskID` lifted to parameters.
- [low] Added a `projectThreadOrCreate(projectPath:)` accessor that delegates to `thread(projectPath:taskID: "")`, mirroring the per-task create-or-get. **Why:** the plan suggested a `projectThreadOrCreate`-style accessor; delegating to the existing `thread(...)` (rather than duplicating its create logic) keeps a single source of truth for thread creation/keying.
- [low] Placed the new project-discuss tests in `Tests/PlansTests/TaskRunnerTests.swift` (as the segment directed) even though the existing per-task discuss-API tests live in `DiscussionThreadTests.swift`; replicated the `LaunchRecorder`/`makeRunner` seam pattern locally as a private nested type. **Why:** the segment explicitly named `TaskRunnerTests.swift` for these tests; a local recorder keeps the file self-contained without cross-file test helper coupling.
- [low] For the whole-project `buildDiscussPrompt`, worded the invocation copy as "answer a question about this project's plans-cc backlog (all of its plans, across every status)" and emit a bare `/plan-discuss` line. **Why:** the segment asked to reword "about this plan" to "about this project's backlog / plans" while preserving the identical read-only + no-questions constraints; this phrasing matches plan-discuss's documented no-ID whole-backlog mode without inventing new behaviour.
- [high] Rendered the whole-project reply markdown in `ProjectDiscussionView` with SwiftUI's built-in `Text(.init(reply))` at `MarkdownStyle.compact.bodySize`, NOT via the shared `MarkdownBlockRenderer`/block views. **Why:** the segment offered this as the lighter, acceptable option, and `PlanDetailView.markdownBlockView`/`renderBlock` are `private` so they are not callable from a new file. This keeps the sheet self-contained with no change to `PlanDetailView`; it is a minor visual difference (built-in inline markdown vs. the detail column's block renderer), acceptable for chat-style replies.
- [high] Did NOT touch `PlanDetailView.swift` at all. **Why:** every helper the sheet needs (`discussSubmission`, `canSendDiscussion`, `composerShowsStop`, `showsConversationPanel`, `discussionScrollTarget`) was already `static` and internal, and `MarkdownStyle`/`MarkdownStyle.compact` are top-level internal, so no `private`→`static` promotion was required. The turn/composer VISUALS were replicated (not called) in the new file, matching the segment's instruction.

## Changes

Implemented a whole-project ("Discuss") conversation end-to-end by extending the
existing #099 per-plan discuss pipeline to a no-task-id mode.

**Engine (Swift):** `Sources/Plans/TaskRunner.swift`
- `TaskRun.arguments` now emits `--task-id` only when `mode.usesTaskID` AND the id is
  non-empty, so a project-wide discuss run (empty id) omits the flag entirely while
  every existing non-empty-id call site is byte-for-byte unchanged.
- Added `projectThread(projectPath:)` (read-only accessor, keyed on `runKey(projectPath:
  taskID: "")`), `projectThreadOrCreate(projectPath:)`, and `askProject(projectPath:
  question:)`. Extracted the shared body of `ask`/`askProject` into a private
  `launchDiscuss(thread:projectPath:taskID:question:)` so both are thin wrappers; `ask`'s
  observable behaviour is unchanged. The project thread is held on a `DiscussionThread`,
  never enters `runs`, and is distinct from any per-task thread.

**Engine (Node runner):** `Tools/work-task/run-task.ts`
- `parseArgs` discuss branch split out of the combined `reElaborate || discuss` check:
  `discuss` now requires only `--description` (the question) with `--task-id` OPTIONAL;
  `reElaborate` still requires both. Usage string updated.
- `buildDiscussPrompt` / `buildDiscussFollowUpPrompt` branch on an empty `taskId`: a
  non-empty id keeps today's per-task `/plan-discuss <id>` wording; an empty id emits a
  bare `/plan-discuss` (whole-backlog) with whole-project copy, preserving the identical
  strict read-only + no-questions constraints. `DISCUSS_ALLOWED_TOOLS` (already
  project-wide read-only) unchanged. The bundled JS is regenerated from this `.ts` by the
  gitignored esbuild step at app-build time (`Tools/work-task/dist/run-task.js`).

**UI (SwiftUI):**
- New `Sources/Plans/ProjectDiscussionView.swift` — a sheet rendering the whole-project
  conversation: a titled header ("Discuss <project>") with a Done button (dismiss only,
  never stopping an in-flight turn or resetting the thread), a transcript mirroring
  `PlanDetailView`'s turn rendering (question bubble, compact-markdown reply, "Thinking…"
  pending row, cancelled/error states) with a muted empty state before the first question,
  and a composer (multi-line `TextField`, send/stop glyph) reusing `PlanDetailView`'s pure
  static helpers (`discussSubmission` / `canSendDiscussion` / `composerShowsStop` /
  `discussionScrollTarget`). It sends via `runner.askProject(...)` and cancels via
  `runner.cancelDiscussionTurn(projectPath:taskID: "")`. No GeometryReader / self-measured
  layout (#096); fixed sheet frame only.
- `Sources/Plans/TaskListView.swift` — the single-project `projectHeader` gains a "Discuss"
  button (beside "New Plan", `bubble.left.and.bubble.right` glyph) that raises the sheet via
  a view-local `@State`. The cross-project smart-view list (`project == nil`) is unchanged.

**Tests:** `Tests/PlansTests/TaskRunnerTests.swift`
- 5 new tests (TDD, written failing first): arg shape omits `--task-id` for an empty-id
  discuss while a non-empty id still emits it; `askProject` launches a project-scoped
  `.discuss` run (empty id, question as description) held off `runs`; the project thread is
  distinct from a per-task thread; the project-thread lookup does not create a thread.

**Verification run so far:** `swift test --filter TaskRunnerTests` → 132 tests, 0 failures
(5 new pass); `swift build` → succeeds with the new view wired in; `swift test --filter
PlanDetailViewTests` → 68 tests, 0 failures (reused helpers intact). Node runner changes
verified by a successful esbuild rebuild and parse/prompt sanity checks against the rebuilt
bundle (per-task forms unchanged; no-id form produces a bare `/plan-discuss`).

**Deferred to review:** Step 8's manual end-to-end observation (open a project, click
Discuss, confirm a reply streams and `.plans/` files are unchanged) — provenance recorded
at branch `feature/110-add-project-wide-discuss-option` @ `10628364`. Compilation verified.

**Files changed:** `Sources/Plans/TaskRunner.swift`, `Sources/Plans/TaskListView.swift`,
`Sources/Plans/ProjectDiscussionView.swift` (new), `Tools/work-task/run-task.ts`,
`Tests/PlansTests/TaskRunnerTests.swift`.

**Review follow-up:** the sheet height is capped at 640pt so long conversations scroll, and project discussions are now ephemeral: closing the sheet stops any in-flight turn and discards the thread via `TaskRunner.endProjectDiscussion(projectPath:)`. This supersedes the Done-button behaviour described above. Step 8 was accepted at completion without a full observation.

## Notes
`plan-discuss` with no ID is an existing plans-cc mode (whole-backlog discussion).
The per-plan discuss feature is #099; this task is its whole-project sibling. The
engine changes (runner + arg builder + TaskRunner key) are the load-bearing,
unit-testable core; the sheet view is a thin composition of existing discussion UI.
