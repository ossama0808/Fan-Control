#!/bin/bash
# Cut a release: build, package, changelog, tag, push, publish.
#
#   ./release.sh 1.1.0
#   ./release.sh 1.1.0 --skip-tests     # only if you already ran them
#
# Publishes a GitHub release with the .pkg installer attached, and commits the
# same notes to CHANGELOG.md so the repository carries its own history rather
# than leaving it only on GitHub.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: ./release.sh <major.minor.patch> [--skip-tests]" >&2
    exit 1
fi
SKIP_TESTS="${2:-}"
TAG="v$VERSION"

command -v gh >/dev/null || { echo "gh CLI not found: brew install gh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated: gh auth login" >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || { echo "working tree is dirty — commit first" >&2; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "tag $TAG already exists" >&2; exit 1; }

# The checks drive the fans, so nothing else may be driving them.
pkill -f "Fan Control.app" 2>/dev/null || true
sleep 2
if [ "$SKIP_TESTS" != "--skip-tests" ]; then
    echo "==> running checks"
    swift run selftest
fi

echo "$VERSION" > VERSION
./package.sh "$VERSION"
PKG="dist/Fan-Control-$VERSION.pkg"
[ -f "$PKG" ] || { echo "installer not built" >&2; exit 1; }

# Notes from the commits since the previous tag.
PREV=$(git describe --tags --abbrev=0 2>/dev/null || true)
RANGE=${PREV:+$PREV..HEAD}
NOTES=$(git log --no-merges --format='- %s' ${RANGE:-HEAD})
[ -n "$NOTES" ] || NOTES="- Initial release"

DATE=$(date +%Y-%m-%d)
TMP=$(mktemp)
{
    echo "## $VERSION — $DATE"
    echo
    echo "$NOTES"
    echo
    [ -f CHANGELOG.md ] && tail -n +2 CHANGELOG.md
} > "$TMP"
{ echo "# Changelog"; echo; cat "$TMP"; } > CHANGELOG.md
rm -f "$TMP"

git add VERSION CHANGELOG.md
git commit -q -m "Release $VERSION"
git tag -a "$TAG" -m "Fan Control $VERSION"
git push -q origin main
git push -q origin "$TAG"

gh release create "$TAG" "$PKG" \
    --title "Fan Control $VERSION" \
    --notes "$(printf '%s\n\n---\n\n**Install:** download the `.pkg` below and open it. It installs the app to /Applications and the privileged fan helper, then launches the app.\n\nThe package is not notarized, so macOS will warn on first open — right-click the `.pkg` and choose Open, or allow it under System Settings > Privacy & Security.\n' "$NOTES")"

echo
echo "Released $TAG"
gh release view "$TAG" --json url -q .url
