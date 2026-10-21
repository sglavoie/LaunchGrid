#!/bin/sh
# Quits the LaunchGrid running from one bundle and waits for it to go, forcing it after 5 s.
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
while pgrep -qf "$PATTERN" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if pgrep -qf "$PATTERN"; then
    pkill -KILL -f "$PATTERN" 2>/dev/null || true
    sleep 0.2
fi
