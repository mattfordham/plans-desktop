# Live-update via watch/poll + periodic registry re-read

**ID:** 006
**Created:** 2026-06-04T14:41
**Type:** feature
**Status:** completed
**Completed:** 2026-06-05T12:45
**Branch:** feature/006-live-update-watch-poll
**Source:** Imported from desktop-app-spec.md

## What
The app must reflect data changes **without the user manually refreshing**.

- Changes to any registered project's `.plans/` directory (new/edited/removed task files, status changes, checkbox progress) should appear in the UI automatically and reasonably promptly.
- The **registry file** (`~/.claude/plans-cc/projects.json`) must be **re-read periodically** so newly self-registered projects appear without restarting the app.
- Always re-validate stale projects (§4.3) on each refresh so deleted projects drop out.

Mechanism is your choice — FSEvents / DispatchSource / `FileSystemWatcher`, periodic polling (every few seconds is acceptable), or a hybrid. Pick whatever is simplest and reliable for personal tooling.

Spec reference: §7 (Live-Update Expectation).

## Why
Adds value by making the dashboard a live glance: registered projects, their task
status, and checkbox progress stay current without the user restarting or manually
refreshing the app. Without this, both surfaces paint once at launch (see the
explicit "Continuous live refresh is task #006" note in `PlansApp.swift`) and go
stale the moment any `.plans/` file or the registry changes.

## How

Chosen mechanism (decided during elaboration): a **simple repeating main-thread
`Timer`** that calls `PlansStore.reload()` every **5 seconds**. `reload()` already
re-reads the registry, live-prunes stale projects (via `RegistryReader`'s `.plans/`
existence filter), and re-parses every project's `.plans/` — so one trigger covers
new/edited/removed task files, status/checkbox changes, newly self-registered
projects, and deleted projects. No FSEvents/DispatchSource needed.

- [x] Step 1: Add polling lifecycle to `Sources/Plans/PlansStore.swift` — an `@ObservationIgnored private var pollTimer: Timer?`, a `startPolling(interval: TimeInterval = 5)` that invalidates any existing timer then schedules a repeating `Timer` (on the main run loop) whose block calls `self.reload()`, and a `stopPolling()` that invalidates and nils the timer. Keep `reload()` itself unchanged.
- [x] Step 2: Drive an immediate first refresh from `startPolling()` (call `reload()` once before/at scheduling) so the existing one-shot semantics still hold even if the launch call site is later consolidated.
- [x] Step 3: Wire it up in `Sources/Plans/PlansApp.swift` — in `AppDelegate.applicationDidFinishLaunching`, replace the lone `store.reload()` with `store.startPolling()` (which performs the initial load and then keeps it fresh). Update the inline comments in `PlansApp.swift`/`PlansStore.swift` that currently say live refresh is "task #006" to reflect that it's now implemented.
- [x] Step 4: Add tests to `Tests/PlansTests/PlansStoreTests.swift` covering: (a) `startPolling()` performs an initial load (projects populated synchronously after the call), and (b) a subsequent `reload()` reflects a filesystem change — write a task file into a fixture project's `.plans/`, call `reload()` again, and assert counts update. Follow the existing UUID temp-dir + injected-`RegistryReader` fixture pattern; avoid asserting on real wall-clock timer firing (test `reload()` idempotency/freshness directly, and that `stopPolling()` invalidates the timer).

## Assumptions

### Discovered during execution
- [low] Added a test-only `var isPolling: Bool` computed property to `PlansStore` (returns `pollTimer?.isValid ?? false`) to make timer install/invalidation observable in tests without wall-clock. **Why:** The task asked for a way to assert `stopPolling()` invalidates the timer without relying on real timer firing; a minimal `@testable`-accessible read-only hook over `Timer.isValid` is the least-intrusive option and avoids exposing the timer itself. It is `internal` (default) so it is only reachable via `@testable import`.
- [high] Captured `self` strongly (`[self]`) in the repeating timer block rather than `[weak self]`. **Why:** The task explicitly states the store is app-lifetime and `self` is fine here; the store owns the timer, and `Timer.scheduledTimer` on the main run loop already retains the block, so a weak capture would add no real benefit and the no-cycle reasoning is documented in a code comment.
- [high] Used `Timer.scheduledTimer(withTimeInterval:repeats:block:)` on the implicit main run loop with default interval 5s. **Why:** Matches the "simple repeating main-thread Timer every 5 seconds" mechanism already decided in the `## How` section; scheduling from `applicationDidFinishLaunching` runs on the main thread, so the timer attaches to the main run loop as intended.

## Verification
Run `swift test` — new and existing `PlansStoreTests` pass, confirming `reload()`
picks up fresh filesystem state and `startPolling()`/`stopPolling()` manage the
timer correctly. 👁 Then run the app (`swift run`), open the browser window, and
while it's open create/edit a task file in a registered project's `.plans/` (and
add a brand-new project to `~/.claude/plans-cc/projects.json`); confirm the change
appears within ~5 seconds and a deleted project drops out, all without manual
refresh.

## Changes
- `Sources/Plans/PlansStore.swift`: added `import Foundation`, `@ObservationIgnored private var pollTimer: Timer?`, `startPolling(interval: TimeInterval = 5)` (synchronous initial `reload()` then a repeating main-run-loop `Timer`), `stopPolling()`, and a test-visible `isPolling` hook. `reload()` unchanged. Updated the "task #006" comment to note polling is implemented.
- `Sources/Plans/PlansApp.swift`: `AppDelegate.applicationDidFinishLaunching` now calls `store.startPolling()` instead of `store.reload()`; updated the live-refresh comments accordingly.
- `Tests/PlansTests/PlansStoreTests.swift`: added 4 tests covering synchronous initial load via `startPolling()`, `reload()` reflecting a filesystem change, timer install/invalidate lifecycle, and `stopPolling()` no-op safety. `swift test --filter PlansStoreTests` → 8/8 passing.

## Notes
_Imported from desktop-app-spec.md_
