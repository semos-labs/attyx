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
const SessionLog = @import("session_log.zig").SessionLog;
const SessionClient = @import("session_client.zig").SessionClient;
const SessionPane = @import("session_pane.zig").SessionPane;
const split_layout_mod = @import("split_layout.zig");
const diag = @import("../logging/diag.zig");
const platform = @import("../platform/platform.zig");
const statusbar_mod = @import("statusbar.zig");
pub const Statusbar = statusbar_mod.Statusbar;

pub const c = @cImport({
    @cInclude("bridge.h");
});

// Sub-modules
const publish = @import("ui/publish.zig");
const input = @import("ui/input.zig");
const search = @import("ui/search.zig");
const ai = @import("ui/ai.zig");
const event_loop = @import("ui/event_loop.zig");

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
    // Session mode (daemon-backed)
    session_client: ?*SessionClient = null,
    session_pane: ?*SessionPane = null,
};

// ---------------------------------------------------------------------------
// Global routing pointers (set before attyx_run, read by main/renderer thread)
// ---------------------------------------------------------------------------
pub var g_pty_master: posix.fd_t = -1;
pub var g_engine: ?*attyx.Engine = null;
pub var g_popup_pty_master: posix.fd_t = -1;
pub var g_popup_engine: ?*attyx.Engine = null;
pub var g_session_client: ?*SessionClient = null;

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
pub export var g_native_tab_titles: [16][128]u8 = .{.{0} ** 128} ** 16;

pub export var g_split_active: i32 = 0;
pub export var g_split_drag_active: i32 = 0;
pub export var g_split_drag_direction: i32 = 0;
pub export var g_popup_active: i32 = 0;
pub export var g_popup_trail_active: i32 = 0;
pub export var g_ai_prompt_active: i32 = 0;
pub export var g_toggle_session_switcher: i32 = 0;
pub export var g_session_switcher_active: i32 = 0;

// Ensure keybind exports are linked
comptime {
    _ = &keybinds_mod.attyx_keybind_match;
    _ = &keybinds_mod.g_keybind_matched_seq;
    _ = &keybinds_mod.g_keybind_matched_seq_len;
}

// ---------------------------------------------------------------------------
// Export fn — thin delegators to sub-modules
// ---------------------------------------------------------------------------
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
export fn attyx_session_switcher_nav_up() void { input.sessionSwitcherNavUp(); }
export fn attyx_session_switcher_nav_down() void { input.sessionSwitcherNavDown(); }
export fn attyx_session_switcher_action(action: c_int) void { input.sessionSwitcherAction(action); }
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
    var session_client: ?SessionClient = null;
    defer if (session_client) |*sc| sc.deinit();

    if (config.sessions_enabled) {
        if (SessionClient.connect(allocator)) |sc| {
            session_client = sc;
            logging.info("session", "connected to daemon", .{});
        } else |err| {
            logging.err("session", "daemon connect failed (falling back to direct PTY): {}", .{err});
        }
    }

    // In session mode: attach to last active session, or create a new one.
    if (session_client) |*sc| attach_or_create: {
        // Try to get existing sessions
        sc.requestListSync(2000) catch {
            // Can't get list — create + attach new session
            const sid = sc.createSession("default", initial_pty_rows, config.cols) catch |err| {
                logging.err("session", "create session failed: {}", .{err});
                sc.deinit();
                session_client = null;
                break :attach_or_create;
            };
            sc.attach(sid, initial_pty_rows, config.cols) catch {};
            logging.info("session", "created and attached to session {d}", .{sid});
            break :attach_or_create;
        };

        // Look for an alive session to reattach to
        var found_alive: ?u32 = null;
        for (sc.pending_list[0..sc.pending_list_count]) |entry| {
            if (entry.alive) {
                found_alive = entry.id;
                break;
            }
        }

        if (found_alive) |sid| {
            sc.attach(sid, initial_pty_rows, config.cols) catch |err| {
                logging.err("session", "attach to session {d} failed: {}", .{ sid, err });
                // Fall back to creating new + attach
                const new_sid = sc.createSession("default", initial_pty_rows, config.cols) catch |err2| {
                    logging.err("session", "create session failed: {}", .{err2});
                    sc.deinit();
                    session_client = null;
                    break :attach_or_create;
                };
                sc.attach(new_sid, initial_pty_rows, config.cols) catch {};
            };
            logging.info("session", "reattached to session {d}", .{found_alive.?});
        } else {
            // No alive sessions — create + attach
            const sid = sc.createSession("default", initial_pty_rows, config.cols) catch |err| {
                logging.err("session", "create session failed: {}", .{err});
                sc.deinit();
                session_client = null;
                break :attach_or_create;
            };
            sc.attach(sid, initial_pty_rows, config.cols) catch {};
            logging.info("session", "created and attached to session {d}", .{sid});
        }
    }

    // Always spawn a local Pane (provides Engine + TabManager integration).
    // In session mode, the Pane's PTY is idle — I/O goes through the daemon socket.
    initial_pane.* = try Pane.spawn(allocator, initial_pty_rows, config.cols, spawn_argv, null);
    initial_pane.engine.state.cursor_shape = publish.cursorShapeFromConfig(config.cursor_shape, config.cursor_blink);
    initial_pane.engine.state.reflow_on_resize = config.reflow_enabled;
    if (config.scrollback_lines != 20_000) {
        initial_pane.engine.state.scrollback.max_lines = config.scrollback_lines;
    }

    var tab_mgr = TabManager.init(allocator, initial_pane);
    defer tab_mgr.deinit();
    {
        const gaps = event_loop.computeSplitGaps();
        tab_mgr.updateGaps(gaps.h, gaps.v);
    }

    g_pty_master = initial_pane.pty.master;
    g_engine = &initial_pane.engine;
    g_session_client = if (session_client) |*sc| sc else null;
    defer {
        g_pty_master = -1;
        g_engine = null;
        g_session_client = null;
    }

    const render_cells = try allocator.alloc(c.AttyxCell, MAX_CELLS);
    defer allocator.free(render_cells);

    const total: usize = @as(usize, initial_pty_rows) * @as(usize, config.cols);
    publish.fillCells(render_cells[0..total], &initial_pane.engine, total, &initial_theme);
    c.attyx_set_cursor(@intCast(initial_pane.engine.state.cursor.row + @as(usize, @intCast(g_grid_top_offset))), @intCast(initial_pane.engine.state.cursor.col));

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
        .applied_scrollback_lines = @intCast(initial_pane.engine.state.scrollback.max_lines),
        .theme_registry = &theme_registry,
        .active_theme = initial_theme,
        .overlay_mgr = &overlay_mgr,
        .popup_configs = popup_configs,
        .popup_config_count = popup_config_count,
        .check_updates = config.check_updates,
        .grid_rows = config.rows,
        .grid_cols = config.cols,
        .statusbar = if (statusbar) |*sb| sb else null,
        .session_client = if (session_client) |*sc| sc else null,
    };

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
