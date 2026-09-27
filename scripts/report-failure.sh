#!/usr/bin/env bash
#
# Ather Morpheus apps build pipeline.
# Licensed under CC0 1.0 Universal.
#
# Turn a failed Build run into an issue in the repository that needs the fix, or
# close the resolved issues after a green run.
#
# Routing:
#   patch, bundle   -> MORPHE_REPO, the public patches repository
#   everything else -> REPO, this private build repository
#
# The script is idempotent. Each failure kind and app has one marker; a repeated
# failure comments on the open issue, and a green run closes it.
#
# Environment:
#   GH_TOKEN      actions:read on REPO; for cross-repository issues the token
#                 also needs issues:write on MORPHE_REPO
#   RUN_ID        run to inspect (CI sets GITHUB_RUN_ID)
#   REPO          repository that ran the workflow (CI sets GITHUB_REPOSITORY)
#   MORPHE_REPO   patches repository, default pixincreate/morpheus
#   BUILD_RESULT  success closes issues, anything else reports failures
#   DRY_RUN       when set, print the plan and write nothing

set -euo pipefail

REPO="${REPO:-${GITHUB_REPOSITORY:?REPO or GITHUB_REPOSITORY must be set}}"
RUN_ID="${RUN_ID:-${GITHUB_RUN_ID:?RUN_ID or GITHUB_RUN_ID must be set}}"
MORPHE_REPO="${MORPHE_REPO:-pixincreate/morpheus}"
BUILD_RESULT="${BUILD_RESULT:-failure}"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
RUN_URL="$SERVER/$REPO/actions/runs/$RUN_ID"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/build.yml"
KINDS="patch fetch verify bundle signing merge stage publish unknown"

info() { printf '%s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*" >&2; }

# Read a field of one app from the workflow matrix.
matrix_field() { # $1 app, $2 field
  awk -v app="$1" -v field="$2" '
    $1 == "-" && $2 == "name:" { inside = ($3 == app) }
    inside && $1 == field { gsub(/"/, "", $2); print $2; exit }
  ' "$WORKFLOW"
}

# List the apps the matrix builds.
matrix_apps() {
  awk '
    /^      matrix:/ { inside = 1 }
    /^    steps:/ { inside = 0 }
    inside && $1 == "-" && $2 == "name:" { gsub(/"/, "", $3); print $3 }
  ' "$WORKFLOW"
}

# The failed step decides the kind. "Build and merge" runs both the patch bundle
# and the split merge, so the log text separates them.
classify() { # $1 failed steps, newline separated, $2 log file
  local steps="$1" logfile="$2"
  case "$steps" in
    *"Fetch vendor APKs"*)                echo fetch; return ;;
    *"Verify vendor APKs"*)               echo verify; return ;;
    *"Download the newest patch bundle"*) echo bundle; return ;;
    *"Decode the signing keystore"*)      echo signing; return ;;
    *"Sign the merged APK"*)              echo signing; return ;;
    *"Stage the signed APK"*)             echo stage; return ;;
    *"Upload the signed APK"*)            echo stage; return ;;
    *"Publish the release"*)              echo publish; return ;;
  esac
  if grep -qE 'Patching aborted|Failed to match the fingerprint|PatchException' "$logfile"; then
    echo patch
  elif grep -q 'APKEditor' "$logfile"; then
    echo merge
  else
    echo unknown
  fi
}

# Where the fix belongs.
target_for() {
  case "$1" in
    patch | bundle) printf '%s\n' "$MORPHE_REPO" ;;
    *) printf '%s\n' "$REPO" ;;
  esac
}

title_for() { # $1 kind, $2 app, $3 version
  case "$1" in
    patch)   echo "Patch failure: $2 $3 does not apply" ;;
    fetch)   echo "Vendor fetch failed: $2 $3" ;;
    verify)  echo "Vendor verification failed: $2 $3" ;;
    bundle)  echo "Patch bundle download failed" ;;
    signing) echo "Signing failed: $2" ;;
    merge)   echo "Split merge failed: $2" ;;
    stage)   echo "Staging failed: $2" ;;
    publish) echo "Release publishing failed: $2" ;;
    *)       echo "Build failed: $2 $3" ;;
  esac
}

# What to do about it.
advice_for() { # $1 kind, $2 app, $3 version
  case "$1" in
    patch) cat <<EOF
A vendor update renamed or removed the classes this fingerprint pins, so the
patch bundle no longer applies. Retarget the patch the way v0.1.5 retargeted
13.5.1: decode the vendor base APK with apktool, find the renamed class, update
the fingerprint, and release a new bundle. The failing patch and fingerprint
names are in the log below; the file that holds them:

    rg -n 'name = "<patch name>"' $MORPHE_REPO/patches/src/main/kotlin
EOF
      ;;
    fetch) cat <<EOF
The direct APKPure download failed or the endpoint changed. CI retries are
cheap: rerun the workflow once, the challenge is flaky. If it keeps failing,
upload the untouched vendor APKs as a private release and CI uses it first:

    gh release create vendor/$2/$3 -R $REPO vendor/$2/*.apk
EOF
      ;;
    verify) cat <<EOF
The APKs that arrived are not the bytes this repository pins, or the vendor
signing certificate changed. Check \`vendor/SHA256SUMS\` and
\`vendor-certs.json\`. If the vendor re-signed the app, the
\`SigningCertificatePatch\` in $MORPHE_REPO pins the old certificate too.
EOF
      ;;
    bundle) cat <<EOF
The newest patch bundle release in $MORPHE_REPO could not be downloaded or is
not loadable (it must contain classes.dex). Check the latest release there.
EOF
      ;;
    signing) cat <<EOF
Decoding the keystore or signing the APK failed. Check the four repository
secrets (KEYSTORE_BASE64, KEYSTORE_PASSWORD, KEY_PASSWORD, KEY_ALIAS) with the
commands in README.md.
EOF
      ;;
    merge) cat <<EOF
APKEditor could not merge the patched base with the vendor splits. Check that
the matrix \`splits\` names still match the files the vendor bundle ships.
EOF
      ;;
    stage) cat <<EOF
The merge did not leave exactly one signed APK. A release carries one file so
Obtainium installs it with a plain install. Check the merge output in the log.
EOF
      ;;
    publish) cat <<EOF
The release action failed. Check the tag and the asset name in the log.
EOF
      ;;
    *) cat <<EOF
The job failed before its later steps. Check the log below.
EOF
      ;;
  esac
}

issue_slug() { printf 'morpheus-ci-failure-%s-%s\n' "$1" "$2"; }

find_open_issue() { # $1 repo, $2 slug
  gh issue list -R "$1" --state open --search "$2 in:body" \
    --json number --jq '.[0].number // empty' 2>/dev/null || true
}

create_issue() { # $1 repo, $2 title, $3 body file
  gh label create ci-failure -R "$1" --force --color FBCA04 \
    --description "Reported automatically by the Build workflow" >/dev/null 2>&1 || true
  gh issue create -R "$1" --title "$2" --body-file "$3" --label ci-failure
}

comment_issue() { # $1 repo, $2 number, $3 body file
  gh issue comment "$2" -R "$1" --body-file "$3"
}

build_body() { # $1 file, $2 kind, $3 app, $4 version, $5 code, $6 step, $7 log file, $8 note
  local file="$1" kind="$2" app="$3" version="$4" code="$5" step="$6" logfile="$7" note="${8:-}"
  {
    echo "<!-- $(issue_slug "$kind" "$app") -->"
    echo
    echo "The [Build workflow]($RUN_URL) failed for **$app $version** (version code $code)."
    echo
    echo "- Failure kind: \`$kind\`"
    echo "- Failed step: \`$step\`"
    echo "- App in the matrix: \`$app $version\`"
    echo
    advice_for "$kind" "$app" "$version"
    echo
    if [ -n "$note" ]; then
      echo "$note"
      echo
    fi
    local patch fingerprint
    patch="$(grep -oE 'FAILED: .*' "$logfile" | head -1 || true)"
    fingerprint="$(grep -oE 'Failed to match the fingerprint: [^ ]+' "$logfile" | head -1 || true)"
    if [ -n "$patch" ] || [ -n "$fingerprint" ]; then
      echo "Evidence:"
      echo
      [ -n "$patch" ] && echo "- $patch"
      [ -n "$fingerprint" ] && echo "- $fingerprint"
      echo
    fi
    echo "<details><summary>Log tail of the failed step</summary>"
    echo
    echo '```text'
    tail -n 60 "$logfile" | sed -E 's/\x1b\[[0-9;]*m//g' | tail -c 4000
    echo '```'
    echo
    echo "</details>"
  } > "$file"
}

report_failures() {
  local jobs rows
  jobs="$(gh api "repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=100")"
  rows="$(printf '%s' "$jobs" | jq -r '.jobs[] | select(.conclusion == "failure") | "\(.id) \(.name)"')"
  if [ -z "$rows" ]; then
    warn "Run $RUN_ID has no failed job, nothing to report."
    return 0
  fi

  while read -r job_id job_name; do
    [ -n "$job_id" ] || continue
    case "$job_name" in
      build-*) ;;
      *) info "skip $job_name: not an app build"; continue ;;
    esac
    local app="${job_name#build-}"
    local logfile steps step kind target version code slug number title bodyfile out
    logfile="$(mktemp)"
    bodyfile="$(mktemp)"
    gh api --allow-escape-sequences "repos/$REPO/actions/jobs/$job_id/logs" > "$logfile" 2>/dev/null ||
      warn "could not read the log of $job_name"

    steps="$(printf '%s' "$jobs" | jq -r --argjson id "$job_id" \
      '.jobs[] | select(.id == $id) | .steps[] | select(.conclusion == "failure") | .name')"
    step="$(printf '%s' "$steps" | head -1)"
    kind="$(classify "$steps" "$logfile")"
    target="$(target_for "$kind")"
    version="$(matrix_field "$app" "version:")"
    code="$(matrix_field "$app" "version_code:")"
    version="${version:-unknown}"
    code="${code:-unknown}"
    slug="$(issue_slug "$kind" "$app")"
    title="$(title_for "$kind" "$app" "$version")"

    info "$job_name failed at '$step' -> kind=$kind target=$target"

    if [ -n "${DRY_RUN:-}" ]; then
      info "dry run: would report '$title' in $target (marker $slug)"
      rm -f "$logfile" "$bodyfile"
      continue
    fi

    if [ -n "$(find_open_issue "$target" "$slug")" ]; then
      number="$(find_open_issue "$target" "$slug")"
      build_body "$bodyfile" "$kind" "$app" "$version" "$code" "$step" "$logfile" \
        "This failure happened again."
      comment_issue "$target" "$number" "$bodyfile"
      info "commented on $target#$number"
    else
      build_body "$bodyfile" "$kind" "$app" "$version" "$code" "$step" "$logfile"
      if out="$(create_issue "$target" "$title" "$bodyfile" 2>&1)"; then
        info "created $out"
      else
        warn "could not create an issue in $target: $out"
        build_body "$bodyfile" "$kind" "$app" "$version" "$code" "$step" "$logfile" \
          "> Routed to \`$REPO\` because the token cannot open issues in \`$target\`. Add an \`ISSUE_TOKEN\` secret with issues:write on both repositories to route it correctly."
        if out="$(create_issue "$REPO" "$title" "$bodyfile" 2>&1)"; then
          info "created $out (fallback repository)"
        else
          warn "could not create an issue in $REPO either: $out"
        fi
      fi
    fi
    rm -f "$logfile" "$bodyfile"
  done <<< "$rows"
}

close_resolved() {
  local app kind slug number target
  for app in $(matrix_apps); do
    for kind in $KINDS; do
      slug="$(issue_slug "$kind" "$app")"
      for target in "$REPO" "$MORPHE_REPO"; do
        for number in $(find_open_issue "$target" "$slug"); do
          if [ -n "${DRY_RUN:-}" ]; then
            info "dry run: would close $target#$number ($slug)"
            continue
          fi
          if gh issue comment "$number" -R "$target" \
            --body "The Build workflow succeeded again in $RUN_URL, so this is resolved. Closing." >/dev/null 2>&1 &&
            gh issue close "$number" -R "$target" >/dev/null 2>&1; then
            info "closed $target#$number ($slug)"
          else
            warn "cannot close $target#$number, check the token permissions"
          fi
        done
      done
    done
  done
}

case "$BUILD_RESULT" in
  success) close_resolved ;;
  cancelled) info "run cancelled, nothing to report" ;;
  *) report_failures ;;
esac
