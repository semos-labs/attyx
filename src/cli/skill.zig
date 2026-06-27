//! `attyx skill install` / `uninstall` — install the Attyx agent skill into the
//! coding agents set up on this machine: Claude Code, Codex, opencode, and Pi.
//! Installs are always global (user-level).
//!
//! Interactive on a TTY: it lists the agents detected on this machine and lets
//! you pick which to target, installing all chosen in one go. Flag-driven
//! otherwise (and when stdin isn't a TTY) so scripts and the silent on-launch
//! refresh keep working.
//!
//! All four use the cross-agent "Agent Skills" `SKILL.md` format except opencode,
//! which takes a custom command (`commands/<name>.md`); the instruction body is
//! shared, only the frontmatter/location differ. See the install matrix below.
const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const skill_content_raw = @import("skill_data").content;
const is_dev = builtin.mode == .Debug;
const skill_name = if (is_dev) "attyx-dev" else "attyx";

/// In dev builds, register as `attyx-dev` so it never clobbers a real install.
const skill_content = if (is_dev) replaceSkillName() else skill_content_raw;
fn replaceSkillName() []const u8 {
    @setEvalBranchQuota(skill_content_raw.len * 2);
    const needle = "name: attyx\n";
    const replacement = "name: attyx-dev\n";
    const idx = std.mem.indexOf(u8, skill_content_raw, needle) orelse return skill_content_raw;
    return skill_content_raw[0..idx] ++ replacement ++ skill_content_raw[idx + needle.len ..];
}

/// opencode commands take their name from the filename and only read a
/// `description` frontmatter key, so rebuild the doc with just that — reusing the
/// shared instruction body verbatim.
const command_content = buildCommandContent();
fn buildCommandContent() []const u8 {
    @setEvalBranchQuota(skill_content_raw.len * 4);
    const src = skill_content;
    if (!std.mem.startsWith(u8, src, "---\n")) return src; // no frontmatter — use as-is
    const fm_end = std.mem.indexOf(u8, src[4..], "\n---\n") orelse return src;
    const fm = src[4 .. 4 + fm_end];
    const body = src[4 + fm_end + 5 ..]; // skip the closing "\n---\n"
    const desc = blk: {
        const key = "description: ";
        const di = std.mem.indexOf(u8, fm, key) orelse break :blk "Control the Attyx terminal via IPC.";
        const rest = fm[di + key.len ..];
        const eol = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        break :blk rest[0..eol];
    };
    return "---\ndescription: " ++ desc ++ "\n---\n\n" ++ body;
}

const Fmt = enum { skill, command };

const Harness = struct {
    key: []const u8, // --agents token
    name: []const u8, // display name
    detect: []const u8, // dir under $HOME that means the agent is set up
    prefix: []const u8, // dir under $HOME holding the skill dir / command file
    fmt: Fmt,
};

// Install matrix (verified against each agent's docs), all user-level:
//   Claude Code  skill    ~/.claude/skills/<n>/SKILL.md
//   Codex        skill    ~/.agents/skills/<n>/SKILL.md
//   opencode     command  ~/.config/opencode/commands/<n>.md
//   Pi           skill    ~/.pi/agent/skills/<n>/SKILL.md
const harnesses = [_]Harness{
    .{ .key = "claude", .name = "Claude Code", .detect = ".claude", .prefix = ".claude/skills", .fmt = .skill },
    .{ .key = "codex", .name = "Codex", .detect = ".codex", .prefix = ".agents/skills", .fmt = .skill },
    .{ .key = "opencode", .name = "opencode", .detect = ".config/opencode", .prefix = ".config/opencode/commands", .fmt = .command },
    .{ .key = "pi", .name = "Pi", .detect = ".pi", .prefix = ".pi/agent/skills", .fmt = .skill },
};

fn getHomeDir() ?[]const u8 {
    if (comptime is_windows) {
        const S = struct {
            var buf: [512]u8 = undefined;
        };
        const val = std.process.getEnvVarOwned(std.heap.page_allocator, "USERPROFILE") catch return null;
        defer std.heap.page_allocator.free(val);
        if (val.len >= S.buf.len) return null;
        @memcpy(S.buf[0..val.len], val);
        return S.buf[0..val.len];
    } else {
        return std.posix.getenv("HOME");
    }
}

const Paths = struct {
    dir_buf: [1024]u8 = undefined,
    file_buf: [1024]u8 = undefined,
    dir: []const u8 = "",
    file: []const u8 = "",
};

/// Build the (absolute, user-level) install dir + file for a harness. Returns
/// false on overflow.
fn buildPaths(h: Harness, home: []const u8, p: *Paths) bool {
    switch (h.fmt) {
        .skill => {
            p.dir = std.fmt.bufPrint(&p.dir_buf, "{s}/{s}/{s}", .{ home, h.prefix, skill_name }) catch return false;
            p.file = std.fmt.bufPrint(&p.file_buf, "{s}/SKILL.md", .{p.dir}) catch return false;
        },
        .command => {
            p.dir = std.fmt.bufPrint(&p.dir_buf, "{s}/{s}", .{ home, h.prefix }) catch return false;
            p.file = std.fmt.bufPrint(&p.file_buf, "{s}/{s}.md", .{ p.dir, skill_name }) catch return false;
        },
    }
    return true;
}

fn contentFor(h: Harness) []const u8 {
    return switch (h.fmt) {
        .skill => skill_content,
        .command => command_content,
    };
}

/// True if the agent appears set up on this machine ($HOME/<detect> exists).
fn isAgentPresent(home: []const u8, h: Harness) bool {
    var buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ home, h.detect }) catch return false;
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

/// True if the skill is already installed for a harness.
fn isInstalled(h: Harness, home: []const u8) bool {
    var p = Paths{};
    if (!buildPaths(h, home, &p)) return false;
    std.fs.cwd().access(p.file, .{}) catch return false;
    return true;
}

// ── Install / uninstall a single harness ──

fn installOne(stdout: std.fs.File, h: Harness, home: []const u8) void {
    var p = Paths{};
    var line: [1152]u8 = undefined;
    if (!buildPaths(h, home, &p)) {
        write(stdout, std.fmt.bufPrint(&line, "  ✗ {s}: path too long\n", .{h.name}) catch return);
        return;
    }
    std.fs.cwd().makePath(p.dir) catch |e| {
        write(stdout, std.fmt.bufPrint(&line, "  ✗ {s}: {s}\n", .{ h.name, @errorName(e) }) catch return);
        return;
    };
    const f = std.fs.cwd().createFile(p.file, .{}) catch |e| {
        write(stdout, std.fmt.bufPrint(&line, "  ✗ {s}: {s}\n", .{ h.name, @errorName(e) }) catch return);
        return;
    };
    defer f.close();
    f.writeAll(contentFor(h)) catch |e| {
        write(stdout, std.fmt.bufPrint(&line, "  ✗ {s}: {s}\n", .{ h.name, @errorName(e) }) catch return);
        return;
    };
    write(stdout, std.fmt.bufPrint(&line, "  ✓ {s} → {s}\n", .{ h.name, p.file }) catch return);
}

fn uninstallOne(stdout: std.fs.File, h: Harness, home: []const u8) void {
    var p = Paths{};
    var line: [1152]u8 = undefined;
    if (!buildPaths(h, home, &p)) return;
    // Skill: remove the whole <name>/ dir; command: remove the single file.
    const target = if (h.fmt == .skill) p.dir else p.file;
    std.fs.cwd().deleteTree(target) catch |e| {
        if (e == error.FileNotFound) return;
        write(stdout, std.fmt.bufPrint(&line, "  ✗ {s}: {s}\n", .{ h.name, @errorName(e) }) catch return);
        return;
    };
    write(stdout, std.fmt.bufPrint(&line, "  ✓ removed from {s}\n", .{h.name}) catch return);
}

// ── Entry point ──

pub fn doSkill(args: []const [:0]const u8) void {
    const stdout = std.fs.File.stdout();
    const sub = if (args.len > 2) args[2] else "";
    if (std.mem.eql(u8, sub, "install")) {
        run(stdout, args[2..], .install);
    } else if (std.mem.eql(u8, sub, "uninstall")) {
        run(stdout, args[2..], .uninstall);
    } else {
        write(stdout, skill_help);
    }
}

const Mode = enum { install, uninstall };

fn run(stdout: std.fs.File, args: []const [:0]const u8, mode: Mode) void {
    const home = getHomeDir() orelse {
        write(stdout, "error: HOME not set\n");
        return;
    };

    // Parse flags (args[0] is the subcommand itself).
    var all = false;
    var selected = [_]bool{false} ** harnesses.len;
    var any_agent_flag = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--all") or std.mem.eql(u8, a, "-a")) {
            all = true;
            any_agent_flag = true;
        } else if (std.mem.eql(u8, a, "--agents")) {
            i += 1;
            if (i >= args.len) {
                write(stdout, "error: --agents needs a comma-separated list (e.g. claude,codex)\n");
                return;
            }
            if (!parseAgents(stdout, args[i], &selected)) return;
            any_agent_flag = true;
        } else if (std.mem.eql(u8, a, "--global") or std.mem.eql(u8, a, "-g")) {
            // Installs are always global; tolerate the flag as a no-op.
        } else {
            var b: [256]u8 = undefined;
            write(stdout, std.fmt.bufPrint(&b, "error: unknown option '{s}'\n", .{a}) catch "error: unknown option\n");
            write(stdout, skill_help);
            return;
        }
    }

    // Fully interactive only when on a TTY with no agents chosen up front. Any
    // agent flag (or a pipe) means non-interactive, so scripts and the silent
    // refresh stay predictable.
    if (!any_agent_flag) {
        if (std.fs.File.stdin().isTty()) {
            runInteractive(stdout, home, mode);
        } else {
            write(stdout, "error: specify --agents <list> or --all (or run on a terminal for the interactive prompt)\n");
        }
        return;
    }

    // --all means every agent detected on this machine (don't create config for
    // agents the user doesn't have); explicit --agents stays unconditional.
    if (all) for (harnesses, 0..) |h, idx| {
        if (isAgentPresent(home, h)) selected[idx] = true;
    };

    applyToSelected(stdout, home, mode, &selected);
}

fn parseAgents(stdout: std.fs.File, list: []const u8, selected: *[harnesses.len]bool) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const key = std.mem.trim(u8, raw, " \t");
        if (key.len == 0) continue;
        var found = false;
        for (harnesses, 0..) |h, idx| {
            if (std.mem.eql(u8, key, h.key)) {
                selected[idx] = true;
                found = true;
                break;
            }
        }
        if (!found) {
            var b: [256]u8 = undefined;
            write(stdout, std.fmt.bufPrint(&b, "error: unknown agent '{s}' (valid: claude, codex, opencode, pi)\n", .{key}) catch "error: unknown agent\n");
            return false;
        }
    }
    return true;
}

fn applyToSelected(stdout: std.fs.File, home: []const u8, mode: Mode, selected: *const [harnesses.len]bool) void {
    write(stdout, if (mode == .install) "Installing the Attyx skill:\n" else "Removing the Attyx skill:\n");
    var did_any = false;
    for (harnesses, 0..) |h, idx| {
        if (!selected[idx]) continue;
        did_any = true;
        switch (mode) {
            .install => installOne(stdout, h, home),
            .uninstall => uninstallOne(stdout, h, home),
        }
    }
    if (!did_any) {
        write(stdout, "  (no agents selected)\n");
        return;
    }
    if (mode == .install) write(stdout, invoke_hint);
}

// ── Interactive ──

fn runInteractive(stdout: std.fs.File, home: []const u8, mode: Mode) void {
    // For install, offer every agent present on the machine; for uninstall, only
    // those that actually have the skill.
    var offered = [_]bool{false} ** harnesses.len;
    var count: usize = 0;
    for (harnesses, 0..) |h, idx| {
        const show = switch (mode) {
            .install => isAgentPresent(home, h),
            .uninstall => isInstalled(h, home),
        };
        if (show) {
            offered[idx] = true;
            count += 1;
        }
    }
    if (count == 0) {
        write(stdout, if (mode == .install)
            "No supported agents detected (looked for Claude Code, Codex, opencode, Pi).\n"
        else
            "The Attyx skill isn't installed for any agent.\n");
        return;
    }

    write(stdout, if (mode == .install) "Detected agents:\n" else "Installed agents:\n");
    var b: [256]u8 = undefined;
    var n: usize = 0;
    var num_to_idx = [_]usize{0} ** harnesses.len;
    for (harnesses, 0..) |h, idx| {
        if (!offered[idx]) continue;
        n += 1;
        num_to_idx[n - 1] = idx;
        write(stdout, std.fmt.bufPrint(&b, "  {d}) {s}\n", .{ n, h.name }) catch continue);
    }

    write(stdout, "\nWhich? (e.g. 1,3 — or 'a' for all): ");
    var line_buf: [128]u8 = undefined;
    const line = readLine(&line_buf) orelse {
        write(stdout, "Cancelled.\n");
        return;
    };
    if (line.len == 0) {
        write(stdout, "Cancelled.\n");
        return;
    }

    var selected = [_]bool{false} ** harnesses.len;
    if (line[0] == 'a' or line[0] == 'A') {
        for (0..n) |k| selected[num_to_idx[k]] = true;
    } else {
        var it = std.mem.splitScalar(u8, line, ',');
        while (it.next()) |raw| {
            const tok = std.mem.trim(u8, raw, " \t");
            if (tok.len == 0) continue;
            const pick = std.fmt.parseInt(usize, tok, 10) catch {
                write(stdout, "Invalid selection.\n");
                return;
            };
            if (pick < 1 or pick > n) {
                write(stdout, "Selection out of range.\n");
                return;
            }
            selected[num_to_idx[pick - 1]] = true;
        }
    }

    write(stdout, "\n");
    applyToSelected(stdout, home, mode, &selected);
}

fn readLine(buf: []u8) ?[]const u8 {
    const stdin = std.fs.File.stdin();
    var i: usize = 0;
    while (i < buf.len) {
        var c: [1]u8 = undefined;
        const nread = stdin.read(&c) catch return null;
        if (nread == 0) {
            if (i == 0) return null; // EOF with nothing typed
            break;
        }
        if (c[0] == '\n') break;
        buf[i] = c[0];
        i += 1;
    }
    return std.mem.trim(u8, buf[0..i], " \t\r");
}

// ── On-launch refresh ──

/// Silently refresh every installed skill so updates ship with the app. Only
/// rewrites files that already exist — never creates one the user didn't ask
/// for. Called on app launch.
pub fn autoUpdateSkills() void {
    const home = getHomeDir() orelse return;
    for (harnesses) |h| {
        var p = Paths{};
        if (!buildPaths(h, home, &p)) continue;
        std.fs.accessAbsolute(p.file, .{}) catch continue; // only if already installed
        const f = std.fs.cwd().createFile(p.file, .{}) catch continue;
        defer f.close();
        f.writeAll(contentFor(h)) catch {};
    }
}

fn write(f: std.fs.File, bytes: []const u8) void {
    f.writeAll(bytes) catch {};
}

const invoke_hint =
    \\
    \\Invoke it: /attyx in Claude Code & opencode; /skill:attyx in Pi; Codex loads
    \\it on demand by description. Re-run any time to update.
    \\
;

const skill_help =
    \\Install or remove the Attyx skill across your coding agents
    \\(Claude Code, Codex, opencode, Pi). Installs are global (user-level).
    \\
    \\Usage: attyx skill <install|uninstall> [options]
    \\
    \\Run with no options in a terminal for an interactive prompt (pick from the
    \\agents detected on this machine).
    \\
    \\Options (non-interactive / scripting):
    \\      --agents <list>  Comma-separated: claude,codex,opencode,pi
    \\  -a, --all            All detected agents
    \\
    \\Examples:
    \\  attyx skill install                          # interactive
    \\  attyx skill install --all
    \\  attyx skill install --agents claude,codex
    \\  attyx skill uninstall --agents pi
;

// ── Tests ──

const testing = std.testing;

fn harnessByKey(key: []const u8) Harness {
    for (harnesses) |h| {
        if (std.mem.eql(u8, h.key, key)) return h;
    }
    unreachable;
}

test "buildPaths: skill format" {
    var p = Paths{};
    var exp: [1024]u8 = undefined;

    try testing.expect(buildPaths(harnessByKey("claude"), "/h", &p));
    try testing.expectEqualStrings(try std.fmt.bufPrint(&exp, "/h/.claude/skills/{s}/SKILL.md", .{skill_name}), p.file);

    try testing.expect(buildPaths(harnessByKey("codex"), "/h", &p));
    try testing.expectEqualStrings(try std.fmt.bufPrint(&exp, "/h/.agents/skills/{s}/SKILL.md", .{skill_name}), p.file);

    try testing.expect(buildPaths(harnessByKey("pi"), "/h", &p));
    try testing.expectEqualStrings(try std.fmt.bufPrint(&exp, "/h/.pi/agent/skills/{s}/SKILL.md", .{skill_name}), p.file);
}

test "buildPaths: opencode command format (file name = command, no skill dir)" {
    var p = Paths{};
    var exp: [1024]u8 = undefined;

    try testing.expect(buildPaths(harnessByKey("opencode"), "/h", &p));
    try testing.expectEqualStrings("/h/.config/opencode/commands", p.dir);
    try testing.expectEqualStrings(try std.fmt.bufPrint(&exp, "/h/.config/opencode/commands/{s}.md", .{skill_name}), p.file);
}

test "command_content: opencode frontmatter is description-only over the shared body" {
    try testing.expect(std.mem.startsWith(u8, command_content, "---\ndescription: "));
    // Shared instruction body is preserved…
    try testing.expect(std.mem.indexOf(u8, command_content, "# Attyx Terminal IPC Skill") != null);
    // …but the Claude/skill-only frontmatter keys are gone.
    const fm_end = std.mem.indexOf(u8, command_content[4..], "\n---\n").?;
    const frontmatter = command_content[0 .. 4 + fm_end];
    try testing.expect(std.mem.indexOf(u8, frontmatter, "allowed-tools") == null);
    try testing.expect(std.mem.indexOf(u8, frontmatter, "argument-hint") == null);
}
