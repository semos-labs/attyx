/// Scrollback-aware selection copy — shared by mouse selection and copy mode.
const std = @import("std");
const attyx = @import("attyx");
const terminal = @import("../terminal.zig");
const c = terminal.c;
const logging = @import("../../logging/log.zig");

const Cell = attyx.grid.Cell;

/// Copy the current selection (g_sel_*) to the clipboard, reading from
/// the unified ring buffer. Selection rows are viewport-relative
/// (content-space, with g_grid_top_offset already subtracted).
pub fn copySelection(is_block: bool) void {
    const eng = terminal.g_engine orelse return;
    const ring = &eng.state.ring;
    const eng_cols: i32 = @intCast(ring.cols);
    if (eng_cols <= 0) return;
    const vp = c.g_viewport_offset;
    const sb_count: i32 = @intCast(ring.scrollbackCount());
    const grid_rows: i32 = @intCast(ring.screen_rows);
    const total_lines = sb_count + grid_rows;
    if (total_lines <= 0) return;

    // Read and normalize selection bounds (viewport-relative).
    // In split mode, coords are in global content-space — convert to pane-local.
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

    // Convert viewport-relative rows to absolute line indices:
    // absolute = sb_count - viewport_offset + viewport_row
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
        const cs = if (is_block) @min(sc, eng_cols - 1) else if (is_first) sc else 0;
        const ce = if (is_block) @min(ec, eng_cols - 1) else if (is_last) ec else eng_cols - 1;

        // Find last non-space column to trim trailing whitespace
        var last_ns = cs - 1;
        {
            var ci = ce;
            while (ci >= cs) : (ci -= 1) {
                if (line_cells[@intCast(ci)].char > 32) {
                    last_ns = ci;
                    break;
                }
                if (ci == 0) break;
            }
        }

        var ci = cs;
        while (ci <= @min(last_ns, ce)) : (ci += 1) {
            const cell = line_cells[@intCast(ci)];
            const ch = cell.char;
            if (ch == 0 or ch == ' ') {
                if (pos < buf.len) {
                    buf[pos] = ' ';
                    pos += 1;
                }
            } else {
                pos += utf8Encode(ch, buf[pos..]);
                for (0..2) |k| {
                    const cm = cell.combining[k];
                    if (cm == 0) break;
                    pos += utf8Encode(cm, buf[pos..]);
                }
            }
        }

        // Add newline between rows (respect soft-wrap)
        if (abs_row < abs_er) {
            const wrapped = ring.getWrapped(@intCast(abs_row));
            if (is_block or !wrapped) {
                if (pos < buf.len) {
                    buf[pos] = '\n';
                    pos += 1;
                }
            }
        }
    }

    if (pos > 0) {
        c.attyx_clipboard_copy(@ptrCast(&buf), @intCast(pos));
        logging.info("selection", "copied {d} bytes", .{pos});
    }
}

/// Called from C platform code to copy mouse selection to clipboard.
pub export fn attyx_copy_selection() void {
    if (c.g_sel_active == 0) return;
    copySelection(false);
}

fn utf8Encode(cp: u32, out: []u8) usize {
    if (out.len == 0) return 0;
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    }
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
