# Add Buttons To Show Plan In Finder And Open In Default Markdown App

**ID:** 030
**Created:** 2026-06-06T00:00
**Type:** feature
**Status:** completed
**Completed:** 2026-06-06T00:00
**Branch:** feature/030-add-buttons-show-in-finder-open-markdown

## What
Within plan detail view, add buttons to…
- Show plan in finder
- Open plan in default markdown app

## Why
Adds value by giving the user a fast path from the read-only plan detail window to
the underlying `.plans/…/NNN-slug.md` file on disk — revealing it in Finder or
opening it in their default markdown editor — without hand-navigating the
filesystem. Both actions are non-mutating, consistent with the detail view's
read-only contract (§2).

## How
- [x] Step 1: Add a pure, unit-testable static helper `taskFileURL(projectPath:taskID:isCompletedDir:)` to `Sources/Plans/PlanDetailView.swift` that resolves the on-disk markdown file by scanning `<projectPath>/.plans/<pending|completed>/` for the first `.md` file whose name begins with `<taskID>-`, returning a `URL?` (nil when not found). The slug is not stored on the `Task` model, so it is reconstructed from the filesystem.
- [x] Step 2: Write XCTest coverage in `Tests/PlansTests/PlanDetailViewTests.swift` (new file) for the helper: a pending-dir file resolves, a completed-dir file resolves, a missing file returns nil, and a non-matching id returns nil — using the project's UUID-named per-test temp-directory fixture pattern.
- [x] Step 3: Add two buttons to the detail header action `HStack` in `PlanDetailView.detailHeader(_:)`: "Show in Finder" (`systemImage: "folder"`) calling `NSWorkspace.shared.activateFileViewerSelecting([url])`, and "Open in Markdown App" (`systemImage: "doc.text"`) calling `NSWorkspace.shared.open(url)`. Both resolve the URL via the Step 1 helper and no-op safely when it returns nil. Buttons are always shown (independent of status / running state) since they are read-only.
- [x] Step 4: Build (`swift build`) and run the targeted tests (`swift test --filter PlanDetailViewTests`) to confirm the helper and the build pass.

## Verification
- `swift build` succeeds.
- `swift test --filter PlanDetailViewTests` passes (helper resolves pending/completed files, returns nil for missing/non-matching).
- In the running app, the plan detail window shows "Show in Finder" and "Open in Markdown App" buttons; clicking the first reveals the correct `.md` file selected in Finder, and the second opens it in the default markdown app.

## Impact Scope
_Fewer than 3 files affected — section omitted._

## Assumptions

### Initial (from elaboration)
- [high] Reconstruct the file path by scanning `.plans/<pending|completed>/` for `<id>-*.md` rather than adding a `filename`/`fileURL` field to the `Task` model. **Why:** The `Task` model (TaskParser.swift) carries `id` and `isCompletedDir` but not the slug; the directory layout `<projectPath>/.plans/<dir>/<id>-slug.md` is authoritative and already used by the parser, so a filesystem scan is the lowest-risk, model-free path.
- [high] Use `NSWorkspace.shared.activateFileViewerSelecting(_:)` for "Show in Finder" and `NSWorkspace.shared.open(_:)` for "Open in default app". **Why:** Standard AppKit APIs; the codebase already uses AppKit interop (e.g. ProjectLinking.swift) and has no external deps.
- [low] Place both buttons in the existing detail-header action `HStack` and show them always, regardless of task status or whether a run is in progress. **Why:** The actions are read-only and useful in every state; the source description did not specify placement or gating, and the header is the existing home for plan actions (Elaborate/Execute).
- [low] Chosen SF Symbols `folder` and `doc.text`, and button label "Open in Markdown App". **Why:** UX wording/icons were unspecified; these match the action semantics and the Label-with-systemImage style already used by the header buttons.
- [low] Buttons silently no-op when the file URL can't be resolved (deleted/renamed file), rather than disabling or showing an error. **Why:** Matches the detail view's tolerant, read-only philosophy; error-toast infrastructure does not exist and would be out of scope.

### Discovered during execution
- [high] Placed the two read-only buttons in their own unconditional block within the action `HStack`, after (outside) the `if runner.isRunning … else …` status-gated branch, so they render in every state — including while a run is in progress (when the gated branch shows only the spinner + "Show progress"). **Why:** The segment required the buttons to be always visible; nesting them inside either arm of the conditional would hide them in some state.
- [low] The helper matches `url.pathExtension == "md"` plus a `lastPathComponent.hasPrefix("<id>-")` check (rather than a single string match). **Why:** Cleanly excludes non-markdown files and same-prefix-but-different-extension entries while keeping the "first match wins" semantics specified.

## Changes
- `Sources/Plans/PlanDetailView.swift`:
  - Added `import AppKit`.
  - Added static helper `taskFileURL(projectPath:taskID:isCompletedDir:) -> URL?` that scans `<projectPath>/.plans/<pending|completed>/` for the first `.md` whose name begins with `<taskID>-`, returning nil on error/no-match.
  - Added two always-visible buttons to the detail-header action `HStack` (outside the status/running-gated branch): "Show in Finder" (`folder` → `NSWorkspace.shared.activateFileViewerSelecting`) and "Open in Markdown App" (`doc.text` → `NSWorkspace.shared.open`). Both no-op safely when the helper returns nil.
- `Tests/PlansTests/PlanDetailViewTests.swift` (new): 4 XCTest cases for `taskFileURL` (pending resolves, completed resolves, nil on no match, nil on differing id prefix) using the UUID-named temp-dir fixture pattern.

Tests: `swift test --filter PlanDetailViewTests` → 4 passed, 0 failures. `swift build` succeeds (one pre-existing unrelated Sendable warning in `PlansStore.swift`, not from this change).

## Notes
Research confirmed: `PlanDetailView` resolves its `TaskRow` (with `projectPath` and
`task`) via `BrowserViewModel.resolveRow`. `Task` exposes `id` and `isCompletedDir`
but not the filename slug. Detail-header action buttons live in the `HStack` around
lines 135–167 of PlanDetailView.swift.
