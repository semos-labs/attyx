//! Codex agent-status integration.
//!
//! Codex loads lifecycle hooks from `~/.codex/hooks.json` using the same JSON
//! shape and event names as Claude (SessionStart fires on launch/resume/clear/
//! compact). Codex has no Notification or SessionEnd events, so there's no
//! idle-prompt or clear-on-exit signal; the dot registers idle on launch and
//! rests at idle after a turn.
//!
//! The catch that makes Codex different from Claude: Codex **gates command hooks
//! behind a trust check**. It records a `trusted_hash` per hook in
//! `~/.codex/config.toml` `[hooks.state]` and silently skips any hook whose
//! current hash isn't trusted. So writing hooks.json alone produces no status —
//! the hooks never run. We therefore also pre-trust our own hooks by writing the
//! matching `trusted_hash`, computed with Codex's exact algorithm, so they fire
//! immediately (matching the zero-touch Claude experience).
//!
//! All file writes are non-destructive and idempotent: config.toml is patched at
//! the text level (no parse + re-stringify) so the user's other settings and
//! formatting survive, and we never duplicate a TOML table header.
const std = @import("std");
const ai = @import("agent_integration.zig");

/// Codex lifecycle hooks. Matchers are null (match-all); the trust-hash and
/// matcher-resolution logic below mirrors Codex so a future non-null matcher
/// would still produce a correct hash.
const codex_events = [_]ai.EventSpec{
    .{ .name = "SessionStart", .matcher = null, .state = "idle" },
    .{ .name = "UserPromptSubmit", .matcher = null, .state = "working" },
    .{ .name = "PreToolUse", .matcher = null, .state = "working" },
    .{ .name = "PermissionRequest", .matcher = null, .state = "input" },
    .{ .name = "Stop", .matcher = null, .state = "idle" },
};

/// Merge hooks into ~/.codex/hooks.json, enable the hooks feature, and pre-trust
/// our hooks. Best-effort; a no-op if Codex isn't set up.
pub fn install(a: std.mem.Allocator, home: []const u8, emitter_path: []const u8, telemetry: bool) void {
    const dir = std.fmt.allocPrint(a, "{s}/.codex", .{home}) catch return;
    // Only act if Codex is actually set up (don't create ~/.codex speculatively).
    var d = std.fs.cwd().openDir(dir, .{}) catch return;
    d.close();

    // Codex carries no tokens on its hooks and has no statusline, so usage comes
    // from the session rollout file. With telemetry on, the hooks point at a
    // companion script that (1) delegates status to the shared emitter and
    // (2) tails the active rollout for the last cumulative token_count and emits
    // agent-usage. With telemetry off, the hooks run the plain emitter (status
    // only). Either path is one command / one group / one handler per event, so
    // Codex's trust-hash machinery is unchanged.
    var hook_cmd_path = emitter_path;
    if (telemetry) {
        const agent_bin = std.fmt.allocPrint(a, "{s}/.config/attyx/shell-integration/agent-bin", .{home}) catch return;
        ai.mkdirp(a, agent_bin);
        const script_path = std.fmt.allocPrint(a, "{s}/{s}", .{ agent_bin, ai.codex_script_name }) catch return;
        writeCodexScript(a, script_path, emitter_path);
        hook_cmd_path = script_path;
    }

    const hooks_path = std.fmt.allocPrint(a, "{s}/hooks.json", .{dir}) catch return;
    ai.ensureHooksFile(a, hooks_path, hook_cmd_path, &codex_events);

    const config_path = std.fmt.allocPrint(a, "{s}/config.toml", .{dir}) catch return;
    ensureFeatureFlag(a, config_path);
    ensureTrust(a, config_path, hooks_path, hook_cmd_path);
}

/// Materialize the codex status+usage script with the shared emitter path baked
/// in (substituted for the @EMITTER@ marker). 0o755 so Codex can exec it.
fn writeCodexScript(a: std.mem.Allocator, path: []const u8, emitter_path: []const u8) void {
    const size = std.mem.replacementSize(u8, codex_usage_script, "@EMITTER@", emitter_path);
    const buf = a.alloc(u8, size) catch return;
    _ = std.mem.replace(u8, codex_usage_script, "@EMITTER@", emitter_path, buf);
    ai.writeAtomic(a, path, buf, 0o755);
}

/// Ensure `[features] hooks = true` in config.toml. Conservative: only appends
/// the table when the file has no `[features]` section, to avoid creating a
/// duplicate TOML table. (Hooks are on by default in current Codex, so this is
/// belt-and-suspenders.)
fn ensureFeatureFlag(a: std.mem.Allocator, config_path: []const u8) void {
    const existing = ai.readFile(a, config_path) orelse "";
    if (std.mem.indexOf(u8, existing, "[features]") != null) return; // user manages it
    const appended = std.fmt.allocPrint(a, "{s}{s}[features]\nhooks = true\n", .{
        existing,
        if (existing.len > 0 and existing[existing.len - 1] != '\n') "\n" else "",
    }) catch return;
    ai.writeAtomic(a, config_path, appended, 0o644);
}

// ---------------------------------------------------------------------------
// Trust seeding
// ---------------------------------------------------------------------------

/// Write a `trusted_hash` into config.toml `[hooks.state]` for each injected
/// hook so Codex runs them without an interactive trust prompt. Recomputed every
/// startup against the current emitter path, so it self-heals if that changes.
fn ensureTrust(a: std.mem.Allocator, config_path: []const u8, hooks_path: []const u8, emitter_path: []const u8) void {
    var content = ai.readFile(a, config_path) orelse "";
    var changed = false;

    // Codex keys trust by the symlink-resolved path of the hooks file, so we
    // canonicalize too (a no-op on the usual symlink-free home, but correct when
    // HOME contains a symlink component). The file exists — ensureHooksFile just
    // wrote it — so realpath should succeed; fall back to the raw path if not.
    const key_path = std.fs.realpathAlloc(a, hooks_path) catch hooks_path;

    for (codex_events) |ev| {
        const label = eventLabel(ev.name) orelse continue;
        const command = std.fmt.allocPrint(a, "{s} {s}", .{ emitter_path, ev.state }) catch return;
        // State key mirrors Codex: `<hooks.json path>:<event label>:<group>:<handler>`.
        // Each event has exactly one group and one handler, so both indices are 0.
        const key = std.fmt.allocPrint(a, "{s}:{s}:0:0", .{ key_path, label }) catch return;
        const hash = trustedHash(a, label, resolveMatcher(ev.name, ev.matcher), command) catch return;

        if (upsertTrust(a, content, key, hash) catch return) |next| {
            content = next;
            changed = true;
        }
    }

    if (changed) ai.writeAtomic(a, config_path, content, 0o644);
}

/// Codex's snake_case label for a Claude-style event name, used in both the
/// trust-state key and the hashed identity. Null for events Codex lacks.
fn eventLabel(name: []const u8) ?[]const u8 {
    const map = .{
        .{ "SessionStart", "session_start" },
        .{ "UserPromptSubmit", "user_prompt_submit" },
        .{ "PreToolUse", "pre_tool_use" },
        .{ "PermissionRequest", "permission_request" },
        .{ "Stop", "stop" },
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return null;
}

/// Mirror Codex's `matcher_pattern_for_event`: UserPromptSubmit and Stop ignore
/// any configured matcher (always null); other events pass it through. The
/// resolved matcher is what Codex folds into the trust hash.
fn resolveMatcher(name: []const u8, matcher: ?[]const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "UserPromptSubmit") or std.mem.eql(u8, name, "Stop")) return null;
    return matcher;
}

/// Reproduce Codex's command-hook trust hash: `sha256:` + hex of SHA-256 over the
/// compact, key-sorted JSON of the normalized hook identity. The normalized
/// handler always carries `async=false`, `timeout=600` (Codex's default), and no
/// command_windows/statusMessage, so we can emit the canonical bytes directly.
/// Keys are sorted: top-level `event_name` < `hooks` < `matcher`; handler keys
/// `async` < `command` < `timeout` < `type`.
fn trustedHash(a: std.mem.Allocator, label: []const u8, matcher: ?[]const u8, command: []const u8) ![]u8 {
    var json = std.ArrayList(u8){};
    defer json.deinit(a);
    const w = json.writer(a);

    try w.writeAll("{\"event_name\":");
    try writeJsonString(w, label);
    try w.writeAll(",\"hooks\":[{\"async\":false,\"command\":");
    try writeJsonString(w, command);
    try w.writeAll(",\"timeout\":600,\"type\":\"command\"}]");
    if (matcher) |m| {
        try w.writeAll(",\"matcher\":");
        try writeJsonString(w, m);
    }
    try w.writeAll("}");

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json.items, &digest, .{});
    const hex = std.fmt.bytesToHex(&digest, .lower);
    return std.fmt.allocPrint(a, "sha256:{s}", .{hex});
}

/// Append a JSON-escaped string literal (with surrounding quotes). Matches
/// serde_json: escapes `"` and `\` and control chars; leaves `/` unescaped.
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) {
            try w.print("\\u{x:0>4}", .{c});
        } else {
            try w.writeByte(c);
        },
    };
    try w.writeByte('"');
}

/// Ensure config.toml records `trusted_hash = "<hash>"` under the table
/// `[hooks.state."<key>"]`. Returns the updated content, or null if it already
/// holds the exact hash. Never duplicates the table header (which TOML rejects).
fn upsertTrust(a: std.mem.Allocator, content: []const u8, key: []const u8, hash: []const u8) !?[]u8 {
    const header = try std.fmt.allocPrint(a, "[hooks.state.\"{s}\"]", .{key});
    const hash_line = try std.fmt.allocPrint(a, "trusted_hash = \"{s}\"", .{hash});

    const hpos = std.mem.indexOf(u8, content, header) orelse {
        // Header absent — append a fresh table block.
        const sep: []const u8 = if (content.len == 0 or content[content.len - 1] == '\n') "" else "\n";
        return try std.fmt.allocPrint(a, "{s}{s}{s}\n{s}\n", .{ content, sep, header, hash_line });
    };

    // Header present. Scope to its table block: from the header to the next
    // table header (`\n[`) or EOF.
    const body_start = hpos + header.len;
    const block_end = if (std.mem.indexOf(u8, content[body_start..], "\n[")) |rel|
        body_start + rel
    else
        content.len;
    const block = content[body_start..block_end];

    if (std.mem.indexOf(u8, block, hash_line) != null) return null; // already correct

    if (std.mem.indexOf(u8, block, "trusted_hash")) |rel| {
        // Replace the existing (stale) trusted_hash line in place.
        const line_start = body_start + rel;
        const line_end = if (std.mem.indexOfScalar(u8, content[line_start..], '\n')) |nl|
            line_start + nl
        else
            content.len;
        return try std.fmt.allocPrint(a, "{s}{s}{s}", .{ content[0..line_start], hash_line, content[line_end..] });
    }

    // Header exists but carries no trusted_hash yet — insert one after the
    // header line.
    const after_header = if (std.mem.indexOfScalar(u8, content[hpos..], '\n')) |nl|
        hpos + nl + 1
    else
        content.len;
    const sep: []const u8 = if (after_header == content.len and (content.len == 0 or content[content.len - 1] != '\n')) "\n" else "";
    return try std.fmt.allocPrint(a, "{s}{s}{s}\n{s}", .{ content[0..after_header], sep, hash_line, content[after_header..] });
}

// ---------------------------------------------------------------------------
// Codex status+usage script
// ---------------------------------------------------------------------------

/// Runs as every Codex hook command (`<script> <state>`). Delegates status to
/// the shared emitter (forwarding the hook JSON for the message preview), then
/// tails the active rollout file for the last cumulative `token_count` event and
/// emits an agent-usage OSC. @EMITTER@ is replaced at install time with the
/// absolute shared-emitter path.
///
/// Token parsing needs `jq`; without it the script still reports status and
/// simply omits usage (honest degradation). Codex `input_tokens` is the total
/// prompt count including the cached portion, so non-cached `in` = input − cached
/// and `cr` = cached. `ctx` uses the last turn's total_tokens (current window
/// occupancy). The session file is the newest rollout in today's dir by mtime —
/// with several concurrent Codex sessions this can attribute to the wrong one
/// (acceptable for a live operator view).
const codex_usage_script =
    \\#!/bin/sh
    \\# Attyx Codex status+usage reporter. No-op outside attyx.
    \\[ -n "$ATTYX_PID" ] || exit 0
    \\raw=""
    \\[ -t 0 ] || raw=$(cat 2>/dev/null)
    \\# Status: delegate to the shared emitter, forwarding the hook JSON for preview.
    \\printf '%s' "$raw" | "@EMITTER@" "$1"
    \\# Usage: tail the active rollout for the last cumulative token_count.
    \\command -v jq >/dev/null 2>&1 || exit 0
    \\home="${CODEX_HOME:-$HOME/.codex}"
    \\home="${home%%,*}"
    \\dir="$home/sessions/$(date +%Y/%m/%d)"
    \\f=$(ls -t "$dir"/rollout-*.jsonl 2>/dev/null | head -1)
    \\[ -n "$f" ] || exit 0
    \\# token_count is emitted per turn near the file end; bound the scan.
    \\line=$(tail -n 400 "$f" 2>/dev/null | grep '"token_count"' | tail -1)
    \\[ -n "$line" ] || exit 0
    \\kv=$(printf '%s' "$line" | jq -r '.payload.info | "in=\((.total_token_usage.input_tokens // 0) - (.total_token_usage.cached_input_tokens // 0));cr=\(.total_token_usage.cached_input_tokens // 0);out=\(.total_token_usage.output_tokens // 0);rsn=\(.total_token_usage.reasoning_output_tokens // 0);ctx=\(.last_token_usage.total_tokens // 0);ctxmax=\(.model_context_window // 0)"' 2>/dev/null)
    \\[ -n "$kv" ] || exit 0
    \\model=$(tail -n 1200 "$f" 2>/dev/null | grep '"turn_context"' | tail -1 | jq -r '.payload.model // empty' 2>/dev/null)
    \\[ -n "$model" ] && kv="$kv;model=$model"
    \\kv="$kv;tx=$f"
    \\printf '\033]7337;agent-usage;agent;%s\a' "$kv" > "${ATTYX_TTY:-/dev/tty}" 2>/dev/null
    \\exit 0
    \\
;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "codex usage script self-gates, delegates status, and emits usage" {
    try testing.expect(std.mem.indexOf(u8, codex_usage_script, "[ -n \"$ATTYX_PID\" ] || exit 0") != null);
    try testing.expect(std.mem.indexOf(u8, codex_usage_script, "\"@EMITTER@\" \"$1\"") != null);
    try testing.expect(std.mem.indexOf(u8, codex_usage_script, "token_count") != null);
    try testing.expect(std.mem.indexOf(u8, codex_usage_script, "]7337;agent-usage;agent;%s") != null);
    try testing.expect(std.mem.indexOf(u8, codex_usage_script, "model_context_window") != null);
}

test "writeCodexScript substitutes the emitter path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = "/tmp/attyx_codex_script_test";
    std.fs.cwd().deleteTree(home) catch {};
    defer std.fs.cwd().deleteTree(home) catch {};
    const bin = home ++ "/bin";
    ai.mkdirp(a, bin);
    writeCodexScript(a, bin ++ "/attyx-codex-usage", "/E/attyx-agent-status");
    const out = ai.readFile(a, bin ++ "/attyx-codex-usage") orelse return error.NoScript;
    try testing.expect(std.mem.indexOf(u8, out, "\"/E/attyx-agent-status\" \"$1\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "@EMITTER@") == null); // fully substituted
}

test "trustedHash reproduces Codex's hashes for our events (no matcher)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const emit = "/E/attyx-agent-status";
    // Vectors verified byte-for-byte against codex 0.142.2's stored trusted_hash.
    const cases = .{
        .{ "session_start", emit ++ " idle", "sha256:beef52cd722f43ea007b06b96ecd4051526adfb9c5af530c61663ab3c8f7329f" },
        .{ "stop", emit ++ " idle", "sha256:441a072a32c82a71f6c4723988c97c76b2b64be543199d316fdc014c4a3bb081" },
        .{ "user_prompt_submit", emit ++ " working", "sha256:0572432629b482efb5ec70e58168e00ca488c25ec6410f6273efc077a42970df" },
        .{ "pre_tool_use", emit ++ " working", "sha256:ab05750ea20cf56e3f00057a995c0de1cf67c1e4f73a3e74ff8039f7196a3b1b" },
        .{ "permission_request", emit ++ " input", "sha256:b10b226c92d04785a4f9ddf22a5477901954b696f532c8bcd6a8aec60321907f" },
    };
    inline for (cases) |c| {
        const got = try trustedHash(a, c[0], null, c[1]);
        try testing.expectEqualStrings(c[2], got);
    }
}

test "trustedHash folds in a non-null matcher" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try trustedHash(a, "pre_tool_use", "*", "/E/attyx-agent-status working");
    try testing.expectEqualStrings("sha256:3a576e6da0c48b6901314a9288a9b7ad2c68b3ff4578bc2513e09994086ad25c", got);
}

test "resolveMatcher drops matcher for UserPromptSubmit and Stop" {
    try testing.expect(resolveMatcher("Stop", "*") == null);
    try testing.expect(resolveMatcher("UserPromptSubmit", "*") == null);
    try testing.expectEqualStrings("*", resolveMatcher("PreToolUse", "*").?);
    try testing.expect(resolveMatcher("PreToolUse", null) == null);
}

test "upsertTrust appends a fresh block then is idempotent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = "/H/hooks.json:session_start:0:0";
    const hash = "sha256:abc";

    const once = (try upsertTrust(a, "", key, hash)).?;
    try testing.expectEqualStrings("[hooks.state.\"/H/hooks.json:session_start:0:0\"]\ntrusted_hash = \"sha256:abc\"\n", once);

    // Second pass with the same hash: no change.
    try testing.expect((try upsertTrust(a, once, key, hash)) == null);
}

test "upsertTrust preserves existing config and appends with a separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const existing = "[features]\nhooks = true"; // no trailing newline
    const out = (try upsertTrust(a, existing, "/H/hooks.json:stop:0:0", "sha256:xyz")).?;
    try testing.expect(std.mem.indexOf(u8, out, "[features]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "hooks = true\n[hooks.state.") != null); // separated onto its own line
    try testing.expect(std.mem.indexOf(u8, out, "trusted_hash = \"sha256:xyz\"") != null);
}

test "upsertTrust replaces a stale hash in place without duplicating the header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = "/H/hooks.json:stop:0:0";
    const stale =
        "[hooks.state.\"/H/hooks.json:stop:0:0\"]\ntrusted_hash = \"sha256:OLD\"\n";
    const out = (try upsertTrust(a, stale, key, "sha256:NEW")).?;
    try testing.expect(std.mem.indexOf(u8, out, "sha256:OLD") == null); // stale gone
    try testing.expect(std.mem.indexOf(u8, out, "trusted_hash = \"sha256:NEW\"") != null);
    // Header appears exactly once.
    const header = "[hooks.state.\"/H/hooks.json:stop:0:0\"]";
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out, i, header)) |p| : (count += 1) i = p + header.len;
    try testing.expectEqual(@as(usize, 1), count);
}

test "upsertTrust leaves a following table intact when replacing a hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        "[hooks.state.\"/H/hooks.json:stop:0:0\"]\ntrusted_hash = \"sha256:OLD\"\n\n[other]\nkeep = 1\n";
    const out = (try upsertTrust(a, input, "/H/hooks.json:stop:0:0", "sha256:NEW")).?;
    try testing.expect(std.mem.indexOf(u8, out, "trusted_hash = \"sha256:NEW\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[other]\nkeep = 1\n") != null); // neighbour untouched
}

test "writeJsonString escapes quotes and backslashes but not slashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    try writeJsonString(buf.writer(a), "/a/\"b\"\\c");
    try testing.expectEqualStrings("\"/a/\\\"b\\\"\\\\c\"", buf.items);
}

test "install writes hooks, enables the feature, and pre-trusts every event" {
    const home = "/tmp/attyx_codex_install_test";
    std.fs.cwd().deleteTree("/tmp/attyx_codex_install_test") catch {};
    try std.fs.cwd().makePath(home ++ "/.codex"); // install only acts if ~/.codex exists
    defer std.fs.cwd().deleteTree("/tmp/attyx_codex_install_test") catch {};

    // install() owns no allocations — like production (agent_integration.install),
    // it relies on the caller passing a short-lived arena.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    install(a, home, "/E/attyx-agent-status", true);

    const hooks = ai.readFile(a, home ++ "/.codex/hooks.json") orelse return error.NoHooks;
    try testing.expect(std.mem.indexOf(u8, hooks, "SessionStart") != null);

    const config = ai.readFile(a, home ++ "/.codex/config.toml") orelse return error.NoConfig;
    try testing.expect(std.mem.indexOf(u8, config, "[features]") != null);
    // A trust entry per event, each carrying a sha256 hash.
    for ([_][]const u8{ "session_start", "user_prompt_submit", "pre_tool_use", "permission_request", "stop" }) |label| {
        const needle = std.fmt.allocPrint(a, ":{s}:0:0\"]", .{label}) catch return error.Oom;
        try testing.expect(std.mem.indexOf(u8, config, needle) != null);
    }
    try testing.expect(std.mem.indexOf(u8, config, "trusted_hash = \"sha256:") != null);

    // Idempotent: a second install makes no further changes to config.toml.
    install(a, home, "/E/attyx-agent-status", true);
    const config2 = ai.readFile(a, home ++ "/.codex/config.toml") orelse return error.NoConfig;
    try testing.expectEqualStrings(config, config2);
}
