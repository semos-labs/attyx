// Attyx — `attyx agent read`: read an agent's transcript and return its last
// message (or, with --offset n, the n-th from last).
//
// The agent reports its transcript file path over OSC (agent-usage `tx=`), which
// Attyx stores per pane and exposes via `list agents --json`. This command looks
// that path up (attached window or `-s` daemon session), reads the file, and
// extracts assistant messages structurally — no screen scraping, no heuristics.
// Two transcript shapes are understood:
//   Claude:  {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"…"}]}}
//   Codex:   {"type":"response_item","payload":{"role":"assistant","content":[{"type":"output_text","text":"…"}]}}

const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const client = @import("client.zig");
const dproto = @import("../app/daemon/protocol.zig");
const session_connect = @import("../app/session_connect.zig");
const IpcRequest = @import("../config/cli_ipc.zig").IpcRequest;
const json = std.json;

/// `watch_agents` sentinel meaning "every session" (mirrors agent_watch.all_sessions).
const all_sessions: u32 = 0xFFFFFFFF;

const max_transcript_bytes = 64 * 1024 * 1024;

const Error = error{ NoInstance, NoAgent, NoTranscript, ReadFailed, NoMessages, OffsetOutOfRange };

const Usage = struct { transcript_path: ?[]const u8 = null };
const Rec = struct { pane_id: u32 = 0, session: u32 = 0, usage: Usage = .{} };

pub const ReadResult = struct {
    pane: u32,
    session: u32,
    offset: u32,
    total: usize, // assistant messages found
    messages: []const []const u8, // chronological (oldest first); 1..count entries
};

/// Concatenate the text blocks of one transcript line's assistant message, or
/// null if the line isn't an assistant message with text. `want_type` selects the
/// content-block type ("text" for Claude, "output_text" for Codex).
fn lineText(a: std.mem.Allocator, v: json.Value, want_type: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const content: json.Value = blk: {
        const typ = strOf(v.object, "type") orelse return null;
        if (std.mem.eql(u8, typ, "assistant")) {
            // Claude: top-level message object.
            const msg = v.object.get("message") orelse return null;
            if (msg != .object) return null;
            break :blk msg.object.get("content") orelse return null;
        } else if (std.mem.eql(u8, typ, "response_item")) {
            // Codex: payload object with role == assistant.
            const p = v.object.get("payload") orelse return null;
            if (p != .object) return null;
            const role = strOf(p.object, "role") orelse return null;
            if (!std.mem.eql(u8, role, "assistant")) return null;
            break :blk p.object.get("content") orelse return null;
        } else return null;
    };

    // content may be a bare string or an array of typed blocks.
    if (content == .string) return if (content.string.len > 0) content.string else null;
    if (content != .array) return null;
    var buf = std.ArrayList(u8){};
    for (content.array.items) |item| {
        if (item != .object) continue;
        const it_type = strOf(item.object, "type") orelse continue;
        if (!std.mem.eql(u8, it_type, want_type)) continue;
        const txt = strOf(item.object, "text") orelse continue;
        if (buf.items.len > 0) buf.append(a, '\n') catch return null;
        buf.appendSlice(a, txt) catch return null;
    }
    return if (buf.items.len > 0) buf.items else null;
}

fn strOf(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Extract assistant messages, in order, from a transcript's bytes. Pure — the
/// testable core. One message per assistant turn that carries text.
pub fn extractMessages(a: std.mem.Allocator, bytes: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8){};
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] != '{') continue;
        const v = json.parseFromSliceLeaky(json.Value, a, line, .{}) catch continue;
        const txt = lineText(a, v, "text") orelse lineText(a, v, "output_text") orelse continue;
        try out.append(a, txt);
    }
    return out.items;
}

/// Look up the pane's transcript path through the daemon. The daemon holds every
/// session's live engine and the agent-reported transcript path, so we resolve
/// it there rather than via the attached window — the window may never have
/// received the path (its usage sync can lag/omit it), and daemon-routing means
/// any session works without `-s` (pane ids are unique daemon-wide). Returns a
/// path owned by `a`.
fn transcriptPath(a: std.mem.Allocator, parsed: IpcRequest) Error![]const u8 {
    var sock_buf: [256]u8 = undefined;
    const sock = session_connect.getSocketPath(&sock_buf) orelse return Error.NoInstance;
    const fd = client.connectToSocket(sock) catch return Error.NoInstance;
    defer protocol.closeFd(fd);

    // Snapshot just this pane across all sessions: [all_sessions:u32][pane:u32].
    var pl: [8]u8 = undefined;
    std.mem.writeInt(u32, pl[0..4], all_sessions, .little);
    std.mem.writeInt(u32, pl[4..8], parsed.pane_id, .little);
    var rb: [dproto.header_size + 8]u8 = undefined;
    const req = dproto.encodeMessage(&rb, .watch_agents, &pl) catch return Error.NoInstance;
    protocol.writeAll(fd, req) catch return Error.NoInstance;

    // Drain the snapshot burst (the daemon parks after sending current agents,
    // so there's no terminator — read until the matching pane or a quiet poll).
    const agent_event: u8 = @intFromEnum(dproto.MessageType.agent_event);
    var hdr: [dproto.header_size]u8 = undefined;
    var payload: [4096]u8 = undefined;
    var found_pane = false;
    while (true) {
        var pfd = [_]posix.pollfd{.{ .fd = fd, .events = 0x0001, .revents = 0 }};
        const ready = posix.poll(&pfd, 500) catch break;
        if (ready == 0) break; // snapshot drained
        protocol.readExact(fd, &hdr) catch break;
        const plen = std.mem.readInt(u32, hdr[0..4], .little);
        if (plen == 0) continue;
        if (plen > payload.len) break;
        protocol.readExact(fd, payload[0..plen]) catch break;
        if (hdr[4] != agent_event) continue;
        const rec = json.parseFromSliceLeaky(Rec, a, std.mem.trim(u8, payload[0..plen], " \t\r\n"), .{ .ignore_unknown_fields = true }) catch continue;
        if (rec.pane_id != parsed.pane_id) continue;
        found_pane = true;
        const p = rec.usage.transcript_path orelse return Error.NoTranscript;
        if (p.len == 0) return Error.NoTranscript;
        // p slices into the stack `payload`; copy into `a` so it outlives this fn.
        return a.dupe(u8, p) catch return Error.NoTranscript;
    }
    return if (found_pane) Error.NoTranscript else Error.NoAgent;
}

fn readTranscript(a: std.mem.Allocator, parsed: IpcRequest) Error!ReadResult {
    const path = try transcriptPath(a, parsed);
    const file = std.fs.cwd().openFile(path, .{}) catch return Error.ReadFailed;
    defer file.close();
    const bytes = file.readToEndAlloc(a, max_transcript_bytes) catch return Error.ReadFailed;
    const msgs = extractMessages(a, bytes) catch return Error.ReadFailed;
    if (msgs.len == 0) return Error.NoMessages;
    if (parsed.agent_offset >= msgs.len) return Error.OffsetOutOfRange;
    const win = selectWindow(msgs.len, parsed.agent_offset, parsed.agent_count);
    return .{ .pane = parsed.pane_id, .session = parsed.target_session, .offset = parsed.agent_offset, .total = msgs.len, .messages = msgs[win.start..win.end] };
}

/// Pick the `[start, end)` slice of messages to return: a window of `count`
/// messages whose newest is `offset` back from the last, clamped to the start of
/// the transcript. Caller guarantees `offset < total`.
fn selectWindow(total: usize, offset: u32, count: u32) struct { start: usize, end: usize } {
    const end = total - offset; // exclusive: one past the newest included
    const n = @max(count, 1);
    const start = if (end > n) end - n else 0;
    return .{ .start = start, .end = end };
}

pub fn errMsg(e: Error) []const u8 {
    return switch (e) {
        Error.NoInstance => "no running Attyx instance found",
        Error.NoAgent => "pane is not running an agent",
        Error.NoTranscript => "this agent doesn't report a transcript (only Claude and Codex do)",
        Error.ReadFailed => "could not read the transcript file",
        Error.NoMessages => "the transcript has no agent messages yet",
        Error.OffsetOutOfRange => "--offset is beyond the number of messages in the transcript",
    };
}

pub fn resultJson(a: std.mem.Allocator, r: ReadResult) []const u8 {
    var buf = std.ArrayList(u8){};
    const w = buf.writer(a);
    // `message` is the newest returned message (backward-compatible single field);
    // `messages` carries all of them, oldest first, when --count > 1.
    const newest = if (r.messages.len > 0) r.messages[r.messages.len - 1] else "";
    w.print("{{\"pane\":{d},\"session\":{d},\"offset\":{d},\"count\":{d},\"total\":{d},\"message\":\"", .{ r.pane, r.session, r.offset, r.messages.len, r.total }) catch {};
    writeJsonStr(w, newest);
    w.writeAll("\",\"messages\":[") catch {};
    for (r.messages, 0..) |m, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.writeAll("\"") catch {};
        writeJsonStr(w, m);
        w.writeAll("\"") catch {};
    }
    w.writeAll("]}") catch {};
    return buf.items;
}

fn writeJsonStr(w: anytype, s: []const u8) void {
    for (s) |ch| switch (ch) {
        '"' => w.writeAll("\\\"") catch {},
        '\\' => w.writeAll("\\\\") catch {},
        '\n' => w.writeAll("\\n") catch {},
        '\r' => w.writeAll("\\r") catch {},
        '\t' => w.writeAll("\\t") catch {},
        else => if (ch < 0x20) {
            w.print("\\u{x:0>4}", .{ch}) catch {};
        } else w.writeByte(ch) catch {},
    };
}

/// CLI entry: print the message (or JSON) and exit.
pub fn run(parsed: IpcRequest) noreturn {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = readTranscript(a, parsed) catch |e| {
        std.fs.File.stderr().writeAll("error: ") catch {};
        std.fs.File.stderr().writeAll(errMsg(e)) catch {};
        std.fs.File.stderr().writeAll("\n") catch {};
        std.process.exit(1);
    };
    const stdout = std.fs.File.stdout();
    if (parsed.json_output) {
        stdout.writeAll(resultJson(a, r)) catch {};
        stdout.writeAll("\n") catch {};
    } else {
        // One message per turn, each newline-terminated; a blank line separates
        // turns. For the default single message this is just the message + "\n".
        for (r.messages, 0..) |m, i| {
            if (i > 0) stdout.writeAll("\n") catch {};
            stdout.writeAll(m) catch {};
            if (m.len == 0 or m[m.len - 1] != '\n') stdout.writeAll("\n") catch {};
        }
    }
    std.process.exit(0);
}

/// MCP entry: return the result JSON (no print/exit).
pub fn runForMcp(a: std.mem.Allocator, parsed: IpcRequest) ![]const u8 {
    const r = try readTranscript(a, parsed);
    return resultJson(a, r);
}

// ---------------------------------------------------------------------------
// Tests — the transcript parser, no socket/file required.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "extracts Claude assistant text messages in order, skipping non-text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t =
        \\{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"first"}]}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"x"}]}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"second"}]}}
    ;
    const msgs = try extractMessages(a, t);
    try testing.expectEqual(@as(usize, 2), msgs.len); // tool-only turn skipped
    try testing.expectEqualStrings("first", msgs[0]);
    try testing.expectEqualStrings("second", msgs[1]);
}

test "extracts Codex response_item assistant messages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t =
        \\{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"q"}]}}
        \\{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}]}}
    ;
    const msgs = try extractMessages(a, t);
    try testing.expectEqual(@as(usize, 1), msgs.len);
    try testing.expectEqualStrings("answer", msgs[0]);
}

test "malformed lines are skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = "not json\n\n{bad\n{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}";
    const msgs = try extractMessages(a, t);
    try testing.expectEqual(@as(usize, 1), msgs.len);
    try testing.expectEqualStrings("ok", msgs[0]);
}

test "offset indexing picks the n-th from last" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t =
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"a"}]}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"b"}]}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"c"}]}}
    ;
    const msgs = try extractMessages(a, t);
    try testing.expectEqualStrings("c", msgs[msgs.len - 1 - 0]); // offset 0 = last
    try testing.expectEqualStrings("b", msgs[msgs.len - 1 - 1]); // offset 1
    try testing.expectEqualStrings("a", msgs[msgs.len - 1 - 2]); // offset 2
}

test "selectWindow: count + offset windowing, clamped to start" {
    // total = 5 messages (indices 0..4).
    // default: last message only.
    try testing.expectEqual(@as(usize, 4), selectWindow(5, 0, 1).start);
    try testing.expectEqual(@as(usize, 5), selectWindow(5, 0, 1).end);
    // last 3 messages.
    try testing.expectEqual(@as(usize, 2), selectWindow(5, 0, 3).start);
    try testing.expectEqual(@as(usize, 5), selectWindow(5, 0, 3).end);
    // count beyond the start clamps to 0 (returns the whole transcript).
    try testing.expectEqual(@as(usize, 0), selectWindow(5, 0, 99).start);
    try testing.expectEqual(@as(usize, 5), selectWindow(5, 0, 99).end);
    // offset shifts the window's newest end back; count extends from there.
    try testing.expectEqual(@as(usize, 1), selectWindow(5, 1, 3).start);
    try testing.expectEqual(@as(usize, 4), selectWindow(5, 1, 3).end);
    // count 0 is treated as 1.
    try testing.expectEqual(@as(usize, 4), selectWindow(5, 0, 0).start);
    try testing.expectEqual(@as(usize, 5), selectWindow(5, 0, 0).end);
}
