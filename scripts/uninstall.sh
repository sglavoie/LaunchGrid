#!/bin/sh
# Removes the login item, quits and deletes the installed app; the layout and settings are kept.
# Usage: scripts/uninstall.sh   (INSTALL_DIR overrides /Applications)
set -eu
cd "$(dirname "$0")/.."
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DEST="$INSTALL_DIR/LaunchGrid.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ ! -e "$DEST" ]; then
    echo "Nothing installed at $DEST"
    exit 0
fi
# The login item belongs to the bundle, so drop it while the bundle is still there. A copy
# from before --unregister-login-item would just start up instead, so only ask one that has it.
BIN="$DEST/Contents/MacOS/LaunchGrid"
if ! { grep -qaF -- --unregister-login-item "$BIN" && "$BIN" --unregister-login-item; }; then
    echo "If LaunchGrid opened at login, remove it in System Settings › General › Login Items."
fi
scripts/quit-app.sh "$DEST"
"$LSREGISTER" -u "$DEST" >/dev/null 2>&1 || true
# As the user first: a writable folder can still hold a bundle owned by root (a Mac App Store
# copy), which only sudo can remove.
if ! rm -rf "$DEST" 2>/dev/null; then
    sudo rm -rf "$DEST"
fi
echo "Removed $DEST"
