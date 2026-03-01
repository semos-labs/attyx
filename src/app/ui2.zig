const std = @import("std");
const posix = std.posix;
const attyx = @import("attyx");
const AppConfig = @import("../config/config.zig").AppConfig;
const CursorShapeConfig = @import("../config/config.zig").CursorShapeConfig;
const reload = @import("../config/reload.zig");
const logging = @import("../logging/log.zig");
const diag = @import("../logging/diag.zig");

const Engine = attyx.Engine;
const SearchState = attyx.SearchState;
const state_hash = attyx.hash;
const color_mod = attyx.render_color;
const Pty = @import("pty.zig").Pty;
const SessionLog = @import("session_log.zig").SessionLog;

const config_mod = @import("../config/config.zig");
const theme_registry_mod = @import("../theme/registry.zig");
const ThemeRegistry = theme_registry_mod.ThemeRegistry;
pub const Theme = theme_registry_mod.Theme;

const overlay_mod = attyx.overlay_mod;
const overlay_layout = attyx.overlay_layout;
const overlay_anchor = attyx.overlay_anchor;
const overlay_content = attyx.overlay_content;
const overlay_streaming = attyx.overlay_streaming;
const overlay_demo = attyx.overlay_demo;
const overlay_search = attyx.overlay_search;
const overlay_context = attyx.overlay_context;
const overlay_context_extract = attyx.overlay_context_extract;
const overlay_context_ui = attyx.overlay_context_ui;
const overlay_ai_config = attyx.overlay_ai_config;
const overlay_ai_auth = attyx.overlay_ai_auth;
const overlay_ai_stream = attyx.overlay_ai_stream;
const overlay_ai_content = attyx.overlay_ai_content;
const overlay_ai_error = attyx.overlay_ai_error;
const update_check = attyx.overlay_update_check;
const OverlayManager = overlay_mod.OverlayManager;
const popup_mod = @import("popup.zig");
const keybinds_mod = @import("../config/keybinds.zig");
const platform = @import("../platform/platform.zig");
const TabManager = @import("tab_manager.zig").TabManager;
const tab_bar_mod = @import("tab_bar.zig");
const Pane = @import("pane.zig").Pane;
const split_layout_mod = @import("split_layout.zig");
const SplitLayout = split_layout_mod.SplitLayout;
const split_render = @import("split_render.zig");

const c = @cImport({
    @cInclude("bridge.h");
});

const MAX_CELLS = c.ATTYX_MAX_ROWS * c.ATTYX_MAX_COLS;

const PtyThreadCtx = struct {
    tab_mgr: *TabManager,
    cells: [*]c.AttyxCell,
    session: *SessionLog,
    // Reload context (lifetimes: process args alloc in main.zig)
    allocator: std.mem.Allocator,
    no_config: bool,
    config_path: ?[]const u8,
    args: []const [:0]const u8,
    // Applied live settings (updated after each successful reload)
    applied_cursor_shape: CursorShapeConfig,
    applied_cursor_blink: bool,
    applied_cursor_trail: bool,
    applied_scrollback_lines: u32,
    // Theme (registry lives in run(); active_theme updated on reload)
    theme_registry: *ThemeRegistry,
    active_theme: Theme,
    // Diagnostics
    throughput: diag.ThroughputWindow = .{},
    // DEC 2026: timestamp (ns) when synchronized_output became true; 0 = not active.
    sync_start_ns: i128 = 0,
    // Overlay system
    overlay_mgr: ?*OverlayManager = null,
    // Popup terminal
    popup_state: ?*popup_mod.PopupState = null,
    popup_configs: [32]popup_mod.PopupConfig = undefined,
    popup_config_count: u8 = 0,
    // Update notification
    check_updates: bool = false,
    // Full renderer grid dimensions (before subtracting g_grid_top_offset)
    grid_rows: u16 = 0,
    grid_cols: u16 = 0,
};

// Global PTY fd for attyx_send_input (set before attyx_run, read by main thread)
var g_pty_master: posix.fd_t = -1;

// Global engine pointer for attyx_get_link_uri (set before attyx_run, read by renderer thread)
var g_engine: ?*Engine = null;


// Atomic flag: set to 1 to request a config reload on the next PTY thread tick.
// Written by SIGUSR1 handler or attyx_trigger_config_reload(); read-and-reset by PTY thread.
export var g_needs_reload_config: i32 = 0;
export var g_kitty_kbd_flags: i32 = 0;
export var g_needs_font_rebuild: i32 = 0;
export var g_needs_window_update: i32 = 0;
export var g_background_opacity: f32 = 1.0;
export var g_background_blur: i32 = 30;
export var g_window_decorations: i32 = 1;
export var g_padding_left: i32 = 0;
export var g_padding_right: i32 = 0;
export var g_padding_top: i32 = 0;
export var g_padding_bottom: i32 = 0;
// Theme colors (g_theme_cursor_r < 0 = use foreground; g_theme_sel_*_set = 0 = renderer default)
export var g_theme_cursor_r: i32 = -1;
export var g_theme_cursor_g: i32 = 0;
export var g_theme_cursor_b: i32 = 0;
export var g_theme_sel_bg_set: i32 = 0;
export var g_theme_sel_bg_r: i32 = 0;
export var g_theme_sel_bg_g: i32 = 0;
export var g_theme_sel_bg_b: i32 = 0;
export var g_theme_sel_fg_set: i32 = 0;
export var g_theme_sel_fg_r: i32 = 0;
export var g_theme_sel_fg_g: i32 = 0;
export var g_theme_sel_fg_b: i32 = 0;

// App icon embedded at build time (PNG bytes). Read-only from C.
const _icon_bytes = @import("app_icon").data;
export var g_icon_png: [*]const u8 = _icon_bytes.ptr;
export var g_icon_png_len: c_int = @intCast(_icon_bytes.len);

// App version string embedded at build time. Read-only from C.
export var g_app_version: [*]const u8 = attyx.version.ptr;
export var g_app_version_len: c_int = @intCast(attyx.version.len);

// Grid top offset: number of rows to shift terminal content down (search bar padding).
export var g_grid_top_offset: i32 = 0;

// Overlay toggle flag: set to 1 by input thread, read-and-reset by PTY thread.
export var g_toggle_debug_overlay: i32 = 0;

export fn attyx_toggle_debug_overlay() void {
    @atomicStore(i32, &g_toggle_debug_overlay, 1, .seq_cst);
}

// Anchor demo toggle flag: set to 1 by input thread, read-and-reset by PTY thread.
export var g_toggle_anchor_demo: i32 = 0;

export fn attyx_toggle_anchor_demo() void {
    @atomicStore(i32, &g_toggle_anchor_demo, 1, .seq_cst);
}

// AI demo toggle flag: set to 1 by input thread, read-and-reset by PTY thread.
export var g_toggle_ai_demo: i32 = 0;

export fn attyx_toggle_ai_demo() void {
    @atomicStore(i32, &g_toggle_ai_demo, 1, .seq_cst);
}

// Overlay interaction: signal to input thread whether overlay has actionable buttons.
export var g_overlay_has_actions: i32 = 0;

// Atomic flags: input thread sets to 1, PTY thread reads and resets.
var g_overlay_dismiss: i32 = 0;
var g_overlay_cycle_focus: i32 = 0;
var g_overlay_cycle_focus_rev: i32 = 0;
var g_overlay_activate: i32 = 0;

export fn attyx_overlay_esc() void {
    @atomicStore(i32, &g_overlay_dismiss, 1, .seq_cst);
}
export fn attyx_overlay_tab() void {
    @atomicStore(i32, &g_overlay_cycle_focus, 1, .seq_cst);
}
export fn attyx_overlay_shift_tab() void {
    @atomicStore(i32, &g_overlay_cycle_focus_rev, 1, .seq_cst);
}
export fn attyx_overlay_enter() void {
    @atomicStore(i32, &g_overlay_activate, 1, .seq_cst);
}

// Tab bar click: input thread sets target tab index, PTY thread switches.
var g_tab_click_index: i32 = -1;

/// Called from input thread when a click lands on the tab bar row.
/// Computes the tab index from column position and signals the PTY thread.
export fn attyx_tab_bar_click(col: c_int, grid_cols: c_int) void {
    if (g_grid_top_offset <= 0) return; // no tab bar visible
    const idx = tab_bar_mod.tabIndexAtCol(
        @intCast(@max(0, col)),
        @intCast(@atomicLoad(i32, &g_tab_count, .seq_cst)),
        @intCast(@max(1, grid_cols)),
    ) orelse return;
    @atomicStore(i32, &g_tab_click_index, @as(i32, idx), .seq_cst);
}

// Overlay mouse click: input thread sets coords, PTY thread processes.
var g_overlay_click_col: i32 = -1;
var g_overlay_click_row: i32 = -1;
var g_overlay_click_pending: i32 = 0;

// Overlay scroll: input thread sets delta, PTY thread processes.
var g_overlay_scroll_delta: i32 = 0;
var g_overlay_scroll_pending: i32 = 0;

/// Hit-test click against visible overlay descs. Returns 1 if consumed.
/// Called from input thread; signals PTY thread with coordinates.
export fn attyx_overlay_click(col: c_int, row: c_int) c_int {
    if (c.attyx_overlay_hit_test(col, row) != 0) {
        @atomicStore(i32, &g_overlay_click_col, col, .seq_cst);
        @atomicStore(i32, &g_overlay_click_row, row, .seq_cst);
        @atomicStore(i32, &g_overlay_click_pending, 1, .seq_cst);
        return 1;
    }
    return 0;
}

/// Hit-test scroll against visible overlay descs. Returns 1 if consumed.
export fn attyx_overlay_scroll(col: c_int, row: c_int, delta: c_int) c_int {
    if (c.attyx_overlay_hit_test(col, row) != 0) {
        @atomicStore(i32, &g_overlay_scroll_delta, delta, .seq_cst);
        @atomicStore(i32, &g_overlay_scroll_pending, 1, .seq_cst);
        return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Grid-based search bar globals and exports
// ---------------------------------------------------------------------------

// Atomic command ring: input thread writes, PTY thread reads and processes.
// Char ring: up to 32 codepoints buffered.
var g_search_char_ring: [32]u32 = .{0} ** 32;
var g_search_char_write: u32 = 0; // written by input thread (atomic)
var g_search_char_read: u32 = 0; // read by PTY thread

// Command ring: up to 16 commands buffered.
var g_search_cmd_ring: [16]i32 = .{0} ** 16;
var g_search_cmd_write: u32 = 0;
var g_search_cmd_read: u32 = 0;

export fn attyx_search_insert_char(codepoint: u32) void {
    const w = @atomicLoad(u32, &g_search_char_write, .seq_cst);
    const r = @atomicLoad(u32, &g_search_char_read, .seq_cst);
    if (w -% r >= 32) return; // ring full
    g_search_char_ring[w % 32] = codepoint;
    @atomicStore(u32, &g_search_char_write, w +% 1, .seq_cst);
    c.attyx_mark_all_dirty();
}

export fn attyx_search_cmd(cmd: c_int) void {
    const w = @atomicLoad(u32, &g_search_cmd_write, .seq_cst);
    const r = @atomicLoad(u32, &g_search_cmd_read, .seq_cst);
    if (w -% r >= 16) return; // ring full
    g_search_cmd_ring[w % 16] = cmd;
    @atomicStore(u32, &g_search_cmd_write, w +% 1, .seq_cst);
    c.attyx_mark_all_dirty();
}

// ---------------------------------------------------------------------------
// Tab management globals and exports
// ---------------------------------------------------------------------------
var g_tab_action_request: i32 = 0;
var g_tab_count: i32 = 1; // current tab count, readable by input thread
export var g_tab_bar_visible: i32 = 0; // 1 when tab bar overlay is showing

export fn attyx_tab_action(action: c_int) void {
    @atomicStore(i32, &g_tab_action_request, action, .seq_cst);
}

// ---------------------------------------------------------------------------
// Split pane globals and exports
// ---------------------------------------------------------------------------
var g_split_action_request: i32 = 0;
export var g_split_active: i32 = 0;
/// Set by switchActiveTab to force mark_all_dirty on next main-loop render.
/// Prevents stale rows when the renderer discards a torn-read frame.
var g_force_full_redraw: bool = false;
var g_split_click_col: i32 = -1;
var g_split_click_row: i32 = -1;
var g_split_click_pending: i32 = 0;

export fn attyx_split_action(action: c_int) void {
    @atomicStore(i32, &g_split_action_request, action, .seq_cst);
}

export fn attyx_split_click(col: c_int, row: c_int) void {
    @atomicStore(i32, &g_split_click_col, col, .seq_cst);
    @atomicStore(i32, &g_split_click_row, row, .seq_cst);
    @atomicStore(i32, &g_split_click_pending, 1, .seq_cst);
}

// Split pane drag resize state
var g_split_drag_start_col: i32 = -1;
var g_split_drag_start_row: i32 = -1;
var g_split_drag_start_pending: i32 = 0;
var g_split_drag_cur_col: i32 = -1;
var g_split_drag_cur_row: i32 = -1;
var g_split_drag_cur_pending: i32 = 0;
var g_split_drag_end_pending: i32 = 0;
var g_split_drag_branch: u8 = 0xFF;
export var g_split_drag_active: i32 = 0;
export var g_split_drag_direction: i32 = 0;

export fn attyx_split_drag_start(col: c_int, row: c_int) void {
    @atomicStore(i32, &g_split_drag_start_col, col, .seq_cst);
    @atomicStore(i32, &g_split_drag_start_row, row, .seq_cst);
    @atomicStore(i32, &g_split_drag_start_pending, 1, .seq_cst);
}

export fn attyx_split_drag_update(col: c_int, row: c_int) void {
    @atomicStore(i32, &g_split_drag_cur_col, col, .seq_cst);
    @atomicStore(i32, &g_split_drag_cur_row, row, .seq_cst);
    @atomicStore(i32, &g_split_drag_cur_pending, 1, .seq_cst);
}

export fn attyx_split_drag_end() void {
    @atomicStore(i32, &g_split_drag_end_pending, 1, .seq_cst);
}

// ---------------------------------------------------------------------------
// Popup terminal globals and exports
// ---------------------------------------------------------------------------
export var g_popup_active: i32 = 0;
export var g_popup_trail_active: i32 = 0;
var g_popup_toggle_request: [32]i32 = .{0} ** 32;
var g_popup_dead: i32 = 0; // 1 = child exited with error, popup still displayed
var g_popup_close_request: i32 = 0; // input thread requests close of dead popup

// Ensure keybind exports (attyx_keybind_match, g_keybind_matched_seq*) are linked
comptime {
    _ = &keybinds_mod.attyx_keybind_match;
    _ = &keybinds_mod.g_keybind_matched_seq;
    _ = &keybinds_mod.g_keybind_matched_seq_len;
}
var g_popup_pty_master: posix.fd_t = -1; // popup PTY fd for input routing
var g_popup_engine: ?*Engine = null; // popup engine for key encoding

export fn attyx_popup_toggle(index: c_int) void {
    if (index < 0 or index >= 32) return;
    logging.info("popup", "toggle request: index={d}", .{index});
    @atomicStore(i32, &g_popup_toggle_request[@intCast(@as(c_uint, @bitCast(index)))], 1, .seq_cst);
}

export fn attyx_popup_send_input(bytes: [*]const u8, len: c_int) void {
    // Dead popup: Ctrl-C (ETX byte) closes it
    if (@atomicLoad(i32, &g_popup_dead, .seq_cst) != 0) {
        if (len == 1 and bytes[0] == 0x03) {
            @atomicStore(i32, &g_popup_close_request, 1, .seq_cst);
        }
        return;
    }
    const fd = g_popup_pty_master;
    if (fd < 0 or len <= 0) return;
    const data = bytes[0..@intCast(@as(c_uint, @bitCast(len)))];
    _ = posix.write(fd, data) catch {};
}

export fn attyx_popup_handle_key(key_raw: u16, mods_raw: u8, event_type_raw: u8, codepoint_raw: u32) void {
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

    const fd = g_popup_pty_master;
    if (fd < 0) return;
    const eng = g_popup_engine orelse return;
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

export fn attyx_trigger_config_reload() void {
    @atomicStore(i32, &g_needs_reload_config, 1, .seq_cst);
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

fn sigusr1Handler(_: c_int) callconv(.c) void {
    @atomicStore(i32, &g_needs_reload_config, 1, .seq_cst);
}

export fn attyx_send_input(bytes: [*]const u8, len: c_int) void {
    if (g_pty_master < 0 or len <= 0) return;
    const data = bytes[0..@intCast(@as(c_uint, @bitCast(len)))];
    const chunk_size: usize = 4096;
    var offset: usize = 0;
    while (offset < data.len) {
        const end = @min(offset + chunk_size, data.len);
        const n = posix.write(g_pty_master, data[offset..end]) catch |err| {
            if (err == error.WouldBlock) {
                // PTY buffer full — yield briefly and retry
                posix.nanosleep(0, 1_000_000); // 1ms
                continue;
            }
            return; // broken pipe or other fatal error
        };
        offset += n;
    }
}

export fn attyx_handle_key(key_raw: u16, mods_raw: u8, event_type_raw: u8, codepoint_raw: u32) void {
    if (g_pty_master < 0) return;
    const eng = g_engine orelse return;
    const key_encode = attyx.key_encode;

    const key: key_encode.KeyCode = std.meta.intToEnum(key_encode.KeyCode, key_raw) catch return;
    const mods: key_encode.Modifiers = @bitCast(mods_raw);
    const event_type: key_encode.EventType = std.meta.intToEnum(key_encode.EventType, event_type_raw) catch return;
    const cp: u21 = if (codepoint_raw <= 0x10FFFF) @intCast(codepoint_raw) else 0;

    // Read terminal state from engine (published by PTY thread via volatile globals)
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
        _ = posix.write(g_pty_master, encoded) catch {};
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

pub fn run(
    config: AppConfig,
    no_config: bool,
    config_path: ?[]const u8,
    args: []const [:0]const u8,
) !void {
    // Platform support is enforced at compile time via src/platform/platform.zig.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Heap-allocate the initial Pane (Engine + PTY) to keep Engine's ~70KB
    // (Parser buffers) off the main thread's stack.
    const initial_pane = try allocator.create(Pane);
    errdefer allocator.destroy(initial_pane);

    // Publish font config to C bridge
    publishFontConfig(&config);

    // Publish cursor trail config
    c.g_cursor_trail = @intFromBool(config.cursor_trail);

    // Publish background transparency config
    g_background_opacity = config.background_opacity;
    g_background_blur    = @intCast(config.background_blur);

    // Publish window decorations config
    g_window_decorations = if (config.window_decorations) 1 else 0;

    // Publish window padding
    g_padding_left   = @intCast(config.window_padding_left);
    g_padding_right  = @intCast(config.window_padding_right);
    g_padding_top    = @intCast(config.window_padding_top);
    g_padding_bottom = @intCast(config.window_padding_bottom);

    // Theme registry — load built-ins, then custom themes from ~/.config/attyx/themes/
    var theme_registry = ThemeRegistry.init(allocator);
    defer theme_registry.deinit();
    theme_registry.loadBuiltins() catch |err| {
        logging.warn("theme", "failed to load built-in themes: {}", .{err});
    };
    if (config_mod.getThemesDir(allocator)) |themes_dir| {
        defer allocator.free(themes_dir);
        theme_registry.loadDir(themes_dir);
    } else |_| {}
    logging.info("theme", "registry: {d} theme(s) loaded", .{theme_registry.count()});
    var initial_theme = theme_registry.resolve(config.theme_name);
    if (config.theme_background) |bg| initial_theme.background = bg;
    publishTheme(&initial_theme);

    // Install SIGUSR1 → config reload handler.
    const sa = posix.Sigaction{
        .handler = .{ .handler = sigusr1Handler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.USR1, &sa, null);

    // Build spawn argv: --cmd wins, then [program] config, then $SHELL default.
    const program_argv: ?[]const [:0]const u8 = if (config.program) |prog|
        try buildProgramArgv(allocator, prog, config.program_args)
    else
        null;
    defer if (program_argv) |pa| {
        for (pa) |s| allocator.free(s);
        allocator.free(pa);
    };

    const spawn_argv = config.argv orelse program_argv;

    // Spawn initial pane and wrap in TabManager
    initial_pane.* = try Pane.spawn(allocator, config.rows, config.cols, spawn_argv, null);

    // Apply config to initial pane's engine
    initial_pane.engine.state.cursor_shape = cursorShapeFromConfig(config.cursor_shape, config.cursor_blink);
    initial_pane.engine.state.reflow_on_resize = config.reflow_enabled;
    if (config.scrollback_lines != 20_000) {
        initial_pane.engine.state.scrollback.max_lines = config.scrollback_lines;
    }

    var tab_mgr = TabManager.init(allocator, initial_pane);
    defer tab_mgr.deinit();
    {
        const gaps = computeSplitGaps();
        tab_mgr.updateGaps(gaps.h, gaps.v);
    }

    g_pty_master = initial_pane.pty.master;
    g_engine = &initial_pane.engine;
    defer {
        g_pty_master = -1;
        g_engine = null;
    }

    const render_cells = try allocator.alloc(c.AttyxCell, MAX_CELLS);
    defer allocator.free(render_cells);

    const total: usize = @as(usize, config.rows) * @as(usize, config.cols);
    fillCells(render_cells[0..total], &initial_pane.engine, total, &initial_theme);
    c.attyx_set_cursor(@intCast(initial_pane.engine.state.cursor.row), @intCast(initial_pane.engine.state.cursor.col));

    var session = try SessionLog.init(allocator);
    defer session.deinit();

    var overlay_mgr = OverlayManager.init(allocator);
    defer overlay_mgr.deinit();

    // Parse popup configs and build keybind table
    var popup_configs: [32]popup_mod.PopupConfig = undefined;
    var popup_config_count: u8 = 0;
    var popup_hotkeys: [32]keybinds_mod.PopupHotkey = undefined;
    if (config.popup_configs) |entries| {
        for (entries) |entry| {
            if (popup_config_count >= 32) break;
            popup_configs[popup_config_count] = .{
                .command = entry.command,
                .width_pct = popup_mod.parsePct(entry.width, 80),
                .height_pct = popup_mod.parsePct(entry.height, 80),
                .border_style = popup_mod.parseBorderStyle(entry.border),
                .border_fg = popup_mod.parseHexColor(entry.border_color, .{ 120, 130, 150 }),
                .pad = popup_mod.parsePadding(
                    entry.padding,
                    entry.padding_x,
                    entry.padding_y,
                    entry.padding_top,
                    entry.padding_bottom,
                    entry.padding_left,
                    entry.padding_right,
                ),
                .on_return_cmd = entry.on_return_cmd,
                .inject_alt = entry.inject_alt,
                .bg_opacity = if (entry.background_opacity) |o| @intFromFloat(o * 255.0) else 255,
                .bg_color = if (entry.background.len == 7 and entry.background[0] == '#')
                    popup_mod.parseHexColor(entry.background, .{ 0, 0, 0 })
                else
                    null,
            };
            popup_hotkeys[popup_config_count] = .{
                .index = popup_config_count,
                .hotkey = entry.hotkey,
            };
            popup_config_count += 1;
        }
    }
    const kb_table = keybinds_mod.buildTable(
        config.keybind_overrides,
        config.sequence_entries,
        popup_hotkeys[0..popup_config_count],
    );
    keybinds_mod.installTable(&kb_table);
    logging.info("popup", "configured {d} popup(s)", .{popup_config_count});
    logging.info("keybinds", "installed {d} keybind(s)", .{kb_table.count});

    var ctx = PtyThreadCtx{
        .tab_mgr = &tab_mgr,
        .cells = render_cells.ptr,
        .session = &session,
        .allocator = allocator,
        .no_config = no_config,
        .config_path = config_path,
        .args = args,
        .applied_cursor_shape = config.cursor_shape,
        .applied_cursor_blink = config.cursor_blink,
        .applied_cursor_trail = config.cursor_trail,
        .applied_scrollback_lines = @intCast(initial_pane.engine.state.scrollback.max_lines),
        .theme_registry = &theme_registry,
        .active_theme = initial_theme,
        .overlay_mgr = &overlay_mgr,
        .popup_configs = popup_configs,
        .popup_config_count = popup_config_count,
        .check_updates = config.check_updates,
        .grid_rows = config.rows,
        .grid_cols = config.cols,
    };

    const thread = try std.Thread.spawn(.{}, ptyReaderThread, .{&ctx});
    defer thread.join();

    c.attyx_run(render_cells.ptr, @intCast(config.cols), @intCast(config.rows));
}

/// Convert [program] config into a [:0]const u8 slice suitable for Pty.spawn.
fn buildProgramArgv(
    allocator: std.mem.Allocator,
    prog: []const u8,
    args: ?[]const []const u8,
) ![]const [:0]const u8 {
    const extra = args orelse &[_][]const u8{};
    const total = 1 + extra.len;
    const argv = try allocator.alloc([:0]const u8, total);
    argv[0] = try allocator.dupeZ(u8, prog);
    for (extra, 0..) |a, i| {
        argv[1 + i] = try allocator.dupeZ(u8, a);
    }
    return argv;
}

/// Convenience: return the active tab's Engine from a PtyThreadCtx.
fn ctxEngine(ctx: *PtyThreadCtx) *Engine {
    return &ctx.tab_mgr.activePane().engine;
}

/// Convenience: return the active tab's Pty from a PtyThreadCtx.
fn ctxPty(ctx: *PtyThreadCtx) *Pty {
    return &ctx.tab_mgr.activePane().pty;
}

fn cursorShapeFromConfig(shape: CursorShapeConfig, blink: bool) attyx.actions.CursorShape {
    return switch (shape) {
        .block => if (blink) .blinking_block else .steady_block,
        .underline => if (blink) .blinking_underline else .steady_underline,
        .beam => if (blink) .blinking_bar else @enumFromInt(5),
    };
}

fn publishFontConfig(config: *const AppConfig) void {
    const family = config.font_family;
    const len = @min(family.len, c.ATTYX_FONT_FAMILY_MAX - 1);
    @memcpy(c.g_font_family[0..len], family[0..len]);
    c.g_font_family[len] = 0;
    c.g_font_family_len = @intCast(len);
    c.g_font_size = @intCast(config.font_size);
    c.g_cell_width = config.cell_width.encode();
    c.g_cell_height = config.cell_height.encode();

    // Publish fallback font list.
    if (config.font_fallback) |fallback| {
        const count = @min(fallback.len, c.ATTYX_FONT_FALLBACK_MAX);
        for (0..count) |i| {
            const name = fallback[i];
            const flen = @min(name.len, c.ATTYX_FONT_FAMILY_MAX - 1);
            @memcpy(c.g_font_fallback[i][0..flen], name[0..flen]);
            c.g_font_fallback[i][flen] = 0;
        }
        c.g_font_fallback_count = @intCast(count);
    } else {
        c.g_font_fallback_count = 0;
    }
}

fn syncViewportFromC(state: *attyx.TerminalState) void {
    const c_vp: i32 = @bitCast(c.g_viewport_offset);
    if (c_vp >= 0) {
        state.viewport_offset = @intCast(@as(c_uint, @bitCast(c_vp)));
    }
}

/// Extract image_id from a cell's foreground color (Kitty Unicode placement protocol).
fn imageIdFromFg(fg: attyx.grid.Color) ?u32 {
    return switch (fg) {
        .palette => |v| @as(u32, v),
        .ansi => |v| @as(u32, v),
        .rgb => |rgb| (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | @as(u32, rgb.b),
        .default => null,
    };
}

/// Scan the grid for the first U+10EEEE placeholder cell whose fg color encodes the given image_id.
fn findPlaceholderPosition(grid: anytype, image_id: u32) ?struct { row: i32, col: i32 } {
    const rows: usize = @intCast(grid.rows);
    const cols: usize = @intCast(grid.cols);
    for (0..rows) |r| {
        for (0..cols) |co| {
            const cell = grid.cells[r * cols + co];
            if (cell.char == 0x10EEEE) {
                if (imageIdFromFg(cell.style.fg)) |id| {
                    if (id == image_id) {
                        return .{ .row = @intCast(r), .col = @intCast(co) };
                    }
                }
            }
        }
    }
    return null;
}

fn publishImagePlacements(ctx: *PtyThreadCtx) void {
    const state = &ctxEngine(ctx).state;
    const store = state.graphics_store orelse {
        c.g_image_placement_count = 0;
        return;
    };

    const gs = attyx.graphics_store;
    var buf: [c.ATTYX_MAX_IMAGE_PLACEMENTS]gs.Placement = undefined;
    const visible = store.visiblePlacements(state.grid.rows, &buf);

    var out_count: c_int = 0;
    for (visible) |p| {
        if (out_count >= c.ATTYX_MAX_IMAGE_PLACEMENTS) break;

        const img = store.getImage(p.image_id) orelse continue;
        const idx: usize = @intCast(out_count);

        // For virtual placements, derive position from grid placeholder cells.
        var row = p.row;
        var col = p.col;
        if (p.virtual) {
            if (findPlaceholderPosition(&state.grid, p.image_id)) |pos| {
                row = pos.row;
                col = pos.col;
            }
        }

        c.g_image_placements[idx] = .{
            .image_id = p.image_id,
            .row = row,
            .col = col,
            .img_width = img.width,
            .img_height = img.height,
            .src_x = p.src_x,
            .src_y = p.src_y,
            .src_w = p.src_width,
            .src_h = p.src_height,
            .display_cols = p.display_cols,
            .display_rows = p.display_rows,
            .z_index = p.z_index,
            .pixels = img.pixels.ptr,
        };
        out_count += 1;
    }

    c.g_image_placement_count = out_count;
    if (out_count > 0) {
        // Bump generation so renderer knows to check for texture changes.
        _ = @atomicRmw(u64, @as(*u64, @ptrCast(@volatileCast(&c.g_image_gen))), .Add, 1, .seq_cst);
    }
}

fn publishOverlays(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    var out_count: c_int = 0;

    for (mgr.layers[0..overlay_mod.max_layers], 0..) |layer, li| {
        if (!layer.visible) continue;
        const cells = layer.cells orelse continue;
        if (out_count >= c.ATTYX_OVERLAY_MAX_LAYERS) break;

        const idx: usize = @intCast(out_count);
        const cell_count = @min(cells.len, c.ATTYX_OVERLAY_MAX_CELLS);

        for (0..cell_count) |ci| {
            c.g_overlay_cells[idx][ci] = .{
                .character = cells[ci].char,
                .fg_r = cells[ci].fg.r,
                .fg_g = cells[ci].fg.g,
                .fg_b = cells[ci].fg.b,
                .bg_r = cells[ci].bg.r,
                .bg_g = cells[ci].bg.g,
                .bg_b = cells[ci].bg.b,
                .bg_alpha = cells[ci].bg_alpha,
            };
        }

        c.g_overlay_descs[idx] = .{
            .visible = 1,
            .col = @intCast(layer.col),
            .row = @intCast(layer.row),
            .width = @intCast(layer.width),
            .height = @intCast(layer.height),
            .cell_count = @intCast(cell_count),
            .z_order = @intCast(li),
        };

        out_count += 1;
    }

    c.g_overlay_count = out_count;

    // Update g_overlay_has_actions so input thread knows whether to intercept keys
    g_overlay_has_actions = if (mgr.hasActiveActions()) @as(i32, 1) else @as(i32, 0);

    _ = @atomicRmw(u32, @as(*u32, @ptrCast(@volatileCast(&c.g_overlay_gen))), .Add, 1, .seq_cst);
}

fn generateDebugCard(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    if (!mgr.isVisible(.debug_card)) return;

    const eng = ctxEngine(ctx);
    const cols: u16 = @intCast(eng.state.grid.cols);
    const rows: u16 = @intCast(eng.state.grid.rows);

    // Format debug info lines
    var grid_buf: [32]u8 = undefined;
    var vp_buf: [32]u8 = undefined;
    var sb_buf: [32]u8 = undefined;
    var cur_buf: [32]u8 = undefined;
    var alt_buf: [32]u8 = undefined;

    const grid_line = std.fmt.bufPrint(&grid_buf, "Grid: {d}x{d}", .{ cols, rows }) catch "Grid: ?";
    const vp_line = std.fmt.bufPrint(&vp_buf, "Viewport: {d}", .{eng.state.viewport_offset}) catch "Viewport: ?";
    const sb_line = std.fmt.bufPrint(&sb_buf, "Scrollback: {d}", .{eng.state.scrollback.count}) catch "Scrollback: ?";
    const cur_line = std.fmt.bufPrint(&cur_buf, "Cursor: {d},{d}", .{ eng.state.cursor.row, eng.state.cursor.col }) catch "Cursor: ?";
    const alt_line = std.fmt.bufPrint(&alt_buf, "Alt screen: {s}", .{if (eng.state.alt_active) "yes" else "no"}) catch "Alt screen: ?";

    const debug_lines = [_][]const u8{
        grid_line,
        vp_line,
        sb_line,
        cur_line,
        alt_line,
    };

    const action_mod = attyx.overlay_action;

    // Build action bar with [Dismiss] button
    var action_bar = action_mod.ActionBar{};
    action_bar.add(.dismiss, "Dismiss");
    // Preserve focus state from existing action_bar if present
    const layer = &mgr.layers[@intFromEnum(overlay_mod.OverlayId.debug_card)];
    if (layer.action_bar) |existing| {
        action_bar.focused = existing.focused;
    }

    const result = overlay_layout.layoutActionCard(
        mgr.allocator,
        "Attyx Debug",
        &debug_lines,
        layer.style,
        action_bar,
    ) catch return;

    // Position: top-right, 2 cells margin
    const card_col = if (cols > result.width + 2) cols - result.width - 2 else 0;
    const card_row: u16 = 2;

    mgr.setContent(.debug_card, card_col, card_row, result.width, result.height, result.cells) catch {
        mgr.allocator.free(result.cells);
        return;
    };
    // layoutActionCard allocated cells; setContent copies them, so free the original.
    mgr.allocator.free(result.cells);

    // Store action_bar on the layer for interaction
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.debug_card)].action_bar = action_bar;
}

fn viewportInfoFromCtx(ctx: *PtyThreadCtx) overlay_anchor.ViewportInfo {
    const eng = ctxEngine(ctx);
    const sel_active_raw: i32 = @bitCast(c.g_sel_active);
    const sel_end_row_raw: i32 = @bitCast(c.g_sel_end_row);
    const sel_end_col_raw: i32 = @bitCast(c.g_sel_end_col);
    return .{
        .grid_cols = @intCast(eng.state.grid.cols),
        .grid_rows = @intCast(eng.state.grid.rows),
        .cursor_row = @intCast(eng.state.cursor.row),
        .cursor_col = @intCast(eng.state.cursor.col),
        .sel_active = sel_active_raw != 0,
        .sel_end_row = if (sel_end_row_raw >= 0) @intCast(@as(u32, @bitCast(sel_end_row_raw))) else 0,
        .sel_end_col = if (sel_end_col_raw >= 0) @intCast(@as(u32, @bitCast(sel_end_col_raw))) else 0,
        .alt_active = eng.state.alt_active,
    };
}

// Shared anchor demo mode counter (persists across calls).
var g_anchor_mode_counter: u8 = 0;

// AI demo streaming state (persists across PTY loop iterations).
var g_streaming: ?overlay_streaming.StreamingOverlay = null;

// Context bundle captured when the AI demo is started.
var g_context_bundle: ?overlay_context.ContextBundle = null;

// AI backend integration state
var g_token_store: ?overlay_ai_auth.TokenStore = null;
var g_auth_thread: ?overlay_ai_auth.AuthThread = null;
var g_sse_thread: ?overlay_ai_stream.SseThread = null;
var g_ai_accumulator: ?overlay_ai_content.AiContentAccumulator = null;
var g_ai_request_body: ?[]u8 = null;
const g_ai_base_url: []const u8 = overlay_ai_config.base_url;

// Update notification state
var g_update_checker: ?update_check.UpdateChecker = null;

fn generateAnchorDemo(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    if (!mgr.isVisible(.anchor_demo)) return;

    const kinds = [_]overlay_anchor.AnchorKind{
        .cursor_line,
        .selection_end,
        .after_command,
        .viewport_dock,
    };
    const kind_names = [_][]const u8{
        "cursor_line",
        "selection_end",
        "after_command",
        "viewport_dock",
    };

    const kind = kinds[g_anchor_mode_counter % 4];
    const kind_name = kind_names[g_anchor_mode_counter % 4];

    // Build card content
    var mode_buf: [32]u8 = undefined;
    const mode_line = std.fmt.bufPrint(&mode_buf, "Mode: {s}", .{kind_name}) catch "Mode: ?";

    const demo_lines = [_][]const u8{
        mode_line,
        "Ctrl+Shift+A: cycle",
    };

    const result = overlay_layout.layoutDebugCard(
        mgr.allocator,
        "Anchor Demo",
        &demo_lines,
        mgr.layers[@intFromEnum(overlay_mod.OverlayId.anchor_demo)].style,
    ) catch return;

    // Build anchor based on current mode
    const vp = viewportInfoFromCtx(ctx);
    const anchor = overlay_anchor.Anchor{
        .kind = kind,
        .command_row_hint = if (vp.cursor_row + 1 < vp.grid_rows) vp.cursor_row + 1 else null,
        .dock = .bottom_right,
    };

    const placement = overlay_anchor.placeOverlay(anchor, result.width, result.height, vp, .{});

    mgr.setContent(.anchor_demo, placement.col, placement.row, result.width, result.height, result.cells) catch {
        mgr.allocator.free(result.cells);
        return;
    };
    mgr.allocator.free(result.cells);

    // Store anchor on the layer for relayout
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.anchor_demo)].anchor = anchor;
}

fn captureAiContext(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const eng = ctxEngine(ctx);

    if (g_context_bundle) |*old| old.deinit();
    g_context_bundle = null;

    const sel_active_raw: i32 = @bitCast(c.g_sel_active);
    const sel_start_row_raw: i32 = @bitCast(c.g_sel_start_row);
    const sel_start_col_raw: i32 = @bitCast(c.g_sel_start_col);
    const sel_end_row_raw: i32 = @bitCast(c.g_sel_end_row);
    const sel_end_col_raw: i32 = @bitCast(c.g_sel_end_col);
    const sel_bounds: ?overlay_context_extract.SelBounds = if (sel_active_raw != 0)
        .{
            .start_row = if (sel_start_row_raw >= 0) @intCast(@as(u32, @bitCast(sel_start_row_raw))) else 0,
            .start_col = if (sel_start_col_raw >= 0) @intCast(@as(u32, @bitCast(sel_start_col_raw))) else 0,
            .end_row = if (sel_end_row_raw >= 0) @intCast(@as(u32, @bitCast(sel_end_row_raw))) else 0,
            .end_col = if (sel_end_col_raw >= 0) @intCast(@as(u32, @bitCast(sel_end_col_raw))) else 0,
        }
    else
        null;

    const title_len_raw: i32 = @bitCast(c.g_title_len);
    const title_len: usize = if (title_len_raw > 0) @intCast(@as(u32, @bitCast(title_len_raw))) else 0;
    const title_ptr: ?[*]const u8 = if (title_len > 0) @ptrCast(&c.g_title_buf) else null;

    g_context_bundle = overlay_context.captureContext(
        mgr.allocator,
        &eng.state.grid,
        &eng.state.scrollback,
        eng.state.cursor.row,
        title_ptr,
        title_len,
        sel_bounds,
        80,
        eng.state.alt_active,
    ) catch null;
}

fn showAiOverlayCard(ctx: *PtyThreadCtx, cells: []overlay_mod.OverlayCell, width: u16, height: u16, bar: attyx.overlay_action.ActionBar) void {
    const mgr = ctx.overlay_mgr orelse return;
    const vp = viewportInfoFromCtx(ctx);
    const anchor = overlay_anchor.Anchor{ .kind = .viewport_dock, .dock = .bottom_right };
    const placement = overlay_anchor.placeOverlay(anchor, width, height, vp, .{});

    const margin: u16 = 1;
    const bottom_row: u16 = if (vp.grid_rows > margin + 1) vp.grid_rows - 1 - margin else vp.grid_rows -| 1;
    const max_vis: u16 = if (vp.grid_rows > margin * 2) vp.grid_rows - margin * 2 else 3;

    if (g_streaming == null) {
        g_streaming = overlay_streaming.StreamingOverlay{ .allocator = mgr.allocator };
    }
    var so = &(g_streaming.?);
    so.start(cells, width, height, placement.col, bottom_row, max_vis, std.time.nanoTimestamp());

    mgr.layers[@intFromEnum(overlay_mod.OverlayId.ai_demo)].action_bar = bar;
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.ai_demo)].anchor = anchor;
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.ai_demo)].z_order = 2;

    publishAiStreamingFrame(ctx);
}

fn spawnSseStream(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const bundle = &(g_context_bundle orelse return);
    const store = &(g_token_store orelse return);
    const token = store.access_token orelse return;

    // Serialize request body
    if (g_ai_request_body) |old| mgr.allocator.free(old);
    g_ai_request_body = overlay_ai_config.serializeRequest(mgr.allocator, bundle) catch null;
    const body = g_ai_request_body orelse return;

    // Build URL
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/v1/ai/execute/stream", .{g_ai_base_url}) catch return;

    // Initialize SSE thread
    if (g_sse_thread == null) g_sse_thread = overlay_ai_stream.SseThread.init();
    var sse = &(g_sse_thread.?);

    // Initialize accumulator
    if (g_ai_accumulator == null) {
        g_ai_accumulator = overlay_ai_content.AiContentAccumulator.init(mgr.allocator);
    } else {
        g_ai_accumulator.?.reset();
    }

    // Show connecting card
    const connecting_result = overlay_ai_error.layoutConnectingCard(mgr.allocator, 48) catch return;
    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.dismiss, "Cancel");
    showAiOverlayCard(ctx, connecting_result.cells, connecting_result.width, connecting_result.height, bar);

    // Start SSE thread
    sse.start(mgr.allocator, url, token, body) catch {
        showAiErrorCard(ctx, "connection", "Failed to start SSE connection");
        return;
    };
}

fn startAiInvocation(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;

    // Capture terminal context
    captureAiContext(ctx);

    // Load token store if not yet loaded
    if (g_token_store == null) {
        g_token_store = overlay_ai_auth.TokenStore.load(mgr.allocator) catch
            overlay_ai_auth.TokenStore.init(mgr.allocator);
    }
    var store = &(g_token_store.?);

    if (store.hasAccessToken()) {
        // Have access token — go straight to SSE
        spawnSseStream(ctx);
    } else if (store.hasRefreshToken()) {
        // Have refresh token — try refresh first
        startAuthFlow(ctx, store.refresh_token);
    } else {
        // No tokens — device flow
        startAuthFlow(ctx, null);
    }
}

fn startAuthFlow(ctx: *PtyThreadCtx, refresh_token: ?[]const u8) void {
    const mgr = ctx.overlay_mgr orelse return;

    if (g_auth_thread == null) g_auth_thread = overlay_ai_auth.AuthThread.init();
    var auth = &(g_auth_thread.?);

    auth.startAuth(mgr.allocator, g_ai_base_url, refresh_token) catch {
        showAiErrorCard(ctx, "auth", "Failed to start authentication");
        return;
    };

    // Show connecting/refreshing card
    const result = overlay_ai_error.layoutConnectingCard(mgr.allocator, 48) catch return;
    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.dismiss, "Cancel");
    showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
}

fn showAiErrorCard(ctx: *PtyThreadCtx, code: []const u8, msg: []const u8) void {
    const mgr = ctx.overlay_mgr orelse return;
    const result = overlay_ai_error.layoutErrorCard(mgr.allocator, code, msg, 48) catch return;
    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.retry, "Retry");
    bar.add(.copy, "Copy diagnostics");
    bar.add(.dismiss, "Dismiss");
    showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
}

fn showDeviceCodeCard(ctx: *PtyThreadCtx, user_code: []const u8) void {
    const mgr = ctx.overlay_mgr orelse return;
    const result = overlay_ai_error.layoutDeviceCodeCard(mgr.allocator, user_code, 48) catch return;
    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.dismiss, "Cancel");
    showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
}

fn publishAiStreamingFrame(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    var so = &(g_streaming orelse return);

    var scratch: [c.ATTYX_OVERLAY_MAX_CELLS]overlay_mod.OverlayCell = undefined;
    const vis = so.buildVisibleCells(&scratch) orelse return;

    // Bottom-anchored: row computed from anchor_bottom_row - visible_height + 1
    const top_row = so.topRow();
    mgr.setContent(.ai_demo, so.col, top_row, vis.width, vis.height, scratch[0 .. @as(usize, vis.width) * vis.height]) catch return;
    publishOverlays(ctx);
}

fn tickAi(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;

    // --- Check auth thread status ---
    if (g_auth_thread) |*auth| {
        const auth_status = auth.getStatus();
        switch (auth_status) {
            .device_show_code => {
                // Show device code overlay
                const user_code = auth.getUserCode();
                if (user_code.len > 0) {
                    showDeviceCodeCard(ctx, user_code);
                    publishOverlays(ctx);
                }
            },
            .authenticated => {
                // Store tokens and spawn SSE
                const at = auth.getAccessToken();
                const rt = auth.getRefreshToken();
                if (at.len > 0) {
                    if (g_token_store) |*store| {
                        store.update(at, rt) catch {};
                        store.save() catch {};
                    }
                }
                _ = auth.tryJoin();
                spawnSseStream(ctx);
                publishOverlays(ctx);
            },
            .failed => {
                const err_msg = auth.getErrorMsg();
                showAiErrorCard(ctx, "auth", if (err_msg.len > 0) err_msg else "Authentication failed");
                _ = auth.tryJoin();
                publishOverlays(ctx);
            },
            else => {},
        }
    }

    // --- Check SSE thread status ---
    if (g_sse_thread) |*sse| {
        const sse_status = sse.getStatus();
        switch (sse_status) {
            .streaming => {
                // Drain delta ring → accumulator → reparse → relayout
                var drain_buf: [4096]u8 = undefined;
                const drained = sse.delta_ring.drain(&drain_buf);
                if (drained.len > 0) {
                    if (g_ai_accumulator) |*acc| {
                        acc.appendDelta(drained) catch {};
                        const blocks = acc.reparse() catch &.{};
                        if (blocks.len > 0) {
                            relayoutAiStreamContent(ctx, blocks);
                        }
                    }
                }
            },
            .done => {
                // Final drain
                var drain_buf: [4096]u8 = undefined;
                const drained = sse.delta_ring.drain(&drain_buf);
                if (drained.len > 0) {
                    if (g_ai_accumulator) |*acc| {
                        acc.appendDelta(drained) catch {};
                    }
                }
                // Final reparse and relayout with completion action bar
                if (g_ai_accumulator) |*acc| {
                    const blocks = acc.reparse() catch &.{};
                    if (blocks.len > 0) {
                        relayoutAiStreamContent(ctx, blocks);
                    }
                }
                // Update action bar to show Insert/Copy/Context/Dismiss
                var bar = attyx.overlay_action.ActionBar{};
                bar.add(.dismiss, "Dismiss");
                bar.add(.insert, "Insert");
                bar.add(.copy, "Copy");
                bar.add(.context, "Context");
                mgr.layers[@intFromEnum(overlay_mod.OverlayId.ai_demo)].action_bar = bar;

                _ = sse.tryJoin();
                publishOverlays(ctx);
            },
            .errored => {
                const http_code = sse.getHttpStatus();
                _ = sse.tryJoin();

                if (http_code == 401) {
                    // Token expired — try refresh
                    if (g_token_store) |*store| {
                        // Clear expired access token
                        if (store.access_token) |at| store.allocator.free(at);
                        store.access_token = null;
                        startAuthFlow(ctx, store.refresh_token);
                    }
                } else {
                    const code = sse.getErrorCode();
                    const msg = sse.getErrorMsg();
                    showAiErrorCard(ctx, code, if (msg.len > 0) msg else "Request failed");
                }
                publishOverlays(ctx);
            },
            .canceled => {
                _ = sse.tryJoin();
            },
            else => {},
        }
    }

    // --- Tick streaming reveal animation ---
    if (g_streaming) |*so| {
        if (so.state != .active) return;
        if (so.tick(std.time.nanoTimestamp())) {
            publishAiStreamingFrame(ctx);
        }
    }
}

fn tickUpdateCheck(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    var checker = &(g_update_checker orelse return);

    const status = checker.getStatus();
    switch (status) {
        .update_available => {
            const latest = checker.getLatestVersion();
            logging.info("update", "update available: {s}", .{latest});
            if (latest.len > 0) {
                const result = update_check.layoutUpdateCard(mgr.allocator, latest) catch |err| {
                    logging.err("update", "layoutUpdateCard failed: {}", .{err});
                    return;
                };

                const eng = ctxEngine(ctx);
                const cols: u16 = @intCast(eng.state.grid.cols);
                const rows: u16 = @intCast(eng.state.grid.rows);
                // Position: bottom-right, 1 cell margin
                const card_col = if (cols > result.width + 1) cols - result.width - 1 else 0;
                const card_row = if (rows > result.height + 1) rows - result.height - 1 else 0;

                logging.info("update", "showing card at col={d} row={d} w={d} h={d}", .{ card_col, card_row, result.width, result.height });
                mgr.setContent(.update_notification, card_col, card_row, result.width, result.height, result.cells) catch {
                    mgr.allocator.free(result.cells);
                    logging.err("update", "setContent failed", .{});
                    return;
                };
                mgr.allocator.free(result.cells);

                mgr.layers[@intFromEnum(overlay_mod.OverlayId.update_notification)].action_bar = result.action_bar;
                mgr.show(.update_notification);
                publishOverlays(ctx);
                logging.info("update", "overlay published", .{});
            }
            checker.tryJoin();
            g_update_checker = null;
        },
        .up_to_date => {
            logging.info("update", "up to date", .{});
            checker.tryJoin();
            g_update_checker = null;
        },
        .throttled => {
            logging.info("update", "throttled (checked within 24h)", .{});
            checker.tryJoin();
            g_update_checker = null;
        },
        .failed => {
            logging.warn("update", "update check failed", .{});
            checker.tryJoin();
            g_update_checker = null;
        },
        else => {},
    }
}

/// Relayout the streaming overlay with new content blocks from the accumulator.
fn relayoutAiStreamContent(ctx: *PtyThreadCtx, blocks: []const overlay_content.ContentBlock) void {
    const mgr = ctx.overlay_mgr orelse return;

    // Build title from invocation type
    const title = if (g_context_bundle) |*bundle| switch (bundle.invocation) {
        .error_explain => "Error Explanation",
        .selection_explain => "Selection Explanation",
        .command_generate => "Generate Command",
        .general => "AI Response",
    } else "AI Response";

    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.dismiss, "Cancel");

    const result = overlay_content.layoutStructuredCard(
        mgr.allocator,
        title,
        blocks,
        48,
        .{},
        bar,
    ) catch return;

    if (g_streaming) |*so| {
        so.replaceContent(result.cells, result.width, result.height);
        publishAiStreamingFrame(ctx);
    } else {
        showAiOverlayCard(ctx, result.cells, result.width, result.height, bar);
    }
}

/// Reposition the AI demo streaming overlay after a window resize.
/// Updates bottom_row, col, and max_visible_height from the new viewport,
/// then republishes the visible frame.
fn relayoutAiDemo(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    if (!mgr.isVisible(.ai_demo)) return;
    var so = &(g_streaming orelse return);

    const vp = viewportInfoFromCtx(ctx);
    const margin: u16 = 1;
    const bottom_row: u16 = if (vp.grid_rows > margin + 1) vp.grid_rows - 1 - margin else vp.grid_rows -| 1;
    const max_vis: u16 = if (vp.grid_rows > margin * 2) vp.grid_rows - margin * 2 else 3;

    // Recompute horizontal placement
    const anchor = overlay_anchor.Anchor{ .kind = .viewport_dock, .dock = .bottom_right };
    const placement = overlay_anchor.placeOverlay(anchor, so.full_width, so.full_height, vp, .{});

    so.anchor_bottom_row = bottom_row;
    so.max_visible_height = max_vis;
    so.col = placement.col;

    publishAiStreamingFrame(ctx);
}

/// Layout and place the context preview card into the overlay manager.
/// Handles bottom-anchored placement and viewport height capping.
/// Does NOT change visibility — caller is responsible for show/hide.
fn placeContextPreviewCard(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const bundle = &(g_context_bundle orelse return);
    const vp = viewportInfoFromCtx(ctx);

    const result = overlay_context_ui.layoutContextPreview(
        mgr.allocator,
        bundle,
        @min(vp.grid_cols, 50),
        .{},
    ) catch return;
    defer mgr.allocator.free(result.cells);

    // Bottom-anchored placement with viewport capping (same pattern as AI demo)
    const margin: u16 = 1;
    const bottom_row: u16 = if (vp.grid_rows > margin + 1) vp.grid_rows - 1 - margin else vp.grid_rows -| 1;
    const max_vis: u16 = if (vp.grid_rows > margin * 2) vp.grid_rows - margin * 2 else 3;
    const vis_h: u16 = @min(result.height, max_vis);
    const top_row: u16 = if (bottom_row + 1 >= vis_h) bottom_row + 1 - vis_h else 0;
    const col: u16 = if (vp.grid_cols > result.width + margin) vp.grid_cols - result.width - margin else 0;

    if (vis_h >= result.height) {
        mgr.setContent(.context_preview, col, top_row, result.width, result.height, result.cells) catch return;
    } else {
        // Build a height-capped view: top border + content window + action bar + bottom border
        const w: usize = result.width;
        const fh: usize = result.height;
        const vh: usize = vis_h;
        if (vh < 3 or w == 0) return;
        const needed = vh * w;
        var scratch: [c.ATTYX_OVERLAY_MAX_CELLS]overlay_mod.OverlayCell = undefined;
        if (needed > scratch.len) return;

        @memcpy(scratch[0..w], result.cells[0..w]);
        const visible_content = vh -| 3;
        if (visible_content > 0) {
            const src_start = 1 * w;
            const dst_start = 1 * w;
            const count = visible_content * w;
            if (src_start + count <= result.cells.len) {
                @memcpy(scratch[dst_start .. dst_start + count], result.cells[src_start .. src_start + count]);
            }
        }
        {
            const src_row = fh - 2;
            const dst_row = vh - 2;
            @memcpy(scratch[dst_row * w .. (dst_row + 1) * w], result.cells[src_row * w .. (src_row + 1) * w]);
        }
        {
            const src_row = fh - 1;
            const dst_row = vh - 1;
            @memcpy(scratch[dst_row * w .. (dst_row + 1) * w], result.cells[src_row * w .. (src_row + 1) * w]);
        }
        mgr.setContent(.context_preview, col, top_row, result.width, @intCast(vh), scratch[0..needed]) catch return;
    }

    // Action bar for Back button
    var bar = attyx.overlay_action.ActionBar{};
    bar.add(.dismiss, "Back");
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.context_preview)].action_bar = bar;
    mgr.layers[@intFromEnum(overlay_mod.OverlayId.context_preview)].z_order = 3;
}

/// Rebuild the context preview overlay after a window resize.
fn relayoutContextPreview(ctx: *PtyThreadCtx) void {
    if (ctx.overlay_mgr) |mgr| {
        if (!mgr.isVisible(.context_preview)) return;
    } else return;
    placeContextPreviewCard(ctx);
}

fn toggleContextPreview(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;

    if (mgr.isVisible(.context_preview)) {
        mgr.hide(.context_preview);
        // Restore AI demo visibility
        mgr.show(.ai_demo);
        publishOverlays(ctx);
        return;
    }

    placeContextPreviewCard(ctx);

    // Hide AI demo while context preview is shown (prevents overlap)
    mgr.hide(.ai_demo);
    mgr.show(.context_preview);
    publishOverlays(ctx);
}

fn handleInsertAction(ctx: *PtyThreadCtx) void {
    // Try real accumulator blocks first, fall back to demo
    const code = blk: {
        if (g_ai_accumulator) |*acc| {
            const blocks = acc.reparse() catch break :blk @as(?[]const u8, null);
            if (overlay_content.firstCodeBlock(blocks)) |cb| break :blk @as(?[]const u8, cb);
        }
        break :blk overlay_content.firstCodeBlock(&overlay_demo.mock_blocks);
    } orelse return;

    if (ctxEngine(ctx).state.bracketed_paste) {
        c.attyx_send_input("\x1b[200~", 6);
    }
    c.attyx_send_input(code.ptr, @intCast(code.len));
    if (ctxEngine(ctx).state.bracketed_paste) {
        c.attyx_send_input("\x1b[201~", 6);
    }
}

fn handleCopyAction(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    if (mgr.isVisible(.context_preview)) {
        // Copy diagnostics text
        if (g_context_bundle) |*bundle| {
            const diag_text = bundle.serializeDiagnostics() catch return;
            defer bundle.allocator.free(diag_text);
            c.attyx_clipboard_copy(diag_text.ptr, @intCast(diag_text.len));
        }
    } else {
        // Copy first code block from accumulator, fallback to demo
        const code = blk: {
            if (g_ai_accumulator) |*acc| {
                const blocks = acc.reparse() catch break :blk @as(?[]const u8, null);
                if (overlay_content.firstCodeBlock(blocks)) |cb| break :blk @as(?[]const u8, cb);
            }
            break :blk overlay_content.firstCodeBlock(&overlay_demo.mock_blocks);
        } orelse return;
        c.attyx_clipboard_copy(code.ptr, @intCast(code.len));
    }
}

fn handleRetryAction(ctx: *PtyThreadCtx) void {
    // Cancel current operations
    if (g_sse_thread) |*sse| {
        sse.requestCancel();
        _ = sse.tryJoin();
    }
    if (g_auth_thread) |*auth| {
        auth.requestCancel();
        _ = auth.tryJoin();
    }
    if (g_streaming) |*so| so.cancel();
    if (g_ai_accumulator) |*acc| acc.reset();

    // Re-invoke
    startAiInvocation(ctx);
}

fn cancelAi(ctx: *PtyThreadCtx) void {
    // Cancel SSE thread
    if (g_sse_thread) |*sse| {
        sse.requestCancel();
        _ = sse.tryJoin();
    }
    // Cancel auth thread
    if (g_auth_thread) |*auth| {
        auth.requestCancel();
        _ = auth.tryJoin();
    }
    // Cancel streaming overlay
    if (g_streaming) |*so| {
        so.cancel();
    }
    if (ctx.overlay_mgr) |mgr| {
        mgr.hide(.ai_demo);
        mgr.hide(.context_preview);
    }
    // Free request body
    if (g_ai_request_body) |body| {
        if (ctx.overlay_mgr) |mgr| mgr.allocator.free(body);
        g_ai_request_body = null;
    }
    // Free accumulator
    if (g_ai_accumulator) |*acc| {
        acc.deinit();
        g_ai_accumulator = null;
    }
    // Free context
    if (g_context_bundle) |*bundle| {
        bundle.deinit();
        g_context_bundle = null;
    }
}

fn publishState(ctx: *PtyThreadCtx) void {
    c.attyx_set_mode_flags(
        @intFromBool(ctxEngine(ctx).state.bracketed_paste),
        @intFromBool(ctxEngine(ctx).state.cursor_keys_app),
    );
    c.attyx_set_mouse_mode(
        @intFromEnum(ctxEngine(ctx).state.mouse_tracking),
        @intFromBool(ctxEngine(ctx).state.mouse_sgr),
    );
    c.g_scrollback_count = @intCast(ctxEngine(ctx).state.scrollback.count);
    c.g_alt_screen = @intFromBool(ctxEngine(ctx).state.alt_active);
    c.g_viewport_offset = @intCast(ctxEngine(ctx).state.viewport_offset);

    c.g_cursor_shape = @intFromEnum(ctxEngine(ctx).state.cursor_shape);
    c.g_cursor_visible = @intFromBool(ctxEngine(ctx).state.cursor_visible);
    g_kitty_kbd_flags = @intCast(ctxEngine(ctx).state.kittyFlags());

    // Window title: prefer OSC 0/2 title from the shell; fall back to the
    // foreground process name (e.g. "zsh", "vim") so the title bar is useful
    // even when the shell doesn't send title sequences.
    if (ctxEngine(ctx).state.title) |title| {
        const len: usize = @min(title.len, c.ATTYX_TITLE_MAX - 1);
        @memcpy(c.g_title_buf[0..len], title[0..len]);
        c.g_title_buf[len] = 0;
        c.g_title_len = @intCast(len);
        c.g_title_changed = 1;
    } else {
        var name_buf: [256]u8 = undefined;
        if (platform.getForegroundProcessName(ctxPty(ctx).master, &name_buf)) |name| {
            const len: usize = @min(name.len, c.ATTYX_TITLE_MAX - 1);
            // Only update if the name actually changed.
            const cur_len: usize = @intCast(c.g_title_len);
            const same = (len == cur_len) and std.mem.eql(u8, c.g_title_buf[0..cur_len], name[0..len]);
            if (!same) {
                @memcpy(c.g_title_buf[0..len], name[0..len]);
                c.g_title_buf[len] = 0;
                c.g_title_len = @intCast(len);
                c.g_title_changed = 1;
            }
        }
    }
}

var g_search: ?SearchState = null;
var g_search_bar = overlay_search.SearchBarState{};
var g_saved_cursor_shape: i32 = -1; // -1 = not saved
var g_saved_cursor_row: c_int = 0;
var g_saved_cursor_col: c_int = 0;
var g_saved_viewport_offset: usize = 0;
var g_viewport_compensated: bool = false;

/// Consume search input commands from the atomic rings, apply to SearchBarState,
/// and sync the query into g_search_query/g_search_gen for processSearch.
/// Returns true if any input was consumed.
fn consumeSearchInput() bool {
    var consumed = false;
    var query_changed = false;

    // Process character insertions
    while (true) {
        const r = @atomicLoad(u32, &g_search_char_read, .seq_cst);
        const w = @atomicLoad(u32, &g_search_char_write, .seq_cst);
        if (r == w) break;
        const cp: u21 = @intCast(g_search_char_ring[r % 32]);
        g_search_bar.insertChar(cp);
        @atomicStore(u32, &g_search_char_read, r +% 1, .seq_cst);
        consumed = true;
        query_changed = true;
    }

    // Process commands
    while (true) {
        const r = @atomicLoad(u32, &g_search_cmd_read, .seq_cst);
        const w = @atomicLoad(u32, &g_search_cmd_write, .seq_cst);
        if (r == w) break;
        const cmd = g_search_cmd_ring[r % 16];
        @atomicStore(u32, &g_search_cmd_read, r +% 1, .seq_cst);
        consumed = true;

        switch (cmd) {
            1 => { g_search_bar.deleteBack(); query_changed = true; },
            2 => { g_search_bar.deleteFwd(); query_changed = true; },
            3 => g_search_bar.cursorLeft(),
            4 => g_search_bar.cursorRight(),
            5 => g_search_bar.cursorHome(),
            6 => g_search_bar.cursorEnd(),
            10 => { g_search_bar.deleteWord(); query_changed = true; },
            7 => {
                // Dismiss search
                g_search_bar.clear();
                c.g_search_active = 0;
                c.g_search_query_len = 0;
                c.g_search_gen += 1;
                c.attyx_mark_all_dirty();
            },
            8 => {
                // Next match
                _ = @atomicRmw(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_search_nav_delta))), .Add, 1, .seq_cst);
            },
            9 => {
                // Prev match
                _ = @atomicRmw(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_search_nav_delta))), .Add, -1, .seq_cst);
            },
            else => {},
        }
    }

    // Sync query bytes into bridge globals so processSearch sees them
    if (query_changed) {
        const qlen: usize = g_search_bar.query_len;
        @memcpy(c.g_search_query[0..qlen], g_search_bar.query[0..qlen]);
        c.g_search_query_len = @intCast(qlen);
        c.g_search_gen += 1;
        c.attyx_mark_all_dirty();
    }

    return consumed;
}

fn generateSearchBar(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const active: i32 = @bitCast(c.g_search_active);

    if (active == 0) {
        if (mgr.isVisible(.search_bar)) {
            mgr.hide(.search_bar);
            g_search_bar.clear();
            // Restore original cursor shape and position
            if (g_saved_cursor_shape >= 0) {
                c.g_cursor_shape = g_saved_cursor_shape;
                g_saved_cursor_shape = -1;
            }
            c.attyx_set_cursor(g_saved_cursor_row, g_saved_cursor_col);
            updateGridTopOffset(ctx);
            // Restore viewport scroll compensation
            if (g_viewport_compensated) {
                ctxEngine(ctx).state.viewport_offset = g_saved_viewport_offset;
                c.g_viewport_offset = @intCast(g_saved_viewport_offset);
                g_viewport_compensated = false;
                c.attyx_mark_all_dirty();
            }
            publishOverlays(ctx);
        }
        return;
    }

    // Detect fresh activation: search_bar not yet visible but g_search_active is 1
    if (!mgr.isVisible(.search_bar)) {
        g_search_bar.clear();
        // Save current cursor shape/position and switch to blinking block
        g_saved_cursor_shape = c.g_cursor_shape;
        g_saved_cursor_row = c.g_cursor_row;
        g_saved_cursor_col = c.g_cursor_col;
        c.g_cursor_shape = 0; // blinking_block
        updateGridTopOffset(ctx);
        // Compensate viewport: scroll down 1 row so content stays visually stable
        g_saved_viewport_offset = ctxEngine(ctx).state.viewport_offset;
        if (ctxEngine(ctx).state.viewport_offset > 0) {
            ctxEngine(ctx).state.viewport_offset -= 1;
            c.g_viewport_offset = @intCast(ctxEngine(ctx).state.viewport_offset);
            g_viewport_compensated = true;
            c.attyx_mark_all_dirty();
        } else {
            g_viewport_compensated = false;
        }
    }

    // Sync match counts from processSearch results
    g_search_bar.total_matches = @intCast(@as(c_uint, @bitCast(c.g_search_total)));
    g_search_bar.current_match = @intCast(@as(c_uint, @bitCast(c.g_search_current)));

    const grid_cols: u16 = @intCast(ctxEngine(ctx).state.grid.cols);

    const result = overlay_search.layoutSearchBar(
        mgr.allocator,
        grid_cols,
        &g_search_bar,
        .{},
    ) catch return;

    // Place search bar below tab bar (if visible)
    const search_row: u16 = if (ctx.tab_mgr.count > 1) 1 else 0;
    mgr.setContent(.search_bar, 0, search_row, result.width, result.height, result.cells) catch {
        mgr.allocator.free(result.cells);
        return;
    };
    mgr.allocator.free(result.cells);

    if (!mgr.isVisible(.search_bar)) {
        mgr.show(.search_bar);
    }

    // Move the terminal cursor into the search bar input area so the
    // renderer draws it there (blink / shape / trail all work as normal).
    // input_start = 7 (" Find: "), then count display chars to cursor_pos.
    const input_start: u16 = 7;
    var cursor_char_col: u16 = 0;
    var bp: u16 = 0;
    const q = g_search_bar.query[0..g_search_bar.query_len];
    while (bp < g_search_bar.cursor_pos and bp < q.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(q[bp]) catch 1;
        bp += @intCast(cp_len);
        cursor_char_col += 1;
    }
    c.attyx_set_cursor(@intCast(search_row), @intCast(input_start + cursor_char_col));

    publishOverlays(ctx);
}

fn processSearch(state: *attyx.TerminalState) void {
    const active: i32 = @bitCast(c.g_search_active);
    if (active == 0) {
        if (g_search) |*s| {
            s.clear();
            c.g_search_total = 0;
            c.g_search_current = 0;
            c.g_search_vis_count = 0;
            c.g_search_cur_vis_row = -1;
        }
        return;
    }

    const s = &(g_search orelse return);

    // Detect query changes
    const gen: u32 = @bitCast(c.g_search_gen);
    const S = struct {
        var last_gen: u32 = 0;
    };
    if (gen != S.last_gen) {
        S.last_gen = gen;
        const qlen: usize = @intCast(@as(c_uint, @bitCast(c.g_search_query_len)));
        const clamped = @min(qlen, c.ATTYX_SEARCH_QUERY_MAX);
        var query_copy: [c.ATTYX_SEARCH_QUERY_MAX]u8 = undefined;
        for (0..clamped) |i| {
            query_copy[i] = c.g_search_query[i];
        }
        s.update(query_copy[0..clamped], &state.scrollback, &state.grid);
    }

    // Process navigation
    const nav: i32 = @atomicRmw(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_search_nav_delta))), .Xchg, 0, .seq_cst);
    if (nav > 0) {
        var i: i32 = 0;
        while (i < nav) : (i += 1) _ = s.next();
    } else if (nav < 0) {
        var i: i32 = 0;
        while (i < -nav) : (i += 1) _ = s.prev();
    }

    // Scroll viewport to current match
    if (nav != 0) {
        if (s.viewportForCurrent(state.scrollback.count, state.grid.rows)) |vp| {
            state.viewport_offset = vp;
            c.g_viewport_offset = @intCast(vp);
            c.attyx_mark_all_dirty();
        }
    }

    // Publish results for renderer
    c.g_search_total = @intCast(s.matchCount());
    c.g_search_current = @intCast(s.current);

    // Compute viewport window in absolute row coordinates
    const sb_count = state.scrollback.count;
    const grid_rows = state.grid.rows;
    const vp_offset = state.viewport_offset;
    const viewport_top = if (sb_count >= vp_offset) sb_count - vp_offset else 0;

    var vis_buf: [c.ATTYX_SEARCH_VIS_MAX]attyx.SearchMatch = undefined;
    const vis_count = s.visibleMatches(viewport_top, grid_rows, &vis_buf);
    c.g_search_vis_count = @intCast(vis_count);
    for (0..vis_count) |i| {
        const m = vis_buf[i];
        const viewport_row: i32 = @intCast(m.abs_row - viewport_top);
        c.g_search_vis[i] = .{
            .row = viewport_row,
            .col_start = @intCast(m.col_start),
            .col_end = @intCast(m.col_end),
        };
    }

    // Current match position in viewport coordinates
    if (s.currentMatch()) |cur| {
        if (cur.abs_row >= viewport_top and cur.abs_row < viewport_top + grid_rows) {
            c.g_search_cur_vis_row = @intCast(cur.abs_row - viewport_top);
            c.g_search_cur_vis_cs = @intCast(cur.col_start);
            c.g_search_cur_vis_ce = @intCast(cur.col_end);
        } else {
            c.g_search_cur_vis_row = -1;
        }
    } else {
        c.g_search_cur_vis_row = -1;
    }
}

fn ptyReaderThread(ctx: *PtyThreadCtx) void {
    const POLLIN: i16 = 0x0001;
    const POLLHUP: i16 = 0x0010;
    var buf: [65536]u8 = undefined;
    var last_published_vp: usize = 0;

    g_search = SearchState.init(ctxEngine(ctx).state.grid.allocator);
    defer {
        if (g_search) |*s| s.deinit();
        g_search = null;
    }

    // Start update checker if enabled
    if (ctx.check_updates) {
        logging.info("update", "starting update checker", .{});
        g_update_checker = .{ .allocator = ctx.allocator };
        if (g_update_checker) |*uc| uc.start();
    } else {
        logging.info("update", "update check disabled by config", .{});
    }
    defer {
        if (g_update_checker) |*uc| uc.tryJoin();
        g_update_checker = null;
    }

    while (c.attyx_should_quit() == 0) {
        // Config reload check (atomic read-and-reset)
        if (@atomicRmw(i32, &g_needs_reload_config, .Xchg, 0, .seq_cst) != 0) {
            doReloadConfig(ctx);
        }

        // Debug overlay toggle check
        if (@atomicRmw(i32, &g_toggle_debug_overlay, .Xchg, 0, .seq_cst) != 0) {
            if (ctx.overlay_mgr) |mgr| {
                mgr.toggle(.debug_card);
                generateDebugCard(ctx);
                publishOverlays(ctx);
            }
        }

        // Anchor demo toggle check
        if (@atomicRmw(i32, &g_toggle_anchor_demo, .Xchg, 0, .seq_cst) != 0) {
            if (ctx.overlay_mgr) |mgr| {
                if (mgr.isVisible(.anchor_demo)) {
                    g_anchor_mode_counter +%= 1;
                    if (g_anchor_mode_counter % 4 == 0) {
                        // Cycled through all modes — hide overlay
                        mgr.hide(.anchor_demo);
                    } else {
                        generateAnchorDemo(ctx);
                    }
                } else {
                    g_anchor_mode_counter = 0;
                    mgr.show(.anchor_demo);
                    generateAnchorDemo(ctx);
                }
                publishOverlays(ctx);
            }
        }

        // AI demo toggle check
        if (@atomicRmw(i32, &g_toggle_ai_demo, .Xchg, 0, .seq_cst) != 0) {
            if (ctx.overlay_mgr) |mgr| {
                if (mgr.isVisible(.ai_demo)) {
                    cancelAi(ctx);
                } else {
                    mgr.show(.ai_demo);
                    startAiInvocation(ctx);
                }
                publishOverlays(ctx);
            }
        }

        // Tick AI (auth/SSE state + streaming reveal)
        tickAi(ctx);

        // Tick update check notification
        tickUpdateCheck(ctx);

        // Overlay interaction: dismiss (Esc)
        if (@atomicRmw(i32, &g_overlay_dismiss, .Xchg, 0, .seq_cst) != 0) {
            if (ctx.overlay_mgr) |mgr| {
                const was_ai_visible = mgr.isVisible(.ai_demo);
                const was_ctx_visible = mgr.isVisible(.context_preview);
                if (mgr.dismissActive()) {
                    // Context preview dismissed → restore AI demo
                    if (was_ctx_visible and !mgr.isVisible(.context_preview)) {
                        mgr.show(.ai_demo);
                    }
                    // If AI demo was just dismissed, cancel all AI operations
                    if (was_ai_visible and !mgr.isVisible(.ai_demo)) {
                        cancelAi(ctx);
                    }
                    publishOverlays(ctx);
                }
            }
        }

        // Overlay interaction: cycle focus (Tab / Shift-Tab)
        if (@atomicRmw(i32, &g_overlay_cycle_focus, .Xchg, 0, .seq_cst) != 0) {
            if (ctx.overlay_mgr) |mgr| {
                if (mgr.cycleFocus()) {
                    mgr.repaintActiveActionBar();
                    generateDebugCard(ctx);
                    publishOverlays(ctx);
                }
            }
        }
        if (@atomicRmw(i32, &g_overlay_cycle_focus_rev, .Xchg, 0, .seq_cst) != 0) {
            if (ctx.overlay_mgr) |mgr| {
                if (mgr.cycleFocusReverse()) {
                    mgr.repaintActiveActionBar();
                    generateDebugCard(ctx);
                    publishOverlays(ctx);
                }
            }
        }

        // Overlay interaction: activate focused action (Enter)
        if (@atomicRmw(i32, &g_overlay_activate, .Xchg, 0, .seq_cst) != 0) {
            if (ctx.overlay_mgr) |mgr| {
                const was_ai_visible = mgr.isVisible(.ai_demo);
                const was_ctx_visible = mgr.isVisible(.context_preview);
                if (mgr.activateFocused()) |action_id| {
                    switch (action_id) {
                        .dismiss => {
                            _ = mgr.dismissActive();
                            if (was_ctx_visible and !mgr.isVisible(.context_preview)) {
                                mgr.show(.ai_demo);
                            }
                            if (was_ai_visible and !mgr.isVisible(.ai_demo)) {
                                cancelAi(ctx);
                            }
                        },
                        .context => toggleContextPreview(ctx),
                        .insert => handleInsertAction(ctx),
                        .copy => handleCopyAction(ctx),
                        .retry => handleRetryAction(ctx),
                        else => {},
                    }
                    publishOverlays(ctx);
                }
            }
        }

        // Overlay interaction: mouse click
        if (@atomicRmw(i32, &g_overlay_click_pending, .Xchg, 0, .seq_cst) != 0) {
            if (ctx.overlay_mgr) |mgr| {
                const click_col: u16 = @intCast(@max(0, @atomicLoad(i32, &g_overlay_click_col, .seq_cst)));
                const click_row: u16 = @intCast(@max(0, @atomicLoad(i32, &g_overlay_click_row, .seq_cst)));
                if (mgr.hitTest(click_col, click_row)) |hit| {
                    const was_ai_visible = mgr.isVisible(.ai_demo);
                    const was_ctx_visible = mgr.isVisible(.context_preview);
                    if (mgr.clickAction(hit)) |action_id| {
                        switch (action_id) {
                            .dismiss => {
                                _ = mgr.dismissActive();
                                if (was_ctx_visible and !mgr.isVisible(.context_preview)) {
                                    mgr.show(.ai_demo);
                                }
                                if (was_ai_visible and !mgr.isVisible(.ai_demo)) {
                                    cancelAi(ctx);
                                }
                            },
                            .context => toggleContextPreview(ctx),
                            .insert => handleInsertAction(ctx),
                            .copy => handleCopyAction(ctx),
                            .retry => handleRetryAction(ctx),
                            else => {},
                        }
                    }
                    publishOverlays(ctx);
                }
            }
        }

        // Overlay interaction: mouse scroll
        if (@atomicRmw(i32, &g_overlay_scroll_pending, .Xchg, 0, .seq_cst) != 0) {
            const delta = @atomicRmw(i32, &g_overlay_scroll_delta, .Xchg, 0, .seq_cst);
            if (g_streaming) |*so| {
                // Positive delta = scroll up (back), negative = scroll down (forward)
                const d: i16 = @intCast(std.math.clamp(delta, -100, 100));
                if (so.scroll(d)) {
                    publishAiStreamingFrame(ctx);
                }
            }
        }

        // Tab action handling
        processTabActions(ctx);

        // Split pane action handling
        processSplitActions(ctx);

        // Split pane drag resize
        processSplitDrag(ctx);

        // Split pane click focus
        if (@atomicRmw(i32, &g_split_click_pending, .Xchg, 0, .seq_cst) != 0) {
            const click_col: u16 = @intCast(@max(0, @atomicLoad(i32, &g_split_click_col, .seq_cst)));
            const click_row_raw = @atomicLoad(i32, &g_split_click_row, .seq_cst);
            // Subtract grid top offset (tab bar/search bar) to get pane-relative row
            const click_row: u16 = @intCast(@max(0, click_row_raw - g_grid_top_offset));
            const layout = ctx.tab_mgr.activeLayout();
            if (layout.paneAt(click_row, click_col)) |target_idx| {
                if (target_idx != layout.focused) {
                    layout.focused = target_idx;
                    switchActiveTab(ctx);
                }
            }
        }

        // Tab bar click handling
        {
            const click_idx = @atomicRmw(i32, &g_tab_click_index, .Xchg, -1, .seq_cst);
            if (click_idx >= 0 and click_idx < ctx.tab_mgr.count) {
                const idx: u8 = @intCast(click_idx);
                if (idx != ctx.tab_mgr.active) {
                    ctx.tab_mgr.switchTo(idx);
                    switchActiveTab(ctx);
                }
            }
        }

        // Popup toggle handling
        processPopupToggle(ctx);

        // Close dead popup on Ctrl-C from input thread
        if (@atomicRmw(i32, &g_popup_close_request, .Xchg, 0, .seq_cst) != 0) {
            closePopup(ctx);
        }

        // Check popup child exit
        if (ctx.popup_state) |ps| {
            if (!ps.child_exited and ps.pane.childExited()) {
                handlePopupExit(ctx, ps);
            }
        }

        // Check all tabs for child exit (handles split panes)
        {
            var ti: u8 = 0;
            while (ti < ctx.tab_mgr.count) {
                if (ctx.tab_mgr.tabs[ti]) |*lay| {
                    if (lay.findExitedPane()) |exited_idx| {
                        const result = lay.closePaneAt(exited_idx, ctx.allocator);
                        if (result == .last_pane) {
                            ctx.tab_mgr.closeTab(ti);
                            if (ctx.tab_mgr.count == 0) {
                                c.attyx_request_quit();
                                return;
                            }
                            updateGridTopOffset(ctx);
                            switchActiveTab(ctx);
                            continue; // don't increment; array shifted
                        } else {
                            // Pane closed within tab, relayout
                            const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - g_grid_top_offset));
                            lay.layout(pty_rows, ctx.grid_cols);
                            if (ti == ctx.tab_mgr.active) {
                                updateSplitActive(ctx);
                                switchActiveTab(ctx);
                            }
                            continue; // re-check same tab for more exits
                        }
                    }
                }
                ti += 1;
            }
        }

        {
            var rr: c_int = 0;
            var rc: c_int = 0;
            if (c.attyx_check_resize(&rr, &rc) != 0) {
                const nr: usize = @intCast(rr);
                const nc: usize = @intCast(rc);

                // Store full renderer grid dimensions
                ctx.grid_rows = @intCast(rr);
                ctx.grid_cols = @intCast(rc);

                // Recompute split gaps (cell dims may have changed after font rebuild)
                const gaps = computeSplitGaps();
                ctx.tab_mgr.updateGaps(gaps.h, gaps.v);

                // Resize panes to rows minus overlay offset (tab bar, search bar)
                const pty_rows: u16 = @intCast(@max(1, rr - g_grid_top_offset));
                ctx.tab_mgr.resizeAll(pty_rows, @intCast(rc));

                posix.nanosleep(0, 1_000_000);
                while (true) {
                    const n = ctxPty(ctx).read(&buf) catch break;
                    if (n == 0) break;
                    ctx.session.appendOutput(buf[0..n]);
                    ctx.tab_mgr.activePane().feed(buf[0..n]);
                }

                c.attyx_begin_cell_update();
                const resize_layout = ctx.tab_mgr.activeLayout();
                if (resize_layout.pane_count > 1) {
                    split_render.fillCellsSplit(
                        @ptrCast(ctx.cells),
                        resize_layout,
                        pty_rows,
                        @intCast(rc),
                        &ctx.active_theme,
                    );
                    const resize_rect = resize_layout.pool[resize_layout.focused].rect;
                    const vp_cur = @min(ctxEngine(ctx).state.viewport_offset, ctxEngine(ctx).state.scrollback.count);
                    c.attyx_set_cursor(
                        @intCast(ctxEngine(ctx).state.cursor.row + vp_cur + resize_rect.row + @as(usize, @intCast(g_grid_top_offset))),
                        @intCast(ctxEngine(ctx).state.cursor.col + resize_rect.col),
                    );
                    c.attyx_mark_all_dirty();
                } else {
                    const new_total = nr * nc;
                    fillCells(ctx.cells[0..new_total], ctxEngine(ctx), new_total, &ctx.active_theme);
                    const vp_cur = @min(ctxEngine(ctx).state.viewport_offset, ctxEngine(ctx).state.scrollback.count);
                    c.attyx_set_cursor(
                        @intCast(ctxEngine(ctx).state.cursor.row + vp_cur + @as(usize, @intCast(g_grid_top_offset))),
                        @intCast(ctxEngine(ctx).state.cursor.col),
                    );
                    c.attyx_set_dirty(&ctxEngine(ctx).state.dirty.bits);
                }
                ctxEngine(ctx).state.dirty.clear();
                c.attyx_set_grid_size(rc, rr);
                publishImagePlacements(ctx);
                if (ctx.overlay_mgr) |mgr| {
                    mgr.relayoutAnchored(viewportInfoFromCtx(ctx));
                    generateDebugCard(ctx);
                    generateAnchorDemo(ctx);
                    relayoutAiDemo(ctx);
                    relayoutContextPreview(ctx);
                }
                generateTabBar(ctx);
                publishOverlays(ctx);
                // Resize popup if active
                if (ctx.popup_state) |ps| {
                    const cfg = ctx.popup_configs[ps.config_index];
                    ps.resize(cfg, @intCast(nc), @intCast(nr));
                    ps.publishCells(&ctx.active_theme, cfg);
                    ps.publishImagePlacements(cfg);
                }
                c.attyx_end_cell_update();
                publishState(ctx);
                last_published_vp = ctxEngine(ctx).state.viewport_offset;
            }
        }

        // Build poll fd array — include all split pane PTYs + popup PTY
        const tab_max = @import("tab_manager.zig").max_tabs;
        const max_fds = tab_max * split_layout_mod.max_panes + 1;
        var fds: [max_fds]posix.pollfd = undefined;
        var fd_panes: [max_fds]*Pane = undefined;
        var fd_tab_idx: [max_fds]u8 = undefined;
        var nfds: usize = 0;

        // Add all tab PTYs (iterating split leaves per tab)
        for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count], 0..) |*maybe_layout, tab_i| {
            if (maybe_layout.*) |*lay| {
                var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
                const lc = lay.collectLeaves(&leaves);
                for (leaves[0..lc]) |leaf| {
                    fds[nfds] = .{ .fd = leaf.pane.pty.master, .events = POLLIN, .revents = 0 };
                    fd_panes[nfds] = leaf.pane;
                    fd_tab_idx[nfds] = @intCast(tab_i);
                    nfds += 1;
                }
            }
        }
        // Add popup PTY if active and child still running
        const popup_fd_idx = nfds;
        if (ctx.popup_state) |ps| {
            if (!ps.child_exited) {
                fds[nfds] = .{ .fd = ps.pane.pty.master, .events = POLLIN, .revents = 0 };
                fd_panes[nfds] = ps.pane;
                fd_tab_idx[nfds] = 0xFF;
                nfds += 1;
            }
        }

        _ = posix.poll(fds[0..nfds], 16) catch break;

        // Drain all tab PTYs. Only log session/throughput for the active tab's focused pane.
        // When splits are active, any pane in the active tab receiving data triggers refresh.
        var got_data = false;
        const active_focused_pane = ctx.tab_mgr.activePane();
        for (0..nfds) |i| {
            if (i == popup_fd_idx) continue; // popup handled separately
            if (fd_tab_idx[i] == 0xFF) continue;
            if (fds[i].revents & POLLIN != 0) {
                const p = fd_panes[i];
                while (true) {
                    const n = p.pty.read(&buf) catch break;
                    if (n == 0) break;
                    if (p == active_focused_pane) {
                        ctx.session.appendOutput(buf[0..n]);
                        ctx.throughput.add(n);
                    }
                    // Any pane in the active tab triggers got_data
                    if (fd_tab_idx[i] == ctx.tab_mgr.active) {
                        got_data = true;
                    }
                    p.feed(buf[0..n]);
                }
            }
        }

        // Drain popup PTY data if available
        var popup_got_data = false;
        if (ctx.popup_state) |ps| {
            if (popup_fd_idx < nfds and fds[popup_fd_idx].revents & POLLIN != 0) {
                while (true) {
                    const n = ps.pane.pty.read(&buf) catch break;
                    if (n == 0) break;
                    popup_got_data = true;
                    ps.feed(buf[0..n]);
                    // Forward OSC 7337 write-main payload to the main terminal PTY
                    if (ps.pane.engine.state.drainMainInject()) |inject| {
                        _ = ctxPty(ctx).writeToPty(inject) catch {};
                    }
                }
            }
            // Check popup child exit (POLLHUP)
            if (popup_fd_idx < nfds and fds[popup_fd_idx].revents & POLLHUP != 0) {
                if (!ps.child_exited) {
                    _ = ps.pane.childExited(); // reap child to capture exit status
                    handlePopupExit(ctx, ps);
                }
            } else if (popup_got_data) {
                const pcfg = ctx.popup_configs[ps.config_index];
                ps.publishCells(&ctx.active_theme, pcfg);
                ps.publishImagePlacements(pcfg);
            }
        }

        // Sync viewport offset from ObjC (scroll wheel may have changed
        // it) BEFORE deciding whether to re-fill cells.
        syncViewportFromC(&ctxEngine(ctx).state);

        const viewport_changed = (ctxEngine(ctx).state.viewport_offset != last_published_vp);
        const need_update = got_data or viewport_changed;

        // Consume search input from the grid-based search bar
        const search_input_changed = consumeSearchInput();

        // Process search even when no PTY data arrived (navigation / query changes)
        processSearch(&ctxEngine(ctx).state);

        // Update search bar overlay after processSearch has published match counts
        if (search_input_changed or got_data or @as(i32, @bitCast(c.g_search_active)) != 0) {
            generateSearchBar(ctx);
        }

        const search_vp_changed = (ctxEngine(ctx).state.viewport_offset != last_published_vp);
        const need_update_final = need_update or search_vp_changed;

        // DEC 2026 Synchronized Output: defer rendering while the app holds the
        // sync lock so we never present a partial frame.  A 100 ms safety timeout
        // forces a render even if ESC[?2026l is never received (hung or misbehaving app).
        if (ctxEngine(ctx).state.synchronized_output) {
            if (ctx.sync_start_ns == 0)
                ctx.sync_start_ns = std.time.nanoTimestamp();
            const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - ctx.sync_start_ns, std.time.ns_per_ms);
            if (elapsed_ms < 100) continue;
        } else {
            ctx.sync_start_ns = 0;
        }

        if (need_update_final) {
            c.attyx_begin_cell_update();
            const layout = ctx.tab_mgr.activeLayout();
            if (layout.pane_count > 1) {
                // Multi-pane: composite all panes + separators
                const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - g_grid_top_offset));
                split_render.fillCellsSplit(
                    @ptrCast(ctx.cells),
                    layout,
                    pty_rows,
                    ctx.grid_cols,
                    &ctx.active_theme,
                );
                // Cursor: offset by focused pane's rect origin
                const rect = layout.pool[layout.focused].rect;
                const eng = ctxEngine(ctx);
                const vp_cur = @min(eng.state.viewport_offset, eng.state.scrollback.count);
                c.attyx_set_cursor(
                    @intCast(eng.state.cursor.row + vp_cur + rect.row + @as(usize, @intCast(g_grid_top_offset))),
                    @intCast(eng.state.cursor.col + rect.col),
                );
                c.attyx_mark_all_dirty();
                g_force_full_redraw = false;
            } else {
                // Single pane: fast path (original)
                const total = ctxEngine(ctx).state.grid.rows * ctxEngine(ctx).state.grid.cols;
                fillCells(ctx.cells[0..total], ctxEngine(ctx), total, &ctx.active_theme);
                const vp_cur = @min(ctxEngine(ctx).state.viewport_offset, ctxEngine(ctx).state.scrollback.count);
                c.attyx_set_cursor(
                    @intCast(ctxEngine(ctx).state.cursor.row + vp_cur + @as(usize, @intCast(g_grid_top_offset))),
                    @intCast(ctxEngine(ctx).state.cursor.col),
                );
                if (viewport_changed or search_vp_changed or g_force_full_redraw) {
                    c.attyx_mark_all_dirty();
                    g_force_full_redraw = false;
                } else {
                    c.attyx_set_dirty(&ctxEngine(ctx).state.dirty.bits);
                }
            }
            ctxEngine(ctx).state.dirty.clear();
            publishImagePlacements(ctx);
            generateDebugCard(ctx);
            generateAnchorDemo(ctx);
            generateTabBar(ctx);
            publishOverlays(ctx);
            c.attyx_end_cell_update();
            publishState(ctx);
            last_published_vp = ctxEngine(ctx).state.viewport_offset;

            if (got_data) {
                const h = state_hash.hash(&ctxEngine(ctx).state);
                ctx.session.appendFrame(h, ctxEngine(ctx).state.alt_active);
            }
        }

        // Check active focused pane for POLLHUP (quick exit)
        {
            const focused = ctx.tab_mgr.activePane();
            for (0..nfds) |fi| {
                if (fi == popup_fd_idx) continue;
                if (fd_panes[fi] == focused and fds[fi].revents & POLLHUP != 0) {
                    if (focused.childExited()) {
                        const lay = ctx.tab_mgr.activeLayout();
                        if (lay.pane_count <= 1) {
                            ctx.tab_mgr.closeTab(ctx.tab_mgr.active);
                            if (ctx.tab_mgr.count == 0) {
                                c.attyx_request_quit();
                                break;
                            }
                            updateGridTopOffset(ctx);
                        } else {
                            const result = lay.closePane(ctx.allocator);
                            if (result == .last_pane) {
                                ctx.tab_mgr.closeTab(ctx.tab_mgr.active);
                                if (ctx.tab_mgr.count == 0) {
                                    c.attyx_request_quit();
                                    break;
                                }
                                updateGridTopOffset(ctx);
                            } else {
                                const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - g_grid_top_offset));
                                lay.layout(pty_rows, ctx.grid_cols);
                                updateSplitActive(ctx);
                            }
                        }
                        switchActiveTab(ctx);
                    }
                    break;
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tab lifecycle helpers (called from PTY thread)
// ---------------------------------------------------------------------------

fn processTabActions(ctx: *PtyThreadCtx) void {
    const action_raw = @atomicRmw(i32, &g_tab_action_request, .Xchg, 0, .seq_cst);
    if (action_raw == 0) return;

    const Action = keybinds_mod.Action;
    const action: Action = @enumFromInt(@as(u8, @intCast(action_raw)));

    switch (action) {
        .tab_new => {
            const eng = ctxEngine(ctx);
            const rows: u16 = @intCast(eng.state.grid.rows);
            const cols: u16 = @intCast(eng.state.grid.cols);
            const fg_cwd = platform.getForegroundCwd(ctx.allocator, ctxPty(ctx).master);
            defer if (fg_cwd) |cwd| ctx.allocator.free(cwd);
            const cwd_z: ?[:0]u8 = if (fg_cwd) |d| ctx.allocator.dupeZ(u8, d) catch null else null;
            defer if (cwd_z) |z| ctx.allocator.free(z);
            ctx.tab_mgr.addTab(rows, cols, if (cwd_z) |z| z.ptr else null) catch |err| {
                logging.err("tabs", "addTab failed: {}", .{err});
                return;
            };
            updateGridTopOffset(ctx);
            switchActiveTab(ctx);
            logging.info("tabs", "new tab {d}/{d}", .{ ctx.tab_mgr.active + 1, ctx.tab_mgr.count });
        },
        .tab_close => {
            if (ctx.tab_mgr.count <= 1) {
                // Last tab — close window
                c.attyx_request_quit();
                return;
            }
            ctx.tab_mgr.closeTab(ctx.tab_mgr.active);
            updateGridTopOffset(ctx);
            switchActiveTab(ctx);
            logging.info("tabs", "closed tab, now {d}", .{ctx.tab_mgr.count});
        },
        .tab_next => {
            if (ctx.tab_mgr.count <= 1) return;
            ctx.tab_mgr.nextTab();
            switchActiveTab(ctx);
            logging.info("tabs", "switched to tab {d}", .{ctx.tab_mgr.active + 1});
        },
        .tab_prev => {
            if (ctx.tab_mgr.count <= 1) return;
            ctx.tab_mgr.prevTab();
            switchActiveTab(ctx);
            logging.info("tabs", "switched to tab {d}", .{ctx.tab_mgr.active + 1});
        },
        else => {},
    }
}

fn processSplitActions(ctx: *PtyThreadCtx) void {
    const action_raw = @atomicRmw(i32, &g_split_action_request, .Xchg, 0, .seq_cst);
    if (action_raw == 0) return;

    const Action = keybinds_mod.Action;
    const action: Action = @enumFromInt(@as(u8, @intCast(action_raw)));
    const layout = ctx.tab_mgr.activeLayout();

    switch (action) {
        .split_vertical => {
            layout.splitPane(.vertical, ctx.allocator, ctxPty(ctx).master) catch |err| {
                logging.err("split", "splitPane(vertical) failed: {}", .{err});
                return;
            };
            const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - g_grid_top_offset));
            layout.layout(pty_rows, ctx.grid_cols);
            updateSplitActive(ctx);
            switchActiveTab(ctx);
            logging.info("split", "vertical split, {d} panes", .{layout.pane_count});
        },
        .split_horizontal => {
            layout.splitPane(.horizontal, ctx.allocator, ctxPty(ctx).master) catch |err| {
                logging.err("split", "splitPane(horizontal) failed: {}", .{err});
                return;
            };
            const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - g_grid_top_offset));
            layout.layout(pty_rows, ctx.grid_cols);
            updateSplitActive(ctx);
            switchActiveTab(ctx);
            logging.info("split", "horizontal split, {d} panes", .{layout.pane_count});
        },
        .pane_close => {
            const result = layout.closePane(ctx.allocator);
            if (result == .last_pane) {
                // Last pane in tab — close the tab
                if (ctx.tab_mgr.count <= 1) {
                    c.attyx_request_quit();
                    return;
                }
                ctx.tab_mgr.closeTab(ctx.tab_mgr.active);
                updateGridTopOffset(ctx);
            } else {
                const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - g_grid_top_offset));
                layout.layout(pty_rows, ctx.grid_cols);
                updateSplitActive(ctx);
            }
            switchActiveTab(ctx);
            logging.info("split", "pane closed", .{});
        },
        .pane_focus_up => {
            layout.navigate(.up);
            switchActiveTab(ctx);
        },
        .pane_focus_down => {
            layout.navigate(.down);
            switchActiveTab(ctx);
        },
        .pane_focus_left => {
            layout.navigate(.left);
            switchActiveTab(ctx);
        },
        .pane_focus_right => {
            layout.navigate(.right);
            switchActiveTab(ctx);
        },
        .pane_resize_left, .pane_resize_right => {
            const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - g_grid_top_offset));
            if (layout.findResizeTarget(.vertical)) |target| {
                const delta: f32 = if (action == .pane_resize_left) -0.05 else 0.05;
                if (layout.resizeNode(target, delta, pty_rows, ctx.grid_cols)) {
                    switchActiveTab(ctx);
                }
            }
        },
        .pane_resize_up, .pane_resize_down => {
            const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - g_grid_top_offset));
            if (layout.findResizeTarget(.horizontal)) |target| {
                const delta: f32 = if (action == .pane_resize_up) -0.05 else 0.05;
                if (layout.resizeNode(target, delta, pty_rows, ctx.grid_cols)) {
                    switchActiveTab(ctx);
                }
            }
        },
        else => {},
    }
}

fn processSplitDrag(ctx: *PtyThreadCtx) void {
    const layout = ctx.tab_mgr.activeLayout();
    const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - g_grid_top_offset));

    // Handle drag start
    if (@atomicRmw(i32, &g_split_drag_start_pending, .Xchg, 0, .seq_cst) != 0) {
        const col: u16 = @intCast(@max(0, @atomicLoad(i32, &g_split_drag_start_col, .seq_cst)));
        const row_raw = @atomicLoad(i32, &g_split_drag_start_row, .seq_cst);
        const row: u16 = @intCast(@max(0, row_raw - g_grid_top_offset));
        if (layout.separatorAt(row, col)) |branch_idx| {
            g_split_drag_branch = branch_idx;
            @atomicStore(i32, &g_split_drag_active, 1, .seq_cst);
            @atomicStore(i32, &g_split_drag_direction, switch (layout.pool[branch_idx].direction) {
                .vertical => @as(i32, 0),
                .horizontal => @as(i32, 1),
            }, .seq_cst);
        }
    }

    // Handle drag update
    if (@atomicRmw(i32, &g_split_drag_cur_pending, .Xchg, 0, .seq_cst) != 0) {
        const branch_idx = g_split_drag_branch;
        if (branch_idx != 0xFF and layout.pool[branch_idx].tag == .branch) {
            const col: u16 = @intCast(@max(0, @atomicLoad(i32, &g_split_drag_cur_col, .seq_cst)));
            const row_raw = @atomicLoad(i32, &g_split_drag_cur_row, .seq_cst);
            const row: u16 = @intCast(@max(0, row_raw - g_grid_top_offset));
            const rect = layout.pool[branch_idx].rect;

            const new_ratio: f32 = switch (layout.pool[branch_idx].direction) {
                .vertical => blk: {
                    const available = rect.cols -| layout.gap_h;
                    if (available == 0) break :blk @as(f32, 0.5);
                    const offset: f32 = @floatFromInt(@as(i32, col) - @as(i32, rect.col));
                    break :blk @max(0.05, @min(0.95, offset / @as(f32, @floatFromInt(available))));
                },
                .horizontal => blk: {
                    const available = rect.rows -| layout.gap_v;
                    if (available == 0) break :blk @as(f32, 0.5);
                    const offset: f32 = @floatFromInt(@as(i32, row) - @as(i32, rect.row));
                    break :blk @max(0.05, @min(0.95, offset / @as(f32, @floatFromInt(available))));
                },
            };

            layout.pool[branch_idx].ratio = new_ratio;
            layout.layout(pty_rows, ctx.grid_cols);
            switchActiveTab(ctx);
        }
    }

    // Handle drag end
    if (@atomicRmw(i32, &g_split_drag_end_pending, .Xchg, 0, .seq_cst) != 0) {
        g_split_drag_branch = 0xFF;
        @atomicStore(i32, &g_split_drag_active, 0, .seq_cst);
    }
}

/// Compute split gap sizes from window padding and cell dimensions.
fn computeSplitGaps() struct { h: u16, v: u16 } {
    const cell_w: f32 = c.g_cell_w_pts;
    const cell_h: f32 = c.g_cell_h_pts;
    if (cell_w <= 0 or cell_h <= 0) return .{ .h = 1, .v = 1 };
    const pad_h: f32 = @floatFromInt(c.g_padding_left + c.g_padding_right);
    const pad_v: f32 = @floatFromInt(c.g_padding_top + c.g_padding_bottom);
    return .{
        .h = @max(1, @as(u16, @intFromFloat(@round(pad_h / cell_w)))),
        .v = @max(1, @as(u16, @intFromFloat(@round(pad_v / cell_h)))),
    };
}

/// Update g_split_active flag based on active tab's pane count.
fn updateSplitActive(ctx: *PtyThreadCtx) void {
    const layout = ctx.tab_mgr.activeLayout();
    @atomicStore(i32, &g_split_active, if (layout.pane_count > 1) @as(i32, 1) else @as(i32, 0), .seq_cst);
}

/// Update global routing pointers and refresh the cell buffer after a tab switch.
fn switchActiveTab(ctx: *PtyThreadCtx) void {
    const pane = ctx.tab_mgr.activePane();
    g_pty_master = pane.pty.master;
    g_engine = &pane.engine;
    updateSplitActive(ctx);

    c.attyx_begin_cell_update();
    const layout = ctx.tab_mgr.activeLayout();
    if (layout.pane_count > 1) {
        const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - g_grid_top_offset));
        split_render.fillCellsSplit(
            @ptrCast(ctx.cells),
            layout,
            pty_rows,
            ctx.grid_cols,
            &ctx.active_theme,
        );
        const rect = layout.pool[layout.focused].rect;
        const eng = &pane.engine;
        const vp_cur = @min(eng.state.viewport_offset, eng.state.scrollback.count);
        c.attyx_set_cursor(
            @intCast(eng.state.cursor.row + vp_cur + rect.row + @as(usize, @intCast(g_grid_top_offset))),
            @intCast(eng.state.cursor.col + rect.col),
        );
        c.attyx_mark_all_dirty();
    } else {
        // Clear the full renderer buffer first to remove any leftover
        // content from a previously-active split tab.
        const buf_total: usize = @as(usize, ctx.grid_rows) * @as(usize, ctx.grid_cols);
        const bg = ctx.active_theme.background;
        for (0..buf_total) |i| {
            ctx.cells[i] = .{
                .character = ' ',
                .combining = .{ 0, 0 },
                .fg_r = bg.r,
                .fg_g = bg.g,
                .fg_b = bg.b,
                .bg_r = bg.r,
                .bg_g = bg.g,
                .bg_b = bg.b,
                .flags = 4,
                .link_id = 0,
            };
        }
        const eng = &pane.engine;
        const total = eng.state.grid.rows * eng.state.grid.cols;
        fillCells(ctx.cells[0..total], eng, total, &ctx.active_theme);
        const vp_cur = @min(eng.state.viewport_offset, eng.state.scrollback.count);
        c.attyx_set_cursor(
            @intCast(eng.state.cursor.row + vp_cur + @as(usize, @intCast(g_grid_top_offset))),
            @intCast(eng.state.cursor.col),
        );
        c.attyx_mark_all_dirty();
        eng.state.dirty.clear();
    }
    publishImagePlacements(ctx);
    publishState(ctx);
    generateTabBar(ctx);
    publishOverlays(ctx);
    c.attyx_end_cell_update();
    c.attyx_mark_all_dirty();
    // Force the next main-loop render to use mark_all_dirty.  This guards
    // against a torn-read race: if the renderer cleared our dirty bits but
    // then discarded the frame (gen changed), the subsequent main-loop render
    // must re-mark everything dirty so no stale rows survive in the snapshot.
    g_force_full_redraw = true;
}

/// Centralized calculation of g_grid_top_offset accounting for tab bar and search bar.
/// When the offset changes, resizes all panes to account for rows consumed by overlays.
fn updateGridTopOffset(ctx: *PtyThreadCtx) void {
    const old_offset = g_grid_top_offset;
    var offset: i32 = 0;
    if (ctx.tab_mgr.count > 1) offset += 1; // tab bar
    if (@as(i32, @bitCast(c.g_search_active)) != 0) offset += 1; // search bar
    g_grid_top_offset = offset;
    @atomicStore(i32, &g_tab_count, @as(i32, ctx.tab_mgr.count), .seq_cst);
    g_tab_bar_visible = if (ctx.tab_mgr.count > 1) @as(i32, 1) else @as(i32, 0);

    // Resize panes when offset changes (rows consumed by overlays changed)
    if (offset != old_offset and ctx.grid_rows > 0) {
        const pty_rows = @as(u16, @intCast(@max(1, @as(i32, ctx.grid_rows) - offset)));
        ctx.tab_mgr.resizeAll(pty_rows, ctx.grid_cols);
    }
}

/// Generate the tab bar overlay (only visible when count > 1).
fn generateTabBar(ctx: *PtyThreadCtx) void {
    const mgr = ctx.overlay_mgr orelse return;

    if (ctx.tab_mgr.count <= 1) {
        if (mgr.isVisible(.tab_bar)) {
            mgr.hide(.tab_bar);
        }
        return;
    }

    var tab_cells: [512]overlay_mod.OverlayCell = undefined;
    const result = tab_bar_mod.generate(
        &tab_cells,
        ctx.tab_mgr.count,
        ctx.tab_mgr.active,
        ctx.grid_cols,
        .{},
    ) orelse return;

    mgr.setContent(.tab_bar, 0, 0, result.width, result.height, result.cells) catch return;
    if (!mgr.isVisible(.tab_bar)) {
        mgr.show(.tab_bar);
    }
}

// ---------------------------------------------------------------------------
// Popup lifecycle helpers (called from PTY thread)
// ---------------------------------------------------------------------------

fn processPopupToggle(ctx: *PtyThreadCtx) void {
    for (0..ctx.popup_config_count) |i| {
        if (@atomicRmw(i32, &g_popup_toggle_request[i], .Xchg, 0, .seq_cst) != 0) {
            logging.info("popup", "processing toggle for index {d}", .{i});
            if (ctx.popup_state) |ps| {
                // If same popup → close; if different → close then open new
                const same = (ps.config_index == i);
                closePopup(ctx);
                if (same) return;
            }
            // Open popup i
            const cfg = ctx.popup_configs[i];
            logging.info("popup", "spawning: cmd={s} w={d}% h={d}%", .{ cfg.command, cfg.width_pct, cfg.height_pct });
            const grid_cols: u16 = @intCast(ctxEngine(ctx).state.grid.cols);
            const grid_rows: u16 = @intCast(ctxEngine(ctx).state.grid.rows);
            const fg_cwd = platform.getForegroundCwd(ctx.allocator, ctxPty(ctx).master);
            defer if (fg_cwd) |cwd| ctx.allocator.free(cwd);
            var ps = ctx.allocator.create(popup_mod.PopupState) catch return;
            ps.* = popup_mod.PopupState.spawn(ctx.allocator, cfg, grid_cols, grid_rows, fg_cwd) catch |err| {
                logging.err("popup", "spawn failed: {}", .{err});
                ctx.allocator.destroy(ps);
                return;
            };
            ps.config_index = @intCast(i);
            ctx.popup_state = ps;
            g_popup_pty_master = ps.pane.pty.master;
            g_popup_engine = &ps.pane.engine;
            @atomicStore(i32, @as(*i32, @ptrCast(@volatileCast(&c.g_popup_active))), 1, .seq_cst);
            ps.publishCells(&ctx.active_theme, cfg);
            ps.publishImagePlacements(cfg);
            return; // handle one toggle per tick
        }
    }
}

fn closePopup(ctx: *PtyThreadCtx) void {
    const ps = ctx.popup_state orelse return;
    g_popup_pty_master = -1;
    g_popup_engine = null;
    @atomicStore(i32, &g_popup_dead, 0, .seq_cst);
    ps.deinit();
    ctx.allocator.destroy(ps);
    ctx.popup_state = null;
    popup_mod.clearBridgeState();
}

/// Handle popup child exit: close immediately on success, keep visible on error.
fn handlePopupExit(ctx: *PtyThreadCtx, ps: *popup_mod.PopupState) void {
    // Block until child fully exits — POLLHUP can arrive before waitpid(WNOHANG) sees it
    ps.pane.pty.waitForExit();
    const code = ps.pane.pty.exitCode() orelse 1;

    // Drain any remaining data from the PTY buffer.
    var drain_buf: [4096]u8 = undefined;
    while (true) {
        const n = ps.pane.pty.read(&drain_buf) catch break;
        if (n == 0) break;
        ps.feed(drain_buf[0..n]);
        // Forward any pending OSC 7337 inject
        if (ps.pane.engine.state.drainMainInject()) |inject| {
            _ = ctxPty(ctx).writeToPty(inject) catch {};
        }
    }

    logging.info("popup", "exit code={d} stdout_fd={d} alt_active={}", .{
        code, ps.pane.pty.stdout_read_fd, ctxEngine(ctx).state.alt_active,
    });
    if (code == 0) {
        // On success: run on_return_cmd with captured stdout if configured
        const pcfg = ctx.popup_configs[ps.config_index];
        if (pcfg.on_return_cmd) |cmd| {
            const captured = popup_mod.readCapturedStdout(ctx.allocator, ps.pane.pty.stdout_read_fd);
            if (captured) |text| {
                logging.info("popup", "on_return_cmd: cmd=\"{s}\" value=\"{s}\" alt={}", .{
                    cmd, text, ctxEngine(ctx).state.alt_active,
                });
                defer ctx.allocator.free(text);
                // Skip injection when alt screen is active (a TUI would
                // swallow the text) unless inject_alt is set in the popup
                // config — multiplexers like tmux/sesh forward PTY input
                // to the active pane, so injection works there.
                if (ctxEngine(ctx).state.alt_active and !pcfg.inject_alt) {
                    // Alt screen with inject_alt off — run as detached
                    // subprocess so we don't send text into a TUI.
                    popup_mod.execDetached(ctx.allocator, cmd, text);
                } else {
                    _ = ctxPty(ctx).writeToPty(cmd) catch {};
                    _ = ctxPty(ctx).writeToPty(" ") catch {};
                    _ = ctxPty(ctx).writeToPty(text) catch {};
                    _ = ctxPty(ctx).writeToPty("\n") catch {};
                }
            } else {
                logging.info("popup", "on_return_cmd: no captured stdout", .{});
            }
        }
        closePopup(ctx);
        return;
    }
    // Non-zero exit: keep popup visible so the user can read the error output.
    ps.child_exited = true;
    g_popup_pty_master = -1;
    g_popup_engine = null;
    @atomicStore(i32, &g_popup_dead, 1, .seq_cst);
    // Publish final cell state
    const pcfg = ctx.popup_configs[ps.config_index];
    ps.publishCells(&ctx.active_theme, pcfg);
    ps.publishImagePlacements(pcfg);
    logging.info("popup", "command exited with code {d}, keeping popup open (Ctrl-C to close)", .{code});
}

fn doReloadConfig(ctx: *PtyThreadCtx) void {
    var new_cfg = reload.loadReloadedConfig(
        ctx.allocator,
        ctx.no_config,
        ctx.config_path,
        ctx.args,
    ) catch |err| {
        logging.err("config", "reload failed: {}", .{err});
        return;
    };
    defer new_cfg.deinit();

    // Cursor (hot)
    if (new_cfg.cursor_shape != ctx.applied_cursor_shape or
        new_cfg.cursor_blink != ctx.applied_cursor_blink)
    {
        ctxEngine(ctx).state.cursor_shape = cursorShapeFromConfig(new_cfg.cursor_shape, new_cfg.cursor_blink);
        ctx.applied_cursor_shape = new_cfg.cursor_shape;
        ctx.applied_cursor_blink = new_cfg.cursor_blink;
    }
    if (new_cfg.cursor_trail != ctx.applied_cursor_trail) {
        c.g_cursor_trail = @intFromBool(new_cfg.cursor_trail);
        ctx.applied_cursor_trail = new_cfg.cursor_trail;
    }

    // Scrollback — fully hot-reloadable via reallocate()
    if (new_cfg.scrollback_lines != ctx.applied_scrollback_lines) {
        ctxEngine(ctx).state.scrollback.reallocate(new_cfg.scrollback_lines) catch |err| {
            logging.err("config", "scrollback resize failed: {}", .{err});
        };
        ctx.applied_scrollback_lines = @intCast(ctxEngine(ctx).state.scrollback.max_lines);
        // Clamp viewport offset if scrollback shrunk
        if (ctxEngine(ctx).state.viewport_offset > ctxEngine(ctx).state.scrollback.count) {
            ctxEngine(ctx).state.viewport_offset = ctxEngine(ctx).state.scrollback.count;
            c.g_viewport_offset = @intCast(ctxEngine(ctx).state.viewport_offset);
        }
        c.g_scrollback_count = @intCast(ctxEngine(ctx).state.scrollback.count);
    }

    // Font — write new params to bridge globals; main thread rebuilds
    const current_font_size: u16 = @intCast(c.g_font_size);
    const current_family_len: usize = @intCast(c.g_font_family_len);
    const current_family = c.g_font_family[0..current_family_len];
    const font_changed = new_cfg.font_size != current_font_size or
        !std.mem.eql(u8, new_cfg.font_family, current_family) or
        new_cfg.cell_width.encode() != c.g_cell_width or
        new_cfg.cell_height.encode() != c.g_cell_height;
    if (font_changed) {
        publishFontConfig(&new_cfg);
        c.g_needs_font_rebuild = 1;
    }

    // Theme — re-resolve and republish
    ctx.active_theme = ctx.theme_registry.resolve(new_cfg.theme_name);
    if (new_cfg.theme_background) |bg| ctx.active_theme.background = bg;
    publishTheme(&ctx.active_theme);

    // Window properties — update bridge globals, signal render thread
    {
        var needs_window_update = false;

        // Background opacity
        if (new_cfg.background_opacity != c.g_background_opacity) {
            c.g_background_opacity = new_cfg.background_opacity;
            needs_window_update = true;
        }

        // Background blur
        const new_blur: i32 = @intCast(new_cfg.background_blur);
        if (new_blur != c.g_background_blur) {
            c.g_background_blur = new_blur;
            needs_window_update = true;
        }

        // Window decorations
        const new_deco: i32 = if (new_cfg.window_decorations) 1 else 0;
        if (new_deco != c.g_window_decorations) {
            c.g_window_decorations = new_deco;
            needs_window_update = true;
        }

        // Window padding
        const new_pl: i32 = @intCast(new_cfg.window_padding_left);
        const new_pr: i32 = @intCast(new_cfg.window_padding_right);
        const new_pt: i32 = @intCast(new_cfg.window_padding_top);
        const new_pb: i32 = @intCast(new_cfg.window_padding_bottom);
        if (new_pl != c.g_padding_left or new_pr != c.g_padding_right or
            new_pt != c.g_padding_top or new_pb != c.g_padding_bottom)
        {
            c.g_padding_left = new_pl;
            c.g_padding_right = new_pr;
            c.g_padding_top = new_pt;
            c.g_padding_bottom = new_pb;
            needs_window_update = true;
        }

        if (needs_window_update) {
            c.g_needs_window_update = 1;
            // Recompute split gaps when padding changes
            const gaps = computeSplitGaps();
            ctx.tab_mgr.updateGaps(gaps.h, gaps.v);
        }
    }

    // Reflow
    if (new_cfg.reflow_enabled != ctxEngine(ctx).state.reflow_on_resize) {
        ctxEngine(ctx).state.reflow_on_resize = new_cfg.reflow_enabled;
    }

    // Keybindings — always rebuild (cheap, no diff needed)
    {
        var ph: [4]keybinds_mod.PopupHotkey = undefined;
        var ph_count: u8 = 0;
        if (new_cfg.popup_configs) |entries| {
            for (entries) |entry| {
                if (ph_count >= 4) break;
                ph[ph_count] = .{ .index = ph_count, .hotkey = entry.hotkey };
                ph_count += 1;
            }
        }
        const new_table = keybinds_mod.buildTable(
            new_cfg.keybind_overrides,
            new_cfg.sequence_entries,
            ph[0..ph_count],
        );
        keybinds_mod.installTable(&new_table);
        logging.info("keybinds", "reloaded {d} keybind(s)", .{new_table.count});
    }

    c.attyx_mark_all_dirty();
    logging.info("config", "reloaded", .{});
}

/// Publish active theme colors to the C bridge globals.
fn publishTheme(theme: *const Theme) void {
    if (theme.cursor) |cur| {
        c.g_theme_cursor_r = @intCast(cur.r);
        c.g_theme_cursor_g = @intCast(cur.g);
        c.g_theme_cursor_b = @intCast(cur.b);
    } else {
        c.g_theme_cursor_r = -1;
    }
    if (theme.selection_background) |sel| {
        c.g_theme_sel_bg_set = 1;
        c.g_theme_sel_bg_r = @intCast(sel.r);
        c.g_theme_sel_bg_g = @intCast(sel.g);
        c.g_theme_sel_bg_b = @intCast(sel.b);
    } else {
        c.g_theme_sel_bg_set = 0;
    }
    if (theme.selection_foreground) |sel| {
        c.g_theme_sel_fg_set = 1;
        c.g_theme_sel_fg_r = @intCast(sel.r);
        c.g_theme_sel_fg_g = @intCast(sel.g);
        c.g_theme_sel_fg_b = @intCast(sel.b);
    } else {
        c.g_theme_sel_fg_set = 0;
    }
}

/// Resolve a cell color using the active theme for default fg/bg and ANSI palette.
fn resolveWithTheme(color: anytype, is_bg: bool, theme: *const Theme) color_mod.Rgb {
    switch (color) {
        .default => {
            const src = if (is_bg) theme.background else theme.foreground;
            return .{ .r = src.r, .g = src.g, .b = src.b };
        },
        .ansi => |n| {
            if (theme.palette[n]) |p| return .{ .r = p.r, .g = p.g, .b = p.b };
            return color_mod.resolve(color, is_bg);
        },
        else => return color_mod.resolve(color, is_bg),
    }
}

fn cellToAttyxCell(cell: attyx.Cell, theme: *const Theme) c.AttyxCell {
    // Kitty Unicode placeholder: suppress all visual attributes.
    // The fg color encodes image_id and must not be rendered.
    if (cell.char == 0x10EEEE) {
        // Emit a space with the cell's actual bg (not fg!) and default-bg opacity flag.
        const eff_bg = if (cell.style.reverse) cell.style.fg else cell.style.bg;
        const bg = resolveWithTheme(eff_bg, !cell.style.reverse, theme);
        return .{
            .character = ' ',
            .fg_r = 0,
            .fg_g = 0,
            .fg_b = 0,
            .bg_r = bg.r,
            .bg_g = bg.g,
            .bg_b = bg.b,
            .flags = if (!cell.style.reverse and eff_bg == .default) @as(u8, 4) else @as(u8, 0),
            .link_id = 0,
        };
    }

    // Swap fg/bg when reverse video is active.
    // Also flip the is_bg hint so .default resolves to the opposite theme color.
    const eff_fg = if (cell.style.reverse) cell.style.bg else cell.style.fg;
    const eff_bg = if (cell.style.reverse) cell.style.fg else cell.style.bg;
    const fg = resolveWithTheme(eff_fg, cell.style.reverse, theme);
    const bg = resolveWithTheme(eff_bg, !cell.style.reverse, theme);
    // Dim: halve foreground brightness
    const fg_r = if (cell.style.dim) fg.r / 2 else fg.r;
    const fg_g = if (cell.style.dim) fg.g / 2 else fg.g;
    const fg_b = if (cell.style.dim) fg.b / 2 else fg.b;
    return .{
        .character = cell.char,
        .combining = .{ cell.combining[0], cell.combining[1] },
        .fg_r = fg_r,
        .fg_g = fg_g,
        .fg_b = fg_b,
        .bg_r = bg.r,
        .bg_g = bg.g,
        .bg_b = bg.b,
        .flags = @as(u8, if (cell.style.bold) 1 else 0) |
            @as(u8, if (cell.style.underline) 2 else 0) |
            @as(u8, if (!cell.style.reverse and eff_bg == .default) @as(u8, 4) else @as(u8, 0)) |
            @as(u8, if (cell.style.dim) 8 else 0) |
            @as(u8, if (cell.style.italic) 16 else 0) |
            @as(u8, if (cell.style.strikethrough) 32 else 0),
        .link_id = cell.link_id,
    };
}

fn fillCells(cells: []c.AttyxCell, eng: *Engine, _: usize, theme: *const Theme) void {
    const vp = eng.state.viewport_offset;
    const cols = eng.state.grid.cols;
    const rows = eng.state.grid.rows;
    const sb = &eng.state.scrollback;
    const wrapped: *volatile [c.ATTYX_MAX_ROWS]u8 = @ptrCast(&c.g_row_wrapped);

    if (vp == 0) {
        const total = rows * cols;
        for (0..total) |i| {
            cells[i] = cellToAttyxCell(eng.state.grid.cells[i], theme);
        }
        for (0..rows) |row| {
            wrapped[row] = @intFromBool(eng.state.grid.row_wrapped[row]);
        }
        return;
    }

    const effective_vp = @min(vp, sb.count);
    for (0..rows) |row| {
        if (row < effective_vp) {
            const sb_line_idx = sb.count - effective_vp + row;
            const sb_cells = sb.getLine(sb_line_idx);
            for (0..cols) |col| {
                cells[row * cols + col] = cellToAttyxCell(sb_cells[col], theme);
            }
            wrapped[row] = @intFromBool(sb.getLineWrapped(sb_line_idx));
        } else {
            const grid_row = row - effective_vp;
            for (0..cols) |col| {
                cells[row * cols + col] = cellToAttyxCell(eng.state.grid.cells[grid_row * cols + col], theme);
            }
            wrapped[row] = @intFromBool(eng.state.grid.row_wrapped[grid_row]);
        }
    }
}
