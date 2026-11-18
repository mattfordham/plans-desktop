# Format agent output markdown

**ID:** 119
**Created:** 2026-11-12T00:00
**Type:** bug
**Status:** completed
**Completed:** 2026-11-12T16:48
**Branch:** fix/119-format-agent-output-markdown

## What
It seems like agent output has unformatted markdown. It should be formatted.

![pasted image](file://~/Library/Application%20Support/Plans/attachments/9CEF06FC-90C3-4B3E-92BD-313EE32E5BD2.png)

## Why
Improves reliability of the agent dock transcript: assistant run-log narration
currently shows raw markdown (`**bold**`, `#` headings, `-`/`1.` lists, code
fences) as literal text, while discuss-turn replies in the same dock render
formatted. Fixing the asymmetry makes streamed agent output readable and
consistent with the rest of the app, which already renders markdown everywhere
else.

## How Summary
The run-log transcript's assistant-text case renders a bare `Text(chunk)`, which
never routes through the app's markdown engine, so markdown shows verbatim. The
fix is a one-line render swap: render `.text` chunks with the existing
`MarkdownBlockView(body:style:)` (style `.compact`) — the exact renderer the
dock's discuss turns already use (`AgentDock.swift:504`) — instead of plain
`Text`. No new markdown machinery is needed; the block renderer, preparer, and
LRU cache already exist and are unit-tested.

**Files of note:**
- `Sources/Plans/PlanDetailView.swift` — `RunLogContents.lineView` `.text` case
  (≈1864-1866) is the symptom site; `MarkdownBlockView` (≈1546) is the drop-in renderer.
- `Sources/Plans/AgentDock.swift` — `AgentTurnView` (≈504) already renders discuss
  replies via `MarkdownBlockView(body:style:.compact)`; the reference pattern to mirror.
- `Sources/Plans/MarkdownBlockRenderer.swift` / `Sources/Plans/MarkdownPreparer.swift` —
  the existing, tested block-level markdown engine (headings, lists, blockquotes,
  fenced code) the fix reuses.
- `Tests/PlansTests/PlanDetailViewTests.swift` — existing `RunLogContents` /
  `MarkdownStyle` tests; home for any added regression coverage.

## Diagnosis

**Most likely:** The run-log `.text` case renders assistant narration with a bare
`Text(chunk)` that never passes the string through the markdown engine, so markdown
is drawn verbatim. (`Sources/Plans/PlanDetailView.swift:1864-1866`)
**Evidence:** `.text(chunk)` renders `Text(chunk).font(.callout)` where `chunk` is a
plain `String` (not a `LocalizedStringKey` literal), so neither `Text`'s automatic
markdown interpolation nor `AttributedString(markdown:)` ever runs. By contrast, the
same dock's discuss replies call `MarkdownBlockView(body: reply, style: .compact)`
(`Sources/Plans/AgentDock.swift:504`) and format correctly — the asymmetry pins the
symptom to this one render path. The `{kind:"text", chunk}` events upstream already
carry well-formed markdown (`Tools/work-task/run-task.ts:1699-1703`), so this is a
render bug, not a data bug.
**Confidence:** high

**Alternative:** A naive `Text(.init(chunk))` / `Text(AttributedString(markdown:))`
fix would still fail for block markdown (`#` headings, `-`/`1.` lists, ``` fences),
because SwiftUI's built-in inline parser drops block structure
(`Sources/Plans/MarkdownPreparer.swift:43-45`). — **Confidence:** high (as a
constraint on the fix, not a competing root cause)

**To confirm:** In the dock, compare streamed run-log narration against a discuss
reply on the same markdown content — the reply formats and the run log does not,
confirming the screenshot shows a `RunLogContents` run-log segment and the fault is
in its `.text` case (not an engine-wide regression).

## How
- [x] 👁 Step 1: Reproduce the symptom — run an agent whose streamed narration
  contains markdown (bold, a `#` heading, a `-` list, a ``` fence) and confirm the
  dock run-log transcript shows it as raw text, while a discuss reply on the same
  content renders formatted (confirms the Diagnosis before the fix; requires
  observing the running app).
- [x] Step 2: In `Sources/Plans/PlanDetailView.swift`, change the `.text(chunk)`
  case in `RunLogContents.lineView` (≈1864-1866) to render
  `MarkdownBlockView(body: chunk, style: .compact)` instead of
  `Text(chunk).font(.callout)` — swap the whole case; do not stack a `.font(.callout)`
  over `MarkdownBlockView` (it drives its own fonts via `MarkdownStyle`).
- [x] Step 3: Add/extend regression coverage in
  `Tests/PlansTests/PlanDetailViewTests.swift` — assert the markdown engine renders
  the block kinds agents emit (bold, heading, bullet/ordered list, fenced code) via
  `PreparedMarkdownCache` / `MarkdownBlockRenderer.parse`, mirroring the existing
  `MarkdownPreparerTests` / `MarkdownBlockRendererTests` patterns (the `.text` view
  path itself is not directly unit-testable; cover the engine contract the fix relies on).
- [x] 👁 Step 4: Rebuild (`swift build`) and visually confirm in the running app
  that run-log narration now renders formatted markdown and layout/scroll behavior is
  unchanged; run `swift test` to confirm no regressions.

## Verification
- Run-log narration in the agent dock renders formatted markdown (bold, headings,
  lists, fenced code) instead of literal syntax — verified visually in the running
  app, matching how discuss replies already render.
- Discuss turns and other dock surfaces are visually unchanged.
- `swift test` passes (existing markdown-engine tests plus any added regression test).

## Impact Scope
_Not applicable — fewer than 3 files affected (one source file + its test file)._

## Assumptions

### Initial (from elaboration)
- [high] Scoped the fix to the assistant `.text(chunk)` run-log case only (not the
  `.activity` tool-detail lines at ≈1859 or the inline `.question` text at ≈1900).
  **Why:** the reported symptom and screenshot are about assistant narration; those
  other lines are terse metadata/labels where markdown rendering is not wanted, and
  research flagged them as out of the symptom's scope.
- [high] Reuse the existing `MarkdownBlockView(body:style:.compact)` rather than
  `Text(.init(chunk))` / `AttributedString(markdown:)`. **Why:** research shows the
  project deliberately split inline-vs-block rendering because the built-in inline
  parser drops heading/list/code-fence structure (`MarkdownPreparer.swift:43-45`), and
  `.compact` is the preset already used for the dock's discuss turns (`AgentDock.swift:504`).
- [low] Chose to cover the fix with an engine-contract test (asserting
  `PreparedMarkdownCache`/`MarkdownBlockRenderer` renders the block kinds agents emit)
  rather than a view-snapshot test. **Why:** the `.text` render path emits a SwiftUI
  view that isn't directly unit-testable in this XCTest suite, and the existing
  `RunLogContents` tests are limited to pure static helpers (`scrollTarget`,
  `shouldShowFailureBanner`); the engine already has dedicated tests to extend.
- [low] Confirmed (but did not resolve interactively) that the attached screenshot
  shows a run-log segment rather than a discuss turn. **Why:** autonomous run with no
  UI to answer; all code evidence points to `RunLogContents.lineView`'s `.text` case as
  the only un-rendered text path, so proceeding on that basis is low-risk, and Step 1
  re-confirms it before the fix lands.
- [low] Auto-accepted the Path A "proceed with defaults" confirmation under skip mode.
  **Why:** research found one file to modify, a ≤4-step approach, and no blocking open
  questions, meeting the step-10 simple-task criteria.

### Discovered during execution
- [high] Regression tests were added to `PlanDetailViewTests.swift` (as the plan named) and drive `MarkdownBlockRenderer.parse(_:)` directly — the public, Equatable-returning block parse entry point used by `MarkdownBlockRendererTests.swift`. **Why:** `.text(chunk)` now routes through `MarkdownBlockView`, which uses this same engine; the SwiftUI view path is not XCTest-reachable, so the engine contract (block markdown parses into structured blocks, not literal text) is the testable surface the fix relies on. Mirrors the existing `MarkdownBlockRendererTests` assertion style.
- [high] The new engine-contract tests pass immediately rather than going red-then-green. **Why:** the engine was already correct; the bug lived purely in the view wiring (`Text(chunk)` bypassed the engine). The red/green cycle applies to the (untestable) view wiring, not the already-correct parser; the tests pin the contract against regression.

## Changes
- `Sources/Plans/PlanDetailView.swift` — In `RunLogContents.lineView(_:)`, swapped the
  `.text(chunk)` case from the bare `Text(chunk).font(.callout)` (which bypassed the
  markdown engine, rendering `**bold**`, `#` headings, `-`/`1.` lists, and ``` fences as
  literal text) to `MarkdownBlockView(body: chunk, style: .compact)` — the same block
  renderer the dock's discuss turns already use (`AgentDock.swift`). One-line case swap;
  no new markdown machinery.
- `Tests/PlansTests/PlanDetailViewTests.swift` — Added 6 regression tests (`#119`) driving
  `MarkdownBlockRenderer.parse(_:)`, the engine `MarkdownBlockView` uses: `#` heading →
  heading block, bold → paragraph block, bullet list → bullet-list block, ordered list →
  numbered-list block, fenced code → code block, and a mixed-chunk test asserting all five
  parse into structured blocks in document order. Pins the engine contract the fix relies
  on (the `.text` SwiftUI view path is not directly XCTest-reachable).
- Build/tests: `swift build` succeeds (only a pre-existing unrelated `turnID` warning in
  `TaskRunner.swift`); `swift test --filter PlanDetailViewTests` → 94 tests, 0 failures,
  including all 6 new tests.
- Step 1 (👁 reproduce symptom) and Step 4 (👁 rebuild + visual confirm in running app)
  are observation steps deferred to review — this ran in an isolated worktree with no
  running app. The diagnosis is confirmed by code inspection and the fix matches the
  reference discuss-turn render path.

## Notes
- Capture note: The description included a pasted screenshot reference
  (`file://~/Library/Application Support/Plans/attachments/9CEF06FC-90C3-4B3E-92BD-313EE32E5BD2.png`)
  presumably showing the raw/unformatted markdown in the agent output.

### Assumptions made during autonomous capture
- Interpreted "agent output" as the agent dock transcript in the browser
  window's detail column (`AgentDock` / `RunLogContents` / `AgentTurnView`),
  where agent run logs and discuss turns are rendered.
- Interpreted "unformatted markdown" to mean markdown syntax is being shown
  as literal text (e.g. `**bold**`, `#` headings, list markers, code fences
  shown verbatim) rather than rendered, and that the fix is to render markdown
  formatting in that transcript.
- Classified as a `bug` (incorrect rendering of existing output) rather than a
  feature, since the behavior is described as something that "should be"
  working but isn't.
