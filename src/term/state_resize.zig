const std = @import("std");
const grid_mod = @import("grid.zig");
const scrollback_mod = @import("scrollback.zig");

const TerminalState = @import("state.zig").TerminalState;

/// Grid.DropHandler callback: pushes a dropped reflow row into scrollback.
fn onDropRow(ctx_raw: *anyopaque, row_cells: []const grid_mod.Cell, wrapped: bool) void {
    const self: *TerminalState = @ptrCast(@alignCast(ctx_raw));
    self.scrollback.pushLine(row_cells, wrapped);
}

fn clampState(self: *TerminalState, rows: usize, cols: usize) void {
    self.cursor.row = @min(self.cursor.row, rows - 1);
    self.cursor.col = @min(self.cursor.col, cols - 1);

    self.scroll_top = @min(self.scroll_top, rows - 1);
    self.scroll_bottom = rows - 1;

    if (self.scroll_top >= self.scroll_bottom) {
        self.scroll_top = 0;
        self.scroll_bottom = rows - 1;
    }

    if (self.saved_cursor) |*saved| {
        saved.cursor.row = @min(saved.cursor.row, rows - 1);
        saved.cursor.col = @min(saved.cursor.col, cols - 1);
        saved.scroll_top = @min(saved.scroll_top, rows - 1);
        saved.scroll_bottom = rows - 1;
        if (saved.scroll_top >= saved.scroll_bottom) {
            saved.scroll_top = 0;
            saved.scroll_bottom = rows - 1;
        }
    }
}

fn clampInactiveState(self: *TerminalState, rows: usize, cols: usize) void {
    self.inactive_cursor.row = @min(self.inactive_cursor.row, rows - 1);
    self.inactive_cursor.col = @min(self.inactive_cursor.col, cols - 1);

    self.inactive_scroll_top = @min(self.inactive_scroll_top, rows - 1);
    self.inactive_scroll_bottom = rows - 1;

    if (self.inactive_scroll_top >= self.inactive_scroll_bottom) {
        self.inactive_scroll_top = 0;
        self.inactive_scroll_bottom = rows - 1;
    }

    if (self.inactive_saved_cursor) |*saved| {
        saved.cursor.row = @min(saved.cursor.row, rows - 1);
        saved.cursor.col = @min(saved.cursor.col, cols - 1);
        saved.scroll_top = @min(saved.scroll_top, rows - 1);
        saved.scroll_bottom = rows - 1;
        if (saved.scroll_top >= saved.scroll_bottom) {
            saved.scroll_top = 0;
            saved.scroll_bottom = rows - 1;
        }
    }
}

/// Resize both grids to new dimensions. Preserves overlapping content,
/// clamps cursors and scroll regions. Marks all rows dirty.
pub fn resize(self: *TerminalState, new_rows: usize, new_cols: usize) !void {
    if (new_rows == self.grid.rows and new_cols == self.grid.cols) return;

    // Pre-process: strip right-aligned content (e.g. Starship RPROMPT)
    // placed via cursor-jump that spans the full old width. Without
    // this the wide logical line wraps on shrink, creating garbled
    // fragment rows the shell's SIGWINCH handler can't reach.
    if (new_cols < self.grid.cols) {
        const gap_threshold = @max(8, self.grid.cols / 4);
        for (0..self.grid.rows) |r| {
            if (self.grid.row_wrapped[r]) continue;
            const base = r * self.grid.cols;
            var last: usize = 0;
            for (0..self.grid.cols) |c| {
                if (!grid_mod.isDefaultCell(self.grid.cells[base + c])) last = c + 1;
            }
            if (last <= new_cols) continue;
            var gap_start: usize = 0;
            var gap_len: usize = 0;
            for (0..last) |c| {
                if (grid_mod.isDefaultCell(self.grid.cells[base + c])) {
                    if (gap_len == 0) gap_start = c;
                    gap_len += 1;
                } else {
                    if (gap_len >= gap_threshold and gap_start > 0) {
                        @memset(self.grid.cells[base + gap_start .. base + self.grid.cols], grid_mod.Cell{});
                        break;
                    }
                    gap_len = 0;
                }
            }
        }
    }

    // Migrate scrollback to new column width BEFORE grid.resize, so
    // the drop handler can push reflowed rows at the correct stride.
    if (new_cols != self.scrollback.cols) {
        var new_sb = try scrollback_mod.Scrollback.init(
            self.grid.allocator,
            scrollback_mod.Scrollback.default_max_lines,
            new_cols,
        );
        for (0..self.scrollback.count) |i| {
            const old_line = self.scrollback.getLine(i);
            new_sb.pushLine(old_line, self.scrollback.getLineWrapped(i));
        }
        self.scrollback.deinit();
        self.scrollback = new_sb;
    }

    const old_rows = self.grid.rows;
    const old_cursor_row = self.cursor.row;

    const drop: ?grid_mod.Grid.DropHandler = if (!self.alt_active)
        .{ .ctx = @ptrCast(self), .save = onDropRow }
    else
        null;
    try self.grid.resize(new_rows, new_cols, &self.cursor.row, &self.cursor.col, drop);
    try self.inactive_grid.resizeNoReflow(new_rows, new_cols);

    if (!self.alt_active) {
        if (new_rows > old_rows and old_cursor_row == old_rows - 1) {
            // Pin content to bottom: cursor was at the last row of the
            // old grid, so keep it anchored at the bottom after growing.
            // Shift content down so blank rows appear above.
            const shift = new_rows - old_rows;
            const cols = self.grid.cols;

            // Find how many rows actually have content
            var last_used: usize = 0;
            for (0..new_rows) |r| {
                const base = r * cols;
                for (0..cols) |col| {
                    if (!grid_mod.isDefaultCell(self.grid.cells[base + col])) {
                        last_used = r + 1;
                        break;
                    }
                }
            }

            if (last_used > 0 and last_used + shift <= new_rows) {
                // Shift rows down (iterate in reverse to avoid overwriting)
                var r: usize = last_used;
                while (r > 0) {
                    r -= 1;
                    const dst = r + shift;
                    @memcpy(
                        self.grid.cells[dst * cols .. (dst + 1) * cols],
                        self.grid.cells[r * cols .. (r + 1) * cols],
                    );
                    self.grid.row_wrapped[dst] = self.grid.row_wrapped[r];
                }
                // Clear the top rows that are now blank
                for (0..shift) |rr| {
                    @memset(self.grid.cells[rr * cols .. (rr + 1) * cols], grid_mod.Cell{});
                    self.grid.row_wrapped[rr] = false;
                }
                self.cursor.row += shift;
            }
        } else {
            // Compact content upward: shift all rows so the first non-empty
            // row lands at row 0. Shells often push the cursor to the bottom
            // of the initial grid; after growing, that leaves empty rows above.
            var first_used: usize = new_rows;
            for (0..new_rows) |r| {
                const base = r * self.grid.cols;
                for (0..self.grid.cols) |col| {
                    if (!grid_mod.isDefaultCell(self.grid.cells[base + col])) {
                        first_used = r;
                        break;
                    }
                }
                if (first_used < new_rows) break;
            }
            if (first_used > 0 and first_used < new_rows) {
                const cols = self.grid.cols;
                for (first_used..new_rows) |r| {
                    const dst = r - first_used;
                    @memcpy(
                        self.grid.cells[dst * cols .. (dst + 1) * cols],
                        self.grid.cells[r * cols .. (r + 1) * cols],
                    );
                    self.grid.row_wrapped[dst] = self.grid.row_wrapped[r];
                }
                for ((new_rows - first_used)..new_rows) |r| {
                    @memset(self.grid.cells[r * cols .. (r + 1) * cols], grid_mod.Cell{});
                    self.grid.row_wrapped[r] = false;
                }
                self.cursor.row -|= first_used;
            }
        }
    }

    self.viewport_offset = 0;

    for (self.cursor.row..new_rows) |r| {
        self.grid.row_wrapped[r] = false;
    }

    clampState(self, new_rows, new_cols);
    clampInactiveState(self, new_rows, new_cols);

    self.wrap_next = false;
    self.dirty.markAll(new_rows);
}
