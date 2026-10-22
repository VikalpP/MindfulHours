#!/usr/bin/env bash
# Usage: scripts/build-app.sh [--install] [--universal] [--version X.Y.Z] [--build-number N]
#
# Signing identity, in order: $CODESIGN_IDENTITY, a local "Apple Development" identity, then ad-hoc ("-").
# A stable identity keeps macOS Accessibility/Screen Recording grants across rebuilds; ad-hoc does not.
# A "Developer ID Application" identity also enables the hardened runtime required for notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/MindfulHours.app"
BUNDLE_ID="com.vikalppanseriya.MindfulHours"
INSTALL=false
ARCH_FLAGS=()
VERSION=""
BUILD_NUMBER="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) INSTALL=true ;;
    --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
    --version) VERSION="$2"; shift ;;
    --build-number) BUILD_NUMBER="$2"; shift ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_PATH="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/MindfulHours" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [[ -z "$IDENTITY" ]]; then
  echo "warning: no signing identity; ad-hoc signing means permissions reset on every rebuild" >&2
  IDENTITY="-"
fi

SIGN_FLAGS=(--force --sign "$IDENTITY" --identifier "$BUNDLE_ID")
if [[ "$IDENTITY" == *"Developer ID Application"* ]]; then
  SIGN_FLAGS+=(--options runtime --timestamp --entitlements Resources/MindfulHours.entitlements)
fi
codesign "${SIGN_FLAGS[@]}" "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/MindfulHours"); signed with: $IDENTITY)"

if [[ "$INSTALL" == true ]]; then
  pkill -x MindfulHours || true
  # Relaunching while the old instance is still exiting makes `open` fail with error -600.
  for _ in {1..50}; do pgrep -x MindfulHours >/dev/null || break; sleep 0.1; done
  rm -rf "$HOME/Applications/MindfulHours.app"
  rm -rf "/Applications/MindfulHours.app"
  cp -R "$APP" /Applications/
  open /Applications/MindfulHours.app
  echo "Installed to /Applications/MindfulHours.app"
fi
