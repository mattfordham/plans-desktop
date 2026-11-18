# Guided In-App Plan Review

**ID:** 083
**Created:** 2026-09-23T00:00
**Type:** feature
**Status:** completed
**Completed:** 2026-11-10T17:21
**Branch:** feature/083-guided-in-app-plan-review

## What
Brainstorm, how could we review plans from the desktop app? Consider the review skill and what this would look like. Seems the biggest challenge would likely be building a conversation UI.

**Scope (2026-11-09):** the brainstorm is done (see `## Notes`). This task now builds guided in-app review: driving `/plan-review` from the app for kept-worktree tasks and rendering its prompts as buttons.

## Why
Adds value by finishing the loop in-app: a kept-worktree plan can go from executed to reviewed inside the desktop app, answering `/plan-review`'s prompts as buttons instead of switching to a terminal.

## How Summary
Add a `review` mode to the existing bundled runner: one live process runs `/plan-review NNN`, parks on each `AskUserQuestion` through the SDK's `canUseTool` callback, emits a `question` event, and resumes when the app writes the answer to a stdin pipe that exists only for this mode. On the Swift side it is an ordinary `TaskRun` in `runs` with a new `.review` mode and a `pendingQuestion`, surfaced by a Review button and a panel that replaces the Discuss composer while a review is live. Review runs in one of three per-task locations: the kept worktree, a review worktree created at review time (`/plan-review NNN worktree`), or the main checkout. A per-project default is kept in app preferences, and a read-only preflight runs before launch. A runtime spike comes first because several SDK and skill behaviours are not provable from source; the autonomous verbs stay untouched because every change is gated on the review mode.

**Files of note:**
- `Tools/work-task/run-task.ts` — new `review` mode, `canUseTool` bridge, stdin reader, kept-worktree guard.
- `Sources/Plans/TaskRunner.swift` — `RunMode.review`, `RunEvent.question`, `TaskRun.pendingQuestion`, `answer(...)`, review-only stdin pipe.
- `Sources/Plans/PlanDetailView.swift` — `canReview` gate, Review button, question panel replacing the Discuss composer.
- `Sources/Plans/TaskParser.swift` — retain the `**Worktree:**` path for the open-in buttons; `branch` gates review.
- `Sources/Plans/ReviewModal.swift` — location picker and read-only preflight, on the `ExecuteModal` pattern.
- `desktop-app-spec.md` — section 2's driven-verb list gains review.

## How
- [x] Step 1: Run a throwaway spike (not committed) against a fixture project with a kept-worktree task and a non-kept task, importing the SDK from `Tools/work-task/node_modules`. Confirm: (a) whether a literal `/plan-review NNN` string prompt expands despite `disable-model-invocation: true`; (b) that `canUseTool` still receives `AskUserQuestion` even though the skill's `allowed-tools` frontmatter lists it; (c) that a free-text answer reaches the skill's "Something's wrong" branch; (d) that a park over 10 minutes survives and SIGTERM while parked leaves no orphan CLI; (e) that `/plan-review NNN worktree` creates the review worktree and writes `**Worktree:**` when run headless; (f) that a main-checkout review with a dirty tree raises the "Uncommitted changes" gate through `canUseTool`. Record results in `## Notes`. If (a) is blocked, set `disable-model-invocation: false` in `~/Work/Open Source/plans/skills/plan-review/SKILL.md` (the #060 fix for `plan-delete`), reinstall, and re-check. If (b) or (f) fails, stop and bring the finding back before building further.
- [x] Step 2: Add `review` to `Mode` in `Tools/work-task/run-task.ts`, all gated on `mode === "review"`: prompt per location (below); rules in a `systemPrompt` string (a prompt trailer would become `$ARGUMENTS`, and the rules must route the "Something's wrong" description through the answer field); strip `AskUserQuestion` from the merged allowlist including config extras; `MAX_BUDGET_USD`; a `canUseTool` that emits `{"kind":"question","toolUseId":…,"questions":[…]}` and awaits a stdin line `{"kind":"answer","toolUseId":…,"answers":{…}}`, returning `updatedInput` with `questions` and `answers`; deny every other unlisted tool with text containing `haven't granted it yet` so the denial marker still reports it. Stdin EOF and `options.signal` cancel a parked question; destroy `process.stdin` after the message loop so node exits. Accept `--review-location kept|worktree|main`. `kept` sends `/plan-review NNN` and, before `query`, reads the task's `**Worktree:**` path and emits an `error` and exits if it is missing or not on disk. `worktree` sends `/plan-review NNN worktree`; it is the only location whose prompt may contain the keyword. `main` sends `/plan-review NNN` from the project root and relies on the skill's uncommitted-changes gate and its step 3.6 check that no other review holds the main checkout.
- [x] Step 3: In `Sources/Plans/TaskRunner.swift`, test-first in `Tests/PlansTests/TaskRunnerTests.swift`: add `RunMode.review` (`usesTaskID` true, `usesDescription` false, "Reviewing") and `RunEvent.question`, and update the exhaustive switches including `Sources/Plans/DiscussionThread.swift` and the log switch in `Sources/Plans/PlanDetailView.swift`. Add `TaskRun.pendingQuestion` (keyed by `toolUseId`, cleared on send and on finish) and `answer(...)`, which writes one NDJSON line on a private serial queue using `try write(contentsOf:)`. Create `standardInput = Pipe()` only for `.review`, close the write end in `finish`, ignore SIGPIPE, and add review-specific truncation copy so it doesn't say `/plan-execute`. Add a `ReviewLocation` enum (`kept`, `worktree`, `main`) carried on the `.review` run and passed as `--review-location`.
- [x] Step 4: Test-first in `Tests/PlansTests/PlanDetailViewTests.swift`:
  - Add a pure `PlanDetailView.canReview`: the task has a `branch`, is in `review` or `in-review`, is not blocked, is not backlogged, and has no live run. A kept worktree is no longer required.
  - Add a pure `availableReviewLocations(...)`: `kept` only when `showsKeptWorktreeMarker`; `worktree` and `main` always.
  - Add a pure `mainCheckoutOccupant(...)` from store data: another task in the same project that is in `review`/`in-review` with no kept worktree.
  - Add a Review button beside the existing review actions that opens the review sheet.
- [x] Step 5: Build `Sources/Plans/ReviewModal.swift` on the `ExecuteModal` pattern:
  - A location picker preset from a per-project default stored in `UserDefaults` keyed by project path. Never write it to `.plans/config.json`.
  - A read-only preflight on the main checkout using `git branch --show-current` and `git status --porcelain`, following the existing `gitBranch` read (#024).
  - Warn "Main has uncommitted changes — the review will ask to stash or commit" when the tree is dirty. Disable `main` with "Main is held by #MMM" when `mainCheckoutOccupant` is set.
  - Note that a main-checkout review leaves main on the task branch until `/plan-complete`.
  - Confirming launches `.review` with the chosen location and can save it as the project default.
- [x] Step 6: Build the review panel in `Sources/Plans/PlanDetailView.swift`: while a `.review` run is live it replaces the Discuss composer (the discussion thread is kept), showing the transcript from `RunEvent`s, one to four questions from `pendingQuestion` with an option button per choice including "Resolve for me" (honouring `multiSelect`), an "Other" free-text field, and the final summary via `markdownBlockView`. Use plain stacks and `maxHeight: .infinity`; no `GeometryReader` or measured heights (#096). Add a needs-input indicator on the plan's row in `Sources/Plans/ProjectCard.swift` and `Sources/Plans/TaskListView.swift`, so a parked review isn't lost after switching plans. Add "Open in Terminal" and "Open in Editor" buttons for the review directory: the worktree path for `kept`/`worktree`, the project root for `main`. This requires `TaskParser` to retain the `**Worktree:**` path (test-first in `TaskParserTests`). For `worktree`, the buttons appear once the store refresh picks up the field the skill writes.
- [x] Step 7: Add review to section 2's driven-verb list in `desktop-app-spec.md`, noting the review-only stdin channel, the three review locations, and that the app's preflight only reads git. Run `swift test` and rebuild the runner bundle.
- [x] 👁 Step 8: Build with `./build.sh` and test in the app:
  - Review a real kept-worktree task, answering each prompt including "Something's wrong" with free text, and confirm the main checkout is untouched.
  - Review a non-kept task with **new review worktree** and confirm the worktree is created and the open-in buttons go to it.
  - Review a non-kept task in **main** with a dirty tree and confirm the preflight warns and the Stash/Commit/Abort gate shows as buttons.
  - With another non-kept task in review, confirm `main` is disabled and names it.
  - Confirm Stop during a parked question ends cleanly with no leftover process, switching plans and back keeps the question, and a stale `**Worktree:**` path is refused for `kept`.

## Verification
`swift test` passes, including new coverage for `question` event decoding, stdin being wired only for `.review`, `canReview`, `availableReviewLocations`, and `mainCheckoutOccupant` gating, `**Worktree:**`-path parsing, and the question lifecycle via `ingestForTesting`. The existing autonomous verbs and Discuss tests pass unchanged. A manual review in each of the three locations (Step 8) completes in the app. Every prompt is answered there, the kept and new-worktree reviews leave main untouched, and the dirty-main, held-main, Stop, and stale-worktree cases behave safely.

## Impact Scope

### Files to Modify
- [x] `Tools/work-task/run-task.ts` — `review` mode, `canUseTool` bridge, stdin reader, worktree guard.
- [x] `Sources/Plans/TaskRunner.swift` — run mode, question event and state, `answer(...)`, review-only stdin pipe.
- [x] `Sources/Plans/DiscussionThread.swift` — exhaustive switch gains the new event.
- [x] `Sources/Plans/PlanDetailView.swift` — `canReview`, Review button, question panel, log switch.
- [x] `Sources/Plans/ProjectCard.swift` — needs-input indicator → landed in shared `PlanRowActions.swift` (deviation: PlanRowActions is the single trailing control #094 rendered by both row kinds; ProjectCard deliberately doesn't read TaskRunner, so a single source of truth avoids divergent copies). ProjectCard itself unchanged.
- [x] `Sources/Plans/TaskListView.swift` — needs-input indicator → same shared `PlanRowActions.swift` control (see above). TaskListView itself unchanged.
- [x] `Tests/PlansTests/TaskRunnerTests.swift` — event decoding, pipe wiring, question lifecycle.
- [x] `Tests/PlansTests/PlanDetailViewTests.swift` — `canReview`, `availableReviewLocations`, `mainCheckoutOccupant` gating.
- [x] `Sources/Plans/ReviewModal.swift` — new: location picker, per-project default, read-only preflight.
- [x] `Sources/Plans/TaskParser.swift` — retain the `**Worktree:**` path (threaded through `PlansStore.swift`'s failure-overlay rebuild too).
- [x] `Tests/PlansTests/TaskParserTests.swift` — `**Worktree:**` path parsing.
- [x] `desktop-app-spec.md` — section 2 driven-verb list.

### Related Files (may need updates)
- `~/Work/Open Source/plans/skills/plan-review/SKILL.md` — drops `disable-model-invocation` only if the spike shows it blocks the runner.
- `Sources/Plans/RunOutcomeLog.swift` — records review outcomes automatically through `finish`.
- `Sources/Plans/PlansApp.swift` — the quit alert already counts `runs`, so a parked review is covered.

### Endpoints/UI Affected
- Plan detail action bar — new Review button for any task with a branch in `review` or `in-review`, plus a review sheet with location picker and preflight.
- Plan detail footer — review panel replaces the Discuss composer while a review is live.
- Project card and task list rows — needs-input indicator.

## Assumptions

### Initial (from elaboration)
- [low] Treated this as a **brainstorm/design task whose deliverable is a written exploration** (captured in `## Notes`, optionally `desktop-app-spec.md`), not an implementation task. **Why:** the What says "Brainstorm… how could we… consider… what this would look like" — exploratory framing with no committed scope; the How therefore produces a design artifact rather than shipping the feature.
- [low] Interpreted "the review skill" as the **review family** (`plan-review`, `plan-discuss`, `plan-clarify`) rather than a single skill, and recommend `plan-discuss` (free chat) + `plan-review`'s option-prompts (guided response) as the two concrete UI targets. **Why:** research found three distinct interaction shapes; the brainstorm should map all three, and `plan-discuss` is the one actually designed as a turn-by-turn conversation while `plan-review` is dominated by fixed-option `AskUserQuestion` prompts.
- [low] Recommend a **new `ReviewSession` + `review-task.ts`** rather than extending `TaskRun`/`run-task.ts` with a stdin channel. **Why:** the existing one-shot path is built around an autonomous, no-questions, fire-and-forget contract (no stdin; every prompt ends "do not ask for confirmation"); bending it into interactivity risks regressing the six proven autonomous verbs. Recorded as a recommendation, not a locked decision — it is one of the design forks left open for the follow-up.
- [low] Recommend a **guided prompt/response UI first** (render `AskUserQuestion` as buttons), with full free-form chat as a later phase. **Why:** `plan-review` leans far more on fixed-option prompts than free text, so button-rendering delivers most of the value with far less UI; free chat is the better fit for `plan-discuss` and can follow.
- [high] Restrict any in-app review that touches git to **`keep`-worktree tasks** as the safe first cut. **Why:** `desktop-app-spec.md` §2 makes the subprocess the sole `.plans/` writer and the app a read-only viewer; `plan-review` does checkouts/rebases in the working tree, so isolating to a kept worktree preserves the invariant. This is well-grounded in the authoritative spec, hence [high].
- [low] Ran elaboration **fully autonomously** (no interactive gates), because this session has no UI to answer `AskUserQuestion`. Auto-selected the "further-exploration" (Path B) directions above. **Why:** the invoking instruction required autonomous completion; substantive picks are recorded here for later review.
- [high] `deep` was requested but `.plans/config.json` has **no `models.reasoning` entry**, so elaboration fell back to inline drafting (no reasoning sub-agent). **Why:** the skill's deep path requires a configured reasoning model; absent one it falls back silently and notes it once. No design impact — a research sub-agent still ran.
- [high] Did **not** add a `**Build:**` route. **Why:** there is no `design-system/` directory in this project, so build-skill routing does not apply.

### Discovered during execution
- [high] The stdout/stderr pipe wiring in `TaskRun.spawn` spans **`TaskRunner.swift:489–492`**, not the L489–491 cited in "Files of note" / How step 2 — the `proc.standardError = stderrPipe` assignment is on L492. `RunEvent` is at L27 as cited (correct). Recorded the corrected range in `## Notes` §2. **Why:** the task instructed me to verify the cited lines against the current tree and correct any drift; I opened the file and confirmed the exact block.
- [low] Read the Node runner as `run-task.ts` (TypeScript source in `Tools/work-task/`), while `TaskRun.resolveScriptURL` (L690) loads the bundled `run-task.js`. Treated `.ts` as the authoritative source and `.js` as its build output; cited the `.ts` throughout `## Notes`. **Why:** `Tools/work-task/` contains `run-task.ts` + `build.mjs` (no committed `dist/`), so the `.ts` is the source of truth and the bundled `.js` is generated at build time. Note for the §6 segment: there is **no `Tools/work-task/dist/node_modules/` directory in this worktree** (only `build.mjs`, `package.json`, `package-lock.json`, `run-task.ts`, `tsconfig.json`), so Step 6's cited `dist/node_modules/@anthropic-ai/claude-agent-sdk` path does not resolve here and that segment will need to locate the bundled SDK another way.
- [high] (§6) The actual installed/bundled SDK cannot be inspected in this worktree — `node_modules/` and `dist/` are gitignored and not copied into worktrees (confirmed by #078's build note, line 137). So §6 cites the *pinned* version (`^0.3.215` from `package.json`) and reasons about SDK API capability from the pin + the existing `query({...})` call site, explicitly labeling those API claims as reasoned-not-runtime-proven and flagging a Phase-1 spike as the confirmation step. **Why:** verifying against a real installed package is impossible here; conflating a pin with a resolved-and-tested version would overstate certainty.
- [low] (§5) Recommended restricting in-app review to `keep`-worktree tasks as the safe first cut, with non-kept tasks handled only by a Phase-0 terminal hand-off. **Why:** plan-review's SKILL.md does `git checkout`/`git rebase` on the main checkout unless a live `**Worktree:**` field routes it into a kept worktree (step 3.5/5), and spec §2 + the backlog carve-out establish that moving git state must never follow from one click; a kept worktree reviews in isolation, so it is the only branch that preserves the invariant without new git logic in the app. Recorded as a recommendation/fork, not a locked decision.
- [high] (§7) Did NOT edit `desktop-app-spec.md`. **Why:** the spec's §2 is an authoritative record of *shipped* behavior (six driven verbs, review absent); the review design is still forked (§4/§5/§6 open questions) and not SDK-confirmed, so encoding it into the authoritative contract now would risk the stale wording §2 itself warns about (spec lines 100–103). The segment prompt made spec edits conditional ("ONLY if you conclude it genuinely belongs"); I concluded it does not yet.
- [high] (Step 1) Checks (a), (b), (e), (f) are **runtime-proven** against the installed SDK 0.3.215 (keychain creds present → bundled `claude` CLI ran real `/plan-review` sessions in throwaway temp git fixtures). **Why:** see `## Notes` §9 — provenance held (branch/SHA unchanged, repo clean), and the two BLOCKING checks (b)/(f) both fired through `canUseTool`, so the build is GREEN to proceed.
- [low] (Step 1) Checks (c) "Something's wrong" free-text and (d) 10-min park / SIGTERM-orphan are **reasoned-from-source, not runtime-proven**. **Why:** (c) needs a staged `.plans/state` deferred-observation to reach step 7 and (d) is a Swift process-teardown concern plus a deliberately-skipped long park; both are low-risk given (b)'s proven answer plumbing and §8's no-deadline SDK fact, and (d) is covered by Step 8's manual verification.
- [high] (Step 1) Did **NOT** edit the external plans-cc skill `~/Work/Open Source/plans/skills/plan-review/SKILL.md`. **Why:** check (a) proved the `/plan-review NNN` slash prompt expands and the skill body executes despite `disable-model-invocation: true` (that flag only blocks the model-invoked `Skill` tool, not `/command` expansion), so the task's conditional remediation (flip the flag) was unnecessary.
- [high] (Steps 2–4) `ReviewLocation` lives in `Sources/Plans/TaskRunner.swift` (right before `RunMode`), NOT its own file. **Why:** it is meaningful only alongside `RunMode` and the review argument builder it feeds; co-locating it with `RunMode` mirrors how the existing orthogonal flags are housed and keeps the review contract in one place. In the TS runner it is a local `type ReviewLocation = "kept" | "worktree" | "main"`.
- [high] (Step 2) Wire-shape: the runner emits `{"kind":"question","toolUseId":…,"questions":…}` using `toolUseId` (lowercase d) even though the SDK option is `options.toolUseID` (uppercase D); it reads the answer back as `{"kind":"answer","toolUseId":…,"answers":{…}}`. **Why:** the task body fixed this exact wire contract (lowercase `toolUseId`), and the Swift side (`RunEvent.question`, `TaskRun.answerLine`) matches it byte-for-byte so the park/answer round-trip keys correctly.
- [high] (Step 2) The review `systemPrompt` phrases the "Something's wrong" routing as: in the per-observation loop, when the user picks "Something's wrong", their free-text explanation is delivered AS the AskUserQuestion answer, so the skill's "Something's wrong" branch must act on that text rather than discarding it. Behavioral rules live ONLY in `systemPrompt`, never in the prompt (a prompt trailer would be consumed as `$ARGUMENTS`). The prompt is a BARE `/plan-review NNN` (or `/plan-review NNN worktree` for the worktree location only). **Why:** the spike proved a prompt trailer is swallowed by the skill as arguments, and only the `worktree` location may contain the word "worktree" (the skill keyword-matches it).
- [high] (Step 2) `canUseTool` is set ONLY for review mode, and `AskUserQuestion` is stripped from the merged allowlist (base ∪ config extras) ONLY for review mode. **Why:** a bare allowlist entry shadows/bypasses `canUseTool` (SDK logs `[CLAUDE_SDK_CAN_USE_TOOL_SHADOWED]`), so the callback can only fire once the entry is removed; autonomous verbs must never park, so neither change touches any other mode. The stdin reader is attached only in review mode and torn down (`process.stdin.destroy()`) after the message loop so node exits.
- [high] (Step 2) The `kept` guard reads the task's `**Worktree:**` path from its `.plans` file (`readTaskWorktreePath`, searching `review` first) and `emit`s an error + exits non-zero if the path is missing or not on disk, rather than falling through to a checkout. The resolved worktree becomes the `query` `cwd`. `worktree`/`main` run with `cwd = projectRoot` and no guard.
- [high] (Step 3) `answer(...)` writes its one NDJSON line on a PRIVATE serial `DispatchQueue` (`answerQueue`) via `try handle.write(contentsOf:)`, and SIGPIPE is ignored exactly once process-wide via a `static let ignoreSIGPIPE = { signal(SIGPIPE, SIG_IGN) }()` referenced from `TaskRun.init`. **Why:** a write racing the child's exit would otherwise deliver SIGPIPE and kill the whole app; ignoring it makes the write throw (swallowed) instead. The review-only stdin `Pipe()` is created in `spawn` only when `mode == .review`, retained as `standardInput`, and its write end is closed in `finish`.
- [low] (Step 4) `PlanDetailView.canReview(...)` takes an explicit `hasLiveRun: Bool` parameter (the call site passes `runner.isRunning(...)`) so the predicate stays pure and unit-testable, mirroring how `hasLiveRun`-style state is threaded elsewhere. A kept worktree is NOT required for review (unlike the old §5 recommendation) — `canReview` requires only a branch + review/in-review + not blocked/backlogged + no live run; `availableReviewLocations` gates `kept` on `showsKeptWorktreeMarker`. **Why:** the segment explicitly redefined review to work on worktree/main too, so the kept-only restriction from Step 1's §5 recommendation is superseded.
- [low] (Step 4) The Step-4 Review button opens a MINIMAL placeholder sheet (`reviewPlaceholderSheet`) that already calls `runner.review(...)` per picked location, left as a clean seam for Step 5's `ReviewModal`. **Why:** the segment said a compiling placeholder is acceptable and Step 5 replaces it; wiring the launcher now proves the end-to-end seam.
- [high] (Step 5) `ReviewModal`'s pure helpers (`defaultLocationKey`, `savedDefaultLocation`, `saveDefaultLocation`, `initialLocation`, `dirtyTreeWarning`, `mainDisabledReason`, `isLocationDisabled`, `mainCheckoutNote`, `locationLabel`, `locationSubtitle`) are marked `nonisolated static`. **Why:** `ReviewModal` is a SwiftUI `View` (MainActor-isolated), so its static methods inherit MainActor; calling them from a plain (nonisolated) XCTest and passing a per-test `UserDefaults` across the actor boundary raised a `sending 'self.defaults' risks causing data races` compile error. The helpers are genuinely pure (no view state), so `nonisolated` is the correct, race-free fix and keeps the tests non-`@MainActor`.
- [low] (Step 5) Per-project review-location default key is `"reviewLocationDefault:" + projectPath` in `UserDefaults` (NOT `.plans/config.json`, per the hard rule). The preflight runs in a SwiftUI `.task` via `Task.detached` calling `GitHelper.currentBranch` / `GitHelper.isDirty` (the #024 read path), stored in a `ReviewPreflight` struct. **Why:** the GitHelper reads block and must run off the main actor; `.task` + `detached` mirrors how the store does its git second pass, and the struct keeps the two reads together for the `@State` hop back. The dirty warning + main-checkout note render only for the `.main` location.
- [high] (Step 6) `TaskParser` now retains the `**Worktree:**` PATH as a new `Task.worktreePath: String?` (nil when the field is absent/empty, exactly when `isKeptWorktree` is false), threaded through the memberwise init (defaulted), `==`, `resolveBlocked`, AND the store's failure-overlay reconstruction in `PlansStore.swift`. **Why:** the open-in-Terminal/Editor buttons need the kept worktree directory; I had to thread it through the store's `Task(...)` rebuild too, or a failure overlay would silently erase the path. Added as a defaulted init param so the ~dozen existing call sites/tests compile unchanged.
- [high] (Step 6) The needs-input indicator was added to the SHARED `PlanRowActions` view (the trailing per-row control), NOT separately to `ProjectCard.swift` and `TaskListView.swift` as the Impact Scope listed. **Why:** `PlanRowActions` was deliberately extracted (#094) so the ONE control serves both `ProjectCard.planRow` and `TaskListRow`; it already reads `TaskRunner`, while `ProjectCard` deliberately does NOT. Putting the indicator there gives both row kinds the badge from one source of truth, avoiding divergent copies. Recorded as a scope deviation.
- [low] (Step 6) The review panel reuses the existing `RunLogContents` for the live transcript (capped at 220pt), renders the parked question as accent-tinted option rows with a "Resolve for me" sentinel appended + an "Other" free-text field per question, and the final summary via `markdownBlockView(.compact)`. Answer assembly joins picked labels with ", " and appends any non-empty "Other" text; the answer is keyed per question by its `header`. **Why:** the task specified these elements; keying answers by `header` (unique within one `AskUserQuestion` payload) matches how the wire `answers` dict is shaped. Used plain stacks + `maxHeight: .infinity` only (no GeometryReader, #096).
- [high] (Step 7) Edited `desktop-app-spec.md` §2 to add **review** to the driven-verb list with a paragraph covering the review-only stdin channel, the three locations (kept / review worktree / main), and the read-only-git preflight. **Why:** Step 7 explicitly required it; this supersedes Step-7's earlier (Step-1 segment) decision NOT to edit the spec, because the review design is now implemented and SDK-confirmed rather than a fork. The runner bundle was rebuilt via `npm run build` (node_modules present in the worktree); `dist/run-task.js` now contains the review-location/question/answer wiring. Full `swift test` passed: 850 tests, 0 failures.
- [low] (Post-review fixes) "Discuss with reviewer" resumes the review's Agent SDK session via `--resume` for `worktree` / `main` reviews, but falls back to seeding the discussion with the review summary as context for `kept` reviews. **Why:** the CLI stores sessions per working directory; a `kept` review ran with the kept worktree as its cwd, while discuss runs from the project root, so that session can't be found on resume (and the worktree is torn down on completion anyway). Resuming in discuss mode is otherwise sane: the follow-up uses the read-only (or `--apply`) discuss allowlist with no `canUseTool`, so a stray `AskUserQuestion` from the review context is simply denied. A failed resume also restores the summary as context so the reviewer's findings aren't lost.
- [high] (Post-review fixes) Step 3's "review-specific truncation copy" had not been implemented (`truncationError` always said "/plan-execute"). Added `truncationError(for:mode:)` with review/complete copy, and threaded the mode through `shouldShowFailureBanner`, before ticking Step 3. **Why:** the step could not be honestly marked done without it.
- [low] (Post-review fixes) `.complete` reuses the review's `canUseTool`/stdin question bridge (gated on `RunMode.isInteractive` / `isInteractiveMode`), runs a bare `/plan-complete NNN` from the project root, and carries its rules in a `systemPrompt` telling the agent to ask every confirmation (including the skill's plain yes/no prompts) through `AskUserQuestion`. **Why:** a prompt trailer would become `$ARGUMENTS`, and words like "done"/"good"/"ship" are plan-complete auto-accept keywords that skip confirmations.

## Changes

**Post-review fixes (2026-11-10):** two issues found in manual testing.
- *Review panel half empty:* the transcript was `RunLogContents` capped at 220pt
  inside a ScrollView. It now fills the panel as its own band (edge-to-edge,
  still auto-scrolling); a parked question sits in a scrollable section beneath.
- *No follow-up after a review:* a review that finishes cleanly
  (`PlanDetailView.finishedReviewRun` — not running, `done` seen, no error) keeps
  a "Review Finished" panel with the summary and actions: **Discuss with
  Reviewer** (`TaskRunner.continueReviewInDiscussion` →
  `DiscussionThread.seedFromReview`; resumes the review session, or carries the
  summary as context for `kept` reviews), **Complete…**, and **Done** (dismiss).
- *New `RunMode.complete`:* drives `/plan-complete NNN` interactively through the
  same question bridge (`RunMode.isInteractive` / `isInteractiveMode` in
  `run-task.ts`), always from the project root, always behind an `NSAlert`
  confirmation naming the task and branch (`completeConfirmation` /
  `confirmComplete`). Offered in the finished-review panel, the detail header,
  and on in-review rows (`PlanRowActions`), gated by the pure `canComplete`
  (in-review, has branch, not blocked/backlogged, no live run).
- Review/complete runs that hit a cap now get mode-specific copy
  (`truncationError(for:mode:)`), completing Step 3.
- Spec §2 lists **complete** and the finished-review follow-ups.
- Tests: `TaskRunnerTests` (complete flags/args/stdin/launcher, mode-specific
  truncation, review→discussion continuation incl. `kept` fallback),
  `DiscussionThreadTests` (seeding, context consumption, failed-resume fallback),
  `PlanDetailViewTests` (`liveInteractiveRun`, `finishedReviewRun`,
  `showsReviewPanel`, panel title, `canComplete`, confirmation copy, failure
  banner), and a new Node test `Tools/work-task/run-task.modes.test.ts`.
  `swift test`: 874 tests, 0 failures. Runner bundle rebuilt.

Guided in-app plan review is implemented (How Steps 1–7). The app can now drive
`/plan-review NNN` from a live subprocess, render its `AskUserQuestion` prompts as
buttons, and answer them over a review-only stdin pipe — in one of three per-task
locations (kept worktree / new review worktree / main checkout). Step 8 is the 👁
manual in-app build test, deferred to review. All `swift test` pass (850 tests, 0
failures); the runner bundle was rebuilt.

**Node runner (`Tools/work-task/run-task.ts`):**
- New `review` mode, gated entirely on `mode === "review"`: a `canUseTool` bridge
  that emits `{"kind":"question","toolUseId":…,"questions":[…]}` for each
  `AskUserQuestion` and awaits a stdin line `{"kind":"answer","toolUseId":…,
  "answers":{…}}`, returning `{behavior:"allow", updatedInput:{questions, answers}}`.
- `AskUserQuestion` stripped from the merged allowlist (base ∪ config extras) ONLY
  for review mode, so the callback is not shadowed; stdin reader attached only in
  review mode and torn down (`process.stdin.destroy()`) after the message loop.
- `--review-location kept|worktree|main`: `kept` sends a bare `/plan-review NNN` and
  guards on the task's `**Worktree:**` path (errors + exits if missing/off-disk);
  `worktree` sends `/plan-review NNN worktree` (the only location that may contain
  the keyword); `main` sends `/plan-review NNN` from the project root and relies on
  the skill's own uncommitted-changes + main-occupant gates. Behavioural rules
  (incl. routing "Something's wrong" free text through the answer field) live in a
  `systemPrompt`, never as a prompt trailer (which would be swallowed as arguments).

**Swift app (`Sources/Plans/`):**
- `TaskRunner.swift` — `ReviewLocation` enum (kept/worktree/main, co-located with
  `RunMode`), `RunMode.review` ("Reviewing"), `RunEvent.question` (non-terminal) +
  `ReviewQuestion`/`ReviewQuestionOption` codable types, `TaskRun.pendingQuestion`,
  `answer(toolUseId:answers:)` (one NDJSON line on a private serial `answerQueue`),
  review-only `standardInput = Pipe()` created only for `.review` and closed in
  `finish`, process-wide SIGPIPE ignore, and the `review(projectPath:taskID:location:)`
  launcher threading `--review-location`.
- `DiscussionThread.swift` — exhaustive event switch handles `.question`.
- `ReviewModal.swift` (NEW) — location picker preset from a per-project `UserDefaults`
  default (`"reviewLocationDefault:"+projectPath`; never `.plans/config.json`); a
  read-only main-checkout preflight via `GitHelper.currentBranch`/`isDirty` (#024 read
  path) in a `.task`+`Task.detached`; a dirty-tree warning, a main-held-by-#MMM disable
  naming the occupant, and the "main stays on the task branch until /plan-complete"
  note; confirm launches `.review` and can save the chosen location as the default.
- `PlanDetailView.swift` — pure `canReview` / `availableReviewLocations` /
  `mainCheckoutOccupant` predicates, a "Review" header action (checklist glyph), the
  `showReview` sheet now presenting the real `ReviewModal` (placeholder removed), and
  the review panel that replaces the Discuss composer while a `.review` run is live:
  live `RunLogContents` transcript, parked question(s) rendered as option buttons
  (incl. "Resolve for me", honouring `multiSelect`) + an "Other" free-text field, the
  final summary via `markdownBlockView`, and open-in-Terminal/Editor buttons targeting
  the worktree (kept/worktree) or project root (main). Plain stacks + `maxHeight:
  .infinity` only (no GeometryReader, #096).
- `TaskParser.swift` — retains the `**Worktree:**` path as `Task.worktreePath: String?`
  (threaded through init/`==`/`resolveBlocked` and `PlansStore.swift`'s failure-overlay
  rebuild) so the open-in buttons can find the review directory.
- `PlanRowActions.swift` — needs-input badge on the shared trailing row control, so a
  parked review isn't lost after switching plans (one source of truth for both row
  kinds — see the Step-6 assumption bullet; `ProjectCard.swift`/`TaskListView.swift`
  left unchanged by design).

**Tests (all passing):** `TaskRunnerTests.swift` (event decoding, review-only pipe
wiring, question lifecycle), `PlanDetailViewTests.swift` (`canReview`,
`availableReviewLocations`, `mainCheckoutOccupant` gating), `TaskParserTests.swift`
(`**Worktree:**`-path parsing), and `ReviewModalTests.swift` (NEW; per-project default
key, dirty-tree warning, main-disabled decision).

**Spec (`desktop-app-spec.md`):** §2's driven-verb list gains **review**, documenting
the review-only stdin channel, the three locations, and that the app's preflight only
*reads* git (never mutates it). This supersedes the earlier (brainstorm-phase)
decision to leave the spec untouched: the design is now implemented and SDK-confirmed.

---

### Historical: brainstorm phase (How Steps 1–7 of the original design task, 2026-09-24)

Before this task was re-scoped to build the feature, its original deliverable was a
written design exploration, captured in `## Notes` §1–§7 (kept above as background):
the three review-family skills and their interaction shapes (§1); the one-way handoff
architecture and the exact stdin gap (§2); the building blocks and reuse targets (§3);
the design forks and recommendations (§4); the git-safety / read-only invariant and
the kept-worktree escape hatch (§5); bundled-SDK feasibility (§6); and the phased plan
with open forks (§7). The 2026-11-09/10 research (`## Notes` §8) and the Step-1 spike
(§9) then superseded the forks with concrete decisions, which this implementation
realises.

**`desktop-app-spec.md`: NOT modified** — see §7's spec-file decision. The spec's §2
is an authoritative record of shipped behavior; encoding a still-forked, unbuilt,
not-yet-SDK-confirmed design into it during a brainstorm would risk the exact stale
wording §2 already warns about. The right time to amend it is when a follow-up
implementation task lands or the open forks are decided.

### Review fixes (2026-11-10)
- Answers are keyed by question text, as the SDK's AskUserQuestion expects; the question card is no longer clipped (40611a6).
- A parked question can be answered from the toolbar's active-runs popover (15ae7ae): needs-input runs show an orange marker, sort first, and open a `ParkedQuestionSheet` that looks the run up by key. This covers `/plan-complete`, which archives the task before asking about the merge so the plan leaves the list. The form is shared via `ParkedQuestionForm`. The skill-side reorder is tracked separately in plans-cc.

## Notes

> Writeup for How Steps 1–4. Later segments (git-safety §5, SDK-feasibility §6,
> phased plan §7) append their own subheadings below. Every file/line reference
> here was opened and confirmed against the current worktree tree.

### 1. The three review-family skills and their interaction shapes

The "review skill" is really a **family of three** plans-cc skills, each with a
distinct interaction contract. What each demands of a UI is very different, and
that difference is what decides the realistic first target.

**`plan-review` — scripted, fixed-option gates (the realistic first target).**
Read `~/.claude/skills/plan-review/SKILL.md`. Its interactivity is entirely
`AskUserQuestion` with **fixed option sets** at a handful of scripted decision
points, never open free chat:
- Uncommitted-changes gate (step 4): header "Uncommitted changes", three fixed
  options — "Stash changes" / "Commit changes" / "Abort". The skill is emphatic:
  "**REQUIRED: You MUST call the `AskUserQuestion` tool here — do NOT auto-select
  an option**".
- Rebase-conflict gate (step 6): header "Rebase conflict", four fixed options —
  "Resolve for me" / "Resolve in place" / "Abort rebase" / "Skip rebase".
- Deferred-observation walkthrough (step 7): a **loop** over each
  `⏳ Deferred to review` entry in `.plans/state/NNN-state.md`, each a
  three-option `AskUserQuestion` — "Looks good" / "Something's wrong" / "Skip".
  "Something's wrong" spawns a `plan-executor` sub-agent to fix, then re-asks.
- Everything else is non-interactive automation: project-root discovery, status
  validation, `git checkout [branch]` (step 5), `git rebase [target]` (step 6),
  and a final rendered **review summary** (step 10, printed text — no input).

UI implication: `plan-review` is dominated by **render-a-question-with-N-buttons**
plus a scrolling transcript. It needs almost no free-text entry (only the
"Something's wrong" description and the `AskUserQuestion` "Other" field). This is
why it is the realistic first target — a **guided prompt/response** surface
(buttons for options) covers nearly all of it, and it is the review verb users
most want from the desktop app. Caveat for a later segment: it also performs git
checkout/rebase in the working tree, which collides with the read-only invariant
(deferred to §5).

**`plan-discuss` — free-form, turn-by-turn conversation (the hardest UI).**
Read `~/.claude/skills/plan-discuss/SKILL.md`. This is the only member actually
designed as an open conversation: "Have an open, turn-by-turn conversation about
your plans" (line 17); step 6 "Converse turn by turn" responds "in plain prose
for substantive discussion". It has **no fixed script** — the number and shape of
turns are unbounded ("Long-running conversation: no artificial cap", edge case
line 217). It *prefers* `AskUserQuestion` for multiple-choice trade-offs and for
the apply-edit confirmation (step 7 draft→confirm→`Edit`), but the backbone is
free prose in and free prose out. Files are edited only on an explicit update
signal ("update the plan", "apply that", etc., step 7).

UI implication: `plan-discuss` needs a **true chat surface** — a free-text input
box, an unbounded scrolling transcript of user + assistant turns, and optional
inline option-buttons when the agent chooses to ask a structured question. This
is the most expensive UI to build and is best deferred to a later phase.

**`plan-clarify` — scripted Q&A loop (middle ground).**
Read `~/.claude/skills/plan-clarify/SKILL.md`. It first **scans** an elaborated
task for ambiguities (step 5), builds a `findings` list, then loops (step 8):
each finding becomes one `AskUserQuestion` whose options are the 1–2
auto-generated `suggested_resolutions` plus two fixed tail options —
"Different — I'll specify" and "Skip this one". A `skip` argument auto-picks the
first suggestion for every finding with no prompting at all. So it is a **fixed
round of guided questions** whose *count* is data-driven (one per finding) but
whose *shape* per question is always the same button set, with an occasional
free-text fallback when the user picks "Different".

UI implication: `plan-clarify` reuses the **same guided prompt/response surface**
as `plan-review` — render each finding as a question with option buttons, plus a
free-text path for "Different". It rides along for free once the `plan-review`
UI exists; it needs no chat backbone.

**Summary of the three shapes and the first target:**

| Skill | Interaction shape | UI it demands | First target? |
|-------|-------------------|---------------|---------------|
| `plan-review` | Scripted `AskUserQuestion` gates + a per-observation loop | Option-buttons + transcript; almost no free text | **Yes** — most-wanted, mostly buttons |
| `plan-clarify` | Data-driven loop of fixed-option questions | Same option-button surface (+ "Different" free-text) | Rides along with plan-review's UI |
| `plan-discuss` | Open, unbounded free-prose conversation | Full chat: free-text input + unbounded transcript | Later phase |

The realistic first target is **`plan-review`'s guided-option interaction**
(with `plan-clarify` following almost for free on the same surface); full
free-form chat for `plan-discuss` is a distinct, later, larger build.

### 2. The current handoff architecture and the exact gap

Today the app drives plans through a strictly **one-way, fire-and-forget**
subprocess. The pipeline, confirmed against `Sources/Plans/TaskRunner.swift` and
`Tools/work-task/run-task.ts`:

**Swift side (`TaskRunner.swift`):**
- `TaskRunner.run(projectPath:taskID:mode:…)` (L797) constructs a `TaskRun`
  and calls `taskRun.start(projectPath:onFinish:)`.
- `TaskRun.start(projectPath:onFinish:)` (L374) resets observable state, resolves
  the bundled `run-task.js` and the `node` binary (off the main actor), then
  hops back to the main actor and calls `spawn(...)`.
- `TaskRun.spawn(...)` (L448) builds the argv (`--project-root`, optional
  `--task-id` / `--description`, `--mode`, and the valueless `--deep` / `--keep`
  flags), then wires **only two pipes**:
  ```swift
  let stdoutPipe = Pipe()      // TaskRunner.swift:489
  let stderrPipe = Pipe()      // TaskRunner.swift:490
  proc.standardOutput = stdoutPipe   // L491
  proc.standardError = stderrPipe    // L492
  ```
  **There is no `proc.standardInput`.** (Note: the task's "Files of note" cited
  L489–491 for the pipe wiring; the actual block spans **L489–492** — the
  `standardError` assignment is on L492. `RunEvent` is at L27 as cited, correct.)
- The read path is one-directional: `stdoutPipe.fileHandleForReading.readabilityHandler`
  (L496) runs on a background queue, appends `handle.availableData` to a `Data`
  buffer, and hops each chunk to the main actor via `Task { @MainActor in
  self?.ingest(data) }` → `ingest(_:)` (L526) → `RunEvent.parseLines(from:&buffer)`
  (L101, splits on `\n`, decodes each complete NDJSON line, retains the trailing
  partial) → `handle(_:)` (L576, appends a `LoggedEvent` and fans terminal
  events into `summary` / `error`). `terminationHandler` (L504) drains the final
  buffered line and finalizes via `finish(...)`.

**The NDJSON contract (`RunEvent`, L27):** a closed set of **four inbound-only**
event kinds, discriminated by `kind`:
- `activity(tool:detail:)` — a tool invocation for the activity log
- `text(chunk:)` — streamed assistant text (per-turn)
- `done(costUsd:turns:stopReason:)` — terminal success line
- `error(message:)` — terminal error line

Every one of these flows **agent → app**. There is no event kind, and no channel,
for **app → agent**.

**Node side (`run-task.ts`):** `main()` (L671) parses argv, calls `buildPrompt(args)`
(L583) to produce **one static prompt string per mode**, and passes it to a single
`query({ prompt, options })` call (L682). The options set
`permissionMode: "acceptEdits"` (L686) and an `allowedTools` allowlist (L692–716)
that includes `Skill`, `Agent`/`Task`, `Read`/`Write`/`Edit`/`Bash`/`Glob`/`Grep`/
`TodoWrite`, and three read-only Figma tools — **`AskUserQuestion` is deliberately
absent**. Every prompt builder ends with the literal line
`"Work autonomously to completion. Do not ask for confirmation."` (e.g.
`buildExecutePrompt` L259, `buildElaboratePrompt` L309, and every sibling), and
several builders **pre-answer** the interactive gates their skill would otherwise
raise (`buildDeletePrompt` L481 pre-answers the yes/no confirm and the delete-branch
`AskUserQuestion`; `buildBacklogPrompt` L527 pre-answers the pause gate). The
`for await (const message of response)` loop (L720) consumes SDK messages
one-way and `emit()`s the four NDJSON kinds; the process **never reads stdin**.

**The exact gap, stated plainly:** the entire hand-off is architected around an
autonomous, no-questions, one-shot contract. **There is no stdin channel on the
Swift side and no stdin reader on the Node side; there is no long-lived,
idle-awaiting-input session anywhere today.** A `TaskRun` runs to termination and
is done — it has no notion of "paused, waiting for the user to answer a
question." Review is fundamentally the opposite: the agent must *stop mid-run,
ask, and resume on the answer*. That inversion — not any single missing file — is
the gap this brainstorm scopes.

### 3. The four new building blocks a conversation UI needs

A review/conversation surface needs four new pieces layered onto (not replacing)
the existing plumbing. Design-level only — no implementation here.

**(a) Bidirectional process I/O.**
Add a third pipe to the spawned process: `proc.standardInput = Pipe()` alongside
the existing stdout/stderr wiring in `spawn(...)` (`TaskRunner.swift:489–492`),
and a `send(_ line: String)` method that writes one NDJSON line (e.g. an answer
payload) to `stdinPipe.fileHandleForWriting`. This is the smallest new primitive:
it reuses the **entire existing outbound decode path** unchanged (readabilityHandler
→ buffer → `RunEvent.parseLines` → main-actor `handle`); it only *adds* an
outbound-write direction the class has never had. The reverse of the inbound
`\n`-delimited framing already in `parseLines` (L101) is the natural wire format
for the write side.

**(b) A streaming-input Node runner `review-task.ts`.**
A **new sibling to `run-task.ts`** (not an overload of it), because the two have
opposite contracts. Where `run-task.ts` passes a static string prompt and
excludes `AskUserQuestion`, `review-task.ts` would:
- **allowlist `AskUserQuestion`** in its `allowedTools` (the tool `run-task.ts`
  deliberately omits at L692–716);
- drive `/plan-review NNN` (and later `/plan-clarify`, `/plan-discuss`) *without*
  the "Do not ask for confirmation" trailer that every current builder appends —
  the whole point is to let the skill ask;
- **read user messages from stdin** (the channel (a) opens), feeding them back to
  the SDK as the answers to `AskUserQuestion` / as conversational turns. This
  likely requires the SDK's streaming / async-iterable prompt-input form rather
  than the single-string `prompt` used at `run-task.ts:682` (feasibility of the
  bundled SDK version is deferred to §6);
- **emit new outbound event kinds** beyond today's four: a `question` event
  carrying the prompt text + the option set (label/description per option) so the
  UI can render buttons; and an input-state signal such as `awaiting_input` /
  `turn_end` so the UI knows the agent has paused and the input controls should
  activate. These are additive to the `RunEvent` contract — the existing four
  kinds stay valid, so nothing about the six autonomous verbs changes.
Reuses: the `emit()` NDJSON convention, `toolDetail(...)`, the `permissionMode`/
`maxBudgetUsd`/`cwd` option shape, and the argv-parsing style of `run-task.ts`.

**(c) A long-lived `@Observable ReviewSession` (sibling to `TaskRun`).**
`TaskRun` models a run that starts, streams, and terminates — it has no idle
state. A `ReviewSession` (mirroring `TaskRun`'s `@MainActor @Observable final
class` shape, L224–226) would instead **stay alive across many turns**, holding:
- `messages: [ChatMessage]` — the ordered transcript (user + assistant turns),
  each with stable identity for SwiftUI iteration, mirroring how `LoggedEvent`
  (L205) wraps each `RunEvent` with a `UUID`;
- `pendingQuestion: Question?` — the currently-open `AskUserQuestion` (text +
  options) awaiting the user, populated from the new `question` event;
- an input-state enum (e.g. `awaitingInput` / `agentThinking`) driving whether
  the input controls / option buttons are live.
Reuses: `TaskRun`'s spawn/resolve-node/main-actor-hop scaffolding and its
outbound decode pipeline (it decodes the extended event set the same way);
`RunOutcomeLog.swift` for the session's terminal outcome record (confirmed
present — `Sources/Plans/RunOutcomeLog.swift`), which also addresses task #080's
finding that terminal-run tasks skip the outcome log. It would live beside
`TaskRun` inside (or next to) `TaskRunner`, tracked per task id the same way the
`runs` map tracks `TaskRun`s (L756).

**(d) A Surface B chat / guided-response view in `PlanDetailView`.**
The rendering surface. `PlanDetailView.swift` already hosts `RunProgressSheet`
(confirmed at **L802**, wired in at L138) with auto-scroll, an `errorBanner`
(L1007), a scroll-target helper (`scrollTarget(for:)`, used L971), and the
action-button call sites — the natural template and home for a review view. It
would render `session.messages` as a scrolling transcript and, when
`pendingQuestion != nil`, render the options as **buttons** (guided response)
whose tap calls `session.send(...)`; a later phase adds a free-text input box for
`plan-discuss`. Reuses: `MarkdownBlockRenderer` (confirmed —
`Sources/Plans/MarkdownBlockRenderer.swift`, `MarkdownBlockRenderer.parse(...)`
already used in `PlanDetailView` at L636) + `CodeHighlighter.swift` (confirmed
present) to render agent turns as formatted markdown exactly as the plan body is
rendered today; `ExecuteModal.swift` (a pure options sheet — confirmed) as the
template for a pre-review options sheet; `ElaborateModal.swift` (an optional
free-text guidance box reusing `NewPlanModal`'s `PlanTextEditor` — confirmed) as
the template for a future free-text chat input.

### 4. The two design forks and the recommendation

**Fork (i): new `ReviewSession` + `review-task.ts` vs. extending
`TaskRun`/`run-task.ts` with stdin.**

- *Extend the existing path:* add `standardInput` to `TaskRun.spawn`, teach
  `run-task.ts` to read stdin and allowlist `AskUserQuestion`. Pro: one code
  path, less new surface. Con: it forces an idle-awaiting-input state and a
  live-conversation contract onto a class and a script whose every line assumes
  autonomous, terminate-when-done behavior — every prompt builder ends "Do not
  ask for confirmation," several *pre-answer* gates precisely to avoid stdin, and
  `TaskRun` has no idle phase. Bending them risks regressing the **six proven
  autonomous verbs** (execute, elaborate, reElaborate, capture, captureElaborate,
  executeYolo — plus delete/backlog/restore) that thousands of runs depend on.
- *New session + new runner:* add `ReviewSession` beside `TaskRun` and
  `review-task.ts` beside `run-task.ts`. Pro: the autonomous path is **touched
  not at all** — the extended event kinds are additive, the old four still
  decode, the old script is byte-identical. The new class can model idle/awaiting
  states natively. Con: some duplicated spawn/resolve scaffolding between the two
  classes (mitigable by sharing the node-resolution and framing helpers).

**Recommendation: the new-session + new-runner path.** The duplication cost is
small and mostly mechanical; the regression risk of the alternative is large and
lands on the most load-bearing, most-exercised code in the app. Keeping the
autonomous contract frozen is worth a little copied scaffolding.

**Fork (ii): guided prompt/response UI vs. full free-form chat.**

- *Guided prompt/response* (render each `AskUserQuestion` as buttons): fits
  `plan-review` and `plan-clarify` almost completely (§1), needs no free-text
  backbone, and is a small view addition on top of the `RunProgressSheet`
  template.
- *Full free-form chat* (free-text input + unbounded transcript): required for
  `plan-discuss`, materially larger, and only fully pays off for the one skill
  actually designed as open conversation.

**Recommendation: guided-first.** `plan-review` — the review verb users most want
in the app — is *dominated* by fixed-option `AskUserQuestion` prompts, so
button-rendering delivers most of its value with far less UI, and `plan-clarify`
rides the same surface for free. Free-form chat for `plan-discuss` is a deliberate
later phase.

**Combined recommendation:** build a **new `ReviewSession` + `review-task.ts`**
with a **guided prompt/response** surface first. This keeps the six (nine
counting delete/backlog/restore) autonomous verbs completely untouched while
delivering the bulk of `plan-review`'s (and `plan-clarify`'s) value; full chat
for `plan-discuss` follows on the same session machinery in a later phase.
Trade-off accepted: modest duplicated spawn scaffolding between `TaskRun` and
`ReviewSession`, and a git-safety question the guided path still raises because
`plan-review` checks out/rebases in the working tree (deferred to §5). Both
fork recommendations are recorded as **recommendations, not locked decisions** —
they are exactly the forks a follow-up implementation task should confirm.

### 5. The read-only / git-safety invariant

**What the spec actually says (verified).** `desktop-app-spec.md` §2 is titled
**"## 2. Hard Constraint: The App Never Writes `.plans/` Itself"** (line 65).
Its load-bearing wording (lines 67–79):
- *"The app process MUST NEVER write to any `.plans/` directory, edit or create
  task files, change task status, or move tasks between projects."* In-process,
  all `.plans/` content is *"strictly read-only input."*
- Mutation *"happens in exactly one place"*: the app bundles an Agent-SDK
  **runner subprocess** (`Tools/work-task/run-task.ts`, built to
  `dist/run-task.js`), and *"that subprocess is the sole writer of a project's
  `.plans/` directory and git tree."*
- The driven-verb list is enumerated explicitly: *"capture, elaborate, execute,
  delete, backlog, and restore"* (lines 76–79). **Review is absent from that
  list** — the spec has no notion of an interactive review verb today, which is
  exactly the gap this brainstorm scopes. §8 point 7 (lines 467–470) restates the
  invariant for the acceptance summary.

So an in-app review path must preserve one hard rule: **all `.plans/` and git
mutation still flows through a spawned subprocess; the Swift app never touches the
working tree itself.** A `review-task.ts` driving `/plan-review` satisfies that —
the subprocess remains the sole writer. The genuinely new wrinkle is not *who
writes* but *what plan-review does to the working tree*.

**Why `plan-review` is different from the six existing verbs.** The six current
verbs mutate `.plans/` files (and, for execute, a worktree the skill itself
creates and tears down). `plan-review`, by contrast, operates on the **main
checkout** by default: per `~/.claude/skills/plan-review/SKILL.md` it runs
`git checkout [branch]` (step 5) and `git rebase [rebase-target]` (step 6) in the
project directory unless the task was executed with `keep`. Firing that from a
single in-app click would switch the user's working branch and rewrite history
underneath whatever they have open — precisely the class of "moving git state
must never follow from one click" hazard the spec's backlog carve-out already
guards against (spec §2 lines 81–88, and `run-task.ts`'s `buildBacklogPrompt`
which STOPs rather than auto-pausing an active task).

**The `keep`-worktree escape hatch (verified against #078).** Task #078
(`.plans/completed/078-add-keep-option-to-execution.md`) shipped the desktop
app's ability to request plans-cc's `keep` keyword. Its What (lines 14–17)
states: *"`plan-execute` already supports a trailing `keep` keyword that preserves
the execution git worktree past finish (`/plan-execute <id> worktree keep`), so
`/plan-review` can review the task in place and multiple tasks can be reviewed in
parallel."* Crucially, `plan-review`'s own SKILL.md (step 3.5) reads the task's
live `**Worktree:**` field and, when present and on disk, `cd`s **into that
worktree** and reviews in place — **skipping the `git checkout` entirely** (step 5:
*"If `review_in_worktree` is true … SKIP the `git checkout [branch]`"*). A kept
worktree is a self-contained checkout with the task branch already checked out, so
reviewing it touches neither the user's main branch nor their working tree. #078's
own Notes (lines 160–165) reinforce the boundary: teardown of a kept worktree is
deliberately deferred to `/plan-complete`, and *"the desktop app is view-only and
must NOT add worktree teardown logic of its own."*

**Recommendation.** Restrict any in-app review that touches git to
**`keep`-worktree tasks only**, as the safe first cut. Concretely: the in-app
"Review" action is offered only for a task carrying a live `**Worktree:**` field
(the app already parses and renders this as `isKeptWorktree` → the `⌂ kept`
glyph, per #078), and the spawned `review-task.ts` drives `/plan-review NNN`
which detects the worktree and reviews in isolation — no checkout, no rebase of
the main branch, no destruction of uncommitted work. This keeps the spec §2
invariant intact (subprocess is still the sole writer; the app never mutates git
itself) AND avoids the one-click-moves-git-state hazard. Non-kept tasks fall back
to a Phase-0 affordance (copy/deep-link `/plan-review NNN` to run in the terminal
— see §7), never an in-app git checkout.

**Outcome-log caveat (verified against #080).** Task #080
(`.plans/completed/080-investigate-false-error-status-terminal.md`) found and
fixed a false-alarm bug whose root cause is directly relevant here: the durable
`~/.claude/plans-cc/run-outcomes.log` is *"written only by the app-side
`TaskRunner.writeOutcome()` (`TaskRunner.swift:666-684`) — the terminal executor
(`Tools/work-task/run-task.ts`) has no outcome writer"* (#080 Diagnosis, lines
32–33). Any long-lived review session must therefore either (a) write its own
terminal `RunOutcome` via `RunOutcomeLog` when it ends (as §3(c) already
proposes, reusing `Sources/Plans/RunOutcomeLog.swift`), or (b) accept that a
review-only interaction records nothing. A Phase-0 terminal `/plan-review` writes
nothing to the log (same class as #080's terminal executions) — acceptable for
Phase 0, but Phase 1's `ReviewSession` should close the gap by logging its own
outcome so a review that stranded or errored is diagnosable after the sheet
closes, exactly as `TaskRun` does today.

### 6. Bundled-SDK feasibility for the interactive path

**What is confirmable from the repo (no runtime).** Verified against
`Tools/work-task/package.json`, `package-lock.json` was consulted, `build.mjs`,
and `tsconfig.json`:
- The pinned dependency is **`@anthropic-ai/claude-agent-sdk` at `^0.3.215`**
  (`package.json` line 11). devDeps: `esbuild ^0.28.0`, `typescript ^5.6.0`,
  `@types/node ^22.0.0`.
- The bundle is produced by `build.mjs` (esbuild): it esbuilds `run-task.ts` into
  `dist/run-task.js` with the SDK marked **`external`** (line 43), then `cpSync`s
  the real `@anthropic-ai/claude-agent-sdk` package AND the platform-native CLI
  package (`claude-agent-sdk-<platform>-<arch>`) into `dist/node_modules/`
  (lines 50–68). The header comment (lines 12–18) explains why: at `query()` time
  the SDK resolves a native CLI binary from a sibling optional package via
  `createRequire(import.meta.url).resolve(...)`, which needs a real on-disk
  `node_modules` tree — so the SDK cannot be inlined. Auth is the inherited
  `claude login` credential (`run-task.ts` header, lines 41–42); no
  `ANTHROPIC_API_KEY`.

**Honest limitation.** The actual bundled/installed SDK **cannot be inspected in
this worktree**: `node_modules/` (and the generated `dist/`) are gitignored and
not copied into worktrees — confirmed in §1's discovered-assumptions note and
corroborated by #078's build note (line 137: *"`node_modules` was NOT present in
the worktree (gitignored, not copied into worktrees), so `npm ci` … was required
first"*). So the exact resolved SDK version and its actual type signatures are
**not** verifiable here; the version below is the *pin*, and the API claims are
reasoned from the pin + the existing call site, not read off the installed
package.

**Feasibility reasoning (pin + existing call site).** `run-task.ts` already calls
`query({ prompt, options })` (L682) with `permissionMode: "acceptEdits"` (L686)
and an explicit `allowedTools` allowlist (L692–716). Two facts follow:
- **`AskUserQuestion` under `acceptEdits` is gated by the allowlist, not the
  permission mode.** The current runner's whole design turns on `AskUserQuestion`
  being *excludable* from `allowedTools` (that omission is what makes the six
  verbs non-interactive), and `buildDeletePrompt` pre-answers gates *because* the
  tool is not allowlisted. The symmetric inference is that **adding**
  `AskUserQuestion` to `allowedTools` re-enables it — permission mode
  `acceptEdits` governs file-edit auto-approval, not whether a question tool may
  run. This is a strong inference from the existing code but is **not
  runtime-proven** here; it is the single most important thing a Phase-1 spike
  must confirm against the real installed SDK.
- **Streaming / async-iterable prompt input.** The current call passes a single
  static **string** `prompt`. An interactive session needs the agent to *pause,
  ask, and resume on a stdin-delivered answer* — i.e. the SDK's streaming-input /
  async-iterable prompt form (feeding messages over the life of the session)
  rather than one string. Whether `0.3.x` exposes that shape, and its exact
  signature, is **not confirmable from this repo** (source is not vendored) and
  is the second thing the Phase-1 spike must verify. If `0.3.215` lacks a
  usable streaming-input form, Phase 1 needs an SDK bump (with its own risk —
  see below) or a different interaction mechanism.

**Design risk: stale bundled SDK vs. moving default model.** There is a
documented failure mode where a *stale bundled Agent SDK version silently breaks
runs against a new default model* — the class of failure captured in this
project's memory ("stale bundled Agent SDK vs new default model breaks
captures") and consistent with #080's family of silent-terminal-failure
surprises. For the **one-shot** verbs this is a bounded blast radius: a run fails
fast and the user re-runs. For a **long-lived interactive review session** it is
worse — a session can spawn, stream for several turns, and only fail deep into a
conversation the user has invested time in, or hang awaiting input that will never
resolve. This makes SDK freshness a first-class **maintenance/feasibility risk**
for the interactive path specifically: the bundle must be rebuilt (`npm ci` +
`npm run build`, per #078 line 137) whenever the SDK or default model moves, and
`review-task.ts` should surface SDK/model errors as an explicit terminal
`error` event (and a logged `RunOutcome`, per §5) rather than a silent hang, so a
stale-SDK failure is legible instead of a stuck spinner.

### 7. Phased recommendation and open forks

The brainstorm's conclusion is a three-phase path, ordered by value-per-unit-risk.

**Phase 0 — a lightweight "Review" affordance (no new session machinery).**
A Surface B "Review" action in `PlanDetailView` that, rather than driving an
interactive run, either **copies / deep-links `/plan-review NNN`** for the user to
run in the terminal, or — for a `keep`-worktree task — **opens the kept worktree**
(reveal in Finder / open in the user's editor or terminal at the worktree path
the app already parses). Zero new I/O, zero SDK risk, zero git-safety exposure
(it launches nothing that mutates the tree). It closes the *discoverability* gap
immediately and validates demand before any of the heavy lifting. Caveat: a
terminal `/plan-review` writes no `RunOutcome` (§5, #080), which is fine at this
phase.

**Phase 1 — guided prompt/response review session (the core build).**
The four building blocks of §3, scoped to `plan-review` (+ `plan-clarify` riding
the same surface):
1. bidirectional I/O — `standardInput = Pipe()` + `send(_:)` on the new session
   (§3a);
2. `review-task.ts` — a sibling runner that allowlists `AskUserQuestion`, reads
   stdin, drives `/plan-review NNN`, and emits the additive `question` /
   `awaiting_input` event kinds (§3b);
3. `ReviewSession` — the long-lived `@Observable` sibling to `TaskRun`, holding
   the transcript, `pendingQuestion`, and input state, and writing its terminal
   `RunOutcome` (§3c, §5);
4. a Surface B guided-response view rendering `AskUserQuestion` option sets as
   **buttons** over a scrolling transcript (§3d).
Gated to **`keep`-worktree tasks only** (§5) so review runs in isolation and the
git-safety invariant holds. Prerequisite: the Phase-1 spike from §6 must first
confirm, against the real installed SDK, that `AskUserQuestion` runs under
`acceptEdits` when allowlisted and that a streaming-input prompt form exists in
the pinned `0.3.x`.

**Phase 2 — full free-form chat for `plan-discuss`.**
Add a free-text input box (template: `ElaborateModal`'s `PlanTextEditor`) and an
unbounded transcript on the *same* `ReviewSession` machinery, plus a
`discuss-task.ts` (or a mode of `review-task.ts`) driving `/plan-discuss`. This is
the largest UI and serves the one skill actually designed as open conversation;
it is deliberately last.

**Open forks needing a human decision (to split into a follow-up implementation
task):**
1. **New `ReviewSession` + `review-task.ts` vs. extending `TaskRun`/`run-task.ts`
   with stdin** (§4 fork i). Recommended: new session. Needs sign-off before
   coding.
2. **Guided-buttons-first vs. chat-first** (§4 fork ii). Recommended: guided
   first. Needs sign-off.
3. **`keep`-only review vs. also supporting non-kept tasks** (§5). Recommended:
   `keep`-only first; non-kept via Phase-0 terminal hand-off only. A later
   expansion could add an in-app "checkout + review" path *if* it reuses
   `plan-review`'s own uncommitted-changes and rebase-conflict `AskUserQuestion`
   gates (which the guided UI can already render) — but that reintroduces
   main-branch mutation and needs explicit approval.
4. **SDK feasibility spike outcome** (§6). Blocking for Phase 1: does the pinned
   `@anthropic-ai/claude-agent-sdk ^0.3.215` support streaming-input prompts and
   `AskUserQuestion` under `acceptEdits`? If not, decide between an SDK bump
   (with the stale-SDK maintenance risk) and an alternative mechanism.
5. **Does this belong in `desktop-app-spec.md` yet?** (see the spec note below).

**Spec-file decision (why `desktop-app-spec.md` was NOT edited).** The spec's §2
is deliberately an *authoritative invariant* describing what the app *does today*
(the six shipped driven verbs; review is explicitly absent). Adding a "Review
(interactive handoff)" section now would encode a *proposed, unbuilt, and still-
forked* design into the authoritative contract before any of its open forks are
resolved or its SDK feasibility is runtime-confirmed — risking exactly the "stale
wording" the spec's own §2 note (lines 100–103) calls out. The right time to
amend the spec is when the follow-up implementation task lands (or when the forks
above are decided), not during the brainstorm. This design exploration therefore
lives entirely in this task's `## Notes`; the spec is left untouched by design.

**Reopened:** Quick reopen (2026-11-09) to revisit in-app review. The open forks in section 7 are still undecided.

### 8. Implementation research (2026-11-09)

The brainstorm's How steps were completed on 2026-09-24 and are replaced above by the build plan; sections 1 to 7 are kept as background. This section supersedes them where they conflict. Evidence is from source, `.d.ts` files, the bundled CLI, and docs. Nothing has been run; How Step 1 is the runtime check.

**Decisions (user, 2026-11-09):** live process with `canUseTool` and a review-only stdin pipe; the review panel replaces the Discuss composer; if the slash prompt is blocked, drop `disable-model-invocation` in plans-cc; keep "Resolve for me"; tests plus a live kept-worktree review as verification.

**Decisions (user, 2026-11-10):** review offers three locations (kept, new review worktree, main checkout) with a per-project default in app prefs and a read-only preflight; the review panel gets open-in buttons. A per-project worktree setup command (e.g. `npm ci`, `pod install`) next to `worktree_links` is a separate plans-cc follow-up, not part of this task.

**Superseded from the brainstorm:**
- Section 3/4: no `ReviewSession` or `review-task.ts`. A `--mode review` and a `.review` `TaskRun` are enough, and `build.mjs` has a single entrypoint.
- Section 6: the allowlist does not gate `AskUserQuestion`. The CLI disables it in non-interactive runs with no permission host, which is why today's verbs never see it. Never set `canUseTool` for other modes, or autonomous verbs could wait forever.
- A bare `allowedTools` entry bypasses `canUseTool`, hence stripping `AskUserQuestion` from the merged allowlist.
- Async-iterable prompts aren't needed: `canUseTool` works with a single string prompt for one turn.

**Why not per-turn resume (Discuss's pattern):** a resumed turn likely loses the `cd` into the kept worktree, so git or a fix sub-agent could run in the main checkout.

**SDK facts (0.3.215):** `canUseTool` at `sdk.d.ts:206-266`, result type at `:2087-2099`; `AskUserQuestion` input and output in `sdk-tools.d.ts`. A parked callback has no deadline. Answers return as `{behavior:"allow", updatedInput:{questions: input.questions, answers:{[questionText]: label}}}`.

**Pitfalls:**
- `isKeptWorktree` only means the field is non-empty. With a stale path, `plan-review` step 3.5 falls through to `git checkout` and rebase in the main checkout, so the runner guard is mandatory. The parser doesn't retain the path, so the guard lives in the runner and `canReview` doesn't check the disk.
- Only the `worktree` location may put the word `worktree` in the skill arguments; the skill keyword-matches it. Omit the "Do not ask" trailers.
- Nothing in `Sources` ignores SIGPIPE, so a write racing process exit could kill the app.
- A review failing on a stale bundled SDK only shows after the user has invested in a session, so emit explicit `error` events.
- Stop while parked logs as `completed` (existing quirk), and a killed rebase can stay paused in the worktree.
- The app quit ends a parked review; re-running picks up remaining `⏳` observations.

**`plan-review` gates:** Uncommitted changes (Stash/Commit/Abort); Rebase conflict (Resolve for me/Resolve in place/Abort rebase/Skip rebase), with a model-generated nested question; per-observation loop (Looks good/Something's wrong/Skip). The only status change is `review` to `in-review`; it ends with a summary and suggests `/plan-complete`.

### 9. How-Step-1 spike results (2026-11-10)

Ran live throwaway spikes (`/tmp/spike-083*.mjs`, deleted after; nothing committed) importing `query` from the worktree's installed SDK (`createRequire`-resolved from `Tools/work-task/node_modules/@anthropic-ai/claude-agent-sdk`, confirmed version **0.3.215**, resolving `sdk.mjs`). Keychain creds (`Claude Code-credentials`) were present, so the SDK's bundled `claude` CLI started and real `/plan-review` runs executed. **Provenance:** before/after every run, `git rev-parse --abbrev-ref HEAD` = `feature/083-guided-in-app-plan-review` and `git rev-parse HEAD` = `f04eff5c3ba8f79c98063392e2f34fad8642ee40`, unchanged; worktree `git status --porcelain` stayed clean (the SDK's own `node_modules`/`dist` are gitignored). Observations are therefore VALID.

**Verdict: GREEN — both blocking checks (b) and (f) are runtime-proven; proceed to Step 2.**

- **(a) PROVEN LIVE — slash prompt expands despite `disable-model-invocation: true`; NO SKILL.md edit needed.** With `prompt: "/plan-review 999"` the model first tried the `Skill` tool and got `<tool_use_error>Skill plan-review cannot be used with Skill tool due to disable-model-invocation</tool_use_error>`, then stated verbatim *"The skill instructions have already been loaded into this conversation, so I'll follow them directly"* and walked steps 1→6 exactly as written. So the slash-command string injects the SKILL.md body into the turn regardless of `disable-model-invocation` (which only blocks the model-invoked `Skill` tool, not the `/command` expansion). The task's remediation (flip `disable-model-invocation: false` in the external plans-cc skill) is therefore NOT required; the external skill was left untouched.
- **(b) PROVEN LIVE (BLOCKING → GREEN) — `canUseTool` receives `AskUserQuestion` once it is stripped from the allowlist.** Passing `allowedTools: ["Read","Write","Edit","Bash","Glob","Grep","Agent"]` (AskUserQuestion omitted), `canUseTool` fired for `AskUserQuestion` with a valid string `toolUseID` (`toolu_…`). The SDK confirmed the mechanism with an explicit warning: `[CLAUDE_SDK_CAN_USE_TOOL_SHADOWED] … Bare allowedTools entries auto-approve the whole tool before the callback is consulted … remove the bare names from allowedTools so they fall through to canUseTool.` This nails §8's claim ("a bare allowedTools entry bypasses canUseTool, hence stripping AskUserQuestion"). Step 2's runner MUST strip `AskUserQuestion` from the *merged* allowlist (including config extras) for `canUseTool` to see it.
- **(c) REASONED FROM SOURCE (not runtime-proven).** The free-text "Something's wrong" path requires a `.plans/state/NNN-state.md` with `⏳ Deferred to review` entries to reach step 7's observation loop, which this bounded spike did not stage. From `sdk.d.ts` CanUseTool (`:206-266`) + §8's SDK facts: the answer `{behavior:"allow", updatedInput:{questions: input.questions, answers:{[questionText]: label}}}` returns the chosen label; free text travels via the AskUserQuestion "Other" field / the `label` string. SKILL.md step 7's "Something's wrong" branch then asks the user to describe what they saw and routes it to a fix sub-agent. Low runtime risk — the answer plumbing is identical to (b), which IS proven; only the specific branch wasn't driven. (Labeled reasoned-from-source.)
- **(d) REASONED FROM SOURCE (not runtime-proven) — deliberately not run (no 10-minute park).** §8 and `sdk.d.ts` confirm a parked `canUseTool` callback has no deadline (it is a plain awaited Promise), so a >10-min park survives at the SDK layer. SIGTERM-while-parked / orphan-CLI behavior is a Swift `TaskRunner` process-teardown concern (Step 3: close the stdin pipe in `finish`, ignore SIGPIPE) and is covered by Step 8's manual check — not derivable from this import-level spike. (Labeled reasoned-from-source.)
- **(e) PROVEN LIVE — `/plan-review 999 worktree` creates the review worktree and writes `**Worktree:**` headless.** On a non-kept task (no `**Worktree:**` field, clean base tree) the run completed fully (`result subtype:"success"`, 12 turns) and created `.worktrees/999-spike-wt/` on disk, writing `**Worktree:** <abs-path>` below the `**Branch:**` line in the task file — exactly the field Step 6's open-in buttons and plan-review step 3.5 depend on. With a clean tree and no deferred observations it never hit an AskUserQuestion.
- **(f) PROVEN LIVE (BLOCKING → GREEN) — dirty main-checkout raises the "Uncommitted changes" gate through `canUseTool`.** Fixture: task `#999` status `review`, branch `feature/999-spike-fixture`, base branch `main` with an uncommitted edit (`M README.md`). The skill reached step 4 and called `AskUserQuestion` with header **"Uncommitted changes"**, question text naming the modified file, and the three options **Stash changes / Commit changes / Abort** — surfaced through `canUseTool` (the spike denied it to end fast). This confirms the main-checkout review's safety gate is interceptable by the runner bridge.

**Net:** (a)(b)(e)(f) runtime-proven on SDK 0.3.215; (c)(d) reasoned-from-source with low risk. The §8 architecture (strip AskUserQuestion → `canUseTool` → stdin answer) is confirmed viable. No external skill edited. Clear to build Step 2.
