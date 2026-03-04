const std = @import("std");
const grid_mod = @import("grid.zig");
const actions_mod = @import("actions.zig");
const sgr_mod = @import("sgr.zig");
const dirty_mod = @import("dirty.zig");
const scrollback_mod = @import("scrollback.zig");
const graphics_store_mod = @import("graphics_store.zig");
const unicode = @import("unicode.zig");

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
    working_directory: ?[]const u8 = null,

    // -- Wrap state (per-buffer, cleared by cursor movement) ----------------
    wrap_next: bool = false,

    // -- Damage tracking (row-level dirty bitset) --------------------------
    dirty: dirty_mod.DirtyRows = .{},

    // -- Response buffer (filled by DSR/DA/graphics, consumed by app layer) --
    response_buf: [512]u8 = undefined,
    response_len: usize = 0,

    // -- Inject buffer (OSC 7337 write-main, consumed by app layer) ----------
    inject_buf: [512]u8 = undefined,
    inject_len: usize = 0,

    // -- Scrollback (main screen only, not alt) ------------------------------
    scrollback: scrollback_mod.Scrollback,
    viewport_offset: usize = 0,

    // -- Kitty graphics protocol ---------------------------------------------
    graphics_store: ?*graphics_store_mod.GraphicsStore = null,

    // -- Terminal modes (global, not per-buffer) ----------------------------
    auto_wrap: bool = true,
    bracketed_paste: bool = false,
    mouse_tracking: actions_mod.MouseTrackingMode = .off,
    mouse_sgr: bool = false,
    cursor_keys_app: bool = false,
    keypad_app_mode: bool = false,
    cursor_visible: bool = true,
    cursor_shape: actions_mod.CursorShape = .blinking_block,
    /// DEC private mode 2026 — Synchronized Output Mode.
    /// When true the renderer should defer painting until the mode is reset.
    synchronized_output: bool = false,

    /// Whether to reflow content on resize (configurable, default true).
    reflow_on_resize: bool = true,

    /// When true, apply() drops all actions until a CR or LF arrives.
    /// Used to suppress the shell echo of injected commands.
    suppress_echo: bool = false,

    /// Kitty keyboard protocol flags stack (max 16 entries).
    kitty_kbd_flags: [16]u5 = .{0} ** 16,
    kitty_kbd_stack_len: u4 = 0,

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
        const gs = try allocator.create(graphics_store_mod.GraphicsStore);
        gs.* = graphics_store_mod.GraphicsStore.init(allocator);
        return .{
            .grid = main_grid,
            .scroll_bottom = rows - 1,
            .inactive_grid = alt_grid,
            .inactive_scroll_bottom = rows - 1,
            .scrollback = sb,
            .graphics_store = gs,
        };
    }

    pub fn deinit(self: *TerminalState) void {
        const alloc = self.grid.allocator;
        for (self.link_uris.items) |uri| alloc.free(uri);
        self.link_uris.deinit(alloc);
        if (self.title) |t| alloc.free(t);
        if (self.working_directory) |wd| alloc.free(wd);
        if (self.graphics_store) |gs| {
            gs.deinit();
            alloc.destroy(gs);
        }
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
        // Suppress echoed command text until a CR or LF signals acceptance.
        if (self.suppress_echo) {
            if (action == .control and (action.control == .lf or action.control == .cr)) {
                self.suppress_echo = false;
            }
            return;
        }

        // Clear wrap_next for cursor-moving actions.
        switch (action) {
            .print, .nop, .sgr, .hyperlink_start, .hyperlink_end, .set_title, .set_cwd, .dec_private_mode, .device_status, .cursor_position_report, .device_attributes, .secondary_device_attributes, .set_cursor_shape, .query_dec_private_mode, .graphics_command, .kitty_push_flags, .kitty_pop_flags, .kitty_query_flags, .inject_into_main, .dcs_passthrough, .set_keypad_app_mode, .reset_keypad_app_mode => {},
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
            .set_cwd => |u| self.setCwd(u),
            .dec_private_mode => |modes| self.applyDecPrivateModes(modes),
            .device_status => self.respondDeviceStatus(),
            .cursor_position_report => self.respondCursorPosition(),
            .device_attributes => self.respondDeviceAttributes(),
            .secondary_device_attributes => self.respondSecondaryDeviceAttributes(),
            .query_dec_private_mode => |mode| self.respondDecRequestMode(mode),
            .set_cursor_shape => |shape| {
                self.cursor_shape = shape;
            },
            .graphics_command => |raw| self.handleGraphicsCommand(raw),
            .kitty_push_flags => |flags| self.kittyPushFlags(flags),
            .kitty_pop_flags => |n| self.kittyPopFlags(n),
            .kitty_query_flags => self.respondKittyFlags(),
            .inject_into_main => |data| self.appendInject(data),
            .dcs_passthrough => {}, // handled by engine, never reaches here
            .set_keypad_app_mode => self.keypad_app_mode = true,
            .reset_keypad_app_mode => self.keypad_app_mode = false,
        }

        // Mark old + new cursor rows dirty for cursor overlay movement.
        if (self.cursor.row != old_cursor_row) {
            self.dirty.mark(old_cursor_row);
            self.dirty.mark(self.cursor.row);
        }
    }

    // -- Text output -------------------------------------------------------

    const isCombiningMark = unicode.isCombiningMark;
    const isZeroWidth = unicode.isZeroWidth;
    const charDisplayWidth = unicode.charDisplayWidth;

    fn printChar(self: *TerminalState, char: u21) void {
        // Zero-width characters: absorb into the previous cell as combining marks.
        if (isZeroWidth(char) or isCombiningMark(char)) {
            if (self.cursor.col > 0) {
                const prev_col = self.cursor.col - 1;
                const idx = self.cursor.row * self.grid.cols + prev_col;
                if (self.grid.cells[idx].combining[0] == 0) {
                    self.grid.cells[idx].combining[0] = char;
                } else if (self.grid.cells[idx].combining[1] == 0) {
                    self.grid.cells[idx].combining[1] = char;
                }
                self.dirty.mark(self.cursor.row);
            }
            return;
        }

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
        self.scrollback.pushLine(row_cells, self.grid.row_wrapped[0]);
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

    // -- Alternate screen (state_altscreen.zig) ----------------------------
    const enterAltScreen = @import("state_altscreen.zig").enterAltScreen;
    const leaveAltScreen = @import("state_altscreen.zig").leaveAltScreen;

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

    // -- OSC: hyperlinks + title (state_osc.zig) ----------------------------
    const startHyperlink = @import("state_osc.zig").startHyperlink;
    const endHyperlink = @import("state_osc.zig").endHyperlink;
    pub const setTitle = @import("state_osc.zig").setTitle;
    const setCwd = @import("state_osc.zig").setCwd;

    // -- Kitty keyboard protocol ---------------------------------------------

    /// Return the currently active kitty keyboard flags (top of stack, or 0).
    pub fn kittyFlags(self: *const TerminalState) u5 {
        if (self.kitty_kbd_stack_len == 0) return 0;
        return self.kitty_kbd_flags[self.kitty_kbd_stack_len - 1];
    }

    fn kittyPushFlags(self: *TerminalState, flags: u5) void {
        if (self.kitty_kbd_stack_len < 16) {
            self.kitty_kbd_flags[self.kitty_kbd_stack_len] = flags;
            self.kitty_kbd_stack_len += 1;
        } else {
            // Stack full — shift entries down and push at top
            for (0..15) |i| {
                self.kitty_kbd_flags[i] = self.kitty_kbd_flags[i + 1];
            }
            self.kitty_kbd_flags[15] = flags;
        }
    }

    fn kittyPopFlags(self: *TerminalState, n: u8) void {
        const count = @min(n, self.kitty_kbd_stack_len);
        self.kitty_kbd_stack_len -= @intCast(count);
    }

    pub fn kittyResetFlags(self: *TerminalState) void {
        self.kitty_kbd_stack_len = 0;
    }

    // -- Device reports (state_report.zig) -----------------------------------
    pub const appendResponse = @import("state_report.zig").appendResponse;
    pub const respondDeviceStatus = @import("state_report.zig").respondDeviceStatus;
    pub const respondCursorPosition = @import("state_report.zig").respondCursorPosition;
    pub const respondDeviceAttributes = @import("state_report.zig").respondDeviceAttributes;
    pub const respondSecondaryDeviceAttributes = @import("state_report.zig").respondSecondaryDeviceAttributes;
    pub const respondDecRequestMode = @import("state_report.zig").respondDecRequestMode;
    pub const respondKittyFlags = @import("state_report.zig").respondKittyFlags;

    /// Drain the response buffer. Returns the pending response bytes and
    /// resets the buffer. Caller must write these to the PTY.
    pub fn drainResponse(self: *TerminalState) ?[]const u8 {
        if (self.response_len == 0) return null;
        const len = self.response_len;
        self.response_len = 0;
        return self.response_buf[0..len];
    }

    /// Copy data into the inject buffer (OSC 7337 write-main payload).
    fn appendInject(self: *TerminalState, data: []const u8) void {
        const avail = self.inject_buf.len - self.inject_len;
        const n = @min(data.len, avail);
        if (n > 0) {
            @memcpy(self.inject_buf[self.inject_len..][0..n], data[0..n]);
            self.inject_len += n;
        }
    }

    /// Drain the inject buffer. Returns the pending payload and resets.
    /// Caller writes these bytes to the main terminal PTY.
    pub fn drainMainInject(self: *TerminalState) ?[]const u8 {
        if (self.inject_len == 0) return null;
        const len = self.inject_len;
        self.inject_len = 0;
        return self.inject_buf[0..len];
    }

    // -- Graphics (state_graphics.zig) ------------------------------------
    pub const handleGraphicsCommand = @import("state_graphics.zig").handleGraphicsCommand;

    // -- Resize (state_resize.zig) ----------------------------------------
    pub fn resize(self: *TerminalState, new_rows: usize, new_cols: usize) !void {
        return @import("state_resize.zig").resize(self, new_rows, new_cols);
    }
};
