// Attyx — agent status serialization
//
// Shared formatting for agent status records, used by both the one-shot
// `list agents` query (handler_query) and the streaming `watch agents`
// subscription (watch.zig). Keeping it here avoids duplicating the JSON/TSV
// shape in two places so the two surfaces never drift.

const std = @import("std");
const actions = @import("attyx").actions;
const platform = @import("../platform/platform.zig");

pub const AgentStatus = actions.AgentStatus;

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
) !void {
    try w.print(
        "{{\"pane_id\":{d},\"tab_id\":{d},\"session\":{d},\"pid\":{d},\"state\":\"{s}\",\"message\":\"",
        .{ pane_id, tab_id, session, pid, stateStr(status) },
    );
    try writeJsonEscaped(w, message);
    try w.writeAll("\"}");
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
) !void {
    try w.print("{d}\t{d}\t{d}\t{d}\t{s}\t", .{ pane_id, tab_id, session, pid, stateStr(status) });
    for (message) |ch| {
        try w.writeByte(if (ch == '\n' or ch == '\r') ' ' else ch);
    }
    try w.writeByte('\n');
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

test "writeAgentJson escapes message" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeAgentJson(stream.writer(), 3, 1, 2, 4242, .working, "say \"hi\"\nnow");
    try std.testing.expectEqualStrings(
        "{\"pane_id\":3,\"tab_id\":1,\"session\":2,\"pid\":4242,\"state\":\"working\",\"message\":\"say \\\"hi\\\"\\nnow\"}",
        stream.getWritten(),
    );
}

test "writeAgentTsv folds newlines" {
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeAgentTsv(stream.writer(), 7, 2, 0, 0, .input, "needs\ninput");
    try std.testing.expectEqualStrings("7\t2\t0\t0\tinput\tneeds input\n", stream.getWritten());
}
