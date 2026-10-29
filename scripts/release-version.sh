#!/bin/sh
# Usage: scripts/release-version.sh [patch|minor|major|resume] [release notes]
# No bump preserves the build-only workflow. resume retries the current version.
set -eu
cd "$(dirname "$0")/.."
BUMP="${1:-}"
NOTES="${2:-}"
case "$BUMP" in
    '') exec scripts/release.sh ;;
    patch|minor|major|resume) ;;
    *) echo 'Usage: just release [patch|minor|major|resume] ["release notes"]' >&2; exit 2 ;;
esac

# shellcheck source=scripts/release-checks.sh
. scripts/release-checks.sh
require_clean_tree
require_gh
if [ "$(git branch --show-current)" != main ]; then
    echo 'Check out main before releasing.' >&2
    exit 1
fi
git fetch -q --tags origin
if ! git merge-base --is-ancestor origin/main HEAD; then
    echo 'main is behind or has diverged from origin/main; reconcile it before releasing.' >&2
    exit 1
fi
# shellcheck source=scripts/homebrew-tap.sh
. scripts/homebrew-tap.sh
if [ -n "$(git -C "$TAP_DIR" status --porcelain)" ]; then
    echo "Commit or stash changes in $TAP_DIR before releasing (or use just publish to retry a cask update)." >&2
    exit 1
fi

VERSION_TMP=''
if [ "$BUMP" != resume ]; then
    # Reject prereleases, leading zeroes and malformed versions before doing arithmetic.
    if ! printf '%s\n' "$VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
        echo "Expected a major.minor.patch VERSION in scripts/bundle.sh; found: $VERSION" >&2
        exit 1
    fi
    MAJOR="${VERSION%%.*}"
    REST="${VERSION#*.}"
    MINOR="${REST%%.*}"
    PATCH="${REST#*.}"
    case "$BUMP" in
        patch) PATCH=$((PATCH + 1)) ;;
        minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
        major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    esac
    NEXT="$MAJOR.$MINOR.$PATCH"
    if git show-ref --verify --quiet "refs/tags/v$NEXT" ||
        git show-ref --verify --quiet "refs/tags/app-store/v$NEXT"; then
        echo "Version $NEXT already has a release or App Store tag; choose a new version." >&2
        exit 1
    fi
    echo "Bumping $VERSION to $NEXT."
    # Write back into the existing file to preserve its executable mode on BSD and GNU hosts.
    VERSION_TMP="$(mktemp)"
    trap 'rm -f "$VERSION_TMP"' EXIT
    sed "s/^VERSION=\".*\"$/VERSION=\"$NEXT\"/" scripts/bundle.sh > "$VERSION_TMP"
    cat "$VERSION_TMP" > scripts/bundle.sh
    git add scripts/bundle.sh
    git commit -m "chore(release): bump version to $NEXT"
fi

# Any failure after the commit should be retried without incrementing the version again.
finish() {
    RELEASE_STATUS=$?
    if [ "$RELEASE_STATUS" -ne 0 ]; then
        echo 'Release interrupted. Fix the failure, then run: just release resume (pass release notes again if needed).' >&2
    fi
    if [ -n "$VERSION_TMP" ]; then rm -f "$VERSION_TMP"; fi
    exit "$RELEASE_STATUS"
}
trap finish EXIT
COMMIT="$(git rev-parse HEAD)"
git push origin HEAD:main

if [ "${SKIP_CI_CHECK:-0}" != 1 ]; then
    echo "Waiting for CI for ${COMMIT}…"
    ATTEMPT=0
    while :; do
        RUN_ID="$(gh run list --commit "$COMMIT" --branch main --event push --workflow ci.yml \
            --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
        [ -z "$RUN_ID" ] || break
        ATTEMPT=$((ATTEMPT + 1))
        if [ "$ATTEMPT" -ge 60 ]; then
            echo 'No CI run appeared within five minutes; check GitHub Actions.' >&2
            exit 1
        fi
        sleep 5
    done
    gh run watch "$RUN_ID" --exit-status
fi

# A notarised zip from this commit can be reused after publishing or the tap push failed.
# SHA256 is written only after stapling and archiving succeed; a partial build cannot be reused.
# publish.sh validates the ticket and checks any existing remote asset's checksum.
if [ "$BUMP" != resume ] || [ ! -f build/release/LaunchGrid.zip ] ||
    [ ! -f build/release/COMMIT ] || [ "$(cat build/release/COMMIT)" != "$COMMIT" ] ||
    [ ! -f build/release/SHA256 ] ||
    [ "$(shasum -a 256 build/release/LaunchGrid.zip | cut -d ' ' -f 1)" != "$(cat build/release/SHA256)" ]; then
    scripts/release.sh
else
    require_green_ci
fi
scripts/publish.sh "$NOTES"
