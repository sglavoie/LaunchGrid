# Run `just` to list the recipes.

app := "build/LaunchGrid.app"
bundle_id := "com.sglavoie.launchgrid"
install_dir := env("INSTALL_DIR", "/Applications")
lsregister := "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

[private]
default:
    @just --list

# Compile without bundling
build:
    swift build

# Run the core and app-state tests
test *args:
    swift test {{args}}

# Build build/LaunchGrid.app (debug or release)
bundle config="release":
    scripts/bundle.sh {{config}}

# Bundle and open the app from the build folder
run config="release": (bundle config)
    open {{app}}

# Bundle and run against a throwaway layout and separate settings, with logs in the terminal
scratch config="debug": (bundle config)
    #!/bin/sh
    DIR="$(mktemp -d)"
    # Launching registers the build copy with Launch Services; hand .appgrid files back to
    # the installed copy afterwards, and drop the throwaway layout.
    cleanup() { "{{lsregister}}" -u "{{app}}" >/dev/null 2>&1; rm -rf "$DIR"; }
    trap cleanup EXIT
    trap 'exit 130' INT TERM
    LAUNCHGRID_DATA_DIR="$DIR" "{{app}}/Contents/MacOS/LaunchGrid"

# Build and install into /Applications, then relaunch (pass --no-open to skip)
install *args:
    INSTALL_DIR="{{install_dir}}" scripts/install.sh {{args}}

# Quit and remove the installed app; the layout and settings are kept
uninstall:
    #!/bin/sh
    set -eu
    DEST="{{install_dir}}/LaunchGrid.app"
    [ -e "$DEST" ] || { echo "Nothing installed at $DEST"; exit 0; }
    osascript -e 'tell application id "{{bundle_id}}" to quit' >/dev/null 2>&1 || true
    "{{lsregister}}" -u "$DEST" >/dev/null 2>&1 || true
    if [ -w "{{install_dir}}" ]; then rm -rf "$DEST"; else sudo rm -rf "$DEST"; fi
    echo "Removed $DEST"

# Build, test and bundle, as CI does
ci: build test (bundle "release")

# Serve the website (launchgrid.sglavoie.com) locally with the Workers runtime
website:
    cd website && npx -y wrangler@4 dev

# Publish the website to launchgrid.sglavoie.com
website-deploy:
    cd website && npx -y wrangler@4 deploy

# Remove build products
clean:
    rm -rf .build build
