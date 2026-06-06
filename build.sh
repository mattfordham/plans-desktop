#!/usr/bin/env bash
set -euo pipefail

# Run from the script's own directory so relative paths are stable.
cd "$(dirname "${BASH_SOURCE[0]}")"

APP="Plans.app"

# Build the release binary.
swift build -c release

# Recreate the .app bundle cleanly each run.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Copy the static Info.plist into the bundle.
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Copy the app icon into the bundle's Resources directory. CFBundleIconFile in
# Info.plist points at "Plans", which macOS resolves to Plans.icns here.
mkdir -p "$APP/Contents/Resources"
cp Resources/Plans.icns "$APP/Contents/Resources/Plans.icns"

# Build the work-task Agent SDK tool (Node) and bundle it into the .app so the
# app can hand a task off to it at runtime. Produces Tools/work-task/dist/
# (run-task.js plus a minimal node_modules), copied into
# Contents/Resources/work-task/.
(
  cd Tools/work-task
  npm install
  npm run build
)
cp -R Tools/work-task/dist "$APP/Contents/Resources/work-task"

# COPY (do not symlink) the release executable into the bundle. A symlinked
# binary still launches, but macOS resolves the symlink target to locate the
# bundle, so `Bundle.main` points at .build/release/ instead of Plans.app —
# which breaks `Bundle.main.url(forResource:…)` lookups for the bundled
# work-task/run-task.js (TaskRunner can't find the script and silently aborts).
# Copying keeps the executable inside Contents/MacOS so Bundle.main resolves to
# the .app and the bundled resources are found.
cp "$(pwd)/.build/release/Plans" "$APP/Contents/MacOS/Plans"

# Launch the app.
open "$APP"
