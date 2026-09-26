#!/usr/bin/env bash
# Sign the patched base APK plus the original config split APKs with one shared
# key. Produces an installable split set under out/signed/.
# Every split in an install set must be signed with the same key, or the
# package manager rejects the install (INSTALL_FAILED_INVALID_APK /
# signature mismatch).
#
# Override these settings in the environment to reuse the script for another app:
#   APP_NAME             names the default split directory (default: ather)
#   SPLITS               config split names under SRC_SPLITS_DIR, space separated
#                        (default: empty; scripts/build.sh fills it with every
#                        APK in vendor/<APP_NAME>/ that is not the base APK)
#   SRC_SPLITS_DIR       directory with the original config.*.apk
#                        (default: vendor/<APP_NAME>)
#   PATCHED_BASE         unsigned patched base APK (default: build/base-unsigned.apk)
#   OUT_DIR              signed output directory (default: out/signed)
#   KS                   signing keystore (required; never commit one)
#   KS_PASS              keystore password (required)
#   KS_KEY_PASS          key password (default: KS_PASS)
#   KS_ALIAS             key alias (required)
#   ANDROID_HOME         Android SDK (default: ~/Library/Android/sdk)
#   BUILD_TOOLS_VERSION  build-tools revision (default: 37.0.0)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-ather}"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_HOME
BUILD_TOOLS_VERSION="${BUILD_TOOLS_VERSION:-37.0.0}"
BT="$ANDROID_HOME/build-tools/$BUILD_TOOLS_VERSION"

fail() {
  echo "$1" >&2
  exit 1
}

KS="${KS:-}"
KS_PASS="${KS_PASS:-}"
KS_KEY_PASS="${KS_KEY_PASS:-$KS_PASS}"
KS_ALIAS="${KS_ALIAS:-}"
SPLITS="${SPLITS:-}"

[ -n "$KS" ] || fail "KS is not set - point it at the signing keystore (see README.md to add the secrets)."
[ -n "$KS_PASS" ] || fail "KS_PASS is not set - set it to the KEYSTORE_PASSWORD secret."
[ -n "$KS_ALIAS" ] || fail "KS_ALIAS is not set - set it to the KEY_ALIAS secret."
[ -f "$KS" ] || fail "$KS is missing."
[ -x "$BT/apksigner" ] || fail "$BT/apksigner is missing - install build-tools $BUILD_TOOLS_VERSION, or set ANDROID_HOME."

export KS_PASS KS_KEY_PASS

SRC_SPLITS_DIR="${SRC_SPLITS_DIR:-$ROOT/vendor/$APP_NAME}"  # original split APKs live here
PATCHED_BASE="${PATCHED_BASE:-$ROOT/build/base-unsigned.apk}"
OUT_DIR="${OUT_DIR:-$ROOT/out/signed}"

if [ -z "$OUT_DIR" ] || [ "$OUT_DIR" = "/" ]; then
  fail "refusing to remove OUT_DIR '$OUT_DIR'"
fi
[ -f "$PATCHED_BASE" ] || fail "$PATCHED_BASE is missing - run scripts/build.sh first."
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

align_and_sign() {
  local in="$1" name="$2"
  local aligned="$OUT_DIR/${name}.aligned.apk"
  local final="$OUT_DIR/${name}.apk"
  "$BT/zipalign" -p -f 4 "$in" "$aligned"
  "$BT/apksigner" sign \
    --ks "$KS" --ks-pass env:KS_PASS --key-pass env:KS_KEY_PASS \
    --ks-key-alias "$KS_ALIAS" \
    --v1-signing-enabled true --v2-signing-enabled true \
    --v3-signing-enabled true --v4-signing-enabled false \
    --out "$final" "$aligned"
  rm -f "$aligned" "${final}.idsig"
  echo "signed: $final"
}

align_and_sign "$PATCHED_BASE" "base"
INSTALL_APKS="$OUT_DIR/base.apk"
for s in $SPLITS; do
  align_and_sign "$SRC_SPLITS_DIR/${s}.apk" "$s"
  INSTALL_APKS="$INSTALL_APKS $OUT_DIR/$s.apk"
done

echo
echo "Verifying signatures:"
for f in "$OUT_DIR"/*.apk; do
  echo "== $(basename "$f") =="
  "$BT/apksigner" verify --print-certs "$f" | grep -E 'certificate SHA-256 digest|Verified using' || true
done

echo
echo "Install set ready in: $OUT_DIR"
echo "Install with the phone connected:"
echo "  adb install-multiple $INSTALL_APKS"
