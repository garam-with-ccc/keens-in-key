#!/bin/bash
# Builds KeensInKey.app (release), ad-hoc signs it, and produces a zip + dmg in dist/.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 0.1.0)}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCH_FLAGS=""
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS="--arch arm64 --arch x86_64"; fi

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

echo "▶ codesign (ad-hoc)"
codesign --force --deep --sign - --timestamp=none --options runtime --entitlements Resources/KeensInKey.entitlements "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --deep --strict "$APP" && echo "  signature OK"

echo "▶ packaging"
mkdir -p dist
rm -f "dist/KeensInKey-$VERSION.zip" "dist/KeensInKey-$VERSION.dmg"
ditto -c -k --keepParent "$APP" "dist/KeensInKey-$VERSION.zip"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Keens In Key" -srcfolder "$STAGE" -ov -format UDZO -quiet "dist/KeensInKey-$VERSION.dmg"
rm -rf "$STAGE"
ls -la dist/*.zip dist/*.dmg
echo "✓ built $APP"
