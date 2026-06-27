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
const protocol = @import("protocol.zig");
const client = @import("client.zig");
const IpcRequest = @import("../config/cli_ipc.zig").IpcRequest;
const json = std.json;

const max_transcript_bytes = 64 * 1024 * 1024;

const Error = error{ NoInstance, NoAgent, NoTranscript, ReadFailed, NoMessages, OffsetOutOfRange };

const Usage = struct { transcript_path: ?[]const u8 = null };
const Rec = struct { pane_id: u32 = 0, session: u32 = 0, usage: Usage = .{} };

pub const ReadResult = struct {
    pane: u32,
    session: u32,
    offset: u32,
    total: usize, // assistant messages found
    message: []const u8,
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

/// Look up the pane's transcript path via `list agents --json` (attached window,
/// or the daemon when `-s` targets a session). Path returned is owned by `a`.
fn transcriptPath(a: std.mem.Allocator, parsed: IpcRequest) Error![]const u8 {
    const req = IpcRequest{ .command = .list_agents, .pane_id = parsed.pane_id, .json_output = true, .target_session = parsed.target_session, .target_pid = parsed.target_pid };
    var body: []const u8 = undefined;
    if (parsed.target_session != 0) {
        const r = @import("client_daemon.zig").call(a, req);
        if (r.is_error) return Error.NoInstance;
        body = r.text;
    } else {
        var sock_buf: [256]u8 = undefined;
        const sock = client.discoverSocket(&sock_buf, parsed.target_pid) orelse return Error.NoInstance;
        var rb: [protocol.header_size + 64]u8 = undefined;
        const request = client.buildRequest(&rb, req) catch return Error.NoInstance;
        const resp_buf = a.alloc(u8, 1 << 16) catch return Error.NoInstance;
        const resp = client.sendCommand(sock, request, resp_buf) catch return Error.NoInstance;
        if (resp.msg_type != .success) return Error.NoInstance;
        body = resp.payload;
    }
    const arr = json.parseFromSliceLeaky([]Rec, a, std.mem.trim(u8, body, " \t\r\n"), .{ .ignore_unknown_fields = true }) catch return Error.NoAgent;
    for (arr) |rec| {
        if (rec.pane_id == parsed.pane_id) {
            const p = rec.usage.transcript_path orelse return Error.NoTranscript;
            if (p.len == 0) return Error.NoTranscript;
            return p;
        }
    }
    return Error.NoAgent;
}

fn readTranscript(a: std.mem.Allocator, parsed: IpcRequest) Error!ReadResult {
    const path = try transcriptPath(a, parsed);
    const file = std.fs.cwd().openFile(path, .{}) catch return Error.ReadFailed;
    defer file.close();
    const bytes = file.readToEndAlloc(a, max_transcript_bytes) catch return Error.ReadFailed;
    const msgs = extractMessages(a, bytes) catch return Error.ReadFailed;
    if (msgs.len == 0) return Error.NoMessages;
    if (parsed.agent_offset >= msgs.len) return Error.OffsetOutOfRange;
    const idx = msgs.len - 1 - parsed.agent_offset;
    return .{ .pane = parsed.pane_id, .session = parsed.target_session, .offset = parsed.agent_offset, .total = msgs.len, .message = msgs[idx] };
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
    w.print("{{\"pane\":{d},\"session\":{d},\"offset\":{d},\"total\":{d},\"message\":\"", .{ r.pane, r.session, r.offset, r.total }) catch {};
    writeJsonStr(w, r.message);
    w.writeAll("\"}") catch {};
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
        stdout.writeAll(r.message) catch {};
        if (r.message.len == 0 or r.message[r.message.len - 1] != '\n') stdout.writeAll("\n") catch {};
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
