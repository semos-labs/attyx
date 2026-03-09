const std = @import("std");
const grid_mod = @import("../term/grid.zig");
const ring_mod = @import("../term/ring.zig");
const Cell = grid_mod.Cell;
const Grid = grid_mod.Grid;
const RingBuffer = ring_mod.RingBuffer;

/// Result from extractScrollbackExcerpt: the joined text and the number of
/// physical lines that contributed.
pub const ExcerptResult = struct {
    text: []u8,
    line_count: u16,
};

/// Selection bounds (row/col pairs, start <= end in screen order).
pub const SelBounds = struct {
    start_row: usize,
    start_col: usize,
    end_row: usize,
    end_col: usize,
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Normalize selection bounds so start <= end (user may select upward).
fn normalizeSelBounds(sel: SelBounds) SelBounds {
    if (sel.start_row > sel.end_row or
        (sel.start_row == sel.end_row and sel.start_col > sel.end_col))
    {
        return .{
            .start_row = sel.end_row,
            .start_col = sel.end_col,
            .end_row = sel.start_row,
            .end_col = sel.start_col,
        };
    }
    return sel;
}

/// Encode a single u21 codepoint as UTF-8 into `buf`. Returns the number of
/// bytes written (1..4), or 0 if the codepoint is zero / invalid.
fn encodeCodepoint(cp: u21, buf: *[4]u8) u3 {
    if (cp == 0) return 0;
    const len = std.unicode.utf8CodepointSequenceLength(cp) catch return 0;
    _ = std.unicode.utf8Encode(cp, buf) catch return 0;
    return len;
}

/// Append a cell's character (base + combining marks) to an ArrayList(u8).
fn appendCellChar(list: *std.ArrayList(u8), allocator: std.mem.Allocator, cell: Cell) !void {
    var buf: [4]u8 = undefined;
    const base_len = encodeCodepoint(cell.char, &buf);
    if (base_len > 0) {
        try list.appendSlice(allocator, buf[0..base_len]);
    }
    for (cell.combining) |cp| {
        const mark_len = encodeCodepoint(cp, &buf);
        if (mark_len > 0) {
            try list.appendSlice(allocator, buf[0..mark_len]);
        }
    }
}

/// Find the last non-space column in a row of cells (returns content length).
fn trimmedLen(cells: []const Cell) usize {
    var last: usize = 0;
    for (cells, 0..) |cell, i| {
        if (!grid_mod.isDefaultCell(cell) or cell.char != ' ') {
            last = i + 1;
        }
    }
    return last;
}

// ---------------------------------------------------------------------------
// Public extraction functions
// ---------------------------------------------------------------------------

/// Extract a single screen row from the ring as trimmed UTF-8.
pub fn extractLineFromRing(allocator: std.mem.Allocator, ring: *const RingBuffer, screen_row: usize) ![]u8 {
    if (screen_row >= ring.screen_rows) return try allocator.alloc(u8, 0);
    const cells = ring.getScreenRow(screen_row);
    const content_len = trimmedLen(cells);

    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);

    for (cells[0..content_len]) |cell| {
        try appendCellChar(&list, allocator, cell);
    }

    return try list.toOwnedSlice(allocator);
}

/// Extract the last `n_lines` of terminal output (scrollback + visible
/// screen via ring), joined with newlines. Soft-wrapped rows are joined
/// without a newline separator. Returns the text and the number of physical
/// lines used.
pub fn extractScrollbackExcerpt(
    allocator: std.mem.Allocator,
    ring: *const RingBuffer,
    n_lines: u16,
) !ExcerptResult {
    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);

    const sb_count = ring.scrollbackCount();
    const total_avail: usize = sb_count + ring.screen_rows;
    const take: usize = @min(@as(usize, n_lines), total_avail);
    const start_idx: usize = total_avail -| take;
    var line_count: u16 = 0;

    var i = start_idx;
    while (i < total_avail) : (i += 1) {
        if (line_count > 0) {
            // Check if previous physical line was soft-wrapped
            const prev = i - 1;
            const prev_wrapped = ring.getWrapped(prev);
            if (!prev_wrapped) {
                try list.append(allocator, '\n');
            }
        }

        const cells = ring.getRow(i);
        const clen = trimmedLen(cells);
        for (cells[0..clen]) |cell| {
            try appendCellChar(&list, allocator, cell);
        }
        line_count += 1;
    }

    return .{
        .text = try list.toOwnedSlice(allocator),
        .line_count = line_count,
    };
}

/// Extract selected text from the ring's screen rows. Rows within the
/// selection are extracted and joined with newlines (soft-wrapped rows
/// joined without).
pub fn extractSelectionText(
    allocator: std.mem.Allocator,
    ring: *const RingBuffer,
    sel: SelBounds,
) ![]u8 {
    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);

    // Normalize bounds (user may select upward/backward)
    const norm = normalizeSelBounds(sel);
    const sr = @min(norm.start_row, ring.screen_rows -| 1);
    const er = @min(norm.end_row, ring.screen_rows -| 1);

    var row = sr;
    while (row <= er) : (row += 1) {
        if (row > sr) {
            if (!ring.getScreenWrapped(row - 1)) {
                try list.append(allocator, '\n');
            }
        }

        const cells = ring.getScreenRow(row);

        const col_start: usize = if (row == sr) @min(norm.start_col, ring.cols) else 0;
        const col_end: usize = if (row == er) @min(norm.end_col + 1, ring.cols) else trimmedLen(cells);

        if (col_start < col_end) {
            for (cells[col_start..col_end]) |cell| {
                try appendCellChar(&list, allocator, cell);
            }
        }
    }

    return try list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "extractLineFromRing: ASCII extraction" {
    var ring = try RingBuffer.init(std.testing.allocator, 3, 10, 0);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'H' });
    ring.setScreenCell(0, 1, .{ .char = 'e' });
    ring.setScreenCell(0, 2, .{ .char = 'l' });
    ring.setScreenCell(0, 3, .{ .char = 'l' });
    ring.setScreenCell(0, 4, .{ .char = 'o' });

    const line = try extractLineFromRing(std.testing.allocator, &ring, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("Hello", line);
}

test "extractLineFromRing: trailing spaces trimmed" {
    var ring = try RingBuffer.init(std.testing.allocator, 2, 8, 0);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'A' });
    ring.setScreenCell(0, 1, .{ .char = 'B' });

    const line = try extractLineFromRing(std.testing.allocator, &ring, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("AB", line);
}

test "extractLineFromRing: combining marks" {
    var ring = try RingBuffer.init(std.testing.allocator, 1, 4, 0);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'e', .combining = .{ 0x0301, 0 } });

    const line = try extractLineFromRing(std.testing.allocator, &ring, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("e\xcc\x81", line);
}

test "extractLineFromRing: empty row" {
    var ring = try RingBuffer.init(std.testing.allocator, 2, 5, 0);
    defer ring.deinit();

    const line = try extractLineFromRing(std.testing.allocator, &ring, 1);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqual(@as(usize, 0), line.len);
}

test "extractScrollbackExcerpt: screen only" {
    var ring = try RingBuffer.init(std.testing.allocator, 3, 5, 10);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'A' });
    ring.setScreenCell(1, 0, .{ .char = 'B' });

    const result = try extractScrollbackExcerpt(std.testing.allocator, &ring, 3);
    defer std.testing.allocator.free(result.text);
    try std.testing.expectEqual(@as(u16, 3), result.line_count);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "B") != null);
}

test "extractScrollbackExcerpt: soft-wrap joins" {
    var ring = try RingBuffer.init(std.testing.allocator, 2, 4, 10);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'A' });
    ring.setScreenCell(0, 1, .{ .char = 'B' });
    ring.setScreenWrapped(0, true);
    ring.setScreenCell(1, 0, .{ .char = 'C' });
    ring.setScreenCell(1, 1, .{ .char = 'D' });

    const result = try extractScrollbackExcerpt(std.testing.allocator, &ring, 2);
    defer std.testing.allocator.free(result.text);
    try std.testing.expectEqualStrings("ABCD", result.text);
}

test "extractSelectionText: single row" {
    var ring = try RingBuffer.init(std.testing.allocator, 2, 10, 0);
    defer ring.deinit();

    const text = "Hello";
    for (text, 0..) |ch, i| {
        ring.setScreenCell(0, i, .{ .char = ch });
    }

    const sel = SelBounds{ .start_row = 0, .start_col = 1, .end_row = 0, .end_col = 3 };
    const result = try extractSelectionText(std.testing.allocator, &ring, sel);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("ell", result);
}

test "extractSelectionText: multi-row" {
    var ring = try RingBuffer.init(std.testing.allocator, 3, 5, 0);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'A' });
    ring.setScreenCell(0, 1, .{ .char = 'B' });
    ring.setScreenCell(1, 0, .{ .char = 'C' });
    ring.setScreenCell(1, 1, .{ .char = 'D' });

    const sel = SelBounds{ .start_row = 0, .start_col = 0, .end_row = 1, .end_col = 1 };
    const result = try extractSelectionText(std.testing.allocator, &ring, sel);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("AB\nCD", result);
}

test "extractSelectionText: soft-wrap across selection" {
    var ring = try RingBuffer.init(std.testing.allocator, 3, 4, 0);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'W' });
    ring.setScreenCell(0, 1, .{ .char = 'R' });
    ring.setScreenWrapped(0, true);
    ring.setScreenCell(1, 0, .{ .char = 'A' });
    ring.setScreenCell(1, 1, .{ .char = 'P' });

    const sel = SelBounds{ .start_row = 0, .start_col = 0, .end_row = 1, .end_col = 1 };
    const result = try extractSelectionText(std.testing.allocator, &ring, sel);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("WRAP", result);
}
