#!/usr/bin/env bash
# Imports a Developer ID certificate (base64 .p12 in $DEVELOPER_ID_P12_BASE64) into a throwaway CI keychain
# and exports CODESIGN_IDENTITY for later steps via $GITHUB_ENV.
set -euo pipefail

KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
CERTIFICATE="$RUNNER_TEMP/developer-id.p12"

base64 --decode <<<"$DEVELOPER_ID_P12_BASE64" > "$CERTIFICATE"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$CERTIFICATE" -k "$KEYCHAIN" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
rm -f "$CERTIFICATE"

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
if [[ -z "$IDENTITY" ]]; then
  echo "error: the certificate in DEVELOPER_ID_P12_BASE64 is not a Developer ID Application identity" >&2
  exit 1
fi
echo "CODESIGN_IDENTITY=$IDENTITY" >> "$GITHUB_ENV"
