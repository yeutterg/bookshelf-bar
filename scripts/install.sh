#!/bin/zsh
# Builds KEFBar.app, installs it to /Applications and relaunches it.
# Installing in place (rather than running from build/) lets Launch Services announce each new
# binary, so macOS re-applies the existing Local Network approval to it.
set -euo pipefail
cd "${0:A:h}/.."
scripts/bundle.sh "${1:-release}"
pkill -x KEFBar 2>/dev/null || true
ditto build/KEFBar.app /Applications/KEFBar.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/KEFBar.app
open /Applications/KEFBar.app
echo "Installed /Applications/KEFBar.app"
