#!/bin/bash
# Produces the zip that gets attached to a GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    "build/Fan Manager.app/Contents/Info.plist")

# Deliberately not versioned in the filename. A fixed name is what makes
# https://github.com/<repo>/releases/latest/download/FanManager.zip a permanent
# download link; the version lives in the tag, the release title and Info.plist.
ZIP="build/FanManager.zip"

rm -f "$ZIP"
# ditto rather than zip: it preserves the bundle's symlinks and resource forks,
# which a plain `zip` will quietly mangle.
ditto -c -k --keepParent "build/Fan Manager.app" "$ZIP"

# Ship the checksum beside the zip so install.sh can verify what it fetched.
# Generated from inside build/ so the file names the zip, not a path, which is
# what `shasum -c` expects.
( cd "$(dirname "$ZIP")" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )

echo "==> $ZIP  version ${VERSION}  ($(du -h "$ZIP" | cut -f1))"
sed 's/^/    sha256: /' "$ZIP.sha256"
