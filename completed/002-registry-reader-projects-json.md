# Registry reader for projects.json with tolerance & live-prune

**ID:** 002
**Created:** 2026-06-04T14:41
**Type:** feature
**Status:** completed
**Completed:** 2026-06-04T14:41
**Branch:** feature/002-registry-reader-projects-json
**Source:** Imported from desktop-app-spec.md

## What
Implement Data Contract 1. Read the machine-wide registry at `~/.claude/plans-cc/projects.json` (schema: `version`, `projects[]` with `path` + `lastSeen` ISO 8601). Treat unknown future versions defensively.

**Live-prune:** ignore/drop any entry whose `<path>/.plans/` directory does not exist; do not rewrite the registry (stay read-only).

**Tolerance:** handle missing / empty / corrupt files all as "zero known projects" — never throw or show a fatal dialog. Do not assume paths are canonicalized (duplicate paths pointing at the same dir may appear).

Spec reference: §4 (Data Contract 1 — The Registry).

## Why
Adds value by giving the app its source of truth for *which* projects exist — every downstream surface (menu bar glance, browser window, live-update) iterates over the project list this reader produces. The reader is also where all the read-only and crash-tolerance guarantees live: by mirroring plans-cc's own `lib/registry.js` (load → shape-check → drop-stale, all errors → empty), the rest of the app can assume it always gets a clean, non-stale `[RegistryProject]` and never has to handle a bad registry.

## How
- [x] Step 1: Add `RegistryProject` (`{ path: String, lastSeen: String }`) and `Registry` (`{ version: Int, projects: [RegistryProject] }`) as `Codable` structs. Keep `lastSeen` a `String` for now (Date parsing for staleness sort is task #006). Decode `version` but do not gate behavior on it — mirror `lib/registry.js`, which reads `projects` regardless of version.
- [x] Step 2: Create `Sources/Plans/RegistryReader.swift` — a `struct RegistryReader` with an injectable registry-file path (default `~/.claude/plans-cc/projects.json` via `FileManager.default.homeDirectoryForCurrentUser`) and an injectable `FileManager`, so tests can point it at fixtures. Match the existing Swift style (struct, `///` doc comments, `import Foundation`).
- [x] Step 3: Implement `loadRegistry() -> [RegistryProject]` mirroring `lib/registry.js`: read the file; `JSONDecoder` decode into `Registry`; on ANY failure (file missing, zero-byte/empty, invalid JSON, wrong shape) return `[]`. Wrap all I/O + decode in `do/catch` (or `try?`) so it never throws. Wrong-shape note: a JSON object lacking a `projects` array must decode to empty, not crash — `Registry` makes `projects` required, so a missing/non-array `projects` raises a decode error that the catch turns into `[]`.
- [x] Step 4: Implement live-prune: a `readProjects() -> [RegistryProject]` that returns `loadRegistry()` filtered to entries where `<path>/.plans` exists, using `FileManager.fileExists(atPath:)` on `path + "/.plans"`. Treat a throwing/false existence check as "drop it" (defensive, like `hasPlansDir`). Do NOT canonicalize, dedupe, or rewrite — pass paths through verbatim so duplicate/non-canonical paths survive unchanged.
- [x] Step 5: Add an XCTest target: add `.testTarget(name: "PlansTests", dependencies: ["Plans"])` to `Package.swift` and create `Tests/PlansTests/RegistryReaderTests.swift`. Write fixtures into a temp dir per test (registry JSON + temp project dirs with/without a `.plans/` subdir) and point `RegistryReader` at them via the injectable path. Cover: valid registry (live projects kept); missing file → `[]`; zero-byte file → `[]`; corrupt/invalid JSON → `[]`; wrong-shape JSON (e.g. `{"version":1}` with no `projects`, or `projects` not an array) → `[]`; unknown `version` (e.g. `99`) still reads projects; stale entry (no `.plans/`) dropped; duplicate paths both preserved when their `.plans/` exists.
- [x] Step 6: Run `swift test` and confirm all cases pass; run `swift build -c release` (or `./build.sh`) to confirm the executable target still builds with the new test target present. Do NOT wire the reader into any view — integration into the glance/browser is tasks #004/#005.

## Verification
1. `swift test` passes for all cases in Step 5: valid, missing, empty, corrupt, wrong-shape, unknown-version, stale-prune, and duplicate-path.
2. `swift build -c release` (and `./build.sh`) still succeed with the test target added.
3. Against the real `~/.claude/plans-cc/projects.json`, `readProjects()` returns the one live project (`~/Work/Open Source/plans-desktop`) — verifiable via a temporary debug call or a test that reads the real file if present (kept tolerant of it being absent on CI).
4. No write occurs to `~/.claude/plans-cc/projects.json` or any `.plans/` directory (reader is read-only; live-prune drops stale entries in memory only).

## Impact Scope

### Files to Modify
- [ ] `Package.swift` — add a `.testTarget(name: "PlansTests", dependencies: ["Plans"])`.

### Files to Create
- `Sources/Plans/RegistryReader.swift` — `RegistryProject`/`Registry` models + `RegistryReader` (load + live-prune).
- `Tests/PlansTests/RegistryReaderTests.swift` — tolerance & prune test cases.

### Related Files (may need updates)
- `Sources/Plans/BrowserWindow.swift` / `MenuBarView.swift` — NOT touched here; they consume the reader in later tasks (#004/#005).

## Changes
- Created `Sources/Plans/RegistryReader.swift`: `RegistryProject` + `Registry` Codable models, and `struct RegistryReader` with an injectable registry-file `URL?` (default `~/.claude/plans-cc/projects.json`) and injectable `FileManager`. Implemented `loadRegistry() -> [RegistryProject]` with full tolerance (do/catch → `[]` on missing/empty/corrupt/wrong-shape).
- Added `readProjects() -> [RegistryProject]` (live-prune): filters `loadRegistry()` to entries whose `<path>/.plans` exists via `fileManager.fileExists(atPath:)`; no canonicalize/dedupe/rewrite (paths verbatim).
- Added `.testTarget(name: "PlansTests", dependencies: ["Plans"])` to `Package.swift` and created `Tests/PlansTests/RegistryReaderTests.swift` (9 tests, `@testable import Plans`, per-test temp-dir fixtures): valid-kept, missing/empty/corrupt/wrong-shape(×2) → `[]`, unknown-version-reads, stale-dropped, duplicate-paths-kept.
- `swift test`: 9 tests, 0 failures. `swift build -c release` and `./build.sh`: succeed.

## Notes
_Imported from desktop-app-spec.md_

Behavior contract mirrored from plans-cc `lib/registry.js` (via `~/.claude/plans-cc/lib` symlink → `~/Work/Open Source/plans/lib/registry.js`): `loadRegistry` (read → `JSON.parse` → shape-check `Array.isArray(data.projects)` → all errors to empty `{version:1,projects:[]}`), `readProjects` (filter by `hasPlansDir`), `hasPlansDir` (`existsSync(path/.plans)`, false on throw). The reference does not validate `version`.

## Assumptions

### Initial (from elaboration)
_To be filled during elaboration in skip mode._

### Discovered during execution
- [high] Used `Data(contentsOf:)` (URL-based) rather than `FileManager.contents(atPath:)` for reading. **Why:** The injectable path is modeled as a `URL` (idiomatic Swift, and `homeDirectoryForCurrentUser` returns a URL); `Data(contentsOf:)` throws on missing/unreadable files, which the `do/catch` converts to `[]` exactly as required.
- [low] Modeled the injectable registry path as `URL?` defaulting to `nil` and resolving the real location inside `init`, rather than taking a non-optional `URL`. **Why:** Lets callers construct `RegistryReader()` with zero arguments for production while tests pass a fixture URL; the `FileManager` is still injected and used to derive the home directory when no override is given.
- [high] `loadRegistry()` returns `[RegistryProject]` (the projects array) rather than the whole `Registry`. **Why:** Matches the segment's required signature and mirrors `lib/registry.js` callers that consume `projects`; `version` is decoded but intentionally unused.
- [high] `readProjects()` builds the `.plans` path via `URL(fileURLWithPath: project.path).appendingPathComponent(".plans").path` and checks it with `fileManager.fileExists(atPath:)`. **Why:** `fileExists(atPath:)` requires a filesystem path String (not a file URL); using `URL` to join handles trailing-slash/edge cases safely while still passing the original `path` through verbatim (no canonicalization or dedupe).
- [high] Test target sees `Plans` symbols via `@testable import Plans` with the existing default (`internal`) access level — no access-modifier changes were needed. **Why:** SwiftPM's `@testable` exposes internal symbols of the `Plans` executable target to `PlansTests`; all 9 tests compiled and passed without promoting any type/member to `public`.
- [low] Each test writes fixtures (registry JSON + project dirs) into a per-test temp dir `temporaryDirectory/UUID` created in `setUpWithError` and removed in `tearDownWithError`. **Why:** Isolates tests from each other and from the real `~/.claude` registry, and guarantees cleanup even on failure.
- [low] Tolerance cases (missing/empty/corrupt/wrong-shape) assert on BOTH `loadRegistry()` and `readProjects()` returning empty; live-prune cases assert on `readProjects()` (and the stale-drop case also asserts `loadRegistry()` keeps the pre-prune count of 2). **Why:** Pins down which function each behavior belongs to, per the segment's explicit guidance.
