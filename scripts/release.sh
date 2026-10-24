#!/bin/sh
# Builds the downloadable LaunchGrid: universal, signed with Developer ID, notarised and
# stapled, zipped to build/release/LaunchGrid.zip for a GitHub release (see publish.sh).
# Usage: scripts/release.sh
# SIGN_IDENTITY defaults to the keychain's only "Developer ID Application" identity, by its
# hash: codesign can misread a name with accents. Notarisation reads a notarytool keychain
# profile (NOTARY_PROFILE, default "launchgrid"), stored once with:
#   xcrun notarytool store-credentials launchgrid --apple-id … --team-id …
set -eu
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-launchgrid}"
OUT_DIR="build/release"
APP="$OUT_DIR/LaunchGrid.app"
ZIP="$OUT_DIR/LaunchGrid.zip"

# The build number is the commit count, so uncommitted changes would ship under a used number.
if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash your changes first." >&2
    exit 1
fi

# Building and notarising takes minutes, and publish.sh would then refuse a version that is
# already released. Skipped without gh, which publish.sh needs anyway.
VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' scripts/bundle.sh)"
if command -v gh >/dev/null 2>&1 && gh release view "v$VERSION" >/dev/null 2>&1; then
    echo "Release v$VERSION already exists; bump VERSION in scripts/bundle.sh and commit first." >&2
    exit 1
fi

if [ -z "${SIGN_IDENTITY:-}" ]; then
    IDS="$(security find-identity -v -p codesigning | sed -n 's/.*) \([0-9A-F]\{40\}\) "Developer ID Application: .*/\1/p' | sort -u)"
    if [ "$(echo "$IDS" | grep -c .)" != 1 ]; then
        echo "Found $(echo "$IDS" | grep -c .) Developer ID Application identities; set SIGN_IDENTITY to one's hash." >&2
        exit 1
    fi
    SIGN_IDENTITY="$IDS"
fi
export SIGN_IDENTITY

UNIVERSAL=1 scripts/bundle.sh release
codesign --verify --strict --verbose=2 build/LaunchGrid.app

# From here on, work only on copies in build/release: other recipes rebuild build/LaunchGrid.app,
# and the notarisation ticket only matches the exact binary that was submitted.
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
ditto -c -k --keepParent build/LaunchGrid.app "$ZIP"
git rev-parse HEAD > "$OUT_DIR/COMMIT"

# notarytool exits non-zero for a rejected submission too: keep its output to report it.
STATUS=0
RESULT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json)" || STATUS=$?
echo "$RESULT"
if [ "$STATUS" -ne 0 ] || ! echo "$RESULT" | grep -q '"status" *: *"Accepted"'; then
    ID="$(echo "$RESULT" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')"
    if [ -n "$ID" ]; then
        echo "Notarisation failed; see: xcrun notarytool log $ID --keychain-profile $PROFILE" >&2
    else
        echo "Notarisation failed before a submission was made (notarytool exited with $STATUS)." >&2
    fi
    exit 1
fi

# Staple the ticket to the submitted app so it opens offline, then zip the stapled copy.
# A ticket can take a moment to become available after acceptance, so retry briefly.
ditto -x -k "$ZIP" "$OUT_DIR"
n=0
until xcrun stapler staple "$APP"; do
    n=$((n + 1))
    [ "$n" -lt 5 ] || exit 1
    echo "Retrying the staple in 30 s…"
    sleep 30
done
rm -f "$ZIP"
(cd "$OUT_DIR" && ditto -c -k --keepParent LaunchGrid.app LaunchGrid.zip)
spctl --assess --type execute --verbose "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "Built $ZIP (version $VERSION, commit $(cut -c1-7 "$OUT_DIR/COMMIT")); publish it with: just publish"
shasum -a 256 "$ZIP"
