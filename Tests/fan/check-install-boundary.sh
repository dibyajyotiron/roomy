#!/bin/sh
# Verify the installer trust boundary using signed fixtures, never root or a real installed helper.
set -eu
W=$(mktemp -d "${TMPDIR:-/tmp}/roomy-install-check.XXXXXX")
trap 'rm -rf "$W"' EXIT
APP="$W/Roomy.app"
mkdir -p "$APP/Contents/MacOS"
printf 'print("fixture")\n' > "$W/fixture.swift"
xcrun swiftc -module-cache-path "$W/mc" "$W/fixture.swift" -o "$W/fixture"
cp "$W/fixture" "$APP/Contents/MacOS/Roomy"
cp "$W/fixture" "$APP/Contents/MacOS/roomy-fan"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.roomy.install-fixture</string>
<key>CFBundleExecutable</key><string>Roomy</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign -f -s - -i fixture.helper "$APP/Contents/MacOS/roomy-fan" 2>/dev/null
codesign -f -s - "$APP" 2>/dev/null
HASH=$(codesign -d --verbose=4 "$APP" 2>&1 | sed -n 's/^CDHash=//p')
[ -n "$HASH" ]
codesign --verify --deep --strict -R "=cdhash H\"$HASH\"" "$APP"
codesign -f -s - -i changed.helper "$APP/Contents/MacOS/roomy-fan" 2>/dev/null
if codesign --verify --deep --strict -R "=cdhash H\"$HASH\"" "$APP" 2>/dev/null; then
  echo 'Modified embedded helper incorrectly accepted' >&2; exit 1
fi
codesign -f -s - "$APP" 2>/dev/null
if codesign --verify --deep --strict -R "=cdhash H\"$HASH\"" "$APP" 2>/dev/null; then
  echo 'Re-signed replacement app incorrectly accepted' >&2; exit 1
fi
echo 'Helper installation: original accepted; modified helper and re-signed replacement rejected (3 checks)'
