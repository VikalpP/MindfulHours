#!/usr/bin/env bash
# Usage: scripts/take-screenshots.sh [output-dir]   (default: docs/screenshots)
#
# Renders the menu-bar popup, Timeline and Settings windows in light and dark from the installed app, at full
# height with the real window frame and shadow. Keep the Mac unlocked while it runs: locked screens can't be
# captured and windows would render in their inactive style.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="/Applications/MindfulHours.app"
if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found; install it first with scripts/build-app.sh --install" >&2
  exit 1
fi

OUT="${1:-docs/screenshots}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ERRORS="$(mktemp)"
trap 'rm -f "$ERRORS"' EXIT

# Launched with `open` (not the binary) so macOS checks the app's own Screen Recording permission.
render() {
  local target="$1" appearance="$2"
  shift 2
  local file="$OUT/$target-$appearance.png"
  rm -f "$file"
  open -n -W "$@" --stderr "$ERRORS" "$APP" --args "--snapshot-$target" "$file" --appearance "$appearance"
  if [[ ! -s "$file" ]]; then
    cat "$ERRORS" >&2
    echo "error: could not render $target ($appearance)" >&2
    exit 1
  fi
  echo "  $file"
}

echo "Rendering screenshots into $OUT"
for appearance in light dark; do
  # -g keeps the launch in the background, so the popup shows the app you're actually using.
  render menu "$appearance" -g
  render timeline "$appearance"
  render settings "$appearance"
done
