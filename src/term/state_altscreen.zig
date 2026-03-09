const std = @import("std");
const TerminalState = @import("state.zig").TerminalState;
const Grid = @import("grid.zig").Grid;
const grid_mod = @import("grid.zig");
const Cell = grid_mod.Cell;
const Style = grid_mod.Style;

/// Swap ring's screen rows ↔ inactive_grid cells + swap cursors/state.
fn swapBuffers(self: *TerminalState) void {
    const Cursor = @import("state.zig").Cursor;
    const SavedCursor = @import("state.zig").SavedCursor;

    // Copy ring's screen rows into inactive_grid, and vice versa.
    const rows = self.ring.screen_rows;
    const cols = self.ring.cols;
    const copy_rows = @min(rows, self.inactive_grid.rows);
    const copy_cols = @min(cols, self.inactive_grid.cols);

    for (0..copy_rows) |r| {
        const ring_row = self.ring.getScreenRowMut(r);
        const grid_start = r * self.inactive_grid.cols;
        const grid_row = self.inactive_grid.cells[grid_start .. grid_start + self.inactive_grid.cols];
        // Swap cell by cell for the overlapping area
        for (0..copy_cols) |c| {
            const tmp = ring_row[c];
            ring_row[c] = grid_row[c];
            grid_row[c] = tmp;
        }
        // Swap wrapped flags
        const ring_wrapped = self.ring.getScreenWrapped(r);
        const grid_wrapped = self.inactive_grid.row_wrapped[r];
        self.ring.setScreenWrapped(r, grid_wrapped);
        self.inactive_grid.row_wrapped[r] = ring_wrapped;
    }

    std.mem.swap(Cursor, &self.cursor, &self.inactive_cursor);
    std.mem.swap(Style, &self.pen, &self.inactive_pen);
    std.mem.swap(usize, &self.scroll_top, &self.inactive_scroll_top);
    std.mem.swap(usize, &self.scroll_bottom, &self.inactive_scroll_bottom);
    std.mem.swap(?SavedCursor, &self.saved_cursor, &self.inactive_saved_cursor);
    std.mem.swap(u32, &self.pen_link_id, &self.inactive_pen_link_id);
}

pub fn enterAltScreen(self: *TerminalState) void {
    if (self.alt_active) return;
    swapBuffers(self);
    // Clear the screen (now alt screen content in ring's screen rows)
    for (0..self.ring.screen_rows) |r| {
        self.ring.clearScreenRow(r);
    }
    self.cursor = .{};
    self.pen = .{};
    self.pen_link_id = 0;
    self.scroll_top = 0;
    self.scroll_bottom = self.ring.screen_rows - 1;
    self.saved_cursor = null;
    self.wrap_next = false;
    self.alt_active = true;
    self.kittyResetFlags();
    self.dirty.markAll(self.ring.screen_rows);
}

pub fn leaveAltScreen(self: *TerminalState) void {
    if (!self.alt_active) return;
    swapBuffers(self);
    self.alt_active = false;
    self.kittyResetFlags();
    self.dirty.markAll(self.ring.screen_rows);
}
