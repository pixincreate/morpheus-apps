#!/usr/bin/env bash
#
# Morpheus vendor watcher.
# Licensed under CC0 1.0 Universal.
#
# Asks APKPure for the newest build of every app in the build matrix. When the
# vendor ships a newer version it refreshes vendor/<app>/, rewrites that app's
# lines in vendor/SHA256SUMS, bumps the version in .github/workflows/build.yml,
# commits, pushes, files a notification issue and dispatches the build.
#
# The bump is only half the work: the patches were verified against the previous
# version. A patch that no longer applies fails the build, and the report job in
# build.yml files that in pixincreate/morpheus.
#
# Environment:
#   GH_TOKEN      the workflow token; pushes the commit and dispatches the build
#   ISSUE_TOKEN   token that files the issues; falls back to GH_TOKEN, which only
#                 reaches BUILD_REPO
#   BUILD_REPO    repository to file the issues in; defaults to GITHUB_REPOSITORY
#   DRY_RUN       when set, resolve the versions, print the plan and change nothing

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/build.yml"
FETCH="$ROOT/scripts/fetch-vendor-apks.mjs"
BUILD_REPO="${BUILD_REPO:-${GITHUB_REPOSITORY:-pixincreate/morpheus-apps}}"
DRY_RUN="${DRY_RUN:-}"

info() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

# Issue operations use ISSUE_TOKEN when it is set. The workflow token pushes the
# commit and dispatches the build, so a fine-grained PAT needs Issues only.
issue_gh() {
  GH_TOKEN="${ISSUE_TOKEN:-$GH_TOKEN}" gh "$@"
}

# The app names in the build matrix, in file order.
app_list() {
  awk '/^      matrix:/{inside=1}
       inside && $1=="-" && $2=="name:"{print $3}
       /^    steps:/{inside=0}' "$WORKFLOW"
}

# One field of one matrix app, quotes stripped.
app_field() { # $1 app, $2 field
  awk -v app="$1" -v want="$2" '
    /^      matrix:/{inside=1}
    inside && $1=="-" && $2=="name:"{current=$3}
    inside && current==app && $1==want":"{gsub(/"/,"",$2); print $2; exit}
    /^    steps:/{inside=0}' "$WORKFLOW"
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

# Replace the lines of one app in vendor/SHA256SUMS with the hashes of the APKs
# that are in vendor/<app>/ now, and keep the other apps untouched.
refresh_checksums() { # $1 app
  local app="$1" tmp
  tmp="$(mktemp)"
  grep -v "  $app/" "$ROOT/vendor/SHA256SUMS" > "$tmp" || true
  (cd "$ROOT/vendor" && for file in "$app"/*.apk; do sha256 "$file"; done) |
    sort -k2 >> "$tmp"
  mv "$tmp" "$ROOT/vendor/SHA256SUMS"
}

# Write the new version and version code into the matrix entry of one app.
bump_matrix() { # $1 app, $2 version, $3 version code
  local app="$1" version="$2" code="$3" tmp
  tmp="$(mktemp)"
  awk -v app="$app" -v version="$version" -v code="$code" '
    /^      matrix:/{inside=1}
    /^    steps:/{inside=0}
    inside && $1=="-" && $2=="name:"{current=$3}
    inside && current==app && $1=="version:"{
      print "            version: \"" version "\""
      next
    }
    inside && current==app && $1=="version_code:"{
      print "            version_code: \"" code "\""
      next
    }
    {print}
  ' "$WORKFLOW" > "$tmp"
  mv "$tmp" "$WORKFLOW"
}

# File the notification issue and close the earlier one for the same app.
file_issue() { # $1 app, $2 title, $3 version, $4 version code, $5 commit, $6 run url
  local app="$1" app_title="$2" version="$3" code="$4" commit="$5" run="$6"
  local body
  body="$(mktemp)"

  cat > "$body" <<EOF
<!-- vendor-bump:${app}:${version} -->
APKPure serves ${app_title} ${version} (version code ${code}), newer than the version this repository built before.

- Refreshed \`vendor/${app}/\` and its lines in \`vendor/SHA256SUMS\`
- Bumped the build matrix and pushed it as ${commit}
- Build: ${run}

The patches were verified against the previous version. If a fingerprint no longer
matches, the build fails and the report job files that in \`pixincreate/morpheus\`
automatically.
EOF

  if [ -n "$DRY_RUN" ]; then
    info "dry run: would file a bump issue for $app $version in $BUILD_REPO"
    rm -f "$body"
    return
  fi

  local old url number
  old="$(issue_gh issue list -R "$BUILD_REPO" --state open \
    --search "\"<!-- vendor-bump:${app}:\" in:body" \
    --json number,body \
    --jq "first(.[] | select(.body | contains(\"<!-- vendor-bump:${app}:\")) | .number) // empty" \
    2>/dev/null || true)"
  if [ -n "$old" ]; then
    issue_gh issue comment "$old" -R "$BUILD_REPO" \
      --body "Superseded by ${app_title} ${version}." >/dev/null
    issue_gh issue close "$old" -R "$BUILD_REPO" >/dev/null
    info "closed the earlier $app bump issue (#$old)"
  fi

  url="$(issue_gh issue create -R "$BUILD_REPO" \
    --title "Bump ${app_title} to ${version}" --body-file "$body")"
  rm -f "$body"
  number="${url##*/}"

  # The label is cosmetic, so it never blocks the report.
  issue_gh label create vendor-update -R "$BUILD_REPO" --force --color 1D76DB \
    --description "A newer vendor build started a bump" >/dev/null 2>&1 || true
  issue_gh issue edit "$number" -R "$BUILD_REPO" --add-label vendor-update \
    >/dev/null 2>&1 || true

  info "filed $url"
}

read -r -a APPS <<<"$(app_list | tr '\n' ' ')"
bumps=""

for app in "${APPS[@]}"; do
  [ -n "$app" ] || continue
  title="$(app_field "$app" title)"
  package="$(app_field "$app" package)"
  version="$(app_field "$app" version)"
  code="$(app_field "$app" version_code)"

  info "$app: the matrix pins $version ($code)"

  if ! latest="$(node "$FETCH" "$app" --latest-version)"; then
    warn "$app: could not read the latest version, skipping"
    continue
  fi
  new_version="$(printf '%s\n' "$latest" | sed -n 's/^version=//p' | tail -1)"
  new_code="$(printf '%s\n' "$latest" | sed -n 's/^versionCode=//p' | tail -1)"

  if [ -z "$new_version" ] || [ -z "$new_code" ]; then
    warn "$app: the latest download declared no version, skipping"
    continue
  fi
  if [ "$new_version" = "$version" ] && [ "$new_code" = "$code" ]; then
    info "$app: $version ($code) is the newest build"
    continue
  fi

  info "$app: $new_version ($new_code) is newer than $version ($code)"
  if [ -n "$DRY_RUN" ]; then
    info "dry run: would fetch $new_version, refresh the checksums, bump the matrix and commit"
    continue
  fi

  node "$FETCH" "$app" "$new_version" "$new_code"
  refresh_checksums "$app"
  if ! APP="$app" APP_PACKAGE="$package" bash "$ROOT/scripts/verify-vendor-apks.sh"; then
    warn "$app: the fetched APKs failed verification, leaving the matrix alone"
    git -C "$ROOT" checkout -- vendor/SHA256SUMS
    continue
  fi
  bump_matrix "$app" "$new_version" "$new_code"

  git -C "$ROOT" add vendor/SHA256SUMS .github/workflows/build.yml
  git -C "$ROOT" commit --signoff \
    -m "build: bump $title to $new_version" \
    -m "APKPure serves $new_version (version code $new_code) for $package. vendor/$app/ and its lines in vendor/SHA256SUMS are refreshed and the matrix builds the new version from now on." \
    -m "Assisted-by: DeepSeek V4.1 Flash" >/dev/null

  sha="$(git -C "$ROOT" rev-parse --short HEAD)"
  info "$app: committed the bump as $sha"
  bumps="${bumps}${app}|${title}|${new_version}|${new_code}|${sha};"
done

if [ -z "$bumps" ]; then
  info "every app in the matrix is up to date"
  exit 0
fi

if [ -n "$DRY_RUN" ]; then
  info "dry run: would push the bumps and dispatch the build"
  exit 0
fi

git -C "$ROOT" push origin "HEAD:${GITHUB_REF_NAME:-main}"

gh workflow run build.yml -R "$BUILD_REPO"
sleep 10
run_url="$(gh run list -R "$BUILD_REPO" --workflow build.yml --limit 1 \
  --json url --jq '.[0].url' 2>/dev/null || true)"
info "dispatched $run_url"

IFS=';' read -r -a records <<<"$bumps"
for record in "${records[@]}"; do
  [ -n "$record" ] || continue
  IFS='|' read -r app title version code sha <<<"$record"
  file_issue "$app" "$title" "$version" "$code" "$sha" "$run_url"
done
