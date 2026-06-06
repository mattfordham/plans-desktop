#!/usr/bin/env bash
set -euo pipefail

# Run from the script's own directory so relative paths are stable.
cd "$(dirname "${BASH_SOURCE[0]}")"

APP="Plans.app"
# Install destination. Override with: DEST_DIR=~/Applications ./install.sh
DEST_DIR="${DEST_DIR:-/Applications}"
DEST="$DEST_DIR/$APP"

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

# Copy (do NOT symlink) the release executable into the bundle so the app is
# self-contained and keeps working once moved out of this repo.
cp .build/release/Plans "$APP/Contents/MacOS/Plans"

# Install into the destination, replacing any prior copy.
mkdir -p "$DEST_DIR"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo "Installed $APP to $DEST"
echo "Launch it from Spotlight/Launchpad, or run: open \"$DEST\""
