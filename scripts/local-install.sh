#!/bin/bash
# Compile the unofficial local Grok.app and install it to /Applications,
# signed with the stable "Grok Local" identity (TCC persists).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Grok-macOS"
OUT="$ROOT/dist/Grok.app"
MACOS="$OUT/Contents/MacOS"
RES="$OUT/Contents/Resources"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

mkdir -p "$MACOS" "$RES"

cp "$SRC/Info.plist" "$OUT/Contents/Info.plist"

# Compile every app source. -Onone: -O has crashed the SIL inliner on this tree.
# shellcheck disable=SC2046
swiftc -parse-as-library -Onone \
  -default-isolation MainActor \
  -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework WebKit \
  -framework Carbon \
  -framework AVFoundation \
  -framework Speech \
  -framework ServiceManagement \
  -framework Combine \
  -o "$MACOS/Grok" \
  $(ls "$SRC"/*.swift)

"$ROOT/scripts/sign-local.sh" "$OUT"

if pgrep -x Grok >/dev/null; then
  kill $(pgrep -x Grok) || true
  sleep 0.4
fi

ditto "$OUT" /Applications/Grok.app
"$ROOT/scripts/sign-local.sh" /Applications/Grok.app
xattr -c /Applications/Grok.app 2>/dev/null || true

echo "installed /Applications/Grok.app"
