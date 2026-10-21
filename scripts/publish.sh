#!/bin/sh
# Publishes the build from release.sh: creates the GitHub release vVERSION at the commit it was
# built from, with build/release/LaunchGrid.zip, then points the Homebrew cask at it.
# Usage: scripts/publish.sh [release notes]
# TAP_DIR is a clone of github.com/sglavoie/homebrew-tap (default ../homebrew-tap).
set -eu
cd "$(dirname "$0")/.."
OUT_DIR="build/release"
APP="$OUT_DIR/LaunchGrid.app"
ZIP="$OUT_DIR/LaunchGrid.zip"
TAP_DIR="${TAP_DIR:-../homebrew-tap}"
CASK="$TAP_DIR/Casks/launchgrid.rb"

[ -f "$ZIP" ] && [ -f "$OUT_DIR/COMMIT" ] || { echo "No release build; run: just release" >&2; exit 1; }
xcrun stapler validate "$APP" >/dev/null || { echo "$APP has no notarisation ticket" >&2; exit 1; }
[ -f "$CASK" ] || { echo "No cask at $CASK; set TAP_DIR to your homebrew-tap clone" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
COMMIT="$(cat "$OUT_DIR/COMMIT")"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
NOTES="${1:-LaunchGrid $VERSION. Signed and notarised; macOS 14+, Apple silicon and Intel.}"

# The release commit has to be on GitHub, and the asset keeps its name so the website's
# releases/latest/download/LaunchGrid.zip link follows each release.
git fetch -q origin
git merge-base --is-ancestor "$COMMIT" origin/main || { echo "Push $COMMIT to origin first." >&2; exit 1; }
gh release create "v$VERSION" "$ZIP" --target "$COMMIT" --title "LaunchGrid $VERSION" --notes "$NOTES"

git -C "$TAP_DIR" pull -q --ff-only
sed -i -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
git -C "$TAP_DIR" commit -q -m "launchgrid $VERSION" Casks/launchgrid.rb
git -C "$TAP_DIR" push -q
echo "Published v$VERSION; the cask now installs it (brew upgrade --cask launchgrid)."
