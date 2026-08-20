#!/usr/bin/env bash
# Build, sign, notarize, and package Tungsten Edge for public distribution.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/macos-dock-cc-v2.xcodeproj"
SCHEME="macos-dock-cc-v2"
ENTITLEMENTS="$ROOT/Resources/TungstenEdge.entitlements"
LICENSE_FILE="$ROOT/LICENSE"

APP_NAME="Tungsten Edge"
VOL_NAME="Tungsten Edge 钨极"

DD="$ROOT/build/ReleaseDD"
DIST="$ROOT/dist"
PRODUCTS="$DD/Build/Products/Release"
BUILD_LOG="${TMPDIR:-/tmp}/tungsten-edge-package-build.log"

DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Suzhou Mubai Creativity Design Co., Ltd. (DRPT2MJQD5)}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-tungsten-edge-notary}"

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
  local submission="${receipt%.json}-submit.json"
  local id status

  echo "==> Notarizing $label"
  # Submit and wait are two steps on purpose. With a single `submit --wait` the
  # submission id only exists inside the JSON that has not been written yet, so
  # a run that looks hung cannot be inspected without `notarytool history`.
  # A team's first-ever submission really can take ~45 minutes (measured
  # 2026-08-19); later ones land in about a minute.
  if ! xcrun notarytool submit "$artifact" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --output-format json >"$submission"; then
    [[ ! -s "$submission" ]] || cat "$submission" >&2
    die "$label notarization request failed"
  fi

  id="$(plutil -extract id raw -o - "$submission" 2>/dev/null || true)"
  if [[ -z "$id" ]]; then
    cat "$submission" >&2
    die "$label notarization returned no submission id"
  fi
  echo "    submission id: $id"
  echo "    waiting for Apple; from another shell you can follow it with:"
  echo "      xcrun notarytool wait $id --keychain-profile $NOTARY_KEYCHAIN_PROFILE"

  if ! xcrun notarytool wait "$id" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --output-format json >"$receipt"; then
    [[ ! -s "$receipt" ]] || cat "$receipt" >&2
    die "$label notarization wait failed (submission $id)"
  fi

  status="$(plutil -extract status raw -o - "$receipt" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    cat "$receipt" >&2
    # Apple's reason for a rejection lives only in the log, not in the receipt.
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" >&2 2>&1 || true
    die "$label notarization status was ${status:-unknown}, expected Accepted (submission $id)"
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

# Read the Sparkle keys back OUT of the signed app, the same way the entitlements check
# does. A missing feed URL or public key does not fail the build, it ships an app that
# silently never updates - and every user who installs it is stuck until they notice.
verify_sparkle_configuration() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  local feed key

  feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist" 2>/dev/null || true)"
  key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" 2>/dev/null || true)"
  [[ "$feed" == https://* ]] || die "signed app has no https SUFeedURL (got: ${feed:-<missing>})"
  [[ -n "$key" ]] || die "signed app has no SUPublicEDKey"

  # The updater must be signed by us too, or Sparkle refuses to launch it.
  local updater="$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
  [[ -d "$updater" ]] || die "signed app is missing Sparkle's Updater.app"
  verify_developer_id_signature "$updater" "Sparkle Updater.app" yes

  printf '    Sparkle: feed=%s, public key present\n' "$feed"
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
  cmp -s "$LICENSE_FILE" "$app/Contents/Resources/LICENSE" || die "app bundle is missing the exact GPL license text"

  printf '    signed app: archs=%s, GPL license present\n' "$archs"
}

verify_app_gatekeeper() {
  local app="$1"
  xcrun stapler validate -v "$app"
  spctl --assess --type execute --verbose=4 "$app"
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

verify_dmg() {
  local dmg="$1"
  codesign --verify --strict --verbose=2 "$dmg"
  verify_developer_id_signature "$dmg" "signed DMG" no
  xcrun stapler validate -v "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"
}

# Credential checks intentionally happen before clean/build or replacing dist/.
for command_name in awk cmp codesign ditto grep hdiutil lipo plutil security sed shasum spctl xcodebuild xcrun; do
  require_command "$command_name"
done
[[ -f "$PROJECT/project.pbxproj" ]] || die "Xcode project not found: $PROJECT"
[[ -f "$ENTITLEMENTS" ]] || die "entitlements file not found: $ENTITLEMENTS"
[[ -f "$LICENSE_FILE" ]] || die "GPL license file not found: $LICENSE_FILE"
plutil -lint "$ENTITLEMENTS" >/dev/null || die "invalid entitlements plist: $ENTITLEMENTS"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "$ENTITLEMENTS" 2>/dev/null || true)" != "true" ]]; then
  die "entitlements must enable com.apple.security.automation.apple-events"
fi

[[ "$DEVELOPER_ID_APPLICATION" == 'Developer ID Application: '* ]] || die "DEVELOPER_ID_APPLICATION must name a Developer ID Application certificate"
EXPECTED_TEAM_ID="${DEVELOPER_ID_APPLICATION##*(}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID%)}"
[[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "could not parse a 10-character Team ID from DEVELOPER_ID_APPLICATION"
IDENTITIES="$(security find-identity -v -p codesigning 2>&1)"
grep -Fq "\"$DEVELOPER_ID_APPLICATION\"" <<<"$IDENTITIES" || die "Developer ID Application identity is not installed or not valid: $DEVELOPER_ID_APPLICATION"

[[ -n "$NOTARY_KEYCHAIN_PROFILE" ]] || die "NOTARY_KEYCHAIN_PROFILE is required"
if ! NOTARY_PREFLIGHT="$(xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --output-format json 2>&1)"; then
  die "notarytool profile '$NOTARY_KEYCHAIN_PROFILE' is missing, invalid, or unavailable"
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

# GPL-3.0 requires the license text to accompany the binary. It must be added
# before signing because modifying a signed bundle invalidates its signature.
cp "$LICENSE_FILE" "$APP/Contents/Resources/LICENSE"

# Sparkle ships nested code inside its framework. A single codesign of the outer app
# does NOT reach it, and notarization rejects unsigned nested Mach-O outright, so the
# framework has to be signed from the inside out before the app itself.
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
  # The two XPC services only exist for sandboxed hosts (SUEnableDownloaderService /
  # SUEnableInstallerLauncherService). This app is not sandboxed, so they are dead weight
  # and two more things to sign and notarize. Removing them must happen BEFORE the
  # framework is signed, or the seal no longer matches its own contents.
  rm -rf "$SPARKLE_FRAMEWORK/Versions/B/XPCServices"

  echo "==> Signing Sparkle's nested code (inside out)"
  # Order matters: every nested bundle first, the framework last. Do not use --deep;
  # it is deprecated and applies the wrong entitlements to nested code.
  for nested in \
    "$SPARKLE_FRAMEWORK/Versions/B/Updater.app" \
    "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"; do
    [[ -e "$nested" ]] || die "Sparkle is missing expected nested code: $nested"
    codesign --force \
      --sign "$DEVELOPER_ID_APPLICATION" \
      --options runtime \
      --timestamp \
      "$nested"
  done
  codesign --force \
    --sign "$DEVELOPER_ID_APPLICATION" \
    --options runtime \
    --timestamp \
    "$SPARKLE_FRAMEWORK"
else
  die "Sparkle.framework is not embedded in the built app"
fi

echo "==> Signing app with hardened runtime and secure timestamp"
codesign --force \
  --sign "$DEVELOPER_ID_APPLICATION" \
  --options runtime \
  --timestamp \
  --entitlements "$ENTITLEMENTS" \
  "$APP"
verify_app "$APP"
verify_sparkle_configuration "$APP"

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
cp "$LICENSE_FILE" "$DMG_STAGE/LICENSE"
ln -s /Applications "$DMG_STAGE/Applications"
cmp -s "$LICENSE_FILE" "$DMG_STAGE/LICENSE" || die "DMG stage is missing the exact GPL license text"
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

# The appcast entry needs an EdDSA signature over the exact zip we just produced.
# The private key lives only in the login keychain of whoever runs this script; if it is
# gone, every already-installed copy loses auto-update permanently (a new key means a new
# SUPublicEDKey, which only reaches users through a manual reinstall). See Docs/29.
echo "==> Sparkle update signature (paste into appcast.xml)"
SIGN_UPDATE="$(find "$DD/SourcePackages/artifacts" -name sign_update -type f 2>/dev/null | head -n 1)"
[[ -x "$SIGN_UPDATE" ]] || die "sign_update not found under $DD/SourcePackages/artifacts (was the Sparkle package resolved?)"
"$SIGN_UPDATE" "$ZIP" || die "sign_update failed - is the Sparkle EdDSA private key in this keychain?"

# Replace published artifacts only after every verification has passed.
rm -rf "$DIST"
mv "$NEW_DIST" "$DIST"

echo "==> Done. Artifacts in: $DIST"
ls -la "$DIST"
