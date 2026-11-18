# Project Context

**Project:** Plans (plans-cc Desktop App)
**Updated:** 2026-06-05

## Overview
A native macOS app that surfaces task data managed by **plans-cc**, a lightweight
task-management system for Claude Code. plans-cc stores tasks as markdown files
in a `.plans/` directory at the root of each project; this app is a personal,
machine-wide viewer across **all** registered projects. It has two surfaces:

- **Surface A — Menu bar "glance":** an at-a-glance, per-project breakdown of
  task counts by status, rendered with a compact glyph/label vocabulary.
- **Surface B — Browser window:** a cross-project window for drilling into
  projects and individual plans: a three-column split view (sidebar / card
  stack under "All projects", otherwise a task list / persistent plan-detail
  column).

The app reads two data contracts from plans-cc: the registry file (list of
registered project roots) and the per-task markdown file format.

## Tech Stack
- Swift 6.0 (`swift-tools-version:6.0`)
- SwiftUI (macOS 15+ / `.v15` deployment target)
- AppKit interop via `NSApplicationDelegateAdaptor` / `NSApp`
- Swift Package Manager (no external dependencies)

## Structure
```
plans-desktop/
  Package.swift              # SwiftPM manifest: Plans executable + PlansTests target
  Sources/Plans/            # App source (SwiftUI views, store, parsers)
    PlansApp.swift          # @main entry; AppDelegate, scene/window definitions
    PlansStore.swift        # Shared observable store; polling refresh
    RegistryReader.swift    # Reads plans-cc registry (Data Contract 1)
    TaskParser.swift        # Parses .plans task markdown (Data Contract 2)
    MenuBarLabel.swift      # Menu bar icon-space live count label (Surface A)
    MenuBarView.swift       # Menu bar panel content (Surface A)
    BrowserWindow.swift     # Cross-project browser (Surface B)
    ProjectStackView.swift  # "All projects" card stack (Surface B content column)
    PlanDetailView.swift    # Plan detail body (Surface B detail column)
    ProjectCard.swift       # Project summary card UI
    TaskStatus+Glance.swift # Status -> glance glyph/color vocabulary
    TaskType+Glyph.swift    # Task type -> glyph vocabulary
  Tests/PlansTests/         # XCTest unit tests
  Resources/                # Info.plist, Plans.icns (app bundle assets)
  Tools/make-icon.swift     # Icon generation helper
  build.sh                  # Build release binary, assemble Plans.app, launch
  install.sh                # Build + install Plans.app into /Applications
  desktop-app-spec.md       # Self-contained build spec & data contracts
```

## Testing
- **Framework:** XCTest (`@testable import Plans`)
- **Location:** `Tests/PlansTests/` (`*Tests.swift`)
- **Run:** `swift test`
- **Conventions:** TDD; tests mirror plans-cc behavior (e.g. `TaskParser`
  mirrors `lib/parse-tasks.js`). Filesystem tests write fixtures into a unique
  per-test temp directory (UUID-named) created in `setUpWithError`.

## Key Patterns
- **Single shared store:** `PlansStore` is created once in `AppDelegate` and
  injected into every scene via `.environment(store)`. It is created in the
  delegate (not `.onAppear`) so the initial `startPolling()` load completes
  before the menu panel is first opened.
- **Live refresh:** `startPolling()` does an initial synchronous load, then a
  repeating timer keeps both surfaces fresh (~5s poll).
- **Selection-driven detail column:** the browser's `NavigationSplitView`
  detail column shows `PlanDetailView(rowID:)` keyed by `.id(selectedRowID)`;
  card and list rows set the shared `selectedRowID`, which is cleared via
  `BrowserViewModel.validSelection` when the row disappears.
- **Activation policy:** set to `.regular` so windows activate cleanly despite
  the `MenuBarExtra` accessory default.
- **Glyph/label vocabulary:** status and type rendering centralized in
  `TaskStatus+Glance.swift` and `TaskType+Glyph.swift`.

## Notes
- **Plan files are public** (the `plans` branch of a public repo). Never record
  other projects' names, paths, task ids/titles, transcript paths, or service
  URLs in a plan — use placeholders (`Client A`, `~/Work/client-a`,
  `<session-id>`) and `~` for home paths.
- No external package dependencies — pure SwiftPM + SwiftUI/AppKit.
- The app bundle (`Plans.app`) and `.build/` are gitignored and produced by
  `build.sh` / `install.sh`; the binary is symlinked for local dev (build.sh)
  and copied for install (install.sh) so the installed app is self-contained.
- `desktop-app-spec.md` is the authoritative spec, including the two plans-cc
  data contracts; consult it before changing parsing/registry logic.
