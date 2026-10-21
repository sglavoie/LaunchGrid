#!/bin/sh
# Builds LaunchGrid.app and installs it into /Applications, replacing any older copy.
# Usage: scripts/install.sh [--no-open]   (INSTALL_DIR overrides /Applications)
set -eu
cd "$(dirname "$0")/.."
OPEN=1
for arg in "$@"; do
    case "$arg" in
        --no-open) OPEN=0 ;;
        *) echo "Usage: scripts/install.sh [--no-open]" >&2; exit 2 ;;
    esac
done

DEST_DIR="${INSTALL_DIR:-/Applications}"
DEST="$DEST_DIR/LaunchGrid.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

scripts/bundle.sh release

# /Applications is writable for admin users; fall back to sudo otherwise. Create a missing
# INSTALL_DIR as the user first, so sudo only comes in when it's really needed.
mkdir -p "$DEST_DIR" 2>/dev/null || true
SUDO=""
if [ ! -w "$DEST_DIR" ] || { [ -e "$DEST" ] && [ ! -w "$DEST" ]; }; then
    SUDO="sudo"
fi
$SUDO mkdir -p "$DEST_DIR"

# Quit the installed copy so its bundle can be replaced (a scratch run keeps going).
scripts/quit-app.sh "$DEST"

# Stage beside the destination, then swap, so a failed copy never leaves a half-installed app.
STAGE="$DEST_DIR/.LaunchGrid.app.installing"
$SUDO rm -rf "$STAGE"
$SUDO ditto build/LaunchGrid.app "$STAGE"
$SUDO rm -rf "$DEST"
$SUDO mv "$STAGE" "$DEST"

# Point Finder's .appgrid handler at the installed copy rather than the build folder.
"$LSREGISTER" -u build/LaunchGrid.app >/dev/null 2>&1 || true
"$LSREGISTER" -f "$DEST"
echo "Installed $DEST"

if [ "$OPEN" -eq 1 ]; then
    open "$DEST"
fi
