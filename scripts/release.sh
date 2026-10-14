#!/bin/zsh
# Builds a distributable BookshelfBar-<version>.dmg: universal app, Developer ID signed,
# notarized and stapled when credentials are available.
#   VERSION=0.2.0 scripts/release.sh
# Environment (all optional; without them the DMG is built but not notarized):
#   SIGN_IDENTITY        "Developer ID Application: SimpleBulb … (TEAMID)"
#   NOTARY_KEY_PATH      path to the App Store Connect API key (.p8)
#   NOTARY_KEY_ID        its key ID
#   NOTARY_ISSUER_ID     its issuer ID
set -euo pipefail
cd "${0:A:h}/.."
: ${VERSION:?set VERSION, e.g. VERSION=0.2.0}
export VERSION
UNIVERSAL=1 scripts/bundle.sh release

DMG=build/BookshelfBar-$VERSION.dmg
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto build/BookshelfBar.app "$STAGE/BookshelfBar.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "BookshelfBar" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [[ "${SIGN_IDENTITY:-}" == "Developer ID Application"* ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  if [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
    echo "Notarizing…"
    xcrun notarytool submit "$DMG" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
  else
    echo "warning: notary credentials not set; DMG is signed but not notarized" >&2
  fi
else
  echo "warning: no Developer ID identity; DMG is not distributable without Gatekeeper warnings" >&2
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Built $DMG"
