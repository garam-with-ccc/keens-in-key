#!/bin/bash
# Builds KeensInKey.app (release), signs it, optionally notarizes and staples it, and produces a zip + dmg in dist/.
#
# Environment:
#   VERSION            version string (default: contents of VERSION file)
#   UNIVERSAL=1        build arm64 + x86_64
#   CODESIGN_IDENTITY  "Developer ID Application: Name (TEAMID)" — default "-" (ad-hoc)
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER
#                      App Store Connect API key for `notarytool`; when all three are set the
#                      app and the dmg are notarized and stapled (requires a Developer ID identity)
#   NOTARY_PROFILE     alternatively, a `notarytool store-credentials` keychain profile name
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 0.1.0)}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${CODESIGN_IDENTITY:--}"
ARCH_FLAGS=""
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS="--arch arm64 --arch x86_64"; fi

NOTARY_ARGS=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
  NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
fi
NOTARIZE=0
if [[ ${#NOTARY_ARGS[@]} -gt 0 && "$IDENTITY" != "-" ]]; then NOTARIZE=1; fi

echo "▶ swift build (release, v$VERSION build $BUILD)"
swift build -c release --product KeensInKey $ARCH_FLAGS 2>&1 | tail -1
swift build -c release --product kik $ARCH_FLAGS 2>&1 | tail -1
BIN_DIR="$(swift build -c release $ARCH_FLAGS --show-bin-path)"

APP="dist/KeensInKey.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/KeensInKey" "$APP/Contents/MacOS/KeensInKey"
cp "$BIN_DIR/kik" "$APP/Contents/MacOS/kik"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

if [[ "$IDENTITY" == "-" ]]; then
  echo "▶ codesign (ad-hoc)"
  codesign --force --sign - "$APP/Contents/MacOS/kik"
  codesign --force --sign - --options runtime --entitlements Resources/KeensInKey.entitlements "$APP"
else
  echo "▶ codesign ($IDENTITY, hardened runtime, timestamp)"
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP/Contents/MacOS/kik"
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements Resources/KeensInKey.entitlements "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "  signature OK"

mkdir -p dist
ZIP="dist/KeensInKey-$VERSION.zip"
DMG="dist/KeensInKey-$VERSION.dmg"
rm -f "$ZIP" "$DMG"

if [[ "$NOTARIZE" == "1" ]]; then
  echo "▶ notarizing app"
  ditto -c -k --keepParent "$APP" "dist/notarize-upload.zip"
  xcrun notarytool submit "dist/notarize-upload.zip" "${NOTARY_ARGS[@]}" --wait 2>&1 | tail -4
  rm -f "dist/notarize-upload.zip"
  xcrun stapler staple "$APP" | tail -1
fi

echo "▶ packaging"
ditto -c -k --keepParent "$APP" "$ZIP"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Keens In Key" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi
if [[ "$NOTARIZE" == "1" ]]; then
  echo "▶ notarizing dmg"
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait 2>&1 | tail -4
  xcrun stapler staple "$DMG" | tail -1
  echo "▶ gatekeeper check"
  spctl -a -vv -t install "$DMG" 2>&1 | tail -2 || true
  spctl -a -vv -t exec "$APP" 2>&1 | tail -2 || true
fi
ls -la "$ZIP" "$DMG"
echo "✓ built $APP"
