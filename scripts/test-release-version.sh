#!/bin/sh
# Test with disposable local repositories and fake GitHub/build/publish commands.
# No credentials, network, signing or real releases are used.
set -eu
cd "$(dirname "$0")/.."
SOURCE_DIR="$PWD"
ROOT="$(mktemp -d)"
cleanup() {
    TEST_STATUS=$?
    if [ "$TEST_STATUS" -ne 0 ]; then
        echo 'Release test failed; last command output:' >&2
        cat "$ROOT/output.log" "$ROOT/failure.log" "$ROOT/trace" >&2 2>/dev/null || :
    fi
    rm -rf "$ROOT"
    exit "$TEST_STATUS"
}
trap cleanup EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME='Release Test' GIT_AUTHOR_EMAIL='release@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export TAP_DIR="$ROOT/tap" TRACE="$ROOT/trace"
export MOCK_TAP_SOURCE="$TAP_DIR"
mkdir -p "$ROOT/bin" "$TAP_DIR/Casks"
git init -q -b main "$TAP_DIR"
echo 'cask "launchgrid"' > "$TAP_DIR/Casks/launchgrid.rb"
git -C "$TAP_DIR" add .
git -C "$TAP_DIR" commit -qm initial
cat > "$ROOT/bin/gh" <<'EOF'
#!/bin/sh
set -eu
case "$1 $2" in
    'auth status') exit 0 ;;
    'repo clone')
        [ "$3" = sglavoie/homebrew-tap ]
        echo tap-clone >> "$TRACE"
        git clone -q "$MOCK_TAP_SOURCE" "$4" ;;
    'run list')
        echo 'ci-list' >> "$TRACE"
        case "$*" in
            *--event*)
                [ "${MOCK_NO_RUN:-0}" != 1 ] || exit 0
                if [ "${MOCK_DELAY:-0}" = 1 ] && [ ! -f "$TRACE.delayed" ]; then
                    touch "$TRACE.delayed"
                    exit 0
                fi
                echo 123 ;;
            *) echo 'completed success 123 https://example.invalid/run/123' ;;
        esac ;;
    'run watch') echo ci-watch >> "$TRACE"; exit "${MOCK_CI_FAIL:-0}" ;;
    'run view') echo success ;;
    *) echo "Unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
cat > "$ROOT/bin/sleep" <<'EOF'
#!/bin/sh
echo ci-wait >> "$TRACE"
EOF
chmod +x "$ROOT/bin/gh" "$ROOT/bin/sleep"
export PATH="$ROOT/bin:$PATH"

setup() {
    CASE_DIR="$ROOT/$1"
    git init -q --bare "$CASE_DIR.git"
    git init -q -b main "$CASE_DIR"
    cd "$CASE_DIR"
    mkdir scripts
    cp "$SOURCE_DIR/scripts/release-version.sh" "$SOURCE_DIR/scripts/release-checks.sh" \
        "$SOURCE_DIR/scripts/homebrew-tap.sh" scripts/
    printf '#!/bin/sh\nVERSION="1.2.3"\n' > scripts/bundle.sh
    chmod +x scripts/bundle.sh
    echo build/ > .gitignore
    cat > scripts/release.sh <<'EOF'
#!/bin/sh
set -eu
echo build >> "$TRACE"
mkdir -p build/release
git rev-parse HEAD > build/release/COMMIT
echo archive > build/release/LaunchGrid.zip
# A failed notarisation can leave a zip and COMMIT but no completion checksum.
[ "${MOCK_BUILD_FAIL:-0}" != 1 ] || exit 1
shasum -a 256 build/release/LaunchGrid.zip | cut -d ' ' -f 1 > build/release/SHA256
EOF
    cat > scripts/publish.sh <<'EOF'
#!/bin/sh
set -eu
echo publish >> "$TRACE"
# shellcheck source=scripts/homebrew-tap.sh
. scripts/homebrew-tap.sh
printf '%s' "$TAP_DIR" > build/tap-dir
printf '%s' "$1" > build/notes
exit "${MOCK_PUBLISH_FAIL:-0}"
EOF
    chmod +x scripts/*.sh
    git add .
    git commit -qm initial
    git remote add origin "$CASE_DIR.git"
    git push -q origin main
    INITIAL="$(git rev-parse HEAD)"
    : > "$TRACE"
}

expect_failure() {
    if scripts/release-version.sh "$@" > "$ROOT/failure.log" 2>&1; then
        echo "Unexpected success: $*" >&2
        exit 1
    fi
}

for BUMP in patch minor major; do
    setup "$BUMP"
    case "$BUMP" in patch) EXPECTED=1.2.4 ;; minor) EXPECTED=1.3.0 ;; major) EXPECTED=2.0.0 ;; esac
    # Ensure notes retain literal shell syntax.
    # shellcheck disable=SC2016
    NOTES='Notes with spaces, "quotes", $(commands) and `backticks`'
    MOCK_DELAY=1 scripts/release-version.sh "$BUMP" "$NOTES" > "$ROOT/output.log" 2>&1
    grep -qx "VERSION=\"$EXPECTED\"" scripts/bundle.sh
    [ -x scripts/bundle.sh ]
    [ "$(git rev-list --count HEAD)" = 2 ]
    [ "$(git rev-parse HEAD)" = "$(git --git-dir="$CASE_DIR.git" rev-parse main)" ]
    [ -z "$(git status --porcelain)" ]
    [ "$(cat build/notes)" = "$NOTES" ]
    [ "$(tail -n 3 "$TRACE")" = "$(printf 'ci-watch\nbuild\npublish')" ]
done

setup guards
expect_failure invalid
git switch -qc feature
expect_failure patch
git switch -q main
echo dirty > untracked
expect_failure patch
rm untracked
echo dirty > "$TAP_DIR/untracked"
expect_failure patch
rm "$TAP_DIR/untracked"
git tag v1.2.4
expect_failure patch
git tag -d v1.2.4 >/dev/null
git tag app-store/v1.2.4
expect_failure patch
[ "$(git rev-parse HEAD)" = "$INITIAL" ]
[ ! -s "$TRACE" ]
# The remote has a commit this checkout has not incorporated.
echo newer > newer
git add newer
git commit -qm newer
git push -q origin main
git reset -q --hard "$INITIAL"
expect_failure minor
[ "$(git rev-parse HEAD)" = "$INITIAL" ]

setup ci-failure
(MOCK_CI_FAIL=1 expect_failure patch)
if grep -Eq '^(build|publish)$' "$TRACE"; then exit 1; fi
grep -q 'just release resume' "$ROOT/failure.log"
scripts/release-version.sh resume > "$ROOT/output.log" 2>&1
[ "$(git rev-list --count HEAD)" = 2 ]
grep -qx 'VERSION="1.2.4"' scripts/bundle.sh
grep -qx publish "$TRACE"

setup ci-timeout
(MOCK_NO_RUN=1 expect_failure minor)
if grep -Eq '^(build|publish)$' "$TRACE"; then exit 1; fi
grep -q 'No CI run appeared' "$ROOT/failure.log"

setup partial-build
(MOCK_BUILD_FAIL=1 expect_failure patch)
scripts/release-version.sh resume > "$ROOT/output.log" 2>&1
[ "$(grep -c '^build$' "$TRACE")" = 2 ]
[ "$(grep -c '^publish$' "$TRACE")" = 1 ]

setup publish-retry
(MOCK_PUBLISH_FAIL=1 expect_failure patch)
scripts/release-version.sh resume > "$ROOT/output.log" 2>&1
[ "$(grep -c '^build$' "$TRACE")" = 1 ]
[ "$(grep -c '^publish$' "$TRACE")" = 2 ]
[ "$(git rev-list --count HEAD)" = 2 ]
# A damaged archive must be rebuilt even if its completion marker is still present.
echo damage >> build/release/LaunchGrid.zip
scripts/release-version.sh resume > "$ROOT/output.log" 2>&1
[ "$(grep -c '^build$' "$TRACE")" = 2 ]

setup skip-ci
SKIP_CI_CHECK=1 scripts/release-version.sh patch > "$ROOT/output.log" 2>&1
[ "$(cat "$TRACE")" = "$(printf 'build\npublish')" ]

setup build-only
scripts/release-version.sh
[ "$(cat "$TRACE")" = build ]
[ "$(git rev-parse HEAD)" = "$INITIAL" ]

setup tap-prefixed
git clone -q "$MOCK_TAP_SOURCE" "$ROOT/sglavoie_homebrew-tap"
(unset TAP_DIR; scripts/release-version.sh patch > "$ROOT/output.log" 2>&1)
[ "$(cat build/tap-dir)" = ../sglavoie_homebrew-tap ]
if grep -qx tap-clone "$TRACE"; then exit 1; fi

setup tap-override
scripts/release-version.sh patch > "$ROOT/output.log" 2>&1
[ "$(cat build/tap-dir)" = "$TAP_DIR" ]

setup tap-invalid
(TAP_DIR="$ROOT/missing" expect_failure patch)
[ ! -e "$ROOT/missing" ]
[ "$(git rev-parse HEAD)" = "$INITIAL" ]

setup tap-clone
rm -rf "$ROOT/sglavoie_homebrew-tap"
(unset TAP_DIR; scripts/release-version.sh patch > "$ROOT/output.log" 2>&1)
[ "$(cat build/tap-dir)" = ../homebrew-tap ]
[ "$(grep -c '^tap-clone$' "$TRACE")" = 1 ]

setup tap-existing
(unset TAP_DIR; scripts/release-version.sh patch > "$ROOT/output.log" 2>&1)
[ "$(cat build/tap-dir)" = ../homebrew-tap ]
if grep -qx tap-clone "$TRACE"; then exit 1; fi
echo 'Release orchestration passed: bumps, guards, CI, retries and build-only compatibility.'
