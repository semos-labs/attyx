// Windows terminal entry point — minimal bootstrap that spawns a ConPTY,
// starts a PTY reader thread, and hands off to the Win32/D3D11 event loop.
//
// This replaces terminal.zig on Windows. terminal.zig is deeply POSIX
// (Unix sockets, signals, fork/exec) and cannot compile on Windows.

const std = @import("std");
const attyx = @import("attyx");
const Engine = attyx.Engine;
const AppConfig = @import("../config/config.zig").AppConfig;
const config_mod = @import("../config/config.zig");
const logging = @import("../logging/log.zig");
const theme_registry_mod = @import("../theme/registry.zig");
const ThemeRegistry = theme_registry_mod.ThemeRegistry;
const Theme = theme_registry_mod.Theme;
const Pty = @import("pty.zig").Pty;
const keybinds_mod = @import("../config/keybinds.zig");
const windows_stubs = @import("windows_stubs.zig");
const publish = @import("ui/publish.zig");

// Use publish.zig's c namespace to avoid cimport type mismatch.
const c = publish.c;

const MAX_CELLS = c.ATTYX_MAX_ROWS * c.ATTYX_MAX_COLS;

const HANDLE = std.os.windows.HANDLE;
const DWORD = std.os.windows.DWORD;
const BOOL = std.os.windows.BOOL;

extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

extern "kernel32" fn GetExitCodeProcess(
    hProcess: HANDLE,
    lpExitCode: *DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

pub fn run(
    config: AppConfig,
    no_config: bool,
    config_path: ?[]const u8,
    args: []const [:0]const u8,
) !void {
    _ = no_config;
    _ = config_path;
    _ = args;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Publish font config and globals (use C bridge for exported vars)
    publish.publishFontConfig(&config);
    c.g_font_ligatures = @intFromBool(config.font_ligatures);
    c.g_background_opacity = config.background_opacity;
    c.g_background_blur = @intCast(config.background_blur);
    c.g_window_decorations = if (config.window_decorations) 1 else 0;
    c.g_padding_left = @intCast(config.window_padding_left);
    c.g_padding_right = @intCast(config.window_padding_right);
    c.g_padding_top = @intCast(config.window_padding_top);
    c.g_padding_bottom = @intCast(config.window_padding_bottom);
    c.g_native_tabs_enabled = if (config.tab_appearance == .native) @as(i32, 1) else @as(i32, 0);
    c.g_tab_always_show = if (config.tab_always_show) @as(i32, 1) else @as(i32, 0);

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

    // Keybinds
    var popup_hotkeys: [32]keybinds_mod.PopupHotkey = undefined;
    var popup_count: u8 = 0;
    if (config.popup_configs) |entries| {
        for (entries) |entry| {
            if (popup_count >= 32) break;
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

    // Statusbar offsets
    if (config.statusbar) |sb_cfg| {
        if (sb_cfg.enabled) {
            if (sb_cfg.position == .top) {
                c.g_grid_top_offset = 1;
            } else {
                c.g_grid_bottom_offset = 1;
            }
            c.g_statusbar_visible = 1;
        }
    }
    const grid_top: i32 = c.g_grid_top_offset;
    const grid_bottom: i32 = c.g_grid_bottom_offset;
    const pty_rows: u16 = @intCast(@max(1, @as(i32, config.rows) - grid_top - grid_bottom));

    // Spawn ConPTY
    logging.info("pty", "spawning ConPTY {d}x{d}...", .{ config.cols, pty_rows });
    var pty = try Pty.spawn(allocator, .{
        .rows = pty_rows,
        .cols = config.cols,
    });
    defer pty.deinit();

    // Check if child is alive immediately after spawn
    {
        var code: DWORD = 0;
        const ok = GetExitCodeProcess(pty.process, &code);
        if (ok != 0) {
            if (code == 259) { // STILL_ACTIVE
                logging.info("pty", "child process is alive", .{});
            } else {
                logging.info("pty", "child process already exited with code {d}", .{code});
            }
        } else {
            logging.info("pty", "GetExitCodeProcess failed: {d}", .{GetLastError()});
        }
    }

    // Create engine
    var engine = try Engine.init(allocator, pty_rows, config.cols, config.scrollback_lines);
    defer engine.deinit();
    engine.state.cursor_shape = publish.cursorShapeFromConfig(config.cursor_shape, config.cursor_blink);
    engine.state.reflow_on_resize = config.reflow_enabled;
    engine.state.theme_colors = publish.themeToEngineColors(&theme);

    // Wire up stubs so input dispatch can write to PTY and read engine state
    windows_stubs.g_engine = &engine;
    windows_stubs.g_pty_handle = pty.pipe_in_write;
    defer {
        windows_stubs.g_engine = null;
        windows_stubs.g_pty_handle = null;
    }

    // Allocate render cells
    const render_cells = try allocator.alloc(c.AttyxCell, MAX_CELLS);
    @memset(render_cells, std.mem.zeroes(c.AttyxCell));
    defer allocator.free(render_cells);

    // Initial cell fill
    const total: usize = @as(usize, pty_rows) * @as(usize, config.cols);
    publish.fillCells(render_cells[0..total], &engine, total, &theme, null);
    c.attyx_set_cursor(
        @intCast(engine.state.cursor.row + @as(usize, @intCast(grid_top))),
        @intCast(engine.state.cursor.col),
    );
    c.attyx_mark_all_dirty();

    // Start PTY reader thread
    const reader_thread = try std.Thread.spawn(.{}, ptyReaderThread, .{
        &engine, pty.pipe_out_read, render_cells.ptr, &theme, pty_rows, config.cols, grid_top,
    });
    defer reader_thread.join();

    // Enter Win32 message loop + D3D11 rendering
    c.attyx_run(render_cells.ptr, @intCast(config.cols), @intCast(config.rows));
}

fn ptyReaderThread(
    engine: *Engine,
    read_handle: HANDLE,
    cells: [*]c.AttyxCell,
    theme: *const Theme,
    rows: u16,
    cols: u16,
    grid_top_offset: i32,
) void {
    logging.info("pty", "reader thread started", .{});

    // Check if the child process is still alive
    var exit_code: DWORD = 0;
    const exit_ok = GetExitCodeProcess(read_handle, &exit_code);
    _ = exit_ok;
    // Note: read_handle is the pipe, not the process — we can't check here.
    // Just proceed with reading.

    var buf: [16384]u8 = undefined;
    while (true) {
        var bytes_read: DWORD = 0;
        const rc = ReadFile(
            read_handle,
            @ptrCast(&buf),
            @as(DWORD, buf.len),
            &bytes_read,
            null,
        );
        if (rc == 0) {
            const err = GetLastError();
            logging.info("pty", "ReadFile failed: error={d}", .{err});
            break;
        }
        if (bytes_read == 0) {
            logging.info("pty", "ReadFile returned 0 bytes", .{});
            break;
        }

        logging.info("pty", "read {d} bytes from ConPTY", .{bytes_read});

        // Feed data to engine
        engine.feed(buf[0..bytes_read]);

        // Update render cells
        const total: usize = @as(usize, rows) * @as(usize, cols);
        c.attyx_begin_cell_update();
        publish.fillCells(cells[0..total], engine, total, theme, null);
        c.attyx_set_cursor(
            @intCast(engine.state.cursor.row + @as(usize, @intCast(grid_top_offset))),
            @intCast(engine.state.cursor.col),
        );
        c.attyx_mark_all_dirty();
        c.attyx_end_cell_update();
    }
}
