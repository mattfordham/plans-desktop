# Add Link Command To Manually Enter File Path

**ID:** 018
**Created:** 2026-06-05T00:00
**Type:** feature
**Status:** completed
**Branch:** feature/018-add-link-command-to-manually-enter-file-path
**Completed:** 2026-06-06T10:05

## What
Add a link command. So if for some reason the config is stale, we could manually enter a file path.

A "Link Project…" action that lets the user pick a project directory and register it with Plans.app directly, instead of waiting for a plans-cc action (`/plan-capture`, dashboard launch, etc.) to add it to the registry. This covers the case where the registry (`~/.claude/plans-cc/projects.json`) is stale or missing an entry for a project that exists on disk.

## Why
Adds value by giving the user a manual recovery path when the plans-cc registry is out of sync — letting them link an existing `.plans/`-bearing project on demand rather than being stuck until a plans-cc action re-registers it. Today there is no in-app way to make Plans.app aware of a project; this closes that gap.

## How
- [x] Add `RegistryWriter.swift` (new file, mirroring `RegistryReader`'s injectable `registryURL` + `FileManager` shape): load the existing registry (tolerant — missing/corrupt → empty `version: 1` registry), upsert a project by `path` (update `lastSeen` if the path already exists, else append), and write `projects.json` back atomically with `JSONEncoder` (pretty-printed, matching the `{ "version": 1, "projects": [{ "path", "lastSeen" }] }` schema and ISO-8601-with-milliseconds UTC `lastSeen`).
- [x] Add a `linkProject(at:)` (or similar) method to `PlansStore` that: validates `<path>/.plans/` exists (reject otherwise), calls `RegistryWriter` to upsert the path with a current `lastSeen`, then triggers `reload()` so the linked project appears immediately. Surface a validation error back to the UI when `.plans/` is absent.
- [x] Add a "Link Project…" button to the menu bar drop-down (`MenuBarView.swift`), next to "Open Browser" / "Quit". On tap, present an `NSOpenPanel` configured for directory selection (`canChooseDirectories = true`, `canChooseFiles = false`), then call `store.linkProject(at:)` with the chosen path.
- [x] Add an equivalent "Link Project…" / "Add Project" affordance to the browser window (`BrowserWindow.swift`) — a `.toolbar` button or a header button on the card grid — wired to the same `NSOpenPanel` → `store.linkProject(at:)` flow (factor the panel + link logic so it is shared, not duplicated).
- [x] Surface the "no `.plans/` here" rejection to the user (e.g. an alert or inline message) so a path without a `.plans/` directory gives clear feedback rather than silently doing nothing.

## Verification
Verify the new functionality works as expected; tests pass.
- Pick a project directory that has a `.plans/` but is NOT in the registry → it gets written to `projects.json` and appears in both the menu bar glance and the browser grid after the next reload.
- Pick a directory WITHOUT a `.plans/` → the link is rejected with a clear error and nothing is written to the registry.
- Linking a path already in the registry updates its `lastSeen` without creating a duplicate entry.
- `swift test` passes, including new `RegistryWriterTests` covering create/upsert/dedup and atomic-write behavior against temp-dir fixtures.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/PlansStore.swift` — add `linkProject(at:)` that validates `.plans/`, writes via `RegistryWriter`, and reloads.
- [x] `Sources/Plans/MenuBarView.swift` — add the "Link Project…" button + `NSOpenPanel` flow.
- [x] `Sources/Plans/BrowserWindow.swift` — add the matching toolbar/header link affordance.

### Files to Create
- [x] `Sources/Plans/RegistryWriter.swift` — registry writer (inverse of `RegistryReader`).
- [x] `Tests/PlansTests/RegistryWriterTests.swift` — create/upsert/dedup/atomic-write tests (temp-dir fixtures, injectable `registryURL`).

### Related Files (may need updates)
- `Tests/PlansTests/PlansStoreTests.swift` — add coverage for `linkProject(at:)` (valid path writes + reloads; missing `.plans/` rejected).
- `Sources/Plans/RegistryReader.swift` — reference for the `Registry`/`RegistryProject` Codable shapes the writer reuses (no change expected, but the writer should share these types).

### Endpoints/UI Affected
- Menu bar drop-down — gains a "Link Project…" button.
- Browser window — gains a link/add-project affordance in its toolbar/header.

## Assumptions

### Initial (from elaboration)
_To be filled during elaboration_

### Discovered during execution
- [high] `RegistryWriter` mirrors `RegistryReader`'s injectable `registryURL`/`fileManager` init shape and reuses the shared `Registry`/`RegistryProject` Codable types. **Why:** Direct codebase precedent; the task explicitly required reusing the types.
- [low] `upsertProject(path:now:)` takes an injectable `now: Date = Date()` parameter. **Why:** Lets tests assert `lastSeen` shape/update deterministically; not specified by the task, but a clean testability seam with no production cost.
- [low] The ISO-8601 formatter is built fresh per call via a static factory (`makeLastSeenFormatter()`) instead of a cached static `let`. **Why:** Swift 6 strict concurrency rejects a non-`Sendable` `ISO8601DateFormatter` as a shared static; registry writes are rare so the allocation is negligible.
- [high] Atomic write uses `Data.write(to:options:.atomic)` (writes a temp file then renames into place) rather than a hand-rolled temp-file + `replaceItemAt`. **Why:** Foundation's `.atomic` is the idiomatic, correct atomic-replace; simpler and less error-prone than a manual move.
- [low] `linkProject(at:)` is `throws` with a nested `enum LinkError: Error, Equatable { case missingPlansDirectory }` rather than a published error property or `Result`. **Why:** The store had no prior error-surfacing precedent (`reload()` is non-throwing/tolerant); throwing keeps the store free of UI-presentation state and lets the call site (a button handler, not a reactive view) present an alert. Equatable for clean test assertions.
- [high] `linkProject(at:)` validates `<path>/.plans/` with `FileManager.fileExists`, matching `RegistryReader.readProjects()`' existence check, and passes `path` verbatim (no canonicalization). **Why:** Consistency with the reader's contract, confirmed in the task notes.
- [low] Added a `registryWriter: RegistryWriter` injection to `PlansStore.init` (defaulting to `RegistryWriter()`). **Why:** The store previously injected only the reader; tests need reader+writer pointed at the same temp `projects.json`, so extending the existing injection pattern was the natural fit.
- [low] Menu bar wiring lives in two file-scope `@MainActor` helpers (`presentProjectDirectoryPanel()` returning `URL?`, and a private `presentLinkError`) rather than inline in the button closure. **Why:** The next segment will share the panel flow with BrowserWindow; a standalone function is trivial to lift, while keeping it out of the `View` body. Low confidence on exact factoring since the shared-helper home is decided next segment.
- [low] The no-`.plans/` rejection is surfaced via a modal `NSAlert`. **Why:** The task left the exact mechanism open ("alert or inline message"); a modal alert fits an `NSOpenPanel`-driven AppKit flow and the menu bar panel (which has no persistent surface for inline messaging).
- [low] The open panel calls `NSApp.activate(ignoringOtherApps:)` before `runModal()`. **Why:** The menu bar drop-down is not a key window, so without activation the panel can open behind other apps. Not specified by the task; a defensive UX call.
- [high] (seg 2) The shared link flow lives in a new dedicated file `Sources/Plans/ProjectLinking.swift` as file-scope `@MainActor` helpers, with a single entry point `linkProjectWithUserPrompt(using: PlansStore)` that owns pick → link → alert. `presentProjectDirectoryPanel()` and `presentLinkError(_:informativeText:)` were lifted verbatim from MenuBarView into it (now file-scope, non-private so both surfaces can reach the entry point). MenuBarView's local copies were removed and its button now calls the shared helper. **Why:** The task explicitly required ONE implementation called from both views; a dedicated file is the cleanest neutral home (neither view "owns" it) and matches the codebase's one-concern-per-file convention.
- [low] (seg 2) The browser-window affordance is a `.toolbar { ToolbarItem { ... } }` button using `Label("Link Project…", systemImage: "plus")` with a `.help(...)` tooltip. **Why:** The task suggested a toolbar button as the natural window fit; `plus` is the conventional macOS add-affordance glyph. The task left the exact glyph/placement open — toolbar trailing default placement chosen.
- [high] (seg 2) The no-`.plans/` rejection alert is now emitted from the shared helper, so the browser flow inherits the IDENTICAL alert as the menu bar flow (and any other error falls through to a localized-description alert). The shared alert message now interpolates the chosen path ("No “.plans” directory found at <path>. Pick a project folder that contains a “.plans” directory.") for clearer feedback. **Why:** Step 5 required the browser path to surface the same clear rejection; centralizing it in the helper guarantees parity with no second alert implementation.

## Changes

**Segment 1 (steps 1–3):**
- Added `Sources/Plans/RegistryWriter.swift` — tolerant load, upsert-by-`path`, atomic write (`Data.write(.atomic)`), ISO-8601-ms UTC `lastSeen`; reuses `Registry`/`RegistryProject` from `RegistryReader`.
- Added `Tests/PlansTests/RegistryWriterTests.swift` — 7 tests (create / upsert-updates-lastSeen / no-duplicate / atomic-write validity). All passing.
- Modified `Sources/Plans/PlansStore.swift` — added `linkProject(at:) throws`, validates `<path>/.plans/`, upserts via injected `RegistryWriter`, then `reload()`; nested `enum LinkError: Error, Equatable { case missingPlansDirectory }`; added `registryWriter` injection to `init`.
- Modified `Tests/PlansTests/PlansStoreTests.swift` — 2 new tests (valid path writes + appears after reload; missing `.plans/` rejected, nothing written). 14 store tests passing.
- Modified `Sources/Plans/MenuBarView.swift` — added "Link Project…" button with directory-only `NSOpenPanel`; panel + error logic in file-scope `@MainActor` helpers (`presentProjectDirectoryPanel`, `presentLinkError`) for reuse in segment 2.

**Segment 2 (steps 4–5):**
- Created `Sources/Plans/ProjectLinking.swift` — single shared `@MainActor` flow: `linkProjectWithUserPrompt(using:)` (pick → link → alert), plus `presentProjectDirectoryPanel()` and `presentLinkError(...)` lifted from MenuBarView. One implementation, called from both surfaces.
- Modified `Sources/Plans/MenuBarView.swift` — removed its local link method + helpers; "Link Project…" button now calls the shared `linkProjectWithUserPrompt(using: store)`.
- Modified `Sources/Plans/BrowserWindow.swift` — added a `.toolbar` "Link Project…" button (`plus` glyph) wired to the same shared helper via the existing `@Environment(PlansStore.self)` store.
- Rejection feedback (no `.plans/`) now lives in the shared helper's catch, so both surfaces present the identical alert: "No \".plans\" directory found at <path>…".

## Notes
**Design decisions confirmed with user during elaboration:**
- **UI placement:** Both the menu bar drop-down AND the browser window (factor the link logic so it is shared).
- **Path entry:** Native `NSOpenPanel` directory picker (no free-text field).
- **Persistence:** Write directly to the plans-cc registry (`~/.claude/plans-cc/projects.json`). This is a deliberate, scoped exception to the app's otherwise strict read-only constraint (spec §2) — the "link" action is the one place Plans.app writes the registry. Because the entry becomes a real registry entry, it self-heals and dedupes naturally (no separate UserDefaults override list needed).
- **Validation:** Reject paths that have no `.plans/` directory, with a clear error to the user.

**Registry schema (confirmed from live `projects.json` + `RegistryReader`):**
```json
{ "version": 1, "projects": [ { "path": "/abs/path", "lastSeen": "2026-06-05T17:18:30.904Z" } ] }
```
`lastSeen` is ISO-8601 UTC with milliseconds. Upsert by `path` (verbatim, no canonicalization — matching `RegistryReader`, which passes paths through without canonicalizing).
