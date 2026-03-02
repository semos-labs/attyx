const std = @import("std");

/// Session protocol message types.
/// Client → Daemon: 0x01–0x07
/// Daemon → Client: 0x81–0x86
pub const MessageType = enum(u8) {
    // Client → Daemon
    create = 0x01,
    list = 0x02,
    attach = 0x03,
    detach = 0x04,
    input = 0x05,
    resize = 0x06,
    kill = 0x07,

    // Daemon → Client
    created = 0x81,
    session_list = 0x82,
    attached = 0x83,
    output = 0x84,
    session_died = 0x85,
    err = 0x86,
};

pub const header_size: usize = 5; // 4-byte payload length + 1-byte message type

/// Encode a message header into buf. Returns header_size.
pub fn encodeHeader(buf: *[header_size]u8, msg_type: MessageType, payload_len: u32) void {
    std.mem.writeInt(u32, buf[0..4], payload_len, .little);
    buf[4] = @intFromEnum(msg_type);
}

/// Decode a message header. Returns message type and payload length.
pub fn decodeHeader(buf: *const [header_size]u8) !struct { msg_type: MessageType, payload_len: u32 } {
    const payload_len = std.mem.readInt(u32, buf[0..4], .little);
    const raw_type = buf[4];
    const msg_type = std.meta.intToEnum(MessageType, raw_type) catch return error.InvalidMessageType;
    return .{ .msg_type = msg_type, .payload_len = payload_len };
}

// ── Encode helpers ──

/// Encode Create message payload: name_len:u16, name:[N]u8, rows:u16, cols:u16
pub fn encodeCreate(buf: []u8, name: []const u8, rows: u16, cols: u16) ![]u8 {
    const name_len: u16 = @intCast(@min(name.len, 64));
    const total = 2 + name_len + 2 + 2;
    if (buf.len < total) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[0..2], name_len, .little);
    @memcpy(buf[2 .. 2 + name_len], name[0..name_len]);
    std.mem.writeInt(u16, buf[2 + name_len ..][0..2], rows, .little);
    std.mem.writeInt(u16, buf[4 + name_len ..][0..2], cols, .little);
    return buf[0..total];
}

/// Encode Attach message payload: session_id:u32, rows:u16, cols:u16
pub fn encodeAttach(buf: []u8, session_id: u32, rows: u16, cols: u16) ![]u8 {
    if (buf.len < 8) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[0..4], session_id, .little);
    std.mem.writeInt(u16, buf[4..6], rows, .little);
    std.mem.writeInt(u16, buf[6..8], cols, .little);
    return buf[0..8];
}

/// Encode Resize message payload: rows:u16, cols:u16
pub fn encodeResize(buf: []u8, rows: u16, cols: u16) ![]u8 {
    if (buf.len < 4) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[0..2], rows, .little);
    std.mem.writeInt(u16, buf[2..4], cols, .little);
    return buf[0..4];
}

/// Encode Kill message payload: session_id:u32
pub fn encodeKill(buf: []u8, session_id: u32) ![]u8 {
    if (buf.len < 4) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[0..4], session_id, .little);
    return buf[0..4];
}

/// Encode Created response payload: session_id:u32
pub fn encodeCreated(buf: []u8, session_id: u32) ![]u8 {
    if (buf.len < 4) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[0..4], session_id, .little);
    return buf[0..4];
}

/// Encode Attached response payload: session_id:u32
pub fn encodeAttached(buf: []u8, session_id: u32) ![]u8 {
    if (buf.len < 4) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[0..4], session_id, .little);
    return buf[0..4];
}

/// Encode SessionDied response: session_id:u32, exit_code:u8
pub fn encodeSessionDied(buf: []u8, session_id: u32, exit_code: u8) ![]u8 {
    if (buf.len < 5) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[0..4], session_id, .little);
    buf[4] = exit_code;
    return buf[0..5];
}

/// Encode Error response: code:u8, msg_len:u16, msg:[N]u8
pub fn encodeError(buf: []u8, code: u8, msg: []const u8) ![]u8 {
    const msg_len: u16 = @intCast(@min(msg.len, 256));
    const total = 1 + 2 + msg_len;
    if (buf.len < total) return error.BufferTooSmall;
    buf[0] = code;
    std.mem.writeInt(u16, buf[1..3], msg_len, .little);
    @memcpy(buf[3 .. 3 + msg_len], msg[0..msg_len]);
    return buf[0..total];
}

// ── Decode helpers ──

pub const CreateMsg = struct { name: []const u8, rows: u16, cols: u16 };

pub fn decodeCreate(payload: []const u8) !CreateMsg {
    if (payload.len < 6) return error.PayloadTooShort;
    const name_len = std.mem.readInt(u16, payload[0..2], .little);
    if (payload.len < 2 + @as(usize, name_len) + 4) return error.PayloadTooShort;
    return .{
        .name = payload[2 .. 2 + name_len],
        .rows = std.mem.readInt(u16, payload[2 + name_len ..][0..2], .little),
        .cols = std.mem.readInt(u16, payload[4 + name_len ..][0..2], .little),
    };
}

pub const AttachMsg = struct { session_id: u32, rows: u16, cols: u16 };

pub fn decodeAttach(payload: []const u8) !AttachMsg {
    if (payload.len < 8) return error.PayloadTooShort;
    return .{
        .session_id = std.mem.readInt(u32, payload[0..4], .little),
        .rows = std.mem.readInt(u16, payload[4..6], .little),
        .cols = std.mem.readInt(u16, payload[6..8], .little),
    };
}

pub const ResizeMsg = struct { rows: u16, cols: u16 };

pub fn decodeResize(payload: []const u8) !ResizeMsg {
    if (payload.len < 4) return error.PayloadTooShort;
    return .{
        .rows = std.mem.readInt(u16, payload[0..2], .little),
        .cols = std.mem.readInt(u16, payload[2..4], .little),
    };
}

pub fn decodeKill(payload: []const u8) !u32 {
    if (payload.len < 4) return error.PayloadTooShort;
    return std.mem.readInt(u32, payload[0..4], .little);
}

pub fn decodeCreated(payload: []const u8) !u32 {
    if (payload.len < 4) return error.PayloadTooShort;
    return std.mem.readInt(u32, payload[0..4], .little);
}

pub fn decodeAttachedId(payload: []const u8) !u32 {
    if (payload.len < 4) return error.PayloadTooShort;
    return std.mem.readInt(u32, payload[0..4], .little);
}

pub const SessionDiedMsg = struct { session_id: u32, exit_code: u8 };

pub fn decodeSessionDied(payload: []const u8) !SessionDiedMsg {
    if (payload.len < 5) return error.PayloadTooShort;
    return .{
        .session_id = std.mem.readInt(u32, payload[0..4], .little),
        .exit_code = payload[4],
    };
}

pub const ErrorMsg = struct { code: u8, msg: []const u8 };

pub fn decodeError(payload: []const u8) !ErrorMsg {
    if (payload.len < 3) return error.PayloadTooShort;
    const msg_len = std.mem.readInt(u16, payload[1..3], .little);
    if (payload.len < 3 + @as(usize, msg_len)) return error.PayloadTooShort;
    return .{ .code = payload[0], .msg = payload[3 .. 3 + msg_len] };
}

/// Encode a full message (header + payload) into buf. Returns total bytes used.
pub fn encodeMessage(buf: []u8, msg_type: MessageType, payload: []const u8) ![]u8 {
    const total = header_size + payload.len;
    if (buf.len < total) return error.BufferTooSmall;
    encodeHeader(buf[0..header_size], msg_type, @intCast(payload.len));
    @memcpy(buf[header_size .. header_size + payload.len], payload);
    return buf[0..total];
}

/// Session list entry for encoding/decoding SessionList messages.
pub const SessionEntry = struct {
    id: u32,
    name: []const u8,
    alive: bool,
};

/// Encode SessionList payload: count:u16, entries:[{id:u32, name_len:u16, name:[N]u8, alive:u8}]
pub fn encodeSessionList(buf: []u8, entries: []const SessionEntry) ![]u8 {
    var pos: usize = 0;
    if (buf.len < 2) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[0..2], @intCast(entries.len), .little);
    pos = 2;
    for (entries) |entry| {
        const name_len: u16 = @intCast(@min(entry.name.len, 64));
        const entry_size = 4 + 2 + name_len + 1;
        if (pos + entry_size > buf.len) return error.BufferTooSmall;
        std.mem.writeInt(u32, buf[pos..][0..4], entry.id, .little);
        pos += 4;
        std.mem.writeInt(u16, buf[pos..][0..2], name_len, .little);
        pos += 2;
        @memcpy(buf[pos .. pos + name_len], entry.name[0..name_len]);
        pos += name_len;
        buf[pos] = if (entry.alive) 1 else 0;
        pos += 1;
    }
    return buf[0..pos];
}

/// Decoded session list entry (references payload slice — not owned).
pub const DecodedListEntry = struct {
    id: u32,
    name: []const u8,
    alive: bool,
};

/// Decode SessionList payload: count:u16, entries:[{id:u32, name_len:u16, name:[N]u8, alive:u8}]
/// Returns number of entries decoded into `out`.
pub fn decodeSessionList(payload: []const u8, out: []DecodedListEntry) !u16 {
    if (payload.len < 2) return error.PayloadTooShort;
    const count = std.mem.readInt(u16, payload[0..2], .little);
    var pos: usize = 2;
    var decoded: u16 = 0;
    for (0..count) |_| {
        if (decoded >= out.len) break;
        if (pos + 7 > payload.len) return error.PayloadTooShort; // min: id(4) + name_len(2) + alive(1)
        const id = std.mem.readInt(u32, payload[pos..][0..4], .little);
        pos += 4;
        const name_len = std.mem.readInt(u16, payload[pos..][0..2], .little);
        pos += 2;
        if (pos + name_len + 1 > payload.len) return error.PayloadTooShort;
        const name = payload[pos .. pos + name_len];
        pos += name_len;
        const alive = payload[pos] != 0;
        pos += 1;
        out[decoded] = .{ .id = id, .name = name, .alive = alive };
        decoded += 1;
    }
    return decoded;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "header round-trip" {
    var buf: [header_size]u8 = undefined;
    encodeHeader(&buf, .create, 42);
    const h = try decodeHeader(&buf);
    try std.testing.expectEqual(MessageType.create, h.msg_type);
    try std.testing.expectEqual(@as(u32, 42), h.payload_len);
}

test "create round-trip" {
    var buf: [128]u8 = undefined;
    const payload = try encodeCreate(&buf, "my-session", 24, 80);
    const msg = try decodeCreate(payload);
    try std.testing.expectEqualStrings("my-session", msg.name);
    try std.testing.expectEqual(@as(u16, 24), msg.rows);
    try std.testing.expectEqual(@as(u16, 80), msg.cols);
}

test "attach round-trip" {
    var buf: [128]u8 = undefined;
    const payload = try encodeAttach(&buf, 7, 30, 120);
    const msg = try decodeAttach(payload);
    try std.testing.expectEqual(@as(u32, 7), msg.session_id);
    try std.testing.expectEqual(@as(u16, 30), msg.rows);
    try std.testing.expectEqual(@as(u16, 120), msg.cols);
}

test "resize round-trip" {
    var buf: [128]u8 = undefined;
    const payload = try encodeResize(&buf, 50, 200);
    const msg = try decodeResize(payload);
    try std.testing.expectEqual(@as(u16, 50), msg.rows);
    try std.testing.expectEqual(@as(u16, 200), msg.cols);
}

test "error round-trip" {
    var buf: [128]u8 = undefined;
    const payload = try encodeError(&buf, 3, "not found");
    const msg = try decodeError(payload);
    try std.testing.expectEqual(@as(u8, 3), msg.code);
    try std.testing.expectEqualStrings("not found", msg.msg);
}

test "session_died round-trip" {
    var buf: [128]u8 = undefined;
    const payload = try encodeSessionDied(&buf, 42, 1);
    const msg = try decodeSessionDied(payload);
    try std.testing.expectEqual(@as(u32, 42), msg.session_id);
    try std.testing.expectEqual(@as(u8, 1), msg.exit_code);
}

test "full message encode" {
    var buf: [128]u8 = undefined;
    var payload_buf: [32]u8 = undefined;
    const payload = try encodeResize(&payload_buf, 24, 80);
    const msg = try encodeMessage(&buf, .resize, payload);
    try std.testing.expectEqual(@as(usize, header_size + 4), msg.len);

    const h = try decodeHeader(msg[0..header_size]);
    try std.testing.expectEqual(MessageType.resize, h.msg_type);
    try std.testing.expectEqual(@as(u32, 4), h.payload_len);
}

test "session list round-trip" {
    var buf: [256]u8 = undefined;
    const entries = [_]SessionEntry{
        .{ .id = 1, .name = "shell", .alive = true },
        .{ .id = 2, .name = "vim", .alive = false },
    };
    const payload = try encodeSessionList(&buf, &entries);

    var decoded: [8]DecodedListEntry = undefined;
    const count = try decodeSessionList(payload, &decoded);
    try std.testing.expectEqual(@as(u16, 2), count);
    try std.testing.expectEqual(@as(u32, 1), decoded[0].id);
    try std.testing.expectEqualStrings("shell", decoded[0].name);
    try std.testing.expect(decoded[0].alive);
    try std.testing.expectEqual(@as(u32, 2), decoded[1].id);
    try std.testing.expectEqualStrings("vim", decoded[1].name);
    try std.testing.expect(!decoded[1].alive);
}
