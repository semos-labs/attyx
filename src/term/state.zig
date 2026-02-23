const std = @import("std");
const grid_mod = @import("grid.zig");
const actions_mod = @import("actions.zig");
const sgr_mod = @import("sgr.zig");
const dirty_mod = @import("dirty.zig");
const scrollback_mod = @import("scrollback.zig");

pub const Grid = grid_mod.Grid;
pub const Cell = grid_mod.Cell;
pub const Color = grid_mod.Color;
pub const Style = grid_mod.Style;
pub const Action = actions_mod.Action;
pub const ControlCode = actions_mod.ControlCode;

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
};

/// Snapshot of cursor + attributes, captured by DECSC / CSI s.
pub const SavedCursor = struct {
    cursor: Cursor,
    pen: Style,
    scroll_top: usize,
    scroll_bottom: usize,
};

pub const TerminalState = struct {
    // -- Active buffer state (the currently displayed screen) ---------------
    grid: Grid,
    cursor: Cursor = .{},
    pen: Style = .{},
    scroll_top: usize = 0,
    scroll_bottom: usize = 0,
    saved_cursor: ?SavedCursor = null,
    pen_link_id: u32 = 0,

    // -- Inactive buffer state (swapped on alt screen toggle) --------------
    inactive_grid: Grid,
    inactive_cursor: Cursor = .{},
    inactive_pen: Style = .{},
    inactive_scroll_top: usize = 0,
    inactive_scroll_bottom: usize = 0,
    inactive_saved_cursor: ?SavedCursor = null,
    inactive_pen_link_id: u32 = 0,

    /// True when the alternate screen is the active buffer.
    alt_active: bool = false,

    // -- Global state (shared across buffers) ------------------------------
    link_uris: std.ArrayListUnmanaged([]const u8) = .{},
    next_link_id: u32 = 1,
    title: ?[]const u8 = null,

    // -- Wrap state (per-buffer, cleared by cursor movement) ----------------
    wrap_next: bool = false,

    // -- Damage tracking (row-level dirty bitset) --------------------------
    dirty: dirty_mod.DirtyRows = .{},

    // -- Response buffer (filled by DSR/DA, consumed by app layer) ----------
    response_buf: [128]u8 = undefined,
    response_len: usize = 0,

    // -- Scrollback (main screen only, not alt) ------------------------------
    scrollback: scrollback_mod.Scrollback,
    viewport_offset: usize = 0,

    // -- Terminal modes (global, not per-buffer) ----------------------------
    auto_wrap: bool = true,
    bracketed_paste: bool = false,
    mouse_tracking: actions_mod.MouseTrackingMode = .off,
    mouse_sgr: bool = false,
    cursor_keys_app: bool = false,

    pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !TerminalState {
        var main_grid = try Grid.init(allocator, rows, cols);
        errdefer main_grid.deinit();
        var alt_grid = try Grid.init(allocator, rows, cols);
        errdefer alt_grid.deinit();
        const sb = try scrollback_mod.Scrollback.init(
            allocator,
            scrollback_mod.Scrollback.default_max_lines,
            cols,
        );
        return .{
            .grid = main_grid,
            .scroll_bottom = rows - 1,
            .inactive_grid = alt_grid,
            .inactive_scroll_bottom = rows - 1,
            .scrollback = sb,
        };
    }

    pub fn deinit(self: *TerminalState) void {
        const alloc = self.grid.allocator;
        for (self.link_uris.items) |uri| alloc.free(uri);
        self.link_uris.deinit(alloc);
        if (self.title) |t| alloc.free(t);
        self.scrollback.deinit();
        self.grid.deinit();
        self.inactive_grid.deinit();
    }

    /// Look up the URI for a given link_id. Returns null for id 0 or unknown ids.
    pub fn getLinkUri(self: *const TerminalState, link_id: u32) ?[]const u8 {
        if (link_id == 0) return null;
        const idx = link_id - 1;
        if (idx >= self.link_uris.items.len) return null;
        return self.link_uris.items[idx];
    }

    /// Apply a single Action to the terminal state.
    pub fn apply(self: *TerminalState, action: Action) void {
        // Clear wrap_next for cursor-moving actions.
        switch (action) {
            .print, .nop, .sgr, .hyperlink_start, .hyperlink_end, .set_title, .dec_private_mode, .device_status, .cursor_position_report, .device_attributes => {},
            else => {
                self.wrap_next = false;
            },
        }

        // Mark old cursor row dirty for cursor overlay (before action moves it).
        const old_cursor_row = self.cursor.row;

        switch (action) {
            .print => |cp| self.printChar(cp),
            .control => |code| switch (code) {
                .lf => self.lineFeed(),
                .cr => self.carriageReturn(),
                .bs => self.backspace(),
                .tab => self.tab(),
            },
            .nop => {},
            .cursor_abs => |abs| self.cursorAbsolute(abs),
            .cursor_rel => |rel| self.cursorRelative(rel),
            .cursor_col_abs => |col| {
                self.cursor.col = @min(@as(usize, col), self.grid.cols - 1);
            },
            .cursor_row_abs => |row| {
                self.cursor.row = @min(@as(usize, row), self.grid.rows - 1);
            },
            .cursor_next_line => |n| {
                self.cursorRelative(.{ .dir = .down, .n = n });
                self.cursor.col = 0;
            },
            .cursor_prev_line => |n| {
                self.cursorRelative(.{ .dir = .up, .n = n });
                self.cursor.col = 0;
            },
            .erase_display => |mode| self.eraseInDisplay(mode),
            .erase_line => |mode| {
                self.eraseInLine(mode);
                self.dirty.mark(self.cursor.row);
            },
            .insert_lines => |n| {
                self.grid.scrollDownRegionN(self.cursor.row, self.scroll_bottom, @intCast(n));
                self.dirty.markRange(self.cursor.row, self.scroll_bottom);
            },
            .delete_lines => |n| {
                if (self.cursor.row == self.scroll_top) {
                    const count: usize = @min(@as(usize, @intCast(n)), self.scroll_bottom - self.cursor.row + 1);
                    for (0..count) |_| {
                        self.saveToScrollback();
                        self.grid.scrollUpRegion(self.cursor.row, self.scroll_bottom);
                    }
                    self.dirty.markRange(self.cursor.row, self.scroll_bottom);
                } else {
                    self.grid.scrollUpRegionN(self.cursor.row, self.scroll_bottom, @intCast(n));
                    self.dirty.markRange(self.cursor.row, self.scroll_bottom);
                }
            },
            .insert_chars => |n| {
                self.grid.insertChars(self.cursor.row, self.cursor.col, @intCast(n));
                self.dirty.mark(self.cursor.row);
            },
            .delete_chars => |n| {
                self.grid.deleteChars(self.cursor.row, self.cursor.col, @intCast(n));
                self.dirty.mark(self.cursor.row);
            },
            .erase_chars => |n| {
                self.grid.eraseChars(self.cursor.row, self.cursor.col, @intCast(n));
                self.dirty.mark(self.cursor.row);
            },
            .scroll_up => |n| {
                const count: usize = @min(@as(usize, @intCast(n)), self.scroll_bottom - self.scroll_top + 1);
                for (0..count) |_| {
                    self.saveToScrollback();
                    self.grid.scrollUpRegion(self.scroll_top, self.scroll_bottom);
                }
                self.dirty.markRange(self.scroll_top, self.scroll_bottom);
            },
            .scroll_down => |n| {
                self.grid.scrollDownRegionN(self.scroll_top, self.scroll_bottom, @intCast(n));
                self.dirty.markRange(self.scroll_top, self.scroll_bottom);
            },
            .sgr => |sgr| sgr_mod.applySgr(&self.pen, sgr),
            .set_scroll_region => |region| self.setScrollRegion(region),
            .index => self.cursorDown(),
            .reverse_index => self.reverseIndex(),
            .enter_alt_screen => self.enterAltScreen(),
            .leave_alt_screen => self.leaveAltScreen(),
            .save_cursor => self.saveCursor(),
            .restore_cursor => self.restoreCursor(),
            .hyperlink_start => |uri| self.startHyperlink(uri),
            .hyperlink_end => self.endHyperlink(),
            .set_title => |t| self.setTitle(t),
            .dec_private_mode => |modes| self.applyDecPrivateModes(modes),
            .device_status => self.respondDeviceStatus(),
            .cursor_position_report => self.respondCursorPosition(),
            .device_attributes => self.respondDeviceAttributes(),
        }

        // Mark old + new cursor rows dirty for cursor overlay movement.
        if (self.cursor.row != old_cursor_row) {
            self.dirty.mark(old_cursor_row);
            self.dirty.mark(self.cursor.row);
        }
    }

    // -- Text output -------------------------------------------------------

    fn printChar(self: *TerminalState, char: u21) void {
        if (self.wrap_next) {
            if (self.auto_wrap) {
                self.grid.row_wrapped[self.cursor.row] = true;
                self.cursor.col = 0;
                self.cursorDown();
            }
            self.wrap_next = false;
        }

        self.grid.setCell(self.cursor.row, self.cursor.col, .{
            .char = char,
            .style = self.pen,
            .link_id = self.pen_link_id,
        });
        self.dirty.mark(self.cursor.row);

        if (self.cursor.col >= self.grid.cols - 1) {
            self.wrap_next = self.auto_wrap;
        } else {
            self.cursor.col += 1;
        }
    }

    // -- C0 control characters ---------------------------------------------

    fn lineFeed(self: *TerminalState) void {
        self.cursorDown();
    }

    fn carriageReturn(self: *TerminalState) void {
        self.cursor.col = 0;
    }

    fn backspace(self: *TerminalState) void {
        if (self.cursor.col > 0) {
            self.cursor.col -= 1;
        }
    }

    fn tab(self: *TerminalState) void {
        const next_stop = ((self.cursor.col / 8) + 1) * 8;
        self.cursor.col = @min(next_stop, self.grid.cols - 1);
    }

    /// Save the top visible row to scrollback before it gets shifted out.
    /// Only saves when on the main screen with scroll_top at row 0.
    fn saveToScrollback(self: *TerminalState) void {
        if (self.alt_active) return;
        if (self.scroll_top != 0) return;
        const row_cells = self.grid.cells[0..self.grid.cols];
        self.scrollback.pushLine(row_cells);
        if (self.viewport_offset > 0) self.viewport_offset += 1;
    }

    fn cursorDown(self: *TerminalState) void {
        if (self.cursor.row == self.scroll_bottom) {
            self.saveToScrollback();
            self.grid.scrollUpRegion(self.scroll_top, self.scroll_bottom);
            self.dirty.markRange(self.scroll_top, self.scroll_bottom);
        } else if (self.cursor.row < self.grid.rows - 1) {
            self.cursor.row += 1;
        }
    }

    fn reverseIndex(self: *TerminalState) void {
        if (self.cursor.row == self.scroll_top) {
            self.grid.scrollDownRegion(self.scroll_top, self.scroll_bottom);
            self.dirty.markRange(self.scroll_top, self.scroll_bottom);
        } else if (self.cursor.row > 0) {
            self.cursor.row -= 1;
        }
    }

    // -- CSI cursor positioning --------------------------------------------

    fn cursorAbsolute(self: *TerminalState, abs: actions_mod.CursorAbs) void {
        self.cursor.row = @min(@as(usize, abs.row), self.grid.rows - 1);
        self.cursor.col = @min(@as(usize, abs.col), self.grid.cols - 1);
    }

    fn cursorRelative(self: *TerminalState, rel: actions_mod.CursorRel) void {
        const n: usize = @intCast(rel.n);
        switch (rel.dir) {
            .up => self.cursor.row -|= n,
            .down => self.cursor.row = @min(self.cursor.row +| n, self.grid.rows - 1),
            .right => self.cursor.col = @min(self.cursor.col +| n, self.grid.cols - 1),
            .left => self.cursor.col -|= n,
        }
    }

    // -- CSI erase ---------------------------------------------------------

    fn eraseInDisplay(self: *TerminalState, mode: actions_mod.EraseMode) void {
        const cols = self.grid.cols;
        switch (mode) {
            .to_end => {
                const start = self.cursor.row * cols + self.cursor.col;
                @memset(self.grid.cells[start..], Cell{});
                for (self.cursor.row..self.grid.rows) |r| {
                    self.grid.row_wrapped[r] = false;
                }
                self.dirty.markRange(self.cursor.row, self.grid.rows - 1);
            },
            .to_start => {
                const end = self.cursor.row * cols + self.cursor.col + 1;
                @memset(self.grid.cells[0..end], Cell{});
                for (0..self.cursor.row + 1) |r| {
                    self.grid.row_wrapped[r] = false;
                }
                self.dirty.markRange(0, self.cursor.row);
            },
            .all => {
                if (!self.alt_active) {
                    // If the screen has visible content, save it to
                    // scrollback and pin the cursor to the bottom so
                    // the shell's next prompt lands there (e.g. `clear`).
                    // On an already-empty screen this is a no-op.
                    var last_content_row: usize = 0;
                    var has_content = false;
                    {
                        var r: usize = self.grid.rows;
                        while (r > 0) {
                            r -= 1;
                            const base = r * cols;
                            for (0..cols) |c| {
                                if (!grid_mod.isDefaultCell(self.grid.cells[base + c])) {
                                    last_content_row = r;
                                    has_content = true;
                                    break;
                                }
                            }
                            if (has_content) break;
                        }
                    }
                    if (has_content) {
                        for (0..last_content_row + 1) |r| {
                            const start = r * cols;
                            self.scrollback.pushLine(self.grid.cells[start .. start + cols]);
                        }
                        self.cursor.row = self.grid.rows - 1;
                    }
                }
                @memset(self.grid.cells, Cell{});
                @memset(self.grid.row_wrapped[0..self.grid.rows], false);
                self.dirty.markAll(self.grid.rows);
            },
        }
    }

    fn eraseInLine(self: *TerminalState, mode: actions_mod.EraseMode) void {
        const cols = self.grid.cols;
        const row_start = self.cursor.row * cols;
        switch (mode) {
            .to_end => {
                @memset(self.grid.cells[row_start + self.cursor.col .. row_start + cols], Cell{});
                self.grid.row_wrapped[self.cursor.row] = false;
            },
            .to_start => {
                @memset(self.grid.cells[row_start .. row_start + self.cursor.col + 1], Cell{});
            },
            .all => {
                self.grid.clearRow(self.cursor.row);
            },
        }
    }

    // -- DECSTBM -----------------------------------------------------------

    fn setScrollRegion(self: *TerminalState, region: actions_mod.ScrollRegion) void {
        const rows = self.grid.rows;
        const top_1: usize = if (region.top == 0) 1 else @intCast(@min(region.top, @as(u16, @intCast(rows))));
        const bottom_1: usize = if (region.bottom == 0) rows else @intCast(@min(region.bottom, @as(u16, @intCast(rows))));

        const top = top_1 - 1;
        const bottom = bottom_1 - 1;

        if (top >= bottom) return;

        self.scroll_top = top;
        self.scroll_bottom = bottom;
    }

    // -- DEC private modes ---------------------------------------------------

    fn applyDecPrivateModes(self: *TerminalState, modes: actions_mod.DecPrivateModes) void {
        for (modes.params[0..modes.len]) |param| {
            if (modes.set) {
                switch (param) {
                    1 => self.cursor_keys_app = true,
                    7 => self.auto_wrap = true,
                    47, 1047, 1049 => self.enterAltScreen(),
                    1000 => self.mouse_tracking = .x10,
                    1002 => self.mouse_tracking = .button_event,
                    1003 => self.mouse_tracking = .any_event,
                    1006 => self.mouse_sgr = true,
                    2004 => self.bracketed_paste = true,
                    else => {},
                }
            } else {
                switch (param) {
                    1 => self.cursor_keys_app = false,
                    7 => {
                        self.auto_wrap = false;
                        self.wrap_next = false;
                    },
                    47, 1047, 1049 => self.leaveAltScreen(),
                    1000 => {
                        if (self.mouse_tracking == .x10) self.mouse_tracking = .off;
                    },
                    1002 => {
                        if (self.mouse_tracking == .button_event) self.mouse_tracking = .off;
                    },
                    1003 => {
                        if (self.mouse_tracking == .any_event) self.mouse_tracking = .off;
                    },
                    1006 => self.mouse_sgr = false,
                    2004 => self.bracketed_paste = false,
                    else => {},
                }
            }
        }
    }

    // -- Alternate screen --------------------------------------------------

    fn swapBuffers(self: *TerminalState) void {
        std.mem.swap(Grid, &self.grid, &self.inactive_grid);
        std.mem.swap(Cursor, &self.cursor, &self.inactive_cursor);
        std.mem.swap(Style, &self.pen, &self.inactive_pen);
        std.mem.swap(usize, &self.scroll_top, &self.inactive_scroll_top);
        std.mem.swap(usize, &self.scroll_bottom, &self.inactive_scroll_bottom);
        std.mem.swap(?SavedCursor, &self.saved_cursor, &self.inactive_saved_cursor);
        std.mem.swap(u32, &self.pen_link_id, &self.inactive_pen_link_id);
    }

    fn enterAltScreen(self: *TerminalState) void {
        if (self.alt_active) return;
        self.swapBuffers();
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
        self.dirty.markAll(self.grid.rows);
    }

    fn leaveAltScreen(self: *TerminalState) void {
        if (!self.alt_active) return;
        self.swapBuffers();
        self.alt_active = false;
        self.dirty.markAll(self.grid.rows);
    }

    // -- Cursor save / restore ---------------------------------------------

    fn saveCursor(self: *TerminalState) void {
        self.saved_cursor = .{
            .cursor = self.cursor,
            .pen = self.pen,
            .scroll_top = self.scroll_top,
            .scroll_bottom = self.scroll_bottom,
        };
    }

    fn restoreCursor(self: *TerminalState) void {
        if (self.saved_cursor) |saved| {
            self.cursor = saved.cursor;
            self.pen = saved.pen;
            self.scroll_top = saved.scroll_top;
            self.scroll_bottom = saved.scroll_bottom;
        }
    }

    // -- OSC: hyperlinks + title -------------------------------------------

    fn startHyperlink(self: *TerminalState, uri: []const u8) void {
        if (uri.len == 0) {
            self.pen_link_id = 0;
            return;
        }
        const alloc = self.grid.allocator;
        const uri_copy = alloc.dupe(u8, uri) catch return;
        self.link_uris.append(alloc, uri_copy) catch {
            alloc.free(uri_copy);
            return;
        };
        self.pen_link_id = self.next_link_id;
        self.next_link_id += 1;
    }

    fn endHyperlink(self: *TerminalState) void {
        self.pen_link_id = 0;
    }

    fn setTitle(self: *TerminalState, title_slice: []const u8) void {
        const alloc = self.grid.allocator;
        if (self.title) |old| alloc.free(old);
        if (title_slice.len == 0) {
            self.title = null;
            return;
        }
        self.title = alloc.dupe(u8, title_slice) catch null;
    }

    // -- Device reports (DSR / DA) -------------------------------------------

    fn appendResponse(self: *TerminalState, data: []const u8) void {
        const avail = self.response_buf.len - self.response_len;
        const n = @min(data.len, avail);
        @memcpy(self.response_buf[self.response_len .. self.response_len + n], data[0..n]);
        self.response_len += n;
    }

    fn respondDeviceStatus(self: *TerminalState) void {
        self.appendResponse("\x1b[0n");
    }

    fn respondCursorPosition(self: *TerminalState) void {
        var buf: [32]u8 = undefined;
        const row = self.cursor.row + 1;
        const col = self.cursor.col + 1;
        const len = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ row, col }) catch return;
        self.appendResponse(len);
    }

    fn respondDeviceAttributes(self: *TerminalState) void {
        self.appendResponse("\x1b[?62;c");
    }

    /// Drain the response buffer. Returns the pending response bytes and
    /// resets the buffer. Caller must write these to the PTY.
    pub fn drainResponse(self: *TerminalState) ?[]const u8 {
        if (self.response_len == 0) return null;
        const len = self.response_len;
        self.response_len = 0;
        return self.response_buf[0..len];
    }

    // -- Resize ---------------------------------------------------------------

    /// Grid.DropHandler callback: pushes a dropped reflow row into scrollback.
    fn onDropRow(ctx_raw: *anyopaque, row_cells: []const grid_mod.Cell) void {
        const self: *TerminalState = @ptrCast(@alignCast(ctx_raw));
        self.scrollback.pushLine(row_cells);
    }

    /// Resize both grids to new dimensions. Preserves overlapping content,
    /// clamps cursors and scroll regions. Marks all rows dirty.
    pub fn resize(self: *TerminalState, new_rows: usize, new_cols: usize) !void {
        if (new_rows == self.grid.rows and new_cols == self.grid.cols) return;

        // Pre-process: strip right-aligned content (e.g. Starship RPROMPT)
        // placed via cursor-jump that spans the full old width.  Without
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
                new_sb.pushLine(old_line);
            }
            self.scrollback.deinit();
            self.scrollback = new_sb;
        }

        // Remember whether the cursor was at the bottom of the old grid.
        // Only pin content to the bottom after resize if the viewport was
        // fully utilised (cursor at last row), so partially-filled grids
        // (e.g. early after launch with little output) stay top-aligned.
        const was_at_bottom = !self.alt_active and self.cursor.row >= self.grid.rows - 1;

        // Grid resize with drop handler: rows scrolled off the top during
        // reflow are saved to scrollback instead of being silently lost.
        const drop: ?grid_mod.Grid.DropHandler = if (!self.alt_active)
            .{ .ctx = @ptrCast(self), .save = onDropRow }
        else
            null;
        try self.grid.resize(new_rows, new_cols, &self.cursor.row, &self.cursor.col, drop);
        try self.inactive_grid.resizeNoReflow(new_rows, new_cols);

        // Pin content to the bottom: if there's empty space below the
        // last content row, shift everything down so the prompt stays
        // at the bottom of the viewport.
        if (was_at_bottom) {
            var content_bottom: usize = self.cursor.row;
            {
                var r: usize = new_rows;
                while (r > content_bottom + 1) {
                    r -= 1;
                    const base = r * self.grid.cols;
                    for (0..self.grid.cols) |col| {
                        if (!grid_mod.isDefaultCell(self.grid.cells[base + col])) {
                            content_bottom = r;
                            break;
                        }
                    }
                    if (content_bottom == r) break;
                }
            }

            const shift = new_rows - 1 - content_bottom;
            if (shift > 0) {
                const cols = self.grid.cols;
                var r: usize = new_rows;
                while (r > shift) {
                    r -= 1;
                    const src = r - shift;
                    @memcpy(
                        self.grid.cells[r * cols .. (r + 1) * cols],
                        self.grid.cells[src * cols .. (src + 1) * cols],
                    );
                    self.grid.row_wrapped[r] = self.grid.row_wrapped[src];
                }
                for (0..shift) |row| {
                    @memset(self.grid.cells[row * cols .. (row + 1) * cols], grid_mod.Cell{});
                    self.grid.row_wrapped[row] = false;
                }
                self.cursor.row += shift;
            }
        }

        self.viewport_offset = 0;

        for (self.cursor.row..new_rows) |r| {
            self.grid.row_wrapped[r] = false;
        }

        self.clampState(new_rows, new_cols);
        self.clampInactiveState(new_rows, new_cols);

        self.wrap_next = false;
        self.dirty.markAll(new_rows);
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
};
