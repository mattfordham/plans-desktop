# Changing Projects And Plans Is Very Laggy

**ID:** 113
**Created:** 2026-11-08T19:16
**Type:** bug
**Status:** completed
**Completed:** 2026-11-09T10:41
**Branch:** fix/113-changing-projects-and-plans-is-laggy

## What
Changing projects and plans is very laggy. I wonder if we could use some kind of suspense boundary or something deeper in so that the tabs can change immediately and then have the contents come in when ready.

## Why
Switching sidebar entries (projects / smart views / "All projects") and selecting
a plan feels sluggish because heavy, uncached rendering work runs **synchronously
on the main thread inside the view body** during the same render pass SwiftUI
triggers when the selection changes. The dominant cost is in `PlanDetailView`:
when a plan is selected the detail column is rebuilt fresh (it is keyed by
`.id(selectedRowID)` in `BrowserWindow.detailColumn`), and every `## ` section's
body is re-parsed via `MarkdownBlockRenderer.parse(body)` and then rendered
block-by-block with `CodeHighlighter.highlight(...)` and per-paragraph
`AttributedString(markdown:)` — all in-body, uncached, on the main thread, and
re-run on every 5-second poll while the plan is open. Deferring that heavy
markdown parse/highlight behind a "suspense boundary" (show a lightweight
placeholder immediately, then fill real content from an off-main parse keyed to
the selection) lets the tab/selection switch update instantly and the content
arrive when ready — exactly the behaviour requested.

## How Summary
Introduce the suspense boundary **deep in `PlanDetailView`, around the parsed
markdown body** — the single highest-impact, lowest-risk seam. Extract the
current synchronous `markdownBlockView(_ body:style:)` (`PlanDetailView.swift`
~:1505) into a small child view that:

1. Renders a lightweight placeholder immediately (raw body as plain `Text`) so the
   detail column — and therefore the plan/tab switch — appears instantly.
2. Computes `MarkdownBlockRenderer.parse(body)` **off the main thread** and stores
   the resulting `[MarkdownBlock]` in `@State`, driven by `.task(id:)` keyed to
   the body so it runs once per plan, auto-cancels when the selection moves on,
   and does **not** re-run on idle polls that republish identical content.

Back the view with a pure, unit-testable helper (`AsyncMarkdownParser`) that
owns the generation-guarded "parse off-main, apply only if still current" logic
— mirroring the existing `PlansStore.reloadAsync` / monotonic-generation pattern
(`PlansStore.swift:992`). TDD the helper (parse correctness, generation guard
drops stale results, identical body is a no-op), then wire the view to use it.
`MarkdownBlock` is already `Equatable`, so stored blocks compare cleanly and an
unchanged body produces no view churn.

**Files of note:**
- `Sources/Plans/PlanDetailView.swift` — `markdownBlockView` (~:1505) and its
  caller `sectionView` (~:1494). This is the insertion seam; extract the body
  rendering into an async placeholder-then-fill child view here.
- `Sources/Plans/MarkdownBlockRenderer.swift` — `parse(_:)` (:33) is the pure,
  already-off-mainable parser the boundary defers; `MarkdownBlock` (:9) is
  `Equatable`. No change needed beyond being called off-main.
- `Sources/Plans/PlansStore.swift` — `reloadAsync` (:992) / generation-guard
  pattern (:1042) is the reference model for "do heavy work off-main, apply on
  main, drop stale results."
- `Tests/PlansTests/PlanDetailViewTests.swift` — mirror its pure-static-helper
  testing style for the new `AsyncMarkdownParser` tests (no view rendering).
- `Tests/PlansTests/MarkdownBlockRendererTests.swift` — reference for expected
  parse output when asserting the async helper returns the same blocks.

## How
- [x] Step 1: Add a failing `PlanDetailViewTests` (or a new `AsyncMarkdownParserTests`) case that exercises a pure, testable parse helper: given a markdown body, the helper returns exactly the same `[MarkdownBlock]` as `MarkdownBlockRenderer.parse(body)` (assert against a representative body with a paragraph, a bullet list, and a fenced code block). This drives the existence of the extractable helper. (Agent-verifiable; untagged.)
- [x] Step 2: Add a failing test for the generation guard: simulate an out-of-order completion (an older parse generation finishing after a newer one) and assert the helper keeps the newest result and drops the stale one. Model the token/generation comparison as a pure function so it can be asserted without SwiftUI (mirror `PlansStore`'s monotonic generation counter). (Agent-verifiable; untagged.)
- [x] Step 3: Implement `AsyncMarkdownParser` — a small pure helper (static funcs or a lightweight value type) that: (a) exposes `parse(_ body:) -> [MarkdownBlock]` delegating to `MarkdownBlockRenderer.parse` (so it can run off-main), and (b) exposes a pure generation/identity check used to decide whether a completed parse should be applied (newest-wins). Make Steps 1–2 green. No behaviour change to `MarkdownBlockRenderer` itself.
- [x] Step 4: Extract the current `markdownBlockView(_ body:style:)` body-rendering into a new child `View` (e.g. `AsyncMarkdownBlockView(body:style:)`) that holds `@State private var blocks: [MarkdownBlock]?`, renders a lightweight placeholder (`Text(body)` styled plainly, or a redacted skeleton) while `blocks == nil`, and renders the real `renderBlock(...)` output once `blocks` is set. Keep `renderBlock` / `markdownParagraph` / `CodeHighlighter` usage identical so visual output is unchanged once loaded.
- [x] Step 5: Drive the child view with `.task(id: body)` that computes `AsyncMarkdownParser.parse(body)` off the main thread (e.g. a detached/background `Task` or `MainActor.run` hop mirroring `reloadAsync`), checks `Task.isCancelled` / the generation token before assigning, and assigns `blocks` on the main actor. Confirm a `.task(id: body)` re-runs only when `body` actually changes (so identical poll republishes don't thrash), and that selecting a new plan (`.id(selectedRowID)` → fresh view) shows the placeholder then fills. Wire `markdownBlockView` / `sectionView` to use the new child view in both the plan-body (`style: .plan`) and compact discussion-reply (`style: .compact`) call sites so both paths get the boundary.
- [x] Step 6: 👁 Build and run the app (`./build.sh`), open the browser window, and switch between projects / smart views / "All projects" and click into several plans. Confirm the sidebar selection and detail column update immediately (placeholder appears instantly) and the rendered markdown fills in a beat later, with no visual regression in the final rendered content and no flicker on idle polls.

## Verification
- `swift test --filter PlanDetailViewTests` and the new async-parser tests pass, including the generation-guard (newest-wins) test.
- The async helper returns byte-identical `[MarkdownBlock]` to `MarkdownBlockRenderer.parse` for representative bodies (paragraph + list + code block).
- Running the app: selecting a plan updates the detail column instantly with a placeholder, then the fully-rendered markdown appears shortly after; switching sidebar entries feels responsive.
- No visual regression — once loaded, the rendered plan body (headings, lists, code highlighting, inline formatting) is identical to before.
- No re-parse thrash: an idle 5-second poll that republishes identical content does not clear/re-render an already-loaded body.

## Impact Scope
- `Sources/Plans/PlanDetailView.swift` — extract `markdownBlockView` into an async placeholder-then-fill child view; rewire `sectionView` and the compact reply call site.
- `Sources/Plans/AsyncMarkdownParser.swift` (new) — pure, testable off-main parse + generation-guard helper.
- `Tests/PlansTests/AsyncMarkdownParserTests.swift` (new) OR additions to `PlanDetailViewTests.swift` — parse-equivalence and generation-guard tests.

## Assumptions

### Initial (from elaboration)
- [high] The highest-impact "suspense boundary" seam is the markdown body parse/highlight inside `PlanDetailView`, not the sidebar/content-column recompute. **Why:** Research confirmed parsing data is already cached and off-main in `PlansStore` (`parseCache`, `reloadAsync`); the uncached, in-body, main-thread cost is `MarkdownBlockRenderer.parse` + `CodeHighlighter.highlight` + per-paragraph `AttributedString(markdown:)` in `PlanDetailView`, re-run on every selection and every poll. Deferring it matches the "contents come in when ready" framing with the least risk.
- [low] Use a plain `Text(body)` (raw markdown) as the instant placeholder rather than a `.redacted` skeleton. **Why:** It is readable immediately, requires no layout guesswork, and avoids a skeleton that mis-sizes; the real rendered blocks replace it a beat later. A redacted skeleton is an acceptable alternative if it reads better in practice (deferred to the observation step).
- [low] Scope the change to the `PlanDetailView` markdown seam only; do NOT also convert `ProjectStackView`'s deliberately non-lazy `VStack` (#063/#096 layout-loop history) in this task. **Why:** The content-column stack is intentionally non-lazy to avoid a documented layout-loop hang; touching it is higher-risk and a separate concern. The detail-column markdown seam is the requested "deeper in" boundary and the biggest win. If content-column switching remains laggy after this, capture a follow-up.
- [high] Keep the generation-guard / off-main-then-apply logic in a pure helper so it is unit-testable without rendering SwiftUI. **Why:** Matches the project's TDD convention of testing pure static helpers (see `PlanDetailViewTests`), and mirrors the existing `PlansStore.reloadAsync` generation pattern.

### Discovered during execution
- [high] Generation guard uses `==` (exact match) not `>=`: `shouldApply(completed:current:) = completed == current`. **Why:** With a monotonically-increasing generation counter, only the parse kicked off for the current generation should be applied; a stale older result (completed < current) is dropped, and a "future" result (completed > current) can't legitimately occur, so exact-match is the strictest, clearest newest-wins rule. `>=` would admit impossible future values with no benefit.
- [high] `AsyncMarkdownParser.parse` delegates verbatim to `MarkdownBlockRenderer.parse` (no own parsing logic); the new type exists only to give callers a thread-agnostic entry point plus the pure generation guard. **Why:** Avoids duplicating/forking parse logic; keeps `MarkdownBlockRenderer` untouched per segment scope.
- [high] `AsyncMarkdownBlockView` is nested in `PlanDetailView` and receives the parent's private `renderBlock(_:style:)` as a `@ViewBuilder` closure rather than re-implementing it. **Why:** `renderBlock`/`markdownParagraph`/`CodeHighlighter`/`MarkdownStyle` are private to `PlanDetailView`; passing the closure keeps the loaded output byte-identical to the former synchronous path with zero code duplication. The existing `markdownBlockView(_:style:)` now just wires the closure through, so BOTH call sites (section body ~L1494 `.plan`, discussion reply ~L985 `.compact`) switch to the async path without touching the call sites themselves.
- [low] Placeholder is a plain `Text(bodyText)` (raw markdown) styled secondary in the same `VStack(spacing: style.blockSpacing)` container, not a `.redacted` skeleton. **Why:** Readable immediately and no size guesswork; confirmed the elaboration's low-confidence placeholder choice. Final read-quality call deferred to the observation step.
- [high] `blocks` resets to `nil` INSIDE `.task(id: bodyText)` (at the task start), never on every body evaluation. **Why:** `.task(id:)` re-runs only when `bodyText` actually changes, so an idle 5s poll that republishes identical content does NOT clear or re-parse already-loaded blocks — no flicker. Resetting at task start shows the placeholder again only on a genuine body change.
- [high] Used `_Concurrency.Task.detached` / `_Concurrency.Task.isCancelled` (fully qualified). **Why:** This module declares its own `struct Task` in `TaskParser.swift`, which shadows Swift's concurrency `Task`; without qualification the build fails with "type 'Task' has no member 'detached'".

## Changes
- `Sources/Plans/AsyncMarkdownParser.swift` (new) — Pure helper `enum` mirroring `MarkdownBlockRenderer`'s shape. `parse(_ body:) -> [MarkdownBlock]` delegates to `MarkdownBlockRenderer.parse` (safe to call off-main); `shouldApply(completed:current:) -> Bool` is the newest-wins generation guard (`completed == current`). `MarkdownBlockRenderer` untouched.
- `Tests/PlansTests/AsyncMarkdownParserTests.swift` (new) — `testParseMatchesMarkdownBlockRenderer` (parse-equivalence for paragraph + bullet list + fenced code block) and three generation-guard tests (`testShouldApplyWhenGenerationMatchesCurrent`, `testShouldNotApplyStaleResult`, `testShouldNotApplyFutureResult`). `swift test --filter AsyncMarkdownParserTests` → 4/4 pass.
- `Sources/Plans/PlanDetailView.swift` — Added a nested `private struct AsyncMarkdownBlockView<BlockView: View>` implementing the suspense boundary: `@State blocks: [MarkdownBlock]?` + `@State generation`, renders a plain secondary `Text(body)` placeholder (same `VStack(spacing: style.blockSpacing)` container) while `blocks == nil`, then renders the loaded blocks via the parent's private `renderBlock(_:style:)` passed in as a `@ViewBuilder` closure (byte-identical output). Driven by `.task(id: body)`: resets `blocks = nil`, bumps/captures `generation`, parses off-main via `_Concurrency.Task.detached(.userInitiated) { AsyncMarkdownParser.parse(body) }`, and applies the result on the main actor only if not cancelled and `AsyncMarkdownParser.shouldApply(completed:current:)` (newest-wins). The existing `markdownBlockView(_:style:)` now delegates to this view, so BOTH call sites — the plan section body (`style: .plan`, ~L1494) and the compact discussion reply (`style: .compact`, ~L985) — get the boundary with no call-site edits and no dead code. `swift build` succeeds.

### Outcome after review (supersedes the async approach above)
Manual review found the lag persisted after moving parsing off-main. A `sample` of the running app showed about 30% of main-thread busy time was the plan pane's stack probing its `ScrollView` height, which measured the whole plan's text; app code barely registered.
- `Sources/Plans/PlanDetailView.swift` — the plan `ScrollView` now declares `.frame(minHeight: 0, maxHeight: .infinity)`, so its flexibility is known without measuring content. User confirmed plan switching is faster.
- The placeholder caused visible layout shift and saved only about 4ms typical / 20ms worst, so it was removed along with the background task and generation guard. `PreparedMarkdownBlockView` renders final content on the first frame via `PreparedMarkdownCache.preparedBlocks`.
- `AsyncMarkdownParser.swift` renamed to `MarkdownPreparer.swift` (tests likewise). `swift test` → 795 pass.

### Deferred observation (yolo — to be verified at review)
- Step 6 (👁): run the app, switch projects/plans, confirm the detail column updates instantly (placeholder appears) then markdown fills in, no visual regression, no idle-poll flicker. Deferred to `/plan-review 113`. Provenance: branch `fix/113-changing-projects-and-plans-is-laggy` @ `0471916e83e36c18cbff70477dc591d86bf83f3c`.

## Notes
Autonomous (yolo) run. Research sub-agent located the bottleneck and insertion
seam; all elaboration decisions above were made autonomously and recorded as
assumptions. The observation step (Step 6) is deferred to review per yolo mode.
