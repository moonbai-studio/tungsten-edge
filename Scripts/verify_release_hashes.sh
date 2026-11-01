#!/usr/bin/env bash
# Verify that what users actually download is byte-identical to the ZIP/DMG in dist/.
# Run this AFTER the website deploy: Sparkle updates and the official Homebrew cask both download the
# website ZIP, the website button downloads the DMG, and mainland-China requests are 302ed to the
# mirror on tungstenedge.cn (Docs/29 §三点五, §五). A mismatch is only discovered when a user files an issue.
# The cask sha256 is no longer ours to check - Homebrew's autobump computes it from the same ZIP.
#
# Five checks, any failure is FAIL:
#   1. website ZIP  (followed redirects; the final host must be the website, not the mirror)
#   2. website DMG  via /download/latest (same host rule)
#   3. mirror ZIP   fetched directly (--noproxy) from the mirror
#   4. mirror DMG   same
#   5. the website 302s mainland requests for ZIP and DMG to the mirror
# Checks 1-2 need an overseas exit (this machine's Bash goes through the proxy by default); check 5 needs a
# direct mainland connection. Both hold on the owner's Mac with Clash in system-proxy mode; see Docs/29 §五.
#
# usage: Scripts/verify_release_hashes.sh <version>            e.g. 0.16.1
#   DOWNLOAD_BASE overrides the website download base (default https://tungstenedge.app/download)
#   MIRROR_BASE   overrides the mirror download base  (default https://tungstenedge.cn/download)
set -euo pipefail

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "usage: $0 <version>" >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must look like X.Y.Z, got '$VERSION'" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://tungstenedge.app/download}"
MIRROR_BASE="${MIRROR_BASE:-https://tungstenedge.cn/download}"
ZIP_NAME="Tungsten-Edge-$VERSION.zip"
DMG_NAME="Tungsten-Edge-$VERSION.dmg"

fail=0
note() { printf '%s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*" >&2; fail=1; }
sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
host_of() { printf '%s' "$1" | sed -E 's#^[a-z]+://([^/]+).*#\1#'; }

WEBSITE_HOST="$(host_of "$DOWNLOAD_BASE")"
TMP_DIR="$(mktemp -d -t tungsten-verify.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 0. local artifacts
LOCAL_ZIP_SHA=""; LOCAL_DMG_SHA=""
for kind in zip dmg; do
  local_file="$ROOT/dist/Tungsten-Edge-$VERSION.$kind"
  if [[ -f "$local_file" ]]; then
    sha="$(sha_of "$local_file")"
    note "local   $sha  $local_file"
    [[ "$kind" == zip ]] && LOCAL_ZIP_SHA="$sha" || LOCAL_DMG_SHA="$sha"
  else
    bad "local $kind not found: $local_file (run Scripts/package_release.sh first)"
  fi
done

# fetch <label> <url> <expected-sha> <expected-final-host|""> [curl args...]
fetch_and_compare() {
  local label="$1" url="$2" expected="$3" expected_host="$4"; shift 4
  local out="$TMP_DIR/$label" effective
  if ! effective="$(curl -fsSL --retry 2 "$@" -o "$out" -w '%{url_effective}' "$url")"; then
    bad "$label: could not download $url (not deployed yet?)"; return
  fi
  if [[ -n "$expected_host" && "$(host_of "$effective")" != "$expected_host" ]]; then
    bad "$label: $url ended up at $effective - the website redirected this fetch to the mirror. Checks 1-2 must run with an overseas exit (proxy on); re-run with the proxy."
    return
  fi
  local sha; sha="$(sha_of "$out")"
  note "$label $sha  $effective"
  if [[ -n "$expected" && "$sha" != "$expected" ]]; then
    bad "$label: hash differs from dist/ - the deploy did not publish this build"
  fi
}

# 1-2. what the website serves overseas (final host must stay on the website)
fetch_and_compare "website-zip" "$DOWNLOAD_BASE/$ZIP_NAME" "$LOCAL_ZIP_SHA" "$WEBSITE_HOST"
fetch_and_compare "website-dmg" "$DOWNLOAD_BASE/latest"     "$LOCAL_DMG_SHA" "$WEBSITE_HOST"

# 3-4. what the mirror serves (direct connection, so the fetch cannot be re-routed)
fetch_and_compare "mirror-zip " "$MIRROR_BASE/$ZIP_NAME" "$LOCAL_ZIP_SHA" "" --noproxy '*'
fetch_and_compare "mirror-dmg " "$MIRROR_BASE/$DMG_NAME" "$LOCAL_DMG_SHA" "" --noproxy '*'

# 5. mainland requests are redirected to the mirror
for name in "$ZIP_NAME" "$DMG_NAME"; do
  got="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code} %{redirect_url}' "$DOWNLOAD_BASE/$name" || true)"
  want="302 $MIRROR_BASE/$name"
  if [[ "$got" == "$want" ]]; then
    note "redirect $got"
  else
    bad "redirect for $name: got '$got', want '$want'. This check needs a direct mainland-China connection (--noproxy); with TUN / a transparent proxy or from overseas it cannot pass."
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo "verify_release_hashes: FAIL" >&2
  exit 1
fi
echo "verify_release_hashes: PASS ($VERSION)"
