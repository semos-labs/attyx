const std = @import("std");
const TerminalState = @import("state.zig").TerminalState;
const Grid = @import("grid.zig").Grid;
const grid_mod = @import("grid.zig");
const Cell = grid_mod.Cell;
const Style = grid_mod.Style;

pub fn swapBuffers(self: *TerminalState) void {
    const Cursor = @import("state.zig").Cursor;
    const SavedCursor = @import("state.zig").SavedCursor;
    std.mem.swap(Grid, &self.grid, &self.inactive_grid);
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
    @memset(self.grid.cells, Cell{});
    @memset(&self.grid.row_wrapped, false);
    self.cursor = .{};
    self.pen = .{};
    self.pen_link_id = 0;
    self.scroll_top = 0;
    self.scroll_bottom = self.grid.rows - 1;
    self.saved_cursor = null;
    self.wrap_next = false;
    self.alt_active = true;
    self.kittyResetFlags();
    self.dirty.markAll(self.grid.rows);
}

pub fn leaveAltScreen(self: *TerminalState) void {
    if (!self.alt_active) return;
    swapBuffers(self);
    self.alt_active = false;
    self.kittyResetFlags();
    self.dirty.markAll(self.grid.rows);
}
