#!/bin/sh
# Smoke-test ad-hoc Hardened Runtime + Sparkle and sealed resource validation without starting Roomy's UI.
set -eu
cd "$(dirname "$0")/.."
W=$(mktemp -d "${TMPDIR:-/tmp}/roomy-runtime-check.XXXXXX")
trap 'rm -rf "$W"' EXIT
APP="$W/Fixture.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cat > "$W/main.swift" <<'SWIFT'
import Foundation
import Sparkle
print(CodeIdentity.ownBundleIsValid() ? "valid" : "invalid")
print(NSClassFromString("SPUUpdater") != nil ? "Sparkle loaded" : "Sparkle missing")
SWIFT
xcrun swiftc -module-cache-path "$W/mc" -F Vendor/Sparkle -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  Roomy/Sources/Engine/CodeIdentity.swift "$W/main.swift" -o "$APP/Contents/MacOS/Fixture"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.roomy.runtime-fixture</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
printf 'original\n' > "$APP/Contents/Resources/engine.sh"
ditto Vendor/Sparkle/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
xattr -cr "$APP"
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for part in "$SPK/Autoupdate" "$SPK/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework" "$APP"; do
  codesign -f -s - --options runtime --entitlements Roomy/Resources/AdHoc.entitlements "$part"
done
expected=$(printf 'valid\nSparkle loaded')
[ "$("$APP/Contents/MacOS/Fixture")" = "$expected" ]
printf 'tampered\n' > "$APP/Contents/Resources/engine.sh"
expected=$(printf 'invalid\nSparkle loaded')
[ "$("$APP/Contents/MacOS/Fixture")" = "$expected" ]
echo 'Runtime: hardened ad-hoc Sparkle loads; modified resource fails bundle validation (2 checks)'
