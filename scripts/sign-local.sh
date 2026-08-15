#!/bin/bash
# Sign an .app with the stable "Grok Local" identity.
set -euo pipefail

APP="${1:?usage: sign-local.sh /path/to/Grok.app}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="$("$(dirname "$0")/ensure-local-identity.sh")"
DIR="${GROK_CODESIGN_DIR:-$HOME/.grok/local-codesign}"
KEYCHAIN="$DIR/grok-local.keychain-db"
PASS="$(cat "$DIR/keychain.pass")"

security unlock-keychain -p "$PASS" "$KEYCHAIN"

# Identifier must stay constant so TCC keeps matching this app.
codesign --force --sign "$IDENTITY" \
  --keychain "$KEYCHAIN" \
  --identifier "com.nhershy.Grok-macOS" \
  --timestamp=none \
  "$APP"

codesign --verify --verbose "$APP"
echo "signed $APP as $IDENTITY"
