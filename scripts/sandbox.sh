#!/bin/sh
# Bundles with the Mac App Store build's sandbox and runs it, with logs in the terminal. Its
# layout and settings live in its container; quit the installed copy first, or that one takes over.
# Usage: scripts/sandbox.sh [debug|release]
set -eu
cd "$(dirname "$0")/.."
APP=build/LaunchGrid.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
SANDBOX=1 scripts/bundle.sh "${1:-debug}"
trap '"$LSREGISTER" -u "$APP" >/dev/null 2>&1' EXIT
trap 'exit 130' INT TERM
"$APP/Contents/MacOS/LaunchGrid"
