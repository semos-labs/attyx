const std = @import("std");
const overlay = @import("overlay.zig");
const layout = @import("layout.zig");
const OverlayCell = overlay.OverlayCell;
const OverlayStyle = overlay.OverlayStyle;
const Rgb = overlay.Rgb;
const CardResult = layout.CardResult;

// ---------------------------------------------------------------------------
// Search bar state
// ---------------------------------------------------------------------------

pub const SearchBarState = struct {
    query: [256]u8 = undefined,
    query_len: u16 = 0,
    cursor_pos: u16 = 0,
    total_matches: u32 = 0,
    current_match: u32 = 0,

    pub fn insertChar(self: *SearchBarState, codepoint: u21) void {
        if (codepoint < 0x20) return; // ignore control chars

        // Encode to UTF-8
        var enc_buf: [4]u8 = undefined;
        const enc_len = std.unicode.utf8Encode(codepoint, &enc_buf) catch return;
        if (self.query_len + enc_len > 256) return;

        // Shift bytes right from cursor_pos to make room
        const pos: usize = self.cursor_pos;
        const qlen: usize = self.query_len;
        if (pos < qlen) {
            std.mem.copyBackwards(u8, self.query[pos + enc_len .. qlen + enc_len], self.query[pos..qlen]);
        }
        @memcpy(self.query[pos .. pos + enc_len], enc_buf[0..enc_len]);
        self.query_len += @intCast(enc_len);
        self.cursor_pos += @intCast(enc_len);
    }

    pub fn deleteBack(self: *SearchBarState) void {
        if (self.cursor_pos == 0) return;
        // Find start of previous UTF-8 char
        const prev = prevCharBoundary(self.query[0..self.query_len], self.cursor_pos);
        const del_len = self.cursor_pos - prev;
        const qlen: usize = self.query_len;
        std.mem.copyForwards(u8, self.query[prev..qlen - del_len], self.query[self.cursor_pos..qlen]);
        self.query_len -= del_len;
        self.cursor_pos = prev;
    }

    pub fn deleteFwd(self: *SearchBarState) void {
        if (self.cursor_pos >= self.query_len) return;
        const nxt = nextCharBoundary(self.query[0..self.query_len], self.cursor_pos);
        const del_len = nxt - self.cursor_pos;
        const qlen: usize = self.query_len;
        std.mem.copyForwards(u8, self.query[self.cursor_pos .. qlen - del_len], self.query[nxt..qlen]);
        self.query_len -= del_len;
    }

    pub fn cursorLeft(self: *SearchBarState) void {
        if (self.cursor_pos == 0) return;
        self.cursor_pos = prevCharBoundary(self.query[0..self.query_len], self.cursor_pos);
    }

    pub fn cursorRight(self: *SearchBarState) void {
        if (self.cursor_pos >= self.query_len) return;
        self.cursor_pos = nextCharBoundary(self.query[0..self.query_len], self.cursor_pos);
    }

    pub fn cursorHome(self: *SearchBarState) void {
        self.cursor_pos = 0;
    }

    pub fn cursorEnd(self: *SearchBarState) void {
        self.cursor_pos = self.query_len;
    }

    pub fn clear(self: *SearchBarState) void {
        self.query_len = 0;
        self.cursor_pos = 0;
        self.total_matches = 0;
        self.current_match = 0;
    }

    pub fn querySlice(self: *const SearchBarState) []const u8 {
        return self.query[0..self.query_len];
    }
};

fn prevCharBoundary(data: []const u8, pos: u16) u16 {
    var p: u16 = pos;
    if (p == 0) return 0;
    p -= 1;
    while (p > 0 and (data[p] & 0xC0) == 0x80) p -= 1;
    return p;
}

fn nextCharBoundary(data: []const u8, pos: u16) u16 {
    var p: u16 = pos;
    if (p >= data.len) return @intCast(data.len);
    p += 1;
    while (p < data.len and (data[p] & 0xC0) == 0x80) p += 1;
    return p;
}

// ---------------------------------------------------------------------------
// Search bar style
// ---------------------------------------------------------------------------

pub const SearchBarStyle = struct {
    bg: Rgb = .{ .r = 30, .g = 30, .b = 38 },
    fg: Rgb = .{ .r = 200, .g = 200, .b = 210 },
    label_fg: Rgb = .{ .r = 100, .g = 120, .b = 160 },
    input_bg: Rgb = .{ .r = 45, .g = 45, .b = 55 },
    placeholder_fg: Rgb = .{ .r = 90, .g = 90, .b = 100 },
    cursor_fg: Rgb = .{ .r = 30, .g = 30, .b = 38 },
    cursor_bg: Rgb = .{ .r = 115, .g = 165, .b = 255 },
    match_fg: Rgb = .{ .r = 160, .g = 160, .b = 170 },
    no_match_fg: Rgb = .{ .r = 180, .g = 80, .b = 80 },
    button_fg: Rgb = .{ .r = 130, .g = 140, .b = 160 },
    bg_alpha: u8 = 255,
};

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

/// Layout: " Find: [___query___]  3/12  < > x "
pub fn layoutSearchBar(
    allocator: std.mem.Allocator,
    grid_cols: u16,
    search: *const SearchBarState,
    style: SearchBarStyle,
) !CardResult {
    if (grid_cols == 0) return error.InvalidWidth;

    const width = grid_cols;
    const height: u16 = 1;
    const cell_count: usize = @as(usize, width);
    const cells = try allocator.alloc(OverlayCell, cell_count);

    // Fill all cells with bar background
    for (cells) |*cell| {
        cell.* = .{
            .char = ' ',
            .fg = style.fg,
            .bg = style.bg,
            .bg_alpha = style.bg_alpha,
        };
    }

    var col: u16 = 0;

    // " Find: " prefix (7 chars)
    const label = " Find: ";
    for (label) |ch| {
        if (col >= width) break;
        cells[col] = .{ .char = ch, .fg = style.label_fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
        col += 1;
    }

    // Calculate layout regions
    // Right side: "  N/M  < > x " needs about 16-20 chars depending on match count
    const right_reserved: u16 = computeRightWidth(search);
    const input_start = col;
    const input_end: u16 = if (width > right_reserved + col) width - right_reserved else col;
    const input_width = if (input_end > input_start) input_end - input_start else 0;

    // Input area background
    for (input_start..input_end) |i| {
        cells[i] = .{ .char = ' ', .fg = style.fg, .bg = style.input_bg, .bg_alpha = style.bg_alpha };
    }

    // Query text or placeholder
    if (search.query_len == 0) {
        const placeholder = "type to search...";
        var pi: u16 = 0;
        for (placeholder) |ch| {
            const ci = input_start + pi;
            if (ci >= input_end) break;
            cells[ci] = .{ .char = ch, .fg = style.placeholder_fg, .bg = style.input_bg, .bg_alpha = style.bg_alpha };
            pi += 1;
        }
        // Cursor at position 0 (beginning of input)
        if (input_start < input_end) {
            cells[input_start] = .{
                .char = ' ',
                .fg = style.cursor_fg,
                .bg = style.cursor_bg,
                .bg_alpha = style.bg_alpha,
            };
        }
    } else {
        // Render query chars (decode UTF-8 codepoints)
        const q = search.query[0..search.query_len];
        var byte_pos: u16 = 0;
        var char_col: u16 = 0;
        while (byte_pos < q.len) {
            const ci = input_start + char_col;
            if (ci >= input_end) break;

            const cp_len = std.unicode.utf8ByteSequenceLength(q[byte_pos]) catch 1;
            const cp = std.unicode.utf8Decode(q[byte_pos..@min(byte_pos + cp_len, q.len)]) catch '?';

            const is_cursor = (byte_pos == search.cursor_pos);
            if (is_cursor) {
                cells[ci] = .{
                    .char = cp,
                    .fg = style.cursor_fg,
                    .bg = style.cursor_bg,
                    .bg_alpha = style.bg_alpha,
                };
            } else {
                cells[ci] = .{
                    .char = cp,
                    .fg = style.fg,
                    .bg = style.input_bg,
                    .bg_alpha = style.bg_alpha,
                };
            }
            byte_pos += @intCast(cp_len);
            char_col += 1;
        }

        // If cursor is at end of query (append position)
        if (search.cursor_pos >= search.query_len) {
            const ci = input_start + char_col;
            if (ci < input_end) {
                cells[ci] = .{
                    .char = ' ',
                    .fg = style.cursor_fg,
                    .bg = style.cursor_bg,
                    .bg_alpha = style.bg_alpha,
                };
            }
        }
    }

    // Right section: match count + nav buttons + close
    col = input_end;
    if (col < width) {
        cells[col] = .{ .char = ' ', .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
        col += 1;
    }

    // Match counter
    if (search.query_len > 0) {
        var count_buf: [20]u8 = undefined;
        const count_str = if (search.total_matches > 0)
            std.fmt.bufPrint(&count_buf, "{d}/{d}", .{ search.current_match + 1, search.total_matches }) catch ""
        else
            std.fmt.bufPrint(&count_buf, "-/0", .{}) catch "";

        const match_fg = if (search.total_matches > 0) style.match_fg else style.no_match_fg;
        for (count_str) |ch| {
            if (col >= width) break;
            cells[col] = .{ .char = ch, .fg = match_fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
            col += 1;
        }
    }

    // Space + nav buttons: " < > x "
    if (col < width) { cells[col].char = ' '; col += 1; }

    const nav_chars = [_]u21{ 0x25C0, ' ', 0x25B6, ' ', 'x', ' ' }; // ◀ ▶ x
    for (nav_chars) |ch| {
        if (col >= width) break;
        cells[col] = .{ .char = ch, .fg = style.button_fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
        col += 1;
    }

    _ = input_width;
    return .{ .cells = cells, .width = width, .height = height };
}

fn computeRightWidth(search: *const SearchBarState) u16 {
    // " " + match_count + " < > x "
    // match_count: up to "999/999" = 7 chars, or "-/0" = 3, or empty
    var w: u16 = 1; // leading space
    if (search.query_len > 0) {
        if (search.total_matches > 0) {
            w += digitCount(search.current_match + 1) + 1 + digitCount(search.total_matches);
        } else {
            w += 3; // "-/0"
        }
    }
    w += 7; // " < > x "
    return w;
}

fn digitCount(n: u32) u16 {
    if (n == 0) return 1;
    var v = n;
    var count: u16 = 0;
    while (v > 0) : (v /= 10) count += 1;
    return count;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "SearchBarState: insertChar and querySlice" {
    var s = SearchBarState{};
    s.insertChar('H');
    s.insertChar('i');
    try std.testing.expectEqualSlices(u8, "Hi", s.querySlice());
    try std.testing.expectEqual(@as(u16, 2), s.cursor_pos);
}

test "SearchBarState: deleteBack" {
    var s = SearchBarState{};
    s.insertChar('A');
    s.insertChar('B');
    s.insertChar('C');
    s.deleteBack();
    try std.testing.expectEqualSlices(u8, "AB", s.querySlice());
    try std.testing.expectEqual(@as(u16, 2), s.cursor_pos);
}

test "SearchBarState: deleteFwd" {
    var s = SearchBarState{};
    s.insertChar('X');
    s.insertChar('Y');
    s.cursorHome();
    s.deleteFwd();
    try std.testing.expectEqualSlices(u8, "Y", s.querySlice());
    try std.testing.expectEqual(@as(u16, 0), s.cursor_pos);
}

test "SearchBarState: cursor movement" {
    var s = SearchBarState{};
    s.insertChar('a');
    s.insertChar('b');
    s.insertChar('c');
    s.cursorHome();
    try std.testing.expectEqual(@as(u16, 0), s.cursor_pos);
    s.cursorRight();
    try std.testing.expectEqual(@as(u16, 1), s.cursor_pos);
    s.cursorEnd();
    try std.testing.expectEqual(@as(u16, 3), s.cursor_pos);
    s.cursorLeft();
    try std.testing.expectEqual(@as(u16, 2), s.cursor_pos);
}

test "SearchBarState: insert in middle" {
    var s = SearchBarState{};
    s.insertChar('A');
    s.insertChar('C');
    s.cursorLeft();
    s.insertChar('B');
    try std.testing.expectEqualSlices(u8, "ABC", s.querySlice());
    try std.testing.expectEqual(@as(u16, 2), s.cursor_pos);
}

test "SearchBarState: clear" {
    var s = SearchBarState{};
    s.insertChar('x');
    s.insertChar('y');
    s.clear();
    try std.testing.expectEqual(@as(u16, 0), s.query_len);
    try std.testing.expectEqual(@as(u16, 0), s.cursor_pos);
}

test "layoutSearchBar: dimensions" {
    var s = SearchBarState{};
    const result = try layoutSearchBar(std.testing.allocator, 80, &s, .{});
    defer std.testing.allocator.free(result.cells);
    try std.testing.expectEqual(@as(u16, 80), result.width);
    try std.testing.expectEqual(@as(u16, 1), result.height);
    try std.testing.expectEqual(@as(usize, 80), result.cells.len);
}

test "layoutSearchBar: placeholder when empty" {
    var s = SearchBarState{};
    const sty = SearchBarStyle{};
    const result = try layoutSearchBar(std.testing.allocator, 80, &s, sty);
    defer std.testing.allocator.free(result.cells);
    // Col 7 is cursor cell (overwrites first placeholder char), col 8 has 'y'
    try std.testing.expectEqual(sty.cursor_bg.r, result.cells[7].bg.r);
    try std.testing.expectEqual(@as(u21, 'y'), result.cells[8].char);
}

test "layoutSearchBar: cursor cell inverted" {
    var s = SearchBarState{};
    s.insertChar('a');
    s.insertChar('b');
    const sty = SearchBarStyle{};
    const result = try layoutSearchBar(std.testing.allocator, 80, &s, sty);
    defer std.testing.allocator.free(result.cells);
    // Cursor is at pos 2 (end), which maps to input_start + 2 = col 9
    // The cursor cell should have cursor_bg as background
    try std.testing.expectEqual(sty.cursor_bg.r, result.cells[9].bg.r);
    try std.testing.expectEqual(sty.cursor_bg.g, result.cells[9].bg.g);
    try std.testing.expectEqual(sty.cursor_bg.b, result.cells[9].bg.b);
}

test "layoutSearchBar: match counter" {
    var s = SearchBarState{};
    s.insertChar('f');
    s.total_matches = 12;
    s.current_match = 2;
    const result = try layoutSearchBar(std.testing.allocator, 80, &s, .{});
    defer std.testing.allocator.free(result.cells);
    // Find "3/12" in the cells (current_match + 1 = 3)
    var found = false;
    for (0..result.cells.len - 3) |i| {
        if (result.cells[i].char == '3' and result.cells[i + 1].char == '/' and
            result.cells[i + 2].char == '1' and result.cells[i + 3].char == '2')
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
