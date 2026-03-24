#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_NAME="PokePCNative"
APP_NAME="Poke PC"
BUNDLE_ID="${APP_BUNDLE_ID:-dev.calgan.poke-pc}"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
BIN_DIR="$ROOT_DIR/.build/release"
BIN_PATH="$BIN_DIR/$PRODUCT_NAME"
ICON_CATALOG_DIR="$ROOT_DIR/Assets.xcassets"
VERSION_FILE="$ROOT_DIR/VERSION"

if [[ -n "${APP_VERSION:-}" ]]; then
  VERSION="$APP_VERSION"
elif [[ -f "$VERSION_FILE" ]]; then
  VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
elif [[ -f "$ROOT_DIR/../package.json" ]]; then
  VERSION="$(node -e "console.log(require(process.argv[1]).version)" "$ROOT_DIR/../package.json")"
else
  VERSION="0.1.0"
fi

BUILD_NUMBER="${APP_BUILD:-${GITHUB_RUN_NUMBER:-1}}"

mkdir -p "$BUILD_DIR"

echo "[1/4] Building release binary"
cd "$ROOT_DIR"
swift build -c release --product "$PRODUCT_NAME"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Release binary not found at $BIN_PATH"
  exit 1
fi

echo "[2/4] Creating app bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$PRODUCT_NAME"

if [[ -d "$ICON_CATALOG_DIR/AppIcon.appiconset" ]]; then
  xcrun actool \
    "$ICON_CATALOG_DIR" \
    --compile "$APP_DIR/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$BUILD_DIR/asset-info.plist" \
    >/dev/null
fi

echo "[3/4] Writing Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>__APP_NAME__</string>
  <key>CFBundleDisplayName</key>
  <string>__APP_NAME__</string>
  <key>CFBundleIdentifier</key>
  <string>__BUNDLE_ID__</string>
  <key>CFBundleVersion</key>
  <string>__BUILD_NUMBER__</string>
  <key>CFBundleShortVersionString</key>
  <string>__VERSION__</string>
  <key>CFBundleExecutable</key>
  <string>PokePCNative</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

perl -0pi -e "s/__APP_NAME__/$APP_NAME/g; s/__BUNDLE_ID__/$BUNDLE_ID/g; s/__BUILD_NUMBER__/$BUILD_NUMBER/g; s/__VERSION__/$VERSION/g" "$APP_DIR/Contents/Info.plist"

echo "[4/4] Applying ad-hoc code signature"
SIGN_IDENTITY="${APPLE_SIGN_IDENTITY:--}"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null 2>&1 || true

echo "App bundle ready: $APP_DIR"
