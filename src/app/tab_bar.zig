// Attyx — Tab bar overlay generator
//
// Produces a single row of StyledCell values representing the tab bar.
// Each tab shows " title  N " with the active tab's number highlighted.

const std = @import("std");
const attyx = @import("attyx");
const StyledCell = attyx.overlay_mod.StyledCell;
const Rgb = attyx.overlay_mod.Rgb;
const tab_manager = @import("tab_manager.zig");
pub const max_tabs = tab_manager.max_tabs;

pub const Style = struct {
    tab_bg: Rgb = .{ .r = 50, .g = 50, .b = 58 },
    fg: Rgb = .{ .r = 140, .g = 140, .b = 160 },
    num_highlight_bg: Rgb = .{ .r = 90, .g = 90, .b = 100 },
    num_highlight_fg: Rgb = .{ .r = 230, .g = 230, .b = 240 },
    bg_alpha: u8 = 230,
};

pub const Result = struct {
    cells: []StyledCell,
    width: u16,
    height: u16, // always 1
};

/// Per-tab title, resolved by the caller (OSC title or process name).
pub const TabTitles = [max_tabs]?[]const u8;

/// Cached per-tab widths written by generate(), read by tabIndexAtCol().
var cached_widths: [max_tabs]u16 = .{0} ** max_tabs;
var cached_count: u8 = 0;

/// Decode the next UTF-8 codepoint from `s[i..*]`, advancing `i`.
/// Skips invalid bytes gracefully, returning 0xFFFD (replacement char).
fn nextCodepoint(s: []const u8, i: *usize) ?u21 {
    if (i.* >= s.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(s[i.*]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    if (i.* + len > s.len) {
        i.* = s.len;
        return 0xFFFD;
    }
    const cp = std.unicode.utf8Decode(s[i.*..][0..len]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    i.* += len;
    return cp;
}

/// Count display columns for a UTF-8 string (1 column per codepoint).
fn displayWidth(s: []const u8) u16 {
    var i: usize = 0;
    var count: u16 = 0;
    while (nextCodepoint(s, &i) != null) count += 1;
    return count;
}

/// Number of digits in a 1-indexed tab number.
fn numLen(n: u8) u16 {
    return if (n >= 10) 2 else 1;
}

/// Compute the natural width for a tab: " title " + " N " = (1+title+1) + (1+numlen+1).
/// When zoomed, prepend "⊞ " (2 extra columns).
fn tabWidth(title_len: u16, tab_number: u8, zoomed: bool) u16 {
    const zoom_extra: u16 = if (zoomed) 2 else 0;
    return 1 + zoom_extra + title_len + 1 + 1 + numLen(tab_number) + 1;
}

/// Resolve the title for tab `i`, writing fallback into `fallback_buf`.
fn resolveTitle(titles: *const TabTitles, i: usize, fallback_buf: *[20]u8) []const u8 {
    return titles[i] orelse
        (std.fmt.bufPrint(fallback_buf, "Tab {d}", .{i + 1}) catch "Tab ?");
}

/// Generate tab bar overlay cells into a caller-provided buffer.
/// Returns the number of cells written, or null if buffer is too small.
/// `titles` provides per-tab display names; falls back to "Tab N" when null.
/// `zoomed_tabs` is a bitmask: if bit i is set, tab i shows a zoom indicator.
pub fn generate(
    buf: []StyledCell,
    tab_count: u8,
    active: u8,
    grid_cols: u16,
    style: Style,
    titles: *const TabTitles,
    zoomed_tabs: u16,
) ?Result {
    if (grid_cols == 0 or tab_count == 0) return null;
    const width: u16 = grid_cols;
    if (buf.len < width) return null;

    // Fill entire row with transparent background
    for (buf[0..width]) |*cell| {
        cell.* = .{
            .char = ' ',
            .fg = style.fg,
            .bg = .{ .r = 0, .g = 0, .b = 0 },
            .bg_alpha = 0,
        };
    }

    // Compute content-based widths and cache them for tabIndexAtCol().
    var fallback_bufs: [max_tabs][20]u8 = undefined;
    var resolved: [max_tabs][]const u8 = undefined;
    var widths: [max_tabs]u16 = undefined;
    for (0..tab_count) |i| {
        resolved[i] = resolveTitle(titles, i, &fallback_bufs[i]);
        const is_zoomed = (zoomed_tabs & (@as(u16, 1) << @intCast(i))) != 0;
        widths[i] = tabWidth(displayWidth(resolved[i]), @intCast(i + 1), is_zoomed);
    }
    @memcpy(cached_widths[0..tab_count], widths[0..tab_count]);
    cached_count = tab_count;

    // Format each tab number (1-indexed) into a small buffer.
    var num_bufs: [max_tabs][3]u8 = undefined;
    var num_slices: [max_tabs][]const u8 = undefined;
    for (0..tab_count) |i| {
        num_slices[i] = std.fmt.bufPrint(&num_bufs[i], "{d}", .{i + 1}) catch "?";
    }

    var col: u16 = 0;
    for (0..tab_count) |i| {
        if (col >= width) break;
        const is_active = (i == active);
        const natural_width = widths[i];
        const content_width = if (col + natural_width <= width) natural_width else width - col;

        const title = resolved[i];
        const num = num_slices[i];

        // Number area: double-space + digits + trailing space — all use num bg for active
        const n_fg = if (is_active) style.num_highlight_fg else style.fg;
        const n_bg = if (is_active) style.num_highlight_bg else style.tab_bg;

        var pos: u16 = 0;

        // Title area: " title " — tab_bg (with optional zoom icon)
        if (pos < content_width) {
            buf[col + pos] = .{ .char = ' ', .fg = style.fg, .bg = style.tab_bg, .bg_alpha = style.bg_alpha };
            pos += 1;
        }
        // Zoom indicator: "⊞ " before title
        {
            const tab_zoomed = (zoomed_tabs & (@as(u16, 1) << @intCast(i))) != 0;
            if (tab_zoomed) {
                if (pos < content_width) {
                    buf[col + pos] = .{ .char = 0x229E, .fg = style.fg, .bg = style.tab_bg, .bg_alpha = style.bg_alpha }; // ⊞
                    pos += 1;
                }
                if (pos < content_width) {
                    buf[col + pos] = .{ .char = ' ', .fg = style.fg, .bg = style.tab_bg, .bg_alpha = style.bg_alpha };
                    pos += 1;
                }
            }
        }
        {
            var ti: usize = 0;
            while (nextCodepoint(title, &ti)) |cp| {
                if (pos >= content_width) break;
                buf[col + pos] = .{ .char = cp, .fg = style.fg, .bg = style.tab_bg, .bg_alpha = style.bg_alpha };
                pos += 1;
            }
        }
        if (pos < content_width) {
            buf[col + pos] = .{ .char = ' ', .fg = style.fg, .bg = style.tab_bg, .bg_alpha = style.bg_alpha };
            pos += 1;
        }

        // Number area: " N " — leading space + digits + trailing space
        if (pos < content_width) {
            buf[col + pos] = .{ .char = ' ', .fg = n_fg, .bg = n_bg, .bg_alpha = style.bg_alpha };
            pos += 1;
        }
        for (num) |ch| {
            if (pos >= content_width) break;
            buf[col + pos] = .{ .char = ch, .fg = n_fg, .bg = n_bg, .bg_alpha = style.bg_alpha };
            pos += 1;
        }
        while (pos < content_width) : (pos += 1) {
            buf[col + pos] = .{ .char = ' ', .fg = n_fg, .bg = n_bg, .bg_alpha = style.bg_alpha };
        }

        col += content_width;

        // 1-cell gap between tabs (bar background, not part of any tab)
        if (i + 1 < tab_count and col < width) {
            buf[col] = .{ .char = ' ', .fg = style.fg, .bg = .{ .r = 0, .g = 0, .b = 0 }, .bg_alpha = 0 };
            col += 1;
        }
    }

    return .{
        .cells = buf[0..width],
        .width = width,
        .height = 1,
    };
}

/// Given a column position, return the tab index at that column (or null if outside tabs
/// or on a gap between tabs).
pub fn tabIndexAtCol(col: u16, tab_count: u8, grid_cols: u16) ?u8 {
    if (grid_cols == 0 or tab_count == 0) return null;

    const count = @min(tab_count, cached_count);
    var offset: u16 = 0;
    for (0..count) |i| {
        const w = cached_widths[i];
        if (col >= offset and col < offset + w) return @intCast(i);
        offset += w;
        // Skip the 1-cell gap between tabs
        if (i + 1 < count) offset += 1;
        if (offset >= grid_cols) break;
    }
    return null;
}

// ===========================================================================
// Tests
// ===========================================================================

const no_titles: TabTitles = .{null} ** max_tabs;

test "generate: null on 0 cols" {
    var buf: [100]StyledCell = undefined;
    try std.testing.expect(generate(&buf, 2, 0, 0, .{}, &no_titles, 0) == null);
}

test "generate: null on 0 tabs" {
    var buf: [100]StyledCell = undefined;
    try std.testing.expect(generate(&buf, 0, 0, 40, .{}, &no_titles, 0) == null);
}

test "generate: null on small buffer" {
    var buf: [5]StyledCell = undefined;
    try std.testing.expect(generate(&buf, 1, 0, 10, .{}, &no_titles, 0) == null);
}

test "generate: tab layout is ' title ' + ' N '" {
    var buf: [80]StyledCell = undefined;
    const style = Style{};
    var titles: TabTitles = .{null} ** max_tabs;
    titles[0] = "vim";
    // " vim " + " 1 " = (1+3+1) + (1+1+1) = 5 + 3 = 8
    const result = generate(&buf, 1, 0, 80, style, &titles, 0) orelse return error.TestUnexpectedResult;
    // Title area: " vim " — tab_bg
    try std.testing.expectEqual(@as(u21, ' '), result.cells[0].char);
    try std.testing.expectEqual(style.tab_bg, result.cells[0].bg);
    try std.testing.expectEqual(@as(u21, 'v'), result.cells[1].char);
    try std.testing.expectEqual(@as(u21, 'i'), result.cells[2].char);
    try std.testing.expectEqual(@as(u21, 'm'), result.cells[3].char);
    try std.testing.expectEqual(@as(u21, ' '), result.cells[4].char); // trailing space
    try std.testing.expectEqual(style.tab_bg, result.cells[4].bg);
    // Number area: " 1 " — num_highlight_bg (active)
    try std.testing.expectEqual(@as(u21, ' '), result.cells[5].char);
    try std.testing.expectEqual(style.num_highlight_bg, result.cells[5].bg);
    try std.testing.expectEqual(@as(u21, '1'), result.cells[6].char);
    try std.testing.expectEqual(style.num_highlight_bg, result.cells[6].bg);
    try std.testing.expectEqual(@as(u21, ' '), result.cells[7].char);
    try std.testing.expectEqual(style.num_highlight_bg, result.cells[7].bg);
}

test "generate: inactive number area uses tab_bg, active uses num_highlight_bg" {
    var buf: [80]StyledCell = undefined;
    const style = Style{};
    var titles: TabTitles = .{null} ** max_tabs;
    titles[0] = "zsh";
    titles[1] = "vim";
    // Each tab: " xxx " + " N " = 5 + 3 = 8, gap at 8, tab 1 starts at 9
    const result = generate(&buf, 2, 1, 80, style, &titles, 0) orelse return error.TestUnexpectedResult;

    // Tab 0 (inactive) — title area tab_bg
    try std.testing.expectEqual(style.tab_bg, result.cells[0].bg);
    // Tab 0 number area (cols 5-7) — inactive, tab_bg
    try std.testing.expectEqual(style.tab_bg, result.cells[5].bg);
    try std.testing.expectEqual(style.tab_bg, result.cells[6].bg);
    try std.testing.expectEqual(style.fg, result.cells[6].fg);

    // Gap at col 8 — transparent
    try std.testing.expectEqual(@as(u8, 0), result.cells[8].bg_alpha);

    // Tab 1 (active) — title area tab_bg
    try std.testing.expectEqual(style.tab_bg, result.cells[9].bg);
    // Tab 1 number area (cols 14-16) — active, highlighted
    try std.testing.expectEqual(style.num_highlight_bg, result.cells[14].bg);
    try std.testing.expectEqual(style.num_highlight_bg, result.cells[15].bg);
    try std.testing.expectEqual(style.num_highlight_fg, result.cells[15].fg);
    try std.testing.expectEqual(style.num_highlight_bg, result.cells[16].bg);
}

test "generate: two-digit tab numbers" {
    // tabWidth: 1 + title + 1 + 1 + numlen + 1
    // tab 10 (2 digits), title=1: 1+1+1+1+2+1 = 7
    try std.testing.expectEqual(@as(u16, 7), tabWidth(1, 10, false));
    // tab 1 (1 digit), title=1: 1+1+1+1+1+1 = 6
    try std.testing.expectEqual(@as(u16, 6), tabWidth(1, 1, false));
}

test "generate: gap between tabs is transparent" {
    var buf: [80]StyledCell = undefined;
    const style = Style{};
    var titles: TabTitles = .{null} ** max_tabs;
    titles[0] = "a";
    titles[1] = "b";
    // Tab 0: " a " + " 1 " = 3+3 = 6, gap at 6, Tab 1 starts at 7
    _ = generate(&buf, 2, 0, 80, style, &titles, 0) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(u8, 0), buf[6].bg_alpha);
    try std.testing.expectEqual(style.tab_bg, buf[7].bg);
}

test "tabIndexAtCol: variable width tabs with gaps" {
    var buf: [80]StyledCell = undefined;
    var titles: TabTitles = .{null} ** max_tabs;
    titles[0] = "vim"; // " vim " + " 1 " = 5+3 = 8
    titles[1] = "long-process"; // " long-process " + " 2 " = 14+3 = 17
    titles[2] = "zsh"; // " zsh " + " 3 " = 5+3 = 8
    _ = generate(&buf, 3, 0, 80, .{}, &titles, 0) orelse return error.TestUnexpectedResult;

    // Tab 0: cols 0..7
    try std.testing.expectEqual(@as(?u8, 0), tabIndexAtCol(0, 3, 80));
    try std.testing.expectEqual(@as(?u8, 0), tabIndexAtCol(7, 3, 80));
    // Gap at col 8
    try std.testing.expectEqual(@as(?u8, null), tabIndexAtCol(8, 3, 80));
    // Tab 1: cols 9..25
    try std.testing.expectEqual(@as(?u8, 1), tabIndexAtCol(9, 3, 80));
    try std.testing.expectEqual(@as(?u8, 1), tabIndexAtCol(25, 3, 80));
    // Gap at col 26
    try std.testing.expectEqual(@as(?u8, null), tabIndexAtCol(26, 3, 80));
    // Tab 2: cols 27..34
    try std.testing.expectEqual(@as(?u8, 2), tabIndexAtCol(27, 3, 80));
    try std.testing.expectEqual(@as(?u8, 2), tabIndexAtCol(34, 3, 80));
    // Beyond all tabs
    try std.testing.expectEqual(@as(?u8, null), tabIndexAtCol(35, 3, 80));
}

test "generate: utf-8 title renders codepoints not bytes" {
    var buf: [80]StyledCell = undefined;
    var titles: TabTitles = .{null} ** max_tabs;
    // "café" = 4 codepoints (5 bytes: c a f 0xC3 0xA9)
    titles[0] = "caf\xc3\xa9";
    // displayWidth = 4, tab = " café " + " 1 " = 6 + 3 = 9
    const result = generate(&buf, 1, 0, 80, .{}, &titles, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u21, 'c'), result.cells[1].char);
    try std.testing.expectEqual(@as(u21, 'a'), result.cells[2].char);
    try std.testing.expectEqual(@as(u21, 'f'), result.cells[3].char);
    try std.testing.expectEqual(@as(u21, 0xe9), result.cells[4].char); // é as single codepoint
    try std.testing.expectEqual(@as(u21, ' '), result.cells[5].char); // trailing space of title
}

test "tabIndexAtCol: null on 0 cols or 0 tabs" {
    try std.testing.expectEqual(@as(?u8, null), tabIndexAtCol(0, 0, 40));
    try std.testing.expectEqual(@as(?u8, null), tabIndexAtCol(0, 2, 0));
}
