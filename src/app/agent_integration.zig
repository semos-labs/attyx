/// AI-agent status integration (settings-injection model).
///
/// Detecting an AI coding agent's run state reliably means letting the agent
/// report it via its own lifecycle hooks (the cmux insight). We wire Claude
/// Code's hooks to a small emitter that writes OSC 7337;agent-status, which the
/// terminal engine turns into the per-tab status dot (green=idle, orange=working,
/// purple=needs input).
///
/// Earlier this shadowed `claude` with a PATH shim, but a shell that rebuilds
/// PATH (e.g. xyron's path_defs) or an absolute-path alias defeats that. So we
/// instead merge the hooks into the settings file Claude actually loads
/// (CLAUDE_CONFIG_DIR/settings.json, default ~/.claude). That works regardless
/// of how `claude` is launched — alias, PATH, absolute path, any shell.
///
/// The merge is non-destructive (preserves the user's other settings/hooks),
/// idempotent (a substring fast-path skips already-injected files), and atomic
/// (temp + rename). The emitter is self-gated on ATTYX_PID, so the injected
/// hooks are a no-op when claude runs outside attyx.
///
/// Run once at startup (main process) — not per-pane — so it has a real
/// allocator and config access. POSIX-only; a no-op on Windows.
const std = @import("std");
const builtin = @import("builtin");
const opencode = @import("agent_integration_opencode.zig");
const codex = @import("agent_integration_codex.zig");

const is_windows = builtin.os.tag == .windows;

/// The emitter's filename, also used as the marker for identifying our hook
/// entries when de-duplicating on re-injection.
pub const emitter_name = "attyx-agent-status";

pub const EventSpec = struct { name: []const u8, matcher: ?[]const u8, state: []const u8 };

/// Claude Code hooks (settings.json). PermissionRequest is status-only — the
/// emitter writes nothing to stdout, so it makes no allow/deny decision and the
/// prompt shows normally. Notification's `notify` branch classifies the message
/// into input vs idle.
const claude_events = [_]EventSpec{
    // Fires the instant Claude launches (and on resume/clear/compact), so the
    // agent registers as idle immediately instead of staying invisible until the
    // first prompt. Without this, no OSC is emitted until UserPromptSubmit/Stop.
    .{ .name = "SessionStart", .matcher = null, .state = "idle" },
    .{ .name = "UserPromptSubmit", .matcher = null, .state = "working" },
    .{ .name = "PreToolUse", .matcher = "*", .state = "working" },
    .{ .name = "PermissionRequest", .matcher = null, .state = "input" },
    .{ .name = "Notification", .matcher = null, .state = "notify" },
    .{ .name = "Stop", .matcher = null, .state = "idle" },
    .{ .name = "SessionEnd", .matcher = null, .state = "none" },
};

/// Install the emitter and inject hooks into every discovered Claude config
/// dir. Best-effort; never fails the caller.
pub fn install(gpa: std.mem.Allocator, home: []const u8) void {
    if (comptime is_windows) return;
    if (home.len == 0) return;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // 1. Emitter — written atomically, executable.
    const agent_bin = std.fmt.allocPrint(a, "{s}/.config/attyx/shell-integration/agent-bin", .{home}) catch return;
    mkdirp(a, agent_bin);
    const emitter_path = std.fmt.allocPrint(a, "{s}/{s}", .{ agent_bin, emitter_name }) catch return;
    writeAtomic(a, emitter_path, emitter_script, 0o755);

    // 2. Claude — merge hooks into each config dir's settings.json.
    var dirs = std.ArrayList([]const u8){};
    discoverClaudeConfigDirs(a, home, &dirs);
    for (dirs.items) |dir| {
        mkdirp(a, dir);
        const settings = std.fmt.allocPrint(a, "{s}/settings.json", .{dir}) catch continue;
        ensureHooksFile(a, settings, emitter_path, &claude_events);
    }

    // 3. Codex — same JSON hook shape (at ~/.codex/hooks.json), but Codex gates
    //    command hooks behind a trust check, so the module also pre-trusts them.
    codex.install(a, home, emitter_path);

    // 4. opencode — a JS plugin that shells out to the emitter, loaded via the
    //    plugins dir and registered in opencode.json(c). See its own module.
    opencode.install(a, home, emitter_path);
}

/// Collect Claude config dirs to inject into: ~/.claude (the default) plus any
/// sibling ~/.claude-* directories (e.g. the user's ~/.claude-hs).
fn discoverClaudeConfigDirs(a: std.mem.Allocator, home: []const u8, out: *std.ArrayList([]const u8)) void {
    const default = std.fmt.allocPrint(a, "{s}/.claude", .{home}) catch return;
    out.append(a, default) catch return;

    var dir = std.fs.cwd().openDir(home, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, ".claude-")) continue;
        const p = std.fmt.allocPrint(a, "{s}/{s}", .{ home, entry.name }) catch continue;
        out.append(a, p) catch continue;
    }
}

/// Merge `events` hooks into a JSON hooks file (Claude settings.json or Codex
/// hooks.json — same `{ "hooks": { ... } }` shape). No-op if already present.
pub fn ensureHooksFile(a: std.mem.Allocator, path: []const u8, emitter_path: []const u8, events: []const EventSpec) void {
    const content = readFile(a, path) orelse "{}";

    // Fast path: every command already present → leave the file untouched
    // (don't reformat the user's file on subsequent runs).
    if (hasAllCommands(a, content, emitter_path, events)) return;

    var parsed = std.json.parseFromSlice(std.json.Value, a, content, .{}) catch {
        // Malformed JSON — never overwrite the user's file blind.
        return;
    };
    if (parsed.value != .object) return;
    const root = &parsed.value;

    mergeHooks(a, &root.object, emitter_path, events) catch return;

    const out = std.json.Stringify.valueAlloc(a, root.*, .{ .whitespace = .indent_2 }) catch return;
    writeAtomic(a, path, out, 0o644);
}

fn mergeHooks(a: std.mem.Allocator, root_obj: *std.json.ObjectMap, emitter_path: []const u8, events: []const EventSpec) !void {
    // Get or create the "hooks" object.
    if (root_obj.getPtr("hooks")) |hv| {
        if (hv.* != .object) return error.UnexpectedShape;
    } else {
        try root_obj.put("hooks", .{ .object = std.json.ObjectMap.init(a) });
    }
    const hooks_obj = &root_obj.getPtr("hooks").?.object;

    for (events) |ev| {
        const command = try std.fmt.allocPrint(a, "{s} {s}", .{ emitter_path, ev.state });
        try ensureEventHook(a, hooks_obj, ev.name, ev.matcher, command);
    }
}

fn ensureEventHook(
    a: std.mem.Allocator,
    hooks_obj: *std.json.ObjectMap,
    name: []const u8,
    matcher: ?[]const u8,
    command: []const u8,
) !void {
    // Get or create the event's array.
    if (hooks_obj.getPtr(name)) |ev| {
        if (ev.* != .array) return; // user has an unexpected shape — skip this event
    } else {
        try hooks_obj.put(name, .{ .array = std.json.Array.init(a) });
    }
    const arr = &hooks_obj.getPtr(name).?.array;

    // Drop any prior attyx group (stale emitter path / dedupe), keep user groups.
    var i: usize = 0;
    while (i < arr.items.len) {
        if (groupIsAttyx(arr.items[i])) {
            _ = arr.orderedRemove(i);
        } else i += 1;
    }

    // Append our fresh group: { (matcher,) hooks: [ { type:command, command } ] }.
    var cmd_obj = std.json.ObjectMap.init(a);
    try cmd_obj.put("type", .{ .string = "command" });
    try cmd_obj.put("command", .{ .string = command });
    var inner = std.json.Array.init(a);
    try inner.append(.{ .object = cmd_obj });
    var group = std.json.ObjectMap.init(a);
    if (matcher) |m| try group.put("matcher", .{ .string = m });
    try group.put("hooks", .{ .array = inner });
    try arr.append(.{ .object = group });
}

/// A hook group is "ours" if any of its commands references the emitter.
fn groupIsAttyx(group: std.json.Value) bool {
    if (group != .object) return false;
    const hooks = group.object.get("hooks") orelse return false;
    if (hooks != .array) return false;
    for (hooks.array.items) |h| {
        if (h != .object) continue;
        const cmd = h.object.get("command") orelse continue;
        if (cmd == .string and std.mem.indexOf(u8, cmd.string, emitter_name) != null) return true;
    }
    return false;
}

/// True when the file already has our exact command under EVERY event.
///
/// This must check per-event, not via a global substring scan: several events
/// share a command string (SessionStart and Stop both emit `… idle`), so a
/// plain `indexOf` would report SessionStart as already present whenever Stop is
/// — and a newly-added event would never be injected on upgrade. We parse and
/// verify each event's array actually contains the command.
fn hasAllCommands(a: std.mem.Allocator, content: []const u8, emitter_path: []const u8, events: []const EventSpec) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, a, content, .{}) catch return false;
    if (parsed.value != .object) return false;
    const hooks_v = parsed.value.object.get("hooks") orelse return false;
    if (hooks_v != .object) return false;
    for (events) |ev| {
        const arr_v = hooks_v.object.get(ev.name) orelse return false;
        if (arr_v != .array) return false;
        const command = std.fmt.allocPrint(a, "{s} {s}", .{ emitter_path, ev.state }) catch return false;
        if (!eventHasCommand(arr_v.array, command)) return false;
    }
    return true;
}

/// True when any hook group in `groups` carries the exact command string.
fn eventHasCommand(groups: std.json.Array, command: []const u8) bool {
    for (groups.items) |group| {
        if (group != .object) continue;
        const ghooks = group.object.get("hooks") orelse continue;
        if (ghooks != .array) continue;
        for (ghooks.array.items) |h| {
            if (h != .object) continue;
            const cmd = h.object.get("command") orelse continue;
            if (cmd == .string and std.mem.eql(u8, cmd.string, command)) return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// File helpers
// ---------------------------------------------------------------------------

pub fn readFile(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(a, 4 * 1024 * 1024) catch null;
}

/// Atomic write: full write to a per-pid temp file, then rename over the dest.
pub fn writeAtomic(a: std.mem.Allocator, path: []const u8, content: []const u8, mode: std.posix.mode_t) void {
    const tmp = std.fmt.allocPrintSentinel(a, "{s}.{d}.tmp", .{ path, std.c.getpid() }, 0) catch return;
    const final = std.fmt.allocPrintSentinel(a, "{s}", .{path}, 0) catch return;

    const fd = std.posix.openatZ(std.posix.AT.FDCWD, tmp, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, mode) catch return;
    var ok = true;
    var off: usize = 0;
    while (off < content.len) {
        const n = std.posix.write(fd, content[off..]) catch {
            ok = false;
            break;
        };
        if (n == 0) {
            ok = false;
            break;
        }
        off += n;
    }
    std.posix.fchmod(fd, mode) catch {};
    std.posix.close(fd);
    if (!ok) {
        std.posix.unlinkZ(tmp) catch {};
        return;
    }
    std.posix.renameatZ(std.posix.AT.FDCWD, tmp, std.posix.AT.FDCWD, final) catch {
        std.posix.unlinkZ(tmp) catch {};
    };
}

/// mkdir -p, best-effort.
pub fn mkdirp(a: std.mem.Allocator, path: []const u8) void {
    std.fs.cwd().makePath(path) catch {
        _ = a;
        return;
    };
}

// ---------------------------------------------------------------------------
// Emitter script
// ---------------------------------------------------------------------------

/// Reports the agent state to the controlling terminal via OSC 7337. Invoked by
/// the injected Claude Code hooks (by absolute path). No-op outside attyx
/// (ATTYX_PID unset). `notify` reads the Notification hook's JSON on stdin and
/// distinguishes a permission/approval request (blocked on the user → input)
/// from the idle prompt (just idle).
const emitter_script =
    \\#!/bin/sh
    \\# Attyx agent status emitter. No-op outside attyx; never disturbs the caller.
    \\[ -n "$ATTYX_PID" ] || exit 0
    \\s="$1"
    \\# Read the hook's JSON from stdin once (skip if stdin is a tty, to never block).
    \\raw=""
    \\[ -t 0 ] || raw=$(cat 2>/dev/null)
    \\if [ "$s" = "notify" ]; then
    \\  case "$raw" in
    \\    *permission*|*Permission*|*approve*|*Approve*|*"needs your"*) s=input ;;
    \\    *) s=idle ;;
    \\  esac
    \\fi
    \\case "$s" in
    \\  idle|working|input|none) ;;
    \\  *) exit 0 ;;
    \\esac
    \\# A one-line message preview from the hook JSON's "message" field; strip
    \\# control chars so it can't terminate the OSC. Passed as a printf arg (not
    \\# the format) so a literal % in the message is harmless.
    \\msg=$(printf '%s' "$raw" | LC_ALL=C sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 | cut -c1-160 | tr -d '\001-\037')
    \\tty="${ATTYX_TTY:-/dev/tty}"
    \\if [ -n "$msg" ]; then
    \\  printf '\033]7337;agent-status;agent;%s;%s\a' "$s" "$msg" > "$tty" 2>/dev/null
    \\else
    \\  printf '\033]7337;agent-status;agent;%s\a' "$s" > "$tty" 2>/dev/null
    \\fi
    \\exit 0
    \\
;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |pos| : (count += 1) i = pos + needle.len;
    return count;
}

fn mergeToString(a: std.mem.Allocator, input: []const u8, emitter: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, input, .{});
    const root = &parsed.value;
    try mergeHooks(a, &root.object, emitter, &claude_events);
    return std.json.Stringify.valueAlloc(a, root.*, .{ .whitespace = .indent_2 });
}

test "merge into empty settings injects all lifecycle hooks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try mergeToString(a, "{}", "/E/attyx-agent-status");
    for ([_][]const u8{ "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd" }) |ev|
        try testing.expect(std.mem.indexOf(u8, out, ev) != null);
    try testing.expect(std.mem.indexOf(u8, out, "/E/attyx-agent-status working") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/E/attyx-agent-status notify") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/E/attyx-agent-status input") != null); // PermissionRequest
    try testing.expect(std.mem.indexOf(u8, out, "/E/attyx-agent-status idle") != null); // SessionStart/Stop
}

test "merge preserves unrelated settings and existing user hooks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{ "model": "opus", "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "my-own-hook" } ] } ] } }
    ;
    const out = try mergeToString(a, input, "/E/attyx-agent-status");
    try testing.expect(std.mem.indexOf(u8, out, "\"model\"") != null); // unrelated key kept
    try testing.expect(std.mem.indexOf(u8, out, "my-own-hook") != null); // user's Stop hook kept
    try testing.expect(std.mem.indexOf(u8, out, "/E/attyx-agent-status idle") != null); // ours added
}

test "re-merge is idempotent (no duplicate attyx groups)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const once = try mergeToString(a, "{}", "/E/attyx-agent-status");
    const twice = try mergeToString(a, once, "/E/attyx-agent-status");
    // Idempotency: re-merging adds no new groups, so the idle command (emitted by
    // both SessionStart and Stop) occurs the same number of times either way.
    try testing.expectEqual(countOccurrences(once, "/E/attyx-agent-status idle"), countOccurrences(twice, "/E/attyx-agent-status idle"));
}

test "re-merge with a changed emitter path drops the stale group" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try mergeToString(a, "{}", "/OLD/attyx-agent-status");
    const new = try mergeToString(a, old, "/NEW/attyx-agent-status");
    try testing.expect(std.mem.indexOf(u8, new, "/OLD/attyx-agent-status") == null); // stale gone
    try testing.expect(std.mem.indexOf(u8, new, "/NEW/attyx-agent-status idle") != null); // new present
}

test "hasAllCommands detects a fully-injected file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try mergeToString(a, "{}", "/E/attyx-agent-status");
    try testing.expect(hasAllCommands(a, out, "/E/attyx-agent-status", &claude_events));
    try testing.expect(!hasAllCommands(a, "{}", "/E/attyx-agent-status", &claude_events));
}

test "hasAllCommands requires the SessionStart event, not just the shared idle command" {
    // Pre-upgrade file: has Stop (which emits the same `… idle` command) but no
    // SessionStart. A substring scan would wrongly call this fully-injected and
    // skip the merge, so SessionStart would never appear — the launch-detection
    // regression. hasAllCommands must return false here.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pre_upgrade =
        \\{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/E/attyx-agent-status idle" } ] } ] } }
    ;
    try testing.expect(!hasAllCommands(a, pre_upgrade, "/E/attyx-agent-status", &claude_events));

    // After a merge, the SessionStart event is present and the check passes.
    const merged = try mergeToString(a, pre_upgrade, "/E/attyx-agent-status");
    try testing.expect(hasAllCommands(a, merged, "/E/attyx-agent-status", &claude_events));
    try testing.expect(std.mem.indexOf(u8, merged, "SessionStart") != null);
}

test "emitter script self-gates on ATTYX_PID and emits the OSC" {
    try testing.expect(std.mem.indexOf(u8, emitter_script, "[ -n \"$ATTYX_PID\" ] || exit 0") != null);
    try testing.expect(std.mem.indexOf(u8, emitter_script, "]7337;agent-status;agent;%s") != null);
}

test "install generates the emitter and injects hooks into ~/.claude" {
    const home = "/tmp/attyx_install_test";
    std.fs.cwd().deleteTree("/tmp/attyx_install_test") catch {};
    install(testing.allocator, home);

    // Emitter exists, non-empty, executable.
    const emitter = home ++ "/.config/attyx/shell-integration/agent-bin/attyx-agent-status";
    const ef = try std.fs.cwd().openFile(emitter, .{});
    defer ef.close();
    const st = try ef.stat();
    try testing.expect(st.size > 0);
    try testing.expect(st.mode & 0o111 != 0); // executable bit set

    // settings.json has our hooks pointing at the absolute emitter path.
    const sf = try std.fs.cwd().openFile(home ++ "/.claude/settings.json", .{});
    defer sf.close();
    var buf: [8192]u8 = undefined;
    const n = try sf.readAll(&buf);
    const s = buf[0..n];
    try testing.expect(std.mem.indexOf(u8, s, "UserPromptSubmit") != null);
    try testing.expect(std.mem.indexOf(u8, s, "/.config/attyx/shell-integration/agent-bin/attyx-agent-status working") != null);
}
