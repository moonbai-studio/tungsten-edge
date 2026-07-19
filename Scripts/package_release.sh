#!/usr/bin/env bash
# Build, sign, notarize, and package Tungsten Edge for public distribution.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/macos-dock-cc-v2.xcodeproj"
SCHEME="macos-dock-cc-v2"
ENTITLEMENTS="$ROOT/Resources/TungstenEdge.entitlements"

APP_NAME="Tungsten Edge"
VOL_NAME="Tungsten Edge 钨极"

DD="$ROOT/build/ReleaseDD"
DIST="$ROOT/dist"
PRODUCTS="$DD/Build/Products/Release"
BUILD_LOG="${TMPDIR:-/tmp}/tungsten-edge-package-build.log"

DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"

TEMP_ROOT=""

cleanup() {
  if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
}
trap cleanup EXIT

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

build_setting() {
  local key="$1"
  awk -F ' = ' -v key="$key" '
    {
      name = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name == key) {
        print $2
        exit
      }
    }
  ' <<<"$BUILD_SETTINGS"
}

require_resolved_value() {
  local label="$1"
  local value="$2"
  if [[ -z "$value" || "$value" == *'$('* || "$value" == *'<'* || "$value" == *'>'* ]]; then
    die "$label is empty or unresolved: ${value:-<empty>}"
  fi
}

notarize_and_require_acceptance() {
  local artifact="$1"
  local receipt="$2"
  local label="$3"
  local status

  echo "==> Notarizing $label"
  if ! xcrun notarytool submit "$artifact" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait \
    --output-format json >"$receipt"; then
    [[ ! -s "$receipt" ]] || cat "$receipt" >&2
    die "$label notarization request failed"
  fi

  status="$(plutil -extract status raw -o - "$receipt" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    cat "$receipt" >&2
    die "$label notarization status was ${status:-unknown}, expected Accepted"
  fi
}

verify_developer_id_signature() {
  local artifact="$1"
  local label="$2"
  local require_runtime="$3"
  local details requirement team_id flags authority timestamp

  details="$(codesign -dvvv "$artifact" 2>&1)"
  team_id="$(sed -n 's/^TeamIdentifier=//p' <<<"$details")"
  flags="$(sed -n 's/^CodeDirectory .* flags=\([^ ]*\).*/\1/p' <<<"$details")"
  authority="$(sed -n 's/^Authority=//p' <<<"$details" | head -n 1)"
  timestamp="$(sed -n 's/^Timestamp=//p' <<<"$details")"
  [[ "$authority" == "$DEVELOPER_ID_APPLICATION" ]] || die "$label authority is '$authority', expected '$DEVELOPER_ID_APPLICATION'"
  [[ "$team_id" == "$EXPECTED_TEAM_ID" ]] || die "$label TeamIdentifier is '${team_id:-not set}', expected '$EXPECTED_TEAM_ID'"
  [[ -n "$timestamp" ]] || die "$label is missing a secure timestamp"
  if [[ "$require_runtime" == "yes" && "$flags" != *runtime* ]]; then
    die "$label is missing the hardened runtime flag"
  fi

  requirement="$(codesign -d -r- "$artifact" 2>&1)"
  grep -Fq 'designated =>' <<<"$requirement" || die "$label has no designated requirement"
  if grep -Eiq 'cdhash' <<<"$requirement"; then
    die "$label designated requirement is CDHash-bound"
  fi

  printf '    %s: TeamIdentifier=%s, flags=%s, secure timestamp present\n' "$label" "$team_id" "$flags"
}

verify_app() {
  local app="$1"
  local bundle_version bundle_build archs
  local signed_entitlements="$TEMP_ROOT/signed-entitlements.plist"

  codesign --verify --deep --strict --verbose=2 "$app"
  verify_developer_id_signature "$app" "signed app" yes

  if ! codesign -d --entitlements - --xml "$app" >"$signed_entitlements" 2>/dev/null; then
    die "could not read entitlements from signed app"
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "$signed_entitlements" 2>/dev/null || true)" != "true" ]]; then
    die "signed app is missing the Apple Events automation entitlement"
  fi

  bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true)"
  bundle_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$bundle_version" == "$VERSION" ]] || die "app version is $bundle_version, expected $VERSION"
  [[ "$bundle_build" == "$BUILD_NUMBER" ]] || die "app build is $bundle_build, expected $BUILD_NUMBER"

  archs="$(lipo -archs "$app/Contents/MacOS/$EXECUTABLE_NAME")"
  [[ " $archs " == *' arm64 '* ]] || die "app executable is missing arm64"
  [[ " $archs " == *' x86_64 '* ]] || die "app executable is missing x86_64"

  printf '    signed app: archs=%s\n' "$archs"
}

verify_zip() {
  local zip="$1"
  local extracted="$TEMP_ROOT/zip-verification"

  rm -rf "$extracted"
  mkdir -p "$extracted"
  ditto -x -k "$zip" "$extracted"
  [[ -d "$extracted/$APP_NAME.app" ]] || die "final ZIP does not contain $APP_NAME.app"
  verify_app "$extracted/$APP_NAME.app"
  verify_app_gatekeeper "$extracted/$APP_NAME.app"
}

verify_app_gatekeeper() {
  local app="$1"
  xcrun stapler validate -v "$app"
  spctl --assess --type execute --verbose=4 "$app"
}

verify_dmg() {
  local dmg="$1"
  codesign --verify --strict --verbose=2 "$dmg"
  verify_developer_id_signature "$dmg" "signed DMG" no
  xcrun stapler validate -v "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"
}

# All credential checks intentionally happen before clean/build or replacing dist/.
for command_name in awk codesign ditto grep hdiutil lipo plutil security sed shasum spctl xcodebuild xcrun; do
  require_command "$command_name"
done
[[ -f "$PROJECT/project.pbxproj" ]] || die "Xcode project not found: $PROJECT"
[[ -f "$ENTITLEMENTS" ]] || die "entitlements file not found: $ENTITLEMENTS"
plutil -lint "$ENTITLEMENTS" >/dev/null || die "invalid entitlements plist: $ENTITLEMENTS"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "$ENTITLEMENTS" 2>/dev/null || true)" != "true" ]]; then
  die "entitlements must enable com.apple.security.automation.apple-events"
fi

[[ -n "$DEVELOPER_ID_APPLICATION" ]] || die "DEVELOPER_ID_APPLICATION is required (for example: Developer ID Application: Name (TEAMID))"
[[ "$DEVELOPER_ID_APPLICATION" == 'Developer ID Application: '* ]] || die "DEVELOPER_ID_APPLICATION must name a Developer ID Application certificate"
EXPECTED_TEAM_ID="${DEVELOPER_ID_APPLICATION##*(}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID%)}"
[[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "could not parse a 10-character Team ID from DEVELOPER_ID_APPLICATION"
IDENTITIES="$(security find-identity -v -p codesigning 2>&1)"
grep -Fq "\"$DEVELOPER_ID_APPLICATION\"" <<<"$IDENTITIES" || die "Developer ID Application identity is not installed or not valid: $DEVELOPER_ID_APPLICATION"

[[ -n "$NOTARY_KEYCHAIN_PROFILE" ]] || die "NOTARY_KEYCHAIN_PROFILE is required; create one with: xcrun notarytool store-credentials <profile>"
if ! NOTARY_PREFLIGHT="$(xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --output-format json 2>&1)"; then
  die "notarytool profile '$NOTARY_KEYCHAIN_PROFILE' is missing, invalid, or unavailable; refresh it with xcrun notarytool store-credentials"
fi
unset NOTARY_PREFLIGHT

BUILD_SETTINGS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null)" \
  || die "could not resolve Release build settings"
VERSION="$(build_setting MARKETING_VERSION)"
BUILD_NUMBER="$(build_setting CURRENT_PROJECT_VERSION)"
FULL_PRODUCT_NAME="$(build_setting FULL_PRODUCT_NAME)"
EXECUTABLE_NAME="$(build_setting EXECUTABLE_NAME)"
require_resolved_value MARKETING_VERSION "$VERSION"
require_resolved_value CURRENT_PROJECT_VERSION "$BUILD_NUMBER"
require_resolved_value FULL_PRODUCT_NAME "$FULL_PRODUCT_NAME"
require_resolved_value EXECUTABLE_NAME "$EXECUTABLE_NAME"
echo "==> Release $VERSION ($BUILD_NUMBER)"
echo "==> Signing identity: $DEVELOPER_ID_APPLICATION"
echo "==> Notary profile: $NOTARY_KEYCHAIN_PROFILE"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tungsten-edge-release.XXXXXX")"
STAGE="$TEMP_ROOT/stage"
DMG_STAGE="$TEMP_ROOT/dmg-stage"
NEW_DIST="$TEMP_ROOT/dist"
mkdir -p "$STAGE" "$DMG_STAGE" "$NEW_DIST"

echo "==> Building unsigned universal Release (x86_64 + arm64)"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DD" \
  ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  clean build >"$BUILD_LOG" 2>&1; then
  die "Release build failed; see $BUILD_LOG"
fi

BUILT_APP="$PRODUCTS/$FULL_PRODUCT_NAME"
[[ -d "$BUILT_APP" ]] || die "built app not found: $BUILT_APP"
APP="$STAGE/$APP_NAME.app"
ditto "$BUILT_APP" "$APP"

echo "==> Signing app with hardened runtime and secure timestamp"
codesign --force \
  --sign "$DEVELOPER_ID_APPLICATION" \
  --options runtime \
  --timestamp \
  --entitlements "$ENTITLEMENTS" \
  "$APP"
verify_app "$APP"

NOTARY_ZIP="$TEMP_ROOT/Tungsten-Edge-$VERSION-notarization.zip"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
notarize_and_require_acceptance "$NOTARY_ZIP" "$TEMP_ROOT/app-notary.json" "app archive"

echo "==> Stapling and assessing app"
xcrun stapler staple -v "$APP"
verify_app "$APP"
verify_app_gatekeeper "$APP"

echo "==> Creating final Homebrew ZIP"
ZIP="$NEW_DIST/Tungsten-Edge-$VERSION.zip"
(cd "$STAGE" && ditto -c -k --keepParent "$APP_NAME.app" "$ZIP")
verify_zip "$ZIP"

echo "==> Creating and signing DMG"
ditto "$APP" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
DMG="$NEW_DIST/Tungsten-Edge-$VERSION.dmg"
hdiutil create -volname "$VOL_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

notarize_and_require_acceptance "$DMG" "$TEMP_ROOT/dmg-notary.json" "DMG"

echo "==> Stapling and assessing DMG"
xcrun stapler staple -v "$DMG"
verify_dmg "$DMG"

echo "==> Checksums"
(cd "$NEW_DIST" && shasum -a 256 ./*.dmg ./*.zip)

# Replace published artifacts only after every build, signing, notarization, and
# Gatekeeper check has passed.
rm -rf "$DIST"
mv "$NEW_DIST" "$DIST"

echo "==> Done. Artifacts in: $DIST"
ls -la "$DIST"
