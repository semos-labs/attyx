const std = @import("std");
const posix = std.posix;
const attyx = @import("attyx");
const AppConfig = @import("../config/config.zig").AppConfig;
const CursorShapeConfig = @import("../config/config.zig").CursorShapeConfig;
const logging = @import("../logging/log.zig");

const config_mod = @import("../config/config.zig");
const theme_registry_mod = @import("../theme/registry.zig");
const ThemeRegistry = theme_registry_mod.ThemeRegistry;
pub const Theme = theme_registry_mod.Theme;

const overlay_mod = attyx.overlay_mod;
const OverlayManager = overlay_mod.OverlayManager;
const popup_mod = @import("popup.zig");
const keybinds_mod = @import("../config/keybinds.zig");
const TabManager = @import("tab_manager.zig").TabManager;
const Pane = @import("pane.zig").Pane;
const Pty = @import("pty.zig").Pty;
const layout_codec = @import("layout_codec.zig");
const SessionLog = @import("session_log.zig").SessionLog;
const SessionClient = @import("session_client.zig").SessionClient;
const conn = @import("session_connect.zig");
const split_layout_mod = @import("split_layout.zig");
const diag = @import("../logging/diag.zig");
const platform = @import("../platform/platform.zig");
const statusbar_mod = @import("statusbar.zig");
pub const Statusbar = statusbar_mod.Statusbar;
const ipc_server = @import("../ipc/server.zig");

pub const c = @cImport({
    @cInclude("bridge.h");
});

// Sub-modules
const publish = @import("ui/publish.zig");
const input = @import("ui/input.zig");
const search = @import("ui/search.zig");
const ai = @import("ui/ai.zig");
const event_loop = @import("ui/event_loop.zig");
const dispatch = @import("ui/dispatch.zig");
const copy_mode = @import("ui/copy_mode.zig");
const selection = @import("ui/selection.zig");

const MAX_CELLS = c.ATTYX_MAX_ROWS * c.ATTYX_MAX_COLS;

pub const PtyThreadCtx = struct {
    tab_mgr: *TabManager,
    cells: [*]c.AttyxCell,
    session: *SessionLog,
    allocator: std.mem.Allocator,
    no_config: bool,
    config_path: ?[]const u8,
    args: []const [:0]const u8,
    applied_cursor_shape: CursorShapeConfig,
    applied_cursor_blink: bool,
    applied_cursor_trail: bool,
    applied_font_ligatures: bool,
    applied_scrollback_lines: u32,
    theme_registry: *ThemeRegistry,
    active_theme: Theme,
    throughput: diag.ThroughputWindow = .{},
    sync_start_ns: i128 = 0,
    overlay_mgr: ?*OverlayManager = null,
    popup_state: ?*popup_mod.PopupState = null,
    popup_configs: [32]popup_mod.PopupConfig = undefined,
    popup_config_count: u8 = 0,
    check_updates: bool = false,
    grid_rows: u16 = 0,
    grid_cols: u16 = 0,
    statusbar: ?*Statusbar = null,
    // Session mode (daemon-backed, single shared socket)
    session_client: ?*SessionClient = null,
    sessions_enabled: bool = false,
    // Track last-sent focus_panes IDs to avoid stale replay on refocus.
    last_focus_panes: [split_layout_mod.max_panes]u32 = .{0} ** split_layout_mod.max_panes,
    last_focus_count: u8 = 0,
    // Configurable session picker icons
    session_icon_filter: []const u8 = ">",
    session_icon_session: []const u8 = "",
    session_icon_new: []const u8 = "+",
    session_icon_active: []const u8 = "(active)",
    session_icon_recent: []const u8 = "",
    session_icon_folder: []const u8 = "\xe2\x96\xb8",
    // Session finder config
    session_finder_root: []const u8 = "~",
    session_finder_depth: u8 = 4,
    session_finder_show_hidden: bool = false,
    // Split resize step in cells/rows per keypress
    split_resize_step: u16 = 4,
};

// ---------------------------------------------------------------------------
// Global routing pointers (set before attyx_run, read by main/renderer thread)
// ---------------------------------------------------------------------------
pub var g_pty_master: posix.fd_t = -1;
pub var g_engine: ?*attyx.Engine = null;
pub var g_popup_pty_master: posix.fd_t = -1;
pub var g_popup_engine: ?*attyx.Engine = null;
pub var g_session_client: ?*SessionClient = null;
pub var g_active_daemon_pane_id: u32 = 0;

// ---------------------------------------------------------------------------
// Export vars — C-facing contract (must stay here for linker visibility)
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

const _icon_bytes = @import("app_icon").data;
pub export var g_icon_png: [*]const u8 = _icon_bytes.ptr;
pub export var g_icon_png_len: c_int = @intCast(_icon_bytes.len);

pub export var g_app_version: [*]const u8 = attyx.version.ptr;
pub export var g_app_version_len: c_int = @intCast(attyx.version.len);

pub export var g_grid_top_offset: i32 = 0;
pub export var g_grid_bottom_offset: i32 = 0;
pub export var g_statusbar_visible: i32 = 0;
pub export var g_statusbar_position: i32 = 0; // 0=top, 1=bottom
pub export var g_toggle_debug_overlay: i32 = 0;
pub export var g_toggle_anchor_demo: i32 = 0;
pub export var g_toggle_ai_demo: i32 = 0;
pub export var g_overlay_has_actions: i32 = 0;
pub export var g_tab_bar_visible: i32 = 0;
pub var g_tab_count: i32 = 1;
// Native macOS tabs
pub export var g_native_tabs_enabled: i32 = 0;
pub export var g_tab_always_show: i32 = 0;
pub export var g_native_tab_count: i32 = 1;
pub export var g_native_tab_active: i32 = 0;
pub export var g_native_tab_titles_changed: i32 = 0;
pub export var g_native_tab_click: i32 = -1;
pub export var g_native_tab_reorder: i32 = -1; // packed (from << 8) | to, -1 = none
pub export var g_native_tab_titles: [16][128]u8 = .{.{0} ** 128} ** 16;
// Session dropdown
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
// Focused pane rect (grid-relative, set by PTY thread for copy mode)
pub export var g_pane_rect_row: i32 = 0;
pub export var g_pane_rect_col: i32 = 0;
pub export var g_pane_rect_rows: i32 = 0;
pub export var g_pane_rect_cols: i32 = 0;
pub export var g_popup_active: i32 = 0;
pub export var g_popup_trail_active: i32 = 0;
pub export var g_popup_mouse_tracking: i32 = 0;
pub export var g_popup_mouse_sgr: i32 = 0;
pub export var g_ai_prompt_active: i32 = 0;
pub export var g_toggle_session_switcher: i32 = 0;
pub export var g_create_session_direct: i32 = 0;
pub export var g_session_picker_active: i32 = 0;
pub export var g_toggle_command_palette: i32 = 0;
pub export var g_command_palette_active: i32 = 0;
pub export var g_toggle_theme_picker: i32 = 0;
pub export var g_theme_picker_active: i32 = 0;

// Ensure keybind, dispatch, and copy mode exports are linked
comptime {
    _ = &keybinds_mod.attyx_keybind_match;
    _ = &keybinds_mod.attyx_keybind_for_action;
    _ = &keybinds_mod.g_keybind_matched_seq;
    _ = &keybinds_mod.g_keybind_matched_seq_len;
    _ = &dispatch.attyx_dispatch_action;
    _ = &copy_mode.attyx_copy_mode_enter;
    _ = &copy_mode.attyx_copy_mode_key;
    _ = &copy_mode.attyx_copy_mode_exit;
    _ = &copy_mode.g_copy_mode;
    _ = &copy_mode.g_copy_cursor_row;
    _ = &copy_mode.g_copy_cursor_col;
    _ = &copy_mode.g_sel_block;
    _ = &copy_mode.g_copy_search_active;
    _ = &copy_mode.g_copy_search_dir;
    _ = &copy_mode.g_copy_search_buf;
    _ = &copy_mode.g_copy_search_len;
    _ = &copy_mode.g_copy_search_dirty;
    _ = &selection.attyx_copy_selection;
}

// ---------------------------------------------------------------------------
// Export fn — thin delegators to sub-modules
// ---------------------------------------------------------------------------
/// Called from platform layer on app termination (e.g. applicationWillTerminate
/// on macOS) to clean up IPC sockets. On macOS, [NSApp terminate:] calls exit()
/// which skips Zig defer blocks, so we need an explicit cleanup path.
export fn attyx_cleanup() void {
    ipc_server.shutdown();
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
export fn attyx_toggle_session_switcher() void {
    @atomicStore(i32, &g_toggle_session_switcher, 1, .seq_cst);
}
export fn attyx_toggle_command_palette() void {
    @atomicStore(i32, &g_toggle_command_palette, 1, .seq_cst);
}
export fn attyx_toggle_theme_picker() void {
    @atomicStore(i32, &g_toggle_theme_picker, 1, .seq_cst);
}
export fn attyx_create_session_direct() void {
    @atomicStore(i32, &g_create_session_direct, 1, .seq_cst);
}
export fn attyx_overlay_esc() void { input.overlayEsc(); }
export fn attyx_overlay_tab() void { input.overlayTab(); }
export fn attyx_overlay_shift_tab() void { input.overlayShiftTab(); }
export fn attyx_overlay_enter() void { input.overlayEnter(); }
export fn attyx_overlay_click(col: c_int, row: c_int) c_int { return input.overlayClick(col, row); }
export fn attyx_overlay_scroll(col: c_int, row: c_int, delta: c_int) c_int { return input.overlayScroll(col, row, delta); }
export fn attyx_search_insert_char(codepoint: u32) void { input.searchInsertChar(codepoint); }
export fn attyx_search_cmd(cmd: c_int) void { input.searchCmd(cmd); }
export fn attyx_ai_prompt_insert_char(codepoint: u32) void { input.aiPromptInsertChar(codepoint); }
export fn attyx_ai_prompt_cmd(cmd: c_int) void { input.aiPromptCmd(cmd); }
export fn attyx_picker_insert_char(codepoint: u32) void { input.pickerInsertChar(codepoint); }
export fn attyx_picker_cmd(cmd: c_int) void { input.pickerCmd(cmd); }
export fn attyx_tab_action(action: c_int) void { input.tabAction(action); }
export fn attyx_tab_bar_click(col: c_int, grid_cols: c_int) void { input.tabBarClick(col, grid_cols); }
export fn attyx_statusbar_tab_click(col: c_int, grid_cols: c_int) void { input.statusbarTabClick(col, grid_cols); }
export fn attyx_split_action(action: c_int) void { input.splitAction(action); }
export fn attyx_split_click(col: c_int, row: c_int) void { input.splitClick(col, row); }
export fn attyx_split_drag_start(col: c_int, row: c_int) void { input.splitDragStart(col, row); }
export fn attyx_split_drag_update(col: c_int, row: c_int) void { input.splitDragUpdate(col, row); }
export fn attyx_split_drag_end() void { input.splitDragEnd(); }
export fn attyx_popup_toggle(index: c_int) void { input.popupToggle(index); }
export fn attyx_popup_send_input(bytes: [*]const u8, len: c_int) void { input.popupSendInput(bytes, len); }
export fn attyx_popup_handle_key(k: u16, m: u8, e: u8, cp: u32) void { input.popupHandleKey(k, m, e, cp); }
export fn attyx_send_input(bytes: [*]const u8, len: c_int) void { input.sendInput(bytes, len); }
export fn attyx_clear_screen() void { input.clearScreen(); }
export fn attyx_handle_key(k: u16, m: u8, e: u8, cp: u32) void { input.handleKey(k, m, e, cp); }
export fn attyx_get_link_uri(link_id: u32, buf: [*]u8, buf_len: c_int) c_int { return input.getLinkUri(link_id, buf, buf_len); }
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

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
pub fn run(
    config: AppConfig,
    no_config: bool,
    config_path: ?[]const u8,
    args: []const [:0]const u8,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const initial_pane = try allocator.create(Pane);
    errdefer allocator.destroy(initial_pane);

    publish.publishFontConfig(&config);
    c.g_cursor_trail = @intFromBool(config.cursor_trail);
    c.g_font_ligatures = @intFromBool(config.font_ligatures);
    g_background_opacity = config.background_opacity;
    g_background_blur = @intCast(config.background_blur);
    g_window_decorations = if (config.window_decorations) 1 else 0;
    g_padding_left = @intCast(config.window_padding_left);
    g_padding_right = @intCast(config.window_padding_right);
    g_padding_top = @intCast(config.window_padding_top);
    g_padding_bottom = @intCast(config.window_padding_bottom);
    g_native_tabs_enabled = if (config.tab_appearance == .native) @as(i32, 1) else @as(i32, 0);
    g_tab_always_show = if (config.tab_always_show) @as(i32, 1) else @as(i32, 0);

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
    publish.publishTheme(&initial_theme);

    const sa = posix.Sigaction{
        .handler = .{ .handler = sigusr1Handler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.USR1, &sa, null);

    // Ignore SIGPIPE — writes to dead daemon sockets must return EPIPE, not kill us.
    const sa_ign = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &sa_ign, null);

    const program_argv: ?[]const [:0]const u8 = if (config.program) |prog|
        try buildProgramArgv(allocator, prog, config.program_args)
    else
        null;
    defer if (program_argv) |pa| {
        for (pa) |s| allocator.free(s);
        allocator.free(pa);
    };

    const spawn_argv = config.argv orelse program_argv;

    // Set initial grid offsets for statusbar so the PTY starts with correct rows
    if (config.statusbar) |sb_cfg| {
        if (sb_cfg.enabled) {
            if (sb_cfg.position == .top) {
                g_grid_top_offset = 1;
            } else {
                g_grid_bottom_offset = 1;
            }
            g_statusbar_visible = 1;
        }
    }
    const initial_pty_rows: u16 = @intCast(@max(1, @as(i32, config.rows) - g_grid_top_offset - g_grid_bottom_offset));

    // Session mode: connect to daemon. On failure, fall back to direct PTY.
    // Ownership transfers to the initial pane's heap-allocated copy below.
    var session_client: ?SessionClient = null;
    defer if (session_client) |*sc| sc.deinit();
    var sessions_enabled = false;

    if (config.sessions_enabled and config.argv == null) {
        if (SessionClient.connect(allocator)) |sc| {
            session_client = sc;
            sessions_enabled = true;
            if (sc.legacy_daemon) {
                logging.warn("session", "daemon is running an older version. Save work and run: attyx kill-daemon", .{});
            } else {
                logging.info("session", "connected to daemon", .{});
            }
        } else |err| {
            logging.err("session", "daemon connect failed (falling back to direct PTY): {}", .{err});
        }
    }

    // Resolve initial working directory: config > $HOME > process CWD > /
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const initial_cwd: []const u8 = config.working_directory orelse
        (std.posix.getenv("HOME") orelse (posix.getcwd(&cwd_buf) catch "/"));
    const initial_shell: []const u8 = config.program orelse "";

    // In session mode: attach to last active session, or create a new one.
    var initial_pane_ids: [32]u32 = .{0} ** 32;
    var initial_pane_count: u8 = 0;
    if (session_client) |*sc| attach_or_create: {
        // Helper: attach and get V2 response with pane IDs
        const doAttach = struct {
            fn call(client: *SessionClient, sid: u32, rows: u16, cols: u16, pids: *[32]u32, pcnt: *u8) bool {
                client.attach(sid, rows, cols) catch return false;
                if (client.waitForAttach(5000)) |resp| {
                    pids.* = resp.pane_ids;
                    pcnt.* = resp.pane_count;
                    return true;
                } else |_| return true; // attached but V1 fallback
            }
        }.call;

        // Try to get existing sessions
        sc.requestListSync(2000) catch {
            const sid = sc.createSession("default", initial_pty_rows, config.cols, initial_cwd, initial_shell) catch |err| {
                logging.err("session", "create session failed: {}", .{err});
                sc.deinit();
                session_client = null;
                break :attach_or_create;
            };
            _ = doAttach(sc, sid, initial_pty_rows, config.cols, &initial_pane_ids, &initial_pane_count);
            conn.saveLastSession(sid);
            logging.info("session", "created and attached to session {d}", .{sid});
            break :attach_or_create;
        };

        // When -d / --working-directory is explicitly set, always create a
        // fresh session in that directory instead of reattaching to an existing one.
        if (config.working_directory != null) {
            const sid = sc.createSession("default", initial_pty_rows, config.cols, initial_cwd, initial_shell) catch |err| {
                logging.err("session", "create session failed: {}", .{err});
                sc.deinit();
                session_client = null;
                break :attach_or_create;
            };
            _ = doAttach(sc, sid, initial_pty_rows, config.cols, &initial_pane_ids, &initial_pane_count);
            conn.saveLastSession(sid);
            logging.info("session", "created new session {d} for working directory", .{sid});
            break :attach_or_create;
        }

        // Look for an alive session to reattach to — prefer the last-used one.
        // Skip the "default" session (hidden/detached, only accessible via ^D).
        var found_alive: ?u32 = null;
        if (conn.loadLastSession()) |last_id| {
            for (sc.pending_list[0..sc.pending_list_count]) |entry| {
                if (entry.alive and entry.id == last_id and !isDefaultSession(entry.getName())) {
                    found_alive = last_id;
                    break;
                }
            }
        }
        if (found_alive == null) {
            for (sc.pending_list[0..sc.pending_list_count]) |entry| {
                if (entry.alive and !isDefaultSession(entry.getName())) {
                    found_alive = entry.id;
                    break;
                }
            }
        }
        // Last resort: attach to any alive session (including "default").
        if (found_alive == null) {
            for (sc.pending_list[0..sc.pending_list_count]) |entry| {
                if (entry.alive) {
                    found_alive = entry.id;
                    break;
                }
            }
        }

        if (found_alive) |sid| {
            if (!doAttach(sc, sid, initial_pty_rows, config.cols, &initial_pane_ids, &initial_pane_count)) {
                logging.err("session", "attach to session {d} failed", .{sid});
                const new_sid = sc.createSession("default", initial_pty_rows, config.cols, initial_cwd, initial_shell) catch |err2| {
                    logging.err("session", "create session failed: {}", .{err2});
                    sc.deinit();
                    session_client = null;
                    break :attach_or_create;
                };
                _ = doAttach(sc, new_sid, initial_pty_rows, config.cols, &initial_pane_ids, &initial_pane_count);
            }
            conn.saveLastSession(found_alive.?);
            logging.info("session", "reattached to session {d}", .{found_alive.?});
        } else {
            const sid = sc.createSession("default", initial_pty_rows, config.cols, initial_cwd, initial_shell) catch |err| {
                logging.err("session", "create session failed: {}", .{err});
                sc.deinit();
                session_client = null;
                break :attach_or_create;
            };
            _ = doAttach(sc, sid, initial_pty_rows, config.cols, &initial_pane_ids, &initial_pane_count);
            conn.saveLastSession(sid);
            logging.info("session", "created and attached to session {d}", .{sid});
        }
    }

    // Always spawn a local Pane (provides Engine + TabManager integration).
    // In session mode, the Pane's PTY is idle — I/O goes through the daemon socket.
    const cwd_z: ?[:0]u8 = if (config.working_directory) |d| allocator.dupeZ(u8, d) catch null else null;
    defer if (cwd_z) |z| allocator.free(z);
    const cwd_ptr: ?[*:0]const u8 = if (cwd_z) |z| z.ptr else null;
    initial_pane.* = try Pane.spawn(allocator, initial_pty_rows, config.cols, spawn_argv, cwd_ptr, config.scrollback_lines);
    initial_pane.engine.state.cursor_shape = publish.cursorShapeFromConfig(config.cursor_shape, config.cursor_blink);
    initial_pane.engine.state.reflow_on_resize = config.reflow_enabled;
    initial_pane.engine.state.theme_colors = publish.themeToEngineColors(&initial_theme);

    // Transfer SessionClient to heap — shared by all panes via ctx.
    // Assign daemon_pane_id to the initial pane and send focus_panes.
    var heap_session_client: ?*SessionClient = null;
    if (session_client) |sc_val| {
        const heap_sc = try allocator.create(SessionClient);
        heap_sc.* = sc_val;
        heap_session_client = heap_sc;
        session_client = null; // prevent defer from double-closing
    }

    var tab_mgr = TabManager.init(allocator, initial_pane);
    defer tab_mgr.deinit();
    {
        const gaps = event_loop.computeSplitGaps();
        tab_mgr.updateGaps(gaps.h, gaps.v);
    }

    // Track initial focus pane IDs so PtyThreadCtx starts with correct replay tracking.
    var initial_focus_panes: [split_layout_mod.max_panes]u32 = .{0} ** split_layout_mod.max_panes;
    var initial_focus_count: u8 = 0;

    // Session mode: try to reconstruct tabs from saved layout, else single pane fallback.
    if (heap_session_client) |heap_sc| {
        var reconstructed = false;
        if (heap_sc.layout_len > 0) {
            if (layout_codec.deserialize(heap_sc.layout_buf[0..heap_sc.layout_len])) |info| {
                if (info.tab_count > 0) {
                    tab_mgr.reset(); // tear down initial pane
                    tab_mgr.reconstructFromLayout(&info, initial_pty_rows, config.cols, config.scrollback_lines) catch {
                        logging.err("session", "layout reconstruction failed", .{});
                    };
                    if (tab_mgr.count > 0) {
                        reconstructed = true;
                        logging.info("session", "reconstructed {d} tab(s) from layout", .{tab_mgr.count});
                    }
                }
            } else |_| {
                logging.warn("session", "layout deserialization failed, using single pane", .{});
            }
        }

        // Fallback: no layout or reconstruction failed — use initial pane with first daemon pane ID
        if (!reconstructed) {
            if (initial_pane_count > 0) {
                initial_pane.daemon_pane_id = initial_pane_ids[0];
            }
        }

        // Set active daemon pane ID and send focus_panes
        const active_pane = tab_mgr.activePane();
        g_active_daemon_pane_id = active_pane.daemon_pane_id orelse 0;

        // Collect all daemon pane IDs in the active tab and send focus_panes
        const active_layout = tab_mgr.activeLayout();
        var focus_ids: [split_layout_mod.max_panes]u32 = undefined;
        var focus_count: usize = 0;
        var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
        const lc = active_layout.collectLeaves(&leaves);
        for (leaves[0..lc]) |leaf| {
            if (leaf.pane.daemon_pane_id) |dpid| {
                focus_ids[focus_count] = dpid;
                focus_count += 1;
            }
        }
        if (focus_count > 0) {
            heap_sc.sendFocusPanes(focus_ids[0..focus_count]) catch {};
        }
        // Seed the focus tracking so switchActiveTab won't re-replay these panes.
        for (0..focus_count) |i| {
            initial_focus_panes[i] = focus_ids[i];
        }
        initial_focus_count = @intCast(focus_count);
    }

    g_pty_master = tab_mgr.activePane().pty.master;
    g_engine = &tab_mgr.activePane().engine;
    g_session_client = heap_session_client;

    // Set split-active flag so input dispatch enables pane navigation keybinds.
    {
        const init_layout = tab_mgr.activeLayout();
        @atomicStore(i32, &g_split_active, if (init_layout.pane_count > 1) @as(i32, 1) else @as(i32, 0), .seq_cst);
    }
    defer {
        g_pty_master = -1;
        g_engine = null;
        if (heap_session_client) |hsc| {
            hsc.deinit();
            allocator.destroy(hsc);
        }
        g_session_client = null;
    }

    const render_cells = try allocator.alloc(c.AttyxCell, MAX_CELLS);
    @memset(render_cells, std.mem.zeroes(c.AttyxCell));
    defer allocator.free(render_cells);

    const active_eng = &tab_mgr.activePane().engine;
    const total: usize = @as(usize, initial_pty_rows) * @as(usize, config.cols);
    publish.fillCells(render_cells[0..total], active_eng, total, &initial_theme, null);
    c.attyx_set_cursor(@intCast(active_eng.state.cursor.row + @as(usize, @intCast(g_grid_top_offset))), @intCast(active_eng.state.cursor.col));

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

    // Statusbar
    var statusbar: ?Statusbar = if (config.statusbar) |sb_cfg| blk: {
        var sb = Statusbar.init(allocator, sb_cfg);
        // Resolve config_dir for custom script widgets
        if (platform.getConfigPaths(allocator)) |paths_val| {
            var paths = paths_val;
            sb.config_dir = allocator.dupe(u8, paths.config_dir) catch null;
            paths.deinit();
        } else |_| {}
        if (sb.config.enabled) {
            logging.info("statusbar", "enabled with {d} widget(s), position={s}", .{
                sb.config.widget_count,
                if (sb.config.position == .top) "top" else "bottom",
            });
        }
        break :blk sb;
    } else null;
    defer if (statusbar) |*sb| sb.deinit();

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
        .applied_font_ligatures = config.font_ligatures,
        .applied_scrollback_lines = @intCast(tab_mgr.activePane().engine.state.ring.capacity - tab_mgr.activePane().engine.state.ring.screen_rows),
        .theme_registry = &theme_registry,
        .active_theme = initial_theme,
        .overlay_mgr = &overlay_mgr,
        .popup_configs = popup_configs,
        .popup_config_count = popup_config_count,
        .check_updates = config.check_updates,
        .grid_rows = config.rows,
        .grid_cols = config.cols,
        .statusbar = if (statusbar) |*sb| sb else null,
        .session_client = heap_session_client,
        .sessions_enabled = sessions_enabled,
        .session_icon_filter = config.session_icon_filter,
        .session_icon_session = config.session_icon_session,
        .session_icon_new = config.session_icon_new,
        .session_icon_active = config.session_icon_active,
        .session_icon_recent = config.session_icon_recent,
        .session_icon_folder = config.session_icon_folder,
        .session_finder_root = config.session_finder_root,
        .session_finder_depth = config.session_finder_depth,
        .session_finder_show_hidden = config.session_finder_show_hidden,
        .last_focus_panes = initial_focus_panes,
        .last_focus_count = initial_focus_count,
        .split_resize_step = config.split_resize_step,
    };

    // Push theme colors to all pane engines (covers reconstructed daemon tabs too).
    publish.publishThemeToEngines(&ctx);
    // Push theme colors to daemon for direct OSC 10/11/12/4 response.
    publish.publishThemeToDaemon(&ctx);

    // Start IPC control socket server
    ipc_server.start() catch |err| {
        logging.warn("ipc", "failed to start IPC server: {}", .{err});
    };
    const ipc_thread = if (ipc_server.isStarted())
        std.Thread.spawn(.{}, ipc_server.run, .{}) catch |err| blk: {
            logging.warn("ipc", "failed to spawn IPC thread: {}", .{err});
            break :blk null;
        }
    else
        null;
    defer {
        ipc_server.shutdown();
        if (ipc_thread) |t| t.join();
    }

    const thread = try std.Thread.spawn(.{}, event_loop.ptyReaderThread, .{&ctx});
    defer thread.join();

    c.attyx_run(render_cells.ptr, @intCast(config.cols), @intCast(config.rows));
}

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

/// The "default" session is a hidden/detached session only accessible via ^D.
pub fn isDefaultSession(name: []const u8) bool {
    return std.mem.eql(u8, name, "default");
}
