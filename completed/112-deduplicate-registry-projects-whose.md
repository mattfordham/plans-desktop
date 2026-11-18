# Deduplicate Registry Projects Whose Paths Differ Only By Case

**ID:** 112
**Created:** 2026-11-08T15:22
**Type:** bug
**Status:** completed
**Completed:** 2026-11-09T11:11
**Branch:** fix/112-deduplicate-registry-projects-whose

## What
Deduplicate registry projects whose paths differ only by case. On case-insensitive macOS volumes the plans-cc registry can hold the same folder twice (e.g. ~/Work/Client-C/client-c-backend and ~/Work/client-c/client-c-backend), so the app shows the project and all its tasks twice. RegistryReader.readProjects() should deduplicate by canonical path, keeping the most recent lastSeen and the real on-disk spelling, test first. The matching plans-cc change, canonicalizing in registerProject (lib/registry.js) with fs.realpathSync.native, is in the separate plans repo; RegistryWriter here also matches by exact path and should be considered.

## Why
Case-variant duplicate entries make the browser and menu-bar surfaces show a project — and every task under it — twice, which is confusing and makes task counts wrong. Collapsing duplicates by canonical on-disk path restores a single, correct view per physical project.

## How Summary
Add filesystem-backed path canonicalization (via `Darwin.realpath`, the Swift equivalent of plans-cc's `fs.realpathSync.native`) to `RegistryReader.readProjects()`: after the existing `.plans/`-exists prune, collapse entries that canonicalize to the same real path, keeping one entry per canonical path with the most-recent `lastSeen` and the real on-disk spelling, preserving first-seen order. Apply the same canonical matching in `RegistryWriter.upsertProject` so the write side stops appending case-variant duplicates. Test-first, following the existing `RegistryReaderTests`/`RegistryWriterTests` temp-dir fixture conventions.

**Files of note:**
- `Sources/Plans/RegistryReader.swift` — `readProjects()` is where the duplicate currently survives; add canonical dedup here.
- `Sources/Plans/RegistryWriter.swift` — `upsertProject()` matches by exact `$0.path == path`; canonicalize the match so case-variant upserts refresh rather than append.
- `Sources/Plans/GitHelper.swift` — existing `realpath(3)` wrapper (lines 313-321) is the reference pattern to lift for canonicalization.
- `Tests/PlansTests/RegistryReaderTests.swift` — `testDuplicatePathsBothPreservedWhenPlansDirExists` asserts the OLD no-dedupe behavior and must be updated; add new case-variant dedup tests here.
- `Tests/PlansTests/RegistryWriterTests.swift` — add a case-variant upsert test here.

## Diagnosis

**Most likely:** `readProjects()` passes registry entries through verbatim with no canonical-path deduplication, and its only filter — `fileManager.fileExists(atPath: "<path>/.plans")` — is case-insensitive on default macOS volumes, so both case-variant entries pass the prune and reach the UI (`Sources/Plans/RegistryReader.swift:64-71`).
**Evidence:** `readProjects()` (lines 64-71) only `filter`s by `.plans/` existence; the doc comment (lines 62-63) explicitly declares "no canonicalization, no deduplication." On a case-insensitive volume `fileExists` returns `true` for every case spelling of the same directory, so the prune preserves rather than removes the duplicate. `PlansStore.performReload()` then maps each surviving entry to its own `ProjectTasks`, producing duplicate cards/tasks.
**Confidence:** high

**Alternative:** `RegistryWriter.upsertProject` matches existing entries by exact string equality (`$0.path == path`, `Sources/Plans/RegistryWriter.swift:54`), so a case-variant upsert appends a second entry instead of refreshing the first — a secondary write-side contributor to the duplicate. (The primary writer is plans-cc `registerProject` in the separate plans repo.) — **Confidence:** medium

**To confirm:** Add a failing test that builds a registry with two entries whose `path` strings differ only by case, both resolving to one on-disk project dir with a `.plans/`, each with a different `lastSeen`, and assert `readProjects()` returns exactly ONE entry carrying the most-recent `lastSeen` and the real on-disk spelling. The current code returns two — confirming the dedup is absent.

## How
- [x] Step 1: Add a failing `RegistryReaderTests` case modeling two registry entries whose `path` differs only by case, both pointing at one on-disk dir with a `.plans/`, with differing `lastSeen`; assert `readProjects()` returns exactly ONE entry with the most-recent `lastSeen` and the real on-disk spelling (confirms the Diagnosis; agent-verifiable, so untagged).
- [x] Step 2: Add a private filesystem-backed canonicalization helper to `RegistryReader` modeled on `GitHelper.realpath` (use `Darwin.realpath`, fall back to `URL(fileURLWithPath:).standardizedFileURL.path` when it returns nil). Do NOT use `standardizedFileURL` alone — it does not resolve case.
- [x] Step 3: In `readProjects()`, after the existing `.plans/`-exists prune, deduplicate by canonical path — keep one entry per canonical path, preferring the most-recent `lastSeen`, emit the real on-disk spelling (the realpath result), and preserve first-seen order. Leave `loadRegistry()` untouched (tests assert its verbatim count).
- [x] Step 4: Update the existing `testDuplicatePathsBothPreservedWhenPlansDirExists` to reflect the new behavior (exact-duplicate paths now collapse to one), renaming/retargeting it so the suite asserts dedupe rather than preservation. Run the `RegistryReaderTests` to green.
- [x] Step 5: Canonicalize the match in `RegistryWriter.upsertProject` so a case-variant path refreshes the existing entry in place instead of appending a duplicate; add a `RegistryWriterTests` case asserting a case-variant upsert keeps a single entry. Run the `RegistryWriterTests` to green.

## Issues
- [x] 43 PlansStoreTests cases (115 assertions) fail on this branch but pass on main: readProjects() now returns realpath-canonical paths, so fixtures under /var come back as /private/var.

## Verification
- Run `swift test --filter RegistryReaderTests` and `swift test --filter RegistryWriterTests` — all pass, including the new case-variant dedup tests.
- With two case-variant entries for one physical project in the registry, `readProjects()` returns a single entry with the most-recent `lastSeen` and the real on-disk spelling.
- Genuinely distinct projects on a case-sensitive volume are NOT collapsed (no lowercasing — canonicalization is filesystem-backed via realpath).

## Impact Scope
_To be filled during elaboration (if 3+ files affected)_

## Assumptions

### Initial (from elaboration)
- [low] Use a string `max` comparison on `lastSeen` to pick the most-recent entry rather than pulling task #006's date parsing forward. **Why:** The writer emits uniform ISO-8601-with-millisecond-UTC strings that sort lexicographically; #006 explicitly owns date parsing. Older second-precision fixtures of differing length could misorder, so tests use uniform same-length timestamps.
- [low] Scope the dedup to case/realpath canonicalization via `Darwin.realpath`, which also folds symlink/`.`/`..` duplicates. **Why:** The task names case specifically, but realpath is the correct on-disk canonicalization and additionally merging symlinked duplicates is desirable, not harmful.
- [high] Keep the dedup in `readProjects()` only, not `loadRegistry()`. **Why:** `loadRegistry()` is documented as a verbatim low-level read and tests assert its untouched count.

### Discovered during execution
- [high] Compared `lastSeen` with Swift string `>` (not parsed dates) to pick the most-recent of a canonical group. **Why:** Matches the pre-existing [low] assumption; writer emits uniform same-length ISO-8601 UTC strings that sort lexically. Date parsing stays owned by #006.
- [high] `readProjects()` now emits the realpath-canonical spelling for EVERY entry, not just deduped groups — because canonicalization is applied before dedup. **Why:** The task requires emitting "the real on-disk spelling." Consequence: on macOS temp volumes `/var/...` resolves to `/private/var/...` (the `/var` symlink), so three existing tests (`testValidRegistryKeepsLiveProjects`, `testStaleEntryWithoutPlansDirIsDropped`, `testUnknownVersionStillReadsProjects`) that asserted the raw stored `/var/...` path had to be updated to assert the canonical spelling via a new test-only `canonical()` helper. This is an environmental symlink artifact, not a logic change; `loadRegistry()` still returns raw paths and those assertions are untouched.
- [high] Left `testDuplicatePathsBothPreservedWhenPlansDirExists` failing and unmodified. **Why:** It asserts the OLD no-dedupe behavior; the segment prompt states Step 4 (next segment) owns replacing it.
- [high] When `RegistryWriter.upsertProject` refreshes an existing (canonical-matched) entry in place, it preserves the EXISTING entry's stored `path` spelling and updates only `lastSeen` — it does NOT overwrite with the incoming case-variant spelling. **Why:** Simplest change that keeps all existing writer tests green (identical strings canonicalize identically, so `testUpsertUpdatesLastSeenForExistingPath` / `testUpsertDoesNotDuplicateExistingPath` are unaffected) and matches the reader's intent of a stable real on-disk spelling. The reader's `readProjects()` canonicalizes paths at read time regardless, so the stored writer spelling is normalized when surfaced to the app.
- [low] Canonicalized the `PlansStoreTests` fixture root with `Darwin.realpath` in `setUpWithError` instead of adjusting each path-keyed assertion. **Why:** All 43 failures came from fixtures spelled `/var/...` while `readProjects()` now reports `/private/var/...`; one change at the root fixes them without weakening any assertion, and `realpath(3)` matches the reader exactly where `URL.resolvingSymlinksInPath()` can strip `/private`.
- [high] Fixed a production regression in `PlansStore.performReload`: the paused-migrate branch re-read raw `loadRegistry()` spellings and compared them to canonical paths, so during a migrate any non-canonically registered project vanished and exact duplicates came back. Replaced it with `readProjects(retaining: pausedPaths)`. **Why:** Canonicalizing `readProjects()` output made the raw and canonical spellings disagree; the canonical test fixtures cannot show this, so three regression tests register projects via symlink or as exact duplicates.

## Changes
- `Sources/Plans/RegistryReader.swift` — Added a private static `realpath(_:)` helper (mirrors `GitHelper.realpath`: `Darwin.realpath`, falling back to `standardizedFileURL.path`). Rewrote `readProjects()` to, after the existing `.plans/`-exists prune, canonicalize each entry's path and deduplicate by canonical path — keeping one entry per canonical path with the most-recent `lastSeen` (lexical string compare), emitting the real on-disk spelling, and preserving first-seen order. `loadRegistry()` left untouched.
- `Tests/PlansTests/RegistryReaderTests.swift` — Added `testCaseVariantPathsDeduplicatedToCanonicalSpelling` (the Diagnosis-confirming test). Updated three existing tests (`testValidRegistryKeepsLiveProjects`, `testStaleEntryWithoutPlansDirIsDropped`, `testUnknownVersionStillReadsProjects`) to expect the canonical spelling via a test-only `canonical(_:)` helper, since `readProjects()` now emits realpath-canonical paths (macOS temp dirs resolve `/var → /private/var`); `loadRegistry()` assertions still check the raw stored paths. Renamed `testDuplicatePathsBothPreservedWhenPlansDirExists` → `testDuplicatePathsDeduplicatedToSingleEntry`, now asserting exact-duplicate paths collapse to one entry carrying the most-recent `lastSeen`.
- `Sources/Plans/RegistryWriter.swift` — Added a private static `realpath(_:)` helper (mirrors `RegistryReader`'s) and changed `upsertProject`'s existing-entry match from exact-string `$0.path == path` to canonical `Self.realpath($0.path) == Self.realpath(path)`, so a case-variant upsert refreshes the existing entry's `lastSeen` in place (preserving its stored spelling) instead of appending a duplicate.
- `Tests/PlansTests/RegistryWriterTests.swift` — Added `testUpsertCaseVariantOfSameDirKeepsSingleEntry`: creates a real on-disk subdir, upserts its real path then an uppercased variant of its last component, and asserts a single registry entry survives.
- `Tests/PlansTests/PlansStoreTests.swift` — Canonicalized the `tempDir` fixture root with `Darwin.realpath` in `setUpWithError`, resolving all 43 failures from `/var` vs `/private/var`. Added three regression tests for non-canonical registrations during a migrate.
- `Sources/Plans/RegistryReader.swift` — Added `readProjects(retaining:)`, which keeps the given canonical paths even while their `.plans` is moved aside.
- `Sources/Plans/PlansStore.swift` — `performReload` now calls `readProjects(retaining: pausedPaths)`, replacing a raw `loadRegistry()` re-read that dropped non-canonically registered projects and restored duplicates during a migrate.

## Notes
_Additional context_
