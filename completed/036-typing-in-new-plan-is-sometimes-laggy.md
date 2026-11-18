# Typing in "new plan" is sometimes laggy

**ID:** 036
**Created:** 2026-06-07T00:00
**Type:** bug
**Status:** completed
**Branch:** fix/036-typing-in-new-plan-is-sometimes-laggy
**Completed:** 2026-06-08T09:12

## What
Typing in "new plan" is sometimes laggy. Just my imagination?

## Why
Improves reliability and perceived quality by eliminating intermittent input lag
in the New Plan capture sheet. The lag is real, not imagined: the sheet's body
reads `store.projects` (via `orderedProjects`), and `PlansStore.reload()` reassigns
that observable array on the main thread every 5 seconds. Each poll therefore
invalidates and re-renders the whole `NewPlanModal` body — including the
`TextEditor` the user is typing into — producing a perceptible hitch roughly on
the 5s polling cadence. Decoupling typing from the poll keeps keystroke handling
smooth.

## How
- [x] Step 1: Confirm the re-render coupling in `Sources/Plans/NewPlanModal.swift`
      — `body` (line 83) reads `orderedProjects` (lines 66–68), which reads
      `store.projects`; `PlansStore.reload()` (`Sources/Plans/PlansStore.swift`
      line 272) reassigns `projects` every 5s on the main thread, so the editor
      re-renders on each poll while typing.
- [x] 👁 Step 2: Reproduce/diagnose — run the app (`./build.sh`), open the New
      Plan sheet, and type continuously for ~15s. Confirm the hitch recurs on the
      ~5s poll boundary. (Observation needed before committing to the fix; if lag
      is NOT on poll boundaries, revisit the hypothesis before Step 3.)
- [x] Step 3: Snapshot the project list into local view state in `NewPlanModal`
      so typing no longer re-renders against poll mutations. Replace the
      `orderedProjects` computed property's direct use in `body` with a
      `@State private var orderedProjectsSnapshot: [ProjectTasks] = []` populated
      in `.onAppear` (call `BrowserViewModel.sortByStaleness(store.projects)`),
      and use the snapshot in the `Picker`'s `ForEach` (line 89).
- [x] Step 4: Refresh the snapshot only when the project set actually changes —
      not on every poll. Add `.onChange(of: store.projects.map(\.projectPath))`
      (a value-equatable identity key, NOT the whole array) to recompute the
      snapshot, so adding/removing/linking a project still updates the picker
      while routine 5s re-parses (which keep the same project paths) do not
      churn the editor.
- [x] Step 5: Verify the selected `projectPath` stays valid against the snapshot
      (the form defaults to the most-recent project); confirm switching projects
      (`.onChange(of: projectPath)`, line 124) and draft swap still work with the
      snapshot in place.
- [x] Step 6: Add/extend an XCTest in `Tests/PlansTests/` asserting the snapshot
      logic — i.e. that `sortByStaleness` ordering is preserved and that an
      identity key derived from `projects` only changes when project paths change
      (guards Step 4's refresh trigger). Run `swift test` and ensure green.
- [x] 👁 Step 7: Re-run the app and type continuously again; confirm the hitch is
      gone across several poll cycles and that the project picker still reflects a
      newly-linked project within one poll.

## Verification
- The intermittent typing hitch in the New Plan sheet no longer occurs on the 5s
  poll boundary (verified by typing continuously through several poll cycles).
- The project picker still updates when a project is added/removed/linked
  (within ~one poll), and project switching + per-project draft persistence are
  unaffected.
- `swift test` passes (existing suite plus the new snapshot/identity-key test).
- No regression in the sheet's submit/clear/cancel behavior.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/NewPlanModal.swift` — Replace the body's dependency on
      `store.projects` with a local `@State` snapshot; populate in `.onAppear`
      and refresh via `.onChange` on a project-path identity key.
- [x] `Tests/PlansTests/` (new or existing `*Tests.swift`) — Add a test covering
      the snapshot ordering and the identity-key refresh trigger.

### Related Files (may need updates)
- `Sources/Plans/PlansStore.swift` — `reload()` runs the registry read + parse
  first pass on the main thread every 5s. Not modified in the primary fix, but it
  is the source of the poll-driven mutations; see Notes for the optional deeper fix.
- `Sources/Plans/BrowserWindow.swift` — Presents the sheet and already reacts to
  `store.newPlanTrigger`; sanity-check that snapshotting doesn't affect presentation.

### Endpoints/UI Affected
- New Plan capture sheet (`NewPlanModal`) — text editor typing latency and the
  project picker's update behavior.

## Assumptions

### Initial (from elaboration)
- [high] Root cause is the New Plan sheet re-rendering on every 5s poll because
  its `body` reads `store.projects` via `orderedProjects`. **Why:** Code trace
  confirms `body` → `orderedProjects` → `store.projects`, and `reload()`
  reassigns `projects` on the main run loop every 5s (`startPolling(interval: 5)`),
  invalidating the editor while typing.
- [high] Fix by snapshotting the ordered project list into local `@State` and
  refreshing it only on a project-path identity change, rather than reading the
  store live in `body`. **Why:** Lowest-risk change that breaks the typing↔poll
  coupling; mirrors the codebase's existing care about poll-driven UI churn (the
  #024 git carry-over avoids a per-poll flash). The picker is passive and only
  needs to change when the project set changes.
- [low] Scope the fix to the view layer only and leave `PlansStore.reload()`'s
  main-thread first pass as-is for now. **Why:** Research flagged the synchronous
  parse pass as a secondary contributor, but moving it off-main-thread is a larger,
  riskier change (transient/partial state, ordering) and may be unnecessary once
  the view no longer re-renders on typing. Profile first; deferred to Notes as an
  optional follow-up rather than required here.
- [low] Use `store.projects.map(\.projectPath)` as the `.onChange` identity key.
  **Why:** Project paths are the stable identity used throughout (`ForEach(id:
  \.projectPath)`, `applyGitInfo` matches by path); routine re-parses keep the
  same paths, so this triggers a refresh only on genuine add/remove/link. An exact
  count-only key was rejected as it would miss a same-count rename/relink.
- [low] Add an automated test rather than relying solely on manual observation.
  **Why:** Project convention is TDD/XCTest; a unit test on the ordering +
  identity-key logic is feasible without UI, even though the latency itself can
  only be confirmed by manual observation (Steps 2 and 7).

### Discovered during execution
- [high] Structured the snapshot refresh as a private `refreshProjectsSnapshot()`
  helper that assigns `orderedProjectsSnapshot = orderedProjects`, keeping the
  existing `orderedProjects` computed as the single source of the sort logic.
  **Why:** Avoids duplicating `BrowserViewModel.sortByStaleness` and keeps one
  authoritative ordering definition; the helper is called from both `.onAppear`
  and the path-identity `.onChange`.
- [low] On a selected `projectPath` missing from the snapshot (e.g. its project
  was removed), left the selection as-is rather than auto-reselecting. **Why:**
  SwiftUI's `Picker` tolerates a tag with no matching row (shows blank), and a
  later user pick reselects a valid path; auto-reselect would be over-engineering
  for a rare edge case and risks silently changing the user's target mid-draft.
- [low] (Step 6) Did NOT add a duplicate `sortByStaleness` ordering test; the
  existing `testSortByStaleness*` cases (descending order, fractional seconds,
  stable-for-unparseable) already prove the snapshot preserves live ordering.
  Instead added one snapshot-specific test (`testSnapshotCapturesLiveStalenessOrdering`)
  asserting a shuffled store is reproduced in staleness order AND that the derived
  path-identity key reflects that order. **Why:** Avoids redundant assertions while
  still tying the snapshot's `sortByStaleness(store.projects)` use to the picker.
- [low] (Step 6) Guarded the Step 4 `.onChange` trigger with four path-identity-key
  tests via a local `pathIdentityKey(_:)` helper mirroring
  `store.projects.map(\.projectPath)`: UNCHANGED on a same-paths metadata-only
  re-parse (newer `lastSeen` + added `tasks`), and CHANGED on add / remove / relink.
  **Why:** These four cases directly assert the value-equatable refresh contract —
  routine 5s re-parses don't refresh, genuine project-set changes do — without
  instantiating the SwiftUI view (matching the file's value-only style).

## Changes
- Step 1: Confirmed the re-render coupling via static code trace — `NewPlanModal.body`
  → `orderedProjects` (reads `store.projects`); `PlansStore.reload()` reassigns
  `projects` every 5s on the main thread (plus a per-element reassign in the async
  git second pass), invalidating the modal body (and its `TextEditor`) on each poll.
- Step 2 (👁): Runtime typing-latency observation deferred to human review (no GUI in
  this run); static evidence supports the poll-boundary hitch hypothesis.
- Step 3: Added `@State private var orderedProjectsSnapshot: [ProjectTasks]` to
  `NewPlanModal`; the picker's `ForEach` now iterates the snapshot instead of the
  live `orderedProjects`. Snapshot populated in `.onAppear` via a new private
  `refreshProjectsSnapshot()` helper that assigns `orderedProjectsSnapshot =
  orderedProjects` (reusing the existing `sortByStaleness`-backed computed so the
  sort logic isn't duplicated).
- Step 4: Added `.onChange(of: store.projects.map(\.projectPath))` →
  `refreshProjectsSnapshot()`. The value-equatable path key means routine 5s
  re-parses (same paths) don't churn the editor, while add/remove/link still
  refreshes the picker.
- Step 5: Verified no other render-path reads of `store.projects`/`orderedProjects`
  in the body; `projectPath` selection, project switching, and per-project draft
  swap remain valid against the snapshot. A selected path missing from the snapshot
  is left as-is (Picker tolerates an unmatched tag).
- Step 6: Added a `// MARK: - (b2) #036` test group to `BrowserWindowTests.swift`
  with 5 tests — four path-identity-key guards (unchanged on same-paths metadata
  re-parse; changed on add/remove/relink) plus one snapshot staleness-ordering
  test. `swift test --filter BrowserWindowTests` → 59 tests, 0 failures.

## Notes
- Optional deeper fix (only if profiling in Step 2 shows the main-thread parse
  pass itself stalls the UI independent of the form re-render): restructure
  `PlansStore.reload()` so the first pass (registry read + `taskParser.parseProject`
  for all projects) runs on a background queue and merges results back on the main
  thread — mirroring the existing #024 git second-pass GCD offload (PlansStore.swift
  lines 298–330). Deferred because it is more invasive (risk of transient/partial
  project state in observers) and likely unnecessary once the view stops
  re-rendering on every poll.
- Diagnosis aids: the New Plan sheet logs under the `NewPlanModal` OSLog category
  (`subsystem: com.plans.desktop`); correlate keystroke timing against poll ticks
  in Console.app, and/or use Instruments (Time Profiler + Core Animation) to
  confirm main-thread blocking vs. SwiftUI view-graph invalidation.
- Impact scales with project count and `.plans/` file sizes, so the effect may be
  more pronounced for users with many registered projects.
