#!/bin/sh
# Builds Roomy.app with swiftc: MoleCore and Pow as modules, then the app, bundle, icon and an ad-hoc signature.
# Uses Xcode's toolchain when it's installed; without Xcode the Command Line Tools work too, with Pow
# patched in the build folder only (the CLT have no SwiftUI macro plugin).
# Usage: Roomy/build.sh [--release] [--open] [--install]
#   --install  replaces ~/Applications/Roomy.app with this build and opens it: one copy to launch from Spotlight,
#              and the one to give Full Disk Access to.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
# Build outside the project: a synced Desktop adds Finder metadata to new files while codesign runs, which makes
# signing fail. Roomy/build stays as a link to the real build folder, so its paths keep working.
OUT="${ROOMY_BUILD_DIR:-$HOME/Library/Caches/Roomy/build}"
mkdir -p "$OUT"
# Spotlight never indexes the build folder, so the only Roomy it lists is the installed one.
touch "$OUT/.metadata_never_index"
if [ ! -L "$ROOT/Roomy/build" ]; then rm -rf "$ROOT/Roomy/build"; ln -s "$OUT" "$ROOT/Roomy/build"; fi
OPT="-Onone -g"
VERSION=${ROOMY_VERSION:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)}
# The build number Sparkle compares comes from the version (0.1.0 → 100, 1.2.3 → 10203), so it only ever goes up,
# whatever the git history looks like.
BUILD_NUMBER=${ROOMY_BUILD_NUMBER:-$(echo "$VERSION" | awk -F. '{ printf "%d", $1 * 10000 + $2 * 100 + $3 }')}
# Testing aids: ROOMY_BUNDLE_ID builds a separate copy (its own settings and permissions), ROOMY_FEED_URL points
# its updater at a test feed. Releases use neither.
BUNDLE_ID=${ROOMY_BUNDLE_ID:-app.roomy.Roomy}
FEED_URL=${ROOMY_FEED_URL:-https://github.com/dibyajyotiron/roomy/releases/latest/download/appcast.xml}
# The public half of the update signing key. Only updates signed with its private half (kept in the maintainer's
# Keychain, never in this repository) can install.
ED_KEY=${ROOMY_ED_KEY:-$(cat "$ROOT/Roomy/Resources/sparkle-public-ed-key.txt" 2>/dev/null || true)}
OPEN=0
INSTALL=0
for a in "$@"; do case "$a" in --release) OPT="-O" ;; --open) OPEN=1 ;; --install) INSTALL=1 ;; esac; done
if [ -d /Applications/Xcode.app ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
SDK=$(xcrun --sdk macosx --show-sdk-path)
TARGET=arm64-apple-macos26.0
SWIFTC="xcrun --sdk macosx swiftc -target $TARGET -sdk $SDK -swift-version 5"
MODS="$OUT/modules"
mkdir -p "$MODS"

echo "› MoleCore"
$SWIFTC $OPT -parse-as-library -module-name MoleCore -emit-library -static -emit-module -emit-module-path "$MODS/MoleCore.swiftmodule" \
  -o "$MODS/libMoleCore.a" Packages/MoleCore/Sources/MoleCore/*.swift

echo "› Pow"
POWSRC="$OUT/pow-src"
rm -rf "$POWSRC" && cp -R Vendor/Pow/Sources/Pow "$POWSRC"
printf 'import Foundation\nextension Bundle { static let module: Bundle = Bundle.main }\n' > "$POWSRC/_RoomyBundle.swift"
PLUGIN="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
if [ ! -f "${PLUGIN:-/nonexistent}" ]; then
  find "$POWSRC" -name "*.swift" -exec perl -0pi -e 's/\@State(\s)/\@PowState$1/g' {} \;
  printf 'import SwiftUI\ntypealias PowState = SwiftUI.State\n' > "$POWSRC/_PowState.swift"
fi
(cd "$POWSRC" && $SWIFTC -O -parse-as-library -module-name Pow -emit-library -static -emit-module -emit-module-path "$MODS/Pow.swiftmodule" \
  -o "$MODS/libPow.a" $(find . -name "*.swift"))

echo "› Roomy"
APP="$OUT/Roomy.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
$SWIFTC $OPT -parse-as-library -module-name Roomy -I "$MODS" -L "$MODS" -lMoleCore -lPow \
  -F "$ROOT/Vendor/Sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP/Contents/MacOS/Roomy" $(find Roomy/Sources -name "*.swift")
# Sparkle (MIT), for Roomy's own updates. Roomy isn't sandboxed, so its XPC services aren't included.
mkdir -p "$APP/Contents/Frameworks"
ditto "$ROOT/Vendor/Sparkle/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

echo "› Fan helper"
# roomy-fan is the only part that ever runs as root: you install it from Status, and it can only set fan speed.
$SWIFTC $OPT -module-name RoomyFan -o "$APP/Contents/MacOS/roomy-fan" Roomy/Helper/main.swift Roomy/Sources/Engine/SMC.swift

echo "› Bundle"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Roomy</string>
  <key>CFBundleDisplayName</key><string>Roomy</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Roomy</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>GPL-3.0. Built on PureMac (MIT) and Mole (GPL-3.0).</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$ED_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUAllowsAutomaticUpdates</key><true/>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SUEnableSystemProfiling</key><false/>
</dict></plist>
PLIST
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift Roomy/generate-icon.swift
for s in 16 32 128 256 512; do
  cp "Roomy/Resources/Assets.xcassets/AppIcon.appiconset/icon_${s}x${s}.png" "$ICONSET/icon_${s}x${s}.png"
  cp "Roomy/Resources/Assets.xcassets/AppIcon.appiconset/icon_${s}x${s}@2x.png" "$ICONSET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# The Living Room: CC0 models, textures and lighting from Poly Haven (see Roomy/Resources/Room/CREDITS.md).
ditto Roomy/Resources/Room "$APP/Contents/Resources/Room"
# Mole, bundled: Roomy cleans with Mole (GPL-3.0), so it ships the tested copy it was built against and needs no
# separate install. Taken from Homebrew's Mole on the build machine; its entry script is pointed at its own libexec.
MOLE_HOME=${MOLE_HOME:-$(brew --prefix mole 2>/dev/null || true)}   # CI sets MOLE_HOME (scripts/fetch-mole.sh)
if [ -n "$MOLE_HOME" ] && [ -x "$MOLE_HOME/bin/mole" ]; then
  MOLE_HOME=$(cd "$MOLE_HOME" && pwd -P)
  mkdir -p "$APP/Contents/Resources/mole/bin"
  ditto "$MOLE_HOME/libexec" "$APP/Contents/Resources/mole/libexec"
  sed "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")/../libexec\" \&\& pwd)\"|" "$MOLE_HOME/bin/mole" > "$APP/Contents/Resources/mole/bin/mole"
  chmod 755 "$APP/Contents/Resources/mole/bin/mole"
  cp "$MOLE_HOME/LICENSE" "$APP/Contents/Resources/mole/LICENSE"
  echo "  bundled Mole $(basename "$MOLE_HOME")"
else
  echo "  warning: Mole isn't installed (brew install mole), so this build relies on a Mole on the user's PATH"
fi
# Licenses travel with the app: GPL-3.0 for Roomy (it includes code ported from Mole), plus the notices it carries.
mkdir -p "$APP/Contents/Resources/Licenses"
cp LICENSE "$APP/Contents/Resources/Licenses/LICENSE-GPL-3.0.txt"
cp NOTICE.md LICENSES/*.txt "$APP/Contents/Resources/Licenses/"
# Pow's particle images, by asset name
for set in Vendor/Pow/Sources/Pow/Assets.xcassets/*.imageset; do
  name=$(basename "$set" .imageset)
  img=$(ls -S "$set"/*.png 2>/dev/null | head -1 || true)
  [ -n "$img" ] && cp "$img" "$APP/Contents/Resources/$name.png"
done
xattr -cr "$APP"
# macOS remembers permissions like Full Disk Access by the app's signing requirement. Plain ad-hoc signing ties that to
# this exact build, so every rebuild would lose the grant. Use an Apple Development identity when there is one;
# otherwise sign ad-hoc with a requirement that names the bundle ID, so grants survive rebuilds on this Mac.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
for go in "$APP"/Contents/Resources/mole/libexec/bin/*-go; do
  [ -f "$go" ] && codesign --force --sign "${IDENTITY:--}" ${IDENTITY:+--options runtime} "$go" >/dev/null 2>&1
done
# Sparkle's parts, inside out, with the same identity as the app (Sparkle checks that an update is signed the same way).
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for part in "$SPK/Autoupdate" "$SPK/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
  codesign --force --sign "${IDENTITY:--}" ${IDENTITY:+--options runtime} "$part" >/dev/null
done
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --sign "$IDENTITY" -i app.roomy.fan "$APP/Contents/MacOS/roomy-fan"
  codesign --force --options runtime --sign "$IDENTITY" "$APP" >/dev/null 2>&1
else
  codesign --force --sign - -i app.roomy.fan "$APP/Contents/MacOS/roomy-fan"
  codesign --force --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP" >/dev/null 2>&1
fi
codesign --verify --deep --strict "$APP"
echo "✓ $APP"
if [ "$INSTALL" = 1 ]; then
  DEST="$HOME/Applications/Roomy.app"
  pkill -x Roomy 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST" && ditto "$APP" "$DEST"
  LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREG" -u "$APP" >/dev/null 2>&1 || true   # only the installed copy shows up in Spotlight and Launchpad
  "$LSREG" -f "$DEST" >/dev/null 2>&1 || true
  echo "✓ installed $DEST"
  open "$DEST"
elif [ "$OPEN" = 1 ]; then open "$APP"; fi
