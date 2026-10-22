#!/usr/bin/env bash
# Usage: scripts/build-app.sh [--install]
# Signs with your Apple Development identity so macOS keeps Accessibility/Screen Recording grants across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/MindfulHours.app"
BUNDLE_ID="com.vikalppanseriya.MindfulHours"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MindfulHours" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [[ -z "$IDENTITY" ]]; then
  echo "warning: no Apple Development identity; ad-hoc signing means permissions reset on every rebuild" >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
echo "Built $APP (signed with: $IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x MindfulHours || true
  rm -rf "$HOME/Applications/MindfulHours.app"
  rm -rf "/Applications/MindfulHours.app"
  cp -R "$APP" /Applications/
  open /Applications/MindfulHours.app
  echo "Installed to /Applications/MindfulHours.app"
fi
