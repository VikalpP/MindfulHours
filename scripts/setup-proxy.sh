#!/usr/bin/env bash
# Optional, for the Custom provider: installs CLIProxyAPI, signs in with your Claude subscription, and points
# MindfulHours at it. Most people should pick a provider in MindfulHours Settings instead.
# Usage: scripts/setup-proxy.sh [--relogin]
set -euo pipefail

APP_DOMAIN="com.vikalppanseriya.MindfulHours"
BASE_URL="http://127.0.0.1:8317/v1"

command -v cliproxyapi >/dev/null || brew install cliproxyapi
CONFIG="$(brew --prefix)/etc/cliproxyapi.conf"

if grep -q '"your-api-key-1"' "$CONFIG"; then
  cp "$CONFIG" "$CONFIG.bak"
  export KEY="at-$(openssl rand -hex 24)"
  # Bind to localhost only and replace the placeholder client keys.
  perl -0pi -e 's/^  host: ""/  host: "127.0.0.1"/m; s/"your-api-key-1"/"$ENV{KEY}"/; s/^\s*- "your-api-key-[23]"\n//mg' "$CONFIG"
  echo "Configured $CONFIG (backup at $CONFIG.bak)"
else
  KEY="$(awk '/^access:/ { inAccess = 1 } inAccess && /api-keys:/ { inKeys = 1; next } inKeys && /-/ { print; exit }' "$CONFIG" \
    | sed -E 's/^[[:space:]]*-[[:space:]]*"?([^"]*)"?.*$/\1/')"
  echo "Using existing client key from $CONFIG"
fi

if [[ "${1:-}" == "--relogin" ]] || ! ls "$HOME"/.cli-proxy-api/claude-*.json >/dev/null 2>&1; then
  echo "Opening browser for Claude sign-in…"
  cliproxyapi -claude-login
fi

brew services restart cliproxyapi
MODELS_JSON=""
for _ in {1..60}; do
  MODELS_JSON="$(curl -sf -H "Authorization: Bearer $KEY" "$BASE_URL/models" || true)"
  [[ -n "$MODELS_JSON" ]] && break
  sleep 0.5
done
if [[ -z "$MODELS_JSON" ]]; then
  echo "error: CLIProxyAPI did not answer on $BASE_URL within 30s; check: brew services info cliproxyapi" >&2
  exit 1
fi

MODELS="$(python3 -c 'import json,sys; print("\n".join(m["id"] for m in json.load(sys.stdin)["data"]))' <<<"$MODELS_JSON")"
PREFERRED_MODEL="claude-haiku-5-5"
if grep -qx "$PREFERRED_MODEL" <<<"$MODELS"; then
  MODEL="$PREFERRED_MODEL"
else
  MODEL="$(grep -E '^claude-haiku' <<<"$MODELS" | sort -V | tail -1 || true)"
  MODEL="${MODEL:-$(grep claude <<<"$MODELS" | sort -V | tail -1 || true)}"
fi
if [[ -z "$MODEL" ]]; then
  echo "error: proxy is up but lists no Claude models. Available:" >&2
  echo "$MODELS" >&2
  exit 1
fi

defaults write "$APP_DOMAIN" aiProvider custom
defaults write "$APP_DOMAIN" customBaseURL "$BASE_URL"
defaults write "$APP_DOMAIN" model.custom "$MODEL"
# MindfulHours moves this key into the Keychain at launch.
defaults write "$APP_DOMAIN" customAPIKey "$KEY"

if pgrep -xq MindfulHours; then
  osascript -e 'quit app "MindfulHours"'
  while pgrep -xq MindfulHours; do sleep 0.2; done
  open -a MindfulHours
fi
echo "MindfulHours now uses $MODEL via $BASE_URL"
