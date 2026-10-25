# Run `just` to list the recipes.

app := "build/LaunchGrid.app"
install_dir := env("INSTALL_DIR", "/Applications")

[private]
default:
    @just --list

# Compile without bundling
build:
    swift build

# Run the core and app-state tests
test *args:
    swift test {{args}}

# Run the tests against the Mac App Store variant, in its own build folder
test-app-store:
    swift test --scratch-path .build/app-store -Xswiftc -DAPP_STORE

# Build build/LaunchGrid.app (debug or release)
bundle config="release":
    scripts/bundle.sh {{config}}

# Bundle and open the app from the build folder
run config="release": (bundle config)
    open {{app}}

# Bundle and run against a throwaway layout and separate settings, with logs in the terminal
scratch config="debug": (bundle config)
    scripts/scratch.sh

# Its container is set aside and put back on quit. Quit the installed copy first, or that one takes over
# Run the sandboxed build as a first launch, logs in the terminal (--keep: use its container as it is)
sandbox *args:
    scripts/sandbox.sh {{args}}

# Build and install into /Applications, then relaunch (pass --no-open to skip)
install *args:
    INSTALL_DIR="{{install_dir}}" scripts/install.sh {{args}}

# Remove the login item, quit and remove the installed app; the layout and settings are kept
uninstall:
    INSTALL_DIR="{{install_dir}}" scripts/uninstall.sh

# Build the signed, notarised, universal build/release/LaunchGrid.zip
release:
    scripts/release.sh

# Build the sandboxed, signed build/app-store/LaunchGrid.pkg for App Store Connect (--upload sends it)
app-store *args:
    scripts/app-store.sh {{args}}

# Create the GitHub release for that build and update the Homebrew cask (optional release notes)
publish *notes:
    scripts/publish.sh {{quote(notes)}}

# Run CI's checks: build, test and bundle both variants, verify the bundles, shellcheck (leaves the App Store one in build/)
ci: build test test-app-store
    env -u APP_STORE -u SANDBOX -u ENTITLEMENTS UNIVERSAL=1 scripts/bundle.sh release
    plutil -lint {{app}}/Contents/Info.plist scripts/PrivacyInfo.xcprivacy scripts/LaunchGrid.entitlements
    codesign --verify --strict --verbose=2 {{app}}
    touch build/stand-in.provisionprofile
    env -u ENTITLEMENTS APP_STORE=1 SANDBOX=1 PROVISIONING_PROFILE=build/stand-in.provisionprofile scripts/bundle.sh release
    plutil -lint {{app}}/Contents/Info.plist
    /usr/libexec/PlistBuddy -c 'Print :DTXcode' {{app}}/Contents/Info.plist
    codesign --verify --strict --verbose=2 {{app}}
    codesign -d --entitlements - {{app}} | grep -q com.apple.security.app-sandbox
    ! strings -a {{app}}/Contents/MacOS/LaunchGrid | grep -E 'LAUNCHGRID_DEBUG_(SCRIPT|DIR)'
    shellcheck scripts/*.sh

# Serve the website (launchgrid.sglavoie.com) locally with the Workers runtime
website:
    cd website && npx -y wrangler@4.149.0 dev

# Publish the website to launchgrid.sglavoie.com (pushing website/ to main does this too)
website-deploy:
    scripts/check-website.sh
    cd website && npx -y wrangler@4.149.0 deploy

# Record the website's video and Settings screenshots (run in a terminal window with Screen Recording)
demo-video *args:
    scripts/record-demo.sh {{args}}

# Record the Mac App Store screenshots into docs/app-store/screenshots (in a terminal window with Screen Recording)
app-store-screenshots *args:
    scripts/record-demo.sh --app-store {{args}}

# Remove build products
clean:
    rm -rf .build build
