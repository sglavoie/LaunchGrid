#!/bin/sh
# Exercise first install, replacement, and failure without touching /Applications.
set -eu
cd "$(dirname "$0")/.."
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

mkdir "$ROOT/stage"
printf 'first\n' > "$ROOT/stage/version"
swift scripts/install-swap.swift "$ROOT/stage" "$ROOT/LaunchGrid.app"
[ "$(cat "$ROOT/LaunchGrid.app/version")" = first ]
[ ! -e "$ROOT/stage" ]

mkdir "$ROOT/stage"
printf 'second\n' > "$ROOT/stage/version"
swift scripts/install-swap.swift "$ROOT/stage" "$ROOT/LaunchGrid.app"
[ "$(cat "$ROOT/LaunchGrid.app/version")" = second ]
[ "$(cat "$ROOT/stage/version")" = first ]

rm -rf "$ROOT/stage"
if swift scripts/install-swap.swift "$ROOT/stage" "$ROOT/LaunchGrid.app" 2>/dev/null; then
    echo 'A missing staged app unexpectedly replaced the installed one.' >&2
    exit 1
fi
[ "$(cat "$ROOT/LaunchGrid.app/version")" = second ]
echo 'Install swap preserves the installed app.'
