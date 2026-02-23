const std = @import("std");

/// Terminal color — supports default, 8+8 ANSI, 256-color palette, and
/// 24-bit truecolor.  Represented as a tagged union so each variant
/// carries exactly the data it needs.
pub const Color = union(enum) {
    /// The terminal's default/theme color (SGR 39 / 49 / 0).
    default,
    /// Standard or bright ANSI color index 0–15 (SGR 30–37, 90–97, etc.).
    ansi: u8,
    /// 256-color palette index 0–255 (SGR 38;5;n / 48;5;n).
    palette: u8,
    /// 24-bit truecolor (SGR 38;2;r;g;b / 48;2;r;g;b).
    rgb: Rgb,

    pub const Rgb = struct { r: u8, g: u8, b: u8 };

    // Named constants for the 8 standard ANSI colors.
    pub const black: Color = .{ .ansi = 0 };
    pub const red: Color = .{ .ansi = 1 };
    pub const green: Color = .{ .ansi = 2 };
    pub const yellow: Color = .{ .ansi = 3 };
    pub const blue: Color = .{ .ansi = 4 };
    pub const magenta: Color = .{ .ansi = 5 };
    pub const cyan: Color = .{ .ansi = 6 };
    pub const white: Color = .{ .ansi = 7 };
};

/// Visual attributes attached to each cell.
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    underline: bool = false,
};

/// A single cell in the terminal grid.
pub const Cell = struct {
    char: u21 = ' ',
    style: Style = .{},
    /// Hyperlink association (0 = none). Maps to TerminalState's link table.
    link_id: u32 = 0,
};

/// Fixed-size 2D grid of cells, stored as a flat row-major array.
/// One allocation on init, freed on deinit. No per-character allocations.
pub const Grid = struct {
    rows: usize,
    cols: usize,
    cells: []Cell,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !Grid {
        std.debug.assert(rows > 0 and cols > 0);
        const cells = try allocator.alloc(Cell, rows * cols);
        @memset(cells, Cell{});
        return .{
            .rows = rows,
            .cols = cols,
            .cells = cells,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Grid) void {
        self.allocator.free(self.cells);
    }

    pub fn getCell(self: *const Grid, row: usize, col: usize) Cell {
        return self.cells[row * self.cols + col];
    }

    pub fn setCell(self: *Grid, row: usize, col: usize, cell: Cell) void {
        self.cells[row * self.cols + col] = cell;
    }

    /// Reset every cell in the given row to default (space + default style).
    pub fn clearRow(self: *Grid, row: usize) void {
        const start = row * self.cols;
        @memset(self.cells[start .. start + self.cols], Cell{});
    }

    /// Shift all rows up by one (full-screen scroll).
    pub fn scrollUp(self: *Grid) void {
        self.scrollUpRegion(0, self.rows - 1);
    }

    /// Scroll rows `top..bottom` up by one: row top+1 → top, top+2 → top+1, etc.
    /// Row `bottom` is cleared. The old row `top` is lost.
    /// Rows outside the region are untouched.
    pub fn scrollUpRegion(self: *Grid, top: usize, bottom: usize) void {
        if (top >= bottom) return;
        const stride = self.cols;
        std.mem.copyForwards(
            Cell,
            self.cells[top * stride .. bottom * stride],
            self.cells[(top + 1) * stride .. (bottom + 1) * stride],
        );
        self.clearRow(bottom);
    }

    /// Scroll rows `top..bottom` down by one: row bottom-1 → bottom, etc.
    /// Row `top` is cleared. The old row `bottom` is lost.
    /// Rows outside the region are untouched.
    pub fn scrollDownRegion(self: *Grid, top: usize, bottom: usize) void {
        if (top >= bottom) return;
        const stride = self.cols;
        std.mem.copyBackwards(
            Cell,
            self.cells[(top + 1) * stride .. (bottom + 1) * stride],
            self.cells[top * stride .. bottom * stride],
        );
        self.clearRow(top);
    }

    /// Scroll a region up by n lines. Lines shifted out of the top are lost.
    /// The bottom n rows of the region are cleared.
    pub fn scrollUpRegionN(self: *Grid, top: usize, bottom: usize, n: usize) void {
        if (top >= bottom or n == 0) return;
        const count = @min(n, bottom - top + 1);
        for (0..count) |_| self.scrollUpRegion(top, bottom);
    }

    /// Scroll a region down by n lines. Lines shifted out of the bottom are lost.
    /// The top n rows of the region are cleared.
    pub fn scrollDownRegionN(self: *Grid, top: usize, bottom: usize, n: usize) void {
        if (top >= bottom or n == 0) return;
        const count = @min(n, bottom - top + 1);
        for (0..count) |_| self.scrollDownRegion(top, bottom);
    }

    /// Insert n blank characters at (row, col), shifting existing chars right.
    /// Characters shifted past the right edge are lost.
    pub fn insertChars(self: *Grid, row: usize, col: usize, n: usize) void {
        if (n == 0 or col >= self.cols) return;
        const start = row * self.cols + col;
        const row_end = row * self.cols + self.cols;
        const count = @min(n, self.cols - col);
        const cells = self.cells[start..row_end];
        if (count < cells.len) {
            std.mem.copyBackwards(Cell, cells[count..], cells[0 .. cells.len - count]);
        }
        @memset(cells[0..count], Cell{});
    }

    /// Delete n characters at (row, col), shifting remaining chars left.
    /// The rightmost n cells of the row become blank.
    pub fn deleteChars(self: *Grid, row: usize, col: usize, n: usize) void {
        if (n == 0 or col >= self.cols) return;
        const start = row * self.cols + col;
        const row_end = row * self.cols + self.cols;
        const count = @min(n, self.cols - col);
        const cells = self.cells[start..row_end];
        if (count < cells.len) {
            std.mem.copyForwards(Cell, cells[0 .. cells.len - count], cells[count..]);
        }
        @memset(cells[cells.len - count ..], Cell{});
    }

    /// Erase n characters at (row, col) without shifting.
    pub fn eraseChars(self: *Grid, row: usize, col: usize, n: usize) void {
        if (n == 0 or col >= self.cols) return;
        const start = row * self.cols + col;
        const count = @min(n, self.cols - col);
        @memset(self.cells[start .. start + count], Cell{});
    }
};

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "init creates grid filled with spaces" {
    const alloc = std.testing.allocator;
    var g = try Grid.init(alloc, 3, 4);
    defer g.deinit();

    for (0..3) |r| {
        for (0..4) |c| {
            try std.testing.expectEqual(@as(u21, ' '), g.getCell(r, c).char);
        }
    }
}

test "setCell and getCell round-trip" {
    const alloc = std.testing.allocator;
    var g = try Grid.init(alloc, 2, 2);
    defer g.deinit();

    g.setCell(0, 1, .{ .char = 'X' });
    try std.testing.expectEqual(@as(u21, 'X'), g.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), g.getCell(0, 0).char);
}

test "clearRow resets row to spaces" {
    const alloc = std.testing.allocator;
    var g = try Grid.init(alloc, 2, 3);
    defer g.deinit();

    g.setCell(0, 0, .{ .char = 'A' });
    g.setCell(0, 1, .{ .char = 'B' });
    g.clearRow(0);

    try std.testing.expectEqual(@as(u21, ' '), g.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), g.getCell(0, 1).char);
}

test "scrollUp shifts rows and clears bottom" {
    const alloc = std.testing.allocator;
    var g = try Grid.init(alloc, 3, 2);
    defer g.deinit();

    g.setCell(0, 0, .{ .char = 'A' });
    g.setCell(1, 0, .{ .char = 'B' });
    g.setCell(2, 0, .{ .char = 'C' });
    g.scrollUp();

    try std.testing.expectEqual(@as(u21, 'B'), g.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), g.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), g.getCell(2, 0).char);
}

test "scrollUpRegion shifts only within region" {
    const alloc = std.testing.allocator;
    var g = try Grid.init(alloc, 5, 2);
    defer g.deinit();

    g.setCell(0, 0, .{ .char = 'A' });
    g.setCell(1, 0, .{ .char = 'B' });
    g.setCell(2, 0, .{ .char = 'C' });
    g.setCell(3, 0, .{ .char = 'D' });
    g.setCell(4, 0, .{ .char = 'E' });
    g.scrollUpRegion(1, 3);

    try std.testing.expectEqual(@as(u21, 'A'), g.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), g.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), g.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), g.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, 'E'), g.getCell(4, 0).char);
}

test "scrollDownRegion shifts only within region" {
    const alloc = std.testing.allocator;
    var g = try Grid.init(alloc, 5, 2);
    defer g.deinit();

    g.setCell(0, 0, .{ .char = 'A' });
    g.setCell(1, 0, .{ .char = 'B' });
    g.setCell(2, 0, .{ .char = 'C' });
    g.setCell(3, 0, .{ .char = 'D' });
    g.setCell(4, 0, .{ .char = 'E' });
    g.scrollDownRegion(1, 3);

    try std.testing.expectEqual(@as(u21, 'A'), g.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), g.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), g.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), g.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, 'E'), g.getCell(4, 0).char);
}

test "new cells have default style" {
    const alloc = std.testing.allocator;
    var g = try Grid.init(alloc, 1, 1);
    defer g.deinit();

    const cell = g.getCell(0, 0);
    try std.testing.expectEqual(Color.default, cell.style.fg);
    try std.testing.expectEqual(Color.default, cell.style.bg);
    try std.testing.expect(!cell.style.bold);
    try std.testing.expect(!cell.style.underline);
}
