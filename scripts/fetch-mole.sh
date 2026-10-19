#!/bin/sh
# Fetches exactly the Mole version Roomy is pinned to (./MOLE_VERSION) from Mole's own GitHub release and lays it out
# the way Homebrew does (bin/mole, libexec/bin, libexec/lib, LICENSE), so Roomy/build.sh can bundle it with
# MOLE_HOME=<dest>. CI uses this so every build bundles the tested Mole, not whatever Homebrew has that day.
# The two helper programs are checked against the release's SHA256SUMS, as Mole's own installer does.
#   scripts/fetch-mole.sh <dest>
set -eu
cd "$(dirname "$0")/.."
DEST=${1:?usage: scripts/fetch-mole.sh <dest>}
VERSION=$(cat MOLE_VERSION)
TAG="V$VERSION"
case "$(uname -m)" in arm64) ARCH=arm64 ;; *) ARCH=amd64 ;; esac
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "› Mole $VERSION from github.com/tw93/mole"
curl -fsSL --retry 3 -o "$WORK/src.tar.gz" "https://github.com/tw93/mole/archive/refs/tags/$TAG.tar.gz"
mkdir "$WORK/src"
tar -xzf "$WORK/src.tar.gz" -C "$WORK/src" --strip-components 1
[ -f "$WORK/src/mole" ] && [ -f "$WORK/src/bin/clean.sh" ] && [ -d "$WORK/src/lib" ] || { echo "✗ Mole's source archive isn't laid out as expected" >&2; exit 1; }
SRC_VERSION=$(sed -n 's/^VERSION="\([0-9.]*\)".*/\1/p' "$WORK/src/mole")
[ "$SRC_VERSION" = "$VERSION" ] || { echo "✗ The archive says Mole $SRC_VERSION, not $VERSION" >&2; exit 1; }

curl -fsSL --retry 3 -o "$WORK/SHA256SUMS" "https://github.com/tw93/mole/releases/download/$TAG/SHA256SUMS"
for tool in analyze status; do
  asset="$tool-darwin-$ARCH"
  curl -fsSL --retry 3 -o "$WORK/$asset" "https://github.com/tw93/mole/releases/download/$TAG/$asset"
  expected=$(awk -v a="$asset" '$2 == a { print $1 }' "$WORK/SHA256SUMS")
  actual=$(shasum -a 256 "$WORK/$asset" | awk '{ print $1 }')
  [ -n "$expected" ] && [ "$expected" = "$actual" ] || { echo "✗ $asset doesn't match Mole's published checksum" >&2; exit 1; }
  install -m 755 "$WORK/$asset" "$WORK/src/bin/$tool-go"
done

rm -rf "$DEST"
mkdir -p "$DEST/bin" "$DEST/libexec"
ditto "$WORK/src/bin" "$DEST/libexec/bin"
ditto "$WORK/src/lib" "$DEST/libexec/lib"
install -m 755 "$WORK/src/mole" "$DEST/bin/mole"
cp "$WORK/src/LICENSE" "$DEST/LICENSE"
chmod 755 "$DEST"/libexec/bin/*.sh
echo "✓ Mole $VERSION in $DEST (helpers match SHA256SUMS)"
