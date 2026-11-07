#!/bin/sh
# Makes the README's animation from the website's video: website/public/video/demo.mp4 to
# docs/readme/demo.webp, an animated WebP (GitHub doesn't play a video file in a README).
# scripts/record-demo.sh runs it after recording the video. docs/readme/demo.webp.sha256 holds the
# hash of the video it was made from, and --check fails when that is no longer the current video;
# the website workflow runs that check, so the README can't fall behind the home page.
#
#   scripts/readme-demo.sh           make the animation (needs ffmpeg and img2webp: brew install ffmpeg webp)
#   scripts/readme-demo.sh --check   only check that the animation was made from the current video
#
# FPS (default 15), WIDTH (default 960) and QUALITY (default 70) set the animation's frame rate,
# width and lossy quality.
set -eu
cd "$(dirname "$0")/.."

VIDEO=website/public/video/demo.mp4
OUT=docs/readme/demo.webp
SUM="$OUT.sha256"
FPS="${FPS:-15}"
WIDTH="${WIDTH:-960}"
QUALITY="${QUALITY:-70}"

video_sum() { shasum -a 256 "$VIDEO" | cut -d' ' -f1; }

case "${1:-}" in
    --check)
        if [ ! -f "$OUT" ] || [ ! -f "$SUM" ] || [ "$(cat "$SUM")" != "$(video_sum)" ]; then
            echo "$OUT wasn't made from the current $VIDEO: run scripts/readme-demo.sh and commit both." >&2
            exit 1
        fi
        echo "$OUT matches $VIDEO."
        exit 0
        ;;
    "") ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

command -v ffmpeg >/dev/null || { echo "ffmpeg is needed: brew install ffmpeg" >&2; exit 1; }
command -v img2webp >/dev/null || { echo "img2webp is needed: brew install webp" >&2; exit 1; }
[ -f "$VIDEO" ] || { echo "No $VIDEO: record it with scripts/record-demo.sh --video" >&2; exit 1; }

FRAMES="$(mktemp -d)"
trap 'rm -rf "$FRAMES"' EXIT
ffmpeg -nostdin -hide_banner -loglevel error -i "$VIDEO" \
    -vf "fps=$FPS,scale=$WIDTH:-2:flags=lanczos" "$FRAMES/f%05d.png"
# Each frame shows for 1/FPS s, rounded to whole milliseconds; the frames sort by name.
DELAY=$(( (1000 + FPS / 2) / FPS ))
mkdir -p "$(dirname "$OUT")"
img2webp -loop 0 -d "$DELAY" -lossy -q "$QUALITY" -m 4 -mixed "$FRAMES"/f*.png -o "$OUT.tmp" >/dev/null
mv "$OUT.tmp" "$OUT"
video_sum >"$SUM"
ls -lh "$OUT"
