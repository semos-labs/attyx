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

    /// Reset every cell in the given row to default (space + default style).
    pub fn clearRow(self: *Grid, row: usize) void {
        const start = row * self.cols;
        @memset(self.cells[start .. start + self.cols], Cell{});
        self.row_wrapped[row] = false;
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
        for (top..bottom) |r| {
            self.row_wrapped[r] = self.row_wrapped[r + 1];
        }
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
        {
            var r = bottom;
            while (r > top) : (r -= 1) {
                self.row_wrapped[r] = self.row_wrapped[r - 1];
            }
        }
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

    /// Callback for saving rows that are dropped during reflow (scroll_off).
    /// `ctx` is an opaque pointer supplied by the caller; `row_cells` contains
    /// the reflowed row content at new_cols width (valid only for the duration
    /// of the call — the callee must copy if it needs to keep the data).
    pub const DropHandler = struct {
        ctx: *anyopaque,
        save: *const fn (ctx: *anyopaque, row_cells: []const Cell, wrapped: bool) void,
    };

    /// Resize with reflow: re-wraps logical lines at the new column width.
    /// Soft-wrapped lines are joined and re-split; hard-wrapped lines stay
    /// separate. Cursor position is mapped through the reflow.
    /// If `drop` is non-null, rows scrolled off the top are saved via the
    /// callback instead of being silently discarded.
    pub fn resize(self: *Grid, new_rows: usize, new_cols: usize, cursor_row: ?*usize, cursor_col: ?*usize, drop: ?DropHandler) !void {
        std.debug.assert(new_rows > 0 and new_cols > 0);

        const has_cursor = cursor_row != null and cursor_col != null;
        const old_cr = if (cursor_row) |cr| cr.* else 0;
        const old_cc = if (cursor_col) |cc| cc.* else 0;

        // --- Phase 1: collect logical lines ---
        const LL = struct { start: usize, count: usize, len: usize };
        var ll_buf: [max_rows]LL = undefined;
        var ll_count: usize = 0;
        {
            var r: usize = 0;
            while (r < self.rows) {
                const start = r;
                var content_len: usize = 0;
                while (r < self.rows) : (r += 1) {
                    if (self.row_wrapped[r]) {
                        content_len += self.cols;
                    } else {
                        var last: usize = 0;
                        const base = r * self.cols;
                        for (0..self.cols) |c| {
                            if (!isDefaultCell(self.cells[base + c])) last = c + 1;
                        }
                        content_len += last;
                        r += 1;
                        break;
                    }
                }
                ll_buf[ll_count] = .{ .start = start, .count = r - start, .len = content_len };
                ll_count += 1;
            }
        }

        // --- Phase 2: compute new row count and cursor mapping ---
        var new_phys_total: usize = 0;
        var mapped_cr: usize = 0;
        var mapped_cc: usize = 0;

        for (ll_buf[0..ll_count]) |ll| {
            const rows_needed = if (ll.len == 0) 1 else (ll.len + new_cols - 1) / new_cols;
            if (has_cursor and old_cr >= ll.start and old_cr < ll.start + ll.count) {
                const offset = (old_cr - ll.start) * self.cols + old_cc;
                mapped_cr = new_phys_total + offset / new_cols;
                mapped_cc = offset % new_cols;
            }
            new_phys_total += rows_needed;
        }

        // Keep cursor visible: if reflowed content exceeds new_rows, scroll
        var scroll_off: usize = 0;
        if (has_cursor and new_phys_total > new_rows) {
            if (mapped_cr >= new_rows) {
                scroll_off = mapped_cr - new_rows + 1;
            }
        }

        // --- Phase 3: allocate and fill ---
        const new_cells = try self.allocator.alloc(Cell, new_rows * new_cols);
        @memset(new_cells, Cell{});
        var new_wrapped: [max_rows]bool = [_]bool{false} ** max_rows;

        // Temp row buffer for saving dropped rows via the callback.
        var save_row: ?[]Cell = null;
        defer if (save_row) |sr| self.allocator.free(sr);
        if (scroll_off > 0 and drop != null) {
            save_row = try self.allocator.alloc(Cell, new_cols);
        }

        var dst_row: usize = 0;
        for (ll_buf[0..ll_count]) |ll| {
            const rows_needed = if (ll.len == 0) 1 else (ll.len + new_cols - 1) / new_cols;
            for (0..rows_needed) |pr| {
                const abs_row = dst_row + pr;

                const cells_start = pr * new_cols;
                const cells_end = @min(cells_start + new_cols, ll.len);

                if (abs_row < scroll_off) {
                    if (drop) |handler| {
                        if (save_row) |sr| {
                            @memset(sr, Cell{});
                            if (cells_end > cells_start) {
                                for (0..cells_end - cells_start) |c| {
                                    const src_idx = cells_start + c;
                                    const old_r = ll.start + src_idx / self.cols;
                                    const old_c = src_idx % self.cols;
                                    sr[c] = self.cells[old_r * self.cols + old_c];
                                }
                            }
                            handler.save(handler.ctx, sr, pr < rows_needed - 1);
                        }
                    }
                    continue;
                }

                const grid_row = abs_row - scroll_off;
                if (grid_row >= new_rows) break;

                if (cells_end > cells_start) {
                    for (0..cells_end - cells_start) |c| {
                        const src_idx = cells_start + c;
                        const old_r = ll.start + src_idx / self.cols;
                        const old_c = src_idx % self.cols;
                        new_cells[grid_row * new_cols + c] = self.cells[old_r * self.cols + old_c];
                    }
                }

                if (pr < rows_needed - 1) {
                    new_wrapped[grid_row] = true;
                }
            }
            dst_row += rows_needed;
        }

        // --- Phase 4: apply ---
        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.rows = new_rows;
        self.cols = new_cols;
        self.row_wrapped = new_wrapped;

        if (cursor_row) |cr| cr.* = @min(mapped_cr -| scroll_off, new_rows - 1);
        if (cursor_col) |cc| cc.* = @min(mapped_cc, new_cols - 1);
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

test "resize: grow copies content and fills new cells" {
    const alloc = std.testing.allocator;
    var g = try Grid.init(alloc, 2, 3);
    defer g.deinit();

    g.setCell(0, 0, .{ .char = 'A' });
    g.setCell(0, 1, .{ .char = 'B' });
    g.setCell(1, 0, .{ .char = 'C' });

    try g.resize(4, 5, null, null, null);

    try std.testing.expectEqual(@as(usize, 4), g.rows);
    try std.testing.expectEqual(@as(usize, 5), g.cols);
    try std.testing.expectEqual(@as(u21, 'A'), g.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), g.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'C'), g.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), g.getCell(0, 3).char);
    try std.testing.expectEqual(@as(u21, ' '), g.getCell(2, 0).char);
}

test "resize: shrink wraps long lines (reflow)" {
    const alloc = std.testing.allocator;
    var g = try Grid.init(alloc, 2, 6);
    defer g.deinit();

    // Write "ABCDEF" on row 0 (fills all 6 cols)
    g.setCell(0, 0, .{ .char = 'A' });
    g.setCell(0, 1, .{ .char = 'B' });
    g.setCell(0, 2, .{ .char = 'C' });
    g.setCell(0, 3, .{ .char = 'D' });
    g.setCell(0, 4, .{ .char = 'E' });
    g.setCell(0, 5, .{ .char = 'F' });

    try g.resize(4, 3, null, null, null);

    try std.testing.expectEqual(@as(usize, 4), g.rows);
    try std.testing.expectEqual(@as(usize, 3), g.cols);
    // Row 0: ABC (wrapped)
    try std.testing.expectEqual(@as(u21, 'A'), g.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), g.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'C'), g.getCell(0, 2).char);
    try std.testing.expect(g.row_wrapped[0]);
    // Row 1: DEF (not wrapped — end of logical line)
    try std.testing.expectEqual(@as(u21, 'D'), g.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'E'), g.getCell(1, 1).char);
    try std.testing.expectEqual(@as(u21, 'F'), g.getCell(1, 2).char);
    try std.testing.expect(!g.row_wrapped[1]);
}

test "resize: reflow then grow restores original layout" {
    const alloc = std.testing.allocator;
    var g = try Grid.init(alloc, 2, 6);
    defer g.deinit();

    g.setCell(0, 0, .{ .char = 'A' });
    g.setCell(0, 1, .{ .char = 'B' });
    g.setCell(0, 2, .{ .char = 'C' });
    g.setCell(0, 3, .{ .char = 'D' });
    g.setCell(0, 4, .{ .char = 'E' });
    g.setCell(0, 5, .{ .char = 'F' });

    // Shrink to 3 cols — wraps into 2 rows
    try g.resize(4, 3, null, null, null);
    try std.testing.expectEqual(@as(u21, 'D'), g.getCell(1, 0).char);

    // Grow back to 6 cols — should unwrap
    try g.resize(4, 6, null, null, null);
    try std.testing.expectEqual(@as(u21, 'A'), g.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'F'), g.getCell(0, 5).char);
    try std.testing.expectEqual(@as(u21, ' '), g.getCell(1, 0).char);
    try std.testing.expect(!g.row_wrapped[0]);
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

test "resize: cursor mapped through reflow" {
    const alloc = std.testing.allocator;
    var g = try Grid.init(alloc, 2, 6);
    defer g.deinit();

    g.setCell(0, 0, .{ .char = 'A' });
    g.setCell(0, 1, .{ .char = 'B' });
    g.setCell(0, 2, .{ .char = 'C' });
    g.setCell(0, 3, .{ .char = 'D' });
    g.setCell(0, 4, .{ .char = 'E' });
    g.setCell(0, 5, .{ .char = 'F' });

    // Cursor at row 0, col 4 (on 'E')
    var cr: usize = 0;
    var cc: usize = 4;
    try g.resize(4, 3, &cr, &cc, null);

    // 'E' is at position 4 in the logical line → row 1, col 1
    try std.testing.expectEqual(@as(usize, 1), cr);
    try std.testing.expectEqual(@as(usize, 1), cc);
}
