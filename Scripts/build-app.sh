#!/bin/bash
# Assembles "Fan Manager.app" by hand.
#
# There is no Xcode project here on purpose: SwiftPM plus this script builds the
# whole thing with only the Command Line Tools installed, which keeps the repo
# buildable by anyone who clones it.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Fan Manager"
BUNDLE="build/${APP_NAME}.app"
BUNDLE_ID="io.github.macosfanmanager"
# Driven by the git tag so the zip name and the release never disagree.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.1.0}"
DEPLOY="13.0"
BINARIES=(FanManagerApp fan-helper fanctl)

# `swift build --arch a --arch b` needs XCBuild, which only ships with full
# Xcode. Building each slice against its own triple and lipo-ing them together
# gets the same universal binary from the Command Line Tools alone.
#
# --triple is not available on every toolchain, so a slice that will not build
# is reported and skipped rather than failing the whole release.
build_slice() {
    local triple="$1"
    swift build -c release --triple "$triple" >/dev/null 2>&1 || return 1
    swift build -c release --triple "$triple" --show-bin-path
}

UNIVERSAL=1

echo "==> Building arm64"
if ARM_DIR="$(build_slice "arm64-apple-macosx${DEPLOY}")"; then
    :
else
    echo "    per-triple build unavailable, falling back to a native build"
    swift build -c release
    ARM_DIR="$(swift build -c release --show-bin-path)"
    UNIVERSAL=0
fi

if [ "$UNIVERSAL" = 1 ]; then
    echo "==> Building x86_64"
    if X86_DIR="$(build_slice "x86_64-apple-macosx${DEPLOY}")"; then
        :
    else
        echo "    x86_64 slice unavailable -- shipping this architecture only"
        UNIVERSAL=0
    fi
fi

echo "==> Assembling ${BUNDLE}"
HELPER_WAS_ENABLED=0
if [ -u "$BUNDLE/Contents/MacOS/fan-helper" ]; then HELPER_WAS_ENABLED=1; fi
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

for bin in "${BINARIES[@]}"; do
    out="$BUNDLE/Contents/MacOS/$bin"
    if [ "$UNIVERSAL" = 1 ]; then
        lipo -create "$ARM_DIR/$bin" "$X86_DIR/$bin" -output "$out"
    else
        cp "$ARM_DIR/$bin" "$out"
    fi
done
mv "$BUNDLE/Contents/MacOS/FanManagerApp" "$BUNDLE/Contents/MacOS/FanManager"

# The icon is generated from Core Graphics source rather than checked in as a
# binary blob, so build it on demand if this is a fresh clone.
if [ ! -f Resources/AppIcon.icns ]; then
    echo "==> Generating icon"
    swift Scripts/make-icon.swift >/dev/null
fi
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>        <string>FanManager</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>${DEPLOY}</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>MIT licensed</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for the app to launch, but it is NOT notarization, so
# a downloaded copy still trips Gatekeeper until quarantine is cleared.
# Nested executables must be signed before the bundle that contains them --
# signing the bundle validates whatever code is nested inside it.
echo "==> Signing (ad-hoc)"
for bin in fan-helper fanctl; do
    codesign --force --sign - --timestamp=none "$BUNDLE/Contents/MacOS/$bin"
done
codesign --force --sign - --timestamp=none "$BUNDLE"

# Replacing the helper binary drops its setuid bit, so control silently stops
# working after every rebuild until it is granted again.
if [ "${HELPER_WAS_ENABLED:-0}" = 1 ]; then
    echo "==> Note: the rebuilt helper is no longer setuid."
    echo "    Fan control needs enabling again:"
    echo "    sudo chown root:wheel \"$PWD/$BUNDLE/Contents/MacOS/fan-helper\" && \\"
    echo "    sudo chmod u+s \"$PWD/$BUNDLE/Contents/MacOS/fan-helper\""
fi

echo "==> Done"
echo "    $BUNDLE"
echo "    architectures: $(lipo -archs "$BUNDLE/Contents/MacOS/FanManager")"
echo "    size: $(du -sh "$BUNDLE" | cut -f1)"
