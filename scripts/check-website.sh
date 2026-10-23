#!/bin/sh
# Fails when a page or the stylesheet refers to a local file that website/public doesn't have,
# such as media that scripts/record-demo.sh hasn't recorded yet, or links to a #fragment that the
# target page has no id for. Runs before every deploy and on pull requests that touch website/.
set -eu
cd "$(dirname "$0")/../website/public"

missing=0
REFS="$(mktemp)" PAGES="$(mktemp)"
trap 'rm -f "$REFS" "$PAGES"' EXIT

# A root-relative path's file: "/support/" is /support/index.html.
file_for() {
    path=".${1%%[?#]*}"
    case "$path" in */) path="${path}index.html" ;; esac
    printf '%s\n' "$path"
}

# Pages: src, href and poster attributes, and every candidate of a srcset ("url [descriptor]",
# separated by commas). Root-relative references and same-page #fragments are checked.
find . -name '*.html' >"$PAGES"
while IFS= read -r page; do
    {
        grep -oE '(src|href|poster)="[^"]*"' "$page" | sed -E 's/^[a-z]+="//; s/"$//'
        grep -oE 'srcset="[^"]*"' "$page" | sed -E 's/^srcset="//; s/"$//' | tr ',' '\n' | awk 'NF { print $1 }'
    } >"$REFS" || true
    while IFS= read -r ref; do
        case "$ref" in
            /*) target="$(file_for "$ref")" ;;
            "#"*) target="$page" ;;
            *) continue ;;
        esac
        if [ ! -f "$target" ]; then
            echo "Missing: $ref (in $page)" >&2
            missing=1
            continue
        fi
        case "$ref" in
            *"#"?*)
                fragment="${ref#*#}"
                case "$target" in
                    *.html)
                        if ! grep -qF "id=\"$fragment\"" "$target"; then
                            echo "No id \"$fragment\" in $target: $ref (in $page)" >&2
                            missing=1
                        fi
                        ;;
                esac
                ;;
        esac
    done <"$REFS"
done <"$PAGES"

# The stylesheets' url()s.
find . -name '*.css' -exec grep -hoE 'url\("/[^"]*"\)' {} + | sed -E 's/^url\("//; s/"\)$//' >"$REFS" || true
while IFS= read -r ref; do
    if [ ! -f "$(file_for "$ref")" ]; then
        echo "Missing: $ref (in a stylesheet)" >&2
        missing=1
    fi
done <"$REFS"

[ "$missing" = 0 ] && echo "Every local file and #fragment the website refers to exists."
exit "$missing"
