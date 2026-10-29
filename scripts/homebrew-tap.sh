#!/bin/sh
# Sourced from the project root by release-version.sh and publish.sh.
# Prefer an explicit TAP_DIR, then either conventional sibling checkout name.
if [ -z "${TAP_DIR:-}" ]; then
    if [ -d ../homebrew-tap ]; then
        TAP_DIR=../homebrew-tap
    elif [ -d ../sglavoie_homebrew-tap ]; then
        TAP_DIR=../sglavoie_homebrew-tap
    else
        TAP_DIR=../homebrew-tap
        echo "Cloning sglavoie/homebrew-tap into ${TAP_DIR}…"
        gh repo clone sglavoie/homebrew-tap "$TAP_DIR" || exit 1
    fi
fi
CASK="$TAP_DIR/Casks/launchgrid.rb"
if [ ! -e "$TAP_DIR/.git" ] || [ ! -f "$CASK" ]; then
    echo "No tap checkout with Casks/launchgrid.rb at $TAP_DIR; set TAP_DIR to your homebrew-tap clone." >&2
    exit 1
fi
# Keep the same checkout when release-version.sh invokes publish.sh.
export TAP_DIR
