#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="Poke PC.app"
APP_PATH="$BUILD_DIR/$APP_NAME"
DMG_ROOT="$BUILD_DIR/dmg-root"
DMG_PATH="$BUILD_DIR/Poke-PC.dmg"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH"
  echo "Run scripts/build-macos-app.sh first"
  exit 1
fi

rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"

cp -R "$APP_PATH" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "Poke PC" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [[ -n "${APPLE_SIGN_IDENTITY:-}" ]]; then
  echo "Signing DMG with Developer ID identity"
  codesign --force --timestamp --sign "$APPLE_SIGN_IDENTITY" "$DMG_PATH"
fi

echo "DMG ready: $DMG_PATH"
