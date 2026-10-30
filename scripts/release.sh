#!/bin/bash
# Publishes the version in VERSION as a GitHub release: runs the tests, builds the
# universal app, zips it, signs the zip for the in-app updater, tags and uploads.
#
#   scripts/release.sh [--prerelease]
#
# Write release-notes/<version>.md first. The signing key is the one used for the
# cleanup rules ($DISKLENS_RULES_KEY, ~/.disklens/rules-signing.key by default).
set -euo pipefail
cd "$(dirname "$0")/.."

PRERELEASE=""
[ "${1:-}" = "--prerelease" ] && PRERELEASE="--prerelease"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
KEY="${DISKLENS_RULES_KEY:-$HOME/.disklens/rules-signing.key}"
NOTES="release-notes/$VERSION.md"

[ -f "$NOTES" ] || { echo "Write $NOTES first."; exit 1; }
[ -f "$KEY" ] || { echo "Signing key $KEY not found."; exit 1; }
[ -z "$(git status --porcelain -- Sources Package.swift VERSION scripts "$NOTES")" ] || { echo "Commit your changes first."; exit 1; }
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "$TAG already exists."; exit 1; }

swift test
scripts/build-app.sh

mkdir -p build/release
ZIP="build/release/DiskLens-$VERSION.zip"
rm -f "build/release/DiskLens-$VERSION.zip" "build/release/DiskLens-$VERSION.zip.sig"
ditto -c -k --keepParent build/DiskLens.app "$ZIP"
swift build -c release --product disklens >/dev/null
.build/release/disklens sign "$KEY" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

git tag -a "$TAG" -m "DiskLens $VERSION"
git push origin "$TAG"
TITLE="DiskLens $VERSION"
[ -n "$PRERELEASE" ] && TITLE="$TITLE 预览版"
{ cat "$NOTES"; printf '\nSHA-256（DiskLens-%s.zip）：`%s`\n' "$VERSION" "$SHA"; } > build/release/notes.md
gh release create "$TAG" "$ZIP" "$ZIP.sig" --title "$TITLE" --notes-file build/release/notes.md $PRERELEASE
echo "Released $TAG"
