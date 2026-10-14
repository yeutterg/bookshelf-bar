#!/bin/zsh
# Builds BookshelfBar.app from the Swift package.
#   scripts/bundle.sh [debug|release]
# Environment:
#   VERSION        version string for Info.plist (default 0.1.0)
#   UNIVERSAL=1    build for Apple silicon and Intel
#   SIGN_IDENTITY  codesigning identity; "Developer ID Application: …" enables the hardened
#                  runtime and a secure timestamp (both required for notarization). Defaults to
#                  a local Apple Development identity, then ad-hoc.
set -euo pipefail
cd "${0:A:h}/.."
CONFIG=${1:-release}
VERSION=${VERSION:-0.1.0}
ARCH_FLAGS=()
[[ "${UNIVERSAL:-0}" == 1 ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --product BookshelfBar
BIN=$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)

APP=build/BookshelfBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/BookshelfBar" "$APP/Contents/MacOS/BookshelfBar"
# SwiftPM resource bundle (speaker artwork); Bundle.module finds it in Contents/Resources.
cp -R "$BIN/BookshelfBar_BookshelfBar.bundle" "$APP/Contents/Resources/"
sed "s/__VERSION__/$VERSION/" Resources/Info.plist > "$APP/Contents/Info.plist"

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}
if [[ "$IDENTITY" == "Developer ID Application"* ]]; then
  # Distribution signing: hardened runtime + secure timestamp, inside-out.
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/BookshelfBar_BookshelfBar.bundle"
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
else
  # Local builds: a stable identity keeps permissions like Local Network across rebuilds.
  codesign --force --sign "${IDENTITY:--}" --timestamp=none "$APP"
fi
codesign --verify --strict "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP ($VERSION)"
