// Attyx — Grid sync wire format (server-side VT engine)
//
// When both peers advertise Capabilities.GRID_SYNC the daemon ships cell
// grids instead of raw PTY bytes. Two messages carry the state:
//
//   grid_snapshot — full screen (sent on first focus or gap recovery)
//   grid_delta    — dirty rows only (sent every ~60Hz while bytes flow)
//
// Cells travel in `PackedCell` (32 bytes, extern struct, stable layout).
// Themes are NOT baked in — the client resolves Color → RGB using its
// own theme at publish time. That keeps multi-client + per-client theming
// cleanly separable.

const std = @import("std");
const attyx = @import("attyx");

const Cell = attyx.Cell;
const Color = attyx.Color;
const Style = attyx.Style;

// ── PackedColor: wire-stable Color encoding ──

/// Tag identifying which variant of `Color` a PackedColor holds.
pub const color_tag_default: u8 = 0;
pub const color_tag_ansi: u8 = 1;
pub const color_tag_palette: u8 = 2;
pub const color_tag_rgb: u8 = 3;

/// 32-bit encoded Color. `tag` picks the variant; `value` payload:
///   default  → 0
///   ansi     → 0x0000_00XX (XX = ANSI index 0–15)
///   palette  → 0x0000_00XX (XX = 256-color palette index)
///   rgb      → 0x00_RRGGBB (r,g,b in low three bytes)
pub const PackedColor = packed struct(u32) {
    value: u24,
    tag: u8,
};

pub fn packColor(c: Color) PackedColor {
    return switch (c) {
        .default => .{ .tag = color_tag_default, .value = 0 },
        .ansi => |i| .{ .tag = color_tag_ansi, .value = i },
        .palette => |i| .{ .tag = color_tag_palette, .value = i },
        .rgb => |rgb| .{
            .tag = color_tag_rgb,
            .value = @as(u24, rgb.r) |
                (@as(u24, rgb.g) << 8) |
                (@as(u24, rgb.b) << 16),
        },
    };
}

pub fn unpackColor(p: PackedColor) Color {
    return switch (p.tag) {
        color_tag_ansi => .{ .ansi = @intCast(p.value & 0xFF) },
        color_tag_palette => .{ .palette = @intCast(p.value & 0xFF) },
        color_tag_rgb => .{ .rgb = .{
            .r = @intCast(p.value & 0xFF),
            .g = @intCast((p.value >> 8) & 0xFF),
            .b = @intCast((p.value >> 16) & 0xFF),
        } },
        else => .default,
    };
}

// ── PackedCell: wire-stable Cell ──

pub const style_flag_bold: u8 = 1 << 0;
pub const style_flag_dim: u8 = 1 << 1;
pub const style_flag_italic: u8 = 1 << 2;
pub const style_flag_underline: u8 = 1 << 3;
pub const style_flag_reverse: u8 = 1 << 4;
pub const style_flag_strikethrough: u8 = 1 << 5;

pub const PackedCell = extern struct {
    char: u32 = 0x20,
    combining: [2]u32 = .{ 0, 0 },
    fg: u32 = 0,
    bg: u32 = 0,
    style_flags: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
    link_id: u32 = 0,
};

comptime {
    // Wire format must be stable across builds.
    if (@sizeOf(PackedCell) != 28) @compileError("PackedCell size changed; wire format would break");
}

pub fn packCell(cell: Cell) PackedCell {
    var flags: u8 = 0;
    if (cell.style.bold) flags |= style_flag_bold;
    if (cell.style.dim) flags |= style_flag_dim;
    if (cell.style.italic) flags |= style_flag_italic;
    if (cell.style.underline) flags |= style_flag_underline;
    if (cell.style.reverse) flags |= style_flag_reverse;
    if (cell.style.strikethrough) flags |= style_flag_strikethrough;
    return .{
        .char = cell.char,
        .combining = .{ cell.combining[0], cell.combining[1] },
        .fg = @bitCast(packColor(cell.style.fg)),
        .bg = @bitCast(packColor(cell.style.bg)),
        .style_flags = flags,
        .link_id = cell.link_id,
    };
}

pub fn unpackCell(p: PackedCell) Cell {
    const fg_packed: PackedColor = @bitCast(p.fg);
    const bg_packed: PackedColor = @bitCast(p.bg);
    return .{
        .char = @intCast(p.char & 0x1FFFFF),
        .combining = .{
            @intCast(p.combining[0] & 0x1FFFFF),
            @intCast(p.combining[1] & 0x1FFFFF),
        },
        .style = .{
            .fg = unpackColor(fg_packed),
            .bg = unpackColor(bg_packed),
            .bold = p.style_flags & style_flag_bold != 0,
            .dim = p.style_flags & style_flag_dim != 0,
            .italic = p.style_flags & style_flag_italic != 0,
            .underline = p.style_flags & style_flag_underline != 0,
            .reverse = p.style_flags & style_flag_reverse != 0,
            .strikethrough = p.style_flags & style_flag_strikethrough != 0,
        },
        .link_id = p.link_id,
    };
}

// ── grid_snapshot ──

pub const cursor_visible_flag: u8 = 1 << 0;
pub const alt_active_flag: u8 = 1 << 1;
pub const final_chunk_flag: u8 = 1 << 2;

/// grid_snapshot header. Each message carries a CONTIGUOUS row range
/// `[start_row, start_row + row_count)` of the pane grid. Large panes
/// require multiple messages (bounded by the 64KB wire framing). The
/// final message in a snapshot sets `final_chunk_flag`; all messages
/// share the same `generation`.
pub const SnapshotHeader = extern struct {
    pane_id: u32,
    generation_lo: u32,
    generation_hi: u32,
    rows: u16, // total rows in pane
    cols: u16, // cols in pane
    cursor_row: u16,
    cursor_col: u16,
    flags: u8, // bit0=cursor_visible, bit1=alt_active, bit2=final_chunk
    cursor_shape: u8,
    start_row: u16,
    row_count: u16, // rows in this message's cell block
    /// Scrollback rows that have been produced on the daemon since the
    /// last snapshot shipped to this client. On the first chunk of a new
    /// snapshot (start_row == 0) the client applies `shiftScreenUp(delta)`
    /// before writing cells — that promotes the client's previous top
    /// screen rows into scrollback, mirroring what happened on the daemon.
    /// Subsequent chunks in the same snapshot carry delta=0.
    scrollback_delta: u16,
    _pad: u16 = 0,
};

comptime {
    if (@sizeOf(SnapshotHeader) != 32) @compileError("SnapshotHeader size changed");
}

pub const snapshot_header_size = @sizeOf(SnapshotHeader);

pub const SnapshotInfo = struct {
    pane_id: u32,
    generation: u64,
    rows: u16,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool,
    cursor_shape: u8,
    alt_active: bool,
    start_row: u16,
    row_count: u16,
    final_chunk: bool,
    scrollback_delta: u16,
};

pub fn encodedSnapshotChunkSize(cols: u16, row_count: u16) usize {
    return snapshot_header_size + @as(usize, row_count) * @as(usize, cols) * @sizeOf(PackedCell);
}

/// Encode header into buf; returns header size. Caller appends cells.
pub fn encodeSnapshotHeader(buf: []u8, info: SnapshotInfo) !usize {
    if (buf.len < snapshot_header_size) return error.BufferTooSmall;
    var flags: u8 = 0;
    if (info.cursor_visible) flags |= cursor_visible_flag;
    if (info.alt_active) flags |= alt_active_flag;
    if (info.final_chunk) flags |= final_chunk_flag;
    const hdr: SnapshotHeader = .{
        .pane_id = info.pane_id,
        .generation_lo = @truncate(info.generation),
        .generation_hi = @truncate(info.generation >> 32),
        .rows = info.rows,
        .cols = info.cols,
        .cursor_row = info.cursor_row,
        .cursor_col = info.cursor_col,
        .flags = flags,
        .cursor_shape = info.cursor_shape,
        .start_row = info.start_row,
        .row_count = info.row_count,
        .scrollback_delta = info.scrollback_delta,
    };
    @memcpy(buf[0..snapshot_header_size], std.mem.asBytes(&hdr));
    return snapshot_header_size;
}

pub fn decodeSnapshotHeader(payload: []const u8) !SnapshotInfo {
    if (payload.len < snapshot_header_size) return error.PayloadTooShort;
    var hdr: SnapshotHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr), payload[0..snapshot_header_size]);
    const gen: u64 = @as(u64, hdr.generation_lo) |
        (@as(u64, hdr.generation_hi) << 32);
    return .{
        .pane_id = hdr.pane_id,
        .generation = gen,
        .rows = hdr.rows,
        .cols = hdr.cols,
        .cursor_row = hdr.cursor_row,
        .cursor_col = hdr.cursor_col,
        .cursor_visible = hdr.flags & cursor_visible_flag != 0,
        .cursor_shape = hdr.cursor_shape,
        .alt_active = hdr.flags & alt_active_flag != 0,
        .start_row = hdr.start_row,
        .row_count = hdr.row_count,
        .final_chunk = hdr.flags & final_chunk_flag != 0,
        .scrollback_delta = hdr.scrollback_delta,
    };
}

/// Returns the raw cell bytes embedded in a snapshot chunk payload
/// (row_count × cols × @sizeOf(PackedCell) bytes). Callers read
/// individual cells with `readPackedCell(bytes, idx)` — the bytes are
/// not generally 4-byte aligned (msg frame header pushes the payload
/// offset off alignment), so a direct pointer cast is unsafe.
pub fn snapshotCellBytes(payload: []const u8, info: SnapshotInfo) ![]const u8 {
    const need = @as(usize, info.row_count) * @as(usize, info.cols);
    const bytes = payload[snapshot_header_size..];
    const want = need * @sizeOf(PackedCell);
    if (bytes.len < want) return error.PayloadTooShort;
    return bytes[0..want];
}

/// Read PackedCell at logical index `idx` from a flat cell byte slice.
pub fn readPackedCell(cell_bytes: []const u8, idx: usize) PackedCell {
    var out: PackedCell = .{};
    const off = idx * @sizeOf(PackedCell);
    @memcpy(std.mem.asBytes(&out), cell_bytes[off..][0..@sizeOf(PackedCell)]);
    return out;
}

/// Write a PackedCell at logical index `idx` into a flat cell byte slice.
pub fn writePackedCell(cell_bytes: []u8, idx: usize, cell: PackedCell) void {
    const off = idx * @sizeOf(PackedCell);
    @memcpy(cell_bytes[off..][0..@sizeOf(PackedCell)], std.mem.asBytes(&cell));
}

// ── scrollback_chunk ──
//
// Wire: ScrollbackHeader (fixed) + row_count × cols × PackedCell.
// Rows in the chunk are ordered NEWEST-FIRST so the client can prepend
// each row into its ring in sequence (first-received becomes the newest
// scrollback line, last-received becomes the oldest).

pub const ScrollbackHeader = extern struct {
    pane_id: u32,
    cols: u16,
    row_count: u16, // rows in this chunk
    total_remaining: u32, // scrollback rows still pending after this chunk (for progress)
};

comptime {
    if (@sizeOf(ScrollbackHeader) != 12) @compileError("ScrollbackHeader size changed");
}

pub const scrollback_header_size = @sizeOf(ScrollbackHeader);

pub const ScrollbackInfo = struct {
    pane_id: u32,
    cols: u16,
    row_count: u16,
    total_remaining: u32,
};

pub fn encodedScrollbackSize(cols: u16, row_count: u16) usize {
    return scrollback_header_size + @as(usize, row_count) * @as(usize, cols) * @sizeOf(PackedCell);
}

pub fn encodeScrollbackHeader(buf: []u8, info: ScrollbackInfo) !usize {
    if (buf.len < scrollback_header_size) return error.BufferTooSmall;
    const hdr: ScrollbackHeader = .{
        .pane_id = info.pane_id,
        .cols = info.cols,
        .row_count = info.row_count,
        .total_remaining = info.total_remaining,
    };
    @memcpy(buf[0..scrollback_header_size], std.mem.asBytes(&hdr));
    return scrollback_header_size;
}

pub fn decodeScrollbackHeader(payload: []const u8) !ScrollbackInfo {
    if (payload.len < scrollback_header_size) return error.PayloadTooShort;
    var hdr: ScrollbackHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr), payload[0..scrollback_header_size]);
    return .{
        .pane_id = hdr.pane_id,
        .cols = hdr.cols,
        .row_count = hdr.row_count,
        .total_remaining = hdr.total_remaining,
    };
}

pub fn scrollbackCellBytes(payload: []const u8, info: ScrollbackInfo) ![]const u8 {
    const need = @as(usize, info.row_count) * @as(usize, info.cols);
    const bytes = payload[scrollback_header_size..];
    const want = need * @sizeOf(PackedCell);
    if (bytes.len < want) return error.PayloadTooShort;
    return bytes[0..want];
}

// ── grid_delta ──
//
// Wire: DeltaHeader (fixed), then per-dirty-row {row_index:u16, PackedCell*cols}.

pub const DeltaHeader = extern struct {
    pane_id: u32,
    generation_lo: u32,
    generation_hi: u32,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    dirty_row_count: u16,
    flags: u8,
    cursor_shape: u8,
    _pad: [2]u8 = .{ 0, 0 },
};

comptime {
    if (@sizeOf(DeltaHeader) != 24) @compileError("DeltaHeader size changed");
}

pub const delta_header_size = @sizeOf(DeltaHeader);

pub const DeltaInfo = struct {
    pane_id: u32,
    generation: u64,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool,
    cursor_shape: u8,
    dirty_row_count: u16,
};

/// Per-row entry: row_index:u16, _pad:u16 (keeps PackedCells 4-byte aligned),
/// then cols * PackedCell.
const delta_row_prefix: usize = 4;

pub fn encodedDeltaSize(cols: u16, dirty_rows: u16) usize {
    const per_row: usize = delta_row_prefix + @as(usize, cols) * @sizeOf(PackedCell);
    return delta_header_size + @as(usize, dirty_rows) * per_row;
}

pub fn encodeDeltaHeader(buf: []u8, info: DeltaInfo) !usize {
    if (buf.len < delta_header_size) return error.BufferTooSmall;
    var flags: u8 = 0;
    if (info.cursor_visible) flags |= cursor_visible_flag;
    const hdr: DeltaHeader = .{
        .pane_id = info.pane_id,
        .generation_lo = @truncate(info.generation),
        .generation_hi = @truncate(info.generation >> 32),
        .cols = info.cols,
        .cursor_row = info.cursor_row,
        .cursor_col = info.cursor_col,
        .dirty_row_count = info.dirty_row_count,
        .flags = flags,
        .cursor_shape = info.cursor_shape,
    };
    @memcpy(buf[0..delta_header_size], std.mem.asBytes(&hdr));
    return delta_header_size;
}

pub fn decodeDeltaHeader(payload: []const u8) !DeltaInfo {
    if (payload.len < delta_header_size) return error.PayloadTooShort;
    var hdr: DeltaHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr), payload[0..delta_header_size]);
    const gen: u64 = @as(u64, hdr.generation_lo) |
        (@as(u64, hdr.generation_hi) << 32);
    return .{
        .pane_id = hdr.pane_id,
        .generation = gen,
        .cols = hdr.cols,
        .cursor_row = hdr.cursor_row,
        .cursor_col = hdr.cursor_col,
        .cursor_visible = hdr.flags & cursor_visible_flag != 0,
        .cursor_shape = hdr.cursor_shape,
        .dirty_row_count = hdr.dirty_row_count,
    };
}

/// Iterate dirty rows in a delta payload. Each call returns the next
/// (row_index, cells) pair, or null when exhausted.
pub const DeltaRowIter = struct {
    payload: []const u8,
    info: DeltaInfo,
    offset: usize,
    seen: u16,

    pub const Entry = struct { row_index: u16, cell_bytes: []const u8 };

    pub fn next(self: *DeltaRowIter) !?Entry {
        if (self.seen >= self.info.dirty_row_count) return null;
        if (self.offset + delta_row_prefix > self.payload.len) return error.PayloadTooShort;
        const row_index = std.mem.readInt(u16, self.payload[self.offset..][0..2], .little);
        self.offset += delta_row_prefix;
        const cells_bytes = @as(usize, self.info.cols) * @sizeOf(PackedCell);
        if (self.offset + cells_bytes > self.payload.len) return error.PayloadTooShort;
        const slice = self.payload[self.offset .. self.offset + cells_bytes];
        self.offset += cells_bytes;
        self.seen += 1;
        return .{ .row_index = row_index, .cell_bytes = slice };
    }
};

pub fn deltaRowIter(payload: []const u8, info: DeltaInfo) DeltaRowIter {
    return .{
        .payload = payload,
        .info = info,
        .offset = delta_header_size,
        .seen = 0,
    };
}

// ── Tests ──

test "PackedColor round-trip" {
    const cases = [_]Color{
        .default,
        .{ .ansi = 3 },
        .{ .palette = 217 },
        .{ .rgb = .{ .r = 10, .g = 200, .b = 255 } },
    };
    for (cases) |c| {
        const p = packColor(c);
        const back = unpackColor(p);
        try std.testing.expectEqual(std.meta.activeTag(c), std.meta.activeTag(back));
        switch (c) {
            .default => {},
            .ansi => |i| try std.testing.expectEqual(i, back.ansi),
            .palette => |i| try std.testing.expectEqual(i, back.palette),
            .rgb => |rgb| try std.testing.expectEqual(rgb, back.rgb),
        }
    }
}

test "PackedCell round-trip preserves style and link" {
    const original: Cell = .{
        .char = '漢',
        .combining = .{ 0x0301, 0 },
        .style = .{
            .fg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
            .bg = .{ .palette = 42 },
            .bold = true,
            .italic = true,
            .underline = true,
            .strikethrough = true,
        },
        .link_id = 7,
    };
    const p = packCell(original);
    const back = unpackCell(p);
    try std.testing.expectEqual(original.char, back.char);
    try std.testing.expectEqual(original.combining[0], back.combining[0]);
    try std.testing.expectEqual(@as(u32, 7), back.link_id);
    try std.testing.expect(back.style.bold);
    try std.testing.expect(back.style.italic);
    try std.testing.expect(back.style.underline);
    try std.testing.expect(back.style.strikethrough);
    try std.testing.expect(!back.style.dim);
    try std.testing.expect(!back.style.reverse);
    try std.testing.expectEqual(@as(u8, 42), back.style.bg.palette);
    try std.testing.expectEqual(@as(u8, 1), back.style.fg.rgb.r);
}

test "snapshot header round-trip" {
    var buf: [snapshot_header_size]u8 = undefined;
    const info: SnapshotInfo = .{
        .pane_id = 42,
        .generation = 0x0123_4567_89AB_CDEF,
        .rows = 30,
        .cols = 80,
        .cursor_row = 5,
        .cursor_col = 12,
        .cursor_visible = true,
        .cursor_shape = 2,
        .alt_active = true,
        .start_row = 0,
        .row_count = 30,
        .final_chunk = true,
        .scrollback_delta = 0,
    };
    _ = try encodeSnapshotHeader(&buf, info);
    const back = try decodeSnapshotHeader(&buf);
    try std.testing.expectEqual(info.pane_id, back.pane_id);
    try std.testing.expectEqual(info.generation, back.generation);
    try std.testing.expectEqual(info.rows, back.rows);
    try std.testing.expectEqual(info.cols, back.cols);
    try std.testing.expectEqual(info.cursor_row, back.cursor_row);
    try std.testing.expectEqual(info.cursor_col, back.cursor_col);
    try std.testing.expect(back.cursor_visible);
    try std.testing.expect(back.alt_active);
    try std.testing.expect(back.final_chunk);
    try std.testing.expectEqual(@as(u16, 0), back.start_row);
    try std.testing.expectEqual(@as(u16, 30), back.row_count);
    try std.testing.expectEqual(info.cursor_shape, back.cursor_shape);
}

test "snapshot header chunking: non-final" {
    var buf: [snapshot_header_size]u8 = undefined;
    const info: SnapshotInfo = .{
        .pane_id = 1,
        .generation = 1,
        .rows = 50,
        .cols = 80,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_visible = false,
        .cursor_shape = 0,
        .alt_active = false,
        .start_row = 20,
        .row_count = 15,
        .final_chunk = false,
        .scrollback_delta = 3,
    };
    _ = try encodeSnapshotHeader(&buf, info);
    const back = try decodeSnapshotHeader(&buf);
    try std.testing.expectEqual(@as(u16, 20), back.start_row);
    try std.testing.expectEqual(@as(u16, 15), back.row_count);
    try std.testing.expect(!back.final_chunk);
}

test "delta header + row iter round-trip" {
    const cols: u16 = 4;
    const dirty: u16 = 2;
    const sz = encodedDeltaSize(cols, dirty);
    const alloc = std.testing.allocator;
    const buf = try alloc.alloc(u8, sz);
    defer alloc.free(buf);

    const info: DeltaInfo = .{
        .pane_id = 9,
        .generation = 7,
        .cols = cols,
        .cursor_row = 1,
        .cursor_col = 2,
        .cursor_visible = true,
        .cursor_shape = 0,
        .dirty_row_count = dirty,
    };
    var off = try encodeDeltaHeader(buf, info);

    // Row 0: 'A' 'B' 'C' 'D'
    std.mem.writeInt(u16, buf[off..][0..2], 0, .little);
    std.mem.writeInt(u16, buf[off + 2 ..][0..2], 0, .little); // padding
    off += delta_row_prefix;
    writePackedCell(buf[off..], 0, packCell(.{ .char = 'A' }));
    writePackedCell(buf[off..], 1, packCell(.{ .char = 'B' }));
    writePackedCell(buf[off..], 2, packCell(.{ .char = 'C' }));
    writePackedCell(buf[off..], 3, packCell(.{ .char = 'D' }));
    off += @as(usize, cols) * @sizeOf(PackedCell);

    // Row 5: 'W' 'X' 'Y' 'Z'
    std.mem.writeInt(u16, buf[off..][0..2], 5, .little);
    std.mem.writeInt(u16, buf[off + 2 ..][0..2], 0, .little); // padding
    off += delta_row_prefix;
    writePackedCell(buf[off..], 0, packCell(.{ .char = 'W' }));
    writePackedCell(buf[off..], 1, packCell(.{ .char = 'X' }));
    writePackedCell(buf[off..], 2, packCell(.{ .char = 'Y' }));
    writePackedCell(buf[off..], 3, packCell(.{ .char = 'Z' }));

    const hdr_back = try decodeDeltaHeader(buf);
    try std.testing.expectEqual(info.pane_id, hdr_back.pane_id);
    try std.testing.expectEqual(info.generation, hdr_back.generation);
    try std.testing.expectEqual(info.dirty_row_count, hdr_back.dirty_row_count);

    var it = deltaRowIter(buf, hdr_back);
    const e0 = (try it.next()).?;
    try std.testing.expectEqual(@as(u16, 0), e0.row_index);
    try std.testing.expectEqual(@as(u32, 'A'), readPackedCell(e0.cell_bytes, 0).char);
    try std.testing.expectEqual(@as(u32, 'D'), readPackedCell(e0.cell_bytes, 3).char);

    const e1 = (try it.next()).?;
    try std.testing.expectEqual(@as(u16, 5), e1.row_index);
    try std.testing.expectEqual(@as(u32, 'W'), readPackedCell(e1.cell_bytes, 0).char);
    try std.testing.expectEqual(@as(u32, 'Z'), readPackedCell(e1.cell_bytes, 3).char);

    try std.testing.expect((try it.next()) == null);
}

