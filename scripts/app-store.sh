#!/bin/sh
# Builds the Mac App Store package: sandboxed, universal, signed with Apple Distribution and
# wrapped in build/app-store/LaunchGrid.pkg, signed for the installer. With --upload, sends it
# to App Store Connect; otherwise upload it with the Transporter app.
# Usage: scripts/app-store.sh [--upload]
# One-time setup in the developer portal (Certificates, Identifiers & Profiles):
#   - "Apple Distribution" and "Mac Installer Distribution" certificates, in the keychain;
#   - the explicit App ID com.sglavoie.launchgrid;
#   - a Mac App Store Connect provisioning profile for it, saved as
#     private/LaunchGrid.provisionprofile (or set PROVISIONING_PROFILE).
#   - for --upload, an App Store Connect API key (Users and Access › Integrations), its
#     AuthKey_<key ID>.p8 in ~/.appstoreconnect/private_keys, and ASC_KEY_ID and ASC_ISSUER_ID
#     set or in private/app-store-connect.env.
# SIGN_IDENTITY and INSTALLER_IDENTITY default to the keychain's only identity of each kind.
# One version, one build: once vVERSION is released on GitHub (or uploaded), its App Store build
# comes from that commit. When HEAD has moved on since (screenshots, docs), it is built from a
# worktree of that commit in build/app-store-src, kept between runs so Swift's cache survives.
# An upload records its commit as the tag app-store/vVERSION, pushed to origin so every clone
# sees it: release.sh, and a later upload, refuse that version from any other commit, as two
# binaries would share its number. A Transporter upload isn't recorded; tag it the same way:
#   git tag app-store/vVERSION COMMIT && git push origin app-store/vVERSION
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUNDLE_ID=com.sglavoie.launchgrid
OUT_DIR="$ROOT/build/app-store"
SRC_DIR="$ROOT/build/app-store-src"
PROFILE="${PROVISIONING_PROFILE:-private/LaunchGrid.provisionprofile}"
PB=/usr/libexec/PlistBuddy
UPLOAD=0
for arg in "$@"; do
    case "$arg" in
        --upload) UPLOAD=1 ;;
        *) echo "Unknown argument: $arg" >&2; echo "Usage: scripts/app-store.sh [--upload]" >&2; exit 2 ;;
    esac
done
if [ "$UPLOAD" = 1 ]; then
    # shellcheck source=/dev/null
    [ -f private/app-store-connect.env ] && . private/app-store-connect.env
    if [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ]; then
        echo "--upload needs ASC_KEY_ID and ASC_ISSUER_ID; see this script's header." >&2
        exit 1
    fi
fi

# shellcheck source=scripts/release-checks.sh
. scripts/release-checks.sh
require_clean_tree
require_gh
require_pushed_head
require_green_ci
# One version, one build: the App Store build of a version already released on GitHub, or
# already uploaded, comes from that commit, or two different binaries would share its number.
HEAD_SHA="$(git rev-parse HEAD)"
RELEASED="$(released_commit)"
UPLOADED="$(uploaded_commit)"
if [ "$RELEASED" = unknown ]; then
    echo "Release v$VERSION exists on GitHub but its tag isn't here; run git fetch --tags." >&2
    exit 1
fi
if [ -n "$RELEASED" ] && [ -n "$UPLOADED" ] && [ "$RELEASED" != "$UPLOADED" ]; then
    echo "v$VERSION was released from $RELEASED but uploaded from $UPLOADED; bump VERSION in scripts/bundle.sh and commit first." >&2
    exit 1
fi
COMMIT="${UPLOADED:-${RELEASED:-$HEAD_SHA}}"
if [ "$COMMIT" != "$HEAD_SHA" ]; then
    if ! git merge-base --is-ancestor "$COMMIT" HEAD; then
        echo "v$VERSION was built from $COMMIT, which isn't in HEAD's history; check out main first." >&2
        exit 1
    fi
    # Changes to the code since then ship under the next version, not under this one's number.
    if ! git diff --quiet "$COMMIT" HEAD -- Sources Package.swift Package.resolved scripts/bundle.sh \
        scripts/make-icon.swift scripts/PrivacyInfo.xcprivacy scripts/LaunchGrid.entitlements; then
        echo "Note: the code changed since v$VERSION; this builds v$VERSION as released, without those changes." >&2
    fi
fi
case "$PROFILE" in /*) ;; *) PROFILE="$ROOT/$PROFILE" ;; esac
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
# Build in the source tree of COMMIT: this one, or a worktree checked out at it.
SRC="$ROOT"
if [ "$COMMIT" != "$HEAD_SHA" ]; then
    SRC="$SRC_DIR"
    git worktree prune
    if [ -d "$SRC/.git" ] || [ -f "$SRC/.git" ]; then
        git -C "$SRC" checkout -q -f --detach "$COMMIT"
    else
        rm -rf "$SRC"
        git worktree add -q --detach "$SRC" "$COMMIT"
    fi
    echo "Building v$VERSION from $(git log -1 --format='%h %s' "$COMMIT") in $SRC." >&2
fi
cp "$SRC/scripts/LaunchGrid.entitlements" "$ENTITLEMENTS"
$PB -c "Add :com.apple.application-identifier string $APP_ID" \
    -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENTITLEMENTS"

UNIVERSAL=1 APP_STORE=1 SIGN_IDENTITY="$SIGN_IDENTITY" ENTITLEMENTS="$ENTITLEMENTS" \
    PROVISIONING_PROFILE="$PROFILE" "$SRC/scripts/bundle.sh" release
codesign --verify --strict --verbose=2 "$SRC/build/LaunchGrid.app"

# Work on a copy: other recipes rebuild build/LaunchGrid.app.
ditto "$SRC/build/LaunchGrid.app" "$OUT_DIR/LaunchGrid.app"
# The App Store refuses a package with any quarantined file in it.
if xattr -r "$OUT_DIR/LaunchGrid.app" | grep -q com.apple.quarantine; then
    xattr -r "$OUT_DIR/LaunchGrid.app" | grep com.apple.quarantine >&2
    echo "These files are quarantined; the App Store would refuse the package." >&2
    exit 1
fi
productbuild --component "$OUT_DIR/LaunchGrid.app" /Applications --sign "$INSTALLER_IDENTITY" "$OUT_DIR/LaunchGrid.pkg"
pkgutil --check-signature "$OUT_DIR/LaunchGrid.pkg"
echo "$COMMIT" > "$OUT_DIR/COMMIT"

PLIST="$OUT_DIR/LaunchGrid.app/Contents/Info.plist"
BUILT="$OUT_DIR/LaunchGrid.pkg (version $($PB -c 'Print CFBundleShortVersionString' "$PLIST"), build $($PB -c 'Print CFBundleVersion' "$PLIST"))"
if [ "$UPLOAD" = 1 ]; then
    xcrun altool --upload-package "$OUT_DIR/LaunchGrid.pkg" --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID"
    # Recorded once uploaded, for release.sh and later uploads (see this script's header).
    TAG="app-store/v$VERSION"
    [ -n "$UPLOADED" ] || git tag "$TAG" "$COMMIT"
    if ! git push -q origin "refs/tags/$TAG"; then
        echo "Couldn't push the tag $TAG; push it with: git push origin $TAG" >&2
    fi
    echo "Uploaded $BUILT; App Store Connect emails you once it has processed it."
else
    echo "Built $BUILT; upload it with Transporter, or run again with --upload."
fi
