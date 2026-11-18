# Scaffold native macOS Swift app (menu bar + window)

**ID:** 001
**Created:** 2026-06-04T14:41
**Type:** chore
**Status:** completed
**Completed:** 2026-06-04T15:10
**Branch:** chore/001-scaffold-macos-swift-app
**Source:** Imported from desktop-app-spec.md

## What
Create the project in a **separate directory** from plans-cc. Native macOS, written in **Swift**. Form factor: a menu bar item (Surface A) plus a window (Surface B). This is personal tooling for a single developer — **not** a shipped product. Built/installed separately from the plans-cc npm package (do not bundle into `npx plans-cc`). **No code-signing or notarization required.** Establish the app skeleton: app lifecycle, menu bar status item, and an empty browser window that the menu bar can open.

Spec references: §3 (Platform & Distribution), §1 (the two surfaces).

## Why
Adds value by establishing the buildable app skeleton — app lifecycle, a menu bar status item, and an empty window the menu bar can open — that every subsequent task (registry reader, parser, glance, browser) builds on. Without a working shell there is nothing to attach data and views to.

## How
- [x] Step 1: Create `Package.swift` (`swift-tools-version:6.0`, `platforms: [.macOS(.v15)]`, single `.executableTarget` named `Plans`, no dependencies) and the `Sources/Plans/` directory.
- [x] Step 2: Add `Sources/Plans/PlansApp.swift` — the `@main struct PlansApp: App` with a `MenuBarExtra("Plans", systemImage: "list.bullet")` scene (Surface A) and a `Window("Plans", id: "browser")` scene (Surface B). Hold the status item content in `MenuBarView` and the window content in `BrowserWindow`.
- [x] Step 3: Add `Sources/Plans/MenuBarView.swift` — menu content with an "Open Browser" button that calls `@Environment(\.openWindow) openWindow(id: "browser")`, a divider, and a "Quit" button (`NSApplication.shared.terminate(nil)`).
- [x] Step 4: Add `Sources/Plans/BrowserWindow.swift` — an empty placeholder view (e.g. "Browser (placeholder)") with a sensible `minWidth`/`minHeight`. No data reading — that is task 002+.
- [x] Step 5: Set the activation policy so the opened window comes to the front and receives focus — call `NSApp.setActivationPolicy(.regular)` (e.g. via an `AppDelegate` adapter or `.onAppear`/openWindow side-effect) and `NSApp.activate(ignoringOtherApps: true)` when opening the browser window. (A `MenuBarExtra` app otherwise defaults toward accessory behavior where the window may not activate cleanly.)
- [x] Step 6: Add a static `Info.plist` (in repo, e.g. `Resources/Info.plist`) with `CFBundleExecutable=Plans`, `CFBundleIdentifier=local.plans-cc.viewer`, `CFBundleName=Plans`, `CFBundlePackageType=APPL`, `NSPrincipalClass=NSApplication`, `LSMinimumSystemVersion=15.0`, `NSHighResolutionCapable=true`. Leave `LSUIElement` unset (`0`) so both the status item and the window work.
- [x] Step 7: Add `build.sh` (executable) that runs `swift build -c release`, creates `Plans.app/Contents/MacOS`, copies the Info.plist into `Plans.app/Contents/`, symlinks `.build/release/Plans` into `Plans.app/Contents/MacOS/Plans`, and `open Plans.app`. The generated `.app` is not committed.
- [x] Step 8: Update `.gitignore` to ignore `.build/` and `Plans.app/` (keep the existing `.plans` line).
- [x] 👁 Step 9: Build and launch (`./build.sh`); confirm the status item appears in the menu bar, "Open Browser" opens and focuses the empty window, and "Quit" exits cleanly.

## Verification
1. `swift build -c release` succeeds with no errors.
2. `./build.sh` produces `Plans.app` and launches it.
3. A status item appears in the macOS menu bar (Surface A); clicking "Open Browser" opens and brings forward the empty window (Surface B); "Quit" terminates the app.
4. No `.plans/` directory is read or written (this task is shell-only).

## Impact Scope
_Net-new project scaffold; no existing files modified except `.gitignore`. Skipped — fewer than 3 existing files touched._

## Changes
- Created `Package.swift` (swift-tools 6.0, `.macOS(.v15)`, single `.executableTarget` `Plans`, no deps).
- Created `Sources/Plans/PlansApp.swift` (`@main` App with `MenuBarExtra` + `Window("Plans", id: "browser")`).
- Created `Sources/Plans/MenuBarView.swift` ("Open Browser" → `openWindow(id:)`, divider, "Quit").
- Created `Sources/Plans/BrowserWindow.swift` (placeholder view, 720×480 min size).
- `swift build` (debug) succeeds — all sources compile cleanly.
- Added `AppDelegate` (`@NSApplicationDelegateAdaptor`) setting `.regular` policy at launch; `NSApp.activate(ignoringOtherApps:)` after `openWindow`.
- Created `Resources/Info.plist` with required bundle keys (`LSUIElement` explicit `false`).
- Created `build.sh` (executable): release build → assemble `Plans.app` → symlink binary → `open`.
- Updated `.gitignore` to add `.build/` and `Plans.app/` (kept `.plans`).
- `./build.sh` produced `Plans.app` (release build, bundle assembled, binary symlinked) and launched it; user confirmed status item, Open Browser window focus, and clean Quit.

## Assumptions

### Discovered during execution
- [high] `MenuBarView` returns the menu items (Button/Divider/Button) directly as the `MenuBarExtra` content rather than wrapping them in a container view. **Why:** `MenuBarExtra`'s default (menu) style composes its content as menu commands; wrapping in a `VStack` would render an unwanted inline panel.
- [low] Browser window placeholder sized at `minWidth: 720, minHeight: 480`. **Why:** No size specified in the plan; 720x480 is a sensible roomy default for a future cross-project browser, large enough to be useful while remaining resizable.
- [high] Did not add an `@NSApplicationDelegateAdaptor` yet. **Why:** The segment instructs Steps 5+ are out of scope; the current sources compile cleanly without a delegate, and `PlansApp` is structured so an adaptor can be added without restructuring.
- [high] Step 5: Used an `AppDelegate: NSObject, NSApplicationDelegate` wired via `@NSApplicationDelegateAdaptor` that calls `NSApp.setActivationPolicy(.regular)` in `applicationDidFinishLaunching`, plus `NSApp.activate(ignoringOtherApps: true)` after `openWindow(id:)` in the "Open Browser" action. **Why:** The plan's recommended approach; sets the policy once at launch rather than per-window side-effect, keeping activation logic localized to the open action.
- [low] Step 6: Explicitly set `LSUIElement` to `<false/>` in Info.plist rather than omitting the key. **Why:** The plan says leave it "unset (`0`)"; an explicit `false` is equivalent to `0` and makes the intent (Dock icon + window visible) self-documenting.
- [high] Step 7: `build.sh` symlinks `.build/release/Plans` into the bundle (per plan), recreates `Plans.app` cleanly each run via `rm -rf`, uses `set -euo pipefail`, and `cd`s to the script's own directory. **Why:** Matches the elaboration's symlink choice (simplest for local dev; `open` works on symlinked unsigned binaries) and the segment's robustness requirements.

## Notes
_Imported from desktop-app-spec.md_

Elaboration decisions (confirmed with user):
- **App shell:** SwiftUI `MenuBarExtra` + `Window`, window opened via `@Environment(\.openWindow)` (over AppKit `NSStatusItem`).
- **App name:** `Plans` — executable/target `Plans`, `Sources/Plans/`, bundle id `local.plans-cc.viewer`.
- **Bundling:** `build.sh` script generates the `.app`; the bundle is gitignored, not committed.
- **Activation policy:** `.regular` (Dock icon + status item + activatable window); `LSUIElement` left unset.
