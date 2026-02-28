// Attyx — Tab bar overlay generator
//
// Produces a single row of OverlayCells representing the tab bar.
// Each tab shows " title " with separators. Active tab gets distinct colors.

const std = @import("std");
const attyx = @import("attyx");
const OverlayCell = attyx.overlay_mod.OverlayCell;
const Rgb = attyx.overlay_mod.Rgb;

pub const Style = struct {
    bg: Rgb = .{ .r = 30, .g = 30, .b = 40 },
    active_bg: Rgb = .{ .r = 60, .g = 60, .b = 90 },
    fg: Rgb = .{ .r = 140, .g = 140, .b = 160 },
    active_fg: Rgb = .{ .r = 230, .g = 230, .b = 240 },
    bg_alpha: u8 = 230,
};

pub const Result = struct {
    cells: []OverlayCell,
    width: u16,
    height: u16, // always 1
};

/// Generate tab bar overlay cells into a caller-provided buffer.
/// Returns the number of cells written, or null if buffer is too small.
pub fn generate(
    buf: []OverlayCell,
    tab_count: u8,
    active: u8,
    grid_cols: u16,
    style: Style,
) ?Result {
    if (grid_cols == 0 or tab_count == 0) return null;
    const width: u16 = grid_cols;
    if (buf.len < width) return null;

    // Fill entire row with bar background
    for (buf[0..width]) |*cell| {
        cell.* = .{
            .char = ' ',
            .fg = style.fg,
            .bg = style.bg,
            .bg_alpha = style.bg_alpha,
        };
    }

    // Compute tab width: divide evenly, cap at a reasonable max
    const max_tab_width: u16 = 24;
    const available: u16 = width;
    var tab_width: u16 = if (tab_count > 0) available / @as(u16, tab_count) else available;
    if (tab_width > max_tab_width) tab_width = max_tab_width;
    if (tab_width < 5) tab_width = 5; // minimum: " T1 |"

    var col: u16 = 0;
    for (0..tab_count) |i| {
        if (col >= width) break;
        const is_active = (i == active);
        const fg = if (is_active) style.active_fg else style.fg;
        const bg = if (is_active) style.active_bg else style.bg;

        // Format title: "Tab N" (1-indexed)
        var title_buf: [20]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "Tab {d}", .{i + 1}) catch "Tab ?";

        // Write " title " padded to tab_width, then separator
        const content_width = if (col + tab_width <= width) tab_width else width - col;

        // Leading space
        var pos: u16 = 0;
        if (pos < content_width) {
            buf[col + pos] = .{ .char = ' ', .fg = fg, .bg = bg, .bg_alpha = style.bg_alpha };
            pos += 1;
        }

        // Title characters
        for (title) |ch| {
            if (pos >= content_width) break;
            buf[col + pos] = .{ .char = ch, .fg = fg, .bg = bg, .bg_alpha = style.bg_alpha };
            pos += 1;
        }

        // Remaining padding
        while (pos < content_width) : (pos += 1) {
            const ch: u21 = if (pos == content_width - 1 and i + 1 < tab_count) '|' else ' ';
            const sep_fg = if (ch == '|') style.fg else fg;
            buf[col + pos] = .{ .char = ch, .fg = sep_fg, .bg = bg, .bg_alpha = style.bg_alpha };
        }

        col += content_width;
    }

    return .{
        .cells = buf[0..width],
        .width = width,
        .height = 1,
    };
}

/// Given a column position, return the tab index at that column (or null if outside tabs).
pub fn tabIndexAtCol(col: u16, tab_count: u8, grid_cols: u16) ?u8 {
    if (grid_cols == 0 or tab_count == 0) return null;

    const max_tab_width: u16 = 24;
    var tab_width: u16 = grid_cols / @as(u16, tab_count);
    if (tab_width > max_tab_width) tab_width = max_tab_width;
    if (tab_width < 5) tab_width = 5;

    const total_tabs_width = tab_width * @as(u16, tab_count);
    if (col >= total_tabs_width) return null;

    const idx: u8 = @intCast(col / tab_width);
    return if (idx < tab_count) idx else null;
}
