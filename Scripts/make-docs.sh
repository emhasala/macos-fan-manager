#!/bin/bash
# Regenerates the icon and the README screenshots.
#
# The screenshots come from the app rendering its own SwiftUI views with live
# SMC data, not from a screen capture -- so they cannot drift out of sync with
# the UI, and generating them needs no Screen Recording permission.

set -euo pipefail
cd "$(dirname "$0")/.."

swift Scripts/make-icon.swift
./Scripts/build-app.sh >/dev/null

# The menu bar panel is pure SwiftUI, so ImageRenderer handles it and needs no
# permissions. The dashboards contain AppKit-backed controls, which
# ImageRenderer draws as placeholders -- those are screen-captured instead.
"build/Fan Manager.app/Contents/MacOS/FanManager" --render-screenshots docs
./Scripts/capture-screenshots.sh

echo "==> docs/"
ls -la docs/*.png | awk '{print "    "$NF"  "$5" bytes"}'
