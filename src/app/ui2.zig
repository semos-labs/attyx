const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const attyx = @import("attyx");

const Engine = attyx.Engine;
const SearchState = attyx.SearchState;
const state_hash = attyx.hash;
const color_mod = attyx.render_color;
const Pty = @import("pty.zig").Pty;
const SessionLog = @import("session_log.zig").SessionLog;

const c = @cImport({
    @cInclude("bridge.h");
});

pub const Config = struct {
    rows: u16 = 24,
    cols: u16 = 80,
    argv: ?[]const [:0]const u8 = null,
};

const MAX_CELLS = c.ATTYX_MAX_ROWS * c.ATTYX_MAX_COLS;

const PtyThreadCtx = struct {
    engine: *Engine,
    pty: *Pty,
    cells: [*]c.AttyxCell,
    session: *SessionLog,
};

// Global PTY fd for attyx_send_input (set before attyx_run, read by main thread)
var g_pty_master: posix.fd_t = -1;

// Global engine pointer for attyx_get_link_uri (set before attyx_run, read by renderer thread)
var g_engine: ?*Engine = null;

// Track last-published title pointer to avoid redundant g_title_changed updates.
var g_last_title_ptr: ?[*]const u8 = null;

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

pub fn run(config: Config) !void {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) {
        std.debug.print("Attyx requires macOS or Linux.\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try Engine.init(allocator, config.rows, config.cols);
    defer engine.deinit();

    engine.state.cursor.row = config.rows - 1;

    const render_cells = try allocator.alloc(c.AttyxCell, MAX_CELLS);
    defer allocator.free(render_cells);

    const total: usize = @as(usize, config.rows) * @as(usize, config.cols);
    fillCells(render_cells[0..total], &engine, total);
    c.attyx_set_cursor(@intCast(engine.state.cursor.row), @intCast(engine.state.cursor.col));

    var pty = try Pty.spawn(.{
        .rows = config.rows,
        .cols = config.cols,
        .argv = config.argv,
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
    };

    const thread = try std.Thread.spawn(.{}, ptyReaderThread, .{&ctx});
    defer thread.join();

    c.attyx_run(render_cells.ptr, @intCast(config.cols), @intCast(config.rows));
}

fn syncViewportFromC(state: *attyx.TerminalState) void {
    const c_vp: i32 = @bitCast(c.g_viewport_offset);
    if (c_vp >= 0) {
        state.viewport_offset = @intCast(@as(c_uint, @bitCast(c_vp)));
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
                fillCells(ctx.cells[0..new_total], ctx.engine, new_total);
                c.attyx_set_cursor(
                    @intCast(ctx.engine.state.cursor.row),
                    @intCast(ctx.engine.state.cursor.col),
                );
                c.attyx_set_grid_size(rc, rr);
                c.attyx_set_dirty(&ctx.engine.state.dirty.bits);
                ctx.engine.state.dirty.clear();
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
            while (true) {
                const n = ctx.pty.read(&buf) catch break;
                if (n == 0) break;
                got_data = true;
                ctx.session.appendOutput(buf[0..n]);
                ctx.engine.feed(buf[0..n]);
                if (ctx.engine.state.drainResponse()) |resp| {
                    _ = ctx.pty.writeToPty(resp) catch {};
                }
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

        if (need_update_final) {
            c.attyx_begin_cell_update();
            const total = ctx.engine.state.grid.rows * ctx.engine.state.grid.cols;
            fillCells(ctx.cells[0..total], ctx.engine, total);
            c.attyx_set_cursor(
                @intCast(ctx.engine.state.cursor.row),
                @intCast(ctx.engine.state.cursor.col),
            );
            c.attyx_set_dirty(&ctx.engine.state.dirty.bits);
            ctx.engine.state.dirty.clear();
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

fn cellToAttyxCell(cell: attyx.Cell) c.AttyxCell {
    const fg = color_mod.resolve(cell.style.fg, false);
    const bg = color_mod.resolve(cell.style.bg, true);
    return .{
        .character = cell.char,
        .fg_r = fg.r,
        .fg_g = fg.g,
        .fg_b = fg.b,
        .bg_r = bg.r,
        .bg_g = bg.g,
        .bg_b = bg.b,
        .flags = @as(u8, if (cell.style.bold) 1 else 0) |
            @as(u8, if (cell.style.underline) 2 else 0),
        .link_id = cell.link_id,
    };
}

fn fillCells(cells: []c.AttyxCell, eng: *Engine, _: usize) void {
    const vp = eng.state.viewport_offset;
    const cols = eng.state.grid.cols;
    const rows = eng.state.grid.rows;
    const sb = &eng.state.scrollback;

    if (vp == 0) {
        const total = rows * cols;
        for (0..total) |i| {
            cells[i] = cellToAttyxCell(eng.state.grid.cells[i]);
        }
        return;
    }

    const effective_vp = @min(vp, sb.count);
    for (0..rows) |row| {
        if (row < effective_vp) {
            const sb_line_idx = sb.count - effective_vp + row;
            const sb_cells = sb.getLine(sb_line_idx);
            for (0..cols) |col| {
                cells[row * cols + col] = cellToAttyxCell(sb_cells[col]);
            }
        } else {
            const grid_row = row - effective_vp;
            for (0..cols) |col| {
                cells[row * cols + col] = cellToAttyxCell(eng.state.grid.cells[grid_row * cols + col]);
            }
        }
    }
}
