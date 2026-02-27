const std = @import("std");
const grid_mod = @import("../term/grid.zig");
const scrollback_mod = @import("../term/scrollback.zig");
const Cell = grid_mod.Cell;
const Grid = grid_mod.Grid;
const Scrollback = scrollback_mod.Scrollback;

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

/// Extract a single grid row as trimmed UTF-8. Trailing default-styled spaces
/// are stripped. Combining marks are included after the base character.
pub fn extractLineFromGrid(allocator: std.mem.Allocator, grid: *const Grid, row: usize) ![]u8 {
    if (row >= grid.rows) return try allocator.alloc(u8, 0);
    const start = row * grid.cols;
    const cells = grid.cells[start .. start + grid.cols];
    const content_len = trimmedLen(cells);

    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);

    for (cells[0..content_len]) |cell| {
        try appendCellChar(&list, allocator, cell);
    }

    return try list.toOwnedSlice(allocator);
}

/// Extract a single scrollback line as trimmed UTF-8.
pub fn extractLineFromScrollback(allocator: std.mem.Allocator, sb: *const Scrollback, index: usize) ![]u8 {
    if (index >= sb.count) return try allocator.alloc(u8, 0);
    const cells = sb.getLine(index);
    const content_len = trimmedLen(cells);

    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);

    for (cells[0..content_len]) |cell| {
        try appendCellChar(&list, allocator, cell);
    }

    return try list.toOwnedSlice(allocator);
}

/// Extract the last `n_lines` of terminal output (scrollback tail + visible
/// grid), joined with newlines. Soft-wrapped rows are joined without a
/// newline separator. Returns the text and the number of physical lines used.
pub fn extractScrollbackExcerpt(
    allocator: std.mem.Allocator,
    grid: *const Grid,
    sb: *const Scrollback,
    n_lines: u16,
) !ExcerptResult {
    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);

    const total_avail: usize = sb.count + grid.rows;
    const take: usize = @min(@as(usize, n_lines), total_avail);
    const start_idx: usize = total_avail -| take;
    var line_count: u16 = 0;

    var i = start_idx;
    while (i < total_avail) : (i += 1) {
        if (line_count > 0) {
            // Check if previous physical line was soft-wrapped
            const prev = i - 1;
            const prev_wrapped = if (prev < sb.count)
                sb.getLineWrapped(prev)
            else
                grid.row_wrapped[prev - sb.count];
            if (!prev_wrapped) {
                try list.append(allocator, '\n');
            }
        }

        if (i < sb.count) {
            const cells = sb.getLine(i);
            const clen = trimmedLen(cells);
            for (cells[0..clen]) |cell| {
                try appendCellChar(&list, allocator, cell);
            }
        } else {
            const grid_row = i - sb.count;
            if (grid_row < grid.rows) {
                const s = grid_row * grid.cols;
                const cells = grid.cells[s .. s + grid.cols];
                const clen = trimmedLen(cells);
                for (cells[0..clen]) |cell| {
                    try appendCellChar(&list, allocator, cell);
                }
            }
        }
        line_count += 1;
    }

    return .{
        .text = try list.toOwnedSlice(allocator),
        .line_count = line_count,
    };
}

/// Extract selected text from the grid. Rows within the selection are
/// extracted and joined with newlines (soft-wrapped rows joined without).
pub fn extractSelectionText(
    allocator: std.mem.Allocator,
    grid: *const Grid,
    sel: SelBounds,
) ![]u8 {
    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);

    const sr = @min(sel.start_row, grid.rows -| 1);
    const er = @min(sel.end_row, grid.rows -| 1);

    var row = sr;
    while (row <= er) : (row += 1) {
        if (row > sr) {
            if (!grid.row_wrapped[row - 1]) {
                try list.append(allocator, '\n');
            }
        }

        const base = row * grid.cols;
        const cells = grid.cells[base .. base + grid.cols];

        const col_start: usize = if (row == sr) @min(sel.start_col, grid.cols) else 0;
        const col_end: usize = if (row == er) @min(sel.end_col + 1, grid.cols) else trimmedLen(cells);

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

test "extractLineFromGrid: ASCII extraction" {
    var g = try Grid.init(std.testing.allocator, 3, 10);
    defer g.deinit();

    g.setCell(0, 0, .{ .char = 'H' });
    g.setCell(0, 1, .{ .char = 'e' });
    g.setCell(0, 2, .{ .char = 'l' });
    g.setCell(0, 3, .{ .char = 'l' });
    g.setCell(0, 4, .{ .char = 'o' });

    const line = try extractLineFromGrid(std.testing.allocator, &g, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("Hello", line);
}

test "extractLineFromGrid: trailing spaces trimmed" {
    var g = try Grid.init(std.testing.allocator, 2, 8);
    defer g.deinit();

    g.setCell(0, 0, .{ .char = 'A' });
    g.setCell(0, 1, .{ .char = 'B' });
    // cols 2-7 remain spaces

    const line = try extractLineFromGrid(std.testing.allocator, &g, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("AB", line);
}

test "extractLineFromGrid: combining marks" {
    var g = try Grid.init(std.testing.allocator, 1, 4);
    defer g.deinit();

    // 'e' + combining acute accent (U+0301)
    g.setCell(0, 0, .{ .char = 'e', .combining = .{ 0x0301, 0 } });

    const line = try extractLineFromGrid(std.testing.allocator, &g, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("e\xcc\x81", line); // "é" as decomposed
}

test "extractLineFromGrid: empty row" {
    var g = try Grid.init(std.testing.allocator, 2, 5);
    defer g.deinit();

    const line = try extractLineFromGrid(std.testing.allocator, &g, 1);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqual(@as(usize, 0), line.len);
}

test "extractLineFromScrollback: basic" {
    var sb = try Scrollback.init(std.testing.allocator, 10, 5);
    defer sb.deinit();

    var cells: [5]Cell = undefined;
    for (&cells) |*cell| cell.* = Cell{};
    cells[0] = .{ .char = 'X' };
    cells[1] = .{ .char = 'Y' };
    sb.pushLine(&cells, false);

    const line = try extractLineFromScrollback(std.testing.allocator, &sb, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("XY", line);
}

test "extractScrollbackExcerpt: grid only" {
    var g = try Grid.init(std.testing.allocator, 3, 5);
    defer g.deinit();
    var sb = try Scrollback.init(std.testing.allocator, 10, 5);
    defer sb.deinit();

    g.setCell(0, 0, .{ .char = 'A' });
    g.setCell(1, 0, .{ .char = 'B' });

    const result = try extractScrollbackExcerpt(std.testing.allocator, &g, &sb, 3);
    defer std.testing.allocator.free(result.text);
    try std.testing.expectEqual(@as(u16, 3), result.line_count);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "B") != null);
}

test "extractScrollbackExcerpt: soft-wrap joins" {
    var g = try Grid.init(std.testing.allocator, 2, 4);
    defer g.deinit();
    var sb = try Scrollback.init(std.testing.allocator, 10, 4);
    defer sb.deinit();

    // Row 0 is wrapped, row 1 is not
    g.setCell(0, 0, .{ .char = 'A' });
    g.setCell(0, 1, .{ .char = 'B' });
    g.row_wrapped[0] = true;
    g.setCell(1, 0, .{ .char = 'C' });
    g.setCell(1, 1, .{ .char = 'D' });

    const result = try extractScrollbackExcerpt(std.testing.allocator, &g, &sb, 2);
    defer std.testing.allocator.free(result.text);
    // Wrapped rows are joined without newline
    try std.testing.expectEqualStrings("ABCD", result.text);
}

test "extractSelectionText: single row" {
    var g = try Grid.init(std.testing.allocator, 2, 10);
    defer g.deinit();

    const text = "Hello";
    for (text, 0..) |ch, i| {
        g.setCell(0, i, .{ .char = ch });
    }

    const sel = SelBounds{ .start_row = 0, .start_col = 1, .end_row = 0, .end_col = 3 };
    const result = try extractSelectionText(std.testing.allocator, &g, sel);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("ell", result);
}

test "extractSelectionText: multi-row" {
    var g = try Grid.init(std.testing.allocator, 3, 5);
    defer g.deinit();

    g.setCell(0, 0, .{ .char = 'A' });
    g.setCell(0, 1, .{ .char = 'B' });
    g.setCell(1, 0, .{ .char = 'C' });
    g.setCell(1, 1, .{ .char = 'D' });

    const sel = SelBounds{ .start_row = 0, .start_col = 0, .end_row = 1, .end_col = 1 };
    const result = try extractSelectionText(std.testing.allocator, &g, sel);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("AB\nCD", result);
}

test "extractSelectionText: soft-wrap across selection" {
    var g = try Grid.init(std.testing.allocator, 3, 4);
    defer g.deinit();

    g.setCell(0, 0, .{ .char = 'W' });
    g.setCell(0, 1, .{ .char = 'R' });
    g.row_wrapped[0] = true;
    g.setCell(1, 0, .{ .char = 'A' });
    g.setCell(1, 1, .{ .char = 'P' });

    const sel = SelBounds{ .start_row = 0, .start_col = 0, .end_row = 1, .end_col = 1 };
    const result = try extractSelectionText(std.testing.allocator, &g, sel);
    defer std.testing.allocator.free(result);
    // Soft-wrapped rows joined without newline
    try std.testing.expectEqualStrings("WRAP", result);
}
