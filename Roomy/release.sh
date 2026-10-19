#!/bin/sh
# Builds a release of Roomy and packages it:
#   dist/Roomy-<version>.pkg      the download: double-click, and macOS's Installer puts Roomy in Applications
#   dist/Roomy-<version>.zip      the update Roomy downloads to update itself, signed with the update key
#   dist/appcast.xml              the feed Roomy checks once a day (uploaded with each release)
#   dist/Roomy-<version>.sha256   checksums of the pkg and zip
#
#   Roomy/release.sh              optimised build, ad-hoc signed (the first open needs Open Anyway in Privacy & Security)
#   ROOMY_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ROOMY_INSTALLER_IDENTITY="Developer ID Installer: Name (TEAMID)" \
#   ROOMY_NOTARY_PROFILE=roomy Roomy/release.sh
#                                 signs and notarizes too, so it opens with no warning
#
# Updates are signed with the private key in the maintainer's login Keychain (Sparkle's generate_keys, account
# "roomy"). It never leaves the Keychain; without it (on CI, say) the zip is left unsigned and no appcast is written,
# so nothing unsigned can be published by mistake. The version comes from ./VERSION. Publishing is a separate step
# (see README › Releasing).
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
VERSION=$(cat VERSION)
DIST="$ROOT/dist"
OUT="${ROOMY_BUILD_DIR:-$HOME/Library/Caches/Roomy/build.noindex}"
APP="$OUT/Roomy.app"
URL_PREFIX="${ROOMY_DOWNLOAD_URL_PREFIX:-https://github.com/dibyajyotiron/roomy/releases/download/v$VERSION/}"

Roomy/build.sh --release

# Mole is Roomy's dependency and never updates on its own, so a release ships exactly the Mole it was tested with:
# the version in MOLE_VERSION. To move to a newer Mole, install it (brew upgrade mole), test Roomy with it, then
# change MOLE_VERSION.
MOLE_PIN=$(cat MOLE_VERSION)
MOLE_BUNDLED=$(sed -n 's/^VERSION="\([0-9.]*\)".*/\1/p' "$APP/Contents/Resources/mole/bin/mole" 2>/dev/null || true)
if [ "$MOLE_BUNDLED" != "$MOLE_PIN" ]; then
  echo "✗ This build bundles Mole ${MOLE_BUNDLED:-(none)}, but MOLE_VERSION says $MOLE_PIN. Install Mole $MOLE_PIN or update MOLE_VERSION after testing." >&2
  exit 1
fi
SELFTEST=$("$APP/Contents/MacOS/Roomy" -RoomyMoleSelfTest installed 2>&1 | tail -n 1)
case "$SELFTEST" in
  *passed) echo "› Mole $MOLE_PIN bundled and passes Roomy's checks" ;;
  *) echo "✗ Roomy's checks failed on the bundled Mole: $SELFTEST" >&2; exit 1 ;;
esac

if [ -n "${ROOMY_SIGN_IDENTITY:-}" ]; then
  echo "› Signing with $ROOMY_SIGN_IDENTITY"
  for go in "$APP"/Contents/Resources/mole/libexec/bin/*-go; do codesign --force --options runtime --timestamp --sign "$ROOMY_SIGN_IDENTITY" "$go"; done
  SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  for part in "$SPK/Autoupdate" "$SPK/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --options runtime --timestamp --sign "$ROOMY_SIGN_IDENTITY" "$part"
  done
  codesign --force --options runtime --timestamp --sign "$ROOMY_SIGN_IDENTITY" -i app.roomy.fan "$APP/Contents/MacOS/roomy-fan"
  codesign --force --options runtime --timestamp --sign "$ROOMY_SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
fi
if [ -n "${ROOMY_SIGN_IDENTITY:-}" ] && [ -n "${ROOMY_NOTARY_PROFILE:-}" ]; then
  echo "› Notarizing the app (this takes a few minutes)"
  NZ=$(mktemp -d)/Roomy.zip
  ditto -c -k --keepParent "$APP" "$NZ"
  xcrun notarytool submit "$NZ" --keychain-profile "$ROOMY_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

rm -rf "$DIST" && mkdir -p "$DIST"
ZIP="$DIST/Roomy-$VERSION.zip"
PKG="$DIST/Roomy-$VERSION.pkg"
WORK=$(mktemp -d)

echo "› Update archive"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
if SIG=$("$ROOT/Vendor/Sparkle/bin/sign_update" --account roomy "$ZIP" 2>/dev/null) && [ -n "$SIG" ]; then
  cat > "$DIST/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Roomy</title>
    <item>
      <title>Roomy $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/dibyajyotiron/roomy/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="${URL_PREFIX}Roomy-$VERSION.zip" $SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
  echo "  signed the update and wrote appcast.xml"
else
  echo "  warning: no update key in this Keychain, so the update isn't signed and no appcast was written (fine for CI, not for a release)"
fi

echo "› Installer"
# The component: Roomy.app, installed into /Applications and never "relocated" to another copy Installer finds.
mkdir -p "$WORK/root" "$WORK/scripts" "$WORK/resources"
ditto "$APP" "$WORK/root/Roomy.app"
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Delete :0:BundleIsRelocatable" "$WORK/component.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$WORK/component.plist"
cat > "$WORK/scripts/preinstall" <<'SH'
#!/bin/sh
# Asks a running Roomy to quit (it hands the fans back to macOS on the way out) so the new version can go in.
user=$(stat -f %Su /dev/console)
uid=$(id -u "$user" 2>/dev/null || true)
if [ -n "$uid" ] && pgrep -x Roomy >/dev/null 2>&1; then
  launchctl asuser "$uid" /usr/bin/osascript -e 'tell application id "app.roomy.Roomy" to quit' >/dev/null 2>&1 || true
  sleep 2
fi
exit 0
SH
cat > "$WORK/scripts/postinstall" <<'SH'
#!/bin/sh
# Gives Roomy.app to the person who installed it, so Roomy's own updates can replace it without asking for a password.
user=$(stat -f %Su /dev/console)
if [ -n "$user" ] && [ "$user" != "root" ] && [ -d "$2/Roomy.app" ]; then chown -R "$user":staff "$2/Roomy.app"; fi
exit 0
SH
chmod 755 "$WORK/scripts/preinstall" "$WORK/scripts/postinstall"
pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" --install-location /Applications \
  --identifier app.roomy.Roomy.pkg --version "$VERSION" --scripts "$WORK/scripts" "$WORK/Roomy-component.pkg" >/dev/null
cp LICENSE "$WORK/resources/LICENSE.txt"
cat > "$WORK/resources/welcome.html" <<HTML
<html><body style="font-family: -apple-system; font-size: 13px; line-height: 1.5">
<h2 style="margin-top:0">Roomy $VERSION</h2>
<p>Make room on your Mac, and see exactly what goes before it goes.</p>
<p>This installs Roomy in your Applications folder. Mole, the cleaning engine Roomy uses, comes with it, so there's nothing else to install.</p>
<p>Roomy keeps itself up to date: when a new version is out, an Update button appears in the toolbar. Click it and Roomy downloads the update and reopens updated.</p>
<p>Free software under the GNU General Public License v3.0.</p>
</body></html>
HTML
cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Roomy</title>
  <welcome file="welcome.html" mime-type="text/html"/>
  <license file="LICENSE.txt"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
  <domains enable_localSystem="true" enable_anywhere="false" enable_currentUserHome="false"/>
  <volume-check><allowed-os-versions><os-version min="26.0"/></allowed-os-versions></volume-check>
  <choices-outline><line choice="default"><line choice="app.roomy.Roomy.pkg"/></line></choices-outline>
  <choice id="default"/>
  <choice id="app.roomy.Roomy.pkg" visible="false"><pkg-ref id="app.roomy.Roomy.pkg"/></choice>
  <pkg-ref id="app.roomy.Roomy.pkg" version="$VERSION" onConclusion="none">Roomy-component.pkg</pkg-ref>
</installer-gui-script>
XML
productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/resources" --package-path "$WORK" \
  ${ROOMY_INSTALLER_IDENTITY:+--sign "$ROOMY_INSTALLER_IDENTITY"} "$PKG" >/dev/null
if [ -n "${ROOMY_INSTALLER_IDENTITY:-}" ] && [ -n "${ROOMY_NOTARY_PROFILE:-}" ]; then
  echo "› Notarizing the installer"
  xcrun notarytool submit "$PKG" --keychain-profile "$ROOMY_NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi
rm -rf "$WORK"

(cd "$DIST" && shasum -a 256 "Roomy-$VERSION.pkg" "Roomy-$VERSION.zip" > "Roomy-$VERSION.sha256")
# Which commit this was built from, for scripts/publish-release.sh ("-dirty" if there were local changes).
COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)
[ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] || COMMIT="$COMMIT-dirty"
echo "$COMMIT" > "$DIST/BUILD_COMMIT"
echo "✓ $PKG"
echo "✓ $ZIP"
cat "$DIST/Roomy-$VERSION.sha256"
