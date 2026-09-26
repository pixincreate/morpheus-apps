# morpheus-apps

Private build repository for [pixincreate/morpheus](https://github.com/pixincreate/morpheus).
It takes the newest public patch bundle, applies it to untouched vendor APKs, signs
the result, and publishes everything as one rolling private release tagged `all`.

This repository must stay private.
It carries the signing key in an encrypted secret and the untouched vendor APKs as
private release assets.
Anyone who can read the rolling release can install patched builds that carry your
signing key, so do not make the repository public and do not forward release assets.

## How a build runs

The workflow [`.github/workflows/build.yml`](.github/workflows/build.yml) runs nightly
and on demand.
For each app it does this:

1. Downloads the untouched vendor APKs from the private `vendor/<app>/<version>`
   release in this repository.
   `scripts/fetch-vendor-apks.sh` is the web fallback for APKPure and APKMirror.
2. Verifies the APKs with `scripts/verify-vendor-apks.sh`:
   SHA-256 against the committed `vendor/SHA256SUMS` when present, and the signing
   certificate against the pins in `vendor-certs.json`.
3. Downloads the newest patch bundle from the public repository with
   `gh release download --repo pixincreate/morpheus --pattern 'patches-*.mpp'`.
4. Applies the bundle to each base APK with `scripts/build.sh` and the Morphe CLI
   (`--unsigned --disable-purge`).
5. Signs the patched base APK and every original config split with one key through
   `scripts/sign-all.sh`.
   The workflow decodes `KEYSTORE_BASE64` to a temporary file with mode 600 and
   deletes it in an `always()` step.
6. Publishes every signed APK to the rolling release tagged `all` with
   `ncipollo/release-action` and `allowUpdates: true`.
   Asset names are deterministic, for example `ather-base.apk`,
   `ather-config.arm64_v8a.apk`, and `nothingx-base.apk`.

The build matrix uses `fail-fast: false`, so one app failing does not lose the other
app's signed APKs.

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

## Upload the vendor APKs

Create one private release per app and version, then attach the untouched APKs.
The workflow downloads them with:

```bash
gh release download vendor/ather/13.5.0 -p '*.apk' -D vendor/ather/
```

Name the base APK after its package and keep the original split names:

- `com.athermobileapp.apk`, then `config.arm64_v8a.apk`, `config.en.apk`,
  `config.mdpi.apk` (or the `split_config.*.apk` names that `adb` returns).
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
gh release create vendor/ather/13.5.0 -R pixincreate/morpheus-apps \
  --title "Ather 13.5.0 vendor APKs" \
  --notes "Untouched Ather 13.5.0 base APK and config splits." \
  --latest=false \
  vendor/ather/com.athermobileapp.apk \
  vendor/ather/config.arm64_v8a.apk \
  vendor/ather/config.en.apk \
  vendor/ather/config.mdpi.apk
```

Use the same shape for Nothing X with tag `vendor/nothingx/3.8.0`.
For an APKMirror `.apkm` bundle, `unzip` it first and rename `base.apk` to the
package name.
For an APKPure `.xapk`, `unzip` it and keep the APK files it contains.

### Checksums

Commit the checksums so the workflow can verify the vendor release:

```bash
(cd vendor && shasum -a 256 ather/*.apk > SHA256SUMS)
```

Refresh `vendor/SHA256SUMS` whenever you upload a new vendor release.
The workflow skips the checksum gate when the file is not present.

### Certificate pins

`vendor-certs.json` pins the signing certificate per package.
The workflow prints the certificate it sees and skips the check for a package with
an empty pin.
Ather is pinned.
Nothing X is empty until you read the value from your own vendor APK:

```bash
apksigner verify --print-certs vendor/nothingx/com.nothing.smartcenter.apk | grep 'certificate SHA-'
```

Put both values in `vendor-certs.json` under `com.nothing.smartcenter`, then delete
the comment that explains the empty pin.

## Run a build

```bash
gh workflow run build.yml -R pixincreate/morpheus-apps
gh run list --workflow build.yml -R pixincreate/morpheus-apps
```

The nightly schedule runs at 02:00 UTC.

## Install a build on the phone

```bash
gh release download all -R pixincreate/morpheus-apps -D builds --clobber
adb install-multiple builds/ather-*.apk
```

For Nothing X pass every asset:

```bash
adb install-multiple builds/nothingx-*.apk
```

## Web fallback for vendor APKs

`scripts/fetch-vendor-apks.sh` downloads Ather from APKPure and Nothing X from
APKMirror for the versions the patch bundle targets.
Both sites sit behind Cloudflare and answer plain curl with a challenge page, so the
script gives up with a clear message rather than pretending to work.
The reliable path is always the private vendor release above.
A download that gets through is not trusted on its own: `vendor/SHA256SUMS` and
`vendor-certs.json` decide whether it is the right file.

## Files

| Path | Purpose |
| --- | --- |
| `.github/workflows/build.yml` | The build, verify, sign, and rolling-release workflow |
| `scripts/build.sh` | Apply the patch bundle to one base APK with the Morphe CLI |
| `scripts/sign-all.sh` | Align and sign the patched base plus every config split |
| `scripts/verify-vendor-apks.sh` | Check checksums and certificate pins |
| `scripts/fetch-vendor-apks.sh` | Best-effort web fallback for the vendor APKs |
| `vendor/SHA256SUMS` | SHA-256 of the vendor APKs, relative to `vendor/` |
| `vendor-certs.json` | Signing-certificate pins per package |
