#!/usr/bin/env bash
# Fetch the untouched vendor APKs from the public download sites.
#
# The reliable source is the private vendor release in this repository:
#   gh release download vendor/<app>/<version> -p '*.apk' -D vendor/<app>/
# Use this script only when that release does not exist yet. The workflow tries
# the release first and falls back to this script.
#
# Sources:
#   ather     APKPure. The Ather APKs are not on APKMirror. APKPure publishes
#             13.5.0 as an XAPK (a zip with the base APK and the config splits).
#   nothingx  APKMirror. Nothing X 3.8.0 is an APK bundle (.apkm) with a base
#             APK and 33 config splits.
#
# Both sites sit behind Cloudflare and answer plain curl with a challenge page.
# The FiorenMas project (https://github.com/FiorenMas) drives the same sites
# with FlareSolverr and a Cloudflare-bypass container. This script stays
# dependency-light: it needs curl and unzip only, never solves a challenge, and
# gives up with a clear message when a page cannot be fetched. A download that
# gets through is not trusted on its own - scripts/verify-vendor-apks.sh checks
# the SHA-256 entries in vendor/SHA256SUMS and the certificate pins in
# vendor-certs.json, and a tampered file fails there.
#
# Usage:
#   scripts/fetch-vendor-apks.sh ather [version]
#   scripts/fetch-vendor-apks.sh nothingx [version]
#   scripts/fetch-vendor-apks.sh all
#
# The versions default to the ones the current patch bundle targets, as reported
# by: list-patches --patches=<mpp> --with-versions -p
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ATHER_VERSION="${ATHER_VERSION:-13.5.0}"
NOTHINGX_VERSION="${NOTHINGX_VERSION:-3.8.0}"
ATHER_PACKAGE="com.athermobileapp"
NOTHINGX_PACKAGE="com.nothing.smartcenter"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36" # keywatch:ignore
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "fetch-vendor-apks: $1" >&2
  exit 1
}

# Fetch one page with curl and reject Cloudflare challenge responses.
fetch_page() {
  local url="$1" html
  if ! html="$(curl -fsSL --retry 2 --connect-timeout 20 -A "$UA" "$url" 2>&1)"; then
    fail "cannot fetch $url
The site did not answer. Both sites sit behind Cloudflare; open the page in a
browser, download the APKs, and upload them to a vendor/<app>/<version>
release in this repository (see README.md)."
  fi
  if grep -qiE 'cf-chl|__cf_chl|Just a moment|Enable JavaScript and cookies|Attention Required' <<<"$html"; then
    fail "Cloudflare challenged $url
This script does not solve challenges. Use a browser or FlareSolverr, then
upload the APKs to a vendor/<app>/<version> release (see README.md)."
  fi
  printf '%s' "$html"
}

# Download one archive and reject anything that is not a zip container.
download_zip() {
  local url="$1" out="$2"
  curl -fL --retry 3 --connect-timeout 20 -A "$UA" -o "$out.part" "$url" ||
    fail "cannot download $url"
  if [ "$(head -c 2 "$out.part")" != "PK" ]; then
    rm -f "$out.part"
    fail "the download from $url is not an APK/XAPK/APKM zip. The site may have
served an HTML page instead. Download the file in a browser and upload it to a
vendor/<app>/<version> release (see README.md)."
  fi
  mv "$out.part" "$out"
}

# Extract every *.apk from an XAPK/APKM archive, renaming a bare base.apk to
# the package name the workflow expects.
extract_apks() {
  local archive="$1" dir="$2" package="$3" tmp count
  tmp="$WORK/unpack"
  rm -rf "$tmp"
  unzip -q -o "$archive" -d "$tmp" || fail "cannot extract $archive"
  mkdir -p "$dir"
  find "$tmp" -name '*.apk' -exec cp {} "$dir/" \;
  if [ -f "$dir/base.apk" ] && [ ! -f "$dir/$package.apk" ]; then
    mv "$dir/base.apk" "$dir/$package.apk"
  fi
  count="$(find "$dir" -maxdepth 1 -name '*.apk' | wc -l | tr -d ' ')"
  [ "$count" -gt 0 ] || fail "$archive contains no APK files."
  echo "extracted $count APK(s) into ${dir#"$ROOT"/}"
}

fetch_ather() {
  local version="$1" dir="$ROOT/vendor/ather" archive="$WORK/ather.xapk"
  local page="https://apkpure.com/ather/$ATHER_PACKAGE/download/$version" html link
  echo "fetching Ather $version from APKPure"
  html="$(fetch_page "$page")"
  link="$(grep -oE 'https?://[^"]+\.(xapk|apk)(\?[^"]*)?' <<<"$html" | grep -v 'apkpure\.com/ather' | head -n 1 || true)"
  [ -n "$link" ] ||
    fail "no XAPK or APK download link found on $page.
Download the page in a browser and upload the APKs to a vendor/ather/$version
release (see README.md)."
  download_zip "$link" "$archive"
  extract_apks "$archive" "$dir" "$ATHER_PACKAGE"
}

fetch_nothingx() {
  local version="$1" dir="$ROOT/vendor/nothingx" archive="$WORK/nothingx.apkm"
  local dashed="${version//./-}"
  local base="https://www.apkmirror.com/apk/nothing-technology-limited/ear-1"
  local page="$base/nothing-x-$dashed-release/nothing-x-$dashed-android-apk-download" html link
  echo "fetching Nothing X $version from APKMirror"
  html="$(fetch_page "$page")"
  link="$(grep -oE "$base/[^\"]+/download/\?key=[^\"]+" <<<"$html" | head -n 1 || true)"
  [ -n "$link" ] ||
    fail "no APK bundle link found on $page.
Download the page in a browser and upload the APKs to a vendor/nothingx/$version
release (see README.md)."
  html="$(fetch_page "https://www.apkmirror.com$link")"
  link="$(grep -oE 'https?://[^"]+\.apkm[^"]*' <<<"$html" | head -n 1 || true)"
  if [ -z "$link" ]; then
    link="$(grep -oE 'https?://[^"]+download\.php[^"]*' <<<"$html" | head -n 1 || true)"
  fi
  [ -n "$link" ] ||
    fail "no .apkm download link found on the APKMirror bundle page.
Download the page in a browser and upload the APKs to a vendor/nothingx/$version
release (see README.md)."
  download_zip "$link" "$archive"
  extract_apks "$archive" "$dir" "$NOTHINGX_PACKAGE"
}

case "${1:-}" in
  ather)
    fetch_ather "${2:-$ATHER_VERSION}"
    ;;
  nothingx)
    fetch_nothingx "${2:-$NOTHINGX_VERSION}"
    ;;
  all)
    [ $# -le 1 ] || fail "'all' takes no version argument - set ATHER_VERSION and NOTHINGX_VERSION instead."
    fetch_ather "$ATHER_VERSION"
    fetch_nothingx "$NOTHINGX_VERSION"
    ;;
  *)
    fail "usage: $0 ather|nothingx|all [version]"
    ;;
esac

echo
echo "Now verify before building:"
echo "  APP=<app> APP_PACKAGE=<package> bash scripts/verify-vendor-apks.sh"
