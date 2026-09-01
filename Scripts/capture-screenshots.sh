#!/bin/bash
# Screen-captures the real app window in each state the README documents.
#
# ImageRenderer cannot rasterise AppKit-backed controls -- a slider or a
# segmented picker comes out as a yellow placeholder -- so the dashboard shots
# have to be real captures. That needs Screen Recording permission for whatever
# runs this; the menu bar panel still goes through ImageRenderer, which needs
# none.
#
# States other than "live" are driven by fixed data via --preview, so a
# single-fan MacBook Pro can document a fanless Air and a six-fan desktop.

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Fan Manager.app"
BIN="$APP/Contents/MacOS/FanManager"
[ -x "$BIN" ] && : || { echo "build the app first: ./Scripts/build-app.sh"; exit 1; }

capture() {
    local state=$1 appearance=$2 name=$3 size=$4
    pkill -x FanManager 2>/dev/null || true
    sleep 1

    if [ "$state" = "live" ]; then
        "$BIN" --appearance "$appearance" --window-size "$size" &
    else
        "$BIN" --preview "$state" --appearance "$appearance" --window-size "$size" &
    fi

    # Wait for the window rather than guessing: a live launch has to finish
    # sensor discovery first, a preview appears almost at once.
    local id="" tries=0
    while [ -z "$id" ] && [ $tries -lt 30 ]; do
        sleep 1
        id=$(swift Scripts/window-id.swift 2>/dev/null || true)
        tries=$((tries + 1))
    done
    [ -n "$id" ] || { echo "  $name: window never appeared"; return 1; }
    sleep 3   # let the first refresh land and the resize settle

    screencapture -x -o -l"$id" "docs/$name.png"
    echo "  wrote docs/$name.png"
    pkill -x FanManager 2>/dev/null || true
}

echo "==> Capturing"
# Heights are per state because each shows a different number of cards.
capture live     dark  dashboard-dark 540x580
capture live     light dashboard      540x580
capture setup    light setup          540x580
capture manual   dark  manual         540x430
capture fanless  light fanless        540x320
capture multifan light multifan       540x840

pkill -x FanManager 2>/dev/null || true
echo "==> Done"
