#!/bin/zsh
# Builds KEFBar.app from the Swift package. usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "${0:A:h}/.."
CONFIG=${1:-release}
VERSION=${VERSION:-0.1.0}

swift build -c "$CONFIG" --product KEFBar
BIN=$(swift build -c "$CONFIG" --show-bin-path)

APP=build/KEFBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/KEFBar" "$APP/Contents/MacOS/KEFBar"
# SwiftPM resource bundle (speaker artwork); Bundle.module finds it in Contents/Resources.
cp -R "$BIN/KEFBar_KEFBar.bundle" "$APP/Contents/Resources/"
sed "s/__VERSION__/$VERSION/" Resources/Info.plist > "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS keeps permissions (Local Network) stable between builds.
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"
