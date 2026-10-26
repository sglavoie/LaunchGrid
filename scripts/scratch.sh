#!/bin/sh
# Runs build/LaunchGrid.app against a throwaway layout and separate settings, with logs in the
# terminal, beside the installed copy. Bundle it first (`just scratch` does).
# Usage: scripts/scratch.sh
set -eu
cd "$(dirname "$0")/.."
APP=build/LaunchGrid.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DIR="$(mktemp -d)"
# Launching registers the build copy with Launch Services; hand .launchgrid files back to
# the installed copy afterwards, and drop the throwaway layout.
cleanup() { "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true; rm -rf "$DIR"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
LAUNCHGRID_DATA_DIR="$DIR" "$APP/Contents/MacOS/LaunchGrid"
