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

  // 5. Commit version bump
  await $`git add ${zonPath}`;
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

  // 7. Push
  await $`git push origin main`.quiet();
  await $`git push origin ${tag}`.quiet();
  ok("Pushed to origin");

  // 8. GitHub release (prerelease for RCs, published for stable)
  const ghArgs = isRC
    ? $`gh release create ${tag} --generate-notes --title ${tag} --prerelease`
    : $`gh release create ${tag} --generate-notes --title ${tag}`;

  const gh = await ghArgs.quiet();
  if (gh.exitCode === 0) {
    ok(`Created GitHub release${isRC ? " (prerelease)" : ""}`);
  } else {
    const cmd = isRC
      ? `gh release create ${tag} --generate-notes --title ${tag} --prerelease`
      : `gh release create ${tag} --generate-notes --title ${tag}`;
    warn(`Could not create GitHub release — run manually:`);
    console.log(`      ${cyan(cmd)}`);
  }

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
