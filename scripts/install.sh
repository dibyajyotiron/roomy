#!/bin/sh
# Installs the latest Roomy release into /Applications from Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/dibyajyotiron/roomy/main/scripts/install.sh | sh
#
# Add a version to install that release instead, for example an older one to try an update:
#
#   curl -fsSL https://raw.githubusercontent.com/dibyajyotiron/roomy/main/scripts/install.sh | sh -s -- 0.2.3
#
# Only releases from 0.2.3 on carry the signed manifest this script checks.
#
# What it does, in order:
#   1. asks GitHub for the latest release tag (unless you gave a version)
#   2. downloads the zip, signed release manifest, and signature into a private temporary folder
#   3. authenticates the manifest with Roomy's pinned Ed25519 public key, then verifies the zip digest
#   4. quits Roomy if it's running, then replaces /Applications/Roomy.app with the new copy
#   5. makes sure you own the installed app, so Roomy can update itself later without a password
#   6. opens Roomy
#
# It stages and replaces /Applications/Roomy.app, using temporary folders that it removes when done.
# It uses sudo only if your account can't write to /Applications, and says so first.
#
# The release is authenticated with Roomy's Ed25519 release key (the same key that signs its updates); that is not an
# Apple Developer ID or notarization. Checking it needs Apple's Command Line Tools: without them nothing is installed.
# Files downloaded with curl aren't quarantined, and this script doesn't add quarantine, so Roomy opens without the
# Open Anyway step a browser download needs. The signature check above is what stands in for that first-open check.
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
  INSTALL_DIR=$(cd "$INSTALL_DIR" && pwd -P)
  APP="$INSTALL_DIR/Roomy.app"
  [ ! -L "$APP" ] || fail "Refusing to replace a symlink at $APP."
  xcrun --find swiftc >/dev/null 2>&1 || fail "Checking Roomy's release signature needs Apple's Command Line Tools. Install them with: xcode-select --install, then run this again. Or download the .pkg from the release page. Nothing was installed."

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
  MANIFEST=release-manifest.json
  SIGNATURE=release-manifest.sig
  BASE="https://github.com/$REPO/releases/download/$TAG"

  # 2. Download

  say "Downloading Roomy $VERSION"
  curl -fL --progress-bar -o "$TMP/$ZIP" "$BASE/$ZIP" || fail "Couldn't download $ZIP. Is $VERSION a Roomy release?"
  curl -fsSL -o "$TMP/$MANIFEST" "$BASE/$MANIFEST"
  curl -fsSL -o "$TMP/$SIGNATURE" "$BASE/$SIGNATURE"

  # 3. Verify

  # This verifier is part of the reviewed installer, never downloaded from a release asset.
  cat > "$TMP/verify.swift" <<'ROOMY_VERIFY_SWIFT'
import Foundation
import CryptoKit

func verify(_ key: String, _ signature: Data, _ payload: Data) throws {
    guard let bytes = Data(base64Encoded: key), let sig = Data(base64Encoded: String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes), publicKey.isValidSignature(sig, for: payload) else {
        throw NSError(domain: "RoomyRelease", code: 1, userInfo: [NSLocalizedDescriptionKey: "Release signature did not verify"])
    }
}

do {
    let a = CommandLine.arguments
    if a.count == 2 && a[1] == "--self-test" {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data("Roomy verification fixture".utf8)
        let signature = try key.signature(for: payload).base64EncodedData()
        try verify(key.publicKey.rawRepresentation.base64EncodedString(), signature, payload)
        var rejected = false
        do { try verify(key.publicKey.rawRepresentation.base64EncodedString(), signature, payload + Data([0])) }
        catch { rejected = true }
        guard rejected else { throw NSError(domain: "RoomyRelease", code: 2) }
        print("Ed25519: valid fixture accepted; tampered fixture rejected")
    } else {
        guard a.count == 4 || a.count == 6 else {
            throw NSError(domain: "RoomyRelease", code: 3, userInfo: [NSLocalizedDescriptionKey: "usage: verifier public-key-base64 signature-file payload-file [version zip-file]"])
        }
        let payload = try Data(contentsOf: URL(fileURLWithPath: a[3]))
        try verify(a[1], Data(contentsOf: URL(fileURLWithPath: a[2])), payload)
        if a.count == 6 {
            guard let manifest = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  manifest["schema"] as? Int == 1, manifest["version"] as? String == a[4],
                  let assets = manifest["assets"] as? [String: String],
                  URL(fileURLWithPath: a[5]).lastPathComponent == "Roomy-\(a[4]).zip",
                  let expected = assets["Roomy-\(a[4]).zip"] else { throw NSError(domain: "RoomyRelease", code: 4) }
            let zip = try Data(contentsOf: URL(fileURLWithPath: a[5]), options: .mappedIfSafe)
            let actual = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw NSError(domain: "RoomyRelease", code: 5, userInfo: [NSLocalizedDescriptionKey: "Archive checksum did not match the signed manifest"]) }
        }
        print("Release signature verified")
    }
} catch {
    fputs("Release verification failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
ROOMY_VERIFY_SWIFT
  xcrun swiftc -module-cache-path "$TMP/module-cache" "$TMP/verify.swift" -o "$TMP/verify"
  "$TMP/verify" "KmDoLhHTW4ettZXyEMZMFjgPk3i01x0RFYzE+unlrtg=" "$TMP/$SIGNATURE" "$TMP/$MANIFEST" "$VERSION" "$TMP/$ZIP" \
    || fail "The release signature or archive digest didn't verify. Nothing was installed."

  ditto -x -k "$TMP/$ZIP" "$TMP/unzipped"
  NEW="$TMP/unzipped/Roomy.app"
  [ -d "$NEW" ] || fail "$ZIP doesn't contain Roomy.app. Nothing was installed."
  NEW_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$NEW/Contents/Info.plist" 2>/dev/null || true)
  [ "$NEW_ID" = "$BUNDLE_ID" ] || fail "The app in $ZIP isn't Roomy ($NEW_ID). Nothing was installed."
  if ! codesign --verify --deep --strict "$NEW" 2>/dev/null; then
    fail "Roomy.app's code signature doesn't verify. Nothing was installed."
  fi

  # No quarantine: the release signature, archive digest, bundle ID and code signature above were all verified, and an
  # unnotarized app with quarantine is simply blocked on first open. curl itself never adds quarantine.

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
  # Stage a complete replacement first. Keep the previous app until the replacement is in place.
  STAGE=$($SUDO mktemp -d "$INSTALL_DIR/.roomy-install.XXXXXX")
  if ! $SUDO ditto "$NEW" "$STAGE/Roomy.app"; then
    $SUDO rm -rf "$STAGE"
    fail "Couldn't stage the new app. The installed copy was preserved."
  fi
  HAD_PREVIOUS=0
  if [ -e "$APP" ]; then $SUDO mv "$APP" "$STAGE/previous.app"; HAD_PREVIOUS=1; fi
  if ! $SUDO mv "$STAGE/Roomy.app" "$APP"; then
    if [ "$HAD_PREVIOUS" = 1 ] && ! $SUDO mv "$STAGE/previous.app" "$APP"; then
      fail "Couldn't restore the previous app. It is preserved at $STAGE/previous.app."
    fi
    $SUDO rm -rf "$STAGE"
    fail "Couldn't replace the app. Any previous copy was restored."
  fi
  $SUDO rm -rf "$STAGE"

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
