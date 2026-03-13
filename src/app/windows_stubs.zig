// Windows bridge — provides Zig-exported symbols that terminal.zig normally
// exports on macOS/Linux. On Windows, terminal.zig is not imported because it
// depends deeply on POSIX (Unix sockets, signals, fork/exec). These
// implementations replicate the real input.zig / dispatch.zig / copy_mode.zig
// logic using the same atomic-flag patterns so everything works end-to-end
// once the Windows event loop is wired up.

const std = @import("std");
const attyx = @import("attyx");
const keybinds = @import("../config/keybinds.zig");
const Action = keybinds.Action;
const logging = @import("../logging/log.zig");
const key_encode = attyx.key_encode;

const c = @cImport({
    @cInclude("bridge.h");
});

const HANDLE = std.os.windows.HANDLE;
const BOOL = std.os.windows.BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Windows PTY handles (set by event loop before attyx_run)
// ---------------------------------------------------------------------------

pub var g_pty_handle: ?std.os.windows.HANDLE = null;
pub var g_popup_pty_handle: ?std.os.windows.HANDLE = null;
pub var g_engine: ?*attyx.Engine = null;
pub var g_popup_engine: ?*attyx.Engine = null;

fn writeHandle(handle: ?std.os.windows.HANDLE, data: []const u8) void {
    const h = handle orelse return;
    var written: std.os.windows.DWORD = 0;
    _ = std.os.windows.kernel32.WriteFile(h, data.ptr, @intCast(data.len), &written, null);
}

// ---------------------------------------------------------------------------
// Core I/O
// ---------------------------------------------------------------------------

export fn attyx_send_input(bytes: [*]const u8, len: c_int) void {
    if (len <= 0) return;
    writeHandle(g_pty_handle, bytes[0..@intCast(@as(c_uint, @bitCast(len)))]);
}

pub var g_clear_screen_pending: i32 = 0;

export fn attyx_clear_screen() void {
    @atomicStore(i32, &g_clear_screen_pending, 1, .seq_cst);
}

export fn attyx_handle_key(k: u16, m: u8, e: u8, cp: u32) void {
    const eng = g_engine orelse return;
    const key: key_encode.KeyCode = std.meta.intToEnum(key_encode.KeyCode, k) catch return;
    const mods: key_encode.Modifiers = @bitCast(m);
    const event_type: key_encode.EventType = std.meta.intToEnum(key_encode.EventType, e) catch return;
    const codepoint: u21 = if (cp <= 0x10FFFF) @intCast(cp) else 0;
    var buf: [128]u8 = undefined;
    const encoded = key_encode.encodeKey(
        .{ .key = key, .mods = mods, .event_type = event_type, .codepoint = codepoint },
        .{
            .cursor_keys_app = eng.state.cursor_keys_app,
            .keypad_app_mode = eng.state.keypad_app_mode,
            .kitty_flags = eng.state.kittyFlags(),
        },
        &buf,
    );
    if (encoded.len > 0) writeHandle(g_pty_handle, encoded);
}

export fn attyx_get_link_uri(link_id: u32, buf: [*]u8, buf_len: c_int) c_int {
    const eng = g_engine orelse return 0;
    const uri = eng.state.getLinkUri(link_id) orelse return 0;
    const max: usize = @intCast(@as(c_uint, @bitCast(buf_len)));
    if (max == 0) return 0;
    const copy_len = @min(uri.len, max - 1);
    @memcpy(buf[0..copy_len], uri[0..copy_len]);
    buf[copy_len] = 0;
    return @intCast(copy_len);
}

export fn attyx_trigger_config_reload() void {
    @atomicStore(i32, &g_needs_reload_config, 1, .seq_cst);
}

export fn attyx_cleanup() void {
    if (g_pty_handle) |h| {
        _ = CloseHandle(h);
        g_pty_handle = null;
    }
    if (g_popup_pty_handle) |h| {
        _ = CloseHandle(h);
        g_popup_pty_handle = null;
    }
    g_engine = null;
    g_popup_engine = null;
}

export fn attyx_log(level: c_int, scope: [*:0]const u8, msg: [*:0]const u8) void {
    const l: logging.Level = switch (level) {
        0 => .err,
        1 => .warn,
        2 => .info,
        3 => .debug,
        else => .trace,
    };
    logging.global.write(l, std.mem.span(scope), "{s}", .{std.mem.span(msg)});
}

// ---------------------------------------------------------------------------
// Overlay interaction — atomic flags consumed by event loop
// ---------------------------------------------------------------------------

pub export var g_overlay_has_actions: i32 = 0;

pub var overlay_dismiss: i32 = 0;
pub var overlay_cycle_focus: i32 = 0;
pub var overlay_cycle_focus_rev: i32 = 0;
pub var overlay_activate: i32 = 0;

export fn attyx_overlay_esc() void {
    @atomicStore(i32, &overlay_dismiss, 1, .seq_cst);
}
export fn attyx_overlay_tab() void {
    @atomicStore(i32, &overlay_cycle_focus, 1, .seq_cst);
}
export fn attyx_overlay_shift_tab() void {
    @atomicStore(i32, &overlay_cycle_focus_rev, 1, .seq_cst);
}
export fn attyx_overlay_enter() void {
    @atomicStore(i32, &overlay_activate, 1, .seq_cst);
}

var overlay_click_col: i32 = -1;
var overlay_click_row: i32 = -1;
var overlay_click_pending: i32 = 0;

export fn attyx_overlay_click(col: c_int, row: c_int) c_int {
    if (c.attyx_overlay_hit_test(col, row) != 0) {
        @atomicStore(i32, &overlay_click_col, col, .seq_cst);
        @atomicStore(i32, &overlay_click_row, row, .seq_cst);
        @atomicStore(i32, &overlay_click_pending, 1, .seq_cst);
        return 1;
    }
    return 0;
}

var overlay_scroll_delta: i32 = 0;
var overlay_scroll_pending: i32 = 0;

export fn attyx_overlay_scroll(col: c_int, row: c_int, delta: c_int) c_int {
    if (c.attyx_overlay_hit_test(col, row) != 0) {
        @atomicStore(i32, &overlay_scroll_delta, delta, .seq_cst);
        @atomicStore(i32, &overlay_scroll_pending, 1, .seq_cst);
        return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Search — ring buffers for char/cmd input
// ---------------------------------------------------------------------------

pub var search_char_ring: [32]u32 = .{0} ** 32;
pub export var g_search_char_write: u32 = 0;
pub export var g_search_char_read: u32 = 0;

pub var search_cmd_ring: [16]i32 = .{0} ** 16;
pub export var g_search_cmd_write: u32 = 0;
pub export var g_search_cmd_read: u32 = 0;

export fn attyx_search_insert_char(codepoint: u32) void {
    const w = @atomicLoad(u32, &g_search_char_write, .seq_cst);
    const r = @atomicLoad(u32, &g_search_char_read, .seq_cst);
    if (w -% r >= 32) return;
    search_char_ring[w % 32] = codepoint;
    @atomicStore(u32, &g_search_char_write, w +% 1, .seq_cst);
    c.attyx_mark_all_dirty();
}

export fn attyx_search_cmd(cmd: c_int) void {
    const w = @atomicLoad(u32, &g_search_cmd_write, .seq_cst);
    const r = @atomicLoad(u32, &g_search_cmd_read, .seq_cst);
    if (w -% r >= 16) return;
    search_cmd_ring[w % 16] = cmd;
    @atomicStore(u32, &g_search_cmd_write, w +% 1, .seq_cst);
    c.attyx_mark_all_dirty();
}

// ---------------------------------------------------------------------------
// AI edit prompt — ring buffers
// ---------------------------------------------------------------------------

export var g_ai_prompt_active: i32 = 0;

var ai_char_ring: [32]u32 = .{0} ** 32;
var ai_char_write: u32 = 0;
var ai_char_read: u32 = 0;
var ai_cmd_ring: [16]i32 = .{0} ** 16;
var ai_cmd_write: u32 = 0;
var ai_cmd_read: u32 = 0;

export fn attyx_ai_prompt_insert_char(codepoint: u32) void {
    const w = @atomicLoad(u32, &ai_char_write, .seq_cst);
    const r = @atomicLoad(u32, &ai_char_read, .seq_cst);
    if (w -% r >= 32) return;
    ai_char_ring[w % 32] = codepoint;
    @atomicStore(u32, &ai_char_write, w +% 1, .seq_cst);
    c.attyx_mark_all_dirty();
}

export fn attyx_ai_prompt_cmd(cmd: c_int) void {
    const w = @atomicLoad(u32, &ai_cmd_write, .seq_cst);
    const r = @atomicLoad(u32, &ai_cmd_read, .seq_cst);
    if (w -% r >= 16) return;
    ai_cmd_ring[w % 16] = cmd;
    @atomicStore(u32, &ai_cmd_write, w +% 1, .seq_cst);
    c.attyx_mark_all_dirty();
}

// ---------------------------------------------------------------------------
// Session picker — ring buffers
// ---------------------------------------------------------------------------

export var g_session_picker_active: i32 = 0;

pub var picker_char_ring: [32]u32 = .{0} ** 32;
pub var picker_char_write: u32 = 0;
pub var picker_char_read: u32 = 0;
pub var picker_cmd_ring: [16]i32 = .{0} ** 16;
pub var picker_cmd_write: u32 = 0;
pub var picker_cmd_read: u32 = 0;

export fn attyx_picker_insert_char(codepoint: u32) void {
    const w = @atomicLoad(u32, &picker_char_write, .seq_cst);
    const r = @atomicLoad(u32, &picker_char_read, .seq_cst);
    if (w -% r >= 32) return;
    picker_char_ring[w % 32] = codepoint;
    @atomicStore(u32, &picker_char_write, w +% 1, .seq_cst);
    c.attyx_mark_all_dirty();
}

export fn attyx_picker_cmd(cmd: c_int) void {
    const w = @atomicLoad(u32, &picker_cmd_write, .seq_cst);
    const r = @atomicLoad(u32, &picker_cmd_read, .seq_cst);
    if (w -% r >= 16) return;
    picker_cmd_ring[w % 16] = cmd;
    @atomicStore(u32, &picker_cmd_write, w +% 1, .seq_cst);
    c.attyx_mark_all_dirty();
}

// ---------------------------------------------------------------------------
// Tabs — atomic action signals
// ---------------------------------------------------------------------------

pub var tab_action_request: i32 = 0;
pub var tab_click_index: i32 = -1;
pub var tab_count: i32 = 1;

export fn attyx_tab_action(action: c_int) void {
    @atomicStore(i32, &tab_action_request, action, .seq_cst);
}

export fn attyx_tab_bar_click(col: c_int, grid_cols: c_int) void {
    if (g_grid_top_offset <= 0) return;
    const tc = @atomicLoad(i32, &tab_count, .seq_cst);
    if (tc <= 0 or grid_cols <= 0) return;
    const tw = @divTrunc(grid_cols, tc);
    if (tw <= 0) return;
    const idx = @divTrunc(@max(col, 0), tw);
    if (idx >= 0 and idx < tc)
        @atomicStore(i32, &tab_click_index, idx, .seq_cst);
}

export fn attyx_statusbar_tab_click(col: c_int, grid_cols: c_int) void {
    if (g_statusbar_visible == 0) return;
    const tc = @atomicLoad(i32, &tab_count, .seq_cst);
    if (tc <= 0 or grid_cols <= 0) return;
    const tw = @divTrunc(grid_cols, tc);
    if (tw <= 0) return;
    const idx = @divTrunc(@max(col, 0), tw);
    if (idx >= 0 and idx < tc)
        @atomicStore(i32, &tab_click_index, idx, .seq_cst);
}

// ---------------------------------------------------------------------------
// Splits — atomic action signals
// ---------------------------------------------------------------------------

pub var split_action_request: i32 = 0;
pub var split_click_col: i32 = -1;
pub var split_click_row: i32 = -1;
pub var split_click_pending: i32 = 0;
pub var split_drag_start_col: i32 = -1;
pub var split_drag_start_row: i32 = -1;
pub var split_drag_start_pending: i32 = 0;
pub var split_drag_cur_col: i32 = -1;
pub var split_drag_cur_row: i32 = -1;
pub var split_drag_cur_pending: i32 = 0;
pub var split_drag_end_pending: i32 = 0;
pub var split_drag_branch: u8 = 0xFF;

export fn attyx_split_action(action: c_int) void {
    @atomicStore(i32, &split_action_request, action, .seq_cst);
}

export fn attyx_split_click(col: c_int, row: c_int) void {
    @atomicStore(i32, &split_click_col, col, .seq_cst);
    @atomicStore(i32, &split_click_row, row, .seq_cst);
    @atomicStore(i32, &split_click_pending, 1, .seq_cst);
}

export fn attyx_split_drag_start(col: c_int, row: c_int) void {
    @atomicStore(i32, &split_drag_start_col, col, .seq_cst);
    @atomicStore(i32, &split_drag_start_row, row, .seq_cst);
    @atomicStore(i32, &split_drag_start_pending, 1, .seq_cst);
}

export fn attyx_split_drag_update(col: c_int, row: c_int) void {
    @atomicStore(i32, &split_drag_cur_col, col, .seq_cst);
    @atomicStore(i32, &split_drag_cur_row, row, .seq_cst);
    @atomicStore(i32, &split_drag_cur_pending, 1, .seq_cst);
}

export fn attyx_split_drag_end() void {
    @atomicStore(i32, &split_drag_end_pending, 1, .seq_cst);
}

// ---------------------------------------------------------------------------
// Toggle overlays — atomic flags
// ---------------------------------------------------------------------------

export fn attyx_toggle_session_switcher() void {
    @atomicStore(i32, &g_toggle_session_switcher, 1, .seq_cst);
}
export fn attyx_create_session_direct() void {
    @atomicStore(i32, &g_create_session_direct, 1, .seq_cst);
}
export fn attyx_toggle_command_palette() void {
    @atomicStore(i32, &g_toggle_command_palette, 1, .seq_cst);
}
export fn attyx_toggle_theme_picker() void {
    @atomicStore(i32, &g_toggle_theme_picker, 1, .seq_cst);
}
export fn attyx_toggle_debug_overlay() void {
    @atomicStore(i32, &g_toggle_debug_overlay, 1, .seq_cst);
}
export fn attyx_toggle_anchor_demo() void {
    @atomicStore(i32, &g_toggle_anchor_demo, 1, .seq_cst);
}
export fn attyx_toggle_ai_demo() void {
    @atomicStore(i32, &g_toggle_ai_demo, 1, .seq_cst);
}

// ---------------------------------------------------------------------------
// Popup terminal
// ---------------------------------------------------------------------------

var popup_toggle_request: [32]i32 = .{0} ** 32;
var popup_dead: i32 = 0;
var popup_close_request: i32 = 0;

export fn attyx_popup_toggle(index: c_int) void {
    if (index < 0 or index >= 32) return;
    @atomicStore(i32, &popup_toggle_request[@intCast(@as(c_uint, @bitCast(index)))], 1, .seq_cst);
}

export fn attyx_popup_send_input(bytes: [*]const u8, len: c_int) void {
    if (@atomicLoad(i32, &popup_dead, .seq_cst) != 0) {
        if (len == 1 and bytes[0] == 0x03)
            @atomicStore(i32, &popup_close_request, 1, .seq_cst);
        return;
    }
    if (len <= 0) return;
    writeHandle(g_popup_pty_handle, bytes[0..@intCast(@as(c_uint, @bitCast(len)))]);
}

export fn attyx_popup_handle_key(k: u16, m: u8, e: u8, cp: u32) void {
    if (@atomicLoad(i32, &popup_dead, .seq_cst) != 0) {
        const key: key_encode.KeyCode = std.meta.intToEnum(key_encode.KeyCode, k) catch return;
        const mods: key_encode.Modifiers = @bitCast(m);
        if (key == .codepoint and mods.ctrl and !mods.shift and !mods.alt and
            (cp == 'c' or cp == 'C'))
            @atomicStore(i32, &popup_close_request, 1, .seq_cst);
        return;
    }
    const eng = g_popup_engine orelse return;
    const key: key_encode.KeyCode = std.meta.intToEnum(key_encode.KeyCode, k) catch return;
    const mods: key_encode.Modifiers = @bitCast(m);
    const event_type: key_encode.EventType = std.meta.intToEnum(key_encode.EventType, e) catch return;
    const codepoint: u21 = if (cp <= 0x10FFFF) @intCast(cp) else 0;
    var buf: [128]u8 = undefined;
    const encoded = key_encode.encodeKey(
        .{ .key = key, .mods = mods, .event_type = event_type, .codepoint = codepoint },
        .{
            .cursor_keys_app = eng.state.cursor_keys_app,
            .keypad_app_mode = eng.state.keypad_app_mode,
            .kitty_flags = eng.state.kittyFlags(),
        },
        &buf,
    );
    if (encoded.len > 0) writeHandle(g_popup_pty_handle, encoded);
}

// ---------------------------------------------------------------------------
// Copy mode — extracted to windows_copy_mode.zig
// ---------------------------------------------------------------------------

comptime {
    _ = @import("windows_copy_mode.zig");
}

extern fn attyx_copy_mode_enter() void;

// ---------------------------------------------------------------------------
// Action dispatch
// ---------------------------------------------------------------------------

extern fn attyx_platform_close_window() void;

export fn attyx_dispatch_action(action_raw: u8) u8 {
    const action: Action = @enumFromInt(action_raw);

    if (c.g_sel_active != 0 and c.g_copy_mode == 0) {
        switch (action) {
            .copy, .scroll_page_up, .scroll_page_down, .scroll_to_top, .scroll_to_bottom => {},
            else => { c.g_sel_active = 0; c.attyx_mark_all_dirty(); },
        }
    }

    if (action.popupIndex()) |idx| {
        attyx_popup_toggle(@intCast(idx));
        return 1;
    }

    if (c.g_popup_active != 0) {
        switch (action) {
            .send_sequence, .session_create, .session_kill => {},
            else => return 1,
        }
    }

    switch (action) {
        .tab_new, .tab_close, .tab_next, .tab_prev,
        .tab_move_left, .tab_move_right,
        .tab_select_1, .tab_select_2, .tab_select_3,
        .tab_select_4, .tab_select_5, .tab_select_6,
        .tab_select_7, .tab_select_8, .tab_select_9,
        => { attyx_tab_action(action_raw); return 1; },
        else => {},
    }

    switch (action) {
        .split_vertical, .split_horizontal, .pane_close => {
            attyx_split_action(action_raw);
            return 1;
        },
        .pane_focus_up, .pane_focus_down, .pane_focus_left, .pane_focus_right,
        .pane_resize_up, .pane_resize_down, .pane_resize_left, .pane_resize_right,
        .pane_resize_grow, .pane_resize_shrink, .pane_rotate, .pane_zoom_toggle,
        => {
            if (c.g_split_active != 0) { attyx_split_action(action_raw); return 1; }
            return 0;
        },
        else => {},
    }

    switch (action) {
        .search_toggle => {
            if (c.g_search_active != 0) {
                attyx_search_cmd(7);
            } else {
                c.g_search_active = 1;
                c.g_search_query_len = 0;
                c.g_search_gen +%= 1;
                c.attyx_mark_all_dirty();
            }
            return 1;
        },
        .search_next => {
            if (c.g_search_active != 0) {
                _ = @atomicRmw(c_int, @as(*c_int, @ptrCast(@volatileCast(&c.g_search_nav_delta))), .Add, 1, .seq_cst);
                c.attyx_mark_all_dirty();
            }
            return 1;
        },
        .search_prev => {
            if (c.g_search_active != 0) {
                _ = @atomicRmw(c_int, @as(*c_int, @ptrCast(@volatileCast(&c.g_search_nav_delta))), .Add, -1, .seq_cst);
                c.attyx_mark_all_dirty();
            }
            return 1;
        },
        .scroll_page_up => {
            if (c.g_mouse_tracking != 0 or c.g_alt_screen != 0) return 0;
            c.attyx_scroll_viewport(c.g_rows);
            return 1;
        },
        .scroll_page_down => {
            if (c.g_mouse_tracking != 0 or c.g_alt_screen != 0) return 0;
            c.attyx_scroll_viewport(-c.g_rows);
            return 1;
        },
        .scroll_to_top => {
            if (c.g_mouse_tracking != 0 or c.g_alt_screen != 0) return 0;
            c.g_viewport_offset = c.g_scrollback_count;
            c.attyx_mark_all_dirty();
            return 1;
        },
        .scroll_to_bottom => {
            if (c.g_mouse_tracking != 0 or c.g_alt_screen != 0) return 0;
            c.g_viewport_offset = 0;
            c.attyx_mark_all_dirty();
            return 1;
        },
        .config_reload => { attyx_trigger_config_reload(); return 1; },
        .debug_toggle => { attyx_toggle_debug_overlay(); return 1; },
        .anchor_demo_toggle => { attyx_toggle_anchor_demo(); return 1; },
        .ai_demo_toggle => { attyx_toggle_ai_demo(); return 1; },
        .session_switcher_toggle => { attyx_toggle_session_switcher(); return 1; },
        .command_palette_toggle => { attyx_toggle_command_palette(); return 1; },
        .theme_picker_toggle => { attyx_toggle_theme_picker(); return 1; },
        .session_create => {
            if (c.g_popup_active != 0) {
                const b = [_]u8{0x0e};
                attyx_popup_send_input(&b, 1);
            } else {
                attyx_create_session_direct();
            }
            return 1;
        },
        .session_kill => {
            if (c.g_popup_active != 0) {
                const b = [_]u8{0x04};
                attyx_popup_send_input(&b, 1);
                return 1;
            }
            return 0;
        },
        .new_window => { c.attyx_spawn_new_window(); return 1; },
        .close_window => { attyx_platform_close_window(); return 1; },
        .clear_screen => { attyx_clear_screen(); return 1; },
        .open_config => { openConfigWindows(); return 1; },
        .copy_mode_enter => { attyx_copy_mode_enter(); return 1; },
        .font_size_increase => {
            if (c.g_font_size < 72) { c.g_font_size += 2; c.g_needs_font_rebuild = 1; }
            return 1;
        },
        .font_size_decrease => {
            if (c.g_font_size > 6) { c.g_font_size -= 2; c.g_needs_font_rebuild = 1; }
            return 1;
        },
        .font_size_reset => {
            c.g_font_size = c.g_default_font_size;
            c.g_needs_font_rebuild = 1;
            return 1;
        },
        .send_sequence => {
            if (c.g_keybind_matched_seq_len > 0) {
                if (c.g_popup_active != 0)
                    attyx_popup_send_input(c.g_keybind_matched_seq, c.g_keybind_matched_seq_len)
                else
                    attyx_send_input(c.g_keybind_matched_seq, c.g_keybind_matched_seq_len);
            }
            return 1;
        },
        else => return 0,
    }
}

// ---------------------------------------------------------------------------
// Open config file (Windows)
// ---------------------------------------------------------------------------

extern "shell32" fn ShellExecuteA(
    hwnd: ?*anyopaque,
    lpOperation: [*:0]const u8,
    lpFile: [*:0]const u8,
    lpParameters: ?[*:0]const u8,
    lpDirectory: ?[*:0]const u8,
    nShowCmd: c_int,
) callconv(.winapi) ?*anyopaque;

fn openConfigWindows() void {
    const platform = @import("../platform/windows.zig");
    // Use a thread-local GPA for the short-lived allocation
    var buf: [512]u8 = undefined;
    const appdata = std.process.getEnvVarOwned(std.heap.page_allocator, "APPDATA") catch {
        _ = platform; // fallback: try USERPROFILE
        return;
    };
    defer std.heap.page_allocator.free(appdata);
    const path = std.fmt.bufPrintZ(&buf, "{s}\\attyx\\attyx.toml", .{appdata}) catch return;

    // Ensure config dir + file exist
    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}\\attyx", .{appdata}) catch return;
    std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return,
    };
    if (std.fs.accessAbsolute(path, .{})) {} else |_| {
        const f = std.fs.createFileAbsolute(path, .{ .exclusive = true }) catch null;
        if (f) |file| file.close();
    }

    // Open with default editor (notepad, VS Code, etc.)
    _ = ShellExecuteA(null, "open", path, null, null, 5); // SW_SHOW = 5
}

var ctx_action_id: i32 = 0;
var ctx_action_col: i32 = -1;
var ctx_action_row: i32 = -1;
var ctx_action_pending: i32 = 0;

export fn attyx_context_menu_action(action_id: u8, col: c_int, row: c_int) void {
    @atomicStore(i32, &ctx_action_col, col, .seq_cst);
    @atomicStore(i32, &ctx_action_row, row, .seq_cst);
    @atomicStore(i32, &ctx_action_id, @as(i32, action_id), .seq_cst);
    @atomicStore(i32, &ctx_action_pending, 1, .seq_cst);
}

// ---------------------------------------------------------------------------
// Zig-owned globals (normally exported by terminal.zig / copy_mode.zig)
// ---------------------------------------------------------------------------

pub export var g_needs_reload_config: i32 = 0;
pub export var g_kitty_kbd_flags: i32 = 0;
pub export var g_needs_font_rebuild: i32 = 0;
pub export var g_needs_window_update: i32 = 0;
pub export var g_background_opacity: f32 = 1.0;
pub export var g_background_blur: i32 = 30;
pub export var g_window_decorations: i32 = 1;
pub export var g_padding_left: i32 = 0;
pub export var g_padding_right: i32 = 0;
pub export var g_padding_top: i32 = 0;
pub export var g_padding_bottom: i32 = 0;
pub export var g_theme_cursor_r: i32 = -1;
pub export var g_theme_cursor_g: i32 = 0;
pub export var g_theme_cursor_b: i32 = 0;
pub export var g_theme_sel_bg_set: i32 = 0;
pub export var g_theme_sel_bg_r: i32 = 0;
pub export var g_theme_sel_bg_g: i32 = 0;
pub export var g_theme_sel_bg_b: i32 = 0;
pub export var g_theme_sel_fg_set: i32 = 0;
pub export var g_theme_sel_fg_r: i32 = 0;
pub export var g_theme_sel_fg_g: i32 = 0;
pub export var g_theme_sel_fg_b: i32 = 0;
pub export var g_theme_bg_r: i32 = 30;
pub export var g_theme_bg_g: i32 = 30;
pub export var g_theme_bg_b: i32 = 36;

var _icon_stub: u8 = 0;
pub export var g_icon_png: [*]const u8 = @ptrCast(&_icon_stub);
pub export var g_icon_png_len: c_int = 0;
var _ver_stub: u8 = 0;
pub export var g_app_version: [*]const u8 = @ptrCast(&_ver_stub);
pub export var g_app_version_len: c_int = 0;

pub export var g_grid_top_offset: i32 = 0;
pub export var g_grid_bottom_offset: i32 = 0;
pub export var g_statusbar_visible: i32 = 0;
pub export var g_statusbar_position: i32 = 0;
pub export var g_tab_bar_visible: i32 = 0;
pub export var g_toggle_debug_overlay: i32 = 0;
pub export var g_toggle_anchor_demo: i32 = 0;
pub export var g_toggle_ai_demo: i32 = 0;

pub export var g_native_tabs_enabled: i32 = 0;
pub export var g_tab_always_show: i32 = 0;
pub export var g_native_tab_count: i32 = 1;
pub export var g_native_tab_active: i32 = 0;
pub export var g_native_tab_titles_changed: i32 = 0;
pub export var g_native_tab_click: i32 = -1;
pub export var g_native_tab_reorder: i32 = -1;
pub export var g_native_tab_titles: [16][128]u8 = .{.{0} ** 128} ** 16;
pub export var g_sessions_active: i32 = 0;
pub export var g_session_count: i32 = 0;
pub export var g_active_session_idx: i32 = -1;
pub export var g_session_ids: [32]u32 = .{0} ** 32;
pub export var g_session_names: [32][64]u8 = .{.{0} ** 64} ** 32;
pub export var g_session_list_changed: i32 = 0;
pub export var g_session_switch_id: i32 = -1;

pub export var g_split_active: i32 = 0;
pub export var g_split_drag_active: i32 = 0;
pub export var g_split_drag_direction: i32 = 0;
pub export var g_pane_rect_row: i32 = 0;
pub export var g_pane_rect_col: i32 = 0;
pub export var g_pane_rect_rows: i32 = 24;
pub export var g_pane_rect_cols: i32 = 80;

pub export var g_toggle_session_switcher: i32 = 0;
pub export var g_create_session_direct: i32 = 0;
pub export var g_command_palette_active: i32 = 0;
pub export var g_toggle_command_palette: i32 = 0;
pub export var g_theme_picker_active: i32 = 0;
pub export var g_toggle_theme_picker: i32 = 0;

pub export var g_popup_active: i32 = 0;
pub export var g_popup_trail_active: i32 = 0;
pub export var g_popup_mouse_tracking: i32 = 0;
pub export var g_popup_mouse_sgr: i32 = 0;

// Copy mode globals are in windows_copy_mode.zig
