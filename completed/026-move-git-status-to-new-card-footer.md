# Move Git Status To New Card Footer

**ID:** 026
**Created:** 2026-06-06T15:15
**Type:** refactor
**Status:** completed
**Branch:** refactor/026-move-git-status-to-new-card-footer
**Completed:** 2026-06-06T16:08

## What
Move Git status to new card footer… which should mirror the header's treatment with a top border.

## Why
Improves maintainability and visual structure of the project card. The git
indicator (#024) currently lives inline in the header HStack, where the branch
name competes for horizontal space with the project name and the per-status
count badges (forcing middle-truncation). Relocating it to a dedicated footer
gives git status its own row, declutters the header, and gives the card a
clear three-part structure (header / body / footer) with consistent border
treatment top and bottom.

## How
- [x] Step 1: In `Sources/Plans/ProjectCard.swift`, remove the git indicator block (currently lines ~139–160, the `if let branch = project.gitBranch { HStack { … } }`) from the `header` computed property. The header should then contain only: project name, `captureControl`, `Spacer(minLength: 8)`, and the per-status count badges. *(Note: the worktree's header had NO `captureControl`; only the git block was removed.)*
- [x] Step 2: Add a new private `gitFooter` view (computed property or `@ViewBuilder` func) in `ProjectCard.swift` that renders the same git block — branch glyph (`arrow.triangle.branch`, `.small`, `.secondary`), branch name (`.caption`, `.secondary`, middle-truncated), and the orange dirty dot when `gitIsDirty == true` — wrapped so it only appears when `project.gitBranch != nil`. Mirror the existing header git markup verbatim. Add a doc comment in the same style as the `header` comment.
- [x] Step 3: Insert the footer into the card's `body` VStack so it mirrors the header's treatment: after `body(for: rows)` and before the trailing `Spacer(minLength: 0)`, add `Divider()` then the `gitFooter`. The header is preceded by nothing and *followed* by a `Divider()`; the footer is *preceded* by a `Divider()` (its top border) — mirroring the header/body separator. Guard the divider+footer so a non-git project (no `gitBranch`) renders neither an empty footer nor a dangling divider.
- [x] Step 4: Build (`swift build`) and run the targeted test file added below (`ProjectCardTests`) to confirm everything compiles and the footer-rendering logic holds. Adjust VStack spacing/padding only if the footer visibly floats; otherwise leave the existing 10pt spacing and asymmetric padding untouched.

## Verification
- `swift build` succeeds with no warnings introduced by the change.
- The git branch/dirty indicator no longer appears in the header row; it appears in a footer at the bottom of the card, separated from the body by a top border (Divider) that mirrors the header→body Divider.
- A project that is not a git repo (`gitBranch == nil`) shows no footer and no dangling divider.
- `swift test --filter ProjectCardTests` passes (targeted tests for the new footer logic).

## Impact Scope
_Single file (`Sources/Plans/ProjectCard.swift`) plus a new targeted test file; under the 3-file threshold, so no detailed scope table._

## Assumptions

### Initial (from elaboration)
- [high] Mirror the git markup verbatim into the footer rather than abbreviating it. **Why:** Task says "move git status," implying the same content; the header block (branch glyph + name + dirty dot) is self-contained and moves cleanly.
- [high] "Mirror the header's treatment with a top border" means a bare `Divider()` above the footer, matching the existing bare `Divider()` that separates header from body (line 96). **Why:** The card has no custom border styling — the header/body separator is a plain `Divider()`, so mirroring it for the footer means another plain `Divider()`.
- [low] Keep the footer visible even when the card has no plans ("No outstanding plans" body). **Why:** The task doesn't call for special empty-state handling; simplest consistent behavior is to always show the footer for git repos.
- [low] Do not change VStack spacing or card padding unless the footer visibly floats. **Why:** The existing 10pt spacing + asymmetric padding is carefully tuned (see comments in `body`); leaving it avoids regressing the tuned layout. A test suite exists, so add a targeted test for the footer logic per repo TDD convention.

### Discovered during execution
- [high] Used the `ProjectTasks` memberwise initializer with the git fields explicit: `ProjectTasks(projectPath:projectName:lastSeen:tasks:counts:activeTasks:gitBranch:gitIsDirty:)`. **Why:** This is the public init in `TaskParser.swift` (`gitBranch`/`gitIsDirty` default to `nil`); the test passes them explicitly to exercise repo/dirty states, mirroring `BrowserWindowTests.makeProject`.
- [high] Made `gitFooter` `@ViewBuilder`. **Why:** It contains a bare `if let` without an `else`, which only type-checks as a view under `@ViewBuilder` — matching how the body's other conditional views are built.
- [high] Guarded the footer with `if project.gitBranch != nil { Divider(); gitFooter }` directly in the body VStack rather than putting the guard only inside `gitFooter`. **Why:** Putting the guard in the VStack prevents a dangling `Divider()` for non-git projects (the footer alone being empty would still leave the divider visible).
- [high] Left VStack `spacing: 10` and the asymmetric padding (.top 14 / .horizontal 14 / .bottom 9) unchanged. **Why:** Built cleanly; no visible floating expected and the layout comments warn the values are tuned. Did not change worktree's header had NO `captureControl` (contrary to the original How text), so only the git block was removed.
- [low] The test asserts data-layer invariants (gitBranch nil vs set; gitIsDirty true/false/nil) rather than rendered SwiftUI output. **Why:** `ProjectCard` is a view whose rendered tree is impractical to assert on in XCTest; the footer's visibility/dirty-dot logic is fully driven by these `ProjectTasks` fields.

## Changes
- `Sources/Plans/ProjectCard.swift`:
  - Removed the `// Git indicator (#024)` block from the `header` HStack. The
    header now holds only the project name, `Spacer(minLength: 8)`, and the
    per-status count `ForEach`.
  - Added a new `// MARK: - Footer (git status)` section with a
    `@ViewBuilder private var gitFooter` that renders the git block verbatim
    (branch glyph + name, orange dirty dot when `gitIsDirty == true`), wrapped
    in `if let branch = project.gitBranch`.
  - Inserted `if project.gitBranch != nil { Divider(); gitFooter }` into the
    card `body` VStack after `body(for: rows)` and before the trailing
    `Spacer(minLength: 0)`. The leading `Divider()` is the footer's top border,
    mirroring the header→body `Divider()`. The guard prevents a dangling
    divider for non-git projects. VStack `spacing: 10` and the asymmetric
    padding (.top 14 / .horizontal 14 / .bottom 9) left unchanged.
- `Tests/PlansTests/ProjectCardTests.swift` (new): 5 targeted tests asserting
  the `ProjectTasks` git fields the footer depends on (gitBranch nil vs set;
  gitIsDirty true/false/nil), built via the memberwise initializer mirroring
  `BrowserWindowTests.makeProject`.

**Tests:** `swift build` succeeds (only a pre-existing unrelated `PlansStore`
Sendable warning; no new warnings). `swift test --filter ProjectCardTests` —
5 tests, 0 failures.

## Notes
Builds on #024 (git branch + status in project cards). Relevant code is entirely
within `Sources/Plans/ProjectCard.swift`. No `ProjectCard`-specific tests existed
before this task; git data fields live on `ProjectTasks` (`gitBranch: String?`,
`gitIsDirty: Bool?`) in `TaskParser.swift`.
