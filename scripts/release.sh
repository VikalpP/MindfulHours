#!/usr/bin/env bash
# Usage: scripts/release.sh VERSION [--publish]
#
# Builds, signs (Developer ID), notarizes and staples a universal release on this Mac into dist/VERSION/.
# Needs a "Developer ID Application" identity in the keychain (override with $CODESIGN_IDENTITY) and a
# notarytool Keychain profile (default "mindfulhours-notary", override with $NOTARY_PROFILE).
# Without --publish it prints the tag and `gh release create` commands; with it, it runs them (from main only).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=""
PUBLISH=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --publish) PUBLISH=true ;;
    -*) echo "unknown option: $1" >&2; exit 64 ;;
    *) VERSION="$1" ;;
  esac
  shift
done

APP="build/MindfulHours.app"
TAG="v$VERSION"
DIST="dist/$VERSION"
DMG="$DIST/MindfulHours-$VERSION.dmg"
ZIP="$DIST/MindfulHours-$VERSION.zip"
SUMS="$DIST/SHA256SUMS.txt"
NOTES="RELEASE_NOTES.md"
NOTARY_PROFILE="${NOTARY_PROFILE:-mindfulhours-notary}"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

fail() { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

find_developer_id_identity() {
  local matches
  matches="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2 }' | sort -u)"
  [[ -n "$matches" ]] || fail "no Developer ID Application identity in the keychain"
  [[ "$(wc -l <<<"$matches")" -eq 1 ]] || fail "several Developer ID identities; pick one with CODESIGN_IDENTITY:"$'\n'"$matches"
  echo "$matches"
}

check_tag_is_new() {
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists locally"
  local remote_status=0
  git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || remote_status=$?
  case "$remote_status" in
    0) fail "tag $TAG already exists on origin" ;;
    2) ;;
    *) fail "could not list tags on origin (git ls-remote exit $remote_status)" ;;
  esac
  if command -v gh >/dev/null && gh release view "$TAG" >/dev/null 2>&1; then
    fail "GitHub release $TAG already exists"
  fi
}

check_publishing_from_pushed_main() {
  command -v gh >/dev/null || fail "--publish needs the gh CLI"
  [[ "$(git branch --show-current)" == main ]] || fail "--publish must run on main"
  git fetch --quiet origin main
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main is not in sync with origin/main; push or pull first"
}

notarize() {
  local file="$1" result status id
  result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
  id="$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null)" || fail "notarytool submit failed: $result"
  status="$(plutil -extract status raw -o - - <<<"$result")"
  echo "notarization submission $id: $status ($(basename "$file"))"
  if [[ "$status" != Accepted ]]; then
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fail "notarization of $(basename "$file") was $status"
  fi
}

check_signature() {
  local target="$1" details
  codesign --verify --deep --strict --verbose=2 "$target"
  details="$(codesign -dv --verbose=4 "$target" 2>&1)"
  grep -qxF "Authority=$IDENTITY" <<<"$details" || fail "$target is not signed by $IDENTITY"
  grep -qxF "TeamIdentifier=$TEAM_ID" <<<"$details" || fail "$target has the wrong team identifier"
  grep -q '^Timestamp=' <<<"$details" || fail "$target has no secure timestamp"
}

check_weak_linked_foundation_models() {
  local arch
  for arch in arm64 x86_64; do
    otool -arch "$arch" -l "$APP/Contents/MacOS/MindfulHours" \
      | grep -B2 FoundationModels.framework | grep LC_LOAD_WEAK_DYLIB >/dev/null \
      || fail "FoundationModels is not weak-linked for $arch (the app must launch on macOS 14/15)"
  done
}

step "Checking release prerequisites"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || fail "usage: scripts/release.sh X.Y.Z[-suffix] [--publish]"
[[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean"
[[ -f "$NOTES" ]] || fail "$NOTES is missing"
xcodebuild -version | awk 'NR == 1 && $2 + 0 < 27 { exit 1 }' \
  || fail "Xcode 27 or later is required (Apple Intelligence screenshot support needs the macOS 27 SDK)"
check_tag_is_new
[[ "$PUBLISH" == true ]] && check_publishing_from_pushed_main
IDENTITY="${CODESIGN_IDENTITY:-$(find_developer_id_identity)}"
security find-identity -v -p codesigning | grep -F "\"$IDENTITY\"" >/dev/null || fail "signing identity not found: $IDENTITY"
[[ "$IDENTITY" =~ \(([A-Z0-9]{10})\)$ ]] || fail "cannot read the team ID from: $IDENTITY"
TEAM_ID="${BASH_REMATCH[1]}"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
  || fail "notarytool profile '$NOTARY_PROFILE' is missing or invalid (xcrun notarytool store-credentials)"
COMMIT="$(git rev-parse HEAD)"
BUILD_NUMBER="$(git rev-list --count HEAD)"
echo "MindfulHours $VERSION (build $BUILD_NUMBER) from $COMMIT"
echo "Signing with: $IDENTITY"

step "Testing"
swift test

step "Building and signing the universal app"
CODESIGN_IDENTITY="$IDENTITY" scripts/build-app.sh --universal --version "$VERSION" --build-number "$BUILD_NUMBER"
check_weak_linked_foundation_models
check_signature "$APP"
grep -q 'flags=.*(runtime)' <<<"$(codesign -dv "$APP" 2>&1)" || fail "$APP is not signed with the hardened runtime"

step "Notarizing the app"
ditto -c -k --keepParent "$APP" "$SCRATCH/MindfulHours.zip"
notarize "$SCRATCH/MindfulHours.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP"

step "Packaging the zip and DMG"
rm -rf "$DIST"
mkdir -p "$DIST" "$SCRATCH/dmg"
ditto -c -k --keepParent "$APP" "$ZIP"
ditto "$APP" "$SCRATCH/dmg/MindfulHours.app"
ln -s /Applications "$SCRATCH/dmg/Applications"
hdiutil create -quiet -volname "MindfulHours $VERSION" -srcfolder "$SCRATCH/dmg" -fs HFS+ -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
check_signature "$DMG"

step "Notarizing the DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vv -t install "$DMG"

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS.txt && shasum -a 256 -c SHA256SUMS.txt)
ls -lh "$DIST"

PRERELEASE_FLAG=""
[[ "$VERSION" == *-* ]] && PRERELEASE_FLAG=" --prerelease"
TAG_COMMAND="git tag -a $TAG -m \"MindfulHours $VERSION\" $COMMIT && git push origin $TAG"
RELEASE_COMMAND="gh release create $TAG --verify-tag --title \"MindfulHours $VERSION\" --notes-file $NOTES$PRERELEASE_FLAG $DMG $ZIP $SUMS"

if [[ "$PUBLISH" == true ]]; then
  step "Publishing $TAG"
  eval "$TAG_COMMAND"
  eval "$RELEASE_COMMAND"
else
  step "Built $DIST from $COMMIT. To publish these exact files, once $COMMIT is on origin/main:"
  echo "$TAG_COMMAND"
  echo "$RELEASE_COMMAND"
fi
