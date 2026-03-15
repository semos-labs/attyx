// Windows terminal entry point — spawns a ConPTY via TabManager/Pane,
// sets up the event loop, and hands off to the Win32/D3D11 message loop.
//
// This replaces terminal.zig on Windows. terminal.zig is deeply POSIX
// (Unix sockets, signals, fork/exec) and cannot compile on Windows.

const std = @import("std");
const attyx = @import("attyx");
const overlay_mod = attyx.overlay_mod;
const OverlayManager = overlay_mod.OverlayManager;
const AppConfig = @import("../config/config.zig").AppConfig;
const config_mod = @import("../config/config.zig");
const logging = @import("../logging/log.zig");
const theme_registry_mod = @import("../theme/registry.zig");
const ThemeRegistry = theme_registry_mod.ThemeRegistry;
const Theme = theme_registry_mod.Theme;
const TabManager = @import("tab_manager.zig").TabManager;
const Pane = @import("pane.zig").Pane;
const keybinds_mod = @import("../config/keybinds.zig");
const ws = @import("windows_stubs.zig");
const publish = @import("ui/publish.zig");
const event_loop = @import("ui/event_loop_windows.zig");
const WinCtx = event_loop.WinCtx;
const statusbar_mod = @import("statusbar.zig");
const popup_mod = @import("popup.zig");
const session_win = @import("session_windows.zig");

// Use publish.zig's c namespace to avoid cimport type mismatch.
const c = publish.c;

const MAX_CELLS = c.ATTYX_MAX_ROWS * c.ATTYX_MAX_COLS;

pub fn run(
    config: AppConfig,
    no_config: bool,
    config_path: ?[]const u8,
    args: []const [:0]const u8,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Publish font config and globals
    publish.publishFontConfig(&config);
    c.g_font_ligatures = @intFromBool(config.font_ligatures);
    c.g_cursor_trail = @intFromBool(config.cursor_trail);
    ws.g_background_opacity = config.background_opacity;
    ws.g_background_blur = @intCast(config.background_blur);
    ws.g_window_decorations = if (config.window_decorations) 1 else 0;
    ws.g_padding_left = @intCast(config.window_padding_left);
    ws.g_padding_right = @intCast(config.window_padding_right);
    ws.g_padding_top = @intCast(config.window_padding_top);
    ws.g_padding_bottom = @intCast(config.window_padding_bottom);
    ws.g_native_tabs_enabled = if (config.tab_appearance == .native) @as(i32, 1) else @as(i32, 0);
    ws.g_tab_always_show = if (config.tab_always_show) @as(i32, 1) else @as(i32, 0);

    // Theme setup
    var theme_registry = ThemeRegistry.init(allocator);
    defer theme_registry.deinit();
    theme_registry.loadBuiltins() catch |err| {
        logging.warn("theme", "failed to load built-in themes: {}", .{err});
    };
    if (config_mod.getThemesDir(allocator)) |themes_dir| {
        defer allocator.free(themes_dir);
        theme_registry.loadDir(themes_dir);
    } else |_| {}
    var theme = theme_registry.resolve(config.theme_name);
    if (config.theme_background) |bg| theme.background = bg;
    publish.publishTheme(&theme);

    // Parse popup configs and build keybind table
    var popup_configs: [32]popup_mod.PopupConfig = undefined;
    var popup_count: u8 = 0;
    var popup_hotkeys: [32]keybinds_mod.PopupHotkey = undefined;
    if (config.popup_configs) |entries| {
        for (entries) |entry| {
            if (popup_count >= 32) break;
            popup_configs[popup_count] = .{
                .command = entry.command,
                .width_pct = popup_mod.parsePct(entry.width, 80),
                .height_pct = popup_mod.parsePct(entry.height, 80),
                .border_style = popup_mod.parseBorderStyle(entry.border),
                .border_fg = popup_mod.parseHexColor(entry.border_color, .{ 120, 130, 150 }),
                .pad = popup_mod.parsePadding(
                    entry.padding, entry.padding_x, entry.padding_y,
                    entry.padding_top, entry.padding_bottom,
                    entry.padding_left, entry.padding_right,
                ),
                .on_return_cmd = entry.on_return_cmd,
                .inject_alt = entry.inject_alt,
                .bg_opacity = if (entry.background_opacity) |o| @intFromFloat(o * 255.0) else 255,
                .bg_color = if (entry.background.len == 7 and entry.background[0] == '#')
                    popup_mod.parseHexColor(entry.background, .{ 0, 0, 0 })
                else
                    null,
            };
            popup_hotkeys[popup_count] = .{
                .index = popup_count,
                .hotkey = entry.hotkey,
            };
            popup_count += 1;
        }
    }
    const kb_table = keybinds_mod.buildTable(
        config.keybind_overrides,
        config.sequence_entries,
        popup_hotkeys[0..popup_count],
    );
    keybinds_mod.installTable(&kb_table);
    logging.info("popup", "configured {d} popup(s)", .{popup_count});

    // Statusbar offsets
    if (config.statusbar) |sb_cfg| {
        if (sb_cfg.enabled) {
            if (sb_cfg.position == .top) {
                ws.g_grid_top_offset = 1;
            } else {
                ws.g_grid_bottom_offset = 1;
            }
            ws.g_statusbar_visible = 1;
        }
    }
    const pty_rows: u16 = @intCast(@max(1, @as(i32, config.rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));

    // Spawn initial pane via TabManager
    const initial_pane = try allocator.create(Pane);
    errdefer allocator.destroy(initial_pane);
    initial_pane.* = try Pane.spawn(allocator, pty_rows, config.cols, null, null, config.scrollback_lines);
    initial_pane.engine.state.cursor_shape = publish.cursorShapeFromConfig(config.cursor_shape, config.cursor_blink);
    initial_pane.engine.state.reflow_on_resize = config.reflow_enabled;
    initial_pane.engine.state.theme_colors = publish.themeToEngineColors(&theme);

    const tab_mgr = try allocator.create(TabManager);
    tab_mgr.* = TabManager.init(allocator, initial_pane);

    // Session manager wraps the initial TabManager (takes ownership).
    // Derive initial session name from CWD (e.g. "C:\Users\nick\Projects\foo" → "foo").
    const initial_name = session_win.cwdSessionName() orelse "main";
    var session_mgr = session_win.WinSessionManager.init(allocator, tab_mgr, initial_name);
    defer session_mgr.deinit();

    // Wire up stubs so input dispatch can write to PTY and read engine state
    ws.g_engine = &tab_mgr.activePane().engine;
    ws.g_pty_handle = tab_mgr.activePane().pty.pipe_in_write;
    defer {
        ws.g_engine = null;
        ws.g_pty_handle = null;
    }

    // Allocate render cells
    const render_cells = try allocator.alloc(c.AttyxCell, MAX_CELLS);
    @memset(render_cells, std.mem.zeroes(c.AttyxCell));
    defer allocator.free(render_cells);

    // Statusbar
    var statusbar: ?statusbar_mod.Statusbar = if (config.statusbar) |sb_cfg| blk: {
        const sb = statusbar_mod.Statusbar.init(allocator, sb_cfg);
        break :blk sb;
    } else null;
    defer if (statusbar) |*sb| sb.deinit();

    // Overlay manager (used for search bar, debug overlay, etc.)
    var overlay_mgr = OverlayManager.init(allocator);
    defer overlay_mgr.deinit();

    // Build event loop context
    var ctx = WinCtx{
        .tab_mgr = tab_mgr,
        .cells = render_cells.ptr,
        .allocator = allocator,
        .theme = &theme,
        .theme_registry = &theme_registry,
        .grid_rows = config.rows,
        .grid_cols = config.cols,
        .no_config = no_config,
        .config_path = config_path,
        .args = args,
        .applied_scrollback_lines = config.scrollback_lines,
        .statusbar = if (statusbar) |*sb| sb else null,
        .overlay_mgr = &overlay_mgr,
        .split_resize_step = config.split_resize_step,
        .popup_configs = popup_configs,
        .popup_config_count = popup_count,
        .session_mgr = &session_mgr,
        .finder_root = config.session_finder_root,
        .finder_depth = config.session_finder_depth,
        .finder_show_hidden = config.session_finder_show_hidden,
    };

    logging.info("pty", "spawning event loop ({d}x{d}, {d} pty rows)", .{ config.cols, config.rows, pty_rows });

    // Start IPC control server (named pipe)
    const ipc_server = @import("../ipc/server_windows.zig");
    ipc_server.start() catch |err| {
        logging.warn("ipc", "failed to start IPC server: {}", .{err});
    };
    defer ipc_server.shutdown();
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

    // Start event loop thread
    const reader_thread = try std.Thread.spawn(.{}, event_loop.ptyReaderThread, .{&ctx});
    defer reader_thread.join();

    // Enter Win32 message loop + D3D11 rendering
    c.attyx_run(render_cells.ptr, @intCast(config.cols), @intCast(config.rows));
}
