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
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,
};

/// A single cell in the terminal grid.
pub const Cell = struct {
    char: u21 = ' ',
    /// Combining marks attached to the base character (e.g. diacriticals, Thai
    /// tone marks). 2 slots cover virtually all real-world grapheme clusters.
    combining: [2]u21 = .{ 0, 0 },
    style: Style = .{},
    /// Hyperlink association (0 = none). Maps to TerminalState's link table.
    link_id: u32 = 0,
};

pub const max_rows: usize = 256;

/// A cell is "default" for reflow content-length measurement when it
/// contributes nothing visible: space character + default background.
/// Foreground-only styling on a space is invisible (colored nothing on
/// the default background), so we ignore fg/bold/underline here.
/// Cells with a non-default background ARE visible (colored block).
pub fn isDefaultCell(cell: Cell) bool {
    return cell.char == ' ' and
        cell.style.bg == .default and
        cell.link_id == 0;
}

/// Fixed-size 2D grid of cells, stored as a flat row-major array.
/// One allocation on init, freed on deinit. No per-character allocations.
pub const Grid = struct {
    rows: usize,
    cols: usize,
    cells: []Cell,
    allocator: std.mem.Allocator,
    /// Per-row flag: true when a soft wrap (auto-wrap at right edge) caused
    /// continuation onto the next row. Used by reflow on resize.
    row_wrapped: [max_rows]bool = [_]bool{false} ** max_rows,

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

    /// Simple resize without reflow. Preserves the overlapping rectangle
    /// of content. Used for the alternate screen buffer where the app
    /// will redraw on resize anyway.
    pub fn resizeNoReflow(self: *Grid, new_rows: usize, new_cols: usize) !void {
        std.debug.assert(new_rows > 0 and new_cols > 0);
        const new_cells = try self.allocator.alloc(Cell, new_rows * new_cols);
        @memset(new_cells, Cell{});

        const copy_rows = @min(self.rows, new_rows);
        const copy_cols = @min(self.cols, new_cols);

        for (0..copy_rows) |row| {
            const src_start = row * self.cols;
            const dst_start = row * new_cols;
            @memcpy(
                new_cells[dst_start .. dst_start + copy_cols],
                self.cells[src_start .. src_start + copy_cols],
            );
        }

        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.rows = new_rows;
        self.cols = new_cols;
        @memset(&self.row_wrapped, false);
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

test "resizeNoReflow: shrink truncates" {
    const alloc = std.testing.allocator;
    var g = try Grid.init(alloc, 4, 6);
    defer g.deinit();

    g.setCell(0, 0, .{ .char = 'X' });
    g.setCell(3, 5, .{ .char = 'Y' });

    try g.resizeNoReflow(2, 3);

    try std.testing.expectEqual(@as(usize, 2), g.rows);
    try std.testing.expectEqual(@as(usize, 3), g.cols);
    try std.testing.expectEqual(@as(u21, 'X'), g.getCell(0, 0).char);
}

