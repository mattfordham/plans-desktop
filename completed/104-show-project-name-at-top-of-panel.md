# Show Project Name At Top Of Panel When A Project Is Selected

**ID:** 104
**Created:** 2026-11-07T00:00
**Type:** feature
**Status:** completed
**Completed:** 2026-11-07T00:00
**Branch:** feature/104-show-project-name-at-top-of-panel

## What
When Project is selected, show project name at top of panel (instead of "Plans")

## Why
Adds value by orienting the user: when they drill into a single project, the browser window's titlebar currently always reads the literal "Plans", giving no indication of which project they're looking at. Showing the selected project's name makes the context obvious at a glance.

## How Summary
The browser window title is the SwiftUI `Window("Plans", …)` scene title in `PlansApp.swift` — there is no `navigationTitle` anywhere in the app. Add a pure, testable `BrowserViewModel.windowTitle(for:in:)` helper that returns the selected project's already-titleized `projectName` when the resolved sidebar selection is a single `.project`, and `"Plans"` for every other selection (all-projects card stack, smart views). Apply it via `.navigationTitle(...)` on `BrowserWindow`'s outer `NavigationSplitView`, which overrides the scene title.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — add the `windowTitle(for:in:)` helper to `BrowserViewModel` and a `.navigationTitle(...)` on the `NavigationSplitView`.
- `Sources/Plans/PlansStore.swift` — holds `browserSelection` (the persisted `SidebarSelection`); read only.
- `Sources/Plans/TaskParser.swift` — `ProjectTasks.projectName` (already `titleized()`) is the display name used in the title.
- `Tests/PlansTests/BrowserWindowTests.swift` — unit tests for the new pure helper.

## How
- [x] Step 1: Add a failing XCTest in `Tests/PlansTests/BrowserWindowTests.swift` for a new pure static helper `BrowserViewModel.windowTitle(for:in:)`: it returns a selected project's `projectName` for `.project(path)` when that path is live, `"Plans"` for `.allProjects`, `"Plans"` for `.smart(...)`, and `"Plans"` for a `.project(path)` whose path is NOT among the live projects (stale selection falls back).
- [x] Step 2: Implement `static func windowTitle(for selection: SidebarSelection, in projects: [ProjectTasks]) -> String` on `BrowserViewModel` in `Sources/Plans/BrowserWindow.swift`, reusing `BrowserViewModel.resolve(_:in:)` so a stale `.project` path resolves to `.allProjects` → `"Plans"`, and looking up `projectName` via `projects.first { $0.projectPath == path }?.projectName`.
- [x] Step 3: Apply `.navigationTitle(BrowserViewModel.windowTitle(for: store.browserSelection, in: store.projects))` on the outer `NavigationSplitView` in `BrowserWindow` (after the closing brace at line ~106, alongside the existing `.frame(...)` modifier) so the titlebar reflects the selection.
- [x] Step 4: Run the targeted test (`swift test --filter BrowserWindowTests`) to confirm the new helper tests pass; verify `swift build` succeeds.

## Verification
- `swift test --filter BrowserWindowTests` passes, including the new `windowTitle(for:in:)` cases.
- `swift build` succeeds with no new warnings.
- When a single project is selected in the sidebar, the browser window titlebar shows that project's name; selecting "All projects" or a smart view shows "Plans".

## Impact Scope
Fewer than 3 files are substantively modified (BrowserWindow.swift + its test; PlansStore/TaskParser are read-only references), so no formal Impact Scope breakdown is needed.

## Assumptions

### Initial (from elaboration)
- [low] Only the single-project selection retitles the window; `.allProjects` and `.smart(...)` keep the literal "Plans". **Why:** The task scope is strictly "when Project is selected"; the research Open Questions flagged smart-view/all-projects titling as out of scope, so defaulting them to "Plans" avoids scope creep.
- [low] `.allProjects` keeps the literal "Plans" rather than becoming "All Projects". **Why:** The task only specifies the single-project behavior; changing the all-projects label is a separate UX decision not requested here.
- [high] Implement the title as a pure `BrowserViewModel.windowTitle(for:in:)` helper plus a single `.navigationTitle` on the outer `NavigationSplitView`, rather than per-column titles or a new stored property. **Why:** Mirrors the existing `BrowserViewModel.resolve(_:in:)` pure-helper pattern (testable, no SwiftUI/I-O), and a single outer `navigationTitle` is the standard SwiftUI way to drive the window titlebar; per-column titles compete and a stored property would duplicate selection state.

### Discovered during execution
- none

## Changes
- Added `BrowserViewModel.windowTitle(for:in:)` to `Sources/Plans/BrowserWindow.swift` (~line 1277): a pure static helper that resolves the sidebar selection via the existing `resolve(_:in:)` and returns the live project's titleized `projectName` for a `.project` selection, or `"Plans"` for `.allProjects`, `.smart(...)`, and stale `.project` paths. Reusing `resolve` means a stale selection falls back to `"Plans"` with no extra logic.
- Applied `.navigationTitle(BrowserViewModel.windowTitle(for: store.browserSelection, in: store.projects))` on `BrowserWindow`'s outer `NavigationSplitView` (line ~114, alongside the existing `.frame(minWidth:...)`). This overrides the `Window("Plans", …)` scene title from `PlansApp.swift`, so the titlebar shows the selected project's name when a single project is selected and "Plans" otherwise.
- Added 4 XCTests to `Tests/PlansTests/BrowserWindowTests.swift` covering live project → name, `.allProjects` → "Plans", `.smart(.inProgress)` → "Plans", and stale `.project("/gone")` → "Plans".
- Verification: `swift test --filter BrowserWindowTests` → 130 tests, 0 failures (incl. 4 new). `swift build` succeeds. Diff: 2 files, 48 insertions, no deletions.

## Notes
The "Plans" title is the `Window("Plans", id: "browser")` scene title in `PlansApp.swift:126` — not a `navigationTitle` (there are none in the codebase). A `.navigationTitle` on the `NavigationSplitView` overrides the scene title. `ProjectTasks.projectName` is already titleized at parse time (`TaskParser.swift:649`), so no extra titleization is required.
