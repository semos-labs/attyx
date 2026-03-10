// Attyx — IPC control protocol
//
// Message types and framing for the per-instance control socket.
// Reuses the same 5-byte framing as the daemon protocol:
//   [4B payload_len LE][1B msg_type][payload...]
//
// Requests: 0x20–0x42   (client → instance)
// Responses: 0xA0–0xA1  (instance → client)

const std = @import("std");

pub const header_size: usize = 5;

pub const MessageType = enum(u8) {
    // ── Tab commands ──
    tab_create = 0x20,
    tab_close = 0x21,
    tab_next = 0x22,
    tab_prev = 0x23,
    tab_select = 0x24,
    tab_move_left = 0x25,
    tab_move_right = 0x26,
    tab_rename = 0x27,

    // ── Split / pane commands ──
    split_vertical = 0x28,
    split_horizontal = 0x29,
    pane_close = 0x2A,
    pane_rotate = 0x2B,
    pane_zoom_toggle = 0x2C,

    // ── Focus commands ──
    focus_up = 0x2D,
    focus_down = 0x2E,
    focus_left = 0x2F,
    focus_right = 0x30,

    // ── Text / IO ──
    send_keys = 0x31,
    send_text = 0x32,
    get_text = 0x33,

    // ── Config ──
    config_reload = 0x34,
    theme_set = 0x35,

    // ── Scroll ──
    scroll_to_top = 0x36,
    scroll_to_bottom = 0x37,
    scroll_page_up = 0x38,
    scroll_page_down = 0x39,

    // ── Query ──
    list = 0x3A,
    list_tabs = 0x40,
    list_splits = 0x41,

    // ── Popup ──
    popup = 0x42,

    // ── Wait variants (--wait flag: hold response until process exits) ──
    tab_create_wait = 0x43,
    split_vertical_wait = 0x44,
    split_horizontal_wait = 0x45,

    // ── Session commands ──
    session_list = 0x3B,
    session_create = 0x3C,
    session_kill = 0x3D,
    session_switch = 0x3E,
    session_rename = 0x3F,

    // ── Responses ──
    success = 0xA0,
    err = 0xA1,
    exit_code = 0xA2, // process exit code (1-byte payload: u8 code)
};

// ---------------------------------------------------------------------------
// Header encode / decode
// ---------------------------------------------------------------------------

pub fn encodeHeader(buf: *[header_size]u8, msg_type: MessageType, payload_len: u32) void {
    std.mem.writeInt(u32, buf[0..4], payload_len, .little);
    buf[4] = @intFromEnum(msg_type);
}

pub fn decodeHeader(buf: *const [header_size]u8) !struct { msg_type: MessageType, payload_len: u32 } {
    const payload_len = std.mem.readInt(u32, buf[0..4], .little);
    const raw_type = buf[4];
    const msg_type = std.meta.intToEnum(MessageType, raw_type) catch return error.InvalidMessageType;
    return .{ .msg_type = msg_type, .payload_len = payload_len };
}

// ---------------------------------------------------------------------------
// Full message encode / decode
// ---------------------------------------------------------------------------

pub fn encodeMessage(buf: []u8, msg_type: MessageType, payload: []const u8) ![]u8 {
    const total = header_size + payload.len;
    if (buf.len < total) return error.BufferTooSmall;
    encodeHeader(buf[0..header_size], msg_type, @intCast(payload.len));
    if (payload.len > 0) @memcpy(buf[header_size .. header_size + payload.len], payload);
    return buf[0..total];
}

/// Encode a success response with JSON payload.
pub fn encodeSuccess(buf: []u8, json: []const u8) ![]u8 {
    return encodeMessage(buf, .success, json);
}

/// Encode an error response: JSON `{"error":"<msg>"}`.
pub fn encodeErrorResponse(buf: []u8, msg: []const u8) ![]u8 {
    // Build JSON in-place after the header
    const prefix = "{\"error\":\"";
    const suffix = "\"}";
    const json_len = prefix.len + msg.len + suffix.len;
    const total = header_size + json_len;
    if (buf.len < total) return error.BufferTooSmall;
    encodeHeader(buf[0..header_size], .err, @intCast(json_len));
    var pos: usize = header_size;
    @memcpy(buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;
    @memcpy(buf[pos .. pos + msg.len], msg);
    pos += msg.len;
    @memcpy(buf[pos .. pos + suffix.len], suffix);
    return buf[0..total];
}

// ---------------------------------------------------------------------------
// Payload helpers
// ---------------------------------------------------------------------------

/// Encode a tab_select payload: tab_index:u8
pub fn encodeTabSelect(buf: []u8, index: u8) ![]u8 {
    return encodeMessage(buf, .tab_select, &.{index});
}

/// Encode send_text / send_keys payload: raw bytes
pub fn encodeText(buf: []u8, msg_type: MessageType, text: []const u8) ![]u8 {
    return encodeMessage(buf, msg_type, text);
}

/// Encode tab_create with optional command string
pub fn encodeTabCreate(buf: []u8, cmd: []const u8) ![]u8 {
    return encodeMessage(buf, .tab_create, cmd);
}

/// Encode session_kill / session_switch payload: session_id:u32
pub fn encodeSessionId(buf: []u8, msg_type: MessageType, session_id: u32) ![]u8 {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, session_id, .little);
    return encodeMessage(buf, msg_type, &payload);
}

/// Encode session_rename payload: session_id:u32, name
pub fn encodeSessionRename(buf: []u8, session_id: u32, name: []const u8) ![]u8 {
    const total_payload = 4 + name.len;
    if (buf.len < header_size + total_payload) return error.BufferTooSmall;
    encodeHeader(buf[0..header_size], .session_rename, @intCast(total_payload));
    std.mem.writeInt(u32, buf[header_size..][0..4], session_id, .little);
    @memcpy(buf[header_size + 4 .. header_size + 4 + name.len], name);
    return buf[0 .. header_size + total_payload];
}

/// Encode theme_set payload: theme name string
pub fn encodeThemeSet(buf: []u8, name: []const u8) ![]u8 {
    return encodeMessage(buf, .theme_set, name);
}

// ---------------------------------------------------------------------------
// Read helpers (for client: read full response from fd)
// ---------------------------------------------------------------------------

/// Read exactly `len` bytes from fd. Returns error on short read / disconnect.
pub fn readExact(fd: std.posix.fd_t, out: []u8) !void {
    var total: usize = 0;
    while (total < out.len) {
        const n = std.posix.read(fd, out[total..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.ConnectionClosed;
        total += n;
    }
}

/// Write all bytes to fd.
pub fn writeAll(fd: std.posix.fd_t, data: []const u8) !void {
    var total: usize = 0;
    while (total < data.len) {
        const n = std.posix.write(fd, data[total..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        total += n;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "header round-trip" {
    var buf: [header_size]u8 = undefined;
    encodeHeader(&buf, .tab_create, 42);
    const h = try decodeHeader(&buf);
    try std.testing.expectEqual(MessageType.tab_create, h.msg_type);
    try std.testing.expectEqual(@as(u32, 42), h.payload_len);
}

test "message round-trip" {
    var buf: [256]u8 = undefined;
    const msg = try encodeMessage(&buf, .send_text, "hello");
    try std.testing.expectEqual(@as(usize, header_size + 5), msg.len);
    const h = try decodeHeader(msg[0..header_size]);
    try std.testing.expectEqual(MessageType.send_text, h.msg_type);
    try std.testing.expectEqual(@as(u32, 5), h.payload_len);
    try std.testing.expectEqualStrings("hello", msg[header_size..]);
}

test "success response round-trip" {
    var buf: [256]u8 = undefined;
    const msg = try encodeSuccess(&buf, "{\"ok\":true}");
    const h = try decodeHeader(msg[0..header_size]);
    try std.testing.expectEqual(MessageType.success, h.msg_type);
    try std.testing.expectEqualStrings("{\"ok\":true}", msg[header_size..]);
}

test "error response round-trip" {
    var buf: [256]u8 = undefined;
    const msg = try encodeErrorResponse(&buf, "not found");
    const h = try decodeHeader(msg[0..header_size]);
    try std.testing.expectEqual(MessageType.err, h.msg_type);
    try std.testing.expectEqualStrings("{\"error\":\"not found\"}", msg[header_size..]);
}

test "tab_select encode" {
    var buf: [64]u8 = undefined;
    const msg = try encodeTabSelect(&buf, 3);
    const h = try decodeHeader(msg[0..header_size]);
    try std.testing.expectEqual(MessageType.tab_select, h.msg_type);
    try std.testing.expectEqual(@as(u8, 3), msg[header_size]);
}

test "session_id encode" {
    var buf: [64]u8 = undefined;
    const msg = try encodeSessionId(&buf, .session_kill, 42);
    const h = try decodeHeader(msg[0..header_size]);
    try std.testing.expectEqual(MessageType.session_kill, h.msg_type);
    const sid = std.mem.readInt(u32, msg[header_size..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 42), sid);
}
