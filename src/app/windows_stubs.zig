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
extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*anyopaque,
    bManualReset: BOOL,
    bInitialState: BOOL,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Wake event — signaled from render thread to wake the PTY event loop
// immediately when input is sent or actions are queued.
// ---------------------------------------------------------------------------

pub var g_wake_event: ?HANDLE = null;

pub fn initWakeEvent() void {
    g_wake_event = CreateEventW(null, 0, 0, null); // auto-reset
}

fn signalWake() void {
    if (g_wake_event) |evt| _ = SetEvent(evt);
}

// ---------------------------------------------------------------------------
// Windows PTY handles (set by event loop before attyx_run)
// ---------------------------------------------------------------------------

pub var g_pty_handle: ?std.os.windows.HANDLE = null;
pub var g_popup_pty_handle: ?std.os.windows.HANDLE = null;
pub var g_engine: ?*attyx.Engine = null;
pub var g_popup_engine: ?*attyx.Engine = null;

// Session daemon client (null = local PTY mode, no daemon)
const SessionClient = @import("session_client.zig").SessionClient;
pub var g_session_client: ?*SessionClient = null;
pub var g_active_daemon_pane_id: u32 = 0;

fn writeHandle(handle: ?std.os.windows.HANDLE, data: []const u8) void {
    const h = handle orelse {
        logging.warn("pty", "writeHandle: null handle, dropping {d} bytes", .{data.len});
        return;
    };
    var written: std.os.windows.DWORD = 0;
    const ok = std.os.windows.kernel32.WriteFile(h, data.ptr, @intCast(data.len), &written, null);
    if (ok == 0) {
        logging.warn("pty", "writeHandle: WriteFile failed, err={d}", .{@intFromEnum(std.os.windows.kernel32.GetLastError())});
    }
}

// ---------------------------------------------------------------------------
// Core I/O
// ---------------------------------------------------------------------------

/// Export build version for C code (updater, etc.)
export fn attyx_get_version() [*]const u8 {
    return attyx.version.ptr;
}

export fn attyx_send_input(bytes: [*]const u8, len: c_int) void {
    if (len <= 0) return;
    const data = bytes[0..@intCast(@as(c_uint, @bitCast(len)))];
    if (g_session_client) |sc| {
        if (g_active_daemon_pane_id != 0) {
            sc.sendPaneInput(g_active_daemon_pane_id, data) catch {};
            signalWake();
            return;
        }
    }
    writeHandle(g_pty_handle, data);
    signalWake();
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
    if (encoded.len > 0) {
        if (g_session_client) |sc| {
            if (g_active_daemon_pane_id != 0) {
                sc.sendPaneInput(g_active_daemon_pane_id, encoded) catch {};
            } else {
                writeHandle(g_pty_handle, encoded);
            }
        } else {
            writeHandle(g_pty_handle, encoded);
        }
        signalWake();
    }
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

pub export var g_session_picker_active: i32 = 0;

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
export fn attyx_toggle_shell_picker() void {
    @atomicStore(i32, &g_toggle_shell_picker, 1, .seq_cst);
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

pub var popup_toggle_request: [32]i32 = .{0} ** 32;
pub var popup_dead: i32 = 0;
pub var popup_close_request: i32 = 0;

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
// Action dispatch — extracted to windows_dispatch.zig
// ---------------------------------------------------------------------------

comptime {
    _ = @import("windows_copy_mode.zig");
    _ = @import("windows_dispatch.zig");
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
pub export var g_window_scrollbar: i32 = 1;
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
pub export var g_tab_dim_unfocused: i32 = 0;
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
pub export var g_shell_picker_active: i32 = 0;
pub export var g_toggle_shell_picker: i32 = 0;

pub export var g_popup_active: i32 = 0;
pub export var g_popup_trail_active: i32 = 0;
pub export var g_popup_mouse_tracking: i32 = 0;
pub export var g_popup_mouse_sgr: i32 = 0;

// Copy mode globals are in windows_copy_mode.zig
