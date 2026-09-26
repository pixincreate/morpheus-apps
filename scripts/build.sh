#!/usr/bin/env bash
# Build one patched, signed split set from a released Morphe patch bundle.
#
# Layout this script expects:
#   vendor/<app>/   untouched vendor APKs (base APK + original config splits)
#   bundle/         the released Morphe patch bundle (patches-<version>.mpp)
#   build/          scratch: the Morphe CLI, the patched APK
#   out/signed/     the installable split set
#
# The public repository releases the bundle; download it first:
#   gh release download --repo pixincreate/morpheus --pattern 'patches-*.mpp' -D bundle/
#
# The Morphe CLI applies every patch in the bundle to the untouched base APK and
# writes an unsigned APK. scripts/sign-all.sh then signs that APK and the
# original config splits with one key, because every split in an install set must
# carry the same signature.
#
# Usage:
#   bash scripts/build.sh
#
# Override these settings in the environment to reuse the script for another app:
#   APP_NAME      vendor/<APP_NAME> holds the APKs and names the output
#                 (default: ather)
#   APP_PACKAGE   app package the patches target; the base APK defaults to
#                 vendor/<APP_NAME>/<APP_PACKAGE>.apk (required unless BASE_APK
#                 is set)
#   BASE_APK      untouched base APK (default: vendor/<APP_NAME>/<APP_PACKAGE>.apk)
#   SPLITS        config split names under vendor/<APP_NAME>, space separated
#                 (default: every other *.apk in the directory)
#   MPP           patch bundle (default: the newest bundle/patches-*.mpp)
#   JAVA_HOME     JDK 17 or newer (default: Android Studio's JBR)
#   ANDROID_HOME  Android SDK (default: ~/Library/Android/sdk)
# scripts/sign-all.sh also reads APP_NAME, SPLITS, SRC_SPLITS_DIR, KS, KS_PASS,
# KS_KEY_PASS, KS_ALIAS, OUT_DIR, ANDROID_HOME and BUILD_TOOLS_VERSION.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The Morphe CLI and apksigner run on the JDK. The Android Gradle plugin is not
# used here, so any JDK 17 or newer works; the JBR ships with Android Studio.
JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export JAVA_HOME
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_HOME
JAVA="$JAVA_HOME/bin/java"

# Pin the CLI: the patch bundle format must match the CLI that reads it.
CLI_VERSION="1.16.0"
CLI_SHA256="82a0df2ff881d83d5ca8b4f9a6ce196bd4ac3b87ff147fe37845c296b436806c" # keywatch:ignore
CLI_JAR="$ROOT/build/tools/morphe-desktop-$CLI_VERSION-all.jar"
CLI_URL="https://github.com/MorpheApp/morphe-desktop/releases/download/v$CLI_VERSION/morphe-desktop-$CLI_VERSION-all.jar"

fail() {
  echo "$1" >&2
  exit 1
}

APP_NAME="${APP_NAME:-ather}"
VENDOR_DIR="$ROOT/vendor/$APP_NAME"
APP_PACKAGE="${APP_PACKAGE:-}"
if [ -z "$APP_PACKAGE" ] && [ -z "${BASE_APK:-}" ]; then
  fail "APP_PACKAGE is not set - set it to the package the patch bundle targets."
fi
BASE_APK="${BASE_APK:-$VENDOR_DIR/$APP_PACKAGE.apk}"
PATCHED_BASE="$ROOT/build/base-unsigned.apk"

[ -x "$JAVA" ] || fail "$JAVA is missing - install Android Studio, or set JAVA_HOME to a JDK 17 or newer."
[ -f "$BASE_APK" ] || fail "${BASE_APK#"$ROOT"/} is missing - upload the untouched APK to the private vendor release in this repository (see README.md)."

if [ -z "${MPP:-}" ]; then
  MPP="$(find "$ROOT/bundle" -maxdepth 1 -name 'patches-*.mpp' 2>/dev/null | sort -V | tail -n 1)"
fi
if [ -z "$MPP" ] || [ ! -f "$MPP" ]; then
  fail "no patch bundle found - download one into bundle/ (see README.md), or set MPP."
fi

# Sign every split that came with the base APK. An explicit SPLITS value wins.
if [ -z "${SPLITS:-}" ]; then
  base_name="$(basename "$BASE_APK")"
  SPLITS=""
  for f in "$VENDOR_DIR"/*.apk; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "$base_name" ] && continue
    SPLITS="$SPLITS $(basename "$f" .apk)"
  done
  SPLITS="${SPLITS# }"
fi
export SPLITS SRC_SPLITS_DIR="$VENDOR_DIR"

mkdir -p "$(dirname "$CLI_JAR")"

if [ ! -f "$CLI_JAR" ]; then
  echo "[1/3] download the Morphe CLI $CLI_VERSION"
  curl -fL --retry 3 -o "$CLI_JAR.part" "$CLI_URL"
  mv "$CLI_JAR.part" "$CLI_JAR"
fi
ACTUAL_SHA256="$(shasum -a 256 "$CLI_JAR" | cut -d' ' -f1)"
[ "$ACTUAL_SHA256" = "$CLI_SHA256" ] || fail "$CLI_JAR does not match the expected checksum - delete it and run the script again."

echo "[2/3] apply the patch bundle $(basename "$MPP")"
rm -rf "$ROOT/build/cli-tmp"
rm -f "$PATCHED_BASE"
"$JAVA" -jar "$CLI_JAR" patch \
  -p="$MPP" \
  --unsigned \
  --disable-purge \
  -t="$ROOT/build/cli-tmp" \
  -o="$PATCHED_BASE" \
  "$BASE_APK"

echo "[3/3] sign the patched base APK and the original splits"
bash "$ROOT/scripts/sign-all.sh"
