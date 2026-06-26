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
    session: u32,
    pid: u32,
    status: AgentStatus,
    message: []const u8,
    usage: AgentUsage,
) !void {
    try w.print(
        "{{\"pane_id\":{d},\"tab_id\":{d},\"session\":{d},\"pid\":{d},\"state\":\"{s}\",\"message\":\"",
        .{ pane_id, tab_id, session, pid, stateStr(status) },
    );
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

/// One agent record as a tab-separated row terminated by a newline:
///   pane_id \t tab_id \t session \t pid \t state \t message
/// Newlines in the message are folded to spaces so each entry stays on one line.
pub fn writeAgentTsv(
    w: anytype,
    pane_id: u32,
    tab_id: u32,
    session: u32,
    pid: u32,
    status: AgentStatus,
    message: []const u8,
    usage_in: AgentUsage,
) !void {
    const usage = pricing.withEstimate(usage_in);
    try w.print("{d}\t{d}\t{d}\t{d}\t{s}\t", .{ pane_id, tab_id, session, pid, stateStr(status) });
    for (message) |ch| {
        try w.writeByte(if (ch == '\n' or ch == '\r') ' ' else ch);
    }
    // Appended usage columns (fixed order): in out cr cw rsn ctx ctxmax cost model.
    // Empty string for unknowns; leading columns unchanged for back-compat.
    try writeU64Col(w, usage.input_tokens);
    try writeU64Col(w, usage.output_tokens);
    try writeU64Col(w, usage.cache_read_tokens);
    try writeU64Col(w, usage.cache_write_tokens);
    try writeU64Col(w, usage.reasoning_tokens);
    try writeU64Col(w, usage.context_used);
    try writeU64Col(w, usage.context_max);
    if (usage.cost_usd) |c| try w.print("\t{d}", .{c}) else try w.writeAll("\t");
    if (usage.model) |m| {
        try w.writeByte('\t');
        for (m) |ch| try w.writeByte(if (ch == '\t' or ch == '\n' or ch == '\r') ' ' else ch);
    } else try w.writeAll("\t");
    try w.writeByte('\n');
}

fn writeU64Col(w: anytype, v: ?u64) !void {
    if (v) |n| try w.print("\t{d}", .{n}) else try w.writeAll("\t");
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
    try writeAgentJson(stream.writer(), 3, 1, 2, 4242, .working, "say \"hi\"\nnow", .{});
    try std.testing.expectEqualStrings(
        "{\"pane_id\":3,\"tab_id\":1,\"session\":2,\"pid\":4242,\"state\":\"working\",\"message\":\"say \\\"hi\\\"\\nnow\",\"usage\":{}}",
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
    try writeAgentJson(stream.writer(), 3, 1, 2, 0, .working, "", u);
    try std.testing.expectEqualStrings(
        "{\"pane_id\":3,\"tab_id\":1,\"session\":2,\"pid\":0,\"state\":\"working\",\"message\":\"\"," ++
            "\"usage\":{\"input_tokens\":1234,\"output_tokens\":5678,\"context_used\":82000," ++
            "\"context_max\":200000,\"cost_usd\":0.4213,\"cost_is_estimate\":false,\"model\":\"opus-4.6\"}}",
        stream.getWritten(),
    );
}

test "writeAgentTsv folds newlines and appends usage columns" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    // Unknown usage → trailing empty columns.
    try writeAgentTsv(stream.writer(), 7, 2, 0, 0, .input, "needs\ninput", .{});
    try std.testing.expectEqualStrings("7\t2\t0\t0\tinput\tneeds input\t\t\t\t\t\t\t\t\t\n", stream.getWritten());

    stream.reset();
    try writeAgentTsv(stream.writer(), 7, 2, 0, 0, .working, "", .{ .input_tokens = 100, .model = "opus" });
    try std.testing.expectEqualStrings("7\t2\t0\t0\tworking\t\t100\t\t\t\t\t\t\t\topus\n", stream.getWritten());
}
