#!/bin/sh
# Installs the latest Roomy release into /Applications from Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/dibyajyotiron/roomy/main/scripts/install.sh | sh
#
# Add a version to install that release instead, for example an older one to try an update:
#
#   curl -fsSL https://raw.githubusercontent.com/dibyajyotiron/roomy/main/scripts/install.sh | sh -s -- 0.0.2
#
# What it does, in order:
#   1. asks GitHub for the latest release tag (unless you gave a version)
#   2. downloads Roomy-<version>.zip and Roomy-<version>.sha256 from that release into a temporary folder
#   3. checks the zip against the published SHA-256 checksum, and stops if they don't match
#   4. quits Roomy if it's running, then replaces /Applications/Roomy.app with the new copy
#   5. makes sure you own the installed app, so Roomy can update itself later without a password
#   6. opens Roomy
#
# It changes nothing outside /Applications/Roomy.app and its temporary folder, which it removes when it's done.
# It uses sudo only if your account can't write to /Applications, and says so first.
#
# Files downloaded with curl aren't marked as quarantined, so macOS doesn't ask you to click Open Anyway the way it
# does for the .pkg downloaded in a browser.
#
# INSTALL_DIR=<folder> installs into that folder instead of /Applications and leaves any running Roomy alone. It's
# for testing this script only.
set -eu

REPO="dibyajyotiron/roomy"
BUNDLE_ID="app.roomy.Roomy"
TEST_INSTALL=${INSTALL_DIR:+yes}
INSTALL_DIR=${INSTALL_DIR:-/Applications}
APP="$INSTALL_DIR/Roomy.app"

say() { printf '› %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }
# Asks by bundle id without launching Roomy (a plain "tell application" would open it).
roomy_running() { [ "$(osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null)" = "true" ]; }

# Everything runs inside main, so a download cut off halfway runs nothing.
main() {
  # Checks before changing anything

  if [ "$(id -u)" -eq 0 ]; then
    fail "Run this as yourself, not as root (no sudo). It asks for your password only if it needs to."
  fi
  [ "$(uname -s)" = "Darwin" ] || fail "Roomy runs on macOS only."
  [ "$(uname -m)" = "arm64" ] || fail "Roomy needs a Mac with Apple silicon."
  MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
  [ "$MACOS_MAJOR" -ge 26 ] || fail "Roomy needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."
  [ -d "$INSTALL_DIR" ] || fail "$INSTALL_DIR doesn't exist."

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  trap 'exit 1' INT TERM

  # 1. Which release

  if [ $# -gt 0 ]; then
    TAG="v${1#v}"
  else
    say "Finding the latest Roomy release"
    TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
  fi
  VERSION=${TAG#v}
  case "$VERSION" in
    *[!0-9.]* | "" | .* | *.) fail "Couldn't tell which release to install (got '$TAG'). Give a version like 0.0.2." ;;
  esac
  ZIP="Roomy-$VERSION.zip"
  SUMS="Roomy-$VERSION.sha256"
  BASE="https://github.com/$REPO/releases/download/$TAG"

  # 2. Download

  say "Downloading Roomy $VERSION"
  curl -fL --progress-bar -o "$TMP/$ZIP" "$BASE/$ZIP" || fail "Couldn't download $ZIP. Is $VERSION a Roomy release?"
  curl -fsSL -o "$TMP/$SUMS" "$BASE/$SUMS"

  # 3. Verify

  EXPECTED=$(awk -v f="$ZIP" '$2 == f { print $1 }' "$TMP/$SUMS")
  [ -n "$EXPECTED" ] || fail "$SUMS has no checksum for $ZIP. Nothing was installed."
  ACTUAL=$(shasum -a 256 "$TMP/$ZIP" | awk '{ print $1 }')
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    fail "Checksum mismatch for $ZIP (expected $EXPECTED, got $ACTUAL). Nothing was installed."
  fi
  say "Checksum verified ($ACTUAL)"

  # curl doesn't mark downloads as quarantined, so normally there's nothing to remove. If something on this Mac did mark
  # the zip, clear the mark from that one file this script downloaded, so the app unzipped from it doesn't inherit it.
  xattr -d com.apple.quarantine "$TMP/$ZIP" 2>/dev/null || true

  ditto -x -k "$TMP/$ZIP" "$TMP/unzipped"
  NEW="$TMP/unzipped/Roomy.app"
  [ -d "$NEW" ] || fail "$ZIP doesn't contain Roomy.app. Nothing was installed."
  NEW_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$NEW/Contents/Info.plist" 2>/dev/null || true)
  [ "$NEW_ID" = "$BUNDLE_ID" ] || fail "The app in $ZIP isn't Roomy ($NEW_ID). Nothing was installed."
  if ! codesign --verify --deep --strict "$NEW" 2>/dev/null; then
    fail "Roomy.app's code signature doesn't verify. Nothing was installed."
  fi

  # 4. Install

  SUDO=""
  if [ ! -w "$INSTALL_DIR" ] || { [ -e "$APP" ] && [ ! -O "$APP" ]; }; then
    say "Your account can't replace $APP on its own, so the next step uses sudo and asks for your password."
    SUDO="sudo"
  fi

  if [ -z "$TEST_INSTALL" ] && roomy_running; then
    say "Quitting Roomy"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit"
    i=0
    while roomy_running; do
      i=$((i + 1))
      [ "$i" -le 20 ] || fail "Roomy didn't quit. Quit it yourself and run this again. Nothing was installed."
      sleep 0.5
    done
  fi

  say "Installing Roomy $VERSION in $INSTALL_DIR"
  $SUDO rm -rf "$APP"
  $SUDO ditto "$NEW" "$APP"

  # 5. Ownership

  # Roomy replaces itself when it updates, which needs no password only if you own the app.
  if [ -n "$SUDO" ]; then
    sudo chown -R "$(id -un):$(id -gn)" "$APP"
  fi
  [ -O "$APP" ] || fail "Roomy is installed, but $APP isn't owned by you, so updates will ask for a password."

  say "Installed $APP"

  # 6. Open

  if [ -n "$TEST_INSTALL" ]; then
    say "Test install (INSTALL_DIR is set), so Roomy isn't opened."
  else
    open "$APP"
  fi
}

main "$@"
