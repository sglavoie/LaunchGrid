#!/bin/sh
# Records the website's media from a scratch LaunchGrid with the apps in scripts/demo/apps.txt:
#   - the video: scripts/demo/story.txt on the main display, cut from "mark:start" to "mark:end",
#     to website/public/video/demo.mp4 and demo-poster.webp;
#   - the Settings tabs: scripts/demo/settings.txt in light and dark, to
#     website/public/images/settings-<tab>-<light|dark>.webp;
#   - with --app-store only, the Mac App Store screenshots: scripts/demo/app-store.txt in Window
#     mode over a system wallpaper, to docs/app-store/screenshots/*.jpg at 2880×1800.
#
# Needs ffmpeg and cwebp (brew install ffmpeg webp), and Screen Recording permission (System Settings › Privacy & Security › Screen &
# System Audio Recording) for the terminal app you run it from. Run it in a terminal window: a tmux
# server started in the background has no app for macOS to attribute the recording to. Keep the
# mouse and keyboard still while it runs: a click or a switch to another app hides the grid.
#
#   scripts/record-demo.sh               build, then record the video and the Settings tabs
#   scripts/record-demo.sh --video       only the video (--stills: only the Settings tabs)
#   scripts/record-demo.sh --app-store   only the App Store screenshots
#   scripts/record-demo.sh --no-build    reuse build/LaunchGrid.app
#
# BACKGROUND (default wallpaper; material shows open windows through), SCREEN (avfoundation screen
# index, default 0), FPS (default 60), KEEP=1 to keep the raw capture in build/demo/.
set -eu
cd "$(dirname "$0")/.."

BUILD=1 VIDEO=1 STILLS=1 STORE=0
for arg in "$@"; do
    case "$arg" in
        --no-build) BUILD=0 ;;
        --video) STILLS=0 ;;
        --stills) VIDEO=0 ;;
        --app-store) VIDEO=0 STILLS=0 STORE=1 ;;
        *) echo "usage: $0 [--video | --stills | --app-store] [--no-build]" >&2; exit 2 ;;
    esac
done
BACKGROUND="${BACKGROUND:-wallpaper}"
SCREEN="${SCREEN:-0}"
FPS="${FPS:-60}"
WORK="$PWD/build/demo"
DOMAIN=com.sglavoie.launchgrid.scratch
APP=build/LaunchGrid.app

command -v ffmpeg >/dev/null || { echo "ffmpeg is needed: brew install ffmpeg" >&2; exit 1; }
command -v cwebp >/dev/null || { echo "cwebp is needed: brew install webp" >&2; exit 1; }
rm -rf "$WORK"
mkdir -p "$WORK" website/public/video website/public/images docs/app-store/screenshots
if ! screencapture -x "$WORK/check.png" 2>/dev/null; then
    echo "Can't capture the screen. Allow your terminal app in System Settings › Privacy & Security ›" >&2
    echo "Screen & System Audio Recording, restart it, and run this in one of its windows (not a detached tmux)." >&2
    exit 1
fi
[ "$BUILD" = 1 ] && scripts/bundle.sh release

# The scratch settings domain is shared with `just scratch`: set the demo's, and put those back after.
HAD_DEFAULTS=0
defaults export "$DOMAIN" "$WORK/scratch-defaults.plist" 2>/dev/null && HAD_DEFAULTS=1
FFMPEG=
cleanup() {
    [ -n "$FFMPEG" ] && kill -INT "$FFMPEG" 2>/dev/null
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    [ "$HAD_DEFAULTS" = 1 ] && defaults import "$DOMAIN" "$WORK/scratch-defaults.plist"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM
defaults delete "$DOMAIN" >/dev/null 2>&1 || true
defaults write "$DOMAIN" windowMode -string fullScreen
defaults write "$DOMAIN" background -string "$BACKGROUND"
defaults write "$DOMAIN" showLabels -bool true
defaults write "$DOMAIN" iconScale -float 1

# A script file's steps, without comments and blank lines, joined with ";".
steps() { grep -v '^[[:space:]]*#' "$1" | grep . | paste -sd';' -; }
APPS=$(grep -v '^[[:space:]]*#' scripts/demo/apps.txt | grep . | paste -sd, -)

# Runs the steps against a fresh layout of the demo apps, logging to $WORK/<log>.log, and takes
# the window screenshots that "shoot" steps ask for. Fails when the app doesn't quit cleanly: a
# pipeline's status is its last command's, so the app's own goes through $WORK/<log>.status.
run_app() {
    log="$WORK/$1.log"
    status_file="$WORK/$1.status"
    rm -rf "$WORK/data" "$status_file"
    mkdir -p "$WORK/data"
    {
        status=0
        LAUNCHGRID_DATA_DIR="$WORK/data" LAUNCHGRID_DEBUG_DIR="$WORK" \
            LAUNCHGRID_DEBUG_SCRIPT="only:$APPS;size:5x7;build:alpha;$2;quit" \
            "$APP/Contents/MacOS/LaunchGrid" 2>&1 || status=$?
        echo "$status" >"$status_file"
    } | while IFS= read -r line; do
            printf '%s\n' "$line" >>"$log"
            case "$line" in
                "shoot: "*)
                    # "shoot: <window number> <name>"
                    id=$(echo "$line" | cut -d' ' -f2)
                    name=$(echo "$line" | cut -d' ' -f3)
                    screencapture -x -o -l"$id" "$WORK/$name.tmp.png" && mv "$WORK/$name.tmp.png" "$WORK/$name.png"
                    ;;
                "shootrect: "*)
                    # "shootrect: <x,y,w,h> <name>"
                    rect=$(echo "$line" | cut -d' ' -f2)
                    name=$(echo "$line" | cut -d' ' -f3)
                    screencapture -x -R"$rect" "$WORK/$name.tmp.png" && mv "$WORK/$name.tmp.png" "$WORK/$name.png"
                    ;;
            esac
        done
    grep '^only:' "$log" || true
    status="$(cat "$status_file" 2>/dev/null || echo unknown)"
    if [ "$status" != 0 ]; then
        echo "LaunchGrid exited with status $status during the $1 run;" >&2
        echo "see $log and ~/Library/Logs/DiagnosticReports." >&2
        exit 1
    fi
}

if [ "$STILLS" = 1 ]; then
    echo "Settings: keep the mouse and keyboard still until LaunchGrid quits."
    for appearance in light dark; do
        run_app "settings-$appearance" "$(steps scripts/demo/settings.txt | sed "s/{appearance}/$appearance/g")"
    done
    for png in "$WORK"/settings-*.png; do
        cwebp -quiet -q 85 "$png" -o "website/public/images/$(basename "$png" .png).webp"
    done
    ls -lh website/public/images/settings-*.webp
fi

if [ "$STORE" = 1 ]; then
    # Without it, the screenshots would quietly show the blurred desktop instead.
    PICTURE="/System/Library/Desktop Pictures/iMac Blue.heic"
    if [ ! -f "$PICTURE" ]; then
        echo "record-demo: $PICTURE isn't on this Mac; pick another system wallpaper for the App Store screenshots." >&2
        exit 1
    fi
    defaults write "$DOMAIN" windowMode -string window
    defaults write "$DOMAIN" background -string image
    defaults write "$DOMAIN" customImagePath -string "$PICTURE"
    echo "App Store: keep the mouse and keyboard still until LaunchGrid quits."
    run_app app-store "$(steps scripts/demo/app-store.txt)"
    # JPEG without alpha, at the App Store's 2880×1800 whatever the display's scale.
    FIT="scale=2880:1800:force_original_aspect_ratio=increase:flags=lanczos,crop=2880:1800"
    for name in 01-grid 02-search 03-folder 04-edit; do
        ffmpeg -nostdin -hide_banner -loglevel error -y -i "$WORK/$name.png" -vf "$FIT,format=yuvj444p" \
            -q:v 2 -frames:v 1 "docs/app-store/screenshots/$name.jpg"
    done
    # Settings, over the grid blurred and dimmed.
    ffmpeg -nostdin -hide_banner -loglevel error -y -i "$WORK/01-grid.png" -i "$WORK/05-settings.png" -filter_complex \
        "[0]$FIT,gblur=sigma=24,eq=brightness=-0.18[bg];[bg][1]overlay=(W-w)/2:(H-h)/2,format=yuvj444p" \
        -q:v 2 -frames:v 1 docs/app-store/screenshots/05-settings.jpg
    sips -g pixelWidth -g pixelHeight docs/app-store/screenshots/*.jpg | paste - - - | awk '{ print $1, $3 "×" $5 }'
fi

if [ "$VIDEO" = 1 ]; then
    # Wall-clock timestamps on the frames, so the app's marks say where to cut.
    ffmpeg -nostdin -hide_banner -loglevel error -f avfoundation -capture_cursor 0 -framerate "$FPS" \
        -use_wallclock_as_timestamps 1 -i "Capture screen $SCREEN" \
        -c:v hevc_videotoolbox -b:v 80M -copyts -f matroska "$WORK/raw.mkv" &
    FFMPEG=$!
    sleep 2
    kill -0 "$FFMPEG" 2>/dev/null || { FFMPEG=; echo "The screen capture didn't start." >&2; exit 1; }
    echo "Video: keep the mouse and keyboard still until LaunchGrid quits."
    run_app video "$(steps scripts/demo/story.txt);hide;wait:1"
    kill -INT "$FFMPEG"
    wait "$FFMPEG" || true
    FFMPEG=

    START=$(sed -n 's/^mark: start //p' "$WORK/video.log")
    END=$(sed -n 's/^mark: end //p' "$WORK/video.log")
    if [ -z "$START" ] || [ -z "$END" ]; then echo "No mark:start/mark:end in $WORK/video.log" >&2; exit 1; fi
    FIRST=$(ffprobe -v error -show_entries format=start_time -of csv=p=0 "$WORK/raw.mkv")
    FROM=$(echo "$START - $FIRST" | bc)
    TO=$(echo "$END - $FIRST" | bc)
    echo "Cutting $FROM s to $TO s of the capture"

    # 1920×1080 whatever the display's shape, so the page's dimensions hold.
    FRAME="trim=start=$FROM:end=$TO,setpts=PTS-STARTPTS,scale=1920:1080:force_original_aspect_ratio=increase:flags=lanczos,crop=1920:1080"
    ffmpeg -nostdin -hide_banner -loglevel error -y -i "$WORK/raw.mkv" -vf "$FRAME,format=yuv420p" -an \
        -c:v libx264 -preset slow -crf 22 -r "$FPS" -movflags +faststart website/public/video/demo.mp4
    ffmpeg -nostdin -hide_banner -loglevel error -y -i website/public/video/demo.mp4 -frames:v 1 "$WORK/poster.png"
    cwebp -quiet -q 82 "$WORK/poster.png" -o website/public/video/demo-poster.webp
    [ "${KEEP:-0}" = 1 ] || rm -f "$WORK/raw.mkv"
    ls -lh website/public/video/demo.mp4 website/public/video/demo-poster.webp
fi
