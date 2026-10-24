#!/bin/sh
# Checks shared by release.sh and app-store.sh before they spend minutes building and signing.
# Sourced, from the repository root: `. scripts/release-checks.sh`. Sets VERSION.

VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' scripts/bundle.sh)"

# The build number is the commit count, so uncommitted changes would ship under a used number.
require_clean_tree() {
    if [ -n "$(git status --porcelain)" ]; then
        echo "Commit or stash your changes first." >&2
        exit 1
    fi
}

# The release checks below ask GitHub; offline or logged out, they would pass without looking.
require_gh() {
    if ! command -v gh >/dev/null 2>&1; then
        echo "The GitHub CLI (gh) is needed to check the release; install it first." >&2
        exit 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        echo "gh is not logged in (or GitHub can't be reached); run gh auth login first." >&2
        exit 1
    fi
}

# Builds ship from main as it is on GitHub: the build number (the commit count) only rises
# along it, and publish.sh refuses a commit that isn't there.
require_pushed_head() {
    git fetch -q --tags origin
    if ! git merge-base --is-ancestor HEAD origin/main; then
        echo "HEAD isn't on origin/main; push it (or check out main) first." >&2
        exit 1
    fi
}

# The commit the GitHub release vVERSION was made at, or nothing when there is none yet.
released_commit() {
    if gh release view "v$VERSION" >/dev/null 2>&1; then
        git rev-list -n 1 "v$VERSION" 2>/dev/null || echo unknown
    fi
}
