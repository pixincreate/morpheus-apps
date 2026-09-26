#!/usr/bin/env bash
# Fetch the untouched vendor APKs from the APKPure direct download endpoints.
#
# The reliable source is the private vendor release in this repository:
#   gh release download vendor/<app>/<version> -p '*.apk' -D vendor/<app>/
# Use this script only when that release does not exist yet. The workflow tries
# the release first and falls back to this script.
#
# The direct endpoints work in a browser, but APKPure serves them through
# Cloudflare. A plain curl gets HTTP 403 with "cf-mitigated: challenge" and an
# HTML body, even with browser-like headers. When that happens and
# FLARESOLVERR_URL is set, the script asks FlareSolverr for a cf_clearance
# cookie and retries the download with the cookie and the FlareSolverr user
# agent, because Cloudflare binds cf_clearance to both. FlareSolverr is
# optional; the private vendor release stays the primary path.
#
# Endpoints:
#   https://d.apkpure.com/b/XAPK/<package>?version=latest
#   https://d.apkpure.com/b/XAPK/<package>?versionCode=<code>&nc=<abi>&sv=<sdk>
#
# A download that gets through is not trusted on its own:
# scripts/verify-vendor-apks.sh checks the SHA-256 entries in vendor/SHA256SUMS
# and the certificate pins in vendor-certs.json, and a tampered file fails
# there.
#
# Usage:
#   scripts/fetch-vendor-apks.sh ather [version [versionCode [abi [sdk]]]]
#   scripts/fetch-vendor-apks.sh nothingx [version [versionCode [abi [sdk]]]]
#   scripts/fetch-vendor-apks.sh all
#
# Defaults:
#   app        package                    version  versionCode  abi          sdk
#   ather      com.athermobileapp          13.5.0   321          arm64-v8a    32
#   nothingx   com.nothing.smartcenter     3.8.0    3080004      arm64-v8a    32
#
# The versions default to the ones the current patch bundle targets, as reported
# by: list-patches --patches=<mpp> --with-versions -p
#
# Environment:
#   FLARESOLVERR_URL  optional base URL of a reachable FlareSolverr, for example
#                     http://localhost:8191. FlareSolverr and the download must
#                     leave from one public IP, or Cloudflare rejects the cookie.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36" # keywatch:ignore
REFERER="https://apkpure.com/"
FLARESOLVERR_URL="${FLARESOLVERR_URL:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "fetch-vendor-apks: $1" >&2
  exit 1
}

# Load the defaults for one app. Sets APP_NAME, APP_PACKAGE, APP_VERSION,
# APP_VERSION_CODE, APP_ABI and APP_SDK.
app_defaults() {
  APP_NAME="$1"
  case "$1" in
    ather)
      APP_PACKAGE="com.athermobileapp"
      APP_VERSION="13.5.0"
      APP_VERSION_CODE="321"
      APP_ABI="arm64-v8a"
      APP_SDK="32"
      ;;
    nothingx)
      APP_PACKAGE="com.nothing.smartcenter"
      APP_VERSION="3.8.0"
      APP_VERSION_CODE="3080004"
      APP_ABI="arm64-v8a"
      APP_SDK="32"
      ;;
    *)
      fail "unknown app '$1' - expected ather, nothingx or all."
      ;;
  esac
}

endpoint_url() {
  local package="$1" version_code="$2" abi="$3" sdk="$4"
  if [ -n "$version_code" ]; then
    printf 'https://d.apkpure.com/b/XAPK/%s?versionCode=%s&nc=%s&sv=%s' \
      "$package" "$version_code" "$abi" "$sdk"
  else
    printf 'https://d.apkpure.com/b/XAPK/%s?version=latest' "$package"
  fi
}

# GET one URL with browser-like headers and print the HTTP status code. The body
# lands in $2. A cookie jar and a user agent override the defaults.
http_get() {
  local url="$1" body="$2" jar="${3:-}" agent="${4:-$UA}" code
  local -a args=(
    "-sS" "-L" "--connect-timeout" "20" "--retry" "2" "--retry-delay" "1"
    "-A" "$agent" "-e" "$REFERER"
    "-H" "Accept: */*" "-H" "Accept-Language: en-US,en;q=0.9"
    "-o" "$body" "-w" "%{http_code}"
  )
  if [ -n "$jar" ]; then
    args+=("-b" "$jar")
  fi
  if ! code="$(curl "${args[@]}" "$url")"; then
    fail "cannot reach $url."
  fi
  printf '%s' "$code"
}

# Write a Netscape cookie jar so curl sends cf_clearance to d.apkpure.com and to
# every apkpure.com host it redirects to.
write_cookie_jar() {
  local jar="$1" cookie="$2"
  {
    printf '# Netscape HTTP Cookie File\n'
    printf '.apkpure.com\tTRUE\t/\tTRUE\t0\tcf_clearance\t%s\n' "$cookie"
  } >"$jar"
}

# Solve the Cloudflare challenge at $1 through FlareSolverr and print
# "<cf_clearance value>\t<user agent>". returnOnlyCookies drops the response
# body, which would be the whole XAPK.
flare_solve() {
  local url="$1" request="$WORK/flaresolverr-request.json" response="$WORK/flaresolverr-response.json" cookie_line
  command -v python3 >/dev/null 2>&1 ||
    fail "python3 is required to read the FlareSolverr response."
  python3 - "$url" >"$request" <<'PY'
import json
import sys

print(json.dumps({
    "cmd": "request.get",
    "url": sys.argv[1],
    "maxTimeout": 60000,
    "returnOnlyCookies": True,
}))
PY
  if ! curl -fsS --connect-timeout 20 --max-time 120 \
    -H 'Content-Type: application/json' --data-binary "@$request" \
    -o "$response" "$FLARESOLVERR_URL/v1"; then
    fail "cannot reach FlareSolverr at $FLARESOLVERR_URL/v1.
Start FlareSolverr (see README.md) or unset FLARESOLVERR_URL."
  fi
  if ! cookie_line="$(python3 - "$response" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
if data.get("status") != "ok":
    sys.stderr.write("FlareSolverr reported an error: %s\n" % data.get("message", "unknown"))
    sys.exit(1)
solution = data.get("solution") or {}
for cookie in solution.get("cookies") or []:
    if cookie.get("name") == "cf_clearance":
        sys.stdout.write("%s\t%s" % (cookie.get("value", ""), solution.get("userAgent") or ""))
        sys.exit(0)
sys.stderr.write("FlareSolverr returned no cf_clearance cookie.\n")
sys.exit(1)
PY
)"; then
    fail "FlareSolverr did not return a usable cf_clearance cookie for $url."
  fi
  printf '%s' "$cookie_line"
}

give_up() {
  local url="$1" code="$2" first="$3"
  fail "cannot download $url
HTTP $code, and the body does not start with the zip magic PK (it starts with '${first:-nothing}').
Two ways forward:
  1. Open $url in a browser, download the XAPK, unzip it, and upload the APKs
     to the private vendor/$APP_NAME/$APP_VERSION release in this repository
     (see README.md). The workflow reads that release first.
  2. Provide FlareSolverr and set FLARESOLVERR_URL, for example
     http://localhost:8191. This script then solves the Cloudflare challenge
     and retries the download with the cf_clearance cookie."
}

# Download one XAPK. Browser headers first; when Cloudflare challenges the
# request and FLARESOLVERR_URL is set, solve the challenge and retry with the
# cookie and the matching user agent.
download_xapk() {
  local url="$1" out="$2" code first cookie_line flare_cookie flare_ua jar
  echo "downloading $url"
  code="$(http_get "$url" "$out.part")"
  first="$(head -c 2 "$out.part" 2>/dev/null || true)"
  if [ "$code" != "200" ] || [ "$first" != "PK" ]; then
    if [ -n "$FLARESOLVERR_URL" ]; then
      echo "APKPure answered with HTTP $code and no zip body; solving the challenge through FlareSolverr"
      # flare_solve prints its own failure reason; exit here so its message is
      # not followed by a misleading second one.
      if ! cookie_line="$(flare_solve "$url")"; then
        exit 1
      fi
      IFS=$'\t' read -r flare_cookie flare_ua <<<"$cookie_line"
      if [ -z "$flare_ua" ]; then
        fail "FlareSolverr returned no user agent. Cloudflare binds cf_clearance to the user agent, so the download would be challenged again."
      fi
      jar="$WORK/flaresolverr.cookies"
      write_cookie_jar "$jar" "$flare_cookie"
      code="$(http_get "$url" "$out.part" "$jar" "$flare_ua")"
      first="$(head -c 2 "$out.part" 2>/dev/null || true)"
    fi
  fi
  if [ "$code" != "200" ] || [ "$first" != "PK" ]; then
    rm -f "$out.part"
    give_up "$url" "$code" "$first"
  fi
  mv "$out.part" "$out"
  echo "downloaded $(wc -c <"$out" | tr -d ' ') bytes"
}

# Extract every *.apk from an XAPK archive, renaming a bare base.apk to the
# package name the workflow expects. Config splits keep their archive names.
extract_apks() {
  local archive="$1" dir="$2" package="$3" tmp count
  [ "$(head -c 2 "$archive" 2>/dev/null || true)" = "PK" ] ||
    fail "$archive is not a zip container, so it is not an XAPK."
  tmp="$WORK/unpack"
  rm -rf "$tmp"
  unzip -q -o "$archive" -d "$tmp" || fail "cannot extract $archive."
  mkdir -p "$dir"
  find "$tmp" -name '*.apk' -exec cp {} "$dir/" \;
  if [ -f "$dir/base.apk" ] && [ ! -f "$dir/$package.apk" ]; then
    mv "$dir/base.apk" "$dir/$package.apk"
  fi
  count="$(find "$dir" -maxdepth 1 -name '*.apk' | wc -l | tr -d ' ')"
  [ "$count" -gt 0 ] || fail "$archive contains no APK files."
  echo "extracted $count APK(s) into ${dir#"$ROOT"/}"
}

fetch_app() {
  APP_VERSION="$1"
  APP_VERSION_CODE="$2"
  APP_ABI="$3"
  APP_SDK="$4"
  local url dir archive
  url="$(endpoint_url "$APP_PACKAGE" "$APP_VERSION_CODE" "$APP_ABI" "$APP_SDK")"
  dir="$ROOT/vendor/$APP_NAME"
  archive="$WORK/$APP_NAME.xapk"
  echo "fetching $APP_NAME $APP_VERSION (versionCode $APP_VERSION_CODE, $APP_ABI, sdk $APP_SDK)"
  download_xapk "$url" "$archive"
  extract_apks "$archive" "$dir" "$APP_PACKAGE"
}

case "${1:-}" in
  ather | nothingx)
    app_defaults "$1"
    fetch_app "${2:-$APP_VERSION}" "${3:-$APP_VERSION_CODE}" "${4:-$APP_ABI}" "${5:-$APP_SDK}"
    ;;
  all)
    [ $# -le 1 ] ||
      fail "'all' takes no arguments - call the app by name to override version, versionCode, abi or sdk."
    app_defaults ather
    fetch_app "$APP_VERSION" "$APP_VERSION_CODE" "$APP_ABI" "$APP_SDK"
    app_defaults nothingx
    fetch_app "$APP_VERSION" "$APP_VERSION_CODE" "$APP_ABI" "$APP_SDK"
    ;;
  *)
    fail "usage: $0 ather|nothingx|all [version [versionCode [abi [sdk]]]]"
    ;;
esac

echo
echo "Now verify before building:"
echo "  APP=<app> APP_PACKAGE=<package> bash scripts/verify-vendor-apks.sh"
