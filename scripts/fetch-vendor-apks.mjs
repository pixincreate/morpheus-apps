#!/usr/bin/env node
// Fetch the untouched vendor APKs from the APKPure direct download endpoints
// with patchright, a Playwright fork that patches the automation surface at the
// protocol level.
//
// The reliable source is the private vendor release in this repository:
//   gh release download vendor/<app>/<version> -p '*.apk' -D vendor/<app>/
// Use this script only when that release does not exist yet. The workflow tries
// the release first and falls back to this script.
//
// APKPure serves the direct endpoints through Cloudflare. Headless Chromium
// fails there: the request loops through redirects and challenges and no
// download fires. A headed browser gets the 302 straight to data.winudf.com,
// so this script always launches headed. On CI run it under a virtual display:
//   xvfb-run -a node scripts/fetch-vendor-apks.mjs <app>
//
// The launch follows the published guidance for challenged browser fetches:
//   - headed mode, because headless is fingerprinted (BrowserStack,
//     https://www.browserstack.com/guide/playwright-captcha)
//   - a persistent profile and a stable locale and timezone, so runs do not
//     look like fresh automation every time (Cloudflare Browser Run,
//     https://developers.cloudflare.com/browser-run/playwright/)
//   - --disable-blink-features=AutomationControlled and patchright's patched
//     CDP surface. No header or user agent spoofing: Cloudflare's own docs say
//     a user agent override does not bypass bot protection, and the Stack
//     Overflow report of a challenge loop shows the headless tell in
//     sec-ch-ua ("HeadlessChrome"), not in the user agent.
//   - the installed Google Chrome when there is one, because patchright
//     recommends Chrome over Chromium and the GitHub runner images ship and
//     test Chrome. Without Chrome the script falls back to the Chromium build
//     that `npx patchright install chromium` downloads, which is the build
//     that was proven locally.
//
// A download that gets through is not trusted on its own:
// scripts/verify-vendor-apks.sh checks the SHA-256 entries in vendor/SHA256SUMS
// and the certificate pins in vendor-certs.json, and a tampered file fails
// there.
//
// Usage:
//   node scripts/fetch-vendor-apks.mjs ather [version [versionCode [abi [sdk]]]]
//   node scripts/fetch-vendor-apks.mjs nothingx [version [versionCode [abi [sdk]]]]
//   node scripts/fetch-vendor-apks.mjs all
//
// Defaults:
//   app        package                    version  versionCode  abi          sdk
//   ather      com.athermobileapp          13.5.0   321          arm64-v8a    32
//   nothingx   com.nothing.smartcenter     3.8.0    3080004      arm64-v8a    32
//
// Environment:
//   PATCHRIGHT_CHANNEL  force a browser channel for patchright, for example
//                       "chrome". By default the script uses Chrome when it is
//                       installed and the patchright Chromium build otherwise.

import { execFileSync } from "node:child_process";
import {
  closeSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readdirSync,
  readFileSync,
  readSync,
  renameSync,
  rmSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "patchright";

const ROOT = fileURLToPath(new URL("..", import.meta.url));

const APPS = {
  ather: {
    package: "com.athermobileapp",
    version: "13.5.0",
    versionCode: "321",
    abi: "arm64-v8a",
    sdk: "32",
  },
  nothingx: {
    package: "com.nothing.smartcenter",
    version: "3.8.0",
    versionCode: "3080004",
    abi: "arm64-v8a",
    sdk: "32",
  },
};

function fail(message) {
  console.error(`fetch-vendor-apks: ${message}`);
  process.exit(1);
}

function appDefaults(name) {
  const app = APPS[name];
  if (!app) {
    fail(`unknown app '${name}' - expected ather, nothingx or all.`);
  }
  return app;
}

function endpointUrl(app) {
  return `https://d.apkpure.com/b/XAPK/${app.package}?versionCode=${app.versionCode}&nc=${app.abi}&sv=${app.sdk}`;
}

// Chrome when it is installed, so patchright drives a real Chrome build on the
// GitHub runner; the patchright Chromium build otherwise.
function browserChannel() {
  if (process.env.PATCHRIGHT_CHANNEL) {
    return process.env.PATCHRIGHT_CHANNEL;
  }
  if (existsSync("/Applications/Google Chrome.app")) {
    return "chrome";
  }
  for (const binary of ["google-chrome", "google-chrome-stable"]) {
    try {
      execFileSync("which", [binary], { stdio: "ignore" });
      return "chrome";
    } catch {
      // Not installed; try the next name.
    }
  }
  return undefined;
}

// Launch a headed, persistent browser context and wait for the download the
// endpoint triggers. Headed is required: headless gets the challenge loop.
async function downloadXapk(url, out) {
  const profile = mkdtempSync(join(tmpdir(), "fetch-vendor-apks-"));
  const options = {
    headless: false,
    viewport: null,
    locale: "en-IN",
    timezoneId: "Asia/Kolkata",
    args: ["--disable-blink-features=AutomationControlled"], // keywatch:ignore
  };
  const channel = browserChannel();
  if (channel) {
    options.channel = channel;
  }
  console.log(
    `launching patchright with ${channel ? `the ${channel} channel` : "the bundled Chromium"}`,
  );
  console.log(`downloading ${url}`);
  const context = await chromium.launchPersistentContext(profile, options);
  try {
    const page = context.pages()[0] ?? (await context.newPage());
    const [download] = await Promise.all([
      page.waitForEvent("download", { timeout: 120000 }),
      page.goto(url).catch(() => {}),
    ]);
    const failure = await download.failure();
    if (failure) {
      throw new Error(`the download failed: ${failure}`);
    }
    await download.saveAs(out);
  } finally {
    await context.close().catch(() => {});
    rmSync(profile, { recursive: true, force: true });
  }
}

function assertZipMagic(file) {
  const fd = openSync(file, "r");
  const magic = Buffer.alloc(2);
  try {
    readSync(fd, magic, 0, 2, 0);
  } finally {
    closeSync(fd);
  }
  if (magic.toString("latin1") !== "PK") {
    throw new Error(
      `${file} does not start with the zip magic PK, so the download is not an XAPK.`,
    );
  }
}

function findApks(dir) {
  const found = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      found.push(...findApks(path));
    } else if (entry.name.endsWith(".apk")) {
      found.push(path);
    }
  }
  return found;
}

// Name of the base APK inside the archive. APKPure usually names it after the
// package, but the manifest decides: the split_apks entry with id "base" is the
// base, otherwise it is the APK that the manifest does not list as a split.
function baseApkName(staging) {
  const manifest = join(staging, "manifest.json");
  if (existsSync(manifest)) {
    let data = {};
    try {
      data = JSON.parse(readFileSync(manifest, "utf8"));
    } catch {
      data = {};
    }
    const entries = Array.isArray(data.split_apks) ? data.split_apks : [];
    const declared = entries.find((entry) => entry?.id === "base" && entry.file);
    if (declared) {
      return basename(declared.file);
    }
    const listed = new Set(entries.map((entry) => entry?.file).filter(Boolean));
    const unlisted = findApks(staging).filter(
      (path) => !listed.has(basename(path)),
    );
    if (unlisted.length === 1) {
      return basename(unlisted[0]);
    }
  }
  return "base.apk";
}

// Extract every *.apk from an XAPK archive and rename the base APK to
// <package>.apk when the archive names it differently. Config splits keep their
// archive names, because the workflow installs and signs them by those names.
function extractApks(archive, dir, app) {
  assertZipMagic(archive);
  const staging = mkdtempSync(join(tmpdir(), "fetch-vendor-apks-"));
  try {
    execFileSync("unzip", ["-o", archive, "-d", staging], {
      stdio: "inherit",
    });
    const apks = findApks(staging);
    if (apks.length === 0) {
      throw new Error(`${archive} contains no APK files.`);
    }
    mkdirSync(dir, { recursive: true });
    for (const name of readdirSync(dir)) {
      if (name.endsWith(".apk")) {
        rmSync(join(dir, name));
      }
    }
    for (const file of apks) {
      copyFileSync(file, join(dir, basename(file)));
    }
    const wanted = `${app.package}.apk`;
    if (!existsSync(join(dir, wanted))) {
      const candidate = baseApkName(staging);
      if (!existsSync(join(dir, candidate))) {
        throw new Error(
          `cannot find the base APK in ${archive}: neither ${wanted} nor ${candidate} is present. The archive holds: ${apks.map((path) => basename(path)).join(", ")}.`,
        );
      }
      renameSync(join(dir, candidate), join(dir, wanted));
      console.log(`renamed ${candidate} to ${wanted}`);
    }
    const count = readdirSync(dir).filter((name) => name.endsWith(".apk"));
    console.log(`extracted ${count.length} APK(s) into vendor/${app.name}/`);
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
}

async function fetchApp(name, overrides = {}) {
  const app = { ...appDefaults(name), name, ...overrides };
  const work = mkdtempSync(join(tmpdir(), "fetch-vendor-apks-"));
  const archive = join(work, `${name}.xapk`);
  try {
    console.log(
      `fetching ${name} ${app.version} (versionCode ${app.versionCode}, ${app.abi}, sdk ${app.sdk})`,
    );
    await downloadXapk(endpointUrl(app), archive);
    console.log(`downloaded ${statSync(archive).size} bytes`);
    extractApks(archive, join(ROOT, "vendor", name), app);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

async function main() {
  const name = process.argv[2];
  if (name === "all") {
    if (process.argv.length > 3) {
      fail(
        "'all' takes no arguments - call the app by name to override version, versionCode, abi or sdk.",
      );
    }
    await fetchApp("ather");
    await fetchApp("nothingx");
    return;
  }
  if (name === "ather" || name === "nothingx") {
    const app = appDefaults(name);
    await fetchApp(name, {
      version: process.argv[3] ?? app.version,
      versionCode: process.argv[4] ?? app.versionCode,
      abi: process.argv[5] ?? app.abi,
      sdk: process.argv[6] ?? app.sdk,
    });
    console.log();
    console.log("Now verify before building:");
    console.log(
      `  APP=${name} APP_PACKAGE=${app.package} bash scripts/verify-vendor-apks.sh`,
    );
    return;
  }
  fail(
    "usage: node scripts/fetch-vendor-apks.mjs ather|nothingx|all [version [versionCode [abi [sdk]]]]",
  );
}

main().catch((error) => fail(error.message));
