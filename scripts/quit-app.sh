#!/bin/sh
# Quits the LaunchGrid running from one bundle and waits for it to go. If it is still running
# after 10 s (asking whether to quit although its layout couldn't be saved, say), it fails
# instead of forcing it, which would lose the changes that question is about.
# Copies running from elsewhere (a `just scratch` run from build/) are left alone.
# Usage: scripts/quit-app.sh [path/to/LaunchGrid.app]   (default /Applications/LaunchGrid.app)
set -eu
APP="${1:-/Applications/LaunchGrid.app}"
# Match the executable path exactly: escape regex characters and anchor it to the command.
EXE="$(printf '%s' "$APP/Contents/MacOS/LaunchGrid" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
PATTERN="^$EXE( |\$)"

pgrep -qf "$PATTERN" || exit 0
# LaunchGrid treats SIGTERM as a normal quit, saving its layout first.
pkill -TERM -f "$PATTERN" 2>/dev/null || true
i=0
while pgrep -qf "$PATTERN" && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if pgrep -qf "$PATTERN"; then
    echo "LaunchGrid ($APP) is still running: it may be asking whether to quit without saving." >&2
    echo "Answer it (or quit it yourself), then run this again." >&2
    exit 1
fi
