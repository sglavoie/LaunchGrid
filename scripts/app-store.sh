#!/bin/sh
# Builds the Mac App Store package: sandboxed, universal, signed with Apple Distribution and
# wrapped in build/app-store/LaunchGrid.pkg, signed for the installer. Upload it with the
# Transporter app. Usage: scripts/app-store.sh
# One-time setup in the developer portal (Certificates, Identifiers & Profiles):
#   - "Apple Distribution" and "Mac Installer Distribution" certificates, in the keychain;
#   - the explicit App ID com.sglavoie.launchgrid;
#   - a Mac App Store Connect provisioning profile for it, saved as
#     private/LaunchGrid.provisionprofile (or set PROVISIONING_PROFILE).
# SIGN_IDENTITY and INSTALLER_IDENTITY default to the keychain's only identity of each kind.
set -eu
cd "$(dirname "$0")/.."
BUNDLE_ID=com.sglavoie.launchgrid
OUT_DIR=build/app-store
PROFILE="${PROVISIONING_PROFILE:-private/LaunchGrid.provisionprofile}"
PB=/usr/libexec/PlistBuddy

# The build number is the commit count, so uncommitted changes would ship under a used number.
if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash your changes first." >&2
    exit 1
fi
if [ ! -f "$PROFILE" ]; then
    echo "No provisioning profile at $PROFILE; see this script's header." >&2
    exit 1
fi

# The keychain's only identity whose name starts with one of the given names: its hash with
# --hash (codesign can misread a name with accents), else its name (productbuild wants that).
identity() {
    FORMAT='\2'
    if [ "$1" = --hash ]; then FORMAT='\1'; shift; fi
    PATTERN="$(printf '%s|' "$@")"
    FOUND="$(security find-identity -v -p basic | sed -nE "s/.*\) ([0-9A-F]{40}) \"((${PATTERN%?}): .*)\"$/$FORMAT/p" | sort -u)"
    if [ "$(echo "$FOUND" | grep -c .)" != 1 ]; then
        echo "Found $(echo "$FOUND" | grep -c .) \"$1\" identities in the keychain; expected one." >&2
        return 1
    fi
    echo "$FOUND"
}
SIGN_IDENTITY="${SIGN_IDENTITY:-$(identity --hash "Apple Distribution" "3rd Party Mac Developer Application")}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-$(identity "3rd Party Mac Developer Installer" "Mac Installer Distribution")}"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
security cms -D -i "$PROFILE" > "$OUT_DIR/profile.plist"
TEAM_ID="$($PB -c 'Print :TeamIdentifier:0' "$OUT_DIR/profile.plist")"
APP_ID="$($PB -c 'Print :Entitlements:com.apple.application-identifier' "$OUT_DIR/profile.plist")"
if [ "$APP_ID" != "$TEAM_ID.$BUNDLE_ID" ]; then
    echo "$PROFILE is for $APP_ID, not $TEAM_ID.$BUNDLE_ID." >&2
    exit 1
fi

# The sandbox entitlements, plus the identifiers the profile grants.
ENTITLEMENTS="$OUT_DIR/LaunchGrid.entitlements"
cp scripts/LaunchGrid.entitlements "$ENTITLEMENTS"
$PB -c "Add :com.apple.application-identifier string $APP_ID" \
    -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENTITLEMENTS"

UNIVERSAL=1 APP_STORE=1 SIGN_IDENTITY="$SIGN_IDENTITY" ENTITLEMENTS="$ENTITLEMENTS" \
    PROVISIONING_PROFILE="$PROFILE" scripts/bundle.sh release
codesign --verify --strict --verbose=2 build/LaunchGrid.app

# Work on a copy: other recipes rebuild build/LaunchGrid.app.
ditto build/LaunchGrid.app "$OUT_DIR/LaunchGrid.app"
productbuild --component "$OUT_DIR/LaunchGrid.app" /Applications --sign "$INSTALLER_IDENTITY" "$OUT_DIR/LaunchGrid.pkg"
pkgutil --check-signature "$OUT_DIR/LaunchGrid.pkg"
git rev-parse HEAD > "$OUT_DIR/COMMIT"

PLIST="$OUT_DIR/LaunchGrid.app/Contents/Info.plist"
echo "Built $OUT_DIR/LaunchGrid.pkg (version $($PB -c 'Print CFBundleShortVersionString' "$PLIST")," \
    "build $($PB -c 'Print CFBundleVersion' "$PLIST")); upload it with Transporter."
