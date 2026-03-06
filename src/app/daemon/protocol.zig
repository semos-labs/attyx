const std = @import("std");

/// Session protocol message types.
/// Client → Daemon: 0x01–0x0D
/// Daemon → Client: 0x81–0x89
pub const MessageType = enum(u8) {
    // Client → Daemon (session management)
    create = 0x01,
    list = 0x02,
    attach = 0x03,
    detach = 0x04,
    kill = 0x07,

    // Client → Daemon (pane-multiplexed)
    create_pane = 0x08,
    close_pane = 0x09,
    focus_panes = 0x0A,
    pane_input = 0x0B,
    pane_resize = 0x0C,
    save_layout = 0x0D,
    rename = 0x0E,
    hello = 0x0F,
    set_theme_colors = 0x10,

    // Daemon → Client
    created = 0x81,
    session_list = 0x82,
    attached = 0x83,
    err = 0x86,
    pane_created = 0x87,
    pane_output = 0x88,
    pane_died = 0x89,
    pane_proc_name = 0x8A,
    replay_end = 0x8B,
    layout_sync = 0x8C,
    hello_ack = 0x8D,
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

/// Encode Create message payload: name_len:u16, name:[N]u8, rows:u16, cols:u16, cwd_len:u16, cwd:[M]u8, shell_len:u16, shell:[K]u8
pub fn encodeCreate(buf: []u8, name: []const u8, rows: u16, cols: u16, cwd: []const u8, shell: []const u8) ![]u8 {
    const name_len: u16 = @intCast(@min(name.len, 64));
    const cwd_len: u16 = @intCast(@min(cwd.len, 4096));
    const shell_len: u16 = @intCast(@min(shell.len, 256));
    const total = 2 + name_len + 2 + 2 + 2 + cwd_len + 2 + shell_len;
    if (buf.len < total) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[0..2], name_len, .little);
    @memcpy(buf[2 .. 2 + name_len], name[0..name_len]);
    std.mem.writeInt(u16, buf[2 + name_len ..][0..2], rows, .little);
    std.mem.writeInt(u16, buf[4 + name_len ..][0..2], cols, .little);
    const cwd_off = 6 + @as(usize, name_len);
    std.mem.writeInt(u16, buf[cwd_off..][0..2], cwd_len, .little);
    @memcpy(buf[cwd_off + 2 .. cwd_off + 2 + cwd_len], cwd[0..cwd_len]);
    const shell_off = cwd_off + 2 + cwd_len;
    std.mem.writeInt(u16, buf[shell_off..][0..2], shell_len, .little);
    @memcpy(buf[shell_off + 2 .. shell_off + 2 + shell_len], shell[0..shell_len]);
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

/// Encode Kill message payload: session_id:u32
pub fn encodeKill(buf: []u8, session_id: u32) ![]u8 {
    if (buf.len < 4) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[0..4], session_id, .little);
    return buf[0..4];
}

/// Encode Rename message payload: session_id:u32, name_len:u16, name:[N]u8
pub fn encodeRename(buf: []u8, session_id: u32, new_name: []const u8) ![]u8 {
    const name_len: u16 = @intCast(@min(new_name.len, 64));
    const total: usize = 4 + 2 + name_len;
    if (buf.len < total) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[0..4], session_id, .little);
    std.mem.writeInt(u16, buf[4..6], name_len, .little);
    @memcpy(buf[6 .. 6 + name_len], new_name[0..name_len]);
    return buf[0..total];
}

pub const RenameMsg = struct { session_id: u32, name: []const u8 };

pub fn decodeRename(payload: []const u8) !RenameMsg {
    if (payload.len < 6) return error.PayloadTooShort;
    const session_id = std.mem.readInt(u32, payload[0..4], .little);
    const name_len = std.mem.readInt(u16, payload[4..6], .little);
    if (payload.len < 6 + @as(usize, name_len)) return error.PayloadTooShort;
    return .{ .session_id = session_id, .name = payload[6 .. 6 + name_len] };
}

/// Encode Created response payload: session_id:u32
pub fn encodeCreated(buf: []u8, session_id: u32) ![]u8 {
    if (buf.len < 4) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[0..4], session_id, .little);
    return buf[0..4];
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

pub const CreateMsg = struct { name: []const u8, rows: u16, cols: u16, cwd: []const u8, shell: []const u8 };

pub fn decodeCreate(payload: []const u8) !CreateMsg {
    if (payload.len < 6) return error.PayloadTooShort;
    const name_len = std.mem.readInt(u16, payload[0..2], .little);
    if (payload.len < 2 + @as(usize, name_len) + 4) return error.PayloadTooShort;
    const after_cols = 6 + @as(usize, name_len);
    // CWD field: cwd_len:u16, cwd:[M]u8 (optional for backward compat)
    var cwd: []const u8 = "";
    var after_cwd: usize = after_cols;
    if (payload.len >= after_cols + 2) {
        const cwd_len = std.mem.readInt(u16, payload[after_cols..][0..2], .little);
        if (payload.len >= after_cols + 2 + cwd_len) {
            cwd = payload[after_cols + 2 .. after_cols + 2 + cwd_len];
            after_cwd = after_cols + 2 + cwd_len;
        }
    }
    // Shell field: shell_len:u16, shell:[K]u8 (optional for backward compat)
    var shell: []const u8 = "";
    if (payload.len >= after_cwd + 2) {
        const shell_len = std.mem.readInt(u16, payload[after_cwd..][0..2], .little);
        if (payload.len >= after_cwd + 2 + shell_len) {
            shell = payload[after_cwd + 2 .. after_cwd + 2 + shell_len];
        }
    }
    return .{
        .name = payload[2 .. 2 + name_len],
        .rows = std.mem.readInt(u16, payload[2 + name_len ..][0..2], .little),
        .cols = std.mem.readInt(u16, payload[4 + name_len ..][0..2], .little),
        .cwd = cwd,
        .shell = shell,
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

pub fn decodeKill(payload: []const u8) !u32 {
    if (payload.len < 4) return error.PayloadTooShort;
    return std.mem.readInt(u32, payload[0..4], .little);
}

pub fn decodeCreated(payload: []const u8) !u32 {
    if (payload.len < 4) return error.PayloadTooShort;
    return std.mem.readInt(u32, payload[0..4], .little);
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

// ── V2 Encode helpers (pane-multiplexed) ──

/// Encode CreatePane payload: rows:u16, cols:u16
pub fn encodeCreatePane(buf: []u8, rows: u16, cols: u16, cwd: []const u8) ![]u8 {
    const cwd_len: u16 = @intCast(@min(cwd.len, 4096));
    const total: usize = 4 + 2 + cwd_len;
    if (buf.len < total) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[0..2], rows, .little);
    std.mem.writeInt(u16, buf[2..4], cols, .little);
    std.mem.writeInt(u16, buf[4..6], cwd_len, .little);
    if (cwd_len > 0) @memcpy(buf[6 .. 6 + cwd_len], cwd[0..cwd_len]);
    return buf[0..total];
}

/// Encode ClosePane payload: pane_id:u32
pub fn encodeClosePane(buf: []u8, pane_id: u32) ![]u8 {
    if (buf.len < 4) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[0..4], pane_id, .little);
    return buf[0..4];
}

/// Encode FocusPanes payload: count:u8, pane_ids:[N]u32
pub fn encodeFocusPanes(buf: []u8, pane_ids: []const u32) ![]u8 {
    const count: u8 = @intCast(@min(pane_ids.len, 32));
    const total: usize = 1 + @as(usize, count) * 4;
    if (buf.len < total) return error.BufferTooSmall;
    buf[0] = count;
    for (0..count) |i| {
        std.mem.writeInt(u32, buf[1 + i * 4 ..][0..4], pane_ids[i], .little);
    }
    return buf[0..total];
}

/// Encode PaneInput payload: pane_id:u32, bytes:[N]u8
pub fn encodePaneInput(buf: []u8, pane_id: u32, bytes: []const u8) ![]u8 {
    const total = 4 + bytes.len;
    if (buf.len < total) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[0..4], pane_id, .little);
    @memcpy(buf[4 .. 4 + bytes.len], bytes);
    return buf[0..total];
}

/// Encode PaneResize payload: pane_id:u32, rows:u16, cols:u16
pub fn encodePaneResize(buf: []u8, pane_id: u32, rows: u16, cols: u16) ![]u8 {
    if (buf.len < 8) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[0..4], pane_id, .little);
    std.mem.writeInt(u16, buf[4..6], rows, .little);
    std.mem.writeInt(u16, buf[6..8], cols, .little);
    return buf[0..8];
}

/// Encode PaneCreated response payload: pane_id:u32
pub fn encodePaneCreated(buf: []u8, pane_id: u32) ![]u8 {
    if (buf.len < 4) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[0..4], pane_id, .little);
    return buf[0..4];
}

/// Encode PaneDied response: pane_id:u32, exit_code:u8
pub fn encodePaneDied(buf: []u8, pane_id: u32, exit_code: u8) ![]u8 {
    if (buf.len < 5) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[0..4], pane_id, .little);
    buf[4] = exit_code;
    return buf[0..5];
}

/// Encode SessionAttachedV2 payload:
///   session_id:u32, layout_len:u16, layout:[N]u8, pane_count:u8, pane_ids:[N]u32
pub fn encodeAttachedV2(
    buf: []u8,
    session_id: u32,
    layout_data: []const u8,
    pane_ids: []const u32,
) ![]u8 {
    const layout_len: u16 = @intCast(@min(layout_data.len, 4096));
    const pane_count: u8 = @intCast(@min(pane_ids.len, 32));
    const total: usize = 4 + 2 + layout_len + 1 + @as(usize, pane_count) * 4;
    if (buf.len < total) return error.BufferTooSmall;

    std.mem.writeInt(u32, buf[0..4], session_id, .little);
    std.mem.writeInt(u16, buf[4..6], layout_len, .little);
    @memcpy(buf[6 .. 6 + layout_len], layout_data[0..layout_len]);
    var pos: usize = 6 + layout_len;
    buf[pos] = pane_count;
    pos += 1;
    for (0..pane_count) |i| {
        std.mem.writeInt(u32, buf[pos..][0..4], pane_ids[i], .little);
        pos += 4;
    }
    return buf[0..pos];
}

// ── V2 Decode helpers ──

pub const CreatePaneMsg = struct { rows: u16, cols: u16, cwd: []const u8 };

pub fn decodeCreatePane(payload: []const u8) !CreatePaneMsg {
    if (payload.len < 4) return error.PayloadTooShort;
    const rows = std.mem.readInt(u16, payload[0..2], .little);
    const cols = std.mem.readInt(u16, payload[2..4], .little);
    // CWD field is optional for backward compat with old clients.
    if (payload.len >= 6) {
        const cwd_len = std.mem.readInt(u16, payload[4..6], .little);
        if (payload.len >= 6 + @as(usize, cwd_len)) {
            return .{ .rows = rows, .cols = cols, .cwd = payload[6 .. 6 + cwd_len] };
        }
    }
    return .{ .rows = rows, .cols = cols, .cwd = "" };
}

pub fn decodeClosePane(payload: []const u8) !u32 {
    if (payload.len < 4) return error.PayloadTooShort;
    return std.mem.readInt(u32, payload[0..4], .little);
}

pub const FocusPanesMsg = struct {
    count: u8,
    pane_ids: [32]u32,
};

pub fn decodeFocusPanes(payload: []const u8) !FocusPanesMsg {
    if (payload.len < 1) return error.PayloadTooShort;
    const count = payload[0];
    if (payload.len < 1 + @as(usize, count) * 4) return error.PayloadTooShort;
    var msg = FocusPanesMsg{ .count = count, .pane_ids = .{0} ** 32 };
    for (0..count) |i| {
        msg.pane_ids[i] = std.mem.readInt(u32, payload[1 + i * 4 ..][0..4], .little);
    }
    return msg;
}

pub const PaneInputMsg = struct { pane_id: u32, bytes: []const u8 };

pub fn decodePaneInput(payload: []const u8) !PaneInputMsg {
    if (payload.len < 4) return error.PayloadTooShort;
    return .{
        .pane_id = std.mem.readInt(u32, payload[0..4], .little),
        .bytes = payload[4..],
    };
}

pub const PaneResizeMsg = struct { pane_id: u32, rows: u16, cols: u16 };

pub fn decodePaneResize(payload: []const u8) !PaneResizeMsg {
    if (payload.len < 8) return error.PayloadTooShort;
    return .{
        .pane_id = std.mem.readInt(u32, payload[0..4], .little),
        .rows = std.mem.readInt(u16, payload[4..6], .little),
        .cols = std.mem.readInt(u16, payload[6..8], .little),
    };
}

pub fn decodePaneCreated(payload: []const u8) !u32 {
    if (payload.len < 4) return error.PayloadTooShort;
    return std.mem.readInt(u32, payload[0..4], .little);
}

pub const PaneDiedMsg = struct { pane_id: u32, exit_code: u8 };

pub fn decodePaneDied(payload: []const u8) !PaneDiedMsg {
    if (payload.len < 5) return error.PayloadTooShort;
    return .{
        .pane_id = std.mem.readInt(u32, payload[0..4], .little),
        .exit_code = payload[4],
    };
}

pub const AttachedV2Msg = struct {
    session_id: u32,
    layout: []const u8,
    pane_count: u8,
    pane_ids: [32]u32,
};

pub fn decodeAttachedV2(payload: []const u8) !AttachedV2Msg {
    if (payload.len < 7) return error.PayloadTooShort;
    const session_id = std.mem.readInt(u32, payload[0..4], .little);
    const layout_len = std.mem.readInt(u16, payload[4..6], .little);
    var pos: usize = 6;
    if (payload.len < pos + layout_len + 1) return error.PayloadTooShort;
    const layout = payload[pos .. pos + layout_len];
    pos += layout_len;
    const pane_count = payload[pos];
    pos += 1;
    if (payload.len < pos + @as(usize, pane_count) * 4) return error.PayloadTooShort;
    var msg = AttachedV2Msg{
        .session_id = session_id,
        .layout = layout,
        .pane_count = pane_count,
        .pane_ids = .{0} ** 32,
    };
    for (0..pane_count) |i| {
        msg.pane_ids[i] = std.mem.readInt(u32, payload[pos..][0..4], .little);
        pos += 4;
    }
    return msg;
}

/// Encode PaneProcName payload: pane_id:u32, name_len:u8, name:[N]u8
pub fn encodePaneProcName(buf: []u8, pane_id: u32, name: []const u8) ![]u8 {
    const name_len: u8 = @intCast(@min(name.len, 255));
    const total: usize = 4 + 1 + name_len;
    if (buf.len < total) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[0..4], pane_id, .little);
    buf[4] = name_len;
    @memcpy(buf[5 .. 5 + name_len], name[0..name_len]);
    return buf[0..total];
}

pub const PaneProcNameMsg = struct { pane_id: u32, name: []const u8 };

pub fn decodePaneProcName(payload: []const u8) !PaneProcNameMsg {
    if (payload.len < 5) return error.PayloadTooShort;
    const pane_id = std.mem.readInt(u32, payload[0..4], .little);
    const name_len = payload[4];
    if (payload.len < 5 + @as(usize, name_len)) return error.PayloadTooShort;
    return .{ .pane_id = pane_id, .name = payload[5 .. 5 + name_len] };
}

// ── Hello / HelloAck (version handshake) ──

/// Encode Hello or HelloAck payload: version_len:u8, version:[N]u8
pub fn encodeHello(buf: []u8, version: []const u8) ![]u8 {
    const vlen: u8 = @intCast(@min(version.len, 255));
    const total: usize = 1 + vlen;
    if (buf.len < total) return error.BufferTooSmall;
    buf[0] = vlen;
    @memcpy(buf[1 .. 1 + vlen], version[0..vlen]);
    return buf[0..total];
}

pub fn decodeHello(payload: []const u8) ![]const u8 {
    if (payload.len < 1) return error.PayloadTooShort;
    const vlen = payload[0];
    if (payload.len < 1 + @as(usize, vlen)) return error.PayloadTooShort;
    return payload[1 .. 1 + vlen];
}

// ── Theme colors ──

/// Encode SetThemeColors payload: fg[3], bg[3], cursor_set:u8, cursor[3] = 10 bytes
pub fn encodeThemeColors(buf: []u8, fg: [3]u8, bg: [3]u8, cursor_set: bool, cursor: [3]u8) ![]u8 {
    if (buf.len < 10) return error.BufferTooSmall;
    @memcpy(buf[0..3], &fg);
    @memcpy(buf[3..6], &bg);
    buf[6] = if (cursor_set) 1 else 0;
    @memcpy(buf[7..10], &cursor);
    return buf[0..10];
}

pub const ThemeColorsMsg = struct {
    fg: [3]u8,
    bg: [3]u8,
    cursor_set: bool,
    cursor: [3]u8,
};

pub fn decodeThemeColors(payload: []const u8) !ThemeColorsMsg {
    if (payload.len < 10) return error.PayloadTooShort;
    return .{
        .fg = payload[0..3].*,
        .bg = payload[3..6].*,
        .cursor_set = payload[6] != 0,
        .cursor = payload[7..10].*,
    };
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
    var buf: [256]u8 = undefined;
    const payload = try encodeCreate(&buf, "my-session", 24, 80, "/home/user/project", "/usr/bin/fish");
    const msg = try decodeCreate(payload);
    try std.testing.expectEqualStrings("my-session", msg.name);
    try std.testing.expectEqual(@as(u16, 24), msg.rows);
    try std.testing.expectEqual(@as(u16, 80), msg.cols);
    try std.testing.expectEqualStrings("/home/user/project", msg.cwd);
    try std.testing.expectEqualStrings("/usr/bin/fish", msg.shell);
}

test "create round-trip without shell (backward compat)" {
    var buf: [256]u8 = undefined;
    const payload = try encodeCreate(&buf, "my-session", 24, 80, "/home/user/project", "");
    const msg = try decodeCreate(payload);
    try std.testing.expectEqualStrings("my-session", msg.name);
    try std.testing.expectEqualStrings("/home/user/project", msg.cwd);
    try std.testing.expectEqualStrings("", msg.shell);
}

test "create round-trip without cwd (backward compat)" {
    // Simulate old-format payload (no CWD field)
    var buf: [128]u8 = undefined;
    const name = "old-session";
    std.mem.writeInt(u16, buf[0..2], @as(u16, @intCast(name.len)), .little);
    @memcpy(buf[2 .. 2 + name.len], name);
    std.mem.writeInt(u16, buf[2 + name.len ..][0..2], 24, .little);
    std.mem.writeInt(u16, buf[4 + name.len ..][0..2], 80, .little);
    const payload = buf[0 .. 6 + name.len];
    const msg = try decodeCreate(payload);
    try std.testing.expectEqualStrings("old-session", msg.name);
    try std.testing.expectEqual(@as(u16, 24), msg.rows);
    try std.testing.expectEqual(@as(u16, 80), msg.cols);
    try std.testing.expectEqualStrings("", msg.cwd);
}

test "attach round-trip" {
    var buf: [128]u8 = undefined;
    const payload = try encodeAttach(&buf, 7, 30, 120);
    const msg = try decodeAttach(payload);
    try std.testing.expectEqual(@as(u32, 7), msg.session_id);
    try std.testing.expectEqual(@as(u16, 30), msg.rows);
    try std.testing.expectEqual(@as(u16, 120), msg.cols);
}

test "error round-trip" {
    var buf: [128]u8 = undefined;
    const payload = try encodeError(&buf, 3, "not found");
    const msg = try decodeError(payload);
    try std.testing.expectEqual(@as(u8, 3), msg.code);
    try std.testing.expectEqualStrings("not found", msg.msg);
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

test "create_pane round-trip" {
    var buf: [128]u8 = undefined;
    const payload = try encodeCreatePane(&buf, 24, 80, "/tmp/test");
    const msg = try decodeCreatePane(payload);
    try std.testing.expectEqual(@as(u16, 24), msg.rows);
    try std.testing.expectEqual(@as(u16, 80), msg.cols);
    try std.testing.expectEqualStrings("/tmp/test", msg.cwd);
}

test "focus_panes round-trip" {
    var buf: [256]u8 = undefined;
    const ids = [_]u32{ 1, 5, 10 };
    const payload = try encodeFocusPanes(&buf, &ids);
    const msg = try decodeFocusPanes(payload);
    try std.testing.expectEqual(@as(u8, 3), msg.count);
    try std.testing.expectEqual(@as(u32, 1), msg.pane_ids[0]);
    try std.testing.expectEqual(@as(u32, 5), msg.pane_ids[1]);
    try std.testing.expectEqual(@as(u32, 10), msg.pane_ids[2]);
}

test "pane_input round-trip" {
    var buf: [256]u8 = undefined;
    const payload = try encodePaneInput(&buf, 42, "hello");
    const msg = try decodePaneInput(payload);
    try std.testing.expectEqual(@as(u32, 42), msg.pane_id);
    try std.testing.expectEqualStrings("hello", msg.bytes);
}

test "pane_resize round-trip" {
    var buf: [128]u8 = undefined;
    const payload = try encodePaneResize(&buf, 7, 30, 120);
    const msg = try decodePaneResize(payload);
    try std.testing.expectEqual(@as(u32, 7), msg.pane_id);
    try std.testing.expectEqual(@as(u16, 30), msg.rows);
    try std.testing.expectEqual(@as(u16, 120), msg.cols);
}

test "pane_died round-trip" {
    var buf: [128]u8 = undefined;
    const payload = try encodePaneDied(&buf, 99, 2);
    const msg = try decodePaneDied(payload);
    try std.testing.expectEqual(@as(u32, 99), msg.pane_id);
    try std.testing.expectEqual(@as(u8, 2), msg.exit_code);
}

test "attached_v2 round-trip" {
    var buf: [256]u8 = undefined;
    const layout = "test-layout";
    const pane_ids = [_]u32{ 1, 2 };
    const payload = try encodeAttachedV2(&buf, 5, layout, &pane_ids);
    const msg = try decodeAttachedV2(payload);
    try std.testing.expectEqual(@as(u32, 5), msg.session_id);
    try std.testing.expectEqualStrings("test-layout", msg.layout);
    try std.testing.expectEqual(@as(u8, 2), msg.pane_count);
    try std.testing.expectEqual(@as(u32, 1), msg.pane_ids[0]);
    try std.testing.expectEqual(@as(u32, 2), msg.pane_ids[1]);
}

test "rename round-trip" {
    var buf: [128]u8 = undefined;
    const payload = try encodeRename(&buf, 42, "new-name");
    const msg = try decodeRename(payload);
    try std.testing.expectEqual(@as(u32, 42), msg.session_id);
    try std.testing.expectEqualStrings("new-name", msg.name);
}

test "hello round-trip" {
    var buf: [128]u8 = undefined;
    const payload = try encodeHello(&buf, "0.2.10");
    const version = try decodeHello(payload);
    try std.testing.expectEqualStrings("0.2.10", version);
}
