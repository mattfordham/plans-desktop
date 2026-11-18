# Add Higher Fidelity Markdown View Of Plan Files

**ID:** 050
**Created:** 2026-06-12T00:00
**Type:** feature
**Status:** completed
**Branch:** feature/050-add-higher-fidelity-markdown-view
**Completed:** 2026-06-15T00:00

## What
Add higher fidelity markdown view of plan files. Render in very readable way.

## Why
Adds value by making plan detail windows far more readable. Today
`PlanDetailView` renders each section body with `AttributedString(markdown:)`
using `.inlineOnlyPreservingWhitespace`, which only handles *inline* markdown
(bold/italic/links) inside blank-line-delimited paragraphs. Block-level
structure — bullet/numbered lists, fenced code blocks, blockquotes, and
sub-headings inside a section body — renders as flat, run-together text. A
proper block-level renderer makes plans much easier to scan and read.

## How
- [x] Step 1: Add a pure, testable block parser in a new file
  `Sources/Plans/MarkdownBlockRenderer.swift`. Define `enum MarkdownBlock`
  (cases: `.paragraph(String)`, `.bulletList([String])`,
  `.numberedList([String])`, `.codeBlock(String)`, `.blockquote(String)`,
  `.heading(level: Int, text: String)`) and a pure
  `static func parse(_ body: String) -> [MarkdownBlock]`. Write the parser
  test-first in `Tests/PlansTests/MarkdownBlockRendererTests.swift` (paragraphs,
  bullet `-`/`*`, numbered `1.`, fenced ``` code blocks, `>` blockquotes,
  `###` sub-headings, mixed content, and a malformed/unclosed-fence fallback to
  paragraph). Tolerate leading whitespace; never crash.
- [x] Step 2: In `PlanDetailView.swift`, add a `@ViewBuilder markdownBlockView(_:)`
  that calls `MarkdownBlockRenderer.parse(body)` and renders each block:
  paragraphs via the existing `markdownParagraph` inline renderer; bullet/
  numbered lists with hanging indentation and a marker; fenced code in a
  monospaced `Text` with a subtle `Color(nsColor: .textBackgroundColor)`
  background and rounded corners; blockquotes with a left rule/indent;
  sub-headings with a smaller emphasized font. Keep styling restrained.
- [x] Step 3: Switch `sectionView(_:)` to use `markdownBlockView` for all
  non-`How` sections (replacing the current `markdownBody` paragraph-only path).
  Leave the `## How` read-only checklist (`howChecklist`) exactly as-is.
- [x] 👁 Step 4: Build (`swift build`) and run the app (`./build.sh`) to visually
  confirm a plan with lists, code blocks, blockquotes, and sub-headings renders
  in a readable, well-structured way in both light and dark mode.

### Fidelity pass (reopened during review)
Review found block structure correct but styling too flat ("not high-fi" — user
wants a MacDown-grade look). The following steps push toward a richer palette
plus hand-rolled code syntax highlighting.
- [x] Step 5: Capture the fenced-code info string (language hint) in the parser.
  Changed `MarkdownBlock.codeBlock(String)` to
  `.codeBlock(language: String?, code: String)`; parses the first token after the
  opening ```` ``` ```` as the language (nil if empty). Tests updated.
- [x] Step 6: Added pure `Sources/Plans/CodeHighlighter.swift` — hand-rolled lexer
  (no deps) coloring keywords, strings, line/block comments, numbers, types
  (capitalized idents), and function calls. Knows Swift, JS/TS, JSON, shell, and
  a generic fallback. 20 tests in `CodeHighlighterTests.swift`.
- [x] Step 7: Applied the richer palette in `PlanDetailView.renderBlock`:
  depth-tinted headings (accent→teal→primary), blockquote with tinted panel +
  accent rule, code blocks on a bordered surface rendering the highlighted
  `AttributedString`, inline code as an accent monospaced chip.
- [x] 👁 Step 8: Built + ran the app; user confirmed the detail window reads as
  high-fidelity and editorial.

### Editorial typography pass (during review)
User asked for bigger/airier/more-editorial text. Centralized type/spacing in a
`PlanType` constants enum.
- [x] Step 9: 16pt body, 6pt line spacing, generous block (16)/section (28)/list
  (8) spacing; section headings `.title` bold, sub-headings `.largeTitle`/
  `.title`/`.title2`; How checklist text sized to body with accent checkmarks.

## Verification
- `swift test` targeted at `MarkdownBlockRendererTests` passes — every block
  type parses correctly and malformed input falls back to a paragraph.
- `swift build` succeeds.
- Opening a plan detail window shows lists as indented bulleted/numbered items,
  fenced code in a monospaced shaded box, blockquotes indented with a rule, and
  sub-headings emphasized — markedly more readable than the prior flat text.
- The `## How` section still renders as the read-only checkbox checklist.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/MarkdownBlockRenderer.swift` — NEW: pure block parser + `MarkdownBlock` enum.
- [ ] `Sources/Plans/PlanDetailView.swift` — render parsed blocks; switch `sectionView` to block rendering for non-How sections.
- [ ] `Tests/PlansTests/MarkdownBlockRendererTests.swift` — NEW: unit tests for the parser.

### Related Files (may need updates)
- `Sources/Plans/BrowserWindow.swift` — `BrowserViewModel.paragraphs` / `howSteps` are reused, not changed.

### UI Affected
- Plan detail window (Surface B) — section bodies render with block-level fidelity.

## Assumptions

### Initial (from elaboration)
- [low] Supported block subset: paragraphs, bullet lists (`-`/`*`), numbered lists (`1.`), fenced code blocks (```` ``` ````), blockquotes (`>`), and `###`+ sub-headings. **Why:** these are the constructs that actually appear in plan files; full CommonMark/GFM (tables, nested lists, images) is out of scope to avoid a parser rabbit hole.
- [low] Build a hand-rolled block parser rather than adding a dependency. **Why:** project mandates no external package dependencies (CONTEXT.md); SwiftUI native `AttributedString(markdown:)` is inline-only so block structure must be parsed manually.
- [high] Keep the `## How` section on its existing read-only `howChecklist` rendering, not the new block renderer. **Why:** the checklist rendering already works well and is special-cased; re-parsing it as generic blocks would lose the checkbox UI.
- [low] Restrained styling (monospace + subtle background for code, indentation for lists, left rule for quotes). **Why:** the task asks for "very readable"; over-decoration would add noise. No specific visual spec was given.
- [high] New parser is a pure static function with its own unit test file, mirroring existing pure-helper test patterns (`PlanDetailViewTests`, `TaskParserTests`). **Why:** repo convention is TDD with pure, testable helpers split from view code.

### Discovered during execution
- [low] Unclosed fenced code block falls back to a `.codeBlock` of the remaining lines (not a paragraph). **Why:** the opening fence is an explicit author intent to render code; preserving that intent and never dropping content is safer than reinterpreting it as prose. Tested in `testUnclosedFencedCodeBlockFallsBackGracefully`.
- [low] Heading fonts per level: level 1 → `.title3.bold()`, level 2 → `.headline`, level 3+ → `.subheadline.bold()`. **Why:** section headings already use `.headline`, so sub-headings within a body should read as smaller/subordinate; this keeps a clear visual hierarchy without competing with the section title.
- [low] Bullet marker is `Text("•")` and numbered marker is `Text("N.")` with `.monospacedDigit()`, each row indented `.padding(.leading, 4)`. **Why:** restrained, conventional list affordance; monospaced digits keep numbered markers aligned.
- [high] Bullet/numbered lists coalesce only same-kind consecutive lines; a switch between kinds (or to a paragraph/quote) without a blank line flushes the current block. **Why:** matches markdown semantics and keeps `- a` / `1. b` as two distinct blocks (tested).
- [high] Removed the now-unused `markdownBody(_:)` helper from `PlanDetailView` after switching `sectionView` to `markdownBlockView`. **Why:** grep confirmed it had no other references; avoids dead code.

## Changes
- Added `Sources/Plans/MarkdownBlockRenderer.swift`: a pure, dependency-free
  block parser. `enum MarkdownBlock: Equatable` (`.paragraph`, `.bulletList`,
  `.numberedList`, `.codeBlock`, `.blockquote`, `.heading(level:text:)`) and
  `MarkdownBlockRenderer.parse(_:)`. Handles fenced code (verbatim, unclosed →
  code block), `#`-headings, `-`/`*` bullets, `N.` numbered lists, `>`
  blockquotes, blank-line block separation, and tolerates leading whitespace.
  Never crashes.
- Added `Tests/PlansTests/MarkdownBlockRendererTests.swift`: 19 unit tests
  (written test-first) — all block types, mixed/interleaved content, kind-switch
  flushing, leading-whitespace tolerance, and the unclosed-fence fallback.
- Modified `Sources/Plans/PlanDetailView.swift`: added `markdownBlockView(_:)`,
  `renderBlock(_:)`, and `headingFont(forLevel:)`; switched `sectionView(_:)` to
  block rendering for all non-`How` sections (the `## How` checklist is
  unchanged). Removed the now-unused `markdownBody(_:)` helper (no other refs).
- `swift test --filter MarkdownBlockRendererTests`: 19/19 pass.
  `swift build`: succeeds.

### Fidelity + editorial pass (review follow-up)
- `MarkdownBlockRenderer.codeBlock` now carries a `language:` hint (parsed from
  the fence info string); parser tests updated.
- Added `Sources/Plans/CodeHighlighter.swift`: pure, dependency-free syntax
  lexer with a varied `CodeTheme` (keywords pink, strings green, numbers orange,
  comments gray, types teal, function calls blue). Languages: Swift, JS/TS, JSON,
  shell, generic fallback. 20 unit tests in `CodeHighlighterTests.swift`.
- `PlanDetailView`: depth-tinted headings, tinted blockquote panel with accent
  rule, bordered code surface rendering the highlighted string, accent inline-code
  chips. Editorial typography centralized in a `PlanType` enum (16pt body, 6pt
  line spacing, larger headings, body-sized How checklist with accent checkmarks).
- `swift test --filter "MarkdownBlockRendererTests|CodeHighlighterTests|PlanDetailViewTests"`:
  46/46 pass. `swift build` + `./build.sh`: succeed. User visually confirmed.
- Note: 4 pre-existing `PlansStoreTests` failures (project-name casing) are
  unrelated to this task — present on the branch base before these changes.

## Notes
Research confirmed `Task.sections[].body` holds verbatim section text (newlines
intact) — ideal input for block parsing. `BrowserViewModel.paragraphs` and
`howSteps` are reusable helpers and should not be modified.
