#!/bin/sh
# Owner-operated publishing: validate authenticated artifacts and exact-commit CI before exposing a release.
# This script is a voluntary release gate; repository permissions and rules must separately protect publishing.
set -eu
cd "$(dirname "$0")/.."
REPO=dibyajyotiron/roomy
VERSION=$(cat VERSION)
TAG="v$VERSION"
fail() { echo "✗ $*" >&2; exit 1; }
[ -z "$(git -c core.fsmonitor=false -c core.hooksPath=/dev/null status --porcelain --untracked-files=normal)" ] \
  || fail "The source checkout must be clean, including untracked files. Commit reviewed changes and rebuild first."
HEAD=$(git rev-parse HEAD)
[ "$(cat dist/BUILD_COMMIT 2>/dev/null || true)" = "$HEAD" ] || fail "dist/ was not built from this exact clean commit."
python3 -I scripts/release-validation.py verify dist --version "$VERSION" --commit "$HEAD"
DEFAULT=$(gh api "repos/$REPO" --jq .default_branch)
[ "$DEFAULT" = main ] || fail "The default branch changed; update the release and CI policy before publishing."
git -c core.hooksPath=/dev/null fetch -q origin "$DEFAULT"
[ "$HEAD" = "$(git rev-parse "origin/$DEFAULT")" ] || fail "Only the current remote default-branch commit can be published."
python3 -I scripts/release-validation.py ci "$HEAD"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then fail "$TAG already exists. Review it explicitly or bump VERSION."; fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
awk -v v="## $VERSION" '$0 == v { f = 1; next } /^## / { f = 0 } f' CHANGELOG.md > "$WORK/notes"
# A failed validation below leaves a draft for inspection, without exposing it as an update.
gh release create "$TAG" "dist/Roomy-$VERSION.pkg" "dist/Roomy-$VERSION.zip" "dist/Roomy-$VERSION.sha256" \
  dist/appcast.xml dist/release-manifest.json dist/release-manifest.sig \
  -R "$REPO" --target "$HEAD" --title "Roomy $VERSION" --notes-file "$WORK/notes" --draft
mkdir "$WORK/download"
gh release download "$TAG" -R "$REPO" --dir "$WORK/download"
python3 -I scripts/release-validation.py verify "$WORK/download" --version "$VERSION" --commit "$HEAD"
[ "$(gh api "repos/$REPO/commits/$TAG" --jq .sha)" = "$HEAD" ] || fail "The release tag does not resolve to the expected commit. Draft retained."
[ "$(gh api "repos/$REPO/commits/$DEFAULT" --jq .sha)" = "$HEAD" ] || fail "The default branch moved. Draft retained."
python3 -I scripts/release-validation.py ci "$HEAD"
gh release edit "$TAG" -R "$REPO" --draft=false --latest
echo "✓ Published $TAG"
