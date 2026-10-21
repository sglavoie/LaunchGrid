#!/bin/sh
# Builds the downloadable LaunchGrid: universal, signed with Developer ID, notarised and
# stapled, zipped to build/LaunchGrid.zip for a GitHub release.
# Usage: SIGN_IDENTITY="Developer ID Application: …" scripts/release.sh
# Notarisation reads a notarytool keychain profile (NOTARY_PROFILE, default "launchgrid"),
# stored once with: xcrun notarytool store-credentials launchgrid --apple-id … --team-id …
set -eu
cd "$(dirname "$0")/.."
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Developer ID Application identity}"
PROFILE="${NOTARY_PROFILE:-launchgrid}"
APP="build/LaunchGrid.app"
ZIP="build/LaunchGrid.zip"

# The build number is the commit count, so uncommitted changes would ship under a used number.
if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash your changes first." >&2
    exit 1
fi

UNIVERSAL=1 scripts/bundle.sh release
codesign --verify --strict --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
OUT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json)"
echo "$OUT"
if ! echo "$OUT" | grep -q '"status" *: *"Accepted"'; then
    ID="$(echo "$OUT" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')"
    echo "Notarisation failed; see: xcrun notarytool log $ID --keychain-profile $PROFILE" >&2
    exit 1
fi

# Staple the ticket so the app opens offline, then zip the stapled copy.
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "Built $ZIP (version $VERSION)"
shasum -a 256 "$ZIP"
