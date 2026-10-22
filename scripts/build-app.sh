#!/usr/bin/env bash
# Usage: scripts/build-app.sh [--install]
# Signs with your Apple Development identity so macOS keeps Accessibility/Screen Recording grants across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/ActivityTracker.app"
BUNDLE_ID="com.vikalppanseriya.ActivityTracker"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/ActivityTracker" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [[ -z "$IDENTITY" ]]; then
  echo "warning: no Apple Development identity; ad-hoc signing means permissions reset on every rebuild" >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
echo "Built $APP (signed with: $IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x ActivityTracker || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/ActivityTracker.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/ActivityTracker.app"
  echo "Installed to ~/Applications/ActivityTracker.app"
fi
