#!/bin/bash
# Builds ClawdPet.app into dist/. Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release 2>&1 | grep -v '^\[' || true
BIN=".build/release/ClawdPet"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

APP="dist/ClawdPet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClawdPet"
cp Info.plist "$APP/Contents/Info.plist"

# App icon rendered from the sprite itself.
ICONSET="dist/ClawdPet.iconset"
rm -rf "$ICONSET"
"$BIN" --render-icon "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/ClawdPet.icns" 2>/dev/null || echo "iconutil skipped"
rm -rf "$ICONSET"

# Ad-hoc signature keeps macOS happy about launch-at-login and network listening.
# Every ad-hoc build looks like a new app to macOS, which drops the Accessibility
# grant. Set CLAWDPET_SIGN_IDENTITY to a self-signed code-signing certificate
# (Keychain Access > Certificate Assistant) to keep the grant across rebuilds.
codesign --force --deep --sign "${CLAWDPET_SIGN_IDENTITY:--}" "$APP" >/dev/null 2>&1 || echo "codesign skipped"

echo "Built $APP"
echo "Run it:      open $APP"
echo "Install it:  cp -R $APP /Applications/"
