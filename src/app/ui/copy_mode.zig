// Copy/Visual mode (tmux-like keyboard selection)
const std = @import("std");
const attyx = @import("attyx");
const terminal = @import("../terminal.zig");
const c = terminal.c;
const keybinds = @import("../../config/keybinds.zig");
const logging = @import("../../logging/log.zig");
pub const CopyMode = enum(c_int) { off = 0, navigate = 1, visual_char = 2, visual_line = 3, visual_block = 4 };
const State = struct {
    mode: CopyMode = .off,
    cursor_row: i32 = 0,
    cursor_col: i32 = 0,
    anchor_row: i32 = 0,
    anchor_col: i32 = 0,
    pending_count: u16 = 0,
    pending_g: bool = false,
    pane_row: i32 = 0,
    pane_col: i32 = 0,
    pane_rows: i32 = 0,
    pane_cols: i32 = 0,
};

var state: State = .{};
var pending_text_object: ?TextObjectKind = null;
const TextObjectKind = enum { inner, around };
const WordMotion = enum { forward_start, forward_end, backward_start };

const SEARCH_MAX = 128;
var search_buf: [SEARCH_MAX]u8 = .{0} ** SEARCH_MAX;
var search_len: u16 = 0;
var search_input_active: bool = false;
var search_direction: i32 = 1;
var last_search_len: u16 = 0;
var last_search_dir: i32 = 1;

pub export var g_copy_mode: c_int = 0;
pub export var g_copy_cursor_row: c_int = 0;
pub export var g_copy_cursor_col: c_int = 0;
pub export var g_sel_block: c_int = 0;

pub export var g_copy_search_active: c_int = 0;
pub export var g_copy_search_dir: c_int = 1;
pub export var g_copy_search_buf: [SEARCH_MAX]u8 = .{0} ** SEARCH_MAX;
pub export var g_copy_search_len: c_int = 0;
pub export var g_copy_search_dirty: c_int = 0;

pub export fn attyx_copy_mode_enter() void {
    if (c.g_alt_screen != 0) return;
    const pr = c.g_pane_rect_row;
    const pc = c.g_pane_rect_col;
    state = .{
        .mode = .navigate,
        .cursor_row = c.g_cursor_row - c.g_grid_top_offset - pr,
        .cursor_col = c.g_cursor_col - pc,
        .pane_row = pr,
        .pane_col = pc,
        .pane_rows = if (c.g_pane_rect_rows > 0) c.g_pane_rect_rows else getVisibleRows(),
        .pane_cols = if (c.g_pane_rect_cols > 0) c.g_pane_rect_cols else getCols(),
    };
    syncGlobals();
    c.g_sel_active = 0;
    g_sel_block = 0;
    c.g_cursor_visible = 0;
    c.attyx_mark_all_dirty();
    logging.info("copy_mode", "entered navigate at row={d} col={d}", .{ state.cursor_row, state.cursor_col });
}

pub export fn attyx_copy_mode_exit(keep_selection: c_int) void {
    state.mode = .off;
    g_sel_block = 0;
    search_input_active = false;
    g_copy_search_active = 0;
    g_copy_search_len = 0;
    g_copy_search_dirty = 1;
    syncGlobals();
    if (keep_selection == 0) c.g_sel_active = 0;
    c.g_cursor_visible = 1;
    c.g_viewport_offset = 0;
    c.attyx_mark_all_dirty();
}

pub export fn attyx_copy_mode_key(key: u16, mods: u8, codepoint: u32) u8 {
    if (state.mode == .off) return 0;
    const ctrl = (mods & keybinds.MOD_CTRL) != 0;
    const is_cp = (key == keybinds.KC_CODEPOINT);

    if (search_input_active) {
        if (key == keybinds.KC_ESCAPE) {
            cancelSearch();
            return 1;
        }
        if (key == keybinds.KC_ENTER or key == keybinds.KC_KP_ENTER) {
            commitSearch();
            return 1;
        }
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
        if (state.mode != .navigate) {
            state.mode = .navigate;
            c.g_sel_active = 0;
            g_sel_block = 0;
            state.pending_count = 0;
            syncGlobals();
            c.attyx_mark_all_dirty();
        } else {
            attyx_copy_mode_exit(0);
        }
        return 1;
    }

    // Numeric prefix
    if (is_cp and !ctrl) {
        if (codepoint >= '1' and codepoint <= '9') {
            state.pending_g = false;
            const d: u16 = @intCast(codepoint - '0');
            state.pending_count = if (state.pending_count > 6553) 9999 else state.pending_count * 10 + d;
            return 1;
        }
        if (codepoint == '0' and state.pending_count > 0) {
            state.pending_g = false;
            state.pending_count = if (state.pending_count > 6553) 9999 else state.pending_count * 10;
            return 1;
        }
    }

    const count = if (state.pending_count > 0) state.pending_count else @as(u16, 1);
    var consumed = false;

    if (is_cp and !ctrl and pending_text_object != null) {
        consumed = checkPendingTextObject(codepoint);
        if (!consumed) pending_text_object = null;
    } else if (is_cp and !ctrl) {
        consumed = handleCodepoint(codepoint, count);
    } else if (ctrl and is_cp) {
        consumed = handleCtrlCodepoint(codepoint);
    } else {
        consumed = handleSpecialKey(key, count);
    }

    if (consumed) {
        state.pending_count = 0;
        clampCursor();
        syncGlobals();
        if (isVisual()) updateSelection();
        c.attyx_mark_all_dirty();
    }
    return 1; // consume all keys in copy mode
}

fn handleCodepoint(cp: u32, count: u16) bool {
    switch (cp) {
        'h' => moveCursor(0, -@as(i32, count)),
        'j' => moveCursor(@as(i32, count), 0),
        'k' => moveCursor(-@as(i32, count), 0),
        'l' => moveCursor(0, @as(i32, count)),
        'w' => moveWord(count, .forward_start),
        'b' => moveWord(count, .backward_start),
        'e' => moveWord(count, .forward_end),
        '0' => { state.cursor_col = 0; },
        '$' => { state.cursor_col = paneCols() - 1; },
        '^' => moveToFirstNonBlank(),
        'g' => {
            if (state.pending_g) { state.pending_g = false; moveToTop(); } else { state.pending_g = true; return true; }
        },
        'G' => moveToBottom(),
        'v' => toggleVisualMode(.visual_char),
        'V' => toggleVisualMode(.visual_line),
        'y' => { if (isVisual()) { yankSelection(); attyx_copy_mode_exit(0); } return true; },
        '/' => { startSearch(1); return true; },
        '?' => { startSearch(-1); return true; },
        'n' => { searchNext(1); return true; },
        'N' => { searchNext(-1); return true; },
        'i' => { if (!isVisual()) return false; pending_text_object = .inner; return true; },
        'a' => { if (!isVisual()) return false; pending_text_object = .around; return true; },
        else => return false,
    }
    state.pending_g = false;
    return true;
}

fn handleCtrlCodepoint(cp: u32) bool {
    switch (cp) {
        'v', 'V' => { toggleVisualMode(.visual_block); return true; },
        'u', 'U' => { const h: i32 = @max(@divTrunc(paneRows(), 2), 1); moveCursor(-h, 0); return true; },
        'd', 'D' => { const h: i32 = @max(@divTrunc(paneRows(), 2), 1); moveCursor(h, 0); return true; },
        'b', 'B' => { moveCursor(-paneRows(), 0); return true; },
        'f', 'F' => { moveCursor(paneRows(), 0); return true; },
        else => return false,
    }
}

fn handleSpecialKey(key: u16, count: u16) bool {
    switch (key) {
        keybinds.KC_UP => moveCursor(-@as(i32, count), 0),
        keybinds.KC_DOWN => moveCursor(@as(i32, count), 0),
        keybinds.KC_LEFT => moveCursor(0, -@as(i32, count)),
        keybinds.KC_RIGHT => moveCursor(0, @as(i32, count)),
        keybinds.KC_HOME => { state.cursor_col = 0; },
        keybinds.KC_END => { state.cursor_col = paneCols() - 1; },
        keybinds.KC_PAGE_UP => moveCursor(-paneRows(), 0),
        keybinds.KC_PAGE_DOWN => moveCursor(paneRows(), 0),
        else => return false,
    }
    return true;
}

fn toggleVisualMode(target: CopyMode) void {
    if (state.mode == target) {
        state.mode = .navigate;
        c.g_sel_active = 0;
        g_sel_block = 0;
    } else if (isVisual()) {
        state.mode = target;
        g_sel_block = if (target == .visual_block) @as(c_int, 1) else 0;
    } else {
        state.mode = target;
        state.anchor_row = state.cursor_row;
        state.anchor_col = state.cursor_col;
        g_sel_block = if (target == .visual_block) @as(c_int, 1) else 0;
    }
}

fn checkPendingTextObject(cp: u32) bool {
    const kind = pending_text_object orelse return false;
    pending_text_object = null;
    if (cp != 'w') return false;
    selectWord(kind);
    return true;
}

fn selectWord(kind: TextObjectKind) void {
    const pcols = paneCols();
    if (pcols <= 0) return;
    const cells = getCells() orelse return;
    const row = state.cursor_row;
    if (row < 0 or row >= paneRows()) return;
    const base: usize = @intCast((row + state.pane_row) * getCols() + state.pane_col);
    const col: usize = @intCast(@min(@max(state.cursor_col, 0), pcols - 1));
    const target = isWordCharZ(cells[base + col].character);
    var start: usize = col;
    while (start > 0 and isWordCharZ(cells[base + start - 1].character) == target) start -= 1;
    var end: usize = col;
    const upcols: usize = @intCast(pcols);
    while (end < upcols - 1 and isWordCharZ(cells[base + end + 1].character) == target) end += 1;
    if (kind == .around) {
        while (end < upcols - 1) {
            const next_ch = cells[base + end + 1].character;
            if (next_ch != 0 and next_ch != ' ') break;
            end += 1;
        }
    }
    state.anchor_row = row;
    state.anchor_col = @intCast(start);
    state.cursor_col = @intCast(end);
}

fn moveCursor(drow: i32, dcol: i32) void {
    state.cursor_row += drow;
    state.cursor_col += dcol;
    const rows = paneRows();
    if (state.cursor_row < 0) {
        const scroll = -state.cursor_row;
        if (c.g_viewport_offset + scroll <= c.g_scrollback_count) {
            c.attyx_scroll_viewport(scroll);
            if (isVisual()) state.anchor_row += scroll;
            state.cursor_row = 0;
        } else {
            const ms = c.g_scrollback_count - c.g_viewport_offset;
            if (ms > 0) { c.attyx_scroll_viewport(ms); if (isVisual()) state.anchor_row += ms; }
            state.cursor_row = 0;
        }
    } else if (state.cursor_row >= rows) {
        const scroll = state.cursor_row - rows + 1;
        if (c.g_viewport_offset - scroll >= 0) {
            c.attyx_scroll_viewport(-scroll);
            if (isVisual()) state.anchor_row -= scroll;
            state.cursor_row = rows - 1;
        } else {
            const ms = c.g_viewport_offset;
            if (ms > 0) { c.attyx_scroll_viewport(-ms); if (isVisual()) state.anchor_row -= ms; }
            state.cursor_row = rows - 1;
        }
    }
}

fn moveWord(count: u16, direction: WordMotion) void {
    const pcols = paneCols();
    if (pcols <= 0) return;
    const cells = getCells() orelse return;
    const prows = paneRows();
    var n: u16 = 0;
    while (n < count) : (n += 1) {
        const row = state.cursor_row;
        if (row < 0 or row >= prows) break;
        const base: usize = @intCast((row + state.pane_row) * getCols() + state.pane_col);
        const col: usize = @intCast(@min(@max(state.cursor_col, 0), pcols - 1));
        const upcols: usize = @intCast(pcols);
        switch (direction) {
            .forward_start => {
                var pos = col;
                const cw = isWordCharZ(cells[base + pos].character);
                while (pos < upcols - 1 and isWordCharZ(cells[base + pos].character) == cw) pos += 1;
                while (pos < upcols - 1 and !isWordCharZ(cells[base + pos].character)) pos += 1;
                state.cursor_col = @intCast(pos);
            },
            .forward_end => {
                var pos = col;
                if (pos < upcols - 1) pos += 1;
                while (pos < upcols - 1 and !isWordCharZ(cells[base + pos].character)) pos += 1;
                while (pos < upcols - 1 and isWordCharZ(cells[base + pos + 1].character)) pos += 1;
                state.cursor_col = @intCast(pos);
            },
            .backward_start => {
                var pos = col;
                if (pos > 0) pos -= 1;
                while (pos > 0 and !isWordCharZ(cells[base + pos].character)) pos -= 1;
                while (pos > 0 and isWordCharZ(cells[base + pos - 1].character)) pos -= 1;
                state.cursor_col = @intCast(pos);
            },
        }
    }
}

fn moveToFirstNonBlank() void {
    const pcols = paneCols();
    if (pcols <= 0) return;
    const cells = getCells() orelse return;
    const row = state.cursor_row;
    if (row < 0 or row >= paneRows()) return;
    const base: usize = @intCast((row + state.pane_row) * getCols() + state.pane_col);
    var col: i32 = 0;
    while (col < pcols) : (col += 1) {
        const ch = cells[base + @as(usize, @intCast(col))].character;
        if (ch != 0 and ch != ' ') break;
    }
    state.cursor_col = @min(col, pcols - 1);
}

fn moveToTop() void {
    const sa = c.g_scrollback_count - c.g_viewport_offset;
    if (sa > 0) { c.attyx_scroll_viewport(sa); if (isVisual()) state.anchor_row += sa; }
    state.cursor_row = 0;
    state.cursor_col = 0;
}

fn moveToBottom() void {
    const sa = c.g_viewport_offset;
    if (sa > 0) { c.attyx_scroll_viewport(-sa); if (isVisual()) state.anchor_row -= sa; }
    state.cursor_row = paneRows() - 1;
    state.cursor_col = 0;
}

fn updateSelection() void {
    const pr = state.pane_row;
    const pc = state.pane_col;
    switch (state.mode) {
        .visual_char => {
            c.g_sel_start_row = state.anchor_row + pr;
            c.g_sel_start_col = state.anchor_col + pc;
            c.g_sel_end_row = state.cursor_row + pr;
            c.g_sel_end_col = state.cursor_col + pc;
            c.g_sel_active = 1;
            g_sel_block = 0;
        },
        .visual_line => {
            c.g_sel_start_row = @min(state.anchor_row, state.cursor_row) + pr;
            c.g_sel_start_col = pc;
            c.g_sel_end_row = @max(state.anchor_row, state.cursor_row) + pr;
            c.g_sel_end_col = pc + state.pane_cols - 1;
            c.g_sel_active = 1;
            g_sel_block = 0;
        },
        .visual_block => {
            c.g_sel_start_row = @min(state.anchor_row, state.cursor_row) + pr;
            c.g_sel_start_col = @min(state.anchor_col, state.cursor_col) + pc;
            c.g_sel_end_row = @max(state.anchor_row, state.cursor_row) + pr;
            c.g_sel_end_col = @max(state.anchor_col, state.cursor_col) + pc;
            c.g_sel_active = 1;
            g_sel_block = 1;
        },
        else => {},
    }
}

fn yankSelection() void {
    const sel = @import("selection.zig");
    sel.copySelection(g_sel_block != 0);
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
    const pcols = paneCols();
    const prows = paneRows();
    if (pcols <= 0 or prows <= 0) return;
    const cells = getCells() orelse return;
    const qlen: usize = @intCast(search_len);
    if (qlen == 0) return;
    const upcols: usize = @intCast(pcols);
    const uprows: usize = @intCast(prows);
    const grid_cols: usize = @intCast(getCols());
    const pr: usize = @intCast(state.pane_row);
    const pc: usize = @intCast(state.pane_col);
    var found_row: i32 = 0;
    var found_col: i32 = 0;
    var found = false;
    if (dir > 0) {
        var iters: usize = 0;
        var r: usize = @intCast(@max(state.cursor_row, 0));
        var cc: usize = @intCast(@min(@max(state.cursor_col + 1, 0), pcols - 1));
        while (iters < uprows * upcols) : (iters += 1) {
            if (r >= uprows) { r = 0; cc = 0; }
            if (matchAt(cells, r + pr, cc + pc, grid_cols, qlen)) { found = true; found_row = @intCast(r); found_col = @intCast(cc); break; }
            cc += 1;
            if (cc >= upcols) { cc = 0; r += 1; }
        }
    } else {
        var iters: usize = 0;
        var r: i32 = state.cursor_row;
        var cc: i32 = state.cursor_col - 1;
        if (cc < 0) { cc = pcols - 1; r -= 1; }
        if (r < 0) { r = prows - 1; cc = pcols - 1; }
        while (iters < uprows * upcols) : (iters += 1) {
            if (r < 0) { r = prows - 1; cc = pcols - 1; }
            if (matchAt(cells, @intCast(@as(i32, @intCast(pr)) + r), @intCast(@as(i32, @intCast(pc)) + cc), grid_cols, qlen)) { found = true; found_row = r; found_col = cc; break; }
            cc -= 1;
            if (cc < 0) { cc = pcols - 1; r -= 1; }
        }
    }
    if (found) {
        state.cursor_row = found_row;
        state.cursor_col = found_col;
        clampCursor();
        syncGlobals();
        if (isVisual()) updateSelection();
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

fn syncSearchGlobals() void {
    g_copy_search_active = if (search_input_active) @as(c_int, 1) else 0;
    g_copy_search_dir = search_direction;
    g_copy_search_len = @intCast(search_len);
    @memcpy(g_copy_search_buf[0..search_len], search_buf[0..search_len]);
    g_copy_search_dirty = 1;
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

fn isVisual() bool {
    return state.mode == .visual_char or state.mode == .visual_line or state.mode == .visual_block;
}

fn syncGlobals() void {
    g_copy_mode = @intFromEnum(state.mode);
    g_copy_cursor_row = state.cursor_row + state.pane_row;
    g_copy_cursor_col = state.cursor_col + state.pane_col;
}

fn clampCursor() void {
    const cols = paneCols();
    const rows = paneRows();
    if (state.cursor_col < 0) state.cursor_col = 0;
    if (state.cursor_col >= cols) state.cursor_col = cols - 1;
    if (state.cursor_row < 0) state.cursor_row = 0;
    if (state.cursor_row >= rows) state.cursor_row = rows - 1;
}

fn getCols() i32 { return if (c.g_cols > 0) c.g_cols else 1; }
fn getRows() i32 { return if (c.g_rows > 0) c.g_rows else 1; }
fn getVisibleRows() i32 {
    const v = getRows() - c.g_grid_top_offset - c.g_grid_bottom_offset;
    return if (v > 0) v else 1;
}
fn paneCols() i32 { return if (state.pane_cols > 0) state.pane_cols else getCols(); }
fn paneRows() i32 { return if (state.pane_rows > 0) state.pane_rows else getVisibleRows(); }
fn getCells() ?[*]const c.AttyxCell { return @as(?[*]const c.AttyxCell, c.g_cells); }

fn isWordCharZ(ch: u32) bool {
    if (ch == 0 or ch == ' ') return false;
    if (ch == '_' or ch == '-') return true;
    if (ch > 127) return true;
    if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9')) return true;
    return false;
}
