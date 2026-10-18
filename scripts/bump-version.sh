#!/bin/bash
# Prepares a release: sets the version, bumps the build number, dates the changelog,
# commits and tags. Pushing the tag starts the Release workflow.
#
#   scripts/bump-version.sh 0.2.0
#   git push origin main --tags
set -euo pipefail

VERSION="${1:?usage: scripts/bump-version.sh <version, e.g. 0.2.0>}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 1.2.3" >&2; exit 1; }
cd "$(dirname "$0")/.."

[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "Tag v$VERSION already exists." >&2; exit 1; }

CONFIG=Config/Brand.xcconfig
BUILD=$(awk -F' = ' '/^CURRENT_PROJECT_VERSION/ {print $2}' "$CONFIG")
NEXT_BUILD=$((BUILD + 1))
sed -i '' -E "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $VERSION/; s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $NEXT_BUILD/" "$CONFIG"

# "## Unreleased" becomes "## 0.2.0 – 2026-11-02", and a fresh Unreleased section goes on top.
TODAY=$(date +%Y-%m-%d)
if grep -q '^## Unreleased' CHANGELOG.md; then
  awk -v v="$VERSION" -v d="$TODAY" '
    /^## Unreleased/ && !done { print "## Unreleased\n"; print "## " v " – " d; done=1; next }
    { print }' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
fi

git add "$CONFIG" CHANGELOG.md
git commit -qm "Release v$VERSION"
git tag -a "v$VERSION" -m "Vardis $VERSION"
echo "Tagged v$VERSION (build $NEXT_BUILD). Push with: git push origin main --tags"
