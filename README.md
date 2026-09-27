# morpheus-apps

Private build repository for [pixincreate/morpheus](https://github.com/pixincreate/morpheus).
It takes the newest public patch bundle, applies it to untouched vendor APKs, merges the
split set into one APK, signs it, and publishes one versioned private release per app:
`ather-<version>` and `nothingx-<version>`.
Each release carries a single file, `morpheus-<app>-<version>.apk`, so
[Obtainium](https://github.com/ImranR98/Obtainium) can detect and install the next build.

This repository must stay private.
It carries the signing key in an encrypted secret and the untouched vendor APKs as
private release assets.
Anyone who can read a release can install patched builds that carry your signing key,
so do not make the repository public and do not forward release assets.

## How a build runs

The workflow [`.github/workflows/build.yml`](.github/workflows/build.yml) runs weekly
(Mondays 02:00 UTC) and on demand.
For each app it does this:

1. Downloads the untouched vendor APKs from the private `vendor/<app>/<version>`
   release in this repository.
   `scripts/fetch-vendor-apks.mjs` is the best-effort web fallback for the
   APKPure direct download endpoints: it drives a headed browser with patchright
   under `xvfb-run` in CI.
2. Verifies the APKs with `scripts/verify-vendor-apks.sh`:
   SHA-256 against the committed `vendor/SHA256SUMS` when present, and the signing
   certificate against the pins in `vendor-certs.json`.
3. Downloads the newest patch bundle from the public repository with
   `gh release download --repo pixincreate/morpheus --pattern 'patches-*.mpp'`.
4. Applies the bundle to the base APK with `scripts/build.sh` and the Morphe CLI
   (`--unsigned --disable-purge`).
5. Merges the patched base APK and the original config splits into one standalone
   APK with APKEditor, because a release must carry one file for Obtainium.
6. Signs the merged APK with `scripts/sign-all.sh`.
   The workflow decodes `KEYSTORE_BASE64` to a temporary file with mode 600 and
   deletes it in an `always()` step.
7. Publishes the release `ather-13.5.1` with the asset
   `morpheus-ather-13.5.1.apk` through `ncipollo/release-action`.
   A rerun replaces the asset and the notes in the same release.
8. Reports a failure as an issue in the repository that needs the fix with
   `scripts/report-failure.sh`. Patch and bundle failures go to
   `pixincreate/morpheus`, everything else stays here.

The build matrix uses `fail-fast: false`, so one app failing does not lose the other
app's APKs.

## Obtainium

Add one source per app.
Point both at the same repository URL and separate them with the title filter.

| Setting | Ather | Nothing X |
| --- | --- | --- |
| Repository URL | `https://github.com/pixincreate/morpheus-apps` | same |
| Filter release titles by RegEx | `^Ather` | `^Nothing X` |
| Version extraction RegEx | `(\d+\.\d+\.\d+)` | `(\d+\.\d+\.\d+)` |
| Match group to use | `1` | `1` |
| APK filter RegEx | `ather` | `nothingx` |
| Include prereleases | off | off |

The release title carries the version (`Ather 13.5.1`), and the version extraction
reads it into the plain `13.5.1` shape that Obtainium compares.
The title filter and the APK filter keep the other app's release out.
A new released version makes Obtainium report an update, and every build is signed
with the same key, so the update installs over the previous build.

## Required secrets

Set all four secrets before the first run.
`GITHUB_TOKEN` is automatic, and the public repository needs no extra scope.

| Secret | Value |
| --- | --- |
| `KEYSTORE_BASE64` | base64 of your signing keystore |
| `KEYSTORE_PASSWORD` | keystore password |
| `KEY_PASSWORD` | key password |
| `KEY_ALIAS` | key alias |

```bash
base64 -i ~/.keystores/pixincreate_gh.jks | gh secret set KEYSTORE_BASE64 -R pixincreate/morpheus-apps
gh secret set KEYSTORE_PASSWORD -R pixincreate/morpheus-apps   # gh prompts for the value
gh secret set KEY_PASSWORD -R pixincreate/morpheus-apps        # gh prompts for the value
gh secret set KEY_ALIAS -R pixincreate/morpheus-apps --body <alias>
```

Never commit a keystore or a password.
The workflow fails with a clear `::error::` message when a secret is missing.

### Failure issues (optional)

When a run fails, the `report` job opens an issue in the repository that needs the
fix:

| Failure | Repository |
| --- | --- |
| A patch fingerprint no longer matches, or the bundle download fails | `pixincreate/morpheus` |
| Vendor fetch, verification, signing, merge, staging, publishing | this repository |

`GITHUB_TOKEN` can only open issues here. To route patch failures to the public
repository, create a fine-grained token with `Issues: Read and write` on
`pixincreate/morpheus` and on `pixincreate/morpheus-apps`, then store it:

```bash
gh secret set ISSUE_TOKEN -R pixincreate/morpheus-apps
```

Without the token, every failure lands here with a note that says where it belongs.
The job keeps one open issue per failure kind and app: a repeated failure comments on
that issue, and the next green run closes it.

## Bump an app version

Edit the version and its version code in the build matrix in
`.github/workflows/build.yml`, and refresh `vendor/SHA256SUMS` after uploading the
new vendor APKs.
The next run publishes a new release, for example `ather-13.5.1`, and Obtainium picks
it up.

## Upload the vendor APKs

The web fallback covers the common case, so the upload is optional.
Create one private release per app and version, then attach the untouched APKs.
The workflow downloads them with:

```bash
gh release download vendor/ather/13.5.1 -p '*.apk' -D vendor/ather/
```

Name the base APK after its package and keep the original split names:

- `com.athermobileapp.apk`, then `config.arm64_v8a.apk`, `config.en.apk`,
  `config.mdpi.apk`. These names must match the `splits` value in the build
  matrix.
- `com.nothing.smartcenter.apk`, then every config split from the vendor bundle.

### Read the APKs from the phone

```bash
mkdir -p vendor/ather
for p in $(adb shell pm path com.athermobileapp | sed 's/^package://'); do
  adb pull "$p" "vendor/ather/$(basename "$p")"
done
mv vendor/ather/base.apk vendor/ather/com.athermobileapp.apk
```

### Create the vendor release

```bash
gh release create vendor/ather/13.5.1 -R pixincreate/morpheus-apps \
  --title "Ather 13.5.1 vendor APKs" \
  --notes "Untouched Ather 13.5.1 base APK and config splits." \
  --latest=false \
  vendor/ather/com.athermobileapp.apk \
  vendor/ather/config.arm64_v8a.apk \
  vendor/ather/config.en.apk \
  vendor/ather/config.mdpi.apk
```

Use the same shape for Nothing X with tag `vendor/nothingx/3.8.0`.
For an APKPure `.xapk`, `unzip` it, rename the base APK to the package name, and
keep every config split it contains.
`scripts/fetch-vendor-apks.mjs` normalises the base name and keeps every `*.apk`
the same way.

### Checksums

Commit the checksums so the workflow can verify the vendor release:

```bash
(cd vendor && shasum -a 256 ather/*.apk nothingx/*.apk > SHA256SUMS)
```

Refresh `vendor/SHA256SUMS` whenever you upload a new vendor release.
When the file exists, it must list every APK that is built; the workflow fails on a
missing entry and on a checksum mismatch.

### Certificate pins

`vendor-certs.json` pins the signing certificate per package, and both packages are
pinned.
The workflow prints the certificate it sees and fails the run when a pin does not
match.
For a new app, read the values from your own vendor APK and add them:

```bash
apksigner verify --print-certs vendor/nothingx/com.nothing.smartcenter.apk | grep 'certificate SHA-'
```

## Run a build

```bash
gh workflow run build.yml -R pixincreate/morpheus-apps
gh run list --workflow build.yml -R pixincreate/morpheus-apps
```

The weekly schedule runs on Mondays at 02:00 UTC.

## Install a build on the phone

```bash
gh release download ather-13.5.1 -R pixincreate/morpheus-apps -D builds --clobber
adb install builds/morpheus-ather-13.5.1.apk
```

For Nothing X, use the tag `nothingx-3.8.0` and its asset.

## Web fallback for vendor APKs

`scripts/fetch-vendor-apks.mjs` downloads both apps from the APKPure direct
endpoints for the versions the patch bundle targets:

```text
https://d.apkpure.com/b/XAPK/<package>?versionCode=<code>&nc=<abi>&sv=<sdk>
```

Positional arguments override the defaults table:

```bash
node scripts/fetch-vendor-apks.mjs ather 13.5.1 324 arm64-v8a 32
node scripts/fetch-vendor-apks.mjs nothingx 3.8.0 3080004 arm64-v8a 32
node scripts/fetch-vendor-apks.mjs all
```

The script drives a headed browser with
[patchright](https://github.com/Kaliiiiiiiiii-Vinyzu/patchright), a Playwright
fork that hides the automation surface at the protocol level.
Install it once:

```bash
npm install --no-save patchright@1.63.0
npx patchright install chromium
```

APKPure serves the endpoints through Cloudflare.
Headless Chromium never gets the file: the request loops through the challenge
and no download fires.
A headed browser gets the 302 straight to `data.winudf.com`, so the script
always launches headed and follows the published mitigations:

- a persistent browser profile with a fixed locale (`en-IN`) and timezone
  (`Asia/Kolkata`)
- `--disable-blink-features=AutomationControlled`
- no user agent or header spoofing, because the
  [Cloudflare Playwright guide](https://developers.cloudflare.com/browser-run/playwright/)
  says a custom user agent does not bypass bot protection.

A headed browser needs a display.
On a machine with a desktop session, run the script directly.
On CI, run it under a virtual display:

```bash
xvfb-run -a node scripts/fetch-vendor-apks.mjs ather
```

The script prefers the installed Google Chrome, which patchright recommends and
the GitHub runner images ship and test, and falls back to the Chromium build
that `npx patchright install chromium` downloads.
Set `PATCHRIGHT_CHANNEL` to force a channel.

The fallback is best-effort and occasional.
Cloudflare and APKPure can change the challenge at any time, and CI runs from
shared cloud IPs that score worse than a home connection, so expect this path to
fail sometimes.
The private vendor release above stays the reliable path.
A download that gets through is not trusted on its own: `vendor/SHA256SUMS` and
`vendor-certs.json` decide whether it is the right file.

## Files

| Path | Purpose |
| --- | --- |
| `.github/workflows/build.yml` | The build, verify, merge, sign, and release workflow |
| `scripts/build.sh` | Apply the patch bundle, then merge the base APK with the config splits |
| `scripts/sign-all.sh` | Align and sign the merged APK |
| `scripts/verify-vendor-apks.sh` | Check checksums and certificate pins |
| `scripts/report-failure.sh` | File a failed run as an issue in the repository that needs the fix |
| `scripts/fetch-vendor-apks.mjs` | Best-effort web fallback for the vendor APKs (patchright, headed) |
| `vendor/SHA256SUMS` | SHA-256 of the vendor APKs, relative to `vendor/` |
| `vendor-certs.json` | Signing-certificate pins per package |
