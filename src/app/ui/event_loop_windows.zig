// Windows event loop — uses PeekNamedPipe polling instead of POSIX poll().
// Mirrors the POSIX event_loop.zig but avoids all Unix-specific APIs.

const std = @import("std");
const builtin = @import("builtin");
const attyx = @import("attyx");
const Engine = attyx.Engine;
const logging = @import("../../logging/log.zig");
const publish = @import("publish.zig");
const c = publish.c;
const ws = @import("../windows_stubs.zig");
const split_layout_mod = @import("../split_layout.zig");
const split_render = @import("../split_render.zig");
const TabManager = @import("../tab_manager.zig").TabManager;
const Pane = @import("../pane.zig").Pane;
const keybinds_mod = @import("../../config/keybinds.zig");
const Action = keybinds_mod.Action;
const theme_registry_mod = @import("../../theme/registry.zig");
const ThemeRegistry = theme_registry_mod.ThemeRegistry;
const Theme = theme_registry_mod.Theme;
const config_mod = @import("../../config/config.zig");
const reload_mod = @import("../../config/reload.zig");
const tab_bar_mod = @import("../tab_bar.zig");
const statusbar_mod = @import("../statusbar.zig");
const win_split = @import("win_split_actions.zig");
const overlay_mod = attyx.overlay_mod;
const OverlayManager = overlay_mod.OverlayManager;
const StyledCell = overlay_mod.StyledCell;
const Rgb = overlay_mod.Rgb;
const win_search = @import("win_search.zig");
const win_overlays = @import("win_overlays.zig");
const win_popup = @import("win_popup.zig");
const win_session_picker = @import("win_session_picker.zig");
const popup_mod = @import("../popup.zig");
const ipc_queue = @import("../../ipc/queue.zig");
const ipc_handler = @import("../../ipc/handler_windows.zig");
const session_win = @import("../session_windows.zig");
const WinSessionManager = session_win.WinSessionManager;

const HANDLE = std.os.windows.HANDLE;
const DWORD = std.os.windows.DWORD;

extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
extern "winmm" fn timeBeginPeriod(uPeriod: c_uint) callconv(.winapi) c_uint;
extern "winmm" fn timeEndPeriod(uPeriod: c_uint) callconv(.winapi) c_uint;

const MAX_CELLS = c.ATTYX_MAX_ROWS * c.ATTYX_MAX_COLS;

pub const WinCtx = struct {
    tab_mgr: *TabManager,
    cells: [*]c.AttyxCell,
    allocator: std.mem.Allocator,
    theme: *Theme,
    theme_registry: *ThemeRegistry,
    grid_rows: u16,
    grid_cols: u16,
    no_config: bool,
    config_path: ?[]const u8,
    args: []const [:0]const u8,
    applied_scrollback_lines: u32,
    statusbar: ?*statusbar_mod.Statusbar = null,
    overlay_mgr: ?*OverlayManager = null,
    split_resize_step: u16 = 4,
    popup_state: ?*popup_mod.PopupState = null,
    popup_configs: [32]popup_mod.PopupConfig = undefined,
    popup_config_count: u8 = 0,
    session_mgr: ?*WinSessionManager = null,
    finder_root: []const u8 = "~",
    finder_depth: u8 = 4,
    finder_show_hidden: bool = false,
};

pub fn ptyReaderThread(ctx: *WinCtx) void {
    logging.info("event", "Windows event loop started", .{});
    // Set 1ms timer resolution so Sleep(1) actually sleeps ~1ms instead of ~15ms.
    _ = timeBeginPeriod(1);
    defer _ = timeEndPeriod(1);
    var buf: [65536]u8 = undefined;
    var last_published_vp: usize = 0;
    var last_publish_ns: i128 = 0;
    const min_frame_ns: i128 = 16 * std.time.ns_per_ms;

    // Initialize search state
    win_search.g_search = attyx.SearchState.init(ctx.tab_mgr.activePane().engine.state.ring.allocator);

    // Startup drain: give shell time to produce initial prompt.
    for (0..20) |_| {
        const pane = ctx.tab_mgr.activePane();
        // Start async read to trigger ConPTY flush, then wait a bit.
        pane.pty.startAsyncRead();
        Sleep(50);
        if (pane.pty.checkAsyncRead()) |data| {
            pane.feed(data);
            // Drain any remaining data.
            while (pane.pty.peekAvail() > 0) {
                const n = pane.pty.read(&buf) catch break;
                if (n == 0) break;
                pane.feed(buf[0..n]);
            }
        }
    }
    // Compute initial grid offsets and publish initial cells after startup drain.
    updateGridOffsets(ctx);
    logging.info("overlay", "init: top_off={d} bot_off={d} sb_vis={d} tb_vis={d}", .{
        ws.g_grid_top_offset, ws.g_grid_bottom_offset, ws.g_statusbar_visible, ws.g_tab_bar_visible,
    });
    {
        const eng = &ctx.tab_mgr.activePane().engine;
        const total: usize = @as(usize, ctx.grid_rows) * @as(usize, ctx.grid_cols);
        c.attyx_begin_cell_update();
        publish.fillCells(ctx.cells[0..total], eng, total, ctx.theme, null);
        setCursorFromEngine(eng, ws.g_grid_top_offset);
        generateTabBar(ctx);
        generateStatusbar(ctx);
        win_search.publishOverlays(ctx);
        c.attyx_mark_all_dirty();
        c.attyx_end_cell_update();
        publishState(eng);
    }

    while (c.attyx_should_quit() == 0) {
        if (ctx.tab_mgr.count == 0) {
            c.attyx_request_quit();
            break;
        }

        // ── Config reload ──
        if (@atomicRmw(i32, &ws.g_needs_reload_config, .Xchg, 0, .seq_cst) != 0) {
            doReloadConfig(ctx);
        }

        // ── Window resize ──
        handleResize(ctx);

        // ── Tab actions ──
        var tabs_changed = false;
        processTabActions(ctx, &tabs_changed);

        // ── Split actions ──
        win_split.processSplitActions(ctx);

        // ── Split click-to-focus ──
        win_split.processSplitClick(ctx);

        // ── Split drag ──
        win_split.processSplitDrag(ctx);

        // ── Overlay dismiss (Esc) + toggle detection ──
        win_overlays.processOverlayDismiss(ctx);
        win_overlays.processToggles(ctx);

        // ── Overlay input + finder tick ──
        const overlay_input_changed = win_overlays.processInput(ctx);
        win_session_picker.tickFinder(ctx);

        // Guard: an overlay action (e.g. close window) may have killed all tabs
        if (ctx.tab_mgr.count == 0) { c.attyx_request_quit(); break; }

        // ── IPC commands ──
        while (ipc_queue.dequeue()) |cmd| {
            ipc_handler.handle(cmd, ctx);
            ipc_queue.advance();
        }

        // ── Clear screen ──
        if (@atomicRmw(i32, &ws.g_clear_screen_pending, .Xchg, 0, .seq_cst) != 0) {
            const pane = ctx.tab_mgr.activePane();
            const eng = &pane.engine;
            eng.state.ring.clearScrollback();
            eng.state.viewport_offset = 0;
            for (0..eng.state.ring.screen_rows) |r| {
                eng.state.ring.clearScreenRow(r);
                eng.state.ring.setScreenWrapped(r, false);
            }
            eng.state.cursor.row = 0;
            eng.state.cursor.col = 0;
            eng.state.dirty.markAll(eng.state.ring.screen_rows);
            _ = pane.pty.writeToPty("\x0c") catch 0;
        }

        // ── Popup lifecycle ──
        win_popup.processPopupToggle(ctx);
        if (@atomicRmw(i32, &ws.popup_close_request, .Xchg, 0, .seq_cst) != 0) {
            win_popup.closePopup(ctx);
        }
        win_popup.drainPopupPty(ctx, &buf);
        win_popup.checkPopupExit(ctx);

        // ── Pane exit detection ──
        checkPaneExits(ctx);
        if (ctx.tab_mgr.count == 0) { c.attyx_request_quit(); break; }

        // ── Sync viewport from C (scroll sets c.g_viewport_offset) ──
        publish.syncViewportFromC(&ctx.tab_mgr.activePane().engine.state);

        // ── Flush debounced PTY resizes ──
        flushPtyResizes(ctx);

        // ── Read PTY data from all panes ──
        var got_data = false;
        {
            const active_pane = ctx.tab_mgr.activePane();

            // Active pane: check async read completion first (non-blocking).
            // This must happen before PeekNamedPipe to maintain data ordering.
            if (active_pane.daemon_pane_id == null) {
                if (active_pane.pty.checkAsyncRead()) |data| {
                    active_pane.feed(data);
                    got_data = true;
                    // Drain any additional data now available via peek+read.
                    while (active_pane.pty.peekAvail() > 0) {
                        const n = active_pane.pty.read(&buf) catch break;
                        if (n == 0) break;
                        active_pane.feed(buf[0..n]);
                    }
                }
            }

            // All panes (including active): drain via PeekNamedPipe.
            drainAllPanes(ctx, &buf, &got_data);

            // Adaptive coalescing: ConPTY often splits a shell's line-redraw
            // (e.g. Ctrl+W → CR + erase + reprint) across multiple pipe writes.
            // Drain in short rounds so we publish the final state, not an
            // intermediate cursor-at-column-0 snapshot.  Stops as soon as a
            // round produces no data (max ~8ms additional latency).
            if (got_data) {
                var rounds: u32 = 0;
                while (rounds < 4) : (rounds += 1) {
                    Sleep(2);
                    var more = false;
                    drainAllPanes(ctx, &buf, &more);
                    if (!more) break;
                }
            }

            // Keep an async read pending on active pane so ConPTY flushes output.
            if (active_pane.daemon_pane_id == null) {
                active_pane.pty.startAsyncRead();
            }
        }

        // ── Title change detection ──
        for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count]) |*maybe_layout| {
            const lay = &(maybe_layout.* orelse continue);
            var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
            const lc = lay.collectLeaves(&leaves);
            for (leaves[0..lc]) |leaf| {
                if (leaf.pane.engine.state.title_changed) {
                    leaf.pane.engine.state.title_changed = false;
                    got_data = true;
                }
            }
        }

        // ── Search ──
        const search_input_changed = win_search.consumeSearchInput();
        win_search.processSearch(&ctx.tab_mgr.activePane().engine.state);

        if (search_input_changed or got_data or @as(i32, @bitCast(c.g_search_active)) != 0) {
            win_search.generateSearchBar(ctx);
        }

        // ── Statusbar widget tick ──
        var statusbar_refreshed = false;
        if (ctx.statusbar) |sb| {
            if (sb.config.enabled) {
                for (ctx.theme.palette, 0..) |opt_color, i| {
                    if (opt_color) |p| sb.ansi_palette[i] = .{ .r = p.r, .g = p.g, .b = p.b };
                }
                const pane = ctx.tab_mgr.activePane();
                statusbar_refreshed = sb.tick(std.time.timestamp(), pane.pty.pipe_out_read, pane.engine.state.working_directory);
            }
        }

        // ── Throttle & publish ──
        const eng = &ctx.tab_mgr.activePane().engine;
        const viewport_offset = eng.state.viewport_offset;
        const search_vp_changed = (viewport_offset != last_published_vp);
        const viewport_changed = search_vp_changed;
        const need_update = got_data or viewport_changed or search_input_changed or overlay_input_changed or tabs_changed or statusbar_refreshed;

        if (need_update) {
            const now = std.time.nanoTimestamp();
            if (!viewport_changed and !tabs_changed and (now - last_publish_ns) < min_frame_ns) {
                Sleep(0); // Yield timeslice but don't wait — keep draining PTY data
                continue;
            }

            const layout = ctx.tab_mgr.activeLayout();
            const grid_top: i32 = ws.g_grid_top_offset;
            const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));

            c.attyx_begin_cell_update();

            if (layout.pane_count > 1 and !layout.isZoomed()) {
                split_render.fillCellsSplit(
                    @ptrCast(ctx.cells),
                    layout,
                    pty_rows,
                    ctx.grid_cols,
                    ctx.theme,
                );
                const rect = layout.pool[layout.focused].rect;
                const vp = @min(eng.state.viewport_offset, eng.state.ring.scrollbackCount());
                c.attyx_set_cursor(
                    @intCast(eng.state.cursor.row + vp + rect.row + @as(usize, @intCast(grid_top))),
                    @intCast(eng.state.cursor.col + rect.col),
                );
                // Set focused pane rect for copy mode
                ws.g_pane_rect_row = @intCast(rect.row);
                ws.g_pane_rect_col = @intCast(rect.col);
                ws.g_pane_rect_rows = @intCast(rect.rows);
                ws.g_pane_rect_cols = @intCast(rect.cols);
                c.attyx_mark_all_dirty();
            } else {
                const total: usize = @as(usize, pty_rows) * @as(usize, ctx.grid_cols);
                if (viewport_changed) {
                    publish.fillCells(ctx.cells[0..total], eng, total, ctx.theme, null);
                    c.attyx_mark_all_dirty();
                } else {
                    publish.fillCells(ctx.cells[0..total], eng, total, ctx.theme, &eng.state.dirty);
                    c.attyx_set_dirty(&eng.state.dirty.bits);
                }
                eng.state.dirty.clear();
                setCursorFromEngine(eng, grid_top);
            }

            generateTabBar(ctx);
            generateStatusbar(ctx);
            win_search.publishOverlays(ctx);
            c.attyx_end_cell_update();
            publishState(eng);

            last_published_vp = viewport_offset;
            last_publish_ns = std.time.nanoTimestamp();
        } else {
            Sleep(1);
        }
    }
    // Clean up search state
    if (win_search.g_search) |*s| {
        s.deinit();
        win_search.g_search = null;
    }
    logging.info("event", "Windows event loop exited", .{});
}

// ── Helpers ──

const theme_mod = @import("../../theme/theme.zig");

fn themeRgb(t: theme_mod.Rgb) Rgb {
    return .{ .r = t.r, .g = t.g, .b = t.b };
}

fn drainAllPanes(ctx: *WinCtx, buf: *[65536]u8, got_data: *bool) void {
    for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count], 0..) |*maybe_layout, tab_idx| {
        const lay = &(maybe_layout.* orelse continue);
        var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
        const lc = lay.collectLeaves(&leaves);
        for (leaves[0..lc]) |leaf| {
            if (leaf.pane.daemon_pane_id != null) continue;
            while (leaf.pane.pty.peekAvail() > 0) {
                const n = leaf.pane.pty.read(buf) catch break;
                if (n == 0) break;
                leaf.pane.feed(buf[0..n]);
                if (tab_idx == ctx.tab_mgr.active) got_data.* = true;
            }
        }
    }
}

fn setCursorFromEngine(eng: *Engine, grid_top: i32) void {
    const vp = @min(eng.state.viewport_offset, eng.state.ring.scrollbackCount());
    c.attyx_set_cursor(
        @intCast(eng.state.cursor.row + vp + @as(usize, @intCast(grid_top))),
        @intCast(eng.state.cursor.col),
    );
}

fn publishState(eng: *Engine) void {
    c.attyx_set_mode_flags(
        @intFromBool(eng.state.bracketed_paste),
        @intFromBool(eng.state.cursor_keys_app),
    );
    c.attyx_set_mouse_mode(
        @intFromEnum(eng.state.mouse_tracking),
        @intFromBool(eng.state.mouse_sgr),
    );
    c.g_scrollback_count = @intCast(eng.state.ring.scrollbackCount());
    c.g_alt_screen = @intFromBool(eng.state.alt_active);
    c.g_viewport_offset = @intCast(eng.state.viewport_offset);
    c.g_cursor_shape = @intFromEnum(eng.state.cursor_shape);
    c.g_cursor_visible = @intFromBool(eng.state.cursor_visible);
    ws.g_kitty_kbd_flags = @intCast(eng.state.kittyFlags());

    if (eng.state.title) |title| {
        const len: usize = @min(title.len, c.ATTYX_TITLE_MAX - 1);
        const cur_len: usize = @intCast(c.g_title_len);
        const same = (len == cur_len) and std.mem.eql(u8, c.g_title_buf[0..cur_len], title[0..len]);
        if (!same) {
            @memcpy(c.g_title_buf[0..len], title[0..len]);
            c.g_title_buf[len] = 0;
            c.g_title_len = @intCast(len);
            c.g_title_changed = 1;
        }
    }
}

/// Resolve tab titles for Windows — strips MSYS2 prefix (e.g. "CLANGARM64:/path")
/// and shows just the directory basename.
fn resolveTabTitles(
    ctx: *WinCtx,
    titles: *tab_bar_mod.TabTitles,
    name_bufs: *[tab_bar_mod.max_tabs][256]u8,
) void {
    titles.* = .{null} ** tab_bar_mod.max_tabs;
    for (0..ctx.tab_mgr.count) |i| {
        const layout = &(ctx.tab_mgr.tabs[i] orelse continue);
        const pane = layout.focusedPane();
        const raw_title = pane.engine.state.title orelse {
            titles[i] = "cmd";
            continue;
        };
        titles[i] = cleanWindowsTitle(raw_title, &name_bufs[i]) orelse raw_title;
    }
}

/// Strip MSYS2 environment prefix (e.g. "MINGW64:/c/Users/foo" → "foo")
/// and extract the basename from the path portion.
fn cleanWindowsTitle(title: []const u8, buf: *[256]u8) ?[]const u8 {
    // Look for "ENV:/path" pattern (MSYS2 sets title as MSYSTEM:PWD)
    var path: []const u8 = title;
    if (std.mem.indexOf(u8, title, ":/")) |colon_pos| {
        path = title[colon_pos + 1 ..];
    } else if (std.mem.indexOf(u8, title, ":\\")) |colon_pos| {
        // Windows-style path like "C:\Users\foo"
        path = title[colon_pos + 1 ..];
    } else {
        return null; // Not a path-style title, use as-is
    }
    // Find the last path separator
    const basename = if (std.mem.lastIndexOfAny(u8, path, "/\\")) |sep|
        path[sep + 1 ..]
    else
        path;
    // Root or empty basename → "~"
    if (basename.len == 0 or std.mem.eql(u8, path, "/")) {
        buf[0] = '~';
        return buf[0..1];
    }
    if (basename.len > 0 and basename.len < 256) {
        @memcpy(buf[0..basename.len], basename);
        return buf[0..basename.len];
    }
    return null;
}

pub fn generateTabBar(ctx: *WinCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    if (ws.g_grid_top_offset <= 0) return;
    if (ws.g_tab_bar_visible == 0) return;
    if (ctx.tab_mgr.count <= 1 and ws.g_tab_always_show == 0) return;

    var name_bufs: [tab_bar_mod.max_tabs][256]u8 = undefined;
    var titles: tab_bar_mod.TabTitles = undefined;
    resolveTabTitles(ctx, &titles, &name_bufs);

    const tbg = themeRgb(ctx.theme.background);
    const tfg = themeRgb(ctx.theme.foreground);
    const mix20 = struct {
        fn m(bg_c: u8, fg_c: u8) u8 {
            return @intCast((@as(u16, bg_c) * 4 + @as(u16, fg_c)) / 5);
        }
    }.m;
    const mix35 = struct {
        fn m(bg_c: u8, fg_c: u8) u8 {
            return @intCast((@as(u16, bg_c) * 13 + @as(u16, fg_c) * 7) / 20);
        }
    }.m;
    var styled: [c.ATTYX_MAX_COLS]StyledCell = undefined;
    const result = tab_bar_mod.generate(
        &styled,
        ctx.tab_mgr.count,
        ctx.tab_mgr.active,
        ctx.grid_cols,
        .{
            .tab_bg = .{ .r = mix20(tbg.r, tfg.r), .g = mix20(tbg.g, tfg.g), .b = mix20(tbg.b, tfg.b) },
            .active_tab_bg = .{ .r = mix35(tbg.r, tfg.r), .g = mix35(tbg.g, tfg.g), .b = mix35(tbg.b, tfg.b) },
            .fg = tfg,
            .active_fg = tfg,
            .num_highlight_bg = .{ .r = tfg.r / 2, .g = tfg.g / 2, .b = tfg.b / 2 },
            .num_highlight_fg = tfg,
        },
        &titles,
        computeZoomedTabs(ctx),
    ) orelse return;
    mgr.setContent(.tab_bar, 0, 0, result.width, result.height, result.cells) catch return;
    if (!mgr.isVisible(.tab_bar)) mgr.show(.tab_bar);
}

pub fn generateStatusbar(ctx: *WinCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const sb = ctx.statusbar orelse return;
    if (!sb.config.enabled) {
        if (mgr.isVisible(.statusbar)) mgr.hide(.statusbar);
        return;
    }
    // Search takes priority for the top row
    if (@as(i32, @bitCast(c.g_search_active)) != 0 and sb.config.position == .top) {
        if (mgr.isVisible(.statusbar)) mgr.hide(.statusbar);
        return;
    }

    const theme_bg = ctx.theme.background;
    const theme_fg = ctx.theme.foreground;
    const sb_bg = if (ctx.theme.statusbar_background) |bg|
        Rgb{ .r = bg.r, .g = bg.g, .b = bg.b }
    else
        Rgb{ .r = theme_bg.r, .g = theme_bg.g, .b = theme_bg.b };
    const tfg = Rgb{ .r = theme_fg.r, .g = theme_fg.g, .b = theme_fg.b };
    const mix20 = struct {
        fn m(bg_c: u8, fg_c: u8) u8 {
            return @intCast((@as(u16, bg_c) * 4 + @as(u16, fg_c)) / 5);
        }
    }.m;
    const mix35 = struct {
        fn m(bg_c: u8, fg_c: u8) u8 {
            return @intCast((@as(u16, bg_c) * 13 + @as(u16, fg_c) * 7) / 20);
        }
    }.m;

    var name_bufs: [tab_bar_mod.max_tabs][256]u8 = undefined;
    var titles: tab_bar_mod.TabTitles = undefined;
    resolveTabTitles(ctx, &titles, &name_bufs);
    var styled: [c.ATTYX_MAX_COLS]StyledCell = undefined;
    const sb_alpha: u8 = sb.config.background_opacity;
    const result = statusbar_mod.generate(
        &styled,
        sb,
        ctx.tab_mgr.count,
        ctx.tab_mgr.active,
        ctx.grid_cols,
        .{
            .bg = sb_bg,
            .fg = tfg,
            .tab_bg = .{ .r = mix20(sb_bg.r, tfg.r), .g = mix20(sb_bg.g, tfg.g), .b = mix20(sb_bg.b, tfg.b) },
            .active_tab_bg = .{ .r = mix35(sb_bg.r, tfg.r), .g = mix35(sb_bg.g, tfg.g), .b = mix35(sb_bg.b, tfg.b) },
            .active_tab_fg = tfg,
            .bg_alpha = sb_alpha,
        },
        &titles,
        computeZoomedTabs(ctx),
    ) orelse return;

    const row: u16 = if (sb.config.position == .top) 0 else ctx.grid_rows -| 1;
    mgr.setContent(.statusbar, 0, row, result.width, result.height, result.cells) catch return;
    if (!mgr.isVisible(.statusbar)) mgr.show(.statusbar);
}

fn computeZoomedTabs(ctx: *WinCtx) u16 {
    var mask: u16 = 0;
    for (0..ctx.tab_mgr.count) |i| {
        const layout = &(ctx.tab_mgr.tabs[i] orelse continue);
        if (layout.isZoomed()) mask |= @as(u16, 1) << @intCast(i);
    }
    return mask;
}

// ── Tab actions ──

fn processTabActions(ctx: *WinCtx, tabs_changed: *bool) void {
    const action_raw = @atomicRmw(i32, &ws.tab_action_request, .Xchg, 0, .seq_cst);

    if (action_raw != 0) {
        tabs_changed.* = true;
        const action: Action = @enumFromInt(@as(u8, @intCast(action_raw)));

        switch (action) {
            .tab_new => {
                const rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));
                ctx.tab_mgr.addTab(rows, ctx.grid_cols, null, ctx.applied_scrollback_lines) catch |err| {
                    logging.err("tabs", "addTab failed: {}", .{err});
                    return;
                };
                updateGridOffsets(ctx);
                ctx.tab_mgr.activePane().engine.state.theme_colors = publish.themeToEngineColors(ctx.theme);
                switchActiveTab(ctx);
                logging.info("tabs", "new tab {d}/{d}", .{ ctx.tab_mgr.active + 1, ctx.tab_mgr.count });
            },
            .tab_close => {
                if (ctx.tab_mgr.count <= 1) {
                    c.attyx_request_quit();
                    return;
                }
                ctx.tab_mgr.closeTab(ctx.tab_mgr.active);
                updateGridOffsets(ctx);
                switchActiveTab(ctx);
            },
            .tab_next => { ctx.tab_mgr.nextTab(); switchActiveTab(ctx); },
            .tab_prev => { ctx.tab_mgr.prevTab(); switchActiveTab(ctx); },
            .tab_move_left => { ctx.tab_mgr.moveTabLeft(); switchActiveTab(ctx); },
            .tab_move_right => { ctx.tab_mgr.moveTabRight(); switchActiveTab(ctx); },
            .tab_select_1, .tab_select_2, .tab_select_3,
            .tab_select_4, .tab_select_5, .tab_select_6,
            .tab_select_7, .tab_select_8, .tab_select_9,
            => {
                const idx: u8 = @intFromEnum(action) - @intFromEnum(Action.tab_select_1);
                if (idx < ctx.tab_mgr.count) {
                    ctx.tab_mgr.switchTo(idx);
                    switchActiveTab(ctx);
                }
            },
            else => {},
        }
    }

    // Process tab bar clicks
    const click = @atomicRmw(i32, &ws.tab_click_index, .Xchg, -1, .seq_cst);
    if (click >= 0 and click < ctx.tab_mgr.count) {
        ctx.tab_mgr.switchTo(@intCast(@as(u32, @bitCast(click))));
        switchActiveTab(ctx);
        tabs_changed.* = true;
    }
}

pub fn switchActiveTab(ctx: *WinCtx) void {
    const pane = ctx.tab_mgr.activePane();
    const layout = ctx.tab_mgr.activeLayout();
    ws.g_engine = &pane.engine;
    ws.g_pty_handle = pane.pty.pipe_in_write;
    @atomicStore(i32, &ws.g_split_active, if (layout.pane_count > 1) @as(i32, 1) else @as(i32, 0), .seq_cst);
    @atomicStore(i32, &ws.tab_count, @as(i32, ctx.tab_mgr.count), .seq_cst);
    // Force full repaint so the renderer picks up the new tab's content.
    c.attyx_mark_all_dirty();
}

/// Switch the active session — update tab_mgr and bridge globals.
pub fn switchSession(ctx: *WinCtx) void {
    const smgr = ctx.session_mgr orelse return;
    ctx.tab_mgr = smgr.activeTabMgr();
    switchActiveTab(ctx);
}

// ── Resize ──

fn handleResize(ctx: *WinCtx) void {
    var rr: c_int = 0;
    var rc: c_int = 0;
    if (c.attyx_check_resize(&rr, &rc) == 0) return;

    ctx.grid_rows = @intCast(rr);
    ctx.grid_cols = @intCast(rc);

    const pty_rows: u16 = @intCast(@max(1, rr - ws.g_grid_top_offset - ws.g_grid_bottom_offset));
    ctx.tab_mgr.resizeAll(pty_rows, @intCast(rc));

    // Republish cells at new size
    const eng = &ctx.tab_mgr.activePane().engine;
    const total: usize = @as(usize, @intCast(rr)) * @as(usize, @intCast(rc));
    c.attyx_begin_cell_update();
    publish.fillCells(ctx.cells[0..total], eng, total, ctx.theme, null);
    setCursorFromEngine(eng, ws.g_grid_top_offset);
    c.attyx_mark_all_dirty();
    c.attyx_set_grid_size(rc, rr);
    generateTabBar(ctx);
    generateStatusbar(ctx);
    win_search.publishOverlays(ctx);
    c.attyx_end_cell_update();
    publishState(eng);
}

// ── Config reload ──

fn doReloadConfig(ctx: *WinCtx) void {
    var new_config = config_mod.AppConfig{};
    if (!ctx.no_config) {
        if (ctx.config_path) |path| {
            config_mod.loadFromFile(ctx.allocator, path, &new_config) catch return;
        } else {
            config_mod.loadFromDefaultPath(ctx.allocator, &new_config) catch return;
        }
    }
    const cli = @import("../../config/cli.zig");
    cli.applyCliOverrides(ctx.args, &new_config);

    // Apply hot-reloadable settings
    publish.publishFontConfig(&new_config);
    c.g_font_ligatures = @intFromBool(new_config.font_ligatures);
    c.g_cursor_trail = @intFromBool(new_config.cursor_trail);
    ws.g_background_opacity = new_config.background_opacity;

    // Theme
    var new_theme = ctx.theme_registry.resolve(new_config.theme_name);
    if (new_config.theme_background) |bg| new_theme.background = bg;
    ctx.theme.* = new_theme;
    publish.publishTheme(ctx.theme);

    // Apply theme to all engines
    const tc = publish.themeToEngineColors(ctx.theme);
    for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count]) |*maybe_layout| {
        const lay = &(maybe_layout.* orelse continue);
        var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
        const lc = lay.collectLeaves(&leaves);
        for (leaves[0..lc]) |leaf| {
            leaf.pane.engine.state.theme_colors = tc;
        }
    }

    logging.info("config", "config reloaded", .{});
}

// ── Grid offsets ──

pub fn updateGridOffsets(ctx: *WinCtx) void {
    const old_total = ws.g_grid_top_offset + ws.g_grid_bottom_offset;
    var top: i32 = 0;
    var bottom: i32 = 0;

    const sb_active = if (ctx.statusbar) |sb| sb.config.enabled else false;
    if (sb_active) {
        if (ctx.statusbar.?.config.position == .top) {
            ws.g_statusbar_position = 0;
            top += 1;
        } else {
            ws.g_statusbar_position = 1;
            bottom += 1;
        }
        ws.g_statusbar_visible = 1;
        ws.g_tab_bar_visible = 0;
    } else {
        ws.g_statusbar_visible = 0;
        const always_show = (ws.g_tab_always_show != 0);
        const show_builtin = (ctx.tab_mgr.count > 1) or always_show;
        if (show_builtin) top += 1;
        ws.g_tab_bar_visible = if (show_builtin) @as(i32, 1) else @as(i32, 0);
    }

    ws.g_grid_top_offset = top;
    ws.g_grid_bottom_offset = bottom;
    @atomicStore(i32, &ws.tab_count, @as(i32, ctx.tab_mgr.count), .seq_cst);

    const new_total = top + bottom;
    if (new_total != old_total and ctx.grid_rows > 0) {
        const pty_rows = @as(u16, @intCast(@max(1, @as(i32, ctx.grid_rows) - new_total)));
        ctx.tab_mgr.resizeAll(pty_rows, ctx.grid_cols);
    }
}

// ── Pane exit detection ──

fn checkPaneExits(ctx: *WinCtx) void {
    var tab_idx: u8 = 0;
    while (tab_idx < ctx.tab_mgr.count) : (tab_idx += 1) {
        const lay = &(ctx.tab_mgr.tabs[tab_idx] orelse continue);
        const exited_idx = lay.findExitedPane() orelse continue;
        if (lay.pane_count <= 1) {
            ctx.tab_mgr.closeTab(tab_idx);
            if (ctx.tab_mgr.count == 0) {
                c.attyx_request_quit();
                return;
            }
            updateGridOffsets(ctx);
            switchActiveTab(ctx);
            tab_idx -|= 1;
        } else {
            _ = lay.closePaneAt(exited_idx, ctx.allocator);
            const pty_rows: u16 = @intCast(@max(1, @as(i32, ctx.grid_rows) - ws.g_grid_top_offset - ws.g_grid_bottom_offset));
            lay.layout(pty_rows, ctx.grid_cols);
            if (tab_idx == ctx.tab_mgr.active) switchActiveTab(ctx);
        }
    }
}

// ── Flush debounced PTY resizes ──

fn flushPtyResizes(ctx: *WinCtx) void {
    for (ctx.tab_mgr.tabs[0..ctx.tab_mgr.count]) |*maybe_layout| {
        const lay = &(maybe_layout.* orelse continue);
        var leaves: [split_layout_mod.max_panes]split_layout_mod.LeafEntry = undefined;
        const lc = lay.collectLeaves(&leaves);
        for (leaves[0..lc]) |leaf| {
            if (leaf.pane.pending_pty_resize) leaf.pane.flushPtyResize();
        }
    }
}
