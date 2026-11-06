#!/bin/sh
# Builds MoleCore and its checks with swiftc alone (works without Xcode or SwiftPM), then runs them.
# Usage: Tools/check.sh [--parity]
set -eu
cd "$(dirname "$0")/.."
out=$(mktemp -d "${TMPDIR:-/tmp}/molecore-build.XXXXXX")
trap 'rm -rf "$out"' EXIT
swiftc -module-cache-path "$out/module-cache" -O -module-name MoleCore -emit-library -emit-module -emit-module-path "$out/MoleCore.swiftmodule" \
  -o "$out/libMoleCore.dylib" -Xlinker -install_name -Xlinker @rpath/libMoleCore.dylib Sources/MoleCore/*.swift
swiftc -module-cache-path "$out/module-cache" -O -I "$out" -L "$out" -lMoleCore -Xlinker -rpath -Xlinker "$out" \
  -o "$out/MoleCoreChecks" Sources/MoleCoreChecks/main.swift
"$out/MoleCoreChecks" "$@"
