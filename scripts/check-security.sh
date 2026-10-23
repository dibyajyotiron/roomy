#!/bin/sh
# No real cleanup, app launch, privileged helper or user home fixtures.
set -eu
cd "$(dirname "$0")/.."
WORK=$(mktemp -d "${TMPDIR:-/tmp}/roomy-security-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
swiftc -module-cache-path "$WORK/module-cache" -swift-version 5 -parse-as-library Roomy/Sources/Core/Shell.swift Roomy/Sources/Engine/MoleWhitelist.swift Roomy/Sources/Engine/MoleTrashGuard.swift Tests/SecurityChecks.swift -o "$WORK/checks"
"$WORK/checks"
python3 -I -B -m unittest discover -s Tests -p 'test_*.py'
xcrun swiftc -module-cache-path "$WORK/module-cache" scripts/verify-release.swift -o "$WORK/verify"
"$WORK/verify" --self-test

sh Tests/fan/check-fan-helper.sh
