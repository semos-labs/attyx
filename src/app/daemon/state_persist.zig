const std = @import("std");
const DaemonSession = @import("session.zig").DaemonSession;
const session_connect = @import("../session_connect.zig");

const max_sessions: usize = 32;

// ── State file path ──

pub fn getStatePath(buf: *[512]u8) ?[]const u8 {
    return session_connect.statePath(buf, "recent{s}.json");
}

fn ensureParentDir(path: []const u8) void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        std.fs.makeDirAbsolute(path[0..i]) catch {};
    }
}

// ── Save ──

pub fn save(
    sessions: *[max_sessions]?DaemonSession,
    next_session_id: u32,
    next_pane_id: u32,
) void {
    var path_buf: [512]u8 = undefined;
    const path = getStatePath(&path_buf) orelse return;
    ensureParentDir(path);

    // Count dead sessions
    var dead_count: usize = 0;
    for (sessions) |slot| {
        if (slot) |s| {
            if (!s.alive) dead_count += 1;
        }
    }

    // Build JSON into a buffer
    var buf: [32768]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.print("{{\n  \"next_session_id\": {d},\n  \"next_pane_id\": {d},\n  \"sessions\": [", .{ next_session_id, next_pane_id }) catch return;

    var first = true;
    for (sessions) |slot| {
        if (slot) |s| {
            if (s.alive) continue;
            if (!first) w.writeAll(",") catch return;
            first = false;
            writeSession(w, &s) catch return;
        }
    }

    w.writeAll("\n  ]\n}\n") catch return;

    const json = fbs.getWritten();

    // Atomic write: write to temp then rename
    var tmp_path_buf: [520]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path}) catch return;
    const file = std.fs.createFileAbsolute(tmp_path, .{}) catch return;
    file.writeAll(json) catch {
        file.close();
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        return;
    };
    file.close();
    std.fs.renameAbsolute(tmp_path, path) catch {
        std.fs.deleteFileAbsolute(tmp_path) catch {};
    };
}

fn writeSession(w: anytype, s: *const DaemonSession) !void {
    const name = s.name[0..s.name_len];
    const cwd = s.cwd[0..s.cwd_len];
    try w.print("\n    {{\n      \"id\": {d},\n      \"name\": \"", .{s.id});
    try writeJsonString(w, name);
    try w.writeAll("\",\n      \"cwd\": \"");
    try writeJsonString(w, cwd);
    try w.writeAll("\",\n      \"shell\": \"");
    try writeJsonString(w, s.shell[0..s.shell_len]);
    try w.print("\",\n      \"rows\": {d},\n      \"cols\": {d},\n      \"layout\": \"", .{ s.rows, s.cols });
    // Hex-encode layout blob
    const hex_chars = "0123456789abcdef";
    for (s.layout_data[0..s.layout_len]) |byte| {
        try w.writeByte(hex_chars[byte >> 4]);
        try w.writeByte(hex_chars[byte & 0x0f]);
    }
    try w.writeAll("\"\n    }");
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
}

// ── Load ──

pub fn load(
    sessions: *[max_sessions]?DaemonSession,
    next_session_id: *u32,
    next_pane_id: *u32,
) void {
    var path_buf: [512]u8 = undefined;
    const path = getStatePath(&path_buf) orelse return;

    var file_buf: [32768]u8 = undefined;
    const json = readFileInto(path, &file_buf) orelse return;

    // Parse next_session_id
    if (findJsonInt(json, "next_session_id")) |v| {
        next_session_id.* = v;
    }
    if (findJsonInt(json, "next_pane_id")) |v| {
        next_pane_id.* = v;
    }

    // Parse sessions array
    const sessions_start = std.mem.indexOf(u8, json, "\"sessions\"") orelse return;
    const arr_start = std.mem.indexOfScalarPos(u8, json, sessions_start, '[') orelse return;
    var pos = arr_start + 1;

    while (pos < json.len) {
        // Find next object
        const obj_start = std.mem.indexOfScalarPos(u8, json, pos, '{') orelse break;
        const obj_end = std.mem.indexOfScalarPos(u8, json, obj_start, '}') orelse break;
        const obj = json[obj_start .. obj_end + 1];
        pos = obj_end + 1;

        // Find a free slot
        const slot_idx = for (sessions, 0..) |slot, i| {
            if (slot == null) break i;
        } else break;

        var s = DaemonSession{
            .id = 0,
            .rows = 24,
            .cols = 80,
            .alive = false,
        };

        if (findJsonInt(obj, "id")) |v| s.id = v;
        if (findJsonInt(obj, "rows")) |v| s.rows = @intCast(@min(v, 0xFFFF));
        if (findJsonInt(obj, "cols")) |v| s.cols = @intCast(@min(v, 0xFFFF));

        if (findJsonString(obj, "name")) |name| {
            const nlen: u8 = @intCast(@min(name.len, 64));
            @memcpy(s.name[0..nlen], name[0..nlen]);
            s.name_len = nlen;
        }
        if (findJsonString(obj, "cwd")) |cwd| {
            const clen: u16 = @intCast(@min(cwd.len, 1024));
            @memcpy(s.cwd[0..clen], cwd[0..clen]);
            s.cwd_len = clen;
        }
        if (findJsonString(obj, "shell")) |shell| {
            const slen: u16 = @intCast(@min(shell.len, 256));
            @memcpy(s.shell[0..slen], shell[0..slen]);
            s.shell_len = slen;
        }
        if (findJsonString(obj, "layout")) |hex| {
            const decoded_len = @min(hex.len / 2, s.layout_data.len);
            for (0..decoded_len) |i| {
                const hi: u8 = hexVal(hex[i * 2]) orelse break;
                const lo: u8 = hexVal(hex[i * 2 + 1]) orelse break;
                s.layout_data[i] = (hi << 4) | lo;
            }
            s.layout_len = @intCast(decoded_len);
        }

        sessions[slot_idx] = s;
    }

    // Delete state file after successful load — it's consumed.
    std.fs.deleteFileAbsolute(path) catch {};
}

// ── Minimal JSON helpers ──

fn readFileInto(path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const n = file.readAll(buf) catch return null;
    if (n == 0) return null;
    return buf[0..n];
}

fn findJsonInt(json: []const u8, key: []const u8) ?u32 {
    // Search for "key": <number>
    var search_buf: [68]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const colon_pos = std.mem.indexOfScalarPos(u8, json, key_pos + needle.len, ':') orelse return null;
    // Skip whitespace after colon
    var i = colon_pos + 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\n' or json[i] == '\r' or json[i] == '\t')) : (i += 1) {}
    // Parse number
    var val: u32 = 0;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {
        val = val *% 10 +% (json[i] - '0');
    }
    return val;
}

fn findJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [68]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const colon_pos = std.mem.indexOfScalarPos(u8, json, key_pos + needle.len, ':') orelse return null;
    // Find opening quote
    const open_quote = std.mem.indexOfScalarPos(u8, json, colon_pos + 1, '"') orelse return null;
    // Find closing quote (skip escaped quotes)
    var i = open_quote + 1;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\') {
            i += 1; // skip escaped char
            continue;
        }
        if (json[i] == '"') return json[open_quote + 1 .. i];
    }
    return null;
}

fn hexVal(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

// ── Tests ──

test "hex round-trip" {
    const input = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    var hex_buf: [8]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (input, 0..) |byte, i| {
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    for (0..4) |i| {
        const hi = hexVal(hex_buf[i * 2]).?;
        const lo = hexVal(hex_buf[i * 2 + 1]).?;
        const decoded = (@as(u8, hi) << 4) | lo;
        try std.testing.expectEqual(input[i], decoded);
    }
}

test "findJsonInt parses values" {
    const json =
        \\{ "next_session_id": 42, "next_pane_id": 7 }
    ;
    try std.testing.expectEqual(@as(u32, 42), findJsonInt(json, "next_session_id").?);
    try std.testing.expectEqual(@as(u32, 7), findJsonInt(json, "next_pane_id").?);
    try std.testing.expectEqual(@as(?u32, null), findJsonInt(json, "missing"));
}

test "findJsonString parses values" {
    const json =
        \\{ "name": "hello", "cwd": "/tmp/foo" }
    ;
    try std.testing.expectEqualStrings("hello", findJsonString(json, "name").?);
    try std.testing.expectEqualStrings("/tmp/foo", findJsonString(json, "cwd").?);
}
