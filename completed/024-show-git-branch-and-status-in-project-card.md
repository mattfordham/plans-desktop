# Show Git Branch And Status In Each Project Card

**ID:** 024
**Created:** 2026-06-06T00:00
**Type:** feature
**Status:** completed
**Completed:** 2026-06-06T15:12
**Branch:** feature/024-show-git-branch-and-status-in-project-card

## What
In each project card, show the currently checked out Git branch and current git status.

## Why
Adds value by surfacing each project's live VCS state (current branch + whether the
working tree is dirty) directly on its `ProjectCard`, so the cross-project browser
conveys at a glance which projects have in-flight, uncommitted work and what branch
they're parked on — without leaving the app.

## How
- [x] Step 1: Add a new `GitHelper.swift` to `Sources/Plans/` with two `nonisolated static` methods that shell out via `Process` to `/usr/bin/git` (mirroring `TaskRunner.resolveNodePath()`): `currentBranch(at projectPath: String) -> String?` running `git -C <path> rev-parse --abbrev-ref HEAD`, and `isDirty(at projectPath: String) -> Bool?` running `git -C <path> status --porcelain` (dirty = non-empty output). Both must be called off the main actor, return `nil` on any failure / non-git-repo (silent), and trim output.
- [x] Step 2: Add unit tests for `GitHelper` in `Tests/PlansTests/` — create a temp directory, `git init` it (set a branch, make a commit, optionally touch a file to dirty it), assert `currentBranch` returns the expected branch and `isDirty` reflects working-tree state; assert a non-git temp dir yields `nil` for both. Follow the UUID-named temp-dir fixture pattern from `PlansStoreTests`.
- [x] Step 3: Extend the `ProjectTasks` struct in `Sources/Plans/TaskParser.swift` with two optional fields — `let gitBranch: String?` and `let gitIsDirty: Bool?` — documented as `nil` when the project is not a git repo / git is unavailable / the command failed. Default the parser's own construction of `ProjectTasks` to `nil` for both (git info is attached later by the store, keeping `TaskParser` filesystem-only).
- [x] Step 4: In `PlansStore.reload()` (`Sources/Plans/PlansStore.swift`), after the synchronous task-parse pass populates `projects`, gather git info in a `Task.detached` (off main actor) using `GitHelper`, then hop back to the main actor and rebuild each matching `ProjectTasks` with `gitBranch` / `gitIsDirty` attached (match by `projectPath`). This keeps the existing fast first paint and the 5s poll non-blocking while git commands run.
- [x] Step 5: Update `ProjectCard.header` (`Sources/Plans/ProjectCard.swift`) to render a git indicator in keeping with the existing muted/glance idiom: branch name in `.caption`/`.secondary` with a small SF Symbol (e.g. `arrow.triangle.branch`), plus a small dirty dot (`circle.fill`, small scale, `.orange`) shown only when `gitIsDirty == true`. Render nothing when `gitBranch == nil`. Truncate long branch names with `.lineLimit(1)`.
- [x] 👁 Step 6: Run the app (`./build.sh`) and confirm each project card shows the correct current branch, the dirty dot appears for projects with uncommitted changes and is absent for clean ones, non-git project roots render no git row, and the indicator refreshes on the poll cycle when you switch branches / dirty a tree. (Confirmed during review; a per-poll flash bug was found and fixed.)

## Verification
- `GitHelper` unit tests pass (`swift test` scoped to the new test file): branch + dirty detection on a temp git repo, `nil` on a non-repo.
- In the running app, each `ProjectCard` displays the project's actual current git branch.
- A project with uncommitted changes shows the dirty indicator; a clean project does not.
- A project root that is not a git repository renders the card with no git row and no errors.
- The git indicator updates within a poll cycle after switching branches or modifying the working tree.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/GitHelper.swift` (new) — Process-based `currentBranch` / `isDirty` helpers
- [ ] `Sources/Plans/TaskParser.swift` — add `gitBranch` / `gitIsDirty` to `ProjectTasks`
- [ ] `Sources/Plans/PlansStore.swift` — gather git info off-main-actor in `reload()` and attach to projects
- [ ] `Sources/Plans/ProjectCard.swift` — render branch + dirty indicator in the card header

### Related Files (may need updates)
- `Tests/PlansTests/PlansStoreTests.swift` — existing `ProjectTasks` construction sites may need the new fields (defaults to `nil`)
- `Tests/PlansTests/GitHelperTests.swift` (new) — unit tests for the helper

### Endpoints/UI Affected
- `ProjectCard` header (Surface B browser) — new git branch + dirty-state row

## Assumptions

### Initial (from elaboration)
- [low] Git info is gathered in a `Task.detached` after the synchronous parse pass, then merged back on the main actor, rather than blocking `reload()`. **Why:** Shelling out to `git` twice per project every 5s would block the main actor and stutter the UI on workspaces with many/slow repos; the codebase already runs subprocesses off the main actor (`TaskRunner`). Trade-off: a brief moment where cards show tasks before git info populates.
- [low] The git indicator is rendered as a subtle second-line/inline element in the card header using the existing muted `.caption`/`.secondary` glance idiom (branch text + small SF Symbol + orange dirty dot), not a redesign of the header. **Why:** Research found the header is a single `HStack`; matching the existing low-emphasis vocabulary avoids UI clutter, but exact placement (inline vs. new line) is a UX call the description didn't specify.
- [high] Dirty state is derived from `git status --porcelain` returning non-empty output, and branch from `git rev-parse --abbrev-ref HEAD`. **Why:** These are the canonical porcelain-stable commands; `rev-parse --abbrev-ref HEAD` returns `HEAD` for detached state, which is acceptable to display verbatim.
- [high] `GitHelper` mirrors `TaskRunner.resolveNodePath()` — `nonisolated static`, `Process` to an absolute git path, silent `nil` on failure. **Why:** Single established subprocess pattern in the codebase; no plausible alternative surfaced.
- [low] Git results are recomputed every poll rather than cached per-path. **Why:** Branch/dirty state changes frequently and must stay live; caching would risk staleness. Trade-off: per-poll process overhead, mitigated by the off-main-actor gather. Could be revisited if performance suffers on large workspaces.

### Discovered during execution
- [high] Implemented `GitHelper` as an `enum` (no cases) rather than a `struct`/`class` namespace. **Why:** A caseless enum is the idiomatic Swift namespace for a pure collection of static methods — it cannot be instantiated, matching the stateless, no-stored-properties nature of these helpers (TaskRunner uses a class only because it needs the `@MainActor @Observable` instance + a cache, neither of which applies here).
- [high] Used `git status --porcelain` (v1, default) rather than `--porcelain=v2`. **Why:** Step spec named `--porcelain`; v1 output is stable and non-empty iff the tree is dirty, which is all `isDirty` needs.
- [low] `GitHelper.currentBranch(at:)` and `isDirty(at:)` return `nil` (not a thrown error) on empty path before even launching a process. **Why:** Matches the "silent toward UI, nil == unknown" contract and avoids a pointless `git -C ""` invocation; the empty-path guard is covered by a dedicated test.
- [high] `ProjectTasks` got an explicit memberwise `init` with `gitBranch`/`gitIsDirty` defaulting to `nil` (rather than reordering fields or making the parser set them). **Why:** Defaulted explicit init keeps every existing call site (parser + tests using the synthesized memberwise init) compiling unchanged; the store reconstructs the struct with git values supplied.
- [high] Git enrichment in `PlansStore.reload()` uses GCD (`DispatchQueue.global → DispatchQueue.main`) rather than `Task.detached`/`MainActor.run`. **Why:** `PlansStore` is a non-`Sendable`, main-thread-only `@Observable` class that is NOT `@MainActor`-annotated, and its existing tests call its members synchronously from nonisolated test methods. Annotating the class `@MainActor` (to make structured concurrency clean) broke all those tests and added warnings across `BrowserWindowTests` — a ripple outside this segment. GCD hops background→main without crossing a Swift-concurrency Sendability boundary, leaving the class isolation untouched.
- [low] In the GCD path `self` is captured via `nonisolated(unsafe) let unsafeSelf = self` (strong). **Why:** The `@Sendable` GCD closures otherwise warn on the non-`Sendable` `self` capture; the store is app-lifetime and only touched on the main thread (the sole `self` access, `applyGitInfo`, is re-dispatched to the main queue), so a strong unsafe capture is correct and warning-clean. (The pre-existing poll-timer `[self]` closure already carries this same Sendable-capture warning on baseline; left untouched.)
- [low] Branch name in the card uses `.truncationMode(.middle)` and the project-name `Text` gets `.layoutPriority(1)`. **Why:** Long branch names (e.g. `feature/024-show-git-branch...`) must never push the project name out; middle truncation keeps the readable prefix/suffix.

## Changes
- Added `Sources/Plans/GitHelper.swift` — caseless `enum` namespace with `nonisolated static currentBranch(at:) -> String?` (`git -C <path> rev-parse --abbrev-ref HEAD`) and `isDirty(at:) -> Bool?` (`git -C <path> status --porcelain`, dirty = non-empty). Process to `/usr/bin/git`, stderr silenced, `nil` on any failure (not-a-repo / git unavailable), no caching (state stays live).
- Added `Tests/PlansTests/GitHelperTests.swift` — 7 XCTest cases (branch on temp repo via forced `testbranch`, dirty clean/untracked/modified, `nil` on non-git dir, `nil` on empty path). `swift test --filter GitHelperTests` passes.
- `Sources/Plans/TaskParser.swift` — `ProjectTasks` gained `gitBranch: String?` / `gitIsDirty: Bool?` stored fields plus an explicit memberwise `init` defaulting both to `nil`, so existing call sites compile unchanged. `TaskParser` stays filesystem-only (constructs with the `nil` defaults).
- `Sources/Plans/PlansStore.swift` — `reload()` keeps the synchronous parse pass (fast first paint with `nil` git fields), then gathers branch/dirty per project on `DispatchQueue.global(qos: .utility)` and merges results back on the main thread via `applyGitInfo(_:)`, matching by `projectPath`. GCD chosen over structured concurrency to avoid forcing `@MainActor` on the non-`Sendable` store (which would have broken existing test call sites); `self` captured `nonisolated(unsafe)` with a documented main-thread-only invariant.
- `Sources/Plans/ProjectCard.swift` — header renders an `arrow.triangle.branch` glyph + branch name (`.caption`/`.secondary`, middle-truncated, `lineLimit(1)`) and an orange `circle.fill` dirty dot shown only when `gitIsDirty == true`; the whole git group is gated on `gitBranch != nil`. Project name holds `layoutPriority(1)` so the branch never crowds it out.
- Verified: `swift build` clean; `GitHelperTests` pass; `PlansStoreTests` shows only 4 pre-existing baseline failures (project-name titleization staleness) — zero regressions from #024.

## Notes
- `/usr/bin/git` is the standard macOS git shim (Xcode CLT). If git is missing, helpers return `nil` and the card simply omits the git row.
- Detached HEAD will display as `HEAD`; this is intentional and acceptable for v1.
