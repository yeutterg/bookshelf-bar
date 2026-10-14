#!/bin/zsh
# Builds BookshelfBar.app, installs it to /Applications and relaunches it.
# Installing in place (rather than running from build/) lets Launch Services announce each new
# binary, so macOS re-applies the existing Local Network approval to it.
set -euo pipefail
cd "${0:A:h}/.."
scripts/bundle.sh "${1:-release}"
pkill -x BookshelfBar 2>/dev/null || true
# The app used to be called KEF Bar; remove the old copy so only one runs.
pkill -x KEFBar 2>/dev/null || true
rm -rf /Applications/KEFBar.app
ditto build/BookshelfBar.app /Applications/BookshelfBar.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/BookshelfBar.app
open /Applications/BookshelfBar.app
echo "Installed /Applications/BookshelfBar.app"
