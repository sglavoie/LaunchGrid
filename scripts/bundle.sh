#!/bin/sh
# Builds LaunchGrid.app into ./build. Usage: scripts/bundle.sh [debug|release]
# SANDBOX=1 signs it with the App Sandbox entitlements, to try the Mac App Store build's
# sandbox locally. APP_STORE=1 (set by app-store.sh) builds that variant itself: without the
# debug scripts, with Xcode's build details and with ENTITLEMENTS and PROVISIONING_PROFILE.
set -eu
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/LaunchGrid.app"
VERSION="1.1.0"
# The deployment target set in Package.swift, so the two can't disagree.
MIN_MACOS="$(sed -n 's/.*\.macOS(\.v\([0-9][0-9]*\)).*/\1.0/p' Package.swift)"
if [ -z "$MIN_MACOS" ]; then
    echo "Couldn't read the macOS deployment target from Package.swift." >&2
    exit 1
fi

# UNIVERSAL=1 builds for both Apple silicon and Intel, as the downloadable release does.
set -- -c "$CONFIG"
[ "${UNIVERSAL:-0}" = 1 ] && set -- "$@" --arch arm64 --arch x86_64
[ "${APP_STORE:-0}" = 1 ] && set -- "$@" -Xswiftc -DAPP_STORE
swift build "$@"
BIN="$(swift build "$@" --show-bin-path)/LaunchGrid"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LaunchGrid"

# App icon (cached between builds).
ICNS="build/AppIcon.icns"
# `find -newer` rather than `-nt`, which POSIX sh lacks.
if [ ! -f "$ICNS" ] || [ -n "$(find scripts/make-icon.swift -newer "$ICNS")" ]; then
    TMP="$(mktemp -d)"
    swift scripts/make-icon.swift "$TMP/icon.png"
    mkdir "$TMP/AppIcon.iconset"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$TMP/AppIcon.iconset" -o "$ICNS"
    rm -rf "$TMP"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
cp scripts/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
# The String Catalog, as the en.lproj tables String(localized:) and SwiftUI read (plurals, for now).
xcrun xcstringstool compile Sources/LaunchGrid/Localizable.xcstrings --output-directory "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleName</key><string>LaunchGrid</string>
    <key>CFBundleDisplayName</key><string>LaunchGrid</string>
    <key>CFBundleIdentifier</key><string>com.sglavoie.launchgrid</string>
    <key>CFBundleExecutable</key><string>LaunchGrid</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Sébastien Lavoie</string>
    <key>ITSAppUsesNonExemptEncryption</key><false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>LaunchGrid Layout</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>com.sglavoie.launchgrid.layout</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.sglavoie.launchgrid.layout</string>
            <key>UTTypeDescription</key><string>LaunchGrid Layout</string>
            <key>UTTypeConformsTo</key><array><string>public.json</string></array>
            <key>UTTypeTagSpecification</key>
            <!-- .appgrid is what earlier builds saved; still opened, never written. -->
            <dict><key>public.filename-extension</key><array><string>launchgrid</string><string>appgrid</string></array></dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

# App Store Connect checks which Xcode and SDK built the app, from the keys Xcode adds.
if [ "${APP_STORE:-0}" = 1 ]; then
    XCODE_VERSION="$(xcodebuild -version | sed -n 's/^Xcode //p')"
    SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
    SDK_BUILD="$(xcrun --sdk macosx --show-sdk-build-version)"
    PB=/usr/libexec/PlistBuddy
    PLIST="$APP/Contents/Info.plist"
    $PB -c "Add :CFBundleSupportedPlatforms array" -c "Add :CFBundleSupportedPlatforms:0 string MacOSX" "$PLIST"
    $PB -c "Add :DTPlatformName string macosx" -c "Add :DTPlatformVersion string $SDK_VERSION" \
        -c "Add :DTPlatformBuild string $SDK_BUILD" -c "Add :DTSDKName string macosx$SDK_VERSION" \
        -c "Add :DTSDKBuild string $SDK_BUILD" -c "Add :DTCompiler string com.apple.compilers.llvm.clang.1_0" \
        -c "Add :DTXcode string $(echo "$XCODE_VERSION.0.0" | awk -F. '{ printf "%d%d%d", $1, $2, $3 }')" \
        -c "Add :DTXcodeBuild string $(xcodebuild -version | sed -n 's/^Build version //p')" \
        -c "Add :BuildMachineOSBuild string $(sw_vers -buildVersion)" "$PLIST"
    # A downloaded profile is quarantined, which the App Store refuses; copying keeps that, even with -X.
    cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    xattr -d com.apple.quarantine "$APP/Contents/embedded.provisionprofile" 2>/dev/null || true
fi

# Ad-hoc signature with the hardened runtime; use a Developer ID identity to notarise
# (notarisation also needs a secure timestamp, which ad-hoc signing can't have).
IDENTITY="${SIGN_IDENTITY:--}"
[ "${SANDBOX:-0}" = 1 ] && : "${ENTITLEMENTS:=scripts/LaunchGrid.entitlements}"
set -- --force --options runtime
[ -n "${ENTITLEMENTS:-}" ] && set -- "$@" --entitlements "$ENTITLEMENTS"
if [ "$IDENTITY" = "-" ]; then
    codesign "$@" --sign - "$APP"
else
    codesign "$@" --timestamp --sign "$IDENTITY" "$APP"
fi
echo "Built $APP"
