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
# A plain ad-hoc signature identifies the app by the hash of this exact build, so
# macOS forgets the Accessibility grant on every rebuild. Pinning the designated
# requirement to the bundle identifier instead keeps the grant across rebuilds.
# Set CLAWDPET_SIGN_IDENTITY to sign with a real or self-signed certificate.
codesign --force --deep --sign "${CLAWDPET_SIGN_IDENTITY:--}" --identifier dev.clawdpet.app \
  -r '=designated => identifier "dev.clawdpet.app"' "$APP" >/dev/null 2>&1 || echo "codesign skipped"

echo "Built $APP"
echo "Run it:      open $APP"
echo "Install it:  cp -R $APP /Applications/"
