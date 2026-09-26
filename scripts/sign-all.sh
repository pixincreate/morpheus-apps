#!/usr/bin/env bash
# Align and sign the APKs scripts/build.sh produced with one shared key.
#
# The build produces one merged APK per app. Signing every build with one key
# keeps the signature stable, so the package manager treats a new build as an
# update of the previous one: without that, Android rejects the install with a
# signature mismatch.
#
# Override these settings in the environment to reuse the script:
#   APKS                 input APKs, space separated
#                        (default: build/merged-unsigned.apk)
#   SIGNED_NAME          output name for a single input, without .apk
#                        (default: the input file name)
#   OUT_DIR              signed output directory (default: out/signed)
#   KS                   signing keystore (required; never commit one)
#   KS_PASS              keystore password (required)
#   KS_KEY_PASS          key password (default: KS_PASS)
#   KS_ALIAS             key alias (required)
#   ANDROID_HOME         Android SDK (default: ~/Library/Android/sdk)
#   BUILD_TOOLS_VERSION  build-tools revision (default: 37.0.0)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
APKS="${APKS:-$ROOT/build/merged-unsigned.apk}"
SIGNED_NAME="${SIGNED_NAME:-}"
OUT_DIR="${OUT_DIR:-$ROOT/out/signed}"

[ -n "$KS" ] || fail "KS is not set - point it at the signing keystore (see README.md to add the secrets)."
[ -n "$KS_PASS" ] || fail "KS_PASS is not set - set it to the KEYSTORE_PASSWORD secret."
[ -n "$KS_ALIAS" ] || fail "KS_ALIAS is not set - set it to the KEY_ALIAS secret."
[ -f "$KS" ] || fail "$KS is missing."
[ -x "$BT/apksigner" ] || fail "$BT/apksigner is missing - install build-tools $BUILD_TOOLS_VERSION, or set ANDROID_HOME."

export KS_PASS KS_KEY_PASS

# Keep the recursive delete inside the repository output directory.
case "$OUT_DIR" in
  "$ROOT"/out|"$ROOT"/out/*) ;;
  *) fail "OUT_DIR must live under $ROOT/out - refusing to remove '$OUT_DIR'" ;;
esac
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

align_and_sign() {
  local src="$1" name="$2"
  local aligned="$OUT_DIR/${name}.aligned.apk"
  local final="$OUT_DIR/${name}.apk"
  [ -f "$src" ] || fail "$src is missing - run scripts/build.sh first."
  "$BT/zipalign" -p -f 4 "$src" "$aligned"
  "$BT/apksigner" sign \
    --ks "$KS" --ks-pass env:KS_PASS --key-pass env:KS_KEY_PASS \
    --ks-key-alias "$KS_ALIAS" \
    --v1-signing-enabled true --v2-signing-enabled true \
    --v3-signing-enabled true --v4-signing-enabled false \
    --out "$final" "$aligned"
  rm -f "$aligned" "${final}.idsig"
  echo "signed: $final"
}

n=0
for src in $APKS; do
  n=$((n + 1))
  name="$(basename "$src" .apk)"
  if [ -n "$SIGNED_NAME" ] && [ "$n" -eq 1 ]; then
    name="$SIGNED_NAME"
  fi
  align_and_sign "$src" "$name"
done
[ "$n" -gt 0 ] || fail "APKS is empty - pass the unsigned APKs to sign."

echo
echo "Verifying signatures:"
for f in "$OUT_DIR"/*.apk; do
  echo "== $(basename "$f") =="
  "$BT/apksigner" verify --print-certs "$f" | grep -E 'certificate SHA-256 digest|Verified using' || true
done

echo
echo "Signed APKs ready in: $OUT_DIR"
echo "Install with the phone connected:"
if [ "$n" -eq 1 ]; then
  name="$(basename "$APKS" .apk)"
  echo "  adb install $OUT_DIR/${SIGNED_NAME:-$name}.apk"
else
  echo "  adb install-multiple $OUT_DIR/*.apk"
fi
