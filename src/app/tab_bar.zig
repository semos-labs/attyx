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

// ===========================================================================
// Tests
// ===========================================================================

test "generate: null on 0 cols" {
    var buf: [100]OverlayCell = undefined;
    try std.testing.expect(generate(&buf, 2, 0, 0, .{}) == null);
}

test "generate: null on 0 tabs" {
    var buf: [100]OverlayCell = undefined;
    try std.testing.expect(generate(&buf, 0, 0, 40, .{}) == null);
}

test "generate: null on small buffer" {
    var buf: [5]OverlayCell = undefined;
    try std.testing.expect(generate(&buf, 1, 0, 10, .{}) == null);
}

test "generate: single tab fills width" {
    var buf: [20]OverlayCell = undefined;
    const result = generate(&buf, 1, 0, 20, .{}) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 20), result.width);
    try std.testing.expectEqual(@as(u16, 1), result.height);
    // First cell should be a space (leading padding)
    try std.testing.expectEqual(@as(u21, ' '), result.cells[0].char);
}

test "generate: separator pipes between tabs" {
    var buf: [80]OverlayCell = undefined;
    const style = Style{};
    const result = generate(&buf, 3, 0, 60, style) orelse return error.TestUnexpectedResult;

    // Tab width = 60/3 = 20 (capped at 24). Last cell of first tab should be '|'
    const tab_width: u16 = 20;
    try std.testing.expectEqual(@as(u21, '|'), result.cells[tab_width - 1].char);
}

test "generate: active tab uses highlight colors" {
    var buf: [80]OverlayCell = undefined;
    const style = Style{};
    const result = generate(&buf, 2, 1, 40, style) orelse return error.TestUnexpectedResult;

    // Tab 0 (inactive) should use default bg
    try std.testing.expectEqual(style.bg, result.cells[0].bg);
    // Tab 1 (active) — first cell of second tab should use active_bg
    const tab_width: u16 = 20;
    try std.testing.expectEqual(style.active_bg, result.cells[tab_width].bg);
}

test "tabIndexAtCol: correct index per column" {
    // 3 tabs, 60 cols → tab_width = 20
    try std.testing.expectEqual(@as(?u8, 0), tabIndexAtCol(0, 3, 60));
    try std.testing.expectEqual(@as(?u8, 0), tabIndexAtCol(19, 3, 60));
    try std.testing.expectEqual(@as(?u8, 1), tabIndexAtCol(20, 3, 60));
    try std.testing.expectEqual(@as(?u8, 2), tabIndexAtCol(40, 3, 60));
}

test "tabIndexAtCol: null beyond tabs" {
    // 2 tabs, 60 cols → tab_width = 24 (capped), total = 48
    try std.testing.expectEqual(@as(?u8, null), tabIndexAtCol(48, 2, 60));
}

test "tabIndexAtCol: null on 0 cols or 0 tabs" {
    try std.testing.expectEqual(@as(?u8, null), tabIndexAtCol(0, 0, 40));
    try std.testing.expectEqual(@as(?u8, null), tabIndexAtCol(0, 2, 0));
}

test "tab width capping: max 24" {
    // 1 tab, 100 cols → tab_width capped at 24
    var buf: [100]OverlayCell = undefined;
    const default_style = Style{};
    const result = generate(&buf, 1, 0, 100, default_style) orelse return error.TestUnexpectedResult;

    // Active tab content should only span first 24 cells with tab content
    // (the rest is bar background). Check that cell 24 has bar bg, not active bg.
    try std.testing.expectEqual(default_style.bg, result.cells[24].bg);
}

test "tab width capping: min 5" {
    // 10 tabs, 20 cols → 20/10 = 2 < 5, so tab_width = 5
    try std.testing.expectEqual(@as(?u8, 0), tabIndexAtCol(0, 10, 20));
    try std.testing.expectEqual(@as(?u8, 0), tabIndexAtCol(4, 10, 20));
    try std.testing.expectEqual(@as(?u8, 1), tabIndexAtCol(5, 10, 20));
}
