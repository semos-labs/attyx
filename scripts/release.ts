#!/usr/bin/env bun
/**
 * Release script for Attyx
 *
 * Usage:
 *   bun release                # Bump patch version (0.1.6 → 0.1.7)
 *   bun release --minor        # Bump minor version (0.1.6 → 0.2.0)
 *   bun release --major        # Bump major version (0.1.6 → 1.0.0)
 *   bun release --rc           # Bump patch + RC    (0.1.6 → 0.1.7-rc1)
 *   bun release --minor --rc   # Bump minor + RC    (0.1.6 → 0.2.0-rc1)
 *   bun release --major --rc   # Bump major + RC    (0.1.6 → 1.0.0-rc1)
 *
 * RC rules:
 *   - First --rc after a stable release bumps the version and appends -rc1
 *   - Subsequent --rc bumps the RC number (rc1 → rc2 → rc3 ...)
 *   - Running without --rc after an RC finalises the version (removes -rcN)
 */

import { $ } from "bun";

// ── Colors ──────────────────────────────────────────────────────────────────

const bold = (s: string) => `\x1b[1m${s}\x1b[22m`;
const dim = (s: string) => `\x1b[2m${s}\x1b[22m`;
const cyan = (s: string) => `\x1b[36m${s}\x1b[39m`;
const green = (s: string) => `\x1b[32m${s}\x1b[39m`;
const red = (s: string) => `\x1b[31m${s}\x1b[39m`;
const yellow = (s: string) => `\x1b[33m${s}\x1b[39m`;

// ── Helpers ─────────────────────────────────────────────────────────────────

$.throws(false); // we handle errors ourselves

function ok(msg: string) { console.log(`  ${green("✓")} ${msg}`); }
function fail(msg: string) { console.error(`  ${red("✗")} ${msg}`); }
function warn(msg: string) { console.log(`  ${yellow("⚠")} ${msg}`); }

interface ParsedVersion {
  major: number;
  minor: number;
  patch: number;
  rc: number | null; // null = stable, 1+ = rc number
}

function parseVersion(tag: string): ParsedVersion | null {
  const m = tag.match(/^v?(\d+)\.(\d+)\.(\d+)(?:-rc(\d+))?$/);
  if (!m) return null;
  return {
    major: Number(m[1]),
    minor: Number(m[2]),
    patch: Number(m[3]),
    rc: m[4] != null ? Number(m[4]) : null,
  };
}

function formatVersion(v: ParsedVersion): string {
  const base = `${v.major}.${v.minor}.${v.patch}`;
  return v.rc != null ? `${base}-rc${v.rc}` : base;
}

function formatTag(v: ParsedVersion): string {
  return `v${formatVersion(v)}`;
}

// ── Main ────────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);

if (args.includes("-h") || args.includes("--help")) {
  console.log();
  console.log(`  ${bold("release")} ${dim("— tag & publish a new Attyx version")}`);
  console.log();
  console.log(`  ${bold("Usage:")}`);
  console.log(`    ${cyan("bun release")}                ${dim("patch bump  (0.1.6 → 0.1.7)")}`);
  console.log(`    ${cyan("bun release --minor")}        ${dim("minor bump  (0.1.6 → 0.2.0)")}`);
  console.log(`    ${cyan("bun release --major")}        ${dim("major bump  (0.1.6 → 1.0.0)")}`);
  console.log(`    ${cyan("bun release --rc")}           ${dim("patch RC    (0.1.6 → 0.1.7-rc1)")}`);
  console.log(`    ${cyan("bun release --minor --rc")}   ${dim("minor RC    (0.1.6 → 0.2.0-rc1)")}`);
  console.log(`    ${cyan("bun release --major --rc")}   ${dim("major RC    (0.1.6 → 1.0.0-rc1)")}`);
  console.log();
  console.log(`  ${bold("RC rules:")}`);
  console.log(`    ${dim("First --rc after a stable release bumps version + appends -rc1")}`);
  console.log(`    ${dim("Subsequent --rc bumps the RC number (rc1 → rc2 → rc3 …)")}`);
  console.log(`    ${dim("Without --rc after an RC → finalises the version (drops -rcN)")}`);
  console.log();
  process.exit(0);
}

const bumpType = args.includes("--major") ? "major"
  : args.includes("--minor") ? "minor"
  : "patch";

const isRC = args.includes("--rc");

async function main() {
  console.log();

  // 1. Clean work tree
  const status = await $`git status --porcelain`.text();
  if (status.trim() !== "") {
    fail("Work tree is not clean — commit or stash first");
    console.log(dim(status.trimEnd().split("\n").map(l => `      ${l}`).join("\n")));
    console.log();
    process.exit(1);
  }

  // 2a. Switch to main and pull latest
  await $`git checkout main`.quiet();
  ok("Checked out main");

  const pull = await $`git pull origin main`.quiet();
  if (pull.exitCode !== 0) {
    fail("Could not pull latest main");
    console.log();
    process.exit(1);
  }
  ok("Pulled latest main");

  // 2. Resolve current version from latest tag (including RC tags)
  let latestTag: string;
  try {
    latestTag = (await $`git describe --tags --abbrev=0 --match "v*"`.text()).trim();
  } catch {
    latestTag = "v0.0.0";
  }

  const current = parseVersion(latestTag);
  if (!current) {
    fail(`Invalid tag format: ${bold(latestTag)}`);
    console.log();
    process.exit(1);
  }

  // 3. Compute next version
  const next: ParsedVersion = { ...current };

  if (isRC) {
    if (current.rc != null) {
      next.rc = current.rc + 1;
    } else {
      switch (bumpType) {
        case "major": next.major++; next.minor = 0; next.patch = 0; break;
        case "minor": next.minor++; next.patch = 0; break;
        case "patch": next.patch++; break;
      }
      next.rc = 1;
    }
  } else {
    if (current.rc != null) {
      next.rc = null;
    } else {
      switch (bumpType) {
        case "major": next.major++; next.minor = 0; next.patch = 0; break;
        case "minor": next.minor++; next.patch = 0; break;
        case "patch": next.patch++; break;
      }
    }
  }

  const version = formatVersion(next);
  const tag = formatTag(next);
  const label = isRC ? "release candidate" : bumpType;

  console.log(`  ${bold(latestTag)} ${dim("→")} ${bold(cyan(tag))} ${dim(`(${label})`)}`);
  console.log();

  // 3b. Create release branch
  const branch = `release-${version}`;
  await $`git checkout -b ${branch}`.quiet();
  ok(`Created branch ${bold(branch)}`);

  // 4. Update build.zig.zon version
  const zonPath = "./build.zig.zon";
  const zonContent = await Bun.file(zonPath).text();
  const updatedZon = zonContent.replace(
    /\.version\s*=\s*"[^"]*"/,
    `.version = "${version}"`,
  );

  if (updatedZon === zonContent) {
    warn("Could not find .version in build.zig.zon — skipping update");
  } else {
    await Bun.write(zonPath, updatedZon);
    ok("Updated build.zig.zon version");
  }

  // 4b. Update Info.plist version (CFBundleVersion + CFBundleShortVersionString)
  const plistPath = "./resources/Info.plist";
  const plistContent = await Bun.file(plistPath).text();
  // Strip any -rcN suffix for CFBundleVersion — macOS requires X.Y.Z format
  const bundleVersion = `${next.major}.${next.minor}.${next.patch}`;
  const updatedPlist = plistContent
    .replace(
      /(<key>CFBundleVersion<\/key>\s*<string>)[^<]*(<\/string>)/,
      `$1${bundleVersion}$2`,
    )
    .replace(
      /(<key>CFBundleShortVersionString<\/key>\s*<string>)[^<]*(<\/string>)/,
      `$1${bundleVersion}$2`,
    );

  if (updatedPlist === plistContent) {
    warn("Could not find version keys in Info.plist — skipping update");
  } else {
    await Bun.write(plistPath, updatedPlist);
    ok("Updated Info.plist version");
  }

  // 5. Commit version bump
  await $`git add ${zonPath} ${plistPath}`;
  const diff = await $`git diff --cached --name-only`.text();
  if (diff.trim()) {
    await $`git commit -m ${"chore: bump version to " + tag}`.quiet();
    ok("Committed version bump");
  } else {
    ok("Version already up to date");
  }

  // 6. Tag
  await $`git tag -a ${tag} -m ${"Release " + tag}`;
  ok(`Tagged ${bold(tag)}`);

  // 7. Push release branch and tag
  await $`git push -u origin ${branch}`.quiet();
  await $`git push origin ${tag}`.quiet();
  ok("Pushed to origin");

  // 8. GitHub release (draft — CI will publish once all assets are ready)
  const notesPath = `./releases/${tag}.md`;
  const notesFile = Bun.file(notesPath);
  const hasNotes = await notesFile.exists();
  const ghFlags: string[] = ["--draft"];
  if (isRC) ghFlags.push("--prerelease");

  if (hasNotes) {
    ghFlags.push("--notes-file", notesPath);
    ok(`Using release notes from ${bold(notesPath)}`);
  } else {
    ghFlags.push("--generate-notes");
    warn(`No release notes found at ${notesPath} — using auto-generated notes`);
  }

  const gh = await $`gh release create ${tag} --title ${tag} ${ghFlags}`.quiet();
  if (gh.exitCode === 0) {
    ok(`Created draft GitHub release${isRC ? " (prerelease)" : ""}`);
  } else {
    const flagStr = ghFlags.join(" ");
    const cmd = `gh release create ${tag} --title ${tag} ${flagStr}`;
    warn(`Could not create GitHub release — run manually:`);
    console.log(`      ${cyan(cmd)}`);
  }

  // 9. Switch back to main
  await $`git checkout main`.quiet();
  ok("Checked out main");

  console.log();
  console.log(`  ${dim("View:")} ${cyan(`https://github.com/semos-labs/attyx/releases/tag/${tag}`)}`);
  console.log();
}

main().catch((err) => {
  console.log();
  fail(err.message);
  console.log();
  process.exit(1);
});
