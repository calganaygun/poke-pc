#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/build/Poke PC.app"
DMG_PATH="$ROOT_DIR/build/Poke-PC.dmg"
APP_ZIP_PATH="$ROOT_DIR/build/Poke-PC.app.zip"

"$ROOT_DIR/scripts/build-macos-app.sh"

if [[ -n "${APPLE_NOTARY_APPLE_ID:-}" && -n "${APPLE_NOTARY_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_NOTARY_TEAM_ID:-}" ]]; then
	if [[ -z "${APPLE_SIGN_IDENTITY:-}" ]]; then
		echo "APPLE_SIGN_IDENTITY must be set when notarization secrets are configured"
		exit 1
	fi

	echo "Submitting app bundle for notarization"
	rm -f "$APP_ZIP_PATH"
	ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$APP_ZIP_PATH"
	xcrun notarytool submit "$APP_ZIP_PATH" \
		--apple-id "$APPLE_NOTARY_APPLE_ID" \
		--password "$APPLE_NOTARY_APP_SPECIFIC_PASSWORD" \
		--team-id "$APPLE_NOTARY_TEAM_ID" \
		--wait
	rm -f "$APP_ZIP_PATH"

	echo "Stapling app notarization ticket"
	xcrun stapler staple "$APP_PATH"
	xcrun stapler validate "$APP_PATH"
else
	echo "Notarization secrets not set; skipping app notarization/stapling"
fi

"$ROOT_DIR/scripts/build-dmg.sh"

if [[ -n "${APPLE_NOTARY_APPLE_ID:-}" && -n "${APPLE_NOTARY_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_NOTARY_TEAM_ID:-}" ]]; then

	echo "Submitting DMG for notarization"
	xcrun notarytool submit "$DMG_PATH" \
		--apple-id "$APPLE_NOTARY_APPLE_ID" \
		--password "$APPLE_NOTARY_APP_SPECIFIC_PASSWORD" \
		--team-id "$APPLE_NOTARY_TEAM_ID" \
		--wait

	echo "Stapling DMG notarization ticket"
	xcrun stapler staple "$DMG_PATH"
	xcrun stapler validate "$DMG_PATH"
fi

echo "Release artifacts are in $ROOT_DIR/build"
