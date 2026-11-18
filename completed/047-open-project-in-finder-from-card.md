# Open Project In Finder When Clicking Project Name In Project Card

**ID:** 047
**Created:** 2026-06-12T19:39
**Type:** feature
**Status:** completed
**Branch:** feature/047-open-project-in-finder-from-card
**Completed:** 2026-06-14T09:48

## What
When clicking project name in project card, open in finder

## Why
Adds value by enabling quick access to a project's files directly from the
browser window — clicking a project card's name reveals that project's root
directory in macOS Finder, removing the friction of manually navigating there.

## How
- [x] Step 1: Add a testable static helper `finderURL(for projectPath: String) -> URL` to `ProjectCard` (mirroring `PlanDetailView.taskFileURL`), returning `URL(fileURLWithPath:)` for the project root. Write an XCTest in `Tests/PlansTests/ProjectCardTests.swift` first (TDD) asserting it builds a file URL for the project path.
- [x] Step 2: Add `import AppKit` to `ProjectCard.swift` and wrap the project-name `Text(project.projectName)` (line ~212, in `header`) with `.contentShape(Rectangle())` + `.onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([Self.finderURL(for: project.projectPath)]) }`, mirroring the `NSWorkspace` pattern in `PlanDetailView.swift`.
- [x] Step 3: Add a `.help("Open project in Finder")` affordance to the project-name Text and update the header doc-comment (lines ~208–209 and ~22–23) so it no longer states the header/project is not a tap target.
- [x] Step 4: Run the targeted test file (`swift test --filter ProjectCardTests`) and confirm it passes.

## Verification
Verify the new functionality works as expected; tests pass. Clicking a project
name in a project card opens that project's root directory in Finder.
`swift test --filter ProjectCardTests` passes.

## Impact Scope
_Fewer than 3 files affected — section omitted._

## Assumptions

### Initial (from elaboration)
- [low] Open the project ROOT in Finder via `NSWorkspace.activateFileViewerSelecting([rootURL])` (reveal/select the folder) rather than opening the folder window directly with `open`. **Why:** matches the existing "Show in Finder" pattern in `PlanDetailView.swift`; the description only says "open in finder" without specifying which behavior.
- [low] Extract a static `finderURL(for:)` helper and unit-test it instead of asserting on SwiftUI rendering. **Why:** the view's rendered output is impractical to assert against (per `ProjectCardTests` doc-comment); existing tests pin data-layer invariants, and `PlanDetailView.taskFileURL` is the codebase precedent for a testable static URL helper.
- [low] Skip a custom hover/underline affordance; rely on `.help()` tooltip only. **Why:** research flagged hover feedback as optional since the project name is already a prominent headline; keeping scope minimal avoids over-engineering.

### Discovered during execution
- [low] Placed the new `finderURL(for:)` static helper directly after `shouldScrollContent(...)` in `ProjectCard`, grouped with the other pure view-free helpers, rather than near the body/header. **Why:** keeps testable static seams co-located; matches how `shouldScrollContent` is organized.
- [low] Used `.help("Open project in Finder")` as the tooltip wording verbatim from the task; no hover/underline affordance added. **Why:** task Step 3 specified this exact behavior and the initial assumptions opted to skip custom hover feedback.

## Changes
- `Sources/Plans/ProjectCard.swift`:
  - Added `import AppKit`.
  - Added `static func finderURL(for projectPath: String) -> URL` returning `URL(fileURLWithPath:)` (placed beside `shouldScrollContent`).
  - Made the project-name `Text(project.projectName)` in `header` a tap target: `.contentShape(Rectangle())` + `.onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([Self.finderURL(for: project.projectPath)]) }`, plus `.help("Open project in Finder")`.
  - Updated the type-level and `header` doc-comments to reflect that the project name now reveals the project root in Finder on tap (previously documented as not a tap target).
- `Tests/PlansTests/ProjectCardTests.swift`:
  - Added `testFinderURLBuildsFileURLForProjectPath` (TDD) asserting `finderURL(for:)` builds a file URL (`isFileURL == true`, path round-trips).
- Test result: `swift test --filter ProjectCardTests` → 9 tests, 0 failures.

## Notes
_Additional context_
