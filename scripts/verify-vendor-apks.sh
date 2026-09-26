#!/usr/bin/env bash
# Verify the untouched vendor APKs before the patch bundle touches them.
#
# Two gates:
#   1. Checksums. When vendor/SHA256SUMS exists, every entry it lists for this
#      app must match the file on disk. Generate or refresh it with:
#        (cd vendor && shasum -a 256 ather/*.apk nothingx/*.apk > SHA256SUMS)
#   2. Certificates. vendor-certs.json pins the signing certificate per package.
#      Every APK in vendor/<APP>/ must carry the pinned SHA-1 and SHA-256
#      certificate. An empty pin prints the certificate that apksigner reports
#      and skips the check, so fill the pin before trusting a new app.
#
# The bundled apksigner accepts only one APK per invocation - a split set as
# multiple positional arguments fails - so this script calls it once per file.
# apksigner needs the JDK (JBR or temurin) on JAVA_HOME.
#
# Environment:
#   APP                  app directory under vendor/ (default: ather)
#   APP_PACKAGE          package name, the key in vendor-certs.json (required)
#   JAVA_HOME            JDK that runs apksigner
#   ANDROID_HOME         Android SDK (default: ~/Library/Android/sdk)
#   BUILD_TOOLS_VERSION  build-tools revision (default: 37.0.0)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-ather}"
APP_PACKAGE="${APP_PACKAGE:-}"
JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export JAVA_HOME
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_HOME
BUILD_TOOLS_VERSION="${BUILD_TOOLS_VERSION:-37.0.0}"
BT="$ANDROID_HOME/build-tools/$BUILD_TOOLS_VERSION"
VENDOR_DIR="$ROOT/vendor/$APP"
CERT_FILE="$ROOT/vendor-certs.json"
SUMS_FILE="$ROOT/vendor/SHA256SUMS"

fail() {
  echo "verify-vendor-apks: $1" >&2
  exit 1
}

warn() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::warning::$1"
  else
    echo "verify-vendor-apks: warning: $1" >&2
  fi
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

[ -n "$APP_PACKAGE" ] || fail "APP_PACKAGE is not set."
[ -d "$VENDOR_DIR" ] || fail "vendor/$APP/ is missing - fetch the vendor APKs first (see README.md)."
[ -f "$CERT_FILE" ] || fail "vendor-certs.json is missing."
[ -x "$JAVA_HOME/bin/java" ] || fail "$JAVA_HOME/bin/java is missing - set JAVA_HOME to the JDK that runs apksigner."
[ -x "$BT/apksigner" ] || fail "$BT/apksigner is missing - install build-tools $BUILD_TOOLS_VERSION, or set ANDROID_HOME."

found=0
for apk in "$VENDOR_DIR"/*.apk; do
  [ -f "$apk" ] || continue
  found=1
done
[ "$found" -eq 1 ] || fail "vendor/$APP/ has no APK files."

# Gate 1: checksums, when the maintainer committed them.
if [ -f "$SUMS_FILE" ]; then
  listed=0
  while read -r expected rel; do
    case "$expected" in
      "" | \#*) continue ;;
    esac
    case "$rel" in
      "$APP"/*) ;;
      *) continue ;;
    esac
    listed=$((listed + 1))
    [ -f "$ROOT/vendor/$rel" ] || fail "vendor/SHA256SUMS lists vendor/$rel, but the file is missing."
    actual="$(sha256_of "$ROOT/vendor/$rel")"
    [ "$actual" = "$expected" ] ||
      fail "SHA-256 mismatch for $rel: vendor/SHA256SUMS says $expected, the file is $actual."
    echo "checksum ok: $rel"
  done <"$SUMS_FILE"
  if [ "$listed" -eq 0 ]; then
    fail "vendor/SHA256SUMS lists no files for $APP, so the checksum gate would accept any APK. Add the entries (see README.md)."
  fi
else
  warn "vendor/SHA256SUMS is not present; skipping the checksum gate."
fi

# Gate 2: certificate pins.
pin() {
  python3 - "$CERT_FILE" "$APP_PACKAGE" "$1" <<'PY'
import json
import sys

path, package, key = sys.argv[1:4]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
entry = data.get(package) or {}
print(entry.get(key, ""))
PY
}

PIN_SHA1="$(pin sha1)"
PIN_SHA256="$(pin sha256)"

for apk in "$VENDOR_DIR"/*.apk; do
  [ -f "$apk" ] || continue
  name="$(basename "$apk")"

  if ! out="$("$BT/apksigner" verify --print-certs "$apk" 2>&1)"; then
    echo "$out" >&2
    fail "apksigner rejected $name."
  fi

  cert_sha1="$(grep -m1 'certificate SHA-1 digest:' <<<"$out" | sed 's/.*: //' | tr 'A-F' 'a-f')"
  cert_sha256="$(grep -m1 'certificate SHA-256 digest:' <<<"$out" | sed 's/.*: //' | tr 'A-F' 'a-f')"
  [ -n "$cert_sha1" ] || fail "cannot read the signing certificate of $name."

  if [ -z "$PIN_SHA1" ] && [ -z "$PIN_SHA256" ]; then
    warn "vendor-certs.json has no pin for $APP_PACKAGE; observed $name SHA-1 $cert_sha1 SHA-256 $cert_sha256. Fill the pin before trusting this app."
    continue
  fi

  if [ -n "$PIN_SHA1" ] && [ "$cert_sha1" != "$PIN_SHA1" ]; then
    fail "certificate mismatch for $name: vendor-certs.json pins SHA-1 $PIN_SHA1, the file is $cert_sha1."
  fi
  if [ -n "$PIN_SHA256" ] && [ "$cert_sha256" != "$PIN_SHA256" ]; then
    fail "certificate mismatch for $name: vendor-certs.json pins SHA-256 $PIN_SHA256, the file is $cert_sha256."
  fi
  echo "certificate ok: $name (SHA-1 $cert_sha1)"
done

echo "verified vendor/$APP against vendor-certs.json"
