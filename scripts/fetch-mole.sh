#!/bin/sh
# Fetches exactly the Mole version Roomy is pinned to (./MOLE_VERSION) from Mole's own GitHub release and lays it out
# the way Homebrew does (bin/mole, libexec/bin, libexec/lib, LICENSE), so Roomy/build.sh can bundle it with
# MOLE_HOME=<dest>. CI uses this so every build bundles the tested Mole, not whatever Homebrew has that day.
# Source and helper digests are pinned in this repository; a moved tag or changed upstream asset fails closed.
#   scripts/fetch-mole.sh <dest>
set -eu
cd "$(dirname "$0")/.."
DEST=${1:?usage: scripts/fetch-mole.sh <dest>}
VERSION=$(cat MOLE_VERSION)
REVISION=$(cat MOLE_COMMIT)
case "$REVISION" in *[!0-9a-f]* | "") echo "Invalid MOLE_COMMIT" >&2; exit 1 ;; esac
[ "${#REVISION}" = 40 ] || { echo "MOLE_COMMIT must contain a full commit SHA" >&2; exit 1; }
[ ! -e "$DEST" ] && [ ! -L "$DEST" ] || { echo "Refusing to replace an existing destination: $DEST" >&2; exit 1; }
TAG="V$VERSION"
case "$(uname -m)" in arm64) ARCH=arm64 ;; *) ARCH=amd64 ;; esac
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "› Mole $VERSION from github.com/tw93/mole"
verify() {
  expected=$(awk -v a="$2" '$2 == a { print $1 }' MOLE_CHECKSUMS)
  actual=$(shasum -a 256 "$1" | awk '{ print $1 }')
  [ -n "$expected" ] && [ "$expected" = "$actual" ] || { echo "✗ $2 doesn't match the repository's pinned checksum" >&2; exit 1; }
}
curl -fsSL --connect-timeout 20 --max-time 180 --retry 2 -o "$WORK/src.tar.gz" "https://github.com/tw93/mole/archive/$REVISION.tar.gz"
verify "$WORK/src.tar.gz" source.tar.gz
mkdir "$WORK/src"
tar -xzf "$WORK/src.tar.gz" -C "$WORK/src" --strip-components 1
[ -f "$WORK/src/mole" ] && [ -f "$WORK/src/bin/clean.sh" ] && [ -d "$WORK/src/lib" ] || { echo "✗ Mole's source archive isn't laid out as expected" >&2; exit 1; }
SRC_VERSION=$(sed -n 's/^VERSION="\([0-9.]*\)".*/\1/p' "$WORK/src/mole")
[ "$SRC_VERSION" = "$VERSION" ] || { echo "✗ The archive says Mole $SRC_VERSION, not $VERSION" >&2; exit 1; }

for tool in analyze status; do
  asset="$tool-darwin-$ARCH"
  curl -fsSL --connect-timeout 20 --max-time 180 --retry 2 -o "$WORK/$asset" "https://github.com/tw93/mole/releases/download/$TAG/$asset"
  verify "$WORK/$asset" "$asset"
  install -m 755 "$WORK/$asset" "$WORK/src/bin/$tool-go"
done

mkdir -p "$DEST/bin" "$DEST/libexec"
ditto "$WORK/src/bin" "$DEST/libexec/bin"
ditto "$WORK/src/lib" "$DEST/libexec/lib"
install -m 755 "$WORK/src/mole" "$DEST/bin/mole"
cp "$WORK/src/LICENSE" "$DEST/LICENSE"
printf '%s\n' "$REVISION" > "$DEST/ROOMY_MOLE_COMMIT"
cp MOLE_CHECKSUMS "$DEST/ROOMY_MOLE_CHECKSUMS"
chmod 755 "$DEST"/libexec/bin/*.sh
echo "✓ Mole $VERSION in $DEST (source and helpers match repository-pinned hashes)"
