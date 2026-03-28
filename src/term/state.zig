const std = @import("std");
const grid_mod = @import("grid.zig");
const actions_mod = @import("actions.zig");
const sgr_mod = @import("sgr.zig");
const dirty_mod = @import("dirty.zig");
const ring_mod = @import("ring.zig");
const graphics_store_mod = @import("graphics_store.zig");
const unicode = @import("unicode.zig");

pub const Grid = grid_mod.Grid;
pub const Cell = grid_mod.Cell;
pub const Color = grid_mod.Color;
pub const Style = grid_mod.Style;
pub const Action = actions_mod.Action;
pub const ControlCode = actions_mod.ControlCode;
pub const RingBuffer = ring_mod.RingBuffer;

/// Colors the terminal reports in response to OSC 10/11/12/4 queries.
/// Set by the app layer from the active theme; defaults match the
/// built-in renderer palette.
pub const ThemeColors = struct {
    fg: grid_mod.Color.Rgb = .{ .r = 220, .g = 220, .b = 220 },
    bg: grid_mod.Color.Rgb = .{ .r = 30, .g = 30, .b = 36 },
    cursor: ?grid_mod.Color.Rgb = null,
    palette: [16]?grid_mod.Color.Rgb = .{null} ** 16,
};

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
    // -- Active buffer: unified ring (scrollback + visible screen) ----------
    ring: RingBuffer,
    cursor: Cursor = .{},
    pen: Style = .{},
    scroll_top: usize = 0,
    scroll_bottom: usize = 0,
    saved_cursor: ?SavedCursor = null,
    pen_link_id: u32 = 0,

    // -- Inactive buffer state (flat Grid for alt screen, no scrollback) ---
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
    title_changed: bool = false,
    working_directory: ?[]const u8 = null,
    shell_path: ?[]const u8 = null,

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

    // -- Notification buffer (OSC 9 / OSC 777, consumed by app layer) -------
    notify_title_buf: [256]u8 = undefined,
    notify_title_len: usize = 0,
    notify_body_buf: [512]u8 = undefined,
    notify_body_len: usize = 0,
    notify_pending: bool = false,

    // -- Viewport offset (scrollback browsing) ------------------------------
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
    synchronized_output: bool = false,

    /// Whether to reflow content on resize (configurable, default true).
    reflow_on_resize: bool = true,

    /// Colors reported by OSC 10/11/12/4 queries (set from active theme).
    theme_colors: ThemeColors = .{},

    suppress_echo: bool = false,

    /// Kitty keyboard protocol flags stack (max 16 entries).
    kitty_kbd_flags: [16]u5 = .{0} ** 16,
    kitty_kbd_stack_len: u4 = 0,

    pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize, scrollback_lines: usize) !TerminalState {
        var main_ring = try RingBuffer.init(allocator, rows, cols, scrollback_lines);
        errdefer main_ring.deinit();
        var alt_grid = try Grid.init(allocator, rows, cols);
        errdefer alt_grid.deinit();
        const gs = try allocator.create(graphics_store_mod.GraphicsStore);
        gs.* = graphics_store_mod.GraphicsStore.init(allocator);
        return .{
            .ring = main_ring,
            .scroll_bottom = rows - 1,
            .inactive_grid = alt_grid,
            .inactive_scroll_bottom = rows - 1,
            .graphics_store = gs,
        };
    }

    pub fn deinit(self: *TerminalState) void {
        const alloc = self.ring.allocator;
        for (self.link_uris.items) |uri| alloc.free(uri);
        self.link_uris.deinit(alloc);
        if (self.title) |t| alloc.free(t);
        if (self.working_directory) |wd| alloc.free(wd);
        if (self.shell_path) |sp| alloc.free(sp);
        if (self.graphics_store) |gs| {
            gs.deinit();
            alloc.destroy(gs);
        }
        self.ring.deinit();
        self.inactive_grid.deinit();
    }

    /// Look up the URI for a given link_id. Returns null for id 0 or unknown ids.
    pub fn getLinkUri(self: *const TerminalState, link_id: u32) ?[]const u8 {
        if (link_id == 0) return null;
        const idx = link_id - 1;
        if (idx >= self.link_uris.items.len) return null;
        return self.link_uris.items[idx];
    }

    /// BCE (Background Color Erase): create a blank cell that preserves the
    /// current pen's background color for erase/scroll/insert operations.
    pub fn bceCell(self: *const TerminalState) Cell {
        if (self.pen.bg == .default) return Cell{};
        return .{ .style = .{ .bg = self.pen.bg } };
    }

    /// Apply a single Action to the terminal state.
    pub fn apply(self: *TerminalState, action: Action) void {
        if (self.suppress_echo) {
            if (action == .control and (action.control == .lf or action.control == .cr)) {
                self.suppress_echo = false;
            }
            return;
        }

        switch (action) {
            .print, .nop, .sgr, .hyperlink_start, .hyperlink_end, .set_title, .set_cwd, .set_shell_path, .dec_private_mode, .device_status, .cursor_position_report, .device_attributes, .secondary_device_attributes, .set_cursor_shape, .query_dec_private_mode, .graphics_command, .kitty_push_flags, .kitty_pop_flags, .kitty_query_flags, .inject_into_main, .dcs_passthrough, .set_keypad_app_mode, .reset_keypad_app_mode, .query_color, .query_palette_color, .notify => {},
            else => {
                self.wrap_next = false;
            },
        }

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
                self.cursor.col = @min(@as(usize, col), self.ring.cols - 1);
            },
            .cursor_row_abs => |row| {
                self.cursor.row = @min(@as(usize, row), self.ring.screen_rows - 1);
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
                self.ring.scrollDownRegionN(self.cursor.row, self.scroll_bottom, @intCast(n), self.bceCell());
                self.dirty.markRange(self.cursor.row, self.scroll_bottom);
            },
            .delete_lines => |n| {
                if (self.cursor.row == self.scroll_top and self.isFullScreenScroll()) {
                    const count: usize = @min(@as(usize, @intCast(n)), self.scroll_bottom - self.cursor.row + 1);
                    for (0..count) |_| {
                        self.fullScreenScroll();
                    }
                    self.dirty.markRange(self.cursor.row, self.scroll_bottom);
                } else {
                    self.ring.scrollUpRegionN(self.cursor.row, self.scroll_bottom, @intCast(n), self.bceCell());
                    self.dirty.markRange(self.cursor.row, self.scroll_bottom);
                }
            },
            .insert_chars => |n| {
                self.ring.insertChars(self.cursor.row, self.cursor.col, @intCast(n), self.bceCell());
                self.dirty.mark(self.cursor.row);
            },
            .delete_chars => |n| {
                self.ring.deleteChars(self.cursor.row, self.cursor.col, @intCast(n), self.bceCell());
                self.dirty.mark(self.cursor.row);
            },
            .erase_chars => |n| {
                self.ring.eraseChars(self.cursor.row, self.cursor.col, @intCast(n), self.bceCell());
                self.dirty.mark(self.cursor.row);
            },
            .scroll_up => |n| {
                const count: usize = @min(@as(usize, @intCast(n)), self.scroll_bottom - self.scroll_top + 1);
                self.scrollUpActiveRegion(count);
                self.dirty.markRange(self.scroll_top, self.scroll_bottom);
            },
            .scroll_down => |n| {
                self.ring.scrollDownRegionN(self.scroll_top, self.scroll_bottom, @intCast(n), self.bceCell());
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
            .set_shell_path => |p| self.setShellPath(p),
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
            .dcs_passthrough => {},
            .set_keypad_app_mode => self.keypad_app_mode = true,
            .reset_keypad_app_mode => self.keypad_app_mode = false,
            .query_color => |target| self.respondColorQuery(target),
            .query_palette_color => |idx| self.respondPaletteColorQuery(idx),
            .notify => |n| self.queueNotification(n.title, n.body),
        }

        if (self.cursor.row != old_cursor_row) {
            self.dirty.mark(old_cursor_row);
            self.dirty.mark(self.cursor.row);
        }
    }

    // -- Text output -------------------------------------------------------

    const isCombiningMark = unicode.isCombiningMark;
    const isZeroWidth = unicode.isZeroWidth;
    const charDisplayWidth = unicode.charDisplayWidth;

    const isTextDefaultEmoji = unicode.isTextDefaultEmoji;

    fn printChar(self: *TerminalState, char: u21) void {
        if (isZeroWidth(char) or isCombiningMark(char)) {
            if (self.cursor.col > 0) {
                const prev_col = self.cursor.col - 1;
                const row_cells = self.ring.getScreenRowMut(self.cursor.row);

                // VS16 (U+FE0F): upgrade text-default emoji to 2-cell width.
                // Write a spacer into the current cell and advance the cursor
                // so the renderer sees a wide emoji.
                if (char == 0xFE0F and isTextDefaultEmoji(row_cells[prev_col].char)) {
                    if (self.cursor.col < self.ring.cols) {
                        row_cells[self.cursor.col] = .{
                            .char = ' ',
                            .style = self.pen,
                            .link_id = self.pen_link_id,
                        };
                        self.cursor.col += 1;
                        if (self.cursor.col >= self.ring.cols) {
                            self.wrap_next = self.auto_wrap;
                        }
                    }
                }

                if (row_cells[prev_col].combining[0] == 0) {
                    row_cells[prev_col].combining[0] = char;
                } else if (row_cells[prev_col].combining[1] == 0) {
                    row_cells[prev_col].combining[1] = char;
                }
                self.dirty.mark(self.cursor.row);
            }
            return;
        }

        if (self.wrap_next) {
            if (self.auto_wrap) {
                self.ring.setScreenWrapped(self.cursor.row, true);
                self.cursor.col = 0;
                self.cursorDown();
            }
            self.wrap_next = false;
        }

        const width = charDisplayWidth(char);

        self.ring.setScreenCell(self.cursor.row, self.cursor.col, .{
            .char = char,
            .style = self.pen,
            .link_id = self.pen_link_id,
        });
        self.dirty.mark(self.cursor.row);

        if (width == 2 and self.cursor.col + 1 < self.ring.cols) {
            self.ring.setScreenCell(self.cursor.row, self.cursor.col + 1, .{
                .char = ' ',
                .style = self.pen,
                .link_id = self.pen_link_id,
            });
        }

        const advance: usize = width;
        if (self.cursor.col + advance >= self.ring.cols) {
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
        self.cursor.col = @min(next_stop, self.ring.cols - 1);
    }

    /// Full-screen scroll: advance the ring window (zero-copy).
    /// Old screen row 0 becomes scrollback, new bottom row is cleared.
    fn fullScreenScroll(self: *TerminalState) void {
        _ = self.ring.advanceScreen();
        if (self.viewport_offset > 0) {
            self.viewport_offset = @min(self.viewport_offset + 1, self.ring.scrollbackCount());
        }
    }

    fn topAnchoredRegionScroll(self: *TerminalState) void {
        self.ring.scrollUpTopAnchoredRegionWithScrollback(self.scroll_bottom, self.bceCell());
        if (self.viewport_offset > 0) {
            self.viewport_offset = @min(self.viewport_offset + 1, self.ring.scrollbackCount());
        }
    }

    /// Returns true when a scroll should use zero-copy ring advance
    /// (full-screen on main buffer with scroll region covering all rows).
    fn isFullScreenScroll(self: *const TerminalState) bool {
        return !self.alt_active and
            self.scroll_top == 0 and
            self.scroll_bottom == self.ring.screen_rows - 1;
    }

    fn isTopAnchoredMainScroll(self: *const TerminalState) bool {
        return !self.alt_active and
            self.scroll_top == 0 and
            self.scroll_bottom < self.ring.screen_rows - 1;
    }

    fn scrollUpActiveRegion(self: *TerminalState, count: usize) void {
        if (count == 0) return;

        if (self.isFullScreenScroll()) {
            for (0..count) |_| self.fullScreenScroll();
            return;
        }

        if (self.isTopAnchoredMainScroll()) {
            for (0..count) |_| self.topAnchoredRegionScroll();
            return;
        }

        self.ring.scrollUpRegionN(self.scroll_top, self.scroll_bottom, count, self.bceCell());
    }

    fn cursorDown(self: *TerminalState) void {
        if (self.cursor.row == self.scroll_bottom) {
            self.scrollUpActiveRegion(1);
            self.dirty.markRange(self.scroll_top, self.scroll_bottom);
        } else if (self.cursor.row < self.ring.screen_rows - 1) {
            self.cursor.row += 1;
        }
    }

    fn reverseIndex(self: *TerminalState) void {
        if (self.cursor.row == self.scroll_top) {
            self.ring.scrollDownRegion(self.scroll_top, self.scroll_bottom, self.bceCell());
            self.dirty.markRange(self.scroll_top, self.scroll_bottom);
        } else if (self.cursor.row > 0) {
            self.cursor.row -= 1;
        }
    }

    // -- CSI cursor positioning --------------------------------------------

    fn cursorAbsolute(self: *TerminalState, abs: actions_mod.CursorAbs) void {
        self.cursor.row = @min(@as(usize, abs.row), self.ring.screen_rows - 1);
        self.cursor.col = @min(@as(usize, abs.col), self.ring.cols - 1);
    }

    fn cursorRelative(self: *TerminalState, rel: actions_mod.CursorRel) void {
        const n: usize = @intCast(rel.n);
        switch (rel.dir) {
            .up => self.cursor.row -|= n,
            .down => self.cursor.row = @min(self.cursor.row +| n, self.ring.screen_rows - 1),
            .right => self.cursor.col = @min(self.cursor.col +| n, self.ring.cols - 1),
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
        const rows = self.ring.screen_rows;
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
    const setShellPath = @import("state_osc.zig").setShellPath;

    // -- Kitty keyboard protocol ---------------------------------------------

    pub fn kittyFlags(self: *const TerminalState) u5 {
        if (self.kitty_kbd_stack_len == 0) return 0;
        return self.kitty_kbd_flags[self.kitty_kbd_stack_len - 1];
    }

    fn kittyPushFlags(self: *TerminalState, flags: u5) void {
        if (self.kitty_kbd_stack_len < 16) {
            self.kitty_kbd_flags[self.kitty_kbd_stack_len] = flags;
            self.kitty_kbd_stack_len += 1;
        } else {
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
    pub const respondColorQuery = @import("state_report.zig").respondColorQuery;
    pub const respondPaletteColorQuery = @import("state_report.zig").respondPaletteColorQuery;

    pub fn drainResponse(self: *TerminalState) ?[]const u8 {
        if (self.response_len == 0) return null;
        const len = self.response_len;
        self.response_len = 0;
        return self.response_buf[0..len];
    }

    fn appendInject(self: *TerminalState, data: []const u8) void {
        const avail = self.inject_buf.len - self.inject_len;
        const n = @min(data.len, avail);
        if (n > 0) {
            @memcpy(self.inject_buf[self.inject_len..][0..n], data[0..n]);
            self.inject_len += n;
        }
    }

    pub fn drainMainInject(self: *TerminalState) ?[]const u8 {
        if (self.inject_len == 0) return null;
        const len = self.inject_len;
        self.inject_len = 0;
        return self.inject_buf[0..len];
    }

    fn queueNotification(self: *TerminalState, title: []const u8, body: []const u8) void {
        const tlen = @min(title.len, self.notify_title_buf.len);
        const blen = @min(body.len, self.notify_body_buf.len);
        @memcpy(self.notify_title_buf[0..tlen], title[0..tlen]);
        self.notify_title_len = tlen;
        @memcpy(self.notify_body_buf[0..blen], body[0..blen]);
        self.notify_body_len = blen;
        self.notify_pending = true;
    }

    pub fn drainNotification(self: *TerminalState) ?struct { title: []const u8, body: []const u8 } {
        if (!self.notify_pending) return null;
        self.notify_pending = false;
        return .{
            .title = self.notify_title_buf[0..self.notify_title_len],
            .body = self.notify_body_buf[0..self.notify_body_len],
        };
    }

    // -- Graphics (state_graphics.zig) ------------------------------------
    pub const handleGraphicsCommand = @import("state_graphics.zig").handleGraphicsCommand;

    // -- Resize (state_resize.zig) ----------------------------------------
    pub fn resize(self: *TerminalState, new_rows: usize, new_cols: usize) !void {
        return @import("state_resize.zig").resize(self, new_rows, new_cols);
    }
};
