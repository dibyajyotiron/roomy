#!/bin/sh
# Builds Roomy.app with swiftc: MoleCore and Pow as modules, then the app, bundle, icon and an ad-hoc signature.
# Uses Xcode's toolchain when it's installed; without Xcode the Command Line Tools work too, with Pow
# patched in the build folder only (the CLT have no SwiftUI macro plugin).
# Usage: Roomy/build.sh [--release] [--open] [--install] [--demo] [--local-v2]
#   --local-v2 builds a separate Roomy v2 with updates disabled, in a persistent local build folder.
#   --demo     builds "Roomy Demo.app" instead: its own bundle ID, a sanitised snapshot of this Mac's last scan inside,
#              and demo mode on, so Scan and Clean play the whole story without reading or removing anything.
#   --install  replaces ~/Applications/Roomy.app with this build and opens it: one copy to launch from Spotlight,
#              and the one to give Full Disk Access to.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
LOCAL_V2=0
for a in "$@"; do [ "$a" != "--local-v2" ] || LOCAL_V2=1; done
# Build outside the project: a synced Desktop adds Finder metadata to new files while codesign runs, which makes
# signing fail. Roomy/build stays as a link to the real build folder, so its paths keep working.
if [ "$LOCAL_V2" = 1 ]; then
  # This app is kept for manual testing across sessions; cleaners may remove cache folders.
  OUT="${ROOMY_BUILD_DIR:-$HOME/Library/Application Support/Roomy Local Builds/v2/build.noindex}"
else
  OUT="${ROOMY_BUILD_DIR:-$HOME/Library/Caches/Roomy/build.noindex}"
fi
mkdir -p "$OUT"
# Keep generated files out of Spotlight's file index. Launch Services has a
# separate app registry, so also unregister the build after signing/launching.
touch "$OUT/.metadata_never_index"
if [ ! -L "$ROOT/Roomy/build" ]; then rm -rf "$ROOT/Roomy/build"; fi
ln -sfn "$OUT" "$ROOT/Roomy/build"
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
DEMO=0
for a in "$@"; do case "$a" in --release) OPT="-O" ;; --open) OPEN=1 ;; --install) INSTALL=1 ;; --demo) DEMO=1 ;; esac; done
APP_NAME=Roomy
DATA_FOLDER=Roomy
DISABLE_UPDATES=false
if [ "$DEMO" = 1 ]; then APP_NAME="Roomy Demo"; BUNDLE_ID=app.roomy.demo; INSTALL=0; fi
if [ "$LOCAL_V2" = 1 ]; then
  APP_NAME="Roomy v2"
  BUNDLE_ID=app.roomy.v2
  DATA_FOLDER="Roomy v2"
  DISABLE_UPDATES=true
  ED_KEY=""
  FEED_URL=""
  # A local test build stays beside the production copy and never launches as part of this command.
  INSTALL=0
  OPEN=0
fi
if [ -d /Applications/Xcode.app ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
SDK=$(xcrun --sdk macosx --show-sdk-path)
TARGET=arm64-apple-macos26.0
SWIFTC="xcrun --sdk macosx swiftc -target $TARGET -sdk $SDK -swift-version 5"
MODS="$OUT/modules"
mkdir -p "$MODS"

echo "› MoleCore"
$SWIFTC -module-cache-path "$OUT/module-cache" $OPT -parse-as-library -module-name MoleCore -emit-library -static -emit-module -emit-module-path "$MODS/MoleCore.swiftmodule" \
  -o "$MODS/libMoleCore.a" Packages/MoleCore/Sources/MoleCore/*.swift

echo "› Pow"
POWSRC="$OUT/pow-src"
rm -rf "$POWSRC" && cp -R Vendor/Pow/Sources/Pow "$POWSRC"
printf 'import Foundation\nextension Bundle { static let module: Bundle = Bundle.main }\n' > "$POWSRC/_RoomyBundle.swift"
PLUGIN="${DEVELOPER_DIR:-/nonexistent}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
if [ ! -f "${PLUGIN:-/nonexistent}" ]; then
  find "$POWSRC" -name "*.swift" -exec perl -0pi -e 's/\@State(\s)/\@PowState$1/g' {} \;
  printf 'import SwiftUI\ntypealias PowState = SwiftUI.State\n' > "$POWSRC/_PowState.swift"
fi
(cd "$POWSRC" && $SWIFTC -module-cache-path "$OUT/module-cache" -O -parse-as-library -module-name Pow -emit-library -static -emit-module -emit-module-path "$MODS/Pow.swiftmodule" \
  -o "$MODS/libPow.a" $(find . -name "*.swift"))

echo "› Roomy"
APP="$OUT/$APP_NAME.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
$SWIFTC -module-cache-path "$OUT/module-cache" $OPT -parse-as-library -module-name Roomy -I "$MODS" -L "$MODS" -lMoleCore -lPow \
  -F "$ROOT/Vendor/Sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP/Contents/MacOS/Roomy" $(find Roomy/Sources -name "*.swift")
# Sparkle (MIT), for Roomy's own updates. Roomy isn't sandboxed, so its XPC services aren't included.
mkdir -p "$APP/Contents/Frameworks"
ditto "$ROOT/Vendor/Sparkle/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

echo "› Fan helper"
# roomy-fan is the only part that ever runs as root: you install it from Status, and it can only set fan speed.
$SWIFTC -module-cache-path "$OUT/module-cache" $OPT -module-name RoomyFan -o "$APP/Contents/MacOS/roomy-fan" Roomy/Helper/main.swift Roomy/Sources/Engine/SMC.swift

echo "› Bundle"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Roomy</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>GPL-3.0. Cleans with Mole (GPL-3.0).</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$ED_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUAllowsAutomaticUpdates</key><true/>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SUEnableSystemProfiling</key><false/>
  <key>RoomyDataFolder</key><string>$DATA_FOLDER</string>
  <key>RoomyDisableUpdates</key><$DISABLE_UPDATES/>
</dict></plist>
PLIST
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
if [ "${ROOMY_REGENERATE_ICONS:-0}" = 1 ]; then swift Roomy/generate-icon.swift; fi
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
  for marker in ROOMY_MOLE_COMMIT ROOMY_MOLE_CHECKSUMS; do
    [ ! -f "$MOLE_HOME/$marker" ] || cp "$MOLE_HOME/$marker" "$APP/Contents/Resources/mole/$marker"
  done
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
if [ "$DEMO" = 1 ]; then
  # Only generic names survive (scripts/roomy-demo-snapshot.py refuses to write if your username remains).
  SNAP="${ROOMY_DEMO_SOURCE:-$HOME/Library/Application Support/Roomy/snapshot.json}"
  python3 -I scripts/roomy-demo-snapshot.py "$SNAP" "$APP/Contents/Resources/demo-snapshot.json"
fi
python3 -I scripts/release-validation.py build-info "$APP"
xattr -cr "$APP"
# Use an available development identity, otherwise the normal ad-hoc signature. Never reduce the designated
# requirement to a bundle identifier: another binary can claim that identifier. Ad-hoc builds may need privacy
# permissions granted again after an update; retaining that identity boundary is intentional.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
if [ "$LOCAL_V2" = 1 ]; then IDENTITY=""; fi
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
  codesign --force --sign - "$APP" >/dev/null 2>&1
fi
codesign --verify --deep --strict "$APP"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
unregister_build() {
  "$LSREG" -u "$APP" >/dev/null 2>&1 || true
}
unregister_build
echo "✓ $APP"
if [ "$INSTALL" = 1 ]; then
  DEST="$HOME/Applications/Roomy.app"
  pkill -x Roomy 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST" && ditto "$APP" "$DEST"
  "$LSREG" -f "$DEST" >/dev/null 2>&1 || true
  echo "✓ installed $DEST"
  open "$DEST"
elif [ "$OPEN" = 1 ]; then
  open "$APP"
  unregister_build
fi
