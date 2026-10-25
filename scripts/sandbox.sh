#!/bin/sh
# Bundles with the Mac App Store build's sandbox and runs it, with logs in the terminal. Quit the
# installed copy first, or that one takes over.
#
# Each run starts as a first launch, as App Review sees it: the container (layout, settings,
# bookmarks, saved state, caches) is set aside beforehand and put back when the app quits, so the
# welcome window shows and every setting is at its default. --keep runs against the container as it
# is instead, to check that something survives a relaunch. Open at Login is a system login item,
# outside the container: turn it off again before quitting if the run turned it on.
# Usage: scripts/sandbox.sh [--keep] [debug|release]
set -eu
cd "$(dirname "$0")/.."
APP=build/LaunchGrid.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
CONTAINER="$HOME/Library/Containers/com.sglavoie.launchgrid"
BACKUP="$HOME/Library/Application Support/LaunchGrid Sandbox Backup"

KEEP=0
CONFIG=debug
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        debug|release) CONFIG="$arg" ;;
        *) echo "Usage: scripts/sandbox.sh [--keep] [debug|release]" >&2; exit 2 ;;
    esac
done

# cfprefsd caches the container's settings, and would hand the old ones to the fresh run (or the
# fresh ones to the next) after the files under it change; restarting it drops that cache.
reload_prefs() { killall -u "$(id -un)" cfprefsd 2>/dev/null || true; }

# A run that was killed before it could clean up left its container and the real one aside.
restore() {
    if [ -e "$BACKUP" ]; then
        rm -rf "$CONTAINER"
        mv "$BACKUP" "$CONTAINER"
        reload_prefs
    fi
}

if pgrep -qx LaunchGrid; then
    echo "LaunchGrid is running: quit it first." >&2
    exit 1
fi
restore
SANDBOX=1 scripts/bundle.sh "$CONFIG"

cleanup() {
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1
    if [ "$KEEP" = 1 ]; then
        return
    fi
    if [ -e "$BACKUP" ]; then
        restore
    else
        # There was no container before this run.
        rm -rf "$CONTAINER"
        reload_prefs
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
if [ "$KEEP" = 0 ] && [ -e "$CONTAINER" ]; then
    mv "$CONTAINER" "$BACKUP"
    reload_prefs
    echo "Fresh container; the previous one is in $BACKUP until LaunchGrid quits."
fi
"$APP/Contents/MacOS/LaunchGrid"
