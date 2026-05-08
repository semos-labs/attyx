const std = @import("std");
const attyx = @import("attyx");
const SearchState = attyx.SearchState;
const overlay_mod = attyx.overlay_mod;
const overlay_search = attyx.overlay_search;

const terminal = @import("../terminal.zig");
const PtyThreadCtx = terminal.PtyThreadCtx;
const c = terminal.c;
const input = @import("input.zig");
const publish = @import("publish.zig");

pub var g_search: ?SearchState = null;
pub var g_search_bar: overlay_search.SearchBarState = .{};
var g_saved_cursor_shape: i32 = -1; // -1 = not saved
var g_saved_cursor_row: c_int = 0;
var g_saved_cursor_col: c_int = 0;
var g_saved_viewport_offset: usize = 0;
var g_viewport_compensated: bool = false;

/// Consume search input commands from the atomic rings, apply to SearchBarState,
/// and sync the query into g_search_query/g_search_gen for processSearch.
/// Returns true if any input was consumed.
pub fn consumeSearchInput() bool {
    var consumed = false;
    var query_changed = false;

    // Process character insertions
    while (true) {
        const r = @atomicLoad(u32, &input.g_search_char_read, .seq_cst);
        const w = @atomicLoad(u32, &input.g_search_char_write, .seq_cst);
        if (r == w) break;
        const cp: u21 = @intCast(input.g_search_char_ring[r % 32]);
        g_search_bar.insertChar(cp);
        @atomicStore(u32, &input.g_search_char_read, r +% 1, .seq_cst);
        consumed = true;
        query_changed = true;
    }

    // Process commands
    while (true) {
        const r = @atomicLoad(u32, &input.g_search_cmd_read, .seq_cst);
        const w = @atomicLoad(u32, &input.g_search_cmd_write, .seq_cst);
        if (r == w) break;
        const cmd = input.g_search_cmd_ring[r % 16];
        @atomicStore(u32, &input.g_search_cmd_read, r +% 1, .seq_cst);
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

pub fn generateSearchBar(ctx: *PtyThreadCtx) void {
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
            publish.updateGridTopOffset(ctx);
            // Restore viewport scroll compensation
            if (g_viewport_compensated) {
                publish.ctxEngine(ctx).state.viewport_offset = g_saved_viewport_offset;
                c.g_viewport_offset = @intCast(g_saved_viewport_offset);
                g_viewport_compensated = false;
                c.attyx_mark_all_dirty();
            }
            // Restore statusbar/tab bar that were yielding to search
            publish.generateStatusbar(ctx);
            publish.generateTabBar(ctx);
            publish.publishOverlays(ctx);
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
        // Check if there's already a top-row element that search will replace
        // (must check before updateGridTopOffset resets these flags)
        const had_top_row = (terminal.g_grid_top_offset > 0);
        // Hide statusbar/tab bar — search takes priority for the top row
        if (mgr.isVisible(.statusbar)) mgr.hide(.statusbar);
        if (mgr.isVisible(.tab_bar)) mgr.hide(.tab_bar);
        publish.updateGridTopOffset(ctx);
        g_saved_viewport_offset = publish.ctxEngine(ctx).state.viewport_offset;
        if (!had_top_row and publish.ctxEngine(ctx).state.viewport_offset > 0) {
            publish.ctxEngine(ctx).state.viewport_offset -= 1;
            c.g_viewport_offset = @intCast(publish.ctxEngine(ctx).state.viewport_offset);
            g_viewport_compensated = true;
            c.attyx_mark_all_dirty();
        } else {
            g_viewport_compensated = false;
        }
    }

    // Sync match counts from processSearch results
    g_search_bar.total_matches = @intCast(@as(c_uint, @bitCast(c.g_search_total)));
    g_search_bar.current_match = @intCast(@as(c_uint, @bitCast(c.g_search_current)));

    const grid_cols: u16 = @intCast(publish.ctxEngine(ctx).state.ring.cols);

    const result = overlay_search.layoutSearchBar(
        mgr.allocator,
        grid_cols,
        &g_search_bar,
        .{},
    ) catch return;

    // Search always takes the top row (row 0) — it has highest priority.
    // When a side tab bar is active, it runs full-height through row 0, so
    // the search bar starts after the sidebar's left gutter.
    const search_row: u16 = 0;
    const left_off: u16 = @intCast(@max(0, terminal.g_grid_left_offset));
    mgr.setContent(.search_bar, left_off, search_row, result.width, result.height, result.cells) catch {
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

    publish.publishOverlays(ctx);
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

    // Compute viewport window in absolute row coordinates
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
