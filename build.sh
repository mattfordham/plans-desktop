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

# Symlink the release executable into the bundle (simplest for local dev;
# `open Plans.app` works fine with a symlinked binary for unsigned apps).
ln -sf "$(pwd)/.build/release/Plans" "$APP/Contents/MacOS/Plans"

# Launch the app.
open "$APP"
