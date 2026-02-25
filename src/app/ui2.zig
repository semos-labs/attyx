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

const c = @cImport({
    @cInclude("bridge.h");
});

const MAX_CELLS = c.ATTYX_MAX_ROWS * c.ATTYX_MAX_COLS;

const PtyThreadCtx = struct {
    engine: *Engine,
    pty: *Pty,
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
};

// Global PTY fd for attyx_send_input (set before attyx_run, read by main thread)
var g_pty_master: posix.fd_t = -1;

// Global engine pointer for attyx_get_link_uri (set before attyx_run, read by renderer thread)
var g_engine: ?*Engine = null;

// Track last-published title pointer to avoid redundant g_title_changed updates.
var g_last_title_ptr: ?[*]const u8 = null;

// Atomic flag: set to 1 to request a config reload on the next PTY thread tick.
// Written by SIGUSR1 handler or attyx_trigger_config_reload(); read-and-reset by PTY thread.
export var g_needs_reload_config: i32 = 0;
export var g_needs_font_rebuild: i32 = 0;
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
    _ = posix.write(g_pty_master, bytes[0..@intCast(@as(c_uint, @bitCast(len)))]) catch {};
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

    var engine = try Engine.init(allocator, config.rows, config.cols);
    defer engine.deinit();

    engine.state.cursor.row = config.rows - 1;

    // Apply config: default cursor shape
    engine.state.cursor_shape = cursorShapeFromConfig(config.cursor_shape, config.cursor_blink);

    // Apply config: scrollback limit
    if (config.scrollback_lines != 20_000) {
        engine.state.scrollback.max_lines = config.scrollback_lines;
    }

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
    const initial_theme = theme_registry.resolve(config.theme_name);
    publishTheme(&initial_theme);

    // Install SIGUSR1 → config reload handler.
    const sa = posix.Sigaction{
        .handler = .{ .handler = sigusr1Handler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.USR1, &sa, null);

    const render_cells = try allocator.alloc(c.AttyxCell, MAX_CELLS);
    defer allocator.free(render_cells);

    const total: usize = @as(usize, config.rows) * @as(usize, config.cols);
    fillCells(render_cells[0..total], &engine, total, &initial_theme);
    c.attyx_set_cursor(@intCast(engine.state.cursor.row), @intCast(engine.state.cursor.col));

    // Build spawn argv: --cmd wins, then [program] config, then $SHELL default.
    const program_argv: ?[]const [:0]const u8 = if (config.program) |prog|
        try buildProgramArgv(allocator, prog, config.program_args)
    else
        null;
    defer if (program_argv) |pa| {
        for (pa) |s| allocator.free(@as([]const u8, s));
        allocator.free(pa);
    };

    const spawn_argv = config.argv orelse program_argv;

    var pty = try Pty.spawn(.{
        .rows = config.rows,
        .cols = config.cols,
        .argv = spawn_argv,
    });
    defer pty.deinit();

    g_pty_master = pty.master;
    g_engine = &engine;
    defer {
        g_pty_master = -1;
        g_engine = null;
    }

    var session = try SessionLog.init(allocator);
    defer session.deinit();

    var ctx = PtyThreadCtx{
        .engine = &engine,
        .pty = &pty,
        .cells = render_cells.ptr,
        .session = &session,
        .allocator = allocator,
        .no_config = no_config,
        .config_path = config_path,
        .args = args,
        .applied_cursor_shape = config.cursor_shape,
        .applied_cursor_blink = config.cursor_blink,
        .applied_cursor_trail = config.cursor_trail,
        .applied_scrollback_lines = @intCast(engine.state.scrollback.max_lines),
        .theme_registry = &theme_registry,
        .active_theme = initial_theme,
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

fn publishImagePlacements(ctx: *PtyThreadCtx) void {
    const state = &ctx.engine.state;
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

        c.g_image_placements[idx] = .{
            .image_id = p.image_id,
            .row = p.row,
            .col = p.col,
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

fn publishState(ctx: *PtyThreadCtx) void {
    c.attyx_set_mode_flags(
        @intFromBool(ctx.engine.state.bracketed_paste),
        @intFromBool(ctx.engine.state.cursor_keys_app),
    );
    c.attyx_set_mouse_mode(
        @intFromEnum(ctx.engine.state.mouse_tracking),
        @intFromBool(ctx.engine.state.mouse_sgr),
    );
    c.g_scrollback_count = @intCast(ctx.engine.state.scrollback.count);
    c.g_alt_screen = @intFromBool(ctx.engine.state.alt_active);
    c.g_viewport_offset = @intCast(ctx.engine.state.viewport_offset);

    c.g_cursor_shape = @intFromEnum(ctx.engine.state.cursor_shape);
    c.g_cursor_visible = @intFromBool(ctx.engine.state.cursor_visible);

    if (ctx.engine.state.title) |title| {
        if (g_last_title_ptr != title.ptr) {
            const len: usize = @min(title.len, c.ATTYX_TITLE_MAX - 1);
            @memcpy(c.g_title_buf[0..len], title[0..len]);
            c.g_title_buf[len] = 0;
            c.g_title_len = @intCast(len);
            c.g_title_changed = 1;
            g_last_title_ptr = title.ptr;
        }
    } else if (g_last_title_ptr != null) {
        g_last_title_ptr = null;
    }
}

var g_search: ?SearchState = null;

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

    g_search = SearchState.init(ctx.engine.state.grid.allocator);
    defer {
        if (g_search) |*s| s.deinit();
        g_search = null;
    }

    while (c.attyx_should_quit() == 0) {
        // Config reload check (atomic read-and-reset)
        if (@atomicRmw(i32, &g_needs_reload_config, .Xchg, 0, .seq_cst) != 0) {
            doReloadConfig(ctx);
        }

        {
            var rr: c_int = 0;
            var rc: c_int = 0;
            if (c.attyx_check_resize(&rr, &rc) != 0) {
                const nr: usize = @intCast(rr);
                const nc: usize = @intCast(rc);

                ctx.engine.state.resize(nr, nc) catch {};
                ctx.pty.resize(@intCast(rr), @intCast(rc)) catch {};

                posix.nanosleep(0, 1_000_000);
                while (true) {
                    const n = ctx.pty.read(&buf) catch break;
                    if (n == 0) break;
                    ctx.session.appendOutput(buf[0..n]);
                    ctx.engine.feed(buf[0..n]);
                    if (ctx.engine.state.drainResponse()) |resp| {
                        _ = ctx.pty.writeToPty(resp) catch {};
                    }
                }

                c.attyx_begin_cell_update();
                const new_total = nr * nc;
                fillCells(ctx.cells[0..new_total], ctx.engine, new_total, &ctx.active_theme);
                c.attyx_set_cursor(
                    @intCast(ctx.engine.state.cursor.row),
                    @intCast(ctx.engine.state.cursor.col),
                );
                c.attyx_set_grid_size(rc, rr);
                c.attyx_set_dirty(&ctx.engine.state.dirty.bits);
                ctx.engine.state.dirty.clear();
                publishImagePlacements(ctx);
                c.attyx_end_cell_update();
                publishState(ctx);
                last_published_vp = ctx.engine.state.viewport_offset;
            }
        }

        var fds = [_]posix.pollfd{
            .{ .fd = ctx.pty.master, .events = POLLIN, .revents = 0 },
        };

        _ = posix.poll(&fds, 16) catch break;

        // Drain all immediately available PTY data before doing expensive work.
        var got_data = false;
        if (fds[0].revents & POLLIN != 0) {
            const t0 = std.time.nanoTimestamp();
            var total_read: usize = 0;
            while (true) {
                const n = ctx.pty.read(&buf) catch break;
                if (n == 0) break;
                got_data = true;
                total_read += n;
                ctx.session.appendOutput(buf[0..n]);
                ctx.engine.feed(buf[0..n]);
                if (ctx.engine.state.drainResponse()) |resp| {
                    _ = ctx.pty.writeToPty(resp) catch {};
                }
            }
            if (total_read > 0) {
                const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - t0, std.time.ns_per_ms);
                if (elapsed_ms > 16) logging.debug("pty", "slow drain: {d}ms ({d} bytes)", .{ elapsed_ms, total_read });
                ctx.throughput.add(total_read);
            }
        }

        // Sync viewport offset from ObjC (scroll wheel may have changed
        // it) BEFORE deciding whether to re-fill cells.
        syncViewportFromC(&ctx.engine.state);

        const viewport_changed = (ctx.engine.state.viewport_offset != last_published_vp);
        const need_update = got_data or viewport_changed;

        // Process search even when no PTY data arrived (navigation / query changes)
        processSearch(&ctx.engine.state);
        const search_vp_changed = (ctx.engine.state.viewport_offset != last_published_vp);
        const need_update_final = need_update or search_vp_changed;

        // DEC 2026 Synchronized Output: defer rendering while the app holds the
        // sync lock so we never present a partial frame.  A 100 ms safety timeout
        // forces a render even if ESC[?2026l is never received (hung or misbehaving app).
        if (ctx.engine.state.synchronized_output) {
            if (ctx.sync_start_ns == 0)
                ctx.sync_start_ns = std.time.nanoTimestamp();
            const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - ctx.sync_start_ns, std.time.ns_per_ms);
            if (elapsed_ms < 100) continue;
        } else {
            ctx.sync_start_ns = 0;
        }

        if (need_update_final) {
            c.attyx_begin_cell_update();
            const total = ctx.engine.state.grid.rows * ctx.engine.state.grid.cols;
            fillCells(ctx.cells[0..total], ctx.engine, total, &ctx.active_theme);
            c.attyx_set_cursor(
                @intCast(ctx.engine.state.cursor.row),
                @intCast(ctx.engine.state.cursor.col),
            );
            c.attyx_set_dirty(&ctx.engine.state.dirty.bits);
            ctx.engine.state.dirty.clear();
            publishImagePlacements(ctx);
            c.attyx_end_cell_update();
            publishState(ctx);
            last_published_vp = ctx.engine.state.viewport_offset;

            if (got_data) {
                const h = state_hash.hash(&ctx.engine.state);
                ctx.session.appendFrame(h, ctx.engine.state.alt_active);
            }
        }

        if (fds[0].revents & POLLHUP != 0 or ctx.pty.childExited()) {
            c.attyx_request_quit();
            break;
        }
    }
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
        ctx.engine.state.cursor_shape = cursorShapeFromConfig(new_cfg.cursor_shape, new_cfg.cursor_blink);
        ctx.applied_cursor_shape = new_cfg.cursor_shape;
        ctx.applied_cursor_blink = new_cfg.cursor_blink;
    }
    if (new_cfg.cursor_trail != ctx.applied_cursor_trail) {
        c.g_cursor_trail = @intFromBool(new_cfg.cursor_trail);
        ctx.applied_cursor_trail = new_cfg.cursor_trail;
    }

    // Scrollback — fully hot-reloadable via reallocate()
    if (new_cfg.scrollback_lines != ctx.applied_scrollback_lines) {
        ctx.engine.state.scrollback.reallocate(new_cfg.scrollback_lines) catch |err| {
            logging.err("config", "scrollback resize failed: {}", .{err});
        };
        ctx.applied_scrollback_lines = @intCast(ctx.engine.state.scrollback.max_lines);
        // Clamp viewport offset if scrollback shrunk
        if (ctx.engine.state.viewport_offset > ctx.engine.state.scrollback.count) {
            ctx.engine.state.viewport_offset = ctx.engine.state.scrollback.count;
            c.g_viewport_offset = @intCast(ctx.engine.state.viewport_offset);
        }
        c.g_scrollback_count = @intCast(ctx.engine.state.scrollback.count);
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
    publishTheme(&ctx.active_theme);

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
    const fg = resolveWithTheme(cell.style.fg, false, theme);
    const bg = resolveWithTheme(cell.style.bg, true, theme);
    return .{
        .character = cell.char,
        .fg_r = fg.r,
        .fg_g = fg.g,
        .fg_b = fg.b,
        .bg_r = bg.r,
        .bg_g = bg.g,
        .bg_b = bg.b,
        .flags = @as(u8, if (cell.style.bold) 1 else 0) |
            @as(u8, if (cell.style.underline) 2 else 0) |
            @as(u8, switch (cell.style.bg) { .default => @as(u8, 4), else => @as(u8, 0) }),
        .link_id = cell.link_id,
    };
}

fn fillCells(cells: []c.AttyxCell, eng: *Engine, _: usize, theme: *const Theme) void {
    const vp = eng.state.viewport_offset;
    const cols = eng.state.grid.cols;
    const rows = eng.state.grid.rows;
    const sb = &eng.state.scrollback;

    if (vp == 0) {
        const total = rows * cols;
        for (0..total) |i| {
            cells[i] = cellToAttyxCell(eng.state.grid.cells[i], theme);
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
        } else {
            const grid_row = row - effective_vp;
            for (0..cols) |col| {
                cells[row * cols + col] = cellToAttyxCell(eng.state.grid.cells[grid_row * cols + col], theme);
            }
        }
    }
}
