#!/usr/bin/env bash
# Package a public, unsigned (ad-hoc) Release build of Tungsten Edge 钨极
# as both a .dmg (drag-to-install) and a .zip (Homebrew cask).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/macos-dock-cc-v2.xcodeproj"
SCHEME="macos-dock-cc-v2"
BUILT_NAME="macos-dock-cc-v2"     # PRODUCT_NAME of the target
APP_NAME="Tungsten Edge"          # public .app name
VOL_NAME="Tungsten Edge 钨极"

DD="$ROOT/build/ReleaseDD"
DIST="$ROOT/dist"
PRODUCTS="$DD/Build/Products/Release"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist" 2>/dev/null || true)"
# Info.plist uses a build var, so fall back to the project's MARKETING_VERSION.
if [[ -z "$VERSION" || "$VERSION" == *'$('* ]]; then
  VERSION="$(grep -m1 'MARKETING_VERSION' "$PROJECT/project.pbxproj" | sed -E 's/.*= ([0-9.]+);/\1/')"
fi
echo "==> Version $VERSION"

echo "==> Building universal Release (x86_64 + arm64)…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DD" \
  ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO \
  clean build >/tmp/tungsten-package-build.log 2>&1
echo "    build ok"

rm -rf "$DIST"; mkdir -p "$DIST"
STAGE="$(mktemp -d)"
APP="$STAGE/$APP_NAME.app"
cp -R "$PRODUCTS/$BUILT_NAME.app" "$APP"

echo "==> Verifying architectures:"
lipo -info "$APP/Contents/MacOS/$BUILT_NAME" || true

echo "==> Ad-hoc re-signing (so right-click→Open works on other Macs)…"
codesign --remove-signature "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|TeamIdentifier|Signature' || true

echo "==> Creating .zip (Homebrew cask)…"
ZIP="$DIST/Tungsten-Edge-$VERSION.zip"
( cd "$STAGE" && ditto -c -k --keepParent "$APP_NAME.app" "$ZIP" )

echo "==> Creating .dmg (drag-to-install)…"
DMG_STAGE="$(mktemp -d)"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
DMG="$DIST/Tungsten-Edge-$VERSION.dmg"
hdiutil create -volname "$VOL_NAME" -srcfolder "$DMG_STAGE" \
  -ov -format UDZO "$DMG" >/dev/null

echo "==> Checksums:"
( cd "$DIST" && shasum -a 256 *.dmg *.zip )

rm -rf "$STAGE" "$DMG_STAGE"
echo "==> Done. Artifacts in: $DIST"
ls -la "$DIST"
