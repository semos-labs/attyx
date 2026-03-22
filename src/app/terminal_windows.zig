// Windows terminal entry point — spawns a ConPTY via TabManager/Pane,
// sets up the event loop, and hands off to the Win32/D3D11 message loop.
//
// This replaces terminal.zig on Windows. terminal.zig is deeply POSIX
// (Unix sockets, signals, fork/exec) and cannot compile on Windows.
//
// Session mode: when sessions are enabled, connects to the daemon process
// for PTY persistence across window restarts. Falls back to local ConPTY
// when the daemon is unavailable.

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
const SessionClient = @import("session_client.zig").SessionClient;
const conn = @import("session_connect.zig");
const layout_codec = @import("layout_codec.zig");

// Use publish.zig's c namespace to avoid cimport type mismatch.
const c = publish.c;

const MAX_CELLS = c.ATTYX_MAX_ROWS * c.ATTYX_MAX_COLS;

pub fn run(
    config: AppConfig,
    no_config: bool,
    config_path: ?[]const u8,
    args: []const [:0]const u8,
    _: bool, // headless (not yet implemented on Windows)
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Pre-spawn the shell so it boots in parallel with UI setup.
    // The reader thread buffers ConPTY output while we init themes, keybinds, etc.
    var early_pane: ?*Pane = null;
    if (!config.sessions_enabled and config.argv == null) {
        if (allocator.create(Pane)) |p| {
            const sb_offset: i32 = if (config.statusbar) |sb| (if (sb.enabled) @as(i32, 1) else 0) else 0;
            const pty_rows: u16 = @intCast(@max(1, @as(i32, config.rows) - sb_offset));
            if (Pane.spawn(allocator, pty_rows, config.cols, null, null, config.scrollback_lines)) |spawned| {
                p.* = spawned;
                early_pane = p;
            } else |_| {
                allocator.destroy(p);
            }
        } else |_| {}
    }


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

    // Session mode: connect to daemon for PTY persistence.
    var session_client: ?SessionClient = null;
    defer if (session_client) |*sc| sc.deinit();

    // Connect to daemon for session persistence (if enabled in config
    // and no custom argv was specified).
    if (config.sessions_enabled and config.argv == null) {
        if (SessionClient.connect(allocator)) |sc_val| {
            session_client = sc_val;
            if (sc_val.legacy_daemon) {
                logging.warn("session", "daemon is running an older version", .{});
            } else {
                logging.info("session", "connected to daemon", .{});
            }
        } else |err| {
            logging.err("session", "daemon connect failed (falling back to local PTY): {}", .{err});
        }
    }

    // Attach-or-create: if daemon connected, get a session with panes.
    var daemon_pane_id: ?u32 = null;
    if (session_client) |*sc| daemon_blk: {
        const result = attachOrCreate(sc, pty_rows, config.cols) catch |err| {
            logging.err("session", "attach-or-create failed: {}", .{err});
            sc.deinit();
            session_client = null;
            break :daemon_blk;
        };
        conn.saveLastSession(result.session_id);
        logging.info("session", "attached: session={d}, pane={d}", .{ result.session_id, result.pane_id });
        if (result.pane_id != 0) daemon_pane_id = result.pane_id;
    }

    // Transfer SessionClient to heap so it outlives this scope.
    var heap_session_client: ?*SessionClient = null;
    if (session_client) |sc_val| {
        const heap_sc = try allocator.create(SessionClient);
        heap_sc.* = sc_val;
        heap_session_client = heap_sc;
        session_client = null; // prevent defer double-close
    }
    defer if (heap_session_client) |hsc| {
        hsc.deinit();
        allocator.destroy(hsc);
    };

    // Build initial TabManager — reconstruct from daemon layout if available,
    // otherwise spawn a single local pane.
    const tab_mgr = try allocator.create(TabManager);
    const initial_pane = try buildInitialTabs(
        tab_mgr, allocator, heap_session_client, daemon_pane_id,
        pty_rows, config.cols, config.scrollback_lines, &theme, &config,
        early_pane,
    );

    // Session manager wraps the initial TabManager (takes ownership).
    const initial_name = session_win.cwdSessionName() orelse "main";
    var session_mgr = session_win.WinSessionManager.init(allocator, tab_mgr, initial_name);
    session_mgr.session_client = heap_session_client;
    defer session_mgr.deinit();

    // Wire up stubs so input dispatch can write to PTY and read engine state
    ws.g_engine = &tab_mgr.activePane().engine;
    ws.g_pty_handle = tab_mgr.activePane().pty.pipe_in_write;
    ws.g_session_client = heap_session_client;
    ws.g_active_daemon_pane_id = initial_pane.daemon_pane_id orelse 0;
    defer {
        ws.g_engine = null;
        ws.g_pty_handle = null;
        ws.g_session_client = null;
        ws.g_active_daemon_pane_id = 0;
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
        .session_client = heap_session_client,
        .finder_root = config.session_finder_root,
        .finder_depth = config.session_finder_depth,
        .finder_show_hidden = config.session_finder_show_hidden,
    };

    logging.info("pty", "spawning event loop ({d}x{d}, {d} pty rows)", .{ config.cols, config.rows, pty_rows });

    // Pre-drain shell output and publish cells on the main thread.
    // This ensures the first rendered frame has content when the window appears.
    {
        const active = tab_mgr.activePane();
        if (active.daemon_pane_id == null) {
            // Wait up to 300ms for shell to produce output
            var waited: u32 = 0;
            while (waited < 300) : (waited += 1) {
                if (active.pty.consumeReaderData()) |data| {
                    active.feed(data);
                    break;
                }
                std.os.windows.kernel32.Sleep(1);
            }
            // Drain any additional data
            while (active.pty.consumeReaderData()) |more| {
                active.feed(more);
            }
        }
        // Publish cells to g_cells so the renderer can draw them
        const eng = &active.engine;
        const total: usize = @as(usize, config.rows) * @as(usize, config.cols);
        c.attyx_begin_cell_update();
        publish.fillCells(render_cells[0..total], eng, total, &theme, null);
        c.attyx_mark_all_dirty();
        c.attyx_end_cell_update();
    }

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
    // Allocate a hidden console so child processes (git, statusbar scripts)
    // inherit it instead of creating visible console windows that flash.
    @import("pty_windows.zig").ensureHiddenConsole();

    // 8MB stack for reader thread — aarch64 Windows needs committed pages
    // for functions with >4KB frames (no __chkstk probes in Zig debug mode).
    const reader_thread = try std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, event_loop.ptyReaderThread, .{&ctx});
    defer reader_thread.join();

    // Send focus_panes for all daemon panes in the active tab.
    if (heap_session_client) |hsc| {
        sendInitialFocusPanes(tab_mgr, hsc);
    }


    // Enter Win32 message loop + D3D11 rendering
    c.attyx_run(render_cells.ptr, @intCast(config.cols), @intCast(config.rows));
}

const AttachResult = struct { session_id: u32, pane_id: u32 };

/// Try to attach to an existing alive session, or create a new one.
fn attachOrCreate(sc: *SessionClient, rows: u16, cols: u16) !AttachResult {
    // Try listing existing sessions first.
    sc.requestListSync(2000) catch {
        const sid = try sc.createSession("main", rows, cols, "", "");
        return doAttach(sc, sid, rows, cols);
    };

    // Look for an alive session — prefer the last-used one, skip "default".
    const found_alive = findAliveSession(sc);

    if (found_alive) |sid| {
        const result = doAttach(sc, sid, rows, cols) catch {
            // Attach failed — create new.
            const new_sid = try sc.createSession("main", rows, cols, "", "");
            return doAttach(sc, new_sid, rows, cols);
        };
        logging.info("session", "reattached to session {d}", .{sid});
        return result;
    }

    // No alive sessions — create a new one.
    const sid = try sc.createSession("main", rows, cols, "", "");
    const result = try doAttach(sc, sid, rows, cols);
    logging.info("session", "created and attached to session {d}", .{sid});
    return result;
}

fn doAttach(sc: *SessionClient, sid: u32, rows: u16, cols: u16) !AttachResult {
    try sc.attach(sid, rows, cols);
    const resp = sc.waitForAttach(5000) catch {
        return AttachResult{ .session_id = sid, .pane_id = 0 };
    };
    const pane_id: u32 = if (resp.pane_count > 0) resp.pane_ids[0] else 0;
    return AttachResult{ .session_id = sid, .pane_id = pane_id };
}

fn findAliveSession(sc: *SessionClient) ?u32 {
    // Prefer last-used session, skip "default".
    if (conn.loadLastSession()) |last_id| {
        for (sc.pending_list[0..sc.pending_list_count]) |entry| {
            if (entry.alive and entry.id == last_id and !isDefaultSession(entry.getName())) return last_id;
        }
    }
    for (sc.pending_list[0..sc.pending_list_count]) |entry| {
        if (entry.alive and !isDefaultSession(entry.getName())) return entry.id;
    }
    // Last resort: any alive session including "default".
    for (sc.pending_list[0..sc.pending_list_count]) |entry| {
        if (entry.alive) return entry.id;
    }
    return null;
}

fn isDefaultSession(name: []const u8) bool {
    return std.mem.eql(u8, name, "default");
}

const split_layout_mod = @import("split_layout.zig");

/// Build the initial TabManager. If the daemon has a saved layout, reconstruct
/// tabs from it; otherwise spawn a single local pane.
/// Returns the active pane (for wiring up globals).
fn buildInitialTabs(
    tab_mgr: *TabManager,
    allocator: std.mem.Allocator,
    hsc: ?*SessionClient,
    daemon_pane_id: ?u32,
    pty_rows: u16,
    cols: u16,
    scrollback: u32,
    theme: *const @import("../theme/registry.zig").Theme,
    config: *const @import("../config/config.zig").AppConfig,
    early_pane: ?*Pane,
) !*Pane {
    // Try layout reconstruction from daemon.
    if (hsc) |sc| {
        logging.info("session", "layout_len from daemon: {d}", .{sc.layout_len});
        if (sc.layout_len > 0) {
            if (layout_codec.deserialize(sc.layout_buf[0..sc.layout_len])) |info| {
                logging.info("session", "deserialized layout: {d} tabs, active={d}", .{ info.tab_count, info.active_tab });
                if (info.tab_count > 0) {
                    // Create a throwaway initial pane for TabManager.init, then reset.
                    // Mark it daemon-backed so deinit() skips PTY cleanup.
                    const placeholder = try allocator.create(Pane);
                    placeholder.* = try Pane.initDaemonBacked(allocator, pty_rows, cols, scrollback);
                    placeholder.daemon_pane_id = 0xFFFFFFFF; // sentinel so deinit skips PTY
                    tab_mgr.* = TabManager.init(allocator, placeholder);
                    tab_mgr.reconstructFromLayout(&info, pty_rows, cols, scrollback) catch {
                        logging.err("session", "layout reconstruction failed", .{});
                    };
                    if (tab_mgr.count > 0) {
                        logging.info("session", "reconstructed {d} tab(s) from layout", .{tab_mgr.count});
                        applyThemeToAllPanes(tab_mgr, theme, config);
                        // Wire session_client into all daemon-backed panes.
                        wireSessionClient(tab_mgr, sc);
                        return tab_mgr.activePane();
                    }
                }
            } else |_| {
                logging.warn("session", "layout deserialization failed, using single pane", .{});
            }
        }
    }

    // Fallback: single pane (daemon-backed if we have a pane ID, local ConPTY otherwise).
    const pane = if (early_pane) |ep| ep else try allocator.create(Pane);
    errdefer if (early_pane == null) allocator.destroy(pane);
    if (daemon_pane_id != null) {
        pane.* = try Pane.initDaemonBacked(allocator, pty_rows, cols, scrollback);
        pane.daemon_pane_id = daemon_pane_id;
        pane.session_client = hsc;
    } else if (early_pane == null) {
        pane.* = try Pane.spawn(allocator, pty_rows, cols, null, null, scrollback);
    }
    pane.engine.state.cursor_shape = publish.cursorShapeFromConfig(config.cursor_shape, config.cursor_blink);
    pane.engine.state.reflow_on_resize = config.reflow_enabled;
    pane.engine.state.theme_colors = publish.themeToEngineColors(theme);
    tab_mgr.* = TabManager.init(allocator, pane);
    return pane;
}

fn wireSessionClient(tab_mgr: *TabManager, sc: *SessionClient) void {
    for (tab_mgr.tabs[0..tab_mgr.count]) |*maybe_layout| {
        const lay = &(maybe_layout.* orelse continue);
        var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
        const lc = lay.collectLeaves(&leaves);
        for (leaves[0..lc]) |leaf| {
            if (leaf.pane.daemon_pane_id != null) {
                leaf.pane.session_client = sc;
            }
        }
    }
}

fn applyThemeToAllPanes(
    tab_mgr: *TabManager,
    theme: *const @import("../theme/registry.zig").Theme,
    config: *const @import("../config/config.zig").AppConfig,
) void {
    for (tab_mgr.tabs[0..tab_mgr.count]) |*maybe_layout| {
        const lay = &(maybe_layout.* orelse continue);
        var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
        const lc = lay.collectLeaves(&leaves);
        for (leaves[0..lc]) |leaf| {
            leaf.pane.engine.state.cursor_shape = publish.cursorShapeFromConfig(config.cursor_shape, config.cursor_blink);
            leaf.pane.engine.state.reflow_on_resize = config.reflow_enabled;
            leaf.pane.engine.state.theme_colors = publish.themeToEngineColors(theme);
        }
    }
}

/// Send focus_panes for all daemon panes in the active tab.
fn sendInitialFocusPanes(tab_mgr: *TabManager, hsc: *SessionClient) void {
    const layout = tab_mgr.activeLayout();
    var focus_ids: [split_layout_mod.max_panes]u32 = undefined;
    var count: usize = 0;
    var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
    const lc = layout.collectLeaves(&leaves);
    for (leaves[0..lc]) |leaf| {
        if (leaf.pane.daemon_pane_id) |dpid| {
            focus_ids[count] = dpid;
            count += 1;
        }
    }
    if (count > 0) hsc.sendFocusPanes(focus_ids[0..count]) catch {};
}
