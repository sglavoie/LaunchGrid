#!/bin/sh
# Usage: scripts/release-version.sh [--force] [patch|minor|major|X.Y.Z|resume] [release notes]
# No bump preserves the build-only workflow. resume retries the current version. X.Y.Z sets the
# version directly; it must be above every released or uploaded version. --force publishes
# without waiting for or checking CI (the same as SKIP_CI_CHECK=1), so failing tests don't stop it.
set -eu
cd "$(dirname "$0")/.."
usage() {
    echo 'Usage: just release [--force] [patch|minor|major|X.Y.Z|resume] ["release notes"]' >&2
    exit 2
}
BUMP=''
NOTES=''
HAVE_BUMP=0
while [ $# -gt 0 ]; do
    case "$1" in
        -f|--force) export SKIP_CI_CHECK=1 ;;
        --) shift; break ;;
        # After the bump, anything else starts the notes, even "- Fixed …".
        -*) if [ "$HAVE_BUMP" = 0 ]; then usage; else break; fi ;;
        *)
            if [ "$HAVE_BUMP" = 0 ]; then BUMP="$1"; HAVE_BUMP=1; else break; fi ;;
    esac
    shift
done
# Unquoted notes arrive as several words: join them back.
NOTES="$*"
SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
case "$BUMP" in
    '')
        [ -z "$NOTES" ] || usage
        exec scripts/release.sh ;;
    patch|minor|major|resume) ;;
    *) printf '%s\n' "$BUMP" | grep -Eq "$SEMVER" || usage ;;
esac
if [ "${SKIP_CI_CHECK:-0}" = 1 ]; then
    echo 'Not waiting for or checking CI: this release ships even if its tests fail.' >&2
fi

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

# Whether major.minor.patch $1 is above $2.
version_above() {
    A1="${1%%.*}"; AR="${1#*.}"; A2="${AR%%.*}"; A3="${AR#*.}"
    B1="${2%%.*}"; BR="${2#*.}"; B2="${BR%%.*}"; B3="${BR#*.}"
    if [ "$A1" -ne "$B1" ]; then [ "$A1" -gt "$B1" ]; return; fi
    if [ "$A2" -ne "$B2" ]; then [ "$A2" -gt "$B2" ]; return; fi
    [ "$A3" -gt "$B3" ]
}

VERSION_TMP=''
if [ "$BUMP" != resume ]; then
    # Reject prereleases, leading zeroes and malformed versions before doing arithmetic.
    case "$BUMP" in
        patch|minor|major)
            if ! printf '%s\n' "$VERSION" | grep -Eq "$SEMVER"; then
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
            NEXT="$MAJOR.$MINOR.$PATCH" ;;
        *) NEXT="$BUMP" ;;
    esac
    if git show-ref --verify --quiet "refs/tags/v$NEXT" ||
        git show-ref --verify --quiet "refs/tags/app-store/v$NEXT"; then
        echo "Version $NEXT already has a release or App Store tag; choose a new version." >&2
        exit 1
    fi
    # An explicit version may go below VERSION (to reuse a number whose release never shipped),
    # but never to or below one that was released or uploaded: Homebrew and the App Store only
    # move forward.
    for TAG in $(git tag --list 'v*' 'app-store/v*'); do
        TAGGED="${TAG#app-store/}"
        TAGGED="${TAGGED#v}"
        printf '%s\n' "$TAGGED" | grep -Eq "$SEMVER" || continue
        if ! version_above "$NEXT" "$TAGGED"; then
            echo "Version $NEXT isn't above $TAG; choose a higher version." >&2
            exit 1
        fi
    done
    if [ "$NEXT" = "$VERSION" ]; then
        echo "VERSION is already $NEXT; use: just release resume" >&2
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
        RESUME='just release resume'
        if [ "${SKIP_CI_CHECK:-0}" = 1 ]; then RESUME='just release --force resume'; fi
        echo "Release interrupted. Fix the failure, then run: $RESUME (pass release notes again if needed)." >&2
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
