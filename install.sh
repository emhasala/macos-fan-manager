#!/bin/bash
#
# Fan Manager installer.
#
#   curl -fsSL https://raw.githubusercontent.com/emhasala/macos-fan-manager/main/install.sh | bash
#
# Downloads the latest release, verifies its checksum, and puts the app in
# /Applications. It does NOT ask for your password and does NOT enable fan
# control -- that stays a deliberate, separate step you take inside the app.
#
# You can also point it at a zip you already downloaded:
#   ./install.sh ~/Downloads/FanManager-0.1.0.zip
#
# And undo it:
#   ./install.sh --uninstall

set -euo pipefail

REPO="emhasala/macos-fan-manager"
APP_NAME="Fan Manager.app"
STATE_DIR="$HOME/Library/Application Support/FanManager"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# Prefer /Applications, fall back to ~/Applications rather than reaching for
# sudo: nothing here needs root, and an installer that asks for it invites
# exactly the habit this project is trying not to teach.
choose_destination() {
    if [ -n "${INSTALL_DIR:-}" ]; then echo "$INSTALL_DIR"; return; fi
    if [ -w /Applications ]; then echo "/Applications"; return; fi
    mkdir -p "$HOME/Applications"
    echo "$HOME/Applications"
}

uninstall() {
    local found=0
    for dir in /Applications "$HOME/Applications"; do
        if [ -d "$dir/$APP_NAME" ]; then
            bold "Removing $dir/$APP_NAME"
            # The helper inside may be setuid root, but it is owned by root with
            # the directory owned by the user, so a normal rm handles it.
            rm -rf "$dir/$APP_NAME" 2>/dev/null || die "could not remove $dir/$APP_NAME"
            found=1
        fi
    done
    [ -d "$STATE_DIR" ] && rm -rf "$STATE_DIR" && info "removed saved state"
    [ "$found" = 1 ] || info "Fan Manager was not installed"
    bold "Done."
    exit 0
}

[ "$(uname -s)" = "Darwin" ] || die "Fan Manager is macOS only"
[ "${1:-}" = "--uninstall" ] && uninstall

bold "Fan Manager installer"
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -n "${1:-}" ]; then
    # A zip the user already has. Nothing is downloaded, nothing is verified
    # against a checksum they did not fetch themselves.
    [ -f "$1" ] || die "no such file: $1"
    ZIP="$1"
    info "Using $ZIP"
else
    info "Looking up the latest release of $REPO"
    API="https://api.github.com/repos/$REPO/releases/latest"
    ASSETS="$(curl -fsSL "$API" 2>/dev/null)" \
        || die "could not reach GitHub. Is there a published release yet?"

    URL="$(printf '%s' "$ASSETS" \
        | grep -o '"browser_download_url":[[:space:]]*"[^"]*\.zip"' \
        | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/')"
    [ -n "$URL" ] || die "no .zip asset in the latest release of $REPO"

    SUM_URL="$(printf '%s' "$ASSETS" \
        | grep -o '"browser_download_url":[[:space:]]*"[^"]*\.sha256"' \
        | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/')"

    ZIP="$TMP/$(basename "$URL")"
    info "Downloading $(basename "$URL")"
    curl -fsSL "$URL" -o "$ZIP" || die "download failed"

    if [ -n "$SUM_URL" ]; then
        info "Verifying checksum"
        curl -fsSL "$SUM_URL" -o "$TMP/sum" || die "could not fetch checksum"
        EXPECTED="$(awk '{print $1}' "$TMP/sum")"
        ACTUAL="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
        [ "$EXPECTED" = "$ACTUAL" ] \
            || die "checksum mismatch -- expected $EXPECTED, got $ACTUAL"
        info "sha256 ok"
    else
        info "no checksum published for this release, skipping verification"
    fi
fi

info "Unpacking"
ditto -x -k "$ZIP" "$TMP/unpacked" || die "could not unzip $ZIP"
SRC="$TMP/unpacked/$APP_NAME"
[ -d "$SRC" ] || die "$APP_NAME not found inside the archive"

DEST="$(choose_destination)"
if [ -d "$DEST/$APP_NAME" ]; then
    info "Replacing the copy already in $DEST"
    rm -rf "$DEST/$APP_NAME" || die "could not replace $DEST/$APP_NAME"
fi

info "Installing to $DEST"
ditto "$SRC" "$DEST/$APP_NAME" || die "could not write to $DEST"

# Releases are ad-hoc signed rather than notarized, so Gatekeeper would refuse
# to open a downloaded copy until the quarantine flag is cleared.
xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

echo
bold "Installed: $DEST/$APP_NAME"
echo
info "Open it and fan speeds and temperatures appear straight away."
info "No password needed for monitoring."
echo
info "To change fan speeds, click 'Open in Terminal' on the setup card"
info "inside the app. That step is yours to take, and shows you the"
info "command before running it."
echo
if [ -t 0 ]; then
    printf '  Open Fan Manager now? [Y/n] '
    read -r reply
    case "$reply" in [nN]*) ;; *) open "$DEST/$APP_NAME" ;; esac
else
    info "Open it with:  open \"$DEST/$APP_NAME\""
fi
