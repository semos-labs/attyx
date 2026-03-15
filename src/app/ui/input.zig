const std = @import("std");
const posix = std.posix;
const attyx = @import("attyx");
const logging = @import("../../logging/log.zig");
const tab_bar_mod = @import("../tab_bar.zig");

const terminal = @import("../terminal.zig");
const c = terminal.c;

// ---------------------------------------------------------------------------
// Overlay interaction atomics
// ---------------------------------------------------------------------------

pub var g_overlay_dismiss: i32 = 0;
pub var g_overlay_cycle_focus: i32 = 0;
pub var g_overlay_cycle_focus_rev: i32 = 0;
pub var g_overlay_activate: i32 = 0;

pub fn overlayEsc() void {
    @atomicStore(i32, &g_overlay_dismiss, 1, .seq_cst);
}
pub fn overlayTab() void {
    @atomicStore(i32, &g_overlay_cycle_focus, 1, .seq_cst);
}
pub fn overlayShiftTab() void {
    @atomicStore(i32, &g_overlay_cycle_focus_rev, 1, .seq_cst);
}
pub fn overlayEnter() void {
    @atomicStore(i32, &g_overlay_activate, 1, .seq_cst);
}

// ---------------------------------------------------------------------------
// Overlay mouse click
// ---------------------------------------------------------------------------

pub var g_overlay_click_col: i32 = -1;
pub var g_overlay_click_row: i32 = -1;
pub var g_overlay_click_pending: i32 = 0;

pub fn overlayClick(col: c_int, row: c_int) c_int {
    if (c.attyx_overlay_hit_test(col, row) != 0) {
        @atomicStore(i32, &g_overlay_click_col, col, .seq_cst);
        @atomicStore(i32, &g_overlay_click_row, row, .seq_cst);
        @atomicStore(i32, &g_overlay_click_pending, 1, .seq_cst);
        return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Overlay scroll
// ---------------------------------------------------------------------------

pub var g_overlay_scroll_delta: i32 = 0;
pub var g_overlay_scroll_pending: i32 = 0;

pub fn overlayScroll(col: c_int, row: c_int, delta: c_int) c_int {
    if (c.attyx_overlay_hit_test(col, row) != 0) {
        @atomicStore(i32, &g_overlay_scroll_delta, delta, .seq_cst);
        @atomicStore(i32, &g_overlay_scroll_pending, 1, .seq_cst);
        return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Grid-based search bar input rings
// ---------------------------------------------------------------------------

pub var g_search_char_ring: [32]u32 = .{0} ** 32;
pub var g_search_char_write: u32 = 0;
pub var g_search_char_read: u32 = 0;

pub var g_search_cmd_ring: [16]i32 = .{0} ** 16;
pub var g_search_cmd_write: u32 = 0;
pub var g_search_cmd_read: u32 = 0;

pub fn searchInsertChar(codepoint: u32) void {
    const w = @atomicLoad(u32, &g_search_char_write, .seq_cst);
    const r = @atomicLoad(u32, &g_search_char_read, .seq_cst);
    if (w -% r >= 32) return;
    g_search_char_ring[w % 32] = codepoint;
    @atomicStore(u32, &g_search_char_write, w +% 1, .seq_cst);
    c.attyx_mark_all_dirty();
}

pub fn searchCmd(cmd: c_int) void {
    const w = @atomicLoad(u32, &g_search_cmd_write, .seq_cst);
    const r = @atomicLoad(u32, &g_search_cmd_read, .seq_cst);
    if (w -% r >= 16) return;
    g_search_cmd_ring[w % 16] = cmd;
    @atomicStore(u32, &g_search_cmd_write, w +% 1, .seq_cst);
    c.attyx_mark_all_dirty();
}

// ---------------------------------------------------------------------------
// AI edit prompt input rings
// ---------------------------------------------------------------------------

pub var g_ai_prompt_char_ring: [32]u32 = .{0} ** 32;
pub var g_ai_prompt_char_write: u32 = 0;
pub var g_ai_prompt_char_read: u32 = 0;

pub var g_ai_prompt_cmd_ring: [16]i32 = .{0} ** 16;
pub var g_ai_prompt_cmd_write: u32 = 0;
pub var g_ai_prompt_cmd_read: u32 = 0;

pub fn aiPromptInsertChar(codepoint: u32) void {
    const w = @atomicLoad(u32, &g_ai_prompt_char_write, .seq_cst);
    const r = @atomicLoad(u32, &g_ai_prompt_char_read, .seq_cst);
    if (w -% r >= 32) return;
    g_ai_prompt_char_ring[w % 32] = codepoint;
    @atomicStore(u32, &g_ai_prompt_char_write, w +% 1, .seq_cst);
    c.attyx_mark_all_dirty();
}

pub fn aiPromptCmd(cmd: c_int) void {
    const w = @atomicLoad(u32, &g_ai_prompt_cmd_write, .seq_cst);
    const r = @atomicLoad(u32, &g_ai_prompt_cmd_read, .seq_cst);
    if (w -% r >= 16) return;
    g_ai_prompt_cmd_ring[w % 16] = cmd;
    @atomicStore(u32, &g_ai_prompt_cmd_write, w +% 1, .seq_cst);
    c.attyx_mark_all_dirty();
}

// ---------------------------------------------------------------------------
// Session picker input rings
// ---------------------------------------------------------------------------

pub var g_picker_char_ring: [32]u32 = .{0} ** 32;
pub var g_picker_char_write: u32 = 0;
pub var g_picker_char_read: u32 = 0;

pub var g_picker_cmd_ring: [16]i32 = .{0} ** 16;
pub var g_picker_cmd_write: u32 = 0;
pub var g_picker_cmd_read: u32 = 0;

pub fn pickerInsertChar(codepoint: u32) void {
    const w = @atomicLoad(u32, &g_picker_char_write, .seq_cst);
    const r = @atomicLoad(u32, &g_picker_char_read, .seq_cst);
    if (w -% r >= 32) return;
    g_picker_char_ring[w % 32] = codepoint;
    @atomicStore(u32, &g_picker_char_write, w +% 1, .seq_cst);
    c.attyx_mark_all_dirty();
}

pub fn pickerCmd(cmd: c_int) void {
    const w = @atomicLoad(u32, &g_picker_cmd_write, .seq_cst);
    const r = @atomicLoad(u32, &g_picker_cmd_read, .seq_cst);
    if (w -% r >= 16) return;
    g_picker_cmd_ring[w % 16] = cmd;
    @atomicStore(u32, &g_picker_cmd_write, w +% 1, .seq_cst);
    c.attyx_mark_all_dirty();
}

// ---------------------------------------------------------------------------
// Tab management atomics
// ---------------------------------------------------------------------------

pub var g_tab_action_request: i32 = 0;
pub var g_tab_click_index: i32 = -1;

pub fn tabAction(action: c_int) void {
    @atomicStore(i32, &g_tab_action_request, action, .seq_cst);
}

pub fn tabBarClick(col: c_int, grid_cols: c_int) void {
    if (terminal.g_grid_top_offset <= 0) return;
    const idx = tab_bar_mod.tabIndexAtCol(
        @intCast(@max(0, col)),
        @intCast(@atomicLoad(i32, &terminal.g_tab_count, .seq_cst)),
        @intCast(@max(1, grid_cols)),
    ) orelse return;
    @atomicStore(i32, &g_tab_click_index, @as(i32, idx), .seq_cst);
}

const statusbar_mod = @import("../statusbar.zig");

pub fn statusbarTabClick(col: c_int, grid_cols: c_int) void {
    if (terminal.g_statusbar_visible == 0) return;
    const offset = statusbar_mod.tab_col_offset;
    if (col < offset) return;
    const adjusted_col: u16 = @intCast(@as(c_uint, @bitCast(col)) -| offset);
    const remaining: u16 = @intCast(@max(1, grid_cols) -| offset);
    const idx = tab_bar_mod.tabIndexAtCol(
        adjusted_col,
        @intCast(@atomicLoad(i32, &terminal.g_tab_count, .seq_cst)),
        remaining,
    ) orelse return;
    @atomicStore(i32, &g_tab_click_index, @as(i32, idx), .seq_cst);
}

// ---------------------------------------------------------------------------
// Split pane atomics
// ---------------------------------------------------------------------------

pub var g_split_action_request: i32 = 0;
pub var g_split_click_col: i32 = -1;
pub var g_split_click_row: i32 = -1;
pub var g_split_click_pending: i32 = 0;

// Context menu action — dispatches an action on a specific pane (by grid position).
// The event loop focuses the pane at (col, row) first, then runs the action.
pub var g_ctx_action_id: i32 = 0;
pub var g_ctx_action_col: i32 = -1;
pub var g_ctx_action_row: i32 = -1;
pub var g_ctx_action_pending: i32 = 0;

pub fn contextMenuAction(action_id: c_int, col: c_int, row: c_int) void {
    @atomicStore(i32, &g_ctx_action_col, col, .seq_cst);
    @atomicStore(i32, &g_ctx_action_row, row, .seq_cst);
    @atomicStore(i32, &g_ctx_action_id, action_id, .seq_cst);
    @atomicStore(i32, &g_ctx_action_pending, 1, .seq_cst);
}

pub fn splitAction(action: c_int) void {
    @atomicStore(i32, &g_split_action_request, action, .seq_cst);
}

pub fn splitClick(col: c_int, row: c_int) void {
    @atomicStore(i32, &g_split_click_col, col, .seq_cst);
    @atomicStore(i32, &g_split_click_row, row, .seq_cst);
    @atomicStore(i32, &g_split_click_pending, 1, .seq_cst);
}

// Split pane drag resize state
pub var g_split_drag_start_col: i32 = -1;
pub var g_split_drag_start_row: i32 = -1;
pub var g_split_drag_start_pending: i32 = 0;
pub var g_split_drag_cur_col: i32 = -1;
pub var g_split_drag_cur_row: i32 = -1;
pub var g_split_drag_cur_pending: i32 = 0;
pub var g_split_drag_end_pending: i32 = 0;
pub var g_split_drag_branch: u8 = 0xFF;

pub fn splitDragStart(col: c_int, row: c_int) void {
    @atomicStore(i32, &g_split_drag_start_col, col, .seq_cst);
    @atomicStore(i32, &g_split_drag_start_row, row, .seq_cst);
    @atomicStore(i32, &g_split_drag_start_pending, 1, .seq_cst);
}

pub fn splitDragUpdate(col: c_int, row: c_int) void {
    @atomicStore(i32, &g_split_drag_cur_col, col, .seq_cst);
    @atomicStore(i32, &g_split_drag_cur_row, row, .seq_cst);
    @atomicStore(i32, &g_split_drag_cur_pending, 1, .seq_cst);
}

pub fn splitDragEnd() void {
    @atomicStore(i32, &g_split_drag_end_pending, 1, .seq_cst);
}

// ---------------------------------------------------------------------------
// Clear screen (Cmd+K / Ctrl+Shift+K)
// ---------------------------------------------------------------------------

pub var g_clear_screen_pending: i32 = 0;

pub fn clearScreen() void {
    @atomicStore(i32, &g_clear_screen_pending, 1, .seq_cst);
}

// ---------------------------------------------------------------------------
// Popup terminal atomics
// ---------------------------------------------------------------------------

pub var g_popup_toggle_request: [32]i32 = .{0} ** 32;
pub var g_popup_dead: i32 = 0;
pub var g_popup_close_request: i32 = 0;

pub fn popupToggle(index: c_int) void {
    if (index < 0 or index >= 32) return;
    logging.info("popup", "toggle request: index={d}", .{index});
    @atomicStore(i32, &g_popup_toggle_request[@intCast(@as(c_uint, @bitCast(index)))], 1, .seq_cst);
}

pub fn popupSendInput(bytes: [*]const u8, len: c_int) void {
    // Dead popup: Ctrl-C (ETX byte) closes it
    if (@atomicLoad(i32, &g_popup_dead, .seq_cst) != 0) {
        if (len == 1 and bytes[0] == 0x03) {
            @atomicStore(i32, &g_popup_close_request, 1, .seq_cst);
        }
        return;
    }
    const fd = terminal.g_popup_pty_master;
    if (fd < 0 or len <= 0) return;
    const data = bytes[0..@intCast(@as(c_uint, @bitCast(len)))];
    _ = posix.write(fd, data) catch {};
}

pub fn popupHandleKey(key_raw: u16, mods_raw: u8, event_type_raw: u8, codepoint_raw: u32) void {
    // Dead popup: Ctrl-C closes it
    if (@atomicLoad(i32, &g_popup_dead, .seq_cst) != 0) {
        const key_encode = attyx.key_encode;
        const key: key_encode.KeyCode = std.meta.intToEnum(key_encode.KeyCode, key_raw) catch return;
        const mods: key_encode.Modifiers = @bitCast(mods_raw);
        if (key == .codepoint and mods.ctrl and !mods.shift and !mods.alt and
            (codepoint_raw == 'c' or codepoint_raw == 'C'))
        {
            @atomicStore(i32, &g_popup_close_request, 1, .seq_cst);
        }
        return;
    }

    const fd = terminal.g_popup_pty_master;
    if (fd < 0) return;
    const eng = terminal.g_popup_engine orelse return;
    const key_encode = attyx.key_encode;

    const key: key_encode.KeyCode = std.meta.intToEnum(key_encode.KeyCode, key_raw) catch return;
    const mods: key_encode.Modifiers = @bitCast(mods_raw);
    const event_type: key_encode.EventType = std.meta.intToEnum(key_encode.EventType, event_type_raw) catch return;
    const cp: u21 = if (codepoint_raw <= 0x10FFFF) @intCast(codepoint_raw) else 0;

    const cursor_keys_app = eng.state.cursor_keys_app;
    const keypad_app_mode = eng.state.keypad_app_mode;
    const kitty_flags = eng.state.kittyFlags();

    var buf: [128]u8 = undefined;
    const encoded = key_encode.encodeKey(
        .{ .key = key, .mods = mods, .event_type = event_type, .codepoint = cp },
        .{ .cursor_keys_app = cursor_keys_app, .keypad_app_mode = keypad_app_mode, .kitty_flags = kitty_flags },
        &buf,
    );

    if (encoded.len > 0) {
        _ = posix.write(fd, encoded) catch {};
    }
}

// ---------------------------------------------------------------------------
// Async paste buffer — large writes are queued here so the main thread
// doesn't block.  The PTY reader thread drains it via drainPasteBuffer().
// ---------------------------------------------------------------------------

const paste_buf_cap: usize = 4 * 1024 * 1024; // 4 MB max buffered paste
var paste_buf: ?[]u8 = null;
var paste_len: usize = 0;
var paste_offset: usize = 0;
var paste_fd: posix.fd_t = -1;
var paste_mutex: std.Thread.Mutex = .{};

fn pasteAlloc() []u8 {
    if (paste_buf) |b| return b;
    paste_buf = std.heap.page_allocator.alloc(u8, paste_buf_cap) catch return &[0]u8{};
    return paste_buf.?;
}

/// Enqueue data for async write.  Returns true if buffered successfully.
fn enqueuePaste(fd: posix.fd_t, data: []const u8) bool {
    paste_mutex.lock();
    defer paste_mutex.unlock();

    const buf = pasteAlloc();
    if (buf.len == 0) return false;

    // If there's already pending data for a different fd, flush concept doesn't
    // apply — just overwrite (shouldn't happen in practice).
    if (paste_len > 0 and paste_fd != fd) {
        paste_len = 0;
        paste_offset = 0;
    }

    const avail = buf.len - paste_len;
    if (data.len > avail) return false;

    @memcpy(buf[paste_len..][0..data.len], data);
    paste_len += data.len;
    paste_fd = fd;
    return true;
}

/// Called from the PTY reader thread to drain buffered paste data.
/// Writes as much as the PTY will accept without blocking, then returns.
pub fn drainPasteBuffer() void {
    paste_mutex.lock();
    defer paste_mutex.unlock();

    if (paste_len == 0) return;
    const buf = paste_buf orelse return;
    const fd = paste_fd;

    while (paste_offset < paste_len) {
        const remaining = buf[paste_offset..paste_len];
        const chunk = remaining[0..@min(remaining.len, 4096)];
        const n = posix.write(fd, chunk) catch |err| {
            if (err == error.WouldBlock) return; // try again next tick
            // Fatal write error — discard remaining paste
            paste_len = 0;
            paste_offset = 0;
            return;
        };
        paste_offset += n;
    }

    // Fully drained
    paste_len = 0;
    paste_offset = 0;
}

pub fn hasPendingPaste() bool {
    paste_mutex.lock();
    defer paste_mutex.unlock();
    return paste_len > 0;
}

pub fn sendInput(bytes: [*]const u8, len: c_int) void {
    if (len <= 0) return;
    const data = bytes[0..@intCast(@as(c_uint, @bitCast(len)))];

    // Session mode: route input through daemon to active pane
    if (terminal.g_session_client) |sc| {
        sc.sendPaneInput(terminal.g_active_daemon_pane_id, data) catch {};
        return;
    }

    const fd = terminal.g_pty_master;
    if (fd < 0) return;

    // If there's already buffered paste data, append to the buffer to
    // preserve ordering (e.g. bracketed paste markers must follow data).
    if (hasPendingPaste()) {
        if (enqueuePaste(fd, data)) return;
        // Buffer full — fall through to blocking write
    }

    // Try to write directly (non-blocking).
    const chunk_size: usize = 4096;
    var offset: usize = 0;
    while (offset < data.len) {
        const end = @min(offset + chunk_size, data.len);
        const n = posix.write(fd, data[offset..end]) catch |err| {
            if (err == error.WouldBlock) break;
            return;
        };
        offset += n;
        // For large writes, only do one direct chunk then switch to async
        // to avoid blocking the main thread.
        if (data.len > chunk_size) break;
    }

    // Buffer whatever remains for the PTY thread to drain
    if (offset < data.len) {
        if (!enqueuePaste(fd, data[offset..])) {
            // Buffer full — fall back to blocking write as last resort.
            while (offset < data.len) {
                const end = @min(offset + chunk_size, data.len);
                const n = posix.write(fd, data[offset..end]) catch |err| {
                    if (err == error.WouldBlock) {
                        posix.nanosleep(0, 1_000_000);
                        continue;
                    }
                    return;
                };
                offset += n;
            }
        }
    }
}

pub fn handleKey(key_raw: u16, mods_raw: u8, event_type_raw: u8, codepoint_raw: u32) void {
    const eng = terminal.g_engine orelse return;
    const key_encode = attyx.key_encode;

    const key: key_encode.KeyCode = std.meta.intToEnum(key_encode.KeyCode, key_raw) catch return;
    const mods: key_encode.Modifiers = @bitCast(mods_raw);
    const event_type: key_encode.EventType = std.meta.intToEnum(key_encode.EventType, event_type_raw) catch return;
    const cp: u21 = if (codepoint_raw <= 0x10FFFF) @intCast(codepoint_raw) else 0;

    const cursor_keys_app = eng.state.cursor_keys_app;
    const keypad_app_mode = eng.state.keypad_app_mode;
    const kitty_flags = eng.state.kittyFlags();

    var buf: [128]u8 = undefined;
    const encoded = key_encode.encodeKey(
        .{ .key = key, .mods = mods, .event_type = event_type, .codepoint = cp },
        .{ .cursor_keys_app = cursor_keys_app, .keypad_app_mode = keypad_app_mode, .kitty_flags = kitty_flags },
        &buf,
    );

    if (encoded.len > 0) {
        // Session mode: route through daemon to active pane
        if (terminal.g_session_client) |sc| {
            sc.sendPaneInput(terminal.g_active_daemon_pane_id, encoded) catch {};
            return;
        }
        if (terminal.g_pty_master >= 0) {
            _ = posix.write(terminal.g_pty_master, encoded) catch {};
        }
    }
}

pub fn getLinkUri(link_id: u32, buf: [*]u8, buf_len: c_int) c_int {
    const eng = terminal.g_engine orelse return 0;
    const uri = eng.state.getLinkUri(link_id) orelse return 0;
    const max: usize = @intCast(@as(c_uint, @bitCast(buf_len)));
    if (max == 0) return 0;
    const copy_len = @min(uri.len, max - 1);
    @memcpy(buf[0..copy_len], uri[0..copy_len]);
    buf[copy_len] = 0;
    return @intCast(copy_len);
}
