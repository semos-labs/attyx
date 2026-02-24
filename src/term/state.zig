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
    cursor_visible: bool = true,
    cursor_shape: actions_mod.CursorShape = .blinking_block,
    /// DEC private mode 2026 — Synchronized Output Mode.
    /// When true the renderer should defer painting until the mode is reset.
    synchronized_output: bool = false,

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
            .print, .nop, .sgr, .hyperlink_start, .hyperlink_end, .set_title, .dec_private_mode, .device_status, .cursor_position_report, .device_attributes, .secondary_device_attributes, .set_cursor_shape, .query_dec_private_mode => {},
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
            .secondary_device_attributes => self.respondSecondaryDeviceAttributes(),
            .query_dec_private_mode => |mode| self.respondDecRequestMode(mode),
            .set_cursor_shape => |shape| {
                self.cursor_shape = shape;
            },
        }

        // Mark old + new cursor rows dirty for cursor overlay movement.
        if (self.cursor.row != old_cursor_row) {
            self.dirty.mark(old_cursor_row);
            self.dirty.mark(self.cursor.row);
        }
    }

    // -- Text output -------------------------------------------------------

    /// Returns 2 for Unicode characters with East Asian Width W or F (wide),
    /// 1 for everything else. Mirrors the canBeWide() logic in the glyph caches.
    fn charDisplayWidth(char: u21) u2 {
        const cp: u32 = char;
        if (cp < 0x1100) return 1;
        if (cp <= 0x115F) return 2;  // Hangul Jamo
        if (cp == 0x2329 or cp == 0x232A) return 2;
        if (cp >= 0x2E80 and cp <= 0x303E) return 2;
        if (cp >= 0x3041 and cp <= 0x33FF) return 2;
        if (cp >= 0x3400 and cp <= 0x4DBF) return 2;
        if (cp >= 0x4E00 and cp <= 0x9FFF) return 2;
        if (cp >= 0xA000 and cp <= 0xA4CF) return 2;
        if (cp >= 0xA960 and cp <= 0xA97F) return 2;
        if (cp >= 0xAC00 and cp <= 0xD7AF) return 2;
        if (cp >= 0xF900 and cp <= 0xFAFF) return 2;
        if (cp >= 0xFE10 and cp <= 0xFE6F) return 2;
        if (cp >= 0xFF01 and cp <= 0xFF60) return 2;
        if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2;
        if (cp >= 0x1B000 and cp <= 0x1B2FF) return 2;
        if (cp >= 0x1F300 and cp <= 0x1F64F) return 2;
        if (cp >= 0x1F680 and cp <= 0x1F6FF) return 2; // Transport & Map Symbols
        if (cp >= 0x1F7E0 and cp <= 0x1F7FF) return 2; // Coloured circles/squares
        if (cp >= 0x1F900 and cp <= 0x1FAFF) return 2;
        if (cp >= 0x20000 and cp <= 0x2FFFD) return 2;
        if (cp >= 0x30000 and cp <= 0x3FFFD) return 2;
        // Common emoji with Emoji_Presentation that are unambiguously 2-cell:
        if (cp == 0x231A or cp == 0x231B) return 2;
        if (cp >= 0x23E9 and cp <= 0x23F3) return 2;
        if (cp >= 0x23F8 and cp <= 0x23FA) return 2;
        if (cp >= 0x25FB and cp <= 0x25FE) return 2;
        if (cp == 0x2614 or cp == 0x2615) return 2;
        if (cp >= 0x2648 and cp <= 0x2653) return 2;
        if (cp == 0x267F or cp == 0x2693 or cp == 0x26A1) return 2;
        if (cp == 0x26CE or cp == 0x26D4 or cp == 0x26EA) return 2;
        if (cp == 0x26F2 or cp == 0x26F3 or cp == 0x26F5) return 2;
        if (cp == 0x26FA or cp == 0x26FD) return 2;
        if (cp == 0x2702 or cp == 0x2705) return 2;
        if (cp >= 0x2708 and cp <= 0x270D) return 2;
        if (cp == 0x270F or cp == 0x2712 or cp == 0x2714 or cp == 0x2716) return 2;
        if (cp == 0x271D or cp == 0x2721 or cp == 0x2728) return 2;
        if (cp == 0x2733 or cp == 0x2734 or cp == 0x2744 or cp == 0x2747) return 2;
        if (cp == 0x274C or cp == 0x274E) return 2;
        if (cp >= 0x2753 and cp <= 0x2755) return 2;
        if (cp == 0x2757) return 2;
        if (cp == 0x2763 or cp == 0x2764) return 2;
        if (cp >= 0x2795 and cp <= 0x2797) return 2;
        if (cp == 0x27A1 or cp == 0x27B0 or cp == 0x27BF) return 2;
        if (cp == 0x2934 or cp == 0x2935) return 2;
        if (cp >= 0x2B05 and cp <= 0x2B07) return 2;
        if (cp == 0x2B1B or cp == 0x2B1C or cp == 0x2B50 or cp == 0x2B55) return 2;
        return 1;
    }

    fn printChar(self: *TerminalState, char: u21) void {
        // Silently absorb zero-width / combining codepoints that must not occupy a cell.
        if (char == 0xFE0F) return; // VS16 — emoji presentation selector
        if (char == 0x200D) return; // ZWJ — zero width joiner
        if (char == 0x20E3) return; // combining enclosing keycap
        if (char >= 0xFE00 and char <= 0xFE0E) return; // VS1-15 variation selectors
        if (char >= 0x1F3FB and char <= 0x1F3FF) return; // Fitzpatrick skin-tone modifiers

        if (self.wrap_next) {
            if (self.auto_wrap) {
                self.grid.row_wrapped[self.cursor.row] = true;
                self.cursor.col = 0;
                self.cursorDown();
            }
            self.wrap_next = false;
        }

        const width = charDisplayWidth(char);

        self.grid.setCell(self.cursor.row, self.cursor.col, .{
            .char = char,
            .style = self.pen,
            .link_id = self.pen_link_id,
        });
        self.dirty.mark(self.cursor.row);

        if (width == 2 and self.cursor.col + 1 < self.grid.cols) {
            // Place a blank continuation cell at col+1 to hold the second column
            // of the wide glyph. This prevents subsequent narrow characters from
            // overwriting the right half of the rendered 2-cell quad.
            self.grid.setCell(self.cursor.row, self.cursor.col + 1, .{
                .char = ' ',
                .style = self.pen,
                .link_id = self.pen_link_id,
            });
        }

        const advance: usize = width;
        if (self.cursor.col + advance >= self.grid.cols) {
            self.wrap_next = self.auto_wrap;
        } else {
            self.cursor.col += advance;
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

    // -- CSI erase (state_erase.zig) --------------------------------------
    pub fn eraseInDisplay(self: *TerminalState, mode: actions_mod.EraseMode) void {
        @import("state_erase.zig").eraseInDisplay(self, mode);
    }
    pub fn eraseInLine(self: *TerminalState, mode: actions_mod.EraseMode) void {
        @import("state_erase.zig").eraseInLine(self, mode);
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
                    25 => self.cursor_visible = true,
                    47, 1047, 1049 => self.enterAltScreen(),
                    1000 => self.mouse_tracking = .x10,
                    1002 => self.mouse_tracking = .button_event,
                    1003 => self.mouse_tracking = .any_event,
                    1006 => self.mouse_sgr = true,
                    2004 => self.bracketed_paste = true,
                    2026 => self.synchronized_output = true,
                    else => {},
                }
            } else {
                switch (param) {
                    1 => self.cursor_keys_app = false,
                    7 => {
                        self.auto_wrap = false;
                        self.wrap_next = false;
                    },
                    25 => self.cursor_visible = false,
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
                    2026 => self.synchronized_output = false,
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
        self.appendResponse("\x1b[?62c");
    }

    fn respondSecondaryDeviceAttributes(self: *TerminalState) void {
        // VT220-like: type 0, version 10, ROM version 1
        self.appendResponse("\x1b[>0;10;1c");
    }

    fn respondDecRequestMode(self: *TerminalState, mode: u16) void {
        // DECRQM response: ESC[?Ps;Pm$y  where Pm = 0 not recognized, 1 set, 2 reset
        const pm: u8 = switch (mode) {
            2026 => if (self.synchronized_output) 1 else 2,
            else => 0,
        };
        var buf: [32]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "\x1b[?{d};{d}$y", .{ mode, pm }) catch return;
        self.appendResponse(resp);
    }

    /// Drain the response buffer. Returns the pending response bytes and
    /// resets the buffer. Caller must write these to the PTY.
    pub fn drainResponse(self: *TerminalState) ?[]const u8 {
        if (self.response_len == 0) return null;
        const len = self.response_len;
        self.response_len = 0;
        return self.response_buf[0..len];
    }

    // -- Resize (state_resize.zig) ----------------------------------------
    pub fn resize(self: *TerminalState, new_rows: usize, new_cols: usize) !void {
        return @import("state_resize.zig").resize(self, new_rows, new_cols);
    }
};
