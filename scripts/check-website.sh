#!/bin/sh
# Fails when a page or the stylesheet refers to a local file that website/public doesn't have,
# such as media that scripts/record-demo.sh hasn't recorded yet. Runs before every deploy.
set -eu
cd "$(dirname "$0")/../website/public"

missing=0
# Root-relative references: src, href, poster and srcset attributes, and url() in CSS.
for ref in $(find . -name '*.html' -exec grep -hoE '(src|href|poster|srcset)="/[^"]*"' {} + \
        | sed -E 's/^[a-z]+="//; s/"$//; s/[ ,].*//'
    find . -name '*.css' -exec grep -hoE 'url\("/[^"]*"\)' {} + | sed -E 's/^url\("//; s/"\)$//'); do
    path=".${ref%%[?#]*}"
    case "$path" in */) path="${path}index.html" ;; esac
    if [ ! -f "$path" ]; then
        echo "Missing: $ref" >&2
        missing=1
    fi
done
[ "$missing" = 0 ] && echo "Every local file the website refers to exists."
exit "$missing"
