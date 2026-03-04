const std = @import("std");
const overlay = @import("overlay.zig");
const action_mod = @import("action.zig");
const ui = @import("ui.zig");
const ui_render = @import("ui_render.zig");
const OverlayCell = overlay.OverlayCell;
const OverlayStyle = overlay.OverlayStyle;
const Rgb = overlay.Rgb;

pub const LineRange = struct {
    start: u16,
    end: u16,
};

pub const CardResult = struct {
    cells: []OverlayCell,
    width: u16,
    height: u16,
};

/// Wrap `text` into lines of at most `max_width` characters.
/// Returns the number of lines written into `out_lines`.
pub fn wrapText(text: []const u8, max_width: u16, out_lines: []LineRange) u16 {
    if (text.len == 0 or max_width == 0 or out_lines.len == 0) return 0;

    var line_count: u16 = 0;
    var pos: u16 = 0;
    const text_len: u16 = @intCast(@min(text.len, std.math.maxInt(u16)));

    while (pos < text_len and line_count < out_lines.len) {
        const remaining = text_len - pos;
        if (remaining <= max_width) {
            // Check for embedded newlines
            var nl_pos: ?u16 = null;
            for (pos..text_len) |i| {
                if (text[i] == '\n') {
                    nl_pos = @intCast(i);
                    break;
                }
            }
            if (nl_pos) |nl| {
                out_lines[line_count] = .{ .start = pos, .end = nl };
                line_count += 1;
                pos = nl + 1;
                continue;
            }
            out_lines[line_count] = .{ .start = pos, .end = text_len };
            line_count += 1;
            break;
        }

        // Check for newline within this segment
        var nl_pos: ?u16 = null;
        const seg_end = pos + max_width;
        for (pos..seg_end) |i| {
            if (text[i] == '\n') {
                nl_pos = @intCast(i);
                break;
            }
        }
        if (nl_pos) |nl| {
            out_lines[line_count] = .{ .start = pos, .end = nl };
            line_count += 1;
            pos = nl + 1;
            continue;
        }

        // Try to break at last space within max_width
        var break_at: u16 = seg_end;
        var found_space = false;
        var j: u16 = seg_end;
        while (j > pos) {
            j -= 1;
            if (text[j] == ' ') {
                break_at = j;
                found_space = true;
                break;
            }
        }

        out_lines[line_count] = .{ .start = pos, .end = break_at };
        line_count += 1;
        pos = if (found_space) break_at + 1 else break_at;
    }

    return line_count;
}

/// Build a bordered card with wrapped text. Caller owns returned `cells`.
pub fn layoutCard(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_width: u16,
    style: OverlayStyle,
) !CardResult {
    // Content area inside borders + 1-cell padding on each side
    const border_w: u16 = if (style.border) 2 else 0;
    const padding_w: u16 = 2; // 1 cell padding on each side
    const inner_w = if (max_width > border_w + padding_w)
        max_width - border_w - padding_w
    else
        1;

    var line_buf: [128]LineRange = undefined;
    const line_count = wrapText(text, inner_w, &line_buf);
    const content_h = if (line_count > 0) line_count else 1;

    const total_w = inner_w + border_w + padding_w;
    const total_h = content_h + border_w; // top/bottom border rows

    const cell_count: usize = @as(usize, total_w) * @as(usize, total_h);
    const cells = try allocator.alloc(OverlayCell, cell_count);

    // Fill all cells with background
    for (cells) |*cell| {
        cell.* = .{
            .char = ' ',
            .fg = style.fg,
            .bg = style.bg,
            .bg_alpha = style.bg_alpha,
        };
    }

    // Draw border if enabled
    if (style.border) {
        fillBorder(cells, total_w, total_h, style);
    }

    // Fill text content (offset by border + padding)
    const text_col: u16 = if (style.border) 2 else 1; // border + padding
    const text_row: u16 = if (style.border) 1 else 0;
    fillText(cells, total_w, text_col, text_row, line_buf[0..line_count], text, style);

    return .{
        .cells = cells,
        .width = total_w,
        .height = total_h,
    };
}

fn fillBorder(cells: []OverlayCell, width: u16, height: u16, style: OverlayStyle) void {
    const w: usize = width;
    const h: usize = height;
    const bc = style.border_color;

    // Corners
    setCell(cells, 0, 0, w, 0x250C, bc, style); // ┌
    setCell(cells, 0, w - 1, w, 0x2510, bc, style); // ┐
    setCell(cells, h - 1, 0, w, 0x2514, bc, style); // └
    setCell(cells, h - 1, w - 1, w, 0x2518, bc, style); // ┘

    // Top and bottom edges
    for (1..w - 1) |col| {
        setCell(cells, 0, col, w, 0x2500, bc, style); // ─
        setCell(cells, h - 1, col, w, 0x2500, bc, style); // ─
    }

    // Left and right edges
    for (1..h - 1) |row| {
        setCell(cells, row, 0, w, 0x2502, bc, style); // │
        setCell(cells, row, w - 1, w, 0x2502, bc, style); // │
    }
}

fn setCell(cells: []OverlayCell, row: usize, col: usize, width: usize, char: u21, fg: Rgb, style: OverlayStyle) void {
    const idx = row * width + col;
    if (idx >= cells.len) return;
    cells[idx] = .{
        .char = char,
        .fg = fg,
        .bg = style.bg,
        .bg_alpha = style.bg_alpha,
    };
}

fn fillText(
    cells: []OverlayCell,
    stride: u16,
    start_col: u16,
    start_row: u16,
    lines: []const LineRange,
    text: []const u8,
    style: OverlayStyle,
) void {
    for (lines, 0..) |line, li| {
        const row = @as(usize, start_row) + li;
        const line_text = text[line.start..line.end];
        for (line_text, 0..) |ch, ci| {
            const col = @as(usize, start_col) + ci;
            const idx = row * @as(usize, stride) + col;
            if (idx >= cells.len) break;
            cells[idx] = .{
                .char = ch,
                .fg = style.fg,
                .bg = style.bg,
                .bg_alpha = style.bg_alpha,
            };
        }
    }
}

/// Build a debug card with pre-formatted lines. Each line is placed directly,
/// bordered automatically. Title is placed in the top border.
pub fn layoutDebugCard(
    allocator: std.mem.Allocator,
    title: []const u8,
    lines: []const []const u8,
    style: OverlayStyle,
) !CardResult {
    // Compute minimum width to fit title in border
    var min_content_w: u16 = 0;
    for (lines) |line| {
        const len: u16 = @intCast(@min(line.len, std.math.maxInt(u16)));
        min_content_w = @max(min_content_w, len);
    }
    const title_w: u16 = @intCast(@min(title.len, std.math.maxInt(u16)));
    if (title_w + 4 > min_content_w) min_content_w = title_w + 4;

    // Build element tree: bordered box with text children
    const children = try allocator.alloc(ui.Element, lines.len);
    defer allocator.free(children);
    for (lines, 0..) |line, i| {
        children[i] = .{ .text = .{ .content = line, .wrap = false } };
    }

    const theme = themeFromStyle(style);
    const total_w = min_content_w + 4; // border(2) + padding(2)
    const elem = ui.Element{ .box = .{
        .children = children,
        .border = .single,
        .padding = .{ .left = 1, .right = 1 },
        .width = .{ .cells = total_w },
        .style = .{ .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha },
    } };

    const r = try ui_render.renderAlloc(allocator, elem, total_w, theme);
    placeTitle(r.cells, r.result.width, title, style);
    return .{ .cells = r.cells, .width = r.result.width, .height = r.result.height };
}

fn themeFromStyle(style: OverlayStyle) ui.OverlayTheme {
    return .{
        .fg = style.fg,
        .bg = style.bg,
        .bg_alpha = style.bg_alpha,
        .border_color = style.border_color,
    };
}

fn placeTitle(cells: []OverlayCell, width: u16, title_text: []const u8, style: OverlayStyle) void {
    if (title_text.len == 0) return;
    const w: usize = width;
    const title_start: usize = 2;
    setCellFlat(cells, title_start, w, ' ', style.border_color, style);
    for (title_text, 0..) |ch, i| {
        const col = title_start + 1 + i;
        if (col >= w - 1) break;
        setCellFlat(cells, col, w, ch, style.fg, style);
    }
    const after = title_start + 1 + title_text.len;
    if (after < w - 1) {
        setCellFlat(cells, after, w, ' ', style.border_color, style);
    }
}

fn setCellFlat(cells: []OverlayCell, idx: usize, max: usize, char: u21, fg: Rgb, style: OverlayStyle) void {
    if (idx >= max or idx >= cells.len) return;
    cells[idx] = .{ .char = char, .fg = fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
}

pub const ActionBarStyle = struct {
    focused_bg: Rgb = .{ .r = 70, .g = 70, .b = 120 },
    unfocused_bg: Rgb = .{ .r = 40, .g = 40, .b = 55 },
    focused_fg: Rgb = .{ .r = 255, .g = 255, .b = 255 },
    unfocused_fg: Rgb = .{ .r = 160, .g = 160, .b = 160 },
    bracket_fg: Rgb = .{ .r = 100, .g = 100, .b = 140 },
};

/// Fill action bar cells into a row: "  [ Insert ]  [ Copy ]  [ Dismiss ]  "
pub fn fillActionBar(
    cells: []OverlayCell,
    stride: u16,
    row: u16,
    start_col: u16,
    end_col: u16,
    actions: []const action_mod.OverlayAction,
    focused: u8,
    ab_style: ActionBarStyle,
    base_style: OverlayStyle,
) void {
    // Fill entire row with base bg first
    for (start_col..end_col) |col| {
        const idx = @as(usize, row) * @as(usize, stride) + col;
        if (idx >= cells.len) break;
        cells[idx] = .{
            .char = ' ',
            .fg = base_style.fg,
            .bg = base_style.bg,
            .bg_alpha = base_style.bg_alpha,
        };
    }

    var col: u16 = start_col + 1; // start with 1-cell left margin
    for (actions, 0..) |act, ai| {
        if (col + 2 >= end_col) break; // no room
        const is_focused = (ai == focused);
        const fg = if (is_focused) ab_style.focused_fg else ab_style.unfocused_fg;
        const bg = if (is_focused) ab_style.focused_bg else ab_style.unfocused_bg;

        // "[ "
        setActionCell(cells, stride, row, col, '[', ab_style.bracket_fg, bg, base_style.bg_alpha);
        col += 1;
        setActionCell(cells, stride, row, col, ' ', fg, bg, base_style.bg_alpha);
        col += 1;

        // label text
        for (act.label) |ch| {
            if (col >= end_col) break;
            setActionCell(cells, stride, row, col, ch, fg, bg, base_style.bg_alpha);
            col += 1;
        }

        // " ]"
        if (col < end_col) {
            setActionCell(cells, stride, row, col, ' ', fg, bg, base_style.bg_alpha);
            col += 1;
        }
        if (col < end_col) {
            setActionCell(cells, stride, row, col, ']', ab_style.bracket_fg, bg, base_style.bg_alpha);
            col += 1;
        }

        // gap between buttons
        if (col < end_col) {
            col += 1;
        }
    }
}

fn setActionCell(cells: []OverlayCell, stride: u16, row: u16, col: u16, char: u21, fg: Rgb, bg: Rgb, bg_alpha: u8) void {
    const idx = @as(usize, row) * @as(usize, stride) + @as(usize, col);
    if (idx >= cells.len) return;
    cells[idx] = .{ .char = char, .fg = fg, .bg = bg, .bg_alpha = bg_alpha };
}

/// Build a debug card with an action bar row above the bottom border.
/// height = content lines + 2 (borders) + 1 (action row).
pub fn layoutActionCard(
    allocator: std.mem.Allocator,
    title: []const u8,
    lines: []const []const u8,
    style: OverlayStyle,
    action_bar: action_mod.ActionBar,
) !CardResult {
    // Compute minimum width from lines, title, and action bar
    var min_content_w: u16 = 0;
    for (lines) |line| {
        const len: u16 = @intCast(@min(line.len, std.math.maxInt(u16)));
        min_content_w = @max(min_content_w, len);
    }
    const title_w: u16 = @intCast(@min(title.len, std.math.maxInt(u16)));
    if (title_w + 4 > min_content_w) min_content_w = title_w + 4;
    var action_w: u16 = 1;
    for (0..action_bar.count) |i| {
        const label_len: u16 = @intCast(@min(action_bar.actions[i].label.len, std.math.maxInt(u16)));
        action_w += 4 + label_len + 1;
    }
    min_content_w = @max(min_content_w, action_w);

    // Build element tree: bordered box with text children + blank action row
    const child_count = lines.len + 1; // +1 for action bar placeholder
    const children = try allocator.alloc(ui.Element, child_count);
    defer allocator.free(children);
    for (lines, 0..) |line, i| {
        children[i] = .{ .text = .{ .content = line, .wrap = false } };
    }
    children[lines.len] = .{ .text = .{ .content = " ", .wrap = false } }; // action bar row

    const theme = themeFromStyle(style);
    const total_w = min_content_w + 4;
    const elem = ui.Element{ .box = .{
        .children = children,
        .border = .single,
        .padding = .{ .left = 1, .right = 1 },
        .width = .{ .cells = total_w },
        .style = .{ .fg = style.fg, .bg = style.bg, .bg_alpha = style.bg_alpha },
    } };

    const r = try ui_render.renderAlloc(allocator, elem, total_w, theme);
    placeTitle(r.cells, r.result.width, title, style);

    // Fill action bar in the second-to-last row
    const content_h: u16 = @intCast(lines.len);
    const action_row: u16 = content_h + 1;
    fillActionBar(
        r.cells,
        r.result.width,
        action_row,
        1,
        r.result.width - 1,
        action_bar.actions[0..action_bar.count],
        action_bar.focused,
        .{},
        style,
    );

    return .{ .cells = r.cells, .width = r.result.width, .height = r.result.height };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "wrapText: single line" {
    var lines: [8]LineRange = undefined;
    const count = wrapText("Hello", 20, &lines);
    try std.testing.expectEqual(@as(u16, 1), count);
    try std.testing.expectEqual(@as(u16, 0), lines[0].start);
    try std.testing.expectEqual(@as(u16, 5), lines[0].end);
}

test "wrapText: newlines" {
    var lines: [8]LineRange = undefined;
    const count = wrapText("abc\ndef\nghi", 20, &lines);
    try std.testing.expectEqual(@as(u16, 3), count);
    try std.testing.expectEqual(@as(u16, 0), lines[0].start);
    try std.testing.expectEqual(@as(u16, 3), lines[0].end);
    try std.testing.expectEqual(@as(u16, 4), lines[1].start);
    try std.testing.expectEqual(@as(u16, 7), lines[1].end);
}

test "wrapText: word break" {
    var lines: [8]LineRange = undefined;
    const count = wrapText("hello world foo", 10, &lines);
    try std.testing.expectEqual(@as(u16, 2), count);
}

test "layoutCard: basic dimensions" {
    const result = try layoutCard(std.testing.allocator, "Hello", 28, .{});
    defer std.testing.allocator.free(result.cells);
    // With border (2) + padding (2) + content = 28 width (inner = 24)
    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height >= 3); // top border + content + bottom border
    try std.testing.expectEqual(@as(usize, @as(usize, result.width) * result.height), result.cells.len);
}

test "layoutDebugCard: title and lines" {
    const debug_lines = [_][]const u8{
        "Grid: 80x24",
        "Cursor: 0,0",
    };
    const result = try layoutDebugCard(std.testing.allocator, "Debug", &debug_lines, .{});
    defer std.testing.allocator.free(result.cells);
    try std.testing.expectEqual(@as(u16, 4), result.height); // border + 2 lines + border
    try std.testing.expect(result.width >= 15); // at least fits content + borders
}

test "layoutActionCard: dimensions include action row" {
    var bar = action_mod.ActionBar{};
    bar.add(.dismiss, "Dismiss");

    const card_lines = [_][]const u8{
        "Line 1",
        "Line 2",
    };
    const result = try layoutActionCard(std.testing.allocator, "Test", &card_lines, .{}, bar);
    defer std.testing.allocator.free(result.cells);

    // height = top border + 2 content + action row + bottom border = 5
    try std.testing.expectEqual(@as(u16, 5), result.height);
    try std.testing.expect(result.width >= 10);
    try std.testing.expectEqual(@as(usize, @as(usize, result.width) * result.height), result.cells.len);
}

test "layoutActionCard: focused cell has correct bg color" {
    var bar = action_mod.ActionBar{};
    bar.add(.dismiss, "Dismiss");
    bar.add(.copy, "Copy");

    const card_lines = [_][]const u8{"Test"};
    const result = try layoutActionCard(std.testing.allocator, "Card", &card_lines, .{}, bar);
    defer std.testing.allocator.free(result.cells);

    // Action row is at row index 2 (top border=0, content=1, action=2, bottom border=3)
    const action_row: usize = 2;
    const ab_style = ActionBarStyle{};

    // Find a bracket '[' in the action row — it should exist
    var found_bracket = false;
    for (1..result.width - 1) |col| {
        const idx = action_row * @as(usize, result.width) + col;
        if (result.cells[idx].char == '[') {
            found_bracket = true;
            // First bracket belongs to focused action (index 0)
            try std.testing.expectEqual(ab_style.focused_bg.r, result.cells[idx].bg.r);
            try std.testing.expectEqual(ab_style.focused_bg.g, result.cells[idx].bg.g);
            try std.testing.expectEqual(ab_style.focused_bg.b, result.cells[idx].bg.b);
            break;
        }
    }
    try std.testing.expect(found_bracket);
}

test "fillActionBar: bracket chars present" {
    var cells: [40]OverlayCell = undefined;
    for (&cells) |*cell| cell.* = .{};

    var bar = action_mod.ActionBar{};
    bar.add(.dismiss, "OK");
    fillActionBar(&cells, 20, 0, 0, 20, bar.actions[0..bar.count], bar.focused, .{}, .{});

    // Scan for '[' and ']'
    var found_open = false;
    var found_close = false;
    for (cells[0..20]) |cell| {
        if (cell.char == '[') found_open = true;
        if (cell.char == ']') found_close = true;
    }
    try std.testing.expect(found_open);
    try std.testing.expect(found_close);
}
