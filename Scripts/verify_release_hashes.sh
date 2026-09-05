#!/usr/bin/env bash
# Verify that the release ZIP the website serves, the ZIP in dist/, and the sha256 written
# into the Homebrew cask all agree. Run this AFTER the website deploy and BEFORE pushing the
# cask: a wrong cask sha256 breaks `brew install` for every user and is only discovered when
# one of them files an issue (Docs/29 §五).
#
# usage: Scripts/verify_release_hashes.sh <version>            e.g. 0.11.1
#   CASK_FILE overrides the cask path (default ~/Projects/homebrew-tungsten-edge/Casks/tungsten-edge.rb)
#   DOWNLOAD_BASE overrides the website download base (default https://tungstenedge.app/download)
set -euo pipefail

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "usage: $0 <version>" >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must look like X.Y.Z, got '$VERSION'" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_ZIP="$ROOT/dist/Tungsten-Edge-$VERSION.zip"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://tungstenedge.app/download}"
REMOTE_URL="$DOWNLOAD_BASE/Tungsten-Edge-$VERSION.zip"
CASK_FILE="${CASK_FILE:-$HOME/Projects/homebrew-tungsten-edge/Casks/tungsten-edge.rb}"

fail=0
note() { printf '%s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# 1. local artifact
if [[ -f "$LOCAL_ZIP" ]]; then
  LOCAL_SHA="$(sha_of "$LOCAL_ZIP")"
  note "local   $LOCAL_SHA  $LOCAL_ZIP"
else
  bad "local ZIP not found: $LOCAL_ZIP (run Scripts/package_release.sh first)"
  LOCAL_SHA=""
fi

# 2. what the website actually serves
TMP="$(mktemp -t tungsten-verify.XXXXXX)"
trap 'rm -f "$TMP"' EXIT
if curl -fsSL --retry 2 -o "$TMP" "$REMOTE_URL"; then
  REMOTE_SHA="$(sha_of "$TMP")"
  note "website $REMOTE_SHA  $REMOTE_URL"
else
  bad "could not download $REMOTE_URL (website not deployed yet? deploy first, cask last)"
  REMOTE_SHA=""
fi

# 3. what the cask promises
if [[ -f "$CASK_FILE" ]]; then
  CASK_VERSION="$(sed -nE 's/^[[:space:]]*version[[:space:]]+"([^"]+)".*/\1/p' "$CASK_FILE" | head -n 1)"
  CASK_SHA="$(sed -nE 's/^[[:space:]]*sha256[[:space:]]+"([0-9a-f]{64})".*/\1/p' "$CASK_FILE" | head -n 1)"
  note "cask    ${CASK_SHA:-<none>}  $CASK_FILE (version ${CASK_VERSION:-<none>})"
  [[ "$CASK_VERSION" == "$VERSION" ]] || bad "cask version is '$CASK_VERSION', expected '$VERSION'"
  [[ -n "$CASK_SHA" ]] || bad "cask has no sha256 line"
else
  note "cask    (skipped: $CASK_FILE not found; set CASK_FILE to check it)"
  CASK_SHA=""
fi

# cross-check every pair that exists
if [[ -n "$LOCAL_SHA" && -n "$REMOTE_SHA" && "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
  bad "website ZIP differs from dist/ ZIP - the deploy did not upload this build"
fi
if [[ -n "$CASK_SHA" && -n "$REMOTE_SHA" && "$CASK_SHA" != "$REMOTE_SHA" ]]; then
  bad "cask sha256 differs from the ZIP the website serves - brew install would fail for everyone"
fi
if [[ -n "$CASK_SHA" && -n "$LOCAL_SHA" && "$CASK_SHA" != "$LOCAL_SHA" ]]; then
  bad "cask sha256 differs from dist/ ZIP (did you paste the DMG hash? the cask URL points at the ZIP)"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "verify_release_hashes: FAIL" >&2
  exit 1
fi
echo "verify_release_hashes: PASS ($VERSION)"
