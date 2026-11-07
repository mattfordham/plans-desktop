# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**Plans** is a native macOS app (SwiftUI, macOS 15+) that surfaces task data
managed by **plans-cc**, a lightweight task-management system for Claude Code.
plans-cc stores tasks as markdown files in a `.plans/` directory at the root of
each project; this app is a personal, machine-wide viewer across **all**
registered projects.

Two surfaces:
- **Menu bar glance (Surface A):** per-project task counts by status, compact
  glyph/label vocabulary, no window needed.
- **Browser window (Surface B):** cross-project browser — a three-column
  split view (sidebar / card grid or task list / plan detail).

`desktop-app-spec.md` is the authoritative spec, including the two plans-cc data
contracts (the registry file and the task-file markdown format). Consult it
before changing registry or parsing logic.

## Build / run / test

```bash
swift build              # debug build
swift test               # run the XCTest suite
./build.sh               # release build -> assemble Plans.app -> open it
./install.sh             # release build -> install Plans.app into /Applications
```

`DEST_DIR=~/Applications ./install.sh` overrides the install destination.

## Layout

- `Sources/Plans/` — app source (SwiftUI views, store, parsers).
  - `PlansApp.swift` — `@main`; `AppDelegate`, scene/window definitions.
  - `PlansStore.swift` — shared observable store; polling refresh.
  - `RegistryReader.swift` — reads the plans-cc registry (Data Contract 1).
  - `TaskParser.swift` — parses `.plans` task markdown (Data Contract 2;
    mirrors plans-cc `lib/parse-tasks.js`).
  - `MenuBarLabel.swift` / `MenuBarView.swift` — Surface A.
  - `BrowserWindow.swift` / `PlanDetailView.swift` / `ProjectCard.swift` —
    Surface B.
  - `TaskStatus+Glance.swift` / `TaskType+Glyph.swift` — glyph/label vocabulary.
- `Tests/PlansTests/` — XCTest unit tests.
- `Resources/` — `Info.plist`, `Plans.icns`.
- `Tools/make-icon.swift` — icon generation helper.

## Conventions

- **TDD.** Write a failing test first, then the implementation. Tests live in
  `Tests/PlansTests/` as `*Tests.swift` using XCTest with `@testable import Plans`.
- **Filesystem tests** write fixtures into a unique per-test temp directory
  (UUID-named) created in `setUpWithError` — follow that pattern for new ones.
- **Single shared store.** `PlansStore` is created once in `AppDelegate` and
  injected via `.environment(store)`. It is created in the delegate (not in
  `.onAppear`) so the initial `startPolling()` load completes before the menu
  panel first opens. Don't introduce a second store instance.
- **Selection-driven detail column.** Plan detail lives in the browser's
  `NavigationSplitView` detail column, driven by `BrowserWindow`'s single
  (unpersisted) `selectedRowID`, shared by card rows and task-list rows via
  `onOpenDetail`. It renders `PlanDetailView(rowID:)` keyed by
  `.id(selectedRowID)` so per-plan state resets; the selection is cleared via
  `BrowserViewModel.validSelection` when its row disappears. There is no
  separate detail window.
- **Glyph/label vocabulary** for statuses and types is centralized in
  `TaskStatus+Glance.swift` and `TaskType+Glyph.swift` — change it there, not
  inline in views.
- No external package dependencies — keep it pure SwiftPM + SwiftUI/AppKit.

## Notes

- `Plans.app/`, `.build/`, `.plans/`, and `.worktrees/` are gitignored.
- Run `swift test` after changes; ensure all tests pass before considering a
  task complete.
- Commit messages: describe what changed and why; do not attribute commits to
  Claude. Commit or push only when asked.
