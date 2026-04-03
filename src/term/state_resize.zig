const std = @import("std");
const grid_mod = @import("grid.zig");
const ring_reflow = @import("ring_reflow.zig");

const TerminalState = @import("state.zig").TerminalState;

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

/// Resize both the ring buffer and the inactive grid.
pub fn resize(self: *TerminalState, new_rows: usize, new_cols: usize) !void {
    if (new_rows == self.ring.screen_rows and new_cols == self.ring.cols) return;

    if (self.reflow_on_resize and !self.alt_active) {
        // Full reflow through the ring (scrollback + screen)
        const result = try ring_reflow.resize(
            &self.ring,
            new_rows,
            new_cols,
            self.cursor.row,
            self.cursor.col,
        );
        var old_ring = self.ring;
        self.ring = result.ring;
        old_ring.deinit();
        self.cursor.row = result.cursor_row;
        self.cursor.col = result.cursor_col;

    } else {
        // No reflow (alt screen or disabled)
        const new_ring = try ring_reflow.resizeNoReflow(
            &self.ring,
            new_rows,
            new_cols,
        );
        var old_ring = self.ring;
        self.ring = new_ring;
        old_ring.deinit();
    }

    try self.inactive_grid.resizeNoReflow(new_rows, new_cols);

    self.viewport_offset = 0;

    clampState(self, new_rows, new_cols);
    clampInactiveState(self, new_rows, new_cols);

    self.wrap_next = false;
    self.dirty.markAll(new_rows);
}
