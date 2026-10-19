#!/bin/sh
# Publishes dist/ as GitHub release v<VERSION>, but only when it's safe to:
#   - the files in dist/ were built by Roomy/release.sh from this exact commit, with no local changes,
#   - that commit is on GitHub's main, and
#   - GitHub's "Build Roomy" check passed for that commit.
# Every Roomy checks releases/latest for updates, so publishing is what ships a version to everyone.
#   scripts/publish-release.sh
set -eu
cd "$(dirname "$0")/.."
REPO=dibyajyotiron/roomy
VERSION=$(cat VERSION)
TAG="v$VERSION"
fail() { echo "✗ $*" >&2; exit 1; }

[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "There are uncommitted changes. Commit or stash them, rebuild with Roomy/release.sh, then publish."
HEAD=$(git rev-parse HEAD)
[ "$(cat dist/BUILD_COMMIT 2>/dev/null || true)" = "$HEAD" ] || fail "dist/ wasn't built from this commit. Run Roomy/release.sh first."
for f in "Roomy-$VERSION.pkg" "Roomy-$VERSION.zip" "Roomy-$VERSION.sha256" appcast.xml; do
  [ -f "dist/$f" ] || fail "dist/$f is missing. Run Roomy/release.sh (with the update key in your Keychain)."
done
(cd dist && shasum -a 256 -c "Roomy-$VERSION.sha256" >/dev/null) || fail "dist/ files don't match their checksums."
grep -q "<sparkle:shortVersionString>$VERSION<" dist/appcast.xml || fail "dist/appcast.xml isn't for $VERSION."

git fetch -q origin main
git merge-base --is-ancestor "$HEAD" origin/main || fail "This commit isn't on GitHub's main yet. Push it and let CI run."
gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 && fail "$TAG already exists. Bump VERSION for a new release."

RESULT=$(gh api "repos/$REPO/commits/$HEAD/check-runs?check_name=Build%20Roomy" --jq '[.check_runs[] | .conclusion // .status] | first // "missing"')
case "$RESULT" in
  success) echo "› CI passed for ${HEAD%"${HEAD#???????}"}" ;;
  queued|in_progress|pending|waiting) fail "CI is still running for this commit. Publish once it passes." ;;
  missing) fail "CI hasn't run for this commit. Push it to main and wait for the Build check." ;;
  *) fail "CI didn't pass for this commit ($RESULT). Fix the build, push, and publish once it's green." ;;
esac

NOTES=$(mktemp)
awk -v v="## $VERSION" '$0 == v { f = 1; next } /^## / { f = 0 } f' CHANGELOG.md > "$NOTES"
gh release create "$TAG" "dist/Roomy-$VERSION.pkg" "dist/Roomy-$VERSION.zip" "dist/Roomy-$VERSION.sha256" dist/appcast.xml \
  -R "$REPO" --target "$HEAD" --title "Roomy $VERSION" --notes-file "$NOTES" --latest
rm -f "$NOTES"
echo "✓ Published $TAG"
