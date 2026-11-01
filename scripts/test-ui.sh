#!/bin/sh
# Run fixture-based regressions against the bundled UI in a logged-in macOS session.
# Usage: scripts/test-ui.sh [--no-build] [scenario.json]
set -eu
cd "$(dirname "$0")/.."

BUILD=1
if [ "${1:-}" = --no-build ]; then BUILD=0; shift; fi
if [ "$#" -gt 1 ]; then
    echo "usage: $0 [--no-build] [scenario.json]" >&2
    exit 2
fi
TIMEOUT="${UI_TEST_TIMEOUT:-60}"
case "$TIMEOUT" in ''|*[!0-9]*|0) echo 'UI_TEST_TIMEOUT must be a positive integer.' >&2; exit 2 ;; esac
if [ "$BUILD" = 1 ]; then
    env -u APP_STORE -u SANDBOX -u ENTITLEMENTS -u PROVISIONING_PROFILE scripts/bundle.sh debug
fi
APP="$PWD/build/LaunchGrid.app"
if [ ! -x "$APP/Contents/MacOS/LaunchGrid" ]; then
    echo 'Bundle LaunchGrid first, or omit --no-build.' >&2
    exit 1
fi
if ! strings -a "$APP/Contents/MacOS/LaunchGrid" | grep -q 'LAUNCHGRID_DEBUG_UI_TEST'; then
    echo 'This bundle has no UI test driver (the App Store variant compiles it out). Omit --no-build.' >&2
    exit 1
fi
if [ "$#" = 0 ]; then set -- scripts/ui-tests/*.json; fi

WORK="$PWD/build/ui-tests/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$WORK"
CHILD=''
DOMAIN=''
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
clear_defaults() {
    if [ -n "$DOMAIN" ]; then
        defaults delete "$DOMAIN" >/dev/null 2>&1 || true
        # macOS can keep an empty plist after deleting a domain, which `defaults delete`
        # subsequently reports as missing. This UUID belongs only to this test process.
        rm -f "$HOME/Library/Preferences/$DOMAIN.plist"
    fi
}
cleanup() {
    if [ -n "$CHILD" ]; then
        kill -KILL "$CHILD" 2>/dev/null || true
        wait "$CHILD" 2>/dev/null || true
    fi
    clear_defaults
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

FAILED=0
for SCENARIO in "$@"; do
    NAME="$(basename "$SCENARIO" .json)"
    DIR="$WORK/$NAME"
    mkdir -p "$DIR/data"
    if [ ! -f "$SCENARIO" ]; then
        echo "FAIL: missing scenario $SCENARIO" >&2
        FAILED=$((FAILED + 1))
        continue
    fi
    cp "$SCENARIO" "$DIR/scenario.json"
    DOMAIN="com.sglavoie.launchgrid.uitest.$(uuidgen)"
    echo "Running ${NAME}..."
    env -u LAUNCHGRID_DEBUG_SCRIPT -u LAUNCHGRID_DEBUG_SCAN_HANG -u LAUNCHGRID_DEBUG_SCAN_TIMEOUT \
        LAUNCHGRID_DATA_DIR="$DIR/data" LAUNCHGRID_DEBUG_DEFAULTS="$DOMAIN" \
        LAUNCHGRID_DEBUG_DIR="$DIR" LAUNCHGRID_DEBUG_UI_TEST="$DIR/scenario.json" \
        "$APP/Contents/MacOS/LaunchGrid" >"$DIR/run.log" 2>&1 &
    CHILD=$!
    ELAPSED=0
    while kill -0 "$CHILD" 2>/dev/null && [ "$ELAPSED" -lt "$TIMEOUT" ]; do
        sleep 1
        ELAPSED=$((ELAPSED + 1))
    done
    if kill -0 "$CHILD" 2>/dev/null; then
        echo "FAIL: $NAME timed out after ${TIMEOUT}s" | tee "$DIR/timeout.txt" >&2
        # A hung event loop cannot take an in-process snapshot. Its logs and scenario remain.
        kill -KILL "$CHILD" 2>/dev/null || true
    fi
    STATUS=0
    wait "$CHILD" || STATUS=$?
    CHILD=
    clear_defaults
    DOMAIN=
    if [ "$STATUS" = 0 ] && [ -f "$DIR/result.json" ] &&
        [ "$(plutil -extract status raw -o - "$DIR/result.json" 2>/dev/null)" = passed ]; then
        tail -1 "$DIR/run.log"
    else
        FAILED=$((FAILED + 1))
        echo "FAIL: $NAME (exit $STATUS). Artifacts: $DIR" >&2
        tail -12 "$DIR/run.log" >&2
    fi
done
echo "UI test artifacts: $WORK"
if [ "$FAILED" -ne 0 ]; then
    echo "$FAILED UI scenario(s) failed." >&2
    exit 1
fi
