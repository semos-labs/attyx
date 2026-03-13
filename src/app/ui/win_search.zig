// Windows search — consumes search input, runs matching, renders search bar.
// Mirrors search.zig but uses windows_stubs.zig for ring buffers instead of
// POSIX input.zig, and renders via OverlayManager on WinCtx.

const std = @import("std");
const attyx = @import("attyx");
const SearchState = attyx.SearchState;
const overlay_mod = attyx.overlay_mod;
const OverlayManager = overlay_mod.OverlayManager;
const overlay_search = attyx.overlay_search;

const publish = @import("publish.zig");
const c = publish.c;
const ws = @import("../windows_stubs.zig");
const event_loop = @import("event_loop_windows.zig");
const WinCtx = event_loop.WinCtx;

pub var g_search: ?SearchState = null;
pub var g_search_bar: overlay_search.SearchBarState = .{};
var g_saved_cursor_shape: i32 = -1;
var g_saved_cursor_row: c_int = 0;
var g_saved_cursor_col: c_int = 0;
var g_saved_viewport_offset: usize = 0;
var g_viewport_compensated: bool = false;

/// Consume search input commands from the atomic rings, apply to SearchBarState,
/// and sync the query into g_search_query/g_search_gen for processSearch.
pub fn consumeSearchInput() bool {
    var consumed = false;
    var query_changed = false;

    // Process character insertions
    while (true) {
        const r = @atomicLoad(u32, &ws.g_search_char_read, .seq_cst);
        const w = @atomicLoad(u32, &ws.g_search_char_write, .seq_cst);
        if (r == w) break;
        const cp: u21 = @intCast(ws.search_char_ring[r % 32]);
        g_search_bar.insertChar(cp);
        @atomicStore(u32, &ws.g_search_char_read, r +% 1, .seq_cst);
        consumed = true;
        query_changed = true;
    }

    // Process commands
    while (true) {
        const r = @atomicLoad(u32, &ws.g_search_cmd_read, .seq_cst);
        const w = @atomicLoad(u32, &ws.g_search_cmd_write, .seq_cst);
        if (r == w) break;
        const cmd = ws.search_cmd_ring[r % 16];
        @atomicStore(u32, &ws.g_search_cmd_read, r +% 1, .seq_cst);
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

pub fn processSearch(state: *attyx.TerminalState) void {
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
    const S = struct { var last_gen: u32 = 0; };
    if (gen != S.last_gen) {
        S.last_gen = gen;
        const qlen: usize = @intCast(@as(c_uint, @bitCast(c.g_search_query_len)));
        const clamped = @min(qlen, c.ATTYX_SEARCH_QUERY_MAX);
        var query_copy: [c.ATTYX_SEARCH_QUERY_MAX]u8 = undefined;
        for (0..clamped) |i| {
            query_copy[i] = c.g_search_query[i];
        }
        s.update(query_copy[0..clamped], &state.ring);
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
        if (s.viewportForCurrent(state.ring.scrollbackCount(), state.ring.screen_rows)) |vp| {
            state.viewport_offset = vp;
            c.g_viewport_offset = @intCast(vp);
            c.attyx_mark_all_dirty();
        }
    }

    // Publish results for renderer
    c.g_search_total = @intCast(s.matchCount());
    c.g_search_current = @intCast(s.current);

    const sb_count = state.ring.scrollbackCount();
    const grid_rows = state.ring.screen_rows;
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

pub fn generateSearchBar(ctx: *WinCtx) void {
    const mgr = ctx.overlay_mgr orelse return;
    const active: i32 = @bitCast(c.g_search_active);

    if (active == 0) {
        if (mgr.isVisible(.search_bar)) {
            mgr.hide(.search_bar);
            g_search_bar.clear();
            if (g_saved_cursor_shape >= 0) {
                c.g_cursor_shape = g_saved_cursor_shape;
                g_saved_cursor_shape = -1;
            }
            c.attyx_set_cursor(g_saved_cursor_row, g_saved_cursor_col);
            event_loop.updateGridOffsets(ctx);
            if (g_viewport_compensated) {
                const eng = &ctx.tab_mgr.activePane().engine;
                eng.state.viewport_offset = g_saved_viewport_offset;
                c.g_viewport_offset = @intCast(g_saved_viewport_offset);
                g_viewport_compensated = false;
                c.attyx_mark_all_dirty();
            }
            event_loop.generateStatusbar(ctx);
            event_loop.generateTabBar(ctx);
            publishOverlays(ctx);
        }
        return;
    }

    // Detect fresh activation
    if (!mgr.isVisible(.search_bar)) {
        g_search_bar.clear();
        g_saved_cursor_shape = c.g_cursor_shape;
        g_saved_cursor_row = c.g_cursor_row;
        g_saved_cursor_col = c.g_cursor_col;
        c.g_cursor_shape = 0; // blinking_block
        const had_top_row = (ws.g_grid_top_offset > 0);
        if (mgr.isVisible(.statusbar)) mgr.hide(.statusbar);
        if (mgr.isVisible(.tab_bar)) mgr.hide(.tab_bar);
        event_loop.updateGridOffsets(ctx);
        const eng = &ctx.tab_mgr.activePane().engine;
        g_saved_viewport_offset = eng.state.viewport_offset;
        if (!had_top_row and eng.state.viewport_offset > 0) {
            eng.state.viewport_offset -= 1;
            c.g_viewport_offset = @intCast(eng.state.viewport_offset);
            g_viewport_compensated = true;
            c.attyx_mark_all_dirty();
        } else {
            g_viewport_compensated = false;
        }
    }

    // Sync match counts
    g_search_bar.total_matches = @intCast(@as(c_uint, @bitCast(c.g_search_total)));
    g_search_bar.current_match = @intCast(@as(c_uint, @bitCast(c.g_search_current)));

    const grid_cols = ctx.grid_cols;
    const result = overlay_search.layoutSearchBar(
        ctx.allocator,
        grid_cols,
        &g_search_bar,
        .{},
    ) catch return;

    const search_row: u16 = 0;
    mgr.setContent(.search_bar, 0, search_row, result.width, result.height, result.cells) catch {
        ctx.allocator.free(result.cells);
        return;
    };
    ctx.allocator.free(result.cells);

    if (!mgr.isVisible(.search_bar)) {
        mgr.show(.search_bar);
    }

    // Position cursor in the search bar input area
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

/// Publish overlay layers from OverlayManager to C-side buffers.
pub fn publishOverlays(ctx: *WinCtx) void {
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
                .combining = .{ cells[ci].combining[0], cells[ci].combining[1] },
                .fg_r = cells[ci].fg.r,
                .fg_g = cells[ci].fg.g,
                .fg_b = cells[ci].fg.b,
                .bg_r = cells[ci].bg.r,
                .bg_g = cells[ci].bg.g,
                .bg_b = cells[ci].bg.b,
                .bg_alpha = cells[ci].bg_alpha,
                .flags = cells[ci].flags,
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
            .backdrop_alpha = @intCast(layer.backdrop_alpha),
        };

        out_count += 1;
    }

    c.g_overlay_count = out_count;
    ws.g_overlay_has_actions = if (mgr.hasActiveActions()) @as(i32, 1) else @as(i32, 0);
    _ = @atomicRmw(u32, @as(*u32, @ptrCast(@volatileCast(&c.g_overlay_gen))), .Add, 1, .seq_cst);
}

/// Process overlay dismiss (Esc key) — currently just handles search dismiss.
pub fn processOverlayDismiss(ctx: *WinCtx) void {
    if (@atomicRmw(i32, &ws.overlay_dismiss, .Xchg, 0, .seq_cst) == 0) return;

    // If search is active, dismiss it
    if (@as(i32, @bitCast(c.g_search_active)) != 0) {
        g_search_bar.clear();
        c.g_search_active = 0;
        c.g_search_query_len = 0;
        c.g_search_gen += 1;
        c.attyx_mark_all_dirty();
        return;
    }

    // Generic overlay dismiss
    if (ctx.overlay_mgr) |mgr| {
        if (mgr.dismissActive()) {
            publishOverlays(ctx);
        }
    }
}
