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
# Rerunning after a failed cask update keeps the release that is already there, as long as its
# zip is this one: the cask's sha256 has to match what Homebrew downloads.
if gh release view "v$VERSION" >/dev/null 2>&1; then
    REMOTE_DIR="$(mktemp -d)"
    trap 'rm -rf "$REMOTE_DIR"' EXIT
    gh release download "v$VERSION" --pattern LaunchGrid.zip --dir "$REMOTE_DIR" \
        || { echo "Release v$VERSION exists but its LaunchGrid.zip couldn't be downloaded." >&2; exit 1; }
    REMOTE_SHA="$(shasum -a 256 "$REMOTE_DIR/LaunchGrid.zip" | cut -d' ' -f1)"
    if [ "$REMOTE_SHA" != "$SHA" ]; then
        echo "Release v$VERSION already exists with a different LaunchGrid.zip" >&2
        echo "(sha256 $REMOTE_SHA there, $SHA here). Bump VERSION in scripts/bundle.sh," >&2
        echo "commit, push, then run just release and just publish again." >&2
        exit 1
    fi
    echo "Release v$VERSION already exists with this zip; updating the cask only."
else
    gh release create "v$VERSION" "$ZIP" --target "$COMMIT" --title "LaunchGrid $VERSION" --notes "$NOTES"
fi

git -C "$TAP_DIR" pull -q --ff-only
# Through a temporary file: scripts get BSD sed, whose -i takes a different argument from GNU's.
sed -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK" > "$CASK.tmp"
mv "$CASK.tmp" "$CASK"
# A rerun after a failed push finds the cask already committed: push what is there.
if ! git -C "$TAP_DIR" diff --quiet HEAD -- Casks/launchgrid.rb; then
    git -C "$TAP_DIR" commit -q -m "launchgrid $VERSION" Casks/launchgrid.rb
fi
git -C "$TAP_DIR" push -q
echo "Published v$VERSION; the cask now installs it (brew upgrade --cask launchgrid)."
