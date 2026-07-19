#!/usr/bin/env bash
# Build a clearly labeled, self-signed preview for GitHub Pre-release testing.
# Formal public releases must continue to use package_release.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/macos-dock-cc-v2.xcodeproj"
SCHEME="macos-dock-cc-v2"
ENTITLEMENTS="$ROOT/Resources/TungstenEdge.entitlements"

APP_NAME="Tungsten Edge"
VOL_NAME="Tungsten Edge beta"
PREVIEW_TAG="${PREVIEW_TAG:-v0.6.6-beta.1}"
EXPECTED_BASE_VERSION="${EXPECTED_BASE_VERSION:-0.6.6}"
EXPECTED_BUILD="${EXPECTED_BUILD:-7}"
PREVIEW_SIGNING_IDENTITY="${PREVIEW_SIGNING_IDENTITY:-macos-dock-cc Local Code Signing}"
# Load-bearing TCC identity pin. Changing this creates a new Accessibility identity.
PREVIEW_CERTIFICATE_SHA1="520de050f4ea495c166ec7b3447b327bf88a55df"

DD="$ROOT/build/PreviewDD"
DIST="$ROOT/dist"
PRODUCTS="$DD/Build/Products/Release"
BUILD_LOG="${TMPDIR:-/tmp}/tungsten-edge-preview-build.log"

TEMP_ROOT=""
MOUNT_POINT=""
MOUNT_DEVICE=""
ATTACH_PLIST=""
IS_MOUNTED=false

cleanup() {
  local can_remove=true
  if [[ "$IS_MOUNTED" != true
        && -n "$ATTACH_PLIST"
        && -s "$ATTACH_PLIST"
        && -n "$MOUNT_POINT"
        && -d "$MOUNT_POINT/$APP_NAME.app" ]]; then
    IS_MOUNTED=true
  fi
  if [[ "$IS_MOUNTED" == true ]]; then
    local detach_target="${MOUNT_DEVICE:-$MOUNT_POINT}"
    if hdiutil detach "$detach_target" -quiet >/dev/null 2>&1; then
      IS_MOUNTED=false
    else
      can_remove=false
      printf 'warning: could not detach preview DMG at %s; preserving %s\n' "$detach_target" "$TEMP_ROOT" >&2
    fi
  fi
  if [[ "$can_remove" == true && -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
  if [[ "$can_remove" == true && -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    rmdir "$MOUNT_POINT" 2>/dev/null || true
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

verify_preview_signature() {
  local artifact="$1"
  local label="$2"
  local require_runtime="$3"
  local expected_identifier="$4"
  local details authority team_id flags identifier requirement

  if [[ "$artifact" == *.app ]]; then
    codesign --verify --deep --strict --verbose=2 "$artifact"
  else
    codesign --verify --strict --verbose=2 "$artifact"
  fi

  details="$(codesign -dvvv "$artifact" 2>&1)"
  authority="$(awk -F= '/^Authority=/{sub(/^Authority=/, ""); print; exit}' <<<"$details")"
  team_id="$(sed -n 's/^TeamIdentifier=//p' <<<"$details")"
  flags="$(sed -n 's/^CodeDirectory .* flags=\([^ ]*\).*/\1/p' <<<"$details")"
  identifier="$(sed -n 's/^Identifier=//p' <<<"$details")"

  [[ "$authority" == "$PREVIEW_SIGNING_IDENTITY" ]] || die "$label authority is '$authority', expected '$PREVIEW_SIGNING_IDENTITY'"
  [[ "$team_id" == "not set" ]] || die "$label unexpectedly has TeamIdentifier '${team_id:-missing}'"
  if [[ "$require_runtime" == yes && "$flags" != *runtime* ]]; then
    die "$label is missing the hardened runtime flag"
  fi
  if [[ -n "$expected_identifier" && "$identifier" != "$expected_identifier" ]]; then
    die "$label identifier is '$identifier', expected '$expected_identifier'"
  fi

  requirement="$(codesign -d -r- "$artifact" 2>&1)"
  grep -Fq 'designated =>' <<<"$requirement" || die "$label has no designated requirement"
  if grep -Eiq 'cdhash' <<<"$requirement"; then
    die "$label designated requirement is CDHash-bound"
  fi
  grep -Fq "certificate root = H\"$PREVIEW_CERTIFICATE_SHA1\"" <<<"$requirement" \
    || die "$label designated requirement is not bound to the pinned preview certificate"

  printf '    %s: identifier=%s, flags=%s, stable self-signed requirement\n' "$label" "$identifier" "$flags"
}

verify_app() {
  local app="$1"
  local version build archs
  local signed_entitlements="$TEMP_ROOT/signed-entitlements.plist"

  verify_preview_signature "$app" "preview app" yes "com.caye.macosdockcc.v2"
  codesign -d --entitlements - --xml "$app" >"$signed_entitlements" 2>/dev/null \
    || die "could not read entitlements from preview app"
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "$signed_entitlements" 2>/dev/null || true)" != true ]]; then
    die "preview app is missing the Apple Events automation entitlement"
  fi

  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true)"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$version" == "$PREVIEW_VERSION" ]] || die "preview app version is '$version', expected '$PREVIEW_VERSION'"
  [[ "$build" == "$EXPECTED_BUILD" ]] || die "preview app build is '$build', expected '$EXPECTED_BUILD'"

  archs="$(lipo -archs "$app/Contents/MacOS/$EXECUTABLE_NAME")"
  [[ " $archs " == *' arm64 '* ]] || die "preview app executable is missing arm64"
  [[ " $archs " == *' x86_64 '* ]] || die "preview app executable is missing x86_64"
  printf '    preview app: version=%s (%s), archs=%s\n' "$version" "$build" "$archs"
}

for command_name in awk codesign ditto grep hdiutil lipo plutil security sed shasum xcodebuild; do
  require_command "$command_name"
done
[[ -f "$PROJECT/project.pbxproj" ]] || die "Xcode project not found: $PROJECT"
[[ -f "$ENTITLEMENTS" ]] || die "entitlements file not found: $ENTITLEMENTS"
plutil -lint "$ENTITLEMENTS" >/dev/null || die "invalid entitlements plist: $ENTITLEMENTS"

IDENTITIES="$(security find-identity -v -p codesigning 2>&1)"
grep -Fq "\"$PREVIEW_SIGNING_IDENTITY\"" <<<"$IDENTITIES" \
  || die "stable preview signing identity is not installed or not valid: $PREVIEW_SIGNING_IDENTITY"

BUILD_SETTINGS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null)" \
  || die "could not resolve Release build settings"
VERSION="$(build_setting MARKETING_VERSION)"
BUILD_NUMBER="$(build_setting CURRENT_PROJECT_VERSION)"
FULL_PRODUCT_NAME="$(build_setting FULL_PRODUCT_NAME)"
EXECUTABLE_NAME="$(build_setting EXECUTABLE_NAME)"
[[ "$VERSION" == "$EXPECTED_BASE_VERSION" ]] || die "Release MARKETING_VERSION is '$VERSION', expected '$EXPECTED_BASE_VERSION'"
[[ "$BUILD_NUMBER" == "$EXPECTED_BUILD" ]] || die "Release CURRENT_PROJECT_VERSION is '$BUILD_NUMBER', expected '$EXPECTED_BUILD'"
[[ -n "$FULL_PRODUCT_NAME" && -n "$EXECUTABLE_NAME" ]] || die "Release product settings are unresolved"

TAG_PREFIX="v${VERSION}-beta."
[[ "$PREVIEW_TAG" == "$TAG_PREFIX"* ]] || die "PREVIEW_TAG must match ${TAG_PREFIX}<positive integer>"
BETA_NUMBER="${PREVIEW_TAG#$TAG_PREFIX}"
[[ "$BETA_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "PREVIEW_TAG must end in a positive beta number"
ARTIFACT_VERSION="${PREVIEW_TAG#v}"
PREVIEW_VERSION="$ARTIFACT_VERSION"
PREVIEW_DIST="$DIST/preview"
FINAL_ZIP="$PREVIEW_DIST/Tungsten-Edge-$ARTIFACT_VERSION.zip"
FINAL_DMG="$PREVIEW_DIST/Tungsten-Edge-$ARTIFACT_VERSION.dmg"
[[ ! -e "$FINAL_ZIP" && ! -e "$FINAL_DMG" ]] \
  || die "preview artifacts already exist; refusing to overwrite $PREVIEW_DIST"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tungsten-edge-preview.XXXXXX")"
STAGE="$TEMP_ROOT/stage"
DMG_STAGE="$TEMP_ROOT/dmg-stage"
NEW_DIST="$TEMP_ROOT/dist"
ZIP_EXTRACT="$TEMP_ROOT/zip-extract"
MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/tungsten-edge-preview-mount.XXXXXX")"
ATTACH_PLIST="$TEMP_ROOT/dmg-attach.plist"
mkdir -p "$STAGE" "$DMG_STAGE" "$NEW_DIST" "$ZIP_EXTRACT"

echo "==> Building unsigned universal preview $PREVIEW_TAG"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DD" \
  ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$PREVIEW_VERSION" CURRENT_PROJECT_VERSION="$EXPECTED_BUILD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  clean build >"$BUILD_LOG" 2>&1; then
  die "preview build failed; see $BUILD_LOG"
fi

BUILT_APP="$PRODUCTS/$FULL_PRODUCT_NAME"
[[ -d "$BUILT_APP" ]] || die "built app not found: $BUILT_APP"
APP="$STAGE/$APP_NAME.app"
ditto "$BUILT_APP" "$APP"

echo "==> Signing preview app with stable local certificate"
codesign --force \
  --sign "$PREVIEW_SIGNING_IDENTITY" \
  --options runtime \
  --timestamp=none \
  --entitlements "$ENTITLEMENTS" \
  "$APP"
verify_app "$APP"

ZIP="$NEW_DIST/Tungsten-Edge-$ARTIFACT_VERSION.zip"
echo "==> Creating and verifying ZIP"
(cd "$STAGE" && ditto -c -k --keepParent "$APP_NAME.app" "$ZIP")
ditto -x -k "$ZIP" "$ZIP_EXTRACT"
verify_app "$ZIP_EXTRACT/$APP_NAME.app"

echo "==> Creating, signing, and verifying DMG"
ditto "$APP" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
DMG="$NEW_DIST/Tungsten-Edge-$ARTIFACT_VERSION.dmg"
hdiutil create -volname "$VOL_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --sign "$PREVIEW_SIGNING_IDENTITY" --timestamp=none "$DMG"
verify_preview_signature "$DMG" "preview DMG" no ""
hdiutil verify "$DMG" >/dev/null

hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_POINT" -plist >"$ATTACH_PLIST"
IS_MOUNTED=true
MOUNT_DEVICE="$(plutil -extract 'system-entities.0.dev-entry' raw -o - "$ATTACH_PLIST" 2>/dev/null || true)"
[[ "$MOUNT_DEVICE" == /dev/disk* ]] || die "could not resolve attached preview DMG device"
verify_app "$MOUNT_POINT/$APP_NAME.app"
hdiutil detach "$MOUNT_DEVICE" -quiet
IS_MOUNTED=false
MOUNT_DEVICE=""

mkdir -p "$PREVIEW_DIST"
mv "$ZIP" "$FINAL_ZIP"
mv "$DMG" "$FINAL_DMG"

echo "==> Preview checksums"
(cd "$PREVIEW_DIST" && shasum -a 256 "$(basename "$FINAL_DMG")" "$(basename "$FINAL_ZIP")")
echo "==> Done. This preview is self-signed and intentionally not notarized."
