// Attyx — agent status serialization
//
// Shared formatting for agent status records, used by both the one-shot
// `list agents` query (handler_query) and the streaming `watch agents`
// subscription (watch.zig). Keeping it here avoids duplicating the JSON/TSV
// shape in two places so the two surfaces never drift.

const std = @import("std");
const actions = @import("attyx").actions;
const platform = @import("../platform/platform.zig");
const pricing = @import("../app/agent_pricing.zig");
const ui_cell = @import("attyx").overlay_ui_cell;
const humanize = @import("attyx").overlay_agent_dashboard.humanize;

pub const AgentStatus = actions.AgentStatus;
pub const AgentUsage = actions.AgentUsage;

/// Stable string name for a status — the wire/CLI vocabulary.
pub fn stateStr(status: AgentStatus) []const u8 {
    return switch (status) {
        .none => "none",
        .idle => "idle",
        .working => "working",
        .input => "input",
    };
}

/// One agent record as a JSON object (no trailing newline). Caller joins
/// objects into an array (list) or frames them individually (watch).
/// `pid` is the agent's foreground process id (0 = unknown, e.g. daemon-backed
/// panes where the PID lives on the daemon side and isn't shipped to clients).
pub fn writeAgentJson(
    w: anytype,
    pane_id: u32,
    tab_id: u32,
    tab_name: []const u8,
    session: u32,
    pid: u32,
    status: AgentStatus,
    message: []const u8,
    usage: AgentUsage,
) !void {
    try w.print(
        "{{\"pane_id\":{d},\"tab_id\":{d},\"tab_name\":\"",
        .{ pane_id, tab_id },
    );
    try writeJsonEscaped(w, tab_name);
    try w.print("\",\"session\":{d},\"pid\":{d},\"state\":\"{s}\",\"message\":\"", .{ session, pid, stateStr(status) });
    try writeJsonEscaped(w, message);
    try w.writeAll("\"");
    try writeUsageJson(w, usage);
    try w.writeAll("}");
}

/// Append `,"usage":{…}` with only the known (non-null) fields. Always emits the
/// object (possibly empty) so consumers can rely on the key being present.
/// Cost is filled from the static price table when the agent didn't report one
/// (Codex) and the model is known — flagged via `cost_is_estimate`.
fn writeUsageJson(w: anytype, usage: AgentUsage) !void {
    const u = pricing.withEstimate(usage);
    try w.writeAll(",\"usage\":{");
    var first = true;
    try writeU64Field(w, &first, "input_tokens", u.input_tokens);
    try writeU64Field(w, &first, "output_tokens", u.output_tokens);
    try writeU64Field(w, &first, "cache_read_tokens", u.cache_read_tokens);
    try writeU64Field(w, &first, "cache_write_tokens", u.cache_write_tokens);
    try writeU64Field(w, &first, "reasoning_tokens", u.reasoning_tokens);
    try writeU64Field(w, &first, "context_used", u.context_used);
    try writeU64Field(w, &first, "context_max", u.context_max);
    if (u.cost_usd) |c| {
        try sep(w, &first);
        try w.print("\"cost_usd\":{d},\"cost_is_estimate\":{}", .{ c, u.cost_is_estimate });
    }
    if (u.model) |m| {
        try sep(w, &first);
        try w.writeAll("\"model\":\"");
        try writeJsonEscaped(w, m);
        try w.writeAll("\"");
    }
    if (u.transcript_path) |t| {
        try sep(w, &first);
        try w.writeAll("\"transcript_path\":\"");
        try writeJsonEscaped(w, t);
        try w.writeAll("\"");
    }
    try w.writeAll("}");
}

fn writeU64Field(w: anytype, first: *bool, name: []const u8, v: ?u64) !void {
    if (v) |n| {
        try sep(w, first);
        try w.print("\"{s}\":{d}", .{ name, n });
    }
}

fn sep(w: anytype, first: *bool) !void {
    if (!first.*) try w.writeAll(",");
    first.* = false;
}

// ── Human-readable table (plain `list agents` / `watch agents`) ──
//
// One shared row format so the snapshot (`list agents`) and the stream
// (`watch agents`) print identical columns — only their cadence differs. Numbers
// are humanized (1.2M, 82K/200K); `--json` carries the raw values for scripts.
const dash = "-"; // unknown value

// ── Color palette (matches the dashboard) ──
// Emitted only when the caller asks (TTY); plain mode stays grep-clean.
const c_reset = "\x1b[0m";
const c_dim = "\x1b[2m";
const c_idle = "\x1b[38;2;96;208;120m"; // green
const c_working = "\x1b[38;2;255;170;64m"; // orange
const c_input = "\x1b[38;2;176;112;255m"; // purple
const dot = "\xe2\x97\x8f"; // ●

pub fn stateColor(status: AgentStatus) []const u8 {
    return switch (status) {
        .idle => c_idle,
        .working => c_working,
        .input => c_input,
        .none => c_dim,
    };
}

// Column display widths (the message column is free-width, last).
const pane_w: u16 = 4;
const session_w: u16 = 7;
const state_w: u16 = 7;
const model_w: u16 = 14;
const in_w: u16 = 7;
const out_w: u16 = 7;
const ctx_w: u16 = 13;
const cost_w: u16 = 8;
const msg_w: u16 = 40;

fn writeSpaces(w: anytype, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeByte(' ');
}

/// Write `s` in exactly `width` display columns (space-padded, or ellipsis-
/// truncated when it overflows), then a 2-space gutter. `color` (empty = none)
/// wraps only the text — padding stays uncolored and ANSI codes are zero-width,
/// so columns line up identically in plain and colored modes.
fn writeColC(w: anytype, s: []const u8, width: u16, right: bool, color: []const u8) !void {
    const full = ui_cell.utf8Count(s);
    if (full <= width) {
        const pad = width - full;
        if (right) try writeSpaces(w, pad);
        if (color.len > 0) try w.writeAll(color);
        try w.writeAll(s);
        if (color.len > 0) try w.writeAll(c_reset);
        if (!right) try writeSpaces(w, pad);
    } else {
        const off = ui_cell.utf8ByteOffset(s, width - 1);
        if (color.len > 0) try w.writeAll(color);
        try w.writeAll(s[0..off]);
        try w.writeAll("\xe2\x80\xa6"); // …
        if (color.len > 0) try w.writeAll(c_reset);
    }
    try w.writeAll("  ");
}

fn writeCol(w: anytype, s: []const u8, width: u16, right: bool) !void {
    try writeColC(w, s, width, right, "");
}

/// Dim color for an unknown ("-") cell in color mode, else none.
fn dimDash(color: bool, s: []const u8) []const u8 {
    return if (color and std.mem.eql(u8, s, dash)) c_dim else "";
}

/// Column header for the human table (printed once, above the rows). In color
/// mode the labels are dimmed and a 2-col lead is reserved for the status dot.
pub fn writeAgentTableHeader(w: anytype, color: bool) !void {
    const hc = if (color) c_dim else "";
    if (color) try w.writeAll("  "); // dot column lead
    try writeColC(w, "PANE", pane_w, false, hc);
    try writeColC(w, "SESSION", session_w, false, hc);
    try writeColC(w, "STATE", state_w, false, hc);
    try writeColC(w, "MODEL", model_w, false, hc);
    try writeColC(w, "IN", in_w, true, hc);
    try writeColC(w, "OUT", out_w, true, hc);
    try writeColC(w, "CTX", ctx_w, true, hc);
    try writeColC(w, "COST", cost_w, true, hc);
    if (color) {
        try w.writeAll(c_dim);
        try w.writeAll("MESSAGE");
        try w.writeAll(c_reset);
        try w.writeByte('\n');
    } else try w.writeAll("MESSAGE\n");
}

fn fmtCtx(buf: []u8, used: ?u64, max: ?u64) []const u8 {
    if (used) |u| {
        var ub: [16]u8 = undefined;
        const us = humanize(&ub, u);
        if (max) |mx| {
            var mb: [16]u8 = undefined;
            return std.fmt.bufPrint(buf, "{s}/{s}", .{ us, humanize(&mb, mx) }) catch dash;
        }
        return std.fmt.bufPrint(buf, "{s}", .{us}) catch dash;
    }
    return dash;
}

fn fmtCost(buf: []u8, c: ?f64, estimate: bool) []const u8 {
    if (c) |v| return std.fmt.bufPrint(buf, "{s}${d:.2}", .{ if (estimate) "~" else "", v }) catch dash;
    return dash;
}

fn fmtTokens(buf: []u8, v: ?u64) []const u8 {
    return if (v) |n| humanize(buf, n) else dash;
}

/// One agent as an aligned, humanized table row (terminated by newline). Cost is
/// filled from the price table when the agent didn't report one (Codex).
pub fn writeAgentRow(
    w: anytype,
    pane_id: u32,
    tab_id: u32,
    session: u32,
    pid: u32,
    status: AgentStatus,
    message: []const u8,
    usage_in: AgentUsage,
    color: bool,
) !void {
    _ = tab_id;
    _ = pid;
    const usage = pricing.withEstimate(usage_in);
    var pb: [12]u8 = undefined;
    var sb: [12]u8 = undefined;
    var ib: [16]u8 = undefined;
    var ob: [16]u8 = undefined;
    var kb: [24]u8 = undefined;
    var cb: [24]u8 = undefined;
    if (color) {
        try w.writeAll(stateColor(status));
        try w.writeAll(dot);
        try w.writeAll(c_reset);
        try w.writeByte(' ');
    }
    try writeCol(w, std.fmt.bufPrint(&pb, "{d}", .{pane_id}) catch "?", pane_w, false);
    try writeCol(w, std.fmt.bufPrint(&sb, "{d}", .{session}) catch "?", session_w, false);
    try writeColC(w, stateStr(status), state_w, false, if (color) stateColor(status) else "");
    try writeCol(w, if (usage.model) |m| m else dash, model_w, false);
    const in_s = fmtTokens(&ib, usage.input_tokens);
    const out_s = fmtTokens(&ob, usage.output_tokens);
    const ctx_s = fmtCtx(&kb, usage.context_used, usage.context_max);
    const cost_s = fmtCost(&cb, usage.cost_usd, usage.cost_is_estimate);
    try writeColC(w, in_s, in_w, true, dimDash(color, in_s));
    try writeColC(w, out_s, out_w, true, dimDash(color, out_s));
    try writeColC(w, ctx_s, ctx_w, true, dimDash(color, ctx_s));
    try writeColC(w, cost_s, cost_w, true, dimDash(color, cost_s));
    // Message: free-width last column, newlines folded, ellipsis past msg_w.
    var folded: [256]u8 = undefined;
    var n: usize = 0;
    for (message) |ch| {
        if (n >= folded.len) break;
        folded[n] = if (ch == '\n' or ch == '\r' or ch == '\t') ' ' else ch;
        n += 1;
    }
    const m = folded[0..n];
    if (ui_cell.utf8Count(m) > msg_w) {
        const off = ui_cell.utf8ByteOffset(m, msg_w - 1);
        try w.writeAll(m[0..off]);
        try w.writeAll("\xe2\x80\xa6");
    } else try w.writeAll(m);
    try w.writeByte('\n');
}

// JSON shapes for re-parsing a stream frame back into a row (watch client).
const RawUsage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cache_read_tokens: ?u64 = null,
    cache_write_tokens: ?u64 = null,
    reasoning_tokens: ?u64 = null,
    context_used: ?u64 = null,
    context_max: ?u64 = null,
    cost_usd: ?f64 = null,
    cost_is_estimate: bool = false,
    model: ?[]const u8 = null,
};
const RawRecord = struct {
    pane_id: u32 = 0,
    tab_id: u32 = 0,
    session: u32 = 0,
    pid: u32 = 0,
    state: []const u8 = "none",
    message: []const u8 = "",
    usage: RawUsage = .{},
};

fn statusFromStr(s: []const u8) AgentStatus {
    if (std.mem.eql(u8, s, "working")) return .working;
    if (std.mem.eql(u8, s, "input")) return .input;
    if (std.mem.eql(u8, s, "idle")) return .idle;
    return .none;
}

/// Parse one NDJSON agent record and write it as a human table row — so the
/// `watch agents` client reuses the exact same row format as `list agents`.
fn rowUsage(r: RawRecord) AgentUsage {
    return .{
        .input_tokens = r.usage.input_tokens,
        .output_tokens = r.usage.output_tokens,
        .cache_read_tokens = r.usage.cache_read_tokens,
        .cache_write_tokens = r.usage.cache_write_tokens,
        .reasoning_tokens = r.usage.reasoning_tokens,
        .context_used = r.usage.context_used,
        .context_max = r.usage.context_max,
        .cost_usd = r.usage.cost_usd,
        .cost_is_estimate = r.usage.cost_is_estimate,
        .model = r.usage.model,
    };
}

pub fn writeAgentRowFromJson(w: anytype, gpa: std.mem.Allocator, line: []const u8, color: bool) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = std.json.parseFromSliceLeaky(RawRecord, arena.allocator(), trimmed, .{ .ignore_unknown_fields = true }) catch return;
    try writeAgentRow(w, r.pane_id, r.tab_id, r.session, r.pid, statusFromStr(r.state), r.message, rowUsage(r), color);
}

/// Parse a `list agents --json` array and write the full human table (header +
/// a row per agent). Used by the client to format `list agents` locally, so the
/// output is TTY-aware (colored on a terminal, plain when piped).
pub fn writeAgentTable(w: anytype, gpa: std.mem.Allocator, json_array: []const u8, color: bool) !void {
    const trimmed = std.mem.trim(u8, json_array, " \t\r\n");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try writeAgentTableHeader(w, color);
    const arr = std.json.parseFromSliceLeaky([]RawRecord, arena.allocator(), trimmed, .{ .ignore_unknown_fields = true }) catch return;
    for (arr) |r| {
        try writeAgentRow(w, r.pane_id, r.tab_id, r.session, r.pid, statusFromStr(r.state), r.message, rowUsage(r), color);
    }
}

/// Foreground PID of the process running in a pane, or 0 if unknown.
/// `master_fd` is the pane's PTY master fd (`pane.pty.master`); it's < 0 for
/// daemon-backed panes, where no PID is available client-side.
pub fn panePid(master_fd: std.posix.fd_t) u32 {
    const pid = platform.getForegroundProcessId(master_fd) orelse return 0;
    return if (pid > 0) @intCast(pid) else 0;
}

/// Escape a string for embedding inside a JSON string literal.
pub fn writeJsonEscaped(w: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
}

test "writeAgentJson escapes message and omits unknown usage" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeAgentJson(stream.writer(), 3, 1, "dev", 2, 4242, .working, "say \"hi\"\nnow", .{});
    try std.testing.expectEqualStrings(
        "{\"pane_id\":3,\"tab_id\":1,\"tab_name\":\"dev\",\"session\":2,\"pid\":4242,\"state\":\"working\",\"message\":\"say \\\"hi\\\"\\nnow\",\"usage\":{}}",
        stream.getWritten(),
    );
}

test "writeAgentJson emits known usage fields and skips nulls" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const u = AgentUsage{
        .input_tokens = 1234,
        .output_tokens = 5678,
        .context_used = 82000,
        .context_max = 200000,
        .cost_usd = 0.4213,
        .cost_is_estimate = false,
        .model = "opus-4.6",
    };
    try writeAgentJson(stream.writer(), 3, 1, "", 2, 0, .working, "", u);
    try std.testing.expectEqualStrings(
        "{\"pane_id\":3,\"tab_id\":1,\"tab_name\":\"\",\"session\":2,\"pid\":0,\"state\":\"working\",\"message\":\"\"," ++
            "\"usage\":{\"input_tokens\":1234,\"output_tokens\":5678,\"context_used\":82000," ++
            "\"context_max\":200000,\"cost_usd\":0.4213,\"cost_is_estimate\":false,\"model\":\"opus-4.6\"}}",
        stream.getWritten(),
    );
}

test "writeAgentRow renders an aligned, humanized row with context + tokens" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeAgentRow(stream.writer(), 3, 1, 2, 0, .working, "Editing parser.zig", .{
        .input_tokens = 1_200_000,
        .output_tokens = 842_000,
        .context_used = 82_000,
        .context_max = 200_000,
        .cost_usd = 0.42,
        .model = "opus-4.8",
    }, false);
    const out = stream.getWritten();
    // Humanized values + context as used/max + the message, all present.
    try std.testing.expect(std.mem.indexOf(u8, out, "1.2M") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "842K") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "82K/200K") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$0.42") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "opus-4.8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Editing parser.zig") != null);
    try std.testing.expect(out[out.len - 1] == '\n');

    // Unknown usage → dashes, newline folded in the message.
    stream.reset();
    try writeAgentRow(stream.writer(), 7, 0, 1, 0, .input, "needs\ninput", .{}, false);
    const out2 = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out2, "needs input") != null); // folded
    try std.testing.expect(std.mem.indexOf(u8, out2, "input") != null); // state
    // Plain mode has no ANSI escapes (grep-safe).
    try std.testing.expect(std.mem.indexOf(u8, out2, "\x1b[") == null);
}

test "color mode adds a status dot and ANSI codes; plain stays clean" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeAgentRow(stream.writer(), 3, 1, 2, 0, .working, "hi", .{ .model = "opus-4.8" }, true);
    const out = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, dot) != null); // ●
    try std.testing.expect(std.mem.indexOf(u8, out, c_working) != null); // orange
    try std.testing.expect(std.mem.indexOf(u8, out, c_reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "working") != null);
}

test "writeAgentRowFromJson matches writeAgentRow (same format for watch)" {
    var a_buf: [512]u8 = undefined;
    var b_buf: [512]u8 = undefined;
    var as = std.io.fixedBufferStream(&a_buf);
    var bs = std.io.fixedBufferStream(&b_buf);
    const usage = AgentUsage{ .input_tokens = 1_200_000, .context_used = 82_000, .context_max = 200_000, .cost_usd = 0.42, .model = "opus-4.8" };
    try writeAgentRow(as.writer(), 3, 1, 2, 0, .working, "hi", usage, false);
    var json: [512]u8 = undefined;
    var js = std.io.fixedBufferStream(&json);
    try writeAgentJson(js.writer(), 3, 1, "", 2, 0, .working, "hi", usage);
    try writeAgentRowFromJson(bs.writer(), std.testing.allocator, js.getWritten(), false);
    try std.testing.expectEqualStrings(as.getWritten(), bs.getWritten());
}

test "writeAgentTableHeader labels the columns" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeAgentTableHeader(stream.writer(), false);
    const out = stream.getWritten();
    for ([_][]const u8{ "PANE", "SESSION", "STATE", "MODEL", "IN", "OUT", "CTX", "COST", "MESSAGE" }) |h|
        try std.testing.expect(std.mem.indexOf(u8, out, h) != null);
}
