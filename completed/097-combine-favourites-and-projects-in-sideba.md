# Combine Favourites And Projects In Sidebar

**ID:** 097
**Created:** 2026-11-07T15:04
**Type:** refactor
**Status:** completed
**Completed:** 2026-11-07T15:04
**Branch:** refactor/097-combine-favourites-and-projects-in-sideba

## What
When a project is starred/pinned, we can remove it from the list of projects in the sidebar. And the two lists could be combined together, I think.

## Why
Today a starred project appears twice in the browser sidebar — once in the "Favourites" section (as `star.fill`) and again in the "Projects" section (as `folder`) — because the Projects section is not filtered by starred state. Combining the two sections into a single list removes that duplication, makes the sidebar shorter and clearer, and keeps a starred project discoverable in one place while still visually distinguishing it with a star glyph.

## How Summary
Collapse the sidebar's separate "Favourites" and "Projects" sections into one "Projects" section that lists every project (starred and not) in the existing order, marking each row's icon `star.fill` when the project is starred and `folder` otherwise. The drag-reorder `.onMove` keeps operating over the full `sidebarProjects` list exactly as today (so no offset mismatch), and the now-unused `favouriteProjects` computed property and the conditional Favourites `Section` are removed. A small pure `BrowserViewModel` glyph helper is extracted so the starred/unstarred icon choice is unit-tested like the other view-model helpers.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — owns the sidebar `List`; the Favourites section (245-253), the `favouriteProjects` prop (284-286), and the Projects `ForEach` (260-278) are the change sites.
- `Sources/Plans/PlansStore.swift` — holds `starredProjectPaths: Set<String>`, the single source of truth for which projects are starred (read-only for this task).
- `Tests/PlansTests/BrowserWindowTests.swift` — where the pure glyph-helper test goes, mirroring the existing `sortByStaleness` / `applyManualOrder` helper tests.

## How
- [x] Step 1: Add a failing unit test in `Tests/PlansTests/BrowserWindowTests.swift` for a new pure helper `BrowserViewModel.sidebarGlyph(starred:)` (or equivalent), asserting it returns `"star.fill"` when `starred` is true and `"folder"` when false.
- [x] Step 2: Add the `BrowserViewModel.sidebarGlyph(starred:) -> String` pure helper in `Sources/Plans/BrowserWindow.swift` next to the other pure view-model helpers, making the test pass (green).
- [x] Step 3: In the `sidebar` computed property, merge the two lists: delete the conditional `Section("Favourites")` block (lines ~245-253) and change the `Section("Projects")` `ForEach(sidebarProjects)` so each row's `systemImage` is `BrowserViewModel.sidebarGlyph(starred: store.starredProjectPaths.contains(project.projectPath))`. Leave the `.onMove` handler operating over `sidebarProjects.map(\.projectPath)` unchanged (it still renders the full list, so offsets line up).
- [x] Step 4: Remove the now-unused `favouriteProjects` computed property (lines ~284-286) and update the `sidebar` doc comment to describe the single combined Projects section (no separate Favourites section).
- [x] Step 5: Run the targeted test file (`swift test` filtered to `BrowserWindowTests`) and `swift build` to confirm the helper test passes and the app compiles with no references to the removed `favouriteProjects`.

## Verification
- `swift build` succeeds with no unused-symbol or missing-reference errors (the removed `favouriteProjects` is not referenced anywhere else).
- The targeted `BrowserWindowTests` glyph-helper test passes.
- In the running app, the sidebar shows a single "Projects" section (no separate "Favourites" section); a starred project appears exactly once, marked with a filled star, and an unstarred project appears once with a folder icon.
- Drag-reorder in the Projects section still reorders projects and the "All Projects" card stack consistently.

## Impact Scope
_Not applicable — fewer than 3 files affected (BrowserWindow.swift + its test file)._

## Assumptions

### Initial (from elaboration)
- [low] Interpreted the task as doing BOTH asks: (a) remove the duplicate so a starred project no longer appears in both sections, and (b) fully combine Favourites + Projects into one list. **Why:** the description explicitly says "the two lists could be combined together," and the simplest way to satisfy both is a single merged list — the research flagged this as the recommended path.
- [low] ~~Chose to keep starred projects in their normal (recency/manual) position within the combined list and distinguish them only by the `star.fill` glyph, rather than floating them to the top. **Why:** the research warned that sorting favourites to the top fights the existing recency sort and makes `.onMove` reorder ambiguous; glyph-only distinction preserves the current reorder behavior with no correctness risk.~~ **Corrected in review:** the user wants starred projects pinned to the top, above all others.
- [low] Chose to extract a tiny pure `BrowserViewModel.sidebarGlyph(starred:)` helper and unit-test it rather than inlining the ternary in the view. **Why:** mirrors the codebase's established pattern of pure, unit-tested `BrowserViewModel` helpers (`sortByStaleness`, `applyManualOrder`, `moveOrder`), satisfying the project's TDD convention; the view-only Favourites logic had no direct test before.
- [high] No new store state or model is introduced; the change is a pure view-layer filter/glyph change reading existing `store.starredProjectPaths`. **Why:** research confirmed all needed data already exists and warned explicitly against adding a new store field or combined model.

### Discovered during execution
- [high] Removed the now-unused `favouriteProjects` computed property and updated the `sidebar` doc comment while merging the sections, even though this segment's prompt only listed steps 1-3. **Why:** the plan's How Summary and Step 4 both call for this removal; leaving the property would produce an unused-symbol and contradict the plan. Nothing else references it (verified by grep).

## Changes
- `Sources/Plans/BrowserWindow.swift`:
  - Added pure helper `static func sidebarGlyph(starred: Bool) -> String` on `BrowserViewModel` (returns `"star.fill"` when starred, else `"folder"`), placed next to the other pure helpers after `moveOrder`.
  - Merged the sidebar's two project lists into one: deleted the conditional `Section("Favourites")` block and changed the `Section("Projects")` `ForEach(sidebarProjects)` row icon to `BrowserViewModel.sidebarGlyph(starred: store.starredProjectPaths.contains(project.projectPath))`. The `.onMove` drag-reorder still operates over the full `sidebarProjects.map(\.projectPath)` list (unchanged).
  - Removed the now-unused `favouriteProjects` computed property and updated the `sidebar` doc comment to describe the single combined Projects section.
- `Tests/PlansTests/BrowserWindowTests.swift`:
  - Added `testSidebarGlyphReflectsStarredState` (new `// MARK: - sidebarGlyph` section) covering both branches of the glyph helper, written red-first per TDD.

- Review fix (user feedback: starred projects should sit above all others):
  - Added `BrowserViewModel.pinStarredFirst(_:starred:)`, a stable partition (starred first, each group keeping its recency/manual order); `sidebarProjects` now applies it, so `.onMove` offsets still match the displayed list.
  - Tests: `testPinStarredFirstFloatsStarredAboveOthersStably`, `testPinStarredFirstWithNoStarsIsIdentity`.

## Notes
Starring/unstarring itself (the toggle) lives in `ProjectCard.swift` and is out of scope — this task only changes how the sidebar renders the already-persisted starred state. A `.starred` `ProjectViewMode` case was deliberately removed in #096; do not resurrect it — favourites remain a sidebar-only concept.
