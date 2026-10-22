#!/usr/bin/env bash
# Usage: scripts/package-release.sh VERSION
# Packages build/MindfulHours.app into dist/ as a zip and a drag-to-Applications DMG, plus SHA-256 checksums.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/package-release.sh VERSION}"
APP="build/MindfulHours.app"
DIST="dist"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

rm -rf "$DIST"
mkdir -p "$DIST"

ditto -c -k --keepParent "$APP" "$DIST/MindfulHours-$VERSION.zip"

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "MindfulHours $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO \
  "$DIST/MindfulHours-$VERSION.dmg"

(cd "$DIST" && shasum -a 256 MindfulHours-* > SHA256SUMS.txt)
ls -lh "$DIST"
