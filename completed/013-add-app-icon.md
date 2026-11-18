# Add App Icon

**ID:** 013
**Created:** 2026-06-05T12:10
**Type:** feature
**Status:** completed
**Branch:** feature/013-add-app-icon
**Completed:** 2026-06-05T12:45

## What
Add app icon. A white list glyph on colorful gradient background.

## Why
Adds value by giving the Plans app a distinctive Dock/Finder/app-switcher identity. Currently `Plans.app` ships with no `CFBundleIconFile`, so macOS shows a generic blank document icon. A white list glyph on a colorful gradient keeps visual language consistent with the menu-bar `list.bullet` icon already used in `MenuBarLabel.swift`.

## How
- [x] Step 1: Create `Tools/make-icon.swift` — a standalone, runnable Swift script (`#!/usr/bin/env swift`, AppKit) that draws the icon: a colorful diagonal gradient background (blue → purple → pink) with rounded-rect macOS-style corners and a centered white `list.bullet` SF Symbol glyph. It renders one PNG per required size and writes them into a temporary `Plans.iconset/` directory using the Apple-mandated names (`icon_16x16.png`, `icon_16x16@2x.png`, … `icon_512x512@2x.png`).
- [x] Step 2: Run the script to generate the `.iconset`, then convert it with `iconutil -c icns Plans.iconset -o Resources/Plans.icns`. Commit `Resources/Plans.icns` (the generator script stays in the repo so the icon is reproducible).
- [x] Step 3: Add `<key>CFBundleIconFile</key><string>Plans</string>` to `Resources/Info.plist`.
- [x] Step 4: Update `build.sh` to create `Plans.app/Contents/Resources/` and copy `Resources/Plans.icns` into it during the bundle assembly step.
- [x] Step 5: 👁 Run `./build.sh` and confirm the app launches with the new icon visible in the Dock / app switcher (Cmd-Tab) — verify the white list glyph reads clearly on the gradient.

## Verification
- `Resources/Plans.icns` exists and is a valid icns (`iconutil` produced it without error; `file Resources/Plans.icns` reports "Mac OS X icon").
- `Resources/Info.plist` contains the `CFBundleIconFile` → `Plans` key.
- After `./build.sh`, `Plans.app/Contents/Resources/Plans.icns` exists.
- The Dock / Cmd-Tab app switcher shows the colorful-gradient white-list-glyph icon (manual visual check).

## Impact Scope

### Files to Modify
- [ ] `Resources/Info.plist` — add `CFBundleIconFile` key
- [ ] `build.sh` — create `Contents/Resources/` and copy the `.icns` into the bundle

### Files to Create
- [ ] `Tools/make-icon.swift` — programmatic icon generator (reproducible source)
- [ ] `Resources/Plans.icns` — the generated icon (binary, committed)

### UI Affected
- macOS Dock icon, Finder icon, and Cmd-Tab app switcher entry for `Plans.app`

## Assumptions

### Initial (from elaboration)
- [low] Generate the icon programmatically via a standalone Swift/AppKit script (`Tools/make-icon.swift`) rather than a SwiftUI `ImageRenderer` build phase or a hand-authored asset. **Why:** No external design tools are available; a script keeps the icon reproducible and avoids coupling icon generation into `swift build`. The menu bar already renders its glyph programmatically, so this matches the project's existing approach.
- [low] Gradient palette = diagonal blue → purple → pink; glyph = white `list.bullet` SF Symbol matching the menu bar. **Why:** Task says "colorful gradient" without specifying colors; this is a vivid, distinctive default that reads in both light/dark Dock backgrounds and stays consistent with the existing `list.bullet` menu-bar icon.
- [low] Commit the generated `Resources/Plans.icns` binary and have `build.sh` simply copy it, rather than regenerating the icon on every build. **Why:** Keeps `build.sh` fast and dependency-free (no Swift-script run in the hot build path); the generator script is committed so the icon can be regenerated deterministically when the design changes.
- [high] Use `CFBundleIconFile` = `Plans` (bare name, no extension) with the icns at `Contents/Resources/Plans.icns`. **Why:** Standard macOS bundle convention for a non-asset-catalog app; macOS resolves `Plans` → `Plans.icns` in `Contents/Resources` automatically.

### Discovered during execution
- [high] Used Apple's 10 mandated iconset filenames/sizes (`icon_16x16.png` … `icon_512x512@2x.png`, pixel sizes 16–1024) so `iconutil -c icns` accepts the set. **Why:** `iconutil` requires these exact names; this is fixed convention.
- [low] Gradient stops chosen as sRGB blue (0.20, 0.45, 0.98) → purple (0.55, 0.30, 0.95) → pink (0.98, 0.35, 0.70), drawn as a 3-color `NSGradient` at a 45° diagonal. **Why:** Task said "colorful gradient blue → purple → pink" without exact hues; these are vivid, evenly-spaced stops that read on light/dark Dock backgrounds.
- [low] Corner radius = 0.2237 × icon side via `NSBezierPath(roundedRect:)`. **Why:** Approximates the macOS Big Sur+ superellipse "squircle" ratio closely; a true superellipse path wasn't required by the task and a rounded rect is visually close at icon scale.
- [low] Glyph sized to 57% of the canvas using `NSImage.SymbolConfiguration(pointSize: side*0.57, weight: .semibold, scale: .large)`, tinted white via a `.sourceAtop` fill. **Why:** Task asked for ~55–60% and a "bold-ish, white" symbol; `.semibold` matches the menu bar's visual weight and the sourceAtop fill guarantees a solid white glyph regardless of the symbol's intrinsic rendering mode.
- [high] Rendered each PNG by drawing into an `NSBitmapImageRep`-backed `NSGraphicsContext` and exporting via `representation(using: .png)`. **Why:** Standard headless AppKit bitmap export; works without a window/screen, which a build-tool script needs.
- [low] Added the `### Discovered during execution` subsection under `## Assumptions` (the elaboration template had only an `### Initial` subsection and a separate `## Changes` placeholder). **Why:** The segment instructions referenced a `### Discovered during execution` subsection that did not yet exist; created it to record execution-time decisions as directed.

## Changes
- Added `Tools/make-icon.swift`: standalone AppKit icon generator. Draws a full-bleed rounded-rect (0.2237 corner ratio) with a 45° blue→purple→pink `NSGradient` and a centered white `list.bullet` SF Symbol (~57%, `.semibold`), emitting all 10 mandated iconset PNGs (16–1024px) to a configurable output dir.
- Added `Resources/Plans.icns`: generated icon (via the script + `iconutil -c icns`). Verified `file` reports "Mac OS X icon". Visually confirmed: white list glyph on colorful gradient with rounded corners.
- Modified `Resources/Info.plist`: added `CFBundleIconFile` → `Plans`.
- Modified `build.sh`: bundle assembly now `mkdir -p`s `Plans.app/Contents/Resources/` and copies `Resources/Plans.icns` into it.
- Step 5 (visual Dock confirmation) performed at `/plan-review`. First render was too large and too vivid; revised `make-icon.swift`: inset the squircle tile to 80% of the canvas (native macOS bounding-box convention), reduced the glyph to 46% of the tile for more padding, and toned the gradient down to a subtle dark blue→plum. Regenerated `Resources/Plans.icns`. User confirmed the revised Dock icon looks good.

## Notes
Tools `sips`, `iconutil`, and `swift` are all confirmed present on this system. App is built via SwiftPM + manual `build.sh` bundle assembly (no Xcode project / asset catalog). Menu-bar glyph reference: `Sources/Plans/MenuBarLabel.swift` uses `Image(systemName: "list.bullet")`.
