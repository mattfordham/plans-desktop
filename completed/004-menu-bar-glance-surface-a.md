# Surface A — menu bar glance with per-project status counts

**ID:** 004
**Created:** 2026-06-04T14:41
**Type:** feature
**Status:** completed
**Completed:** 2026-06-04T16:25
**Branch:** feature/004-menu-bar-glance-surface-a
**Source:** Imported from desktop-app-spec.md

## What
The 20,000-foot view. A macOS menu bar item giving an at-a-glance summary across every known project without opening a window. Per project show:

- The project's name (last path component of the project root).
- A breakdown of task counts **by status** rendered compactly using the glyph/label vocabulary (§6), e.g. `my-app — 🔨2 🟡1 ⚪5`.

Counts and status only — not task bodies. The six statuses must be visually distinguishable (emoji glyphs, SF Symbols, colored dots, or badge counts — your choice). Clicking a project (or an "Open browser" affordance) should **drill down** into the browser window (Surface B), pre-focused on that project.

Spec references: §1 (Surface A), §6 (Glance Vocabulary).

## Why
Adds value by delivering the spec's primary "20,000-foot" entry point (§1, §8.4): a glance at all registered projects' task status from the menu bar, without opening a window or `cd`-ing into each repo. This is the first user-facing surface — #002/#003 built the read layer (`RegistryReader`, `TaskParser`) but nothing yet renders it. It also establishes the shared app-state seam that #005 (browser) and #006 (live-update) plug into.

## How
- [x] Step 1: Add a shared `@Observable` store `PlansStore` (new file `Sources/Plans/PlansStore.swift`) holding `projects: [ProjectTasks]` and `selectedProjectPath: String?`. Give it a `reload()` that runs `RegistryReader().readProjects()` → `TaskParser().parseProject(at:)` for each live project, reusing the existing readers verbatim (no new parsing). `selectedProjectPath` is the drill-down handoff seam #005 will read; `reload()` is the seam #006 will drive reactively.
- [x] Step 2: Add a `glanceColor` (color intent) mapping for the six statuses on `TaskStatus` (new extension in `TaskParser.swift` or a small `TaskStatus+Glance.swift`), mapping to the §6 color column: in-progress→blue, in-review/review→yellow, elaborated→teal, pending→gray, completed→green. Iterate via `TaskStatus.allCases` for a stable order. (SF Symbols + colored dots chosen over emoji per §6's "your choice".)
- [x] Step 3: Build the glance rows in `MenuBarView.swift` — inject `PlansStore`, `ForEach(store.projects)` rendering one row per project: project name (`ProjectTasks.projectName`) plus, for each status with a non-zero count in `ProjectTasks.counts`, a colored dot (`Image(systemName: "circle.fill")` tinted with `glanceColor`) followed by the count. Omit zero-count statuses. Show an empty/"no tasks" affordance for a project with no counts, and a "No projects" state when `store.projects` is empty (§4.4 / §8.1).
- [x] Step 4: Make each project row tappable to drill down — on tap set `store.selectedProjectPath = project.projectPath`, then `openWindow(id: "browser")` and `NSApp.activate(...)` (mirroring the existing "Open Browser" button). Keep the existing "Open Browser" (no pre-focus) and "Quit" buttons below a `Divider`. Note: interactive custom rows in a `MenuBarExtra` may need `.menuBarExtraStyle(.window)` on the scene in `PlansApp.swift` — apply it if the default menu style won't render tappable dotted rows cleanly.
- [x] Step 5: Wire the store into the app — create it in `PlansApp` (`@State private var store = PlansStore()`), inject via `.environment(store)` so both `MenuBarView` and (later) `BrowserWindow` can read it, and call `store.reload()` once at launch (e.g. in `AppDelegate.applicationDidFinishLaunching` or `.task` on the menu content). Continuous live refresh is explicitly deferred to #006 — a one-shot load is sufficient for #004.
- [x] 👁 Step 6: Build and launch the app (`./build.sh` then open `Plans.app`) and confirm the menu bar item shows real per-project glance lines with distinguishable colored dots + counts, and that clicking a project opens the browser window. (Requires running the GUI app — the agent cannot observe the menu bar.)

## Verification
1. `swift build` and `swift test` pass (existing `RegistryReader`/`TaskParser` tests stay green; no writes to any `.plans/` dir — read-only constraint §2/§8.7 upheld).
2. The menu bar glance shows one line per live project with its name and colored-dot counts broken down by status, omitting zero-count statuses, and the six statuses are visually distinguishable (§8.4, §6).
3. With no registry / empty / corrupt registry the menu shows "No projects" and does not crash (§4.4, §8.1).
4. Clicking a project sets `selectedProjectPath` and opens the browser window (drill-down handoff present for #005); "Open Browser" and "Quit" still work.

## Assumptions

### Discovered during execution
- [low] Rendered the per-project glance row as an `HStack(spacing: 8)` with project name, then per-status `HStack(spacing: 2)` of a `circle.fill` dot (`.font(.system(size: 7))`) + count text. **Why:** The task left dot-row layout/spacing/sizing unspecified; chose compact spacing and a small fixed dot size so multiple status badges read as a tight inline cluster in the menu. Tunable in the step-6 observation.
- [low] Used "no tasks" (muted `.secondary`) for a project whose counts are all zero/absent, and "No projects" for an empty store. **Why:** The task named the "No projects" wording but left the per-project empty affordance to me; "no tasks" mirrors the spec's vocabulary and stays consistent.
- [low] Suspect `.menuBarExtraStyle(.window)` will be needed in `PlansApp.swift` for step 4 (tappable custom dotted rows render cleanly under the window style, not the default menu style). Did NOT change the scene style this segment (per instruction it belongs to step 4/5); current rows render as non-interactive content under the default menu style. **Why:** Default `MenuBarExtra` menu style is geared to standard menu items; custom interactive `HStack` rows typically need `.window`.
- [low] Made `PlansStore` a `final class` with `@Observable` and marked the injected `registryReader`/`taskParser` with `@ObservationIgnored`. **Why:** The readers are immutable dependencies, not observable state; ignoring them keeps observation focused on `projects`/`selectedProjectPath`.
- [high] Wired `PlansStore` into `PlansApp` (`@State private var store`, `.environment(store)` on both scenes, `.onAppear { store.reload() }` on the menu content). **Why:** `MenuBarView`'s `@Environment(PlansStore.self)` requires the store in the environment to function; this is the step-5 wiring and is the established SwiftUI injection pattern. Noted as a deviation since the segment scope nominally listed only `MenuBarView.swift` as modified.
- [high] Applied `.menuBarExtraStyle(.window)` to the `MenuBarExtra` scene (step 4). **Why:** The default `.menu` style does not reliably render/handle custom tappable `HStack` rows; the `.window` style makes the dotted rows a real tappable panel, which is what the drill-down requires.
- [high] Made each project row a `Button` with `.buttonStyle(.plain)` (rather than `.onTapGesture`). **Why:** `Button` gives free keyboard/accessibility/hit-testing semantics; `.plain` keeps it visually a row, not a chrome button. Also added `.contentShape(Rectangle())` + `Spacer` so the whole row width is the tap target. The Open Browser / Quit actions are also `Button(.plain)` for consistent panel styling.
- [low] Chose a fixed panel width of `.frame(width: 280)` with `.padding()` inside a leading-aligned `VStack`. **Why:** The `.window` style is free-floating with no intrinsic width; 280pt comfortably fits a project name plus several status badges. Tunable in the step-6 observation.
- [high] The "Open Browser" button explicitly clears `store.selectedProjectPath = nil` before opening. **Why:** Clearer, predictable behavior — the top-level button opens the browser in its default cross-project state rather than inheriting a stale prior drill-down selection. Per-project rows set the path; the generic button clears it.
- [high] Moved the one-shot `reload()` out of `.onAppear` and into `AppDelegate.applicationDidFinishLaunching`; the `AppDelegate` now owns the `PlansStore` (`let store = PlansStore()`) and `PlansApp` reads it via `appDelegate.store`. **Why:** Under `.menuBarExtraStyle(.window)`, the menu content's `.onAppear` does not fire until the panel is first opened, so an `.onAppear` reload would leave the glance empty until first click. Loading in `applicationDidFinishLaunching` guarantees the glance is populated before first open, and owning the store on the delegate avoids any race over a late-injected reference. Still a single one-shot load (no timer/poller — live refresh deferred to #006).
- [low] Did not add an explicit hover highlight to rows beyond `Button(.plain)` defaults. **Why:** Keeping it minimal for the observation step; a hover affordance can be added later if the rows do not read as clickable.

## Changes
- Added `Sources/Plans/PlansStore.swift` — `@Observable final class PlansStore` with `projects: [ProjectTasks]`, `selectedProjectPath: String?`, and injectable-readers `reload()` (reuses `RegistryReader`/`TaskParser` verbatim).
- Added `Sources/Plans/TaskStatus+Glance.swift` — `TaskStatus.glanceColor` exhaustive switch mapping the six statuses to §6 colors.
- Rewrote `Sources/Plans/MenuBarView.swift` — `@Environment(PlansStore.self)`, per-project glance rows (name + non-zero-status colored dots + counts via `TaskStatus.allCases`), per-project "no tasks" affordance, "No projects" empty state; kept Open Browser / Quit.
- Wired `Sources/Plans/PlansApp.swift` — `@State private var store = PlansStore()`, `.environment(store)` on both scenes, `.onAppear { store.reload() }` on menu content (this is step 5's wiring, pulled forward).
- Tests: `Tests/PlansTests/PlansStoreTests.swift` (4) + `Tests/PlansTests/TaskStatusGlanceTests.swift` (6), all passing.
- Made each project row a tappable `Button(.plain)` (`drillInto`: sets `selectedProjectPath`, opens browser window, activates app); applied `.menuBarExtraStyle(.window)` with a 280pt padded panel. "Open Browser" (clears `selectedProjectPath`) + "Quit" kept below a `Divider`.
- Finalized store wiring: `AppDelegate` owns `PlansStore`, `PlansApp` reads `appDelegate.store`, and `reload()` runs once in `applicationDidFinishLaunching` (window-style content's `.onAppear` doesn't fire until first open). One-shot load — live refresh deferred to #006.
- Post-observation refinement (per user): glance colors + status order now match the plans-cc TUI dashboard verbatim. `glanceColor` uses the exact Gruvbox hex from `lib/render-dashboard.js` (via a new `Color(hex:)` helper); added `TaskStatus.glanceOrder` mirroring the dashboard's `STAT_CARDS` order and **excluding `completed`**, so finished tasks no longer appear in the menu bar. `MenuBarView`/`ProjectGlanceRow` iterate `glanceOrder` instead of `allCases`. `TaskStatusGlanceTests` updated to assert the TUI hex values + glance order.

## Notes
_Imported from desktop-app-spec.md_
