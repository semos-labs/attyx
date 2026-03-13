// Windows copy mode — vi-style keyboard selection and clipboard copy.
// Extracted from windows_stubs.zig to respect the 600-line limit.
// Uses the Engine ring buffer for attyx_copy_selection (same as selection.zig).

const std = @import("std");
const attyx = @import("attyx");
const keybinds = @import("../config/keybinds.zig");
const logging = @import("../logging/log.zig");
const stubs = @import("windows_stubs.zig");

const c = @cImport({
    @cInclude("bridge.h");
});

const Cell = attyx.grid.Cell;

// ---------------------------------------------------------------------------
// Exported globals (consumed by renderer / C platform code)
// ---------------------------------------------------------------------------

pub export var g_copy_mode: c_int = 0;
pub export var g_copy_cursor_row: c_int = 0;
pub export var g_copy_cursor_col: c_int = 0;
pub export var g_sel_block: c_int = 0;

pub export var g_copy_search_active: c_int = 0;
pub export var g_copy_search_dir: c_int = 1;
pub export var g_copy_search_buf: [128]u8 = .{0} ** 128;
pub export var g_copy_search_len: c_int = 0;
pub export var g_copy_search_dirty: c_int = 0;

// ---------------------------------------------------------------------------
// Copy mode state
// ---------------------------------------------------------------------------

const CopyMode = enum(c_int) { off = 0, navigate = 1, vchar = 2, vline = 3, vblock = 4 };

const CopyState = struct {
    mode: CopyMode = .off,
    cr: i32 = 0,
    cc: i32 = 0,
    ar: i32 = 0,
    ac: i32 = 0,
    pr: i32 = 0,
    pc: i32 = 0,
    ph: i32 = 0,
    pw: i32 = 0,
    pending_count: u16 = 0,
};

var cs: CopyState = .{};

// Search state
const SEARCH_MAX = 128;
var search_buf: [SEARCH_MAX]u8 = .{0} ** SEARCH_MAX;
var search_len: u16 = 0;
var search_input_active: bool = false;
var search_direction: i32 = 1;
var last_search_len: u16 = 0;
var last_search_dir: i32 = 1;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn gcols() i32 { return if (c.g_cols > 0) c.g_cols else 1; }
fn grows() i32 { return if (c.g_rows > 0) c.g_rows else 1; }
fn vrows() i32 { const v = grows() - c.g_grid_top_offset - c.g_grid_bottom_offset; return if (v > 0) v else 1; }
fn pw() i32 { return if (cs.pw > 0) cs.pw else gcols(); }
fn ph() i32 { return if (cs.ph > 0) cs.ph else vrows(); }

fn syncCopy() void {
    g_copy_mode = @intFromEnum(cs.mode);
    g_copy_cursor_row = cs.cr + cs.pr;
    g_copy_cursor_col = cs.cc + cs.pc;
}

fn csIsVisual() bool {
    return cs.mode == .vchar or cs.mode == .vline or cs.mode == .vblock;
}

fn clampCS() void {
    cs.cc = @min(@max(cs.cc, 0), pw() - 1);
    cs.cr = @min(@max(cs.cr, 0), ph() - 1);
}

fn csMove(dr: i32, dc: i32) void {
    cs.cr += dr;
    cs.cc += dc;
    const rows = ph();
    if (cs.cr < 0) {
        const scroll = -cs.cr;
        if (c.g_viewport_offset + scroll <= c.g_scrollback_count) {
            c.attyx_scroll_viewport(scroll);
            if (csIsVisual()) cs.ar += scroll;
        }
        cs.cr = 0;
    } else if (cs.cr >= rows) {
        const scroll = cs.cr - rows + 1;
        if (c.g_viewport_offset - scroll >= 0) {
            c.attyx_scroll_viewport(-scroll);
            if (csIsVisual()) cs.ar -= scroll;
        }
        cs.cr = rows - 1;
    }
}

fn csToggleVisual(target: CopyMode) void {
    if (cs.mode == target) {
        cs.mode = .navigate;
        c.g_sel_active = 0;
        g_sel_block = 0;
    } else if (csIsVisual()) {
        cs.mode = target;
        g_sel_block = if (target == .vblock) @as(c_int, 1) else 0;
    } else {
        cs.mode = target;
        cs.ar = cs.cr;
        cs.ac = cs.cc;
        g_sel_block = if (target == .vblock) @as(c_int, 1) else 0;
    }
}

fn csUpdateSel() void {
    const pr = cs.pr;
    const pc = cs.pc;
    switch (cs.mode) {
        .vchar => {
            c.g_sel_start_row = cs.ar + pr;
            c.g_sel_start_col = cs.ac + pc;
            c.g_sel_end_row = cs.cr + pr;
            c.g_sel_end_col = cs.cc + pc;
            c.g_sel_active = 1;
            g_sel_block = 0;
        },
        .vline => {
            c.g_sel_start_row = @min(cs.ar, cs.cr) + pr;
            c.g_sel_start_col = pc;
            c.g_sel_end_row = @max(cs.ar, cs.cr) + pr;
            c.g_sel_end_col = pc + cs.pw - 1;
            c.g_sel_active = 1;
            g_sel_block = 0;
        },
        .vblock => {
            c.g_sel_start_row = @min(cs.ar, cs.cr) + pr;
            c.g_sel_start_col = @min(cs.ac, cs.cc) + pc;
            c.g_sel_end_row = @max(cs.ar, cs.cr) + pr;
            c.g_sel_end_col = @max(cs.ac, cs.cc) + pc;
            c.g_sel_active = 1;
            g_sel_block = 1;
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

fn syncSearchGlobals() void {
    g_copy_search_active = if (search_input_active) @as(c_int, 1) else 0;
    g_copy_search_dir = search_direction;
    g_copy_search_len = @intCast(search_len);
    @memcpy(g_copy_search_buf[0..search_len], search_buf[0..search_len]);
    g_copy_search_dirty = 1;
}

fn startSearch(dir: i32) void {
    search_input_active = true;
    search_direction = dir;
    search_len = 0;
    syncSearchGlobals();
    c.attyx_mark_all_dirty();
}

fn cancelSearch() void {
    search_input_active = false;
    search_len = 0;
    g_copy_search_active = 0;
    g_copy_search_dirty = 1;
    c.attyx_mark_all_dirty();
}

fn commitSearch() void {
    search_input_active = false;
    g_copy_search_active = 0;
    g_copy_search_dirty = 1;
    if (search_len == 0) { c.attyx_mark_all_dirty(); return; }
    last_search_len = search_len;
    last_search_dir = search_direction;
    executeSearch(search_direction);
    c.attyx_mark_all_dirty();
}

fn searchNext(dir_mult: i32) void {
    if (last_search_len == 0) return;
    search_len = last_search_len;
    executeSearch(last_search_dir * dir_mult);
}

fn executeSearch(dir: i32) void {
    const pcols = pw();
    const prows = ph();
    if (pcols <= 0 or prows <= 0) return;
    const cells: ?[*]const c.AttyxCell = @ptrCast(c.g_cells);
    const cell_ptr = cells orelse return;
    const qlen: usize = @intCast(search_len);
    if (qlen == 0) return;
    const upcols: usize = @intCast(pcols);
    const uprows: usize = @intCast(prows);
    const grid_cols: usize = @intCast(gcols());
    const pr: usize = @intCast(@max(cs.pr, 0));
    const pc: usize = @intCast(@max(cs.pc, 0));
    var found_row: i32 = 0;
    var found_col: i32 = 0;
    var found = false;
    if (dir > 0) {
        var iters: usize = 0;
        var r: usize = @intCast(@max(cs.cr, 0));
        var cc: usize = @intCast(@min(@max(cs.cc + 1, 0), pcols - 1));
        while (iters < uprows * upcols) : (iters += 1) {
            if (r >= uprows) { r = 0; cc = 0; }
            if (matchAt(cell_ptr, r + pr, cc + pc, grid_cols, qlen)) {
                found = true;
                found_row = @intCast(r);
                found_col = @intCast(cc);
                break;
            }
            cc += 1;
            if (cc >= upcols) { cc = 0; r += 1; }
        }
    } else {
        var iters: usize = 0;
        var r: i32 = cs.cr;
        var cc: i32 = cs.cc - 1;
        if (cc < 0) { cc = pcols - 1; r -= 1; }
        if (r < 0) { r = prows - 1; cc = pcols - 1; }
        while (iters < uprows * upcols) : (iters += 1) {
            if (r < 0) { r = prows - 1; cc = pcols - 1; }
            if (matchAt(cell_ptr, @intCast(@as(i32, @intCast(pr)) + r), @intCast(@as(i32, @intCast(pc)) + cc), grid_cols, qlen)) {
                found = true;
                found_row = r;
                found_col = cc;
                break;
            }
            cc -= 1;
            if (cc < 0) { cc = pcols - 1; r -= 1; }
        }
    }
    if (found) {
        cs.cr = found_row;
        cs.cc = found_col;
        clampCS();
        syncCopy();
        if (csIsVisual()) csUpdateSel();
    }
}

fn matchAt(cells: [*]const c.AttyxCell, abs_row: usize, abs_col: usize, grid_cols: usize, qlen: usize) bool {
    const base = abs_row * grid_cols + abs_col;
    for (0..qlen) |i| {
        const ch = cells[base + i].character;
        const qch: u32 = search_buf[i];
        const cl = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
        const ql = if (qch >= 'A' and qch <= 'Z') qch + 32 else qch;
        if (cl != ql) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Export: enter / exit / key
// ---------------------------------------------------------------------------

pub export fn attyx_copy_mode_enter() void {
    if (c.g_alt_screen != 0) return;
    cs = .{
        .mode = .navigate,
        .cr = c.g_cursor_row - c.g_grid_top_offset - c.g_pane_rect_row,
        .cc = c.g_cursor_col - c.g_pane_rect_col,
        .pr = c.g_pane_rect_row,
        .pc = c.g_pane_rect_col,
        .ph = if (c.g_pane_rect_rows > 0) c.g_pane_rect_rows else vrows(),
        .pw = if (c.g_pane_rect_cols > 0) c.g_pane_rect_cols else gcols(),
    };
    syncCopy();
    c.g_sel_active = 0;
    g_sel_block = 0;
    c.g_cursor_visible = 0;
    c.attyx_mark_all_dirty();
}

pub export fn attyx_copy_mode_exit(keep_sel: c_int) void {
    cs.mode = .off;
    g_sel_block = 0;
    search_input_active = false;
    g_copy_search_active = 0;
    g_copy_search_len = 0;
    g_copy_search_dirty = 1;
    syncCopy();
    if (keep_sel == 0) c.g_sel_active = 0;
    c.g_cursor_visible = 1;
    c.g_viewport_offset = 0;
    c.attyx_mark_all_dirty();
}

pub export fn attyx_copy_mode_key(key: u16, mods: u8, codepoint: u32) u8 {
    if (cs.mode == .off) return 0;
    const ctrl = (mods & keybinds.MOD_CTRL) != 0;
    const is_cp = (key == keybinds.KC_CODEPOINT);

    // Search input mode
    if (search_input_active) {
        if (key == keybinds.KC_ESCAPE) { cancelSearch(); return 1; }
        if (key == keybinds.KC_ENTER or key == keybinds.KC_KP_ENTER) { commitSearch(); return 1; }
        if (key == keybinds.KC_BACKSPACE) {
            if (search_len > 0) { search_len -= 1; syncSearchGlobals(); c.attyx_mark_all_dirty(); }
            return 1;
        }
        if (is_cp and codepoint >= 32 and codepoint < 127 and search_len < SEARCH_MAX - 1) {
            search_buf[search_len] = @intCast(codepoint);
            search_len += 1;
            syncSearchGlobals();
            c.attyx_mark_all_dirty();
        }
        return 1;
    }

    if (key == keybinds.KC_ESCAPE) {
        if (cs.mode != .navigate) {
            cs.mode = .navigate;
            c.g_sel_active = 0;
            g_sel_block = 0;
        } else {
            attyx_copy_mode_exit(0);
            return 1;
        }
    } else if (is_cp and !ctrl) {
        // Numeric prefix accumulation
        if (codepoint >= '1' and codepoint <= '9') {
            const d: u16 = @intCast(codepoint - '0');
            cs.pending_count = if (cs.pending_count > 6553) 9999 else cs.pending_count * 10 + d;
            return 1;
        }
        if (codepoint == '0' and cs.pending_count > 0) {
            cs.pending_count = if (cs.pending_count > 6553) 9999 else cs.pending_count * 10;
            return 1;
        }
        const count: i32 = if (cs.pending_count > 0) @intCast(cs.pending_count) else 1;
        cs.pending_count = 0;
        switch (codepoint) {
            'h' => csMove(0, -count),
            'j' => csMove(count, 0),
            'k' => csMove(-count, 0),
            'l' => csMove(0, count),
            '0' => { cs.cc = 0; },
            '$' => { cs.cc = pw() - 1; },
            'G' => {
                const sa = c.g_viewport_offset;
                if (sa > 0) { c.attyx_scroll_viewport(-sa); if (csIsVisual()) cs.ar -= sa; }
                cs.cr = ph() - 1;
                cs.cc = 0;
            },
            'g' => {
                const sa = c.g_scrollback_count - c.g_viewport_offset;
                if (sa > 0) { c.attyx_scroll_viewport(sa); if (csIsVisual()) cs.ar += sa; }
                cs.cr = 0;
                cs.cc = 0;
            },
            'v' => csToggleVisual(.vchar),
            'V' => csToggleVisual(.vline),
            'y' => {
                if (csIsVisual()) { yankSelection(); attyx_copy_mode_exit(0); }
                return 1;
            },
            '/' => { startSearch(1); return 1; },
            '?' => { startSearch(-1); return 1; },
            'n' => { searchNext(1); clampCS(); syncCopy(); if (csIsVisual()) csUpdateSel(); c.attyx_mark_all_dirty(); return 1; },
            'N' => { searchNext(-1); clampCS(); syncCopy(); if (csIsVisual()) csUpdateSel(); c.attyx_mark_all_dirty(); return 1; },
            'q' => { attyx_copy_mode_exit(0); return 1; },
            else => {},
        }
    } else if (ctrl and is_cp) {
        switch (codepoint) {
            'v', 'V' => csToggleVisual(.vblock),
            'u', 'U' => { const h: i32 = @max(@divTrunc(ph(), 2), 1); csMove(-h, 0); },
            'd', 'D' => { const h: i32 = @max(@divTrunc(ph(), 2), 1); csMove(h, 0); },
            'b', 'B' => csMove(-ph(), 0),
            'f', 'F' => csMove(ph(), 0),
            else => {},
        }
    } else {
        switch (key) {
            keybinds.KC_UP => csMove(-1, 0),
            keybinds.KC_DOWN => csMove(1, 0),
            keybinds.KC_LEFT => csMove(0, -1),
            keybinds.KC_RIGHT => csMove(0, 1),
            keybinds.KC_HOME => { cs.cc = 0; },
            keybinds.KC_END => { cs.cc = pw() - 1; },
            keybinds.KC_PAGE_UP => csMove(-ph(), 0),
            keybinds.KC_PAGE_DOWN => csMove(ph(), 0),
            else => {},
        }
    }

    clampCS();
    syncCopy();
    if (csIsVisual()) csUpdateSel();
    c.attyx_mark_all_dirty();
    return 1;
}

// ---------------------------------------------------------------------------
// Yank / copy selection — reads from Engine ring buffer
// ---------------------------------------------------------------------------

fn yankSelection() void {
    copySelectionImpl(g_sel_block != 0);
}

pub export fn attyx_copy_selection() void {
    if (c.g_sel_active == 0) return;
    copySelectionImpl(false);
}

fn copySelectionImpl(is_block: bool) void {
    const eng = stubs.g_engine orelse return;
    const ring = &eng.state.ring;
    const eng_cols: i32 = @intCast(ring.cols);
    if (eng_cols <= 0) return;
    const vp = c.g_viewport_offset;
    const sb_count: i32 = @intCast(ring.scrollbackCount());
    const grid_rows: i32 = @intCast(ring.screen_rows);
    const total_lines = sb_count + grid_rows;
    if (total_lines <= 0) return;

    // Read and normalize selection bounds (viewport-relative).
    var sr: i32 = c.g_sel_start_row;
    var sc: i32 = c.g_sel_start_col;
    var er: i32 = c.g_sel_end_row;
    var ec: i32 = c.g_sel_end_col;
    if (c.g_split_active != 0 and c.g_pane_rect_rows > 0) {
        sr -= c.g_pane_rect_row;
        er -= c.g_pane_rect_row;
        sc -= c.g_pane_rect_col;
        ec -= c.g_pane_rect_col;
    }
    if (sr > er or (sr == er and sc > ec)) {
        const tr = sr;
        const tc = sc;
        sr = er;
        sc = ec;
        er = tr;
        ec = tc;
    }

    // Convert viewport-relative to absolute line indices.
    const abs_sr = @max(0, @min(sb_count - vp + sr, total_lines - 1));
    const abs_er = @max(0, @min(sb_count - vp + er, total_lines - 1));

    var buf: [65536]u8 = undefined;
    var pos: usize = 0;

    var abs_row = abs_sr;
    while (abs_row <= abs_er) : (abs_row += 1) {
        const line_cells: []const Cell = if (abs_row < sb_count + grid_rows)
            ring.getRow(@intCast(abs_row))
        else
            continue;

        const is_first = (abs_row == abs_sr);
        const is_last = (abs_row == abs_er);
        const col_start = if (is_block) @min(sc, eng_cols - 1) else if (is_first) sc else 0;
        const col_end = if (is_block) @min(ec, eng_cols - 1) else if (is_last) ec else eng_cols - 1;

        // Find last non-space column to trim trailing whitespace.
        var last_ns = col_start - 1;
        {
            var ci = col_end;
            while (ci >= col_start) : (ci -= 1) {
                if (line_cells[@intCast(ci)].char > 32) { last_ns = ci; break; }
                if (ci == 0) break;
            }
        }

        var ci = col_start;
        while (ci <= @min(last_ns, col_end)) : (ci += 1) {
            const cell = line_cells[@intCast(ci)];
            const ch = cell.char;
            if (ch == 0 or ch == ' ') {
                if (pos < buf.len) { buf[pos] = ' '; pos += 1; }
            } else {
                pos += utf8Encode(ch, buf[pos..]);
                for (0..2) |k| {
                    const cm = cell.combining[k];
                    if (cm == 0) break;
                    pos += utf8Encode(cm, buf[pos..]);
                }
            }
        }

        // Newline between rows (respect soft-wrap).
        if (abs_row < abs_er) {
            const wrapped = ring.getWrapped(@intCast(abs_row));
            if (is_block or !wrapped) {
                if (pos < buf.len) { buf[pos] = '\n'; pos += 1; }
            }
        }
    }

    if (pos > 0) {
        c.attyx_clipboard_copy(@ptrCast(&buf), @intCast(pos));
        logging.info("selection", "copied {d} bytes", .{pos});
    }
}

fn utf8Encode(cp: u32, out: []u8) usize {
    if (out.len == 0) return 0;
    if (cp < 0x80) { out[0] = @intCast(cp); return 1; }
    if (cp < 0x800) {
        if (out.len < 2) return 0;
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        if (out.len < 3) return 0;
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    if (out.len < 4) return 0;
    out[0] = @intCast(0xF0 | (cp >> 18));
    out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    out[3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}
