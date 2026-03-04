// Attyx — Panel component
// A pure rendering component that wraps an Element tree into a centered,
// bordered, popup-like panel and produces an StyledCell buffer with cursor info.

const std = @import("std");
const ui = @import("ui.zig");
const ui_render = @import("ui_render.zig");
const ui_cell = @import("ui_cell.zig");

const StyledCell = ui.StyledCell;
const Rgb = ui.Rgb;
const Element = ui.Element;
const SizeValue = ui.SizeValue;
const BorderStyle = ui.BorderStyle;
const OverlayTheme = ui.OverlayTheme;

pub const PanelConfig = struct {
    title: []const u8 = "",
    width: SizeValue = .{ .percent = 60 },
    height: SizeValue = .{ .percent = 50 },
    border: BorderStyle = .rounded,
    theme: OverlayTheme = .{},
};

pub const PanelResult = struct {
    cells: []StyledCell, // caller owns, must free
    width: u16,
    height: u16,
    col: u16, // centered grid position
    row: u16,
    cursor_col: ?u16 = null, // absolute grid coords
    cursor_row: ?u16 = null,
};

pub fn renderPanel(
    allocator: std.mem.Allocator,
    config: PanelConfig,
    content: Element,
    grid_cols: u16,
    grid_rows: u16,
) !PanelResult {
    const panel_w = config.width.resolve(grid_cols);
    const panel_h = config.height.resolve(grid_rows);

    if (panel_w < 3 or panel_h < 3) {
        return .{
            .cells = &.{},
            .width = 0,
            .height = 0,
            .col = 0,
            .row = 0,
        };
    }

    // Wrap content in a bordered box with horizontal padding
    const wrapper = Element{ .box = .{
        .children = &[_]Element{content},
        .border = config.border,
        .padding = ui.Padding.symmetric(0, 1),
        .width = .{ .cells = panel_w },
        .height = .{ .cells = panel_h },
        .style = .{
            .fg = config.theme.fg,
            .bg = config.theme.bg,
            .bg_alpha = config.theme.bg_alpha,
        },
    } };

    const r = try ui_render.renderAlloc(allocator, wrapper, panel_w, config.theme);
    const cells = r.cells;
    const rr = r.result;

    if (rr.width == 0 or rr.height == 0) {
        return .{
            .cells = &.{},
            .width = 0,
            .height = 0,
            .col = 0,
            .row = 0,
        };
    }

    // Place title into the top border row
    placeTitle(cells, rr.width, config.title, config.theme);

    // Center on grid
    const col = if (grid_cols > rr.width) (grid_cols - rr.width) / 2 else 0;
    const row = if (grid_rows > rr.height) (grid_rows - rr.height) / 2 else 0;

    // Offset cursor coords to absolute grid position
    const cursor_col: ?u16 = if (rr.cursor_col) |cc| cc + col else null;
    const cursor_row: ?u16 = if (rr.cursor_row) |cr| cr + row else null;

    return .{
        .cells = cells,
        .width = rr.width,
        .height = rr.height,
        .col = col,
        .row = row,
        .cursor_col = cursor_col,
        .cursor_row = cursor_row,
    };
}

fn placeTitle(cells: []StyledCell, width: u16, title: []const u8, theme: OverlayTheme) void {
    if (title.len == 0 or width < 5) return;
    const w: usize = width;
    const start: usize = 2; // after corner + one position
    // Space before title
    setCellAt(cells, start, w, ' ', theme.border_color, theme);
    // Title characters
    for (title, 0..) |ch, i| {
        const col = start + 1 + i;
        if (col >= w - 1) break;
        setCellAt(cells, col, w, ch, theme.fg, theme);
    }
    // Space after title
    const after = start + 1 + title.len;
    if (after < w - 1) {
        setCellAt(cells, after, w, ' ', theme.border_color, theme);
    }
}

fn setCellAt(cells: []StyledCell, idx: usize, max: usize, char: u21, fg: Rgb, theme: OverlayTheme) void {
    if (idx >= max or idx >= cells.len) return;
    cells[idx] = .{ .char = char, .fg = fg, .bg = theme.bg, .bg_alpha = theme.bg_alpha };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "panel: basic dimensions and centering" {
    const config = PanelConfig{
        .width = .{ .cells = 20 },
        .height = .{ .cells = 10 },
        .border = .single,
    };
    const content = Element{ .text = .{ .content = "Hello", .wrap = false } };
    const result = try renderPanel(std.testing.allocator, config, content, 80, 24);
    defer std.testing.allocator.free(result.cells);

    try std.testing.expectEqual(@as(u16, 20), result.width);
    try std.testing.expectEqual(@as(u16, 10), result.height);
    // Centered: (80 - 20) / 2 = 30
    try std.testing.expectEqual(@as(u16, 30), result.col);
    // Centered: (24 - 10) / 2 = 7
    try std.testing.expectEqual(@as(u16, 7), result.row);
}

test "panel: percent-based sizing" {
    const config = PanelConfig{
        .width = .{ .percent = 50 },
        .height = .{ .percent = 50 },
    };
    const content = Element{ .text = .{ .content = "Test" } };
    const result = try renderPanel(std.testing.allocator, config, content, 80, 24);
    defer std.testing.allocator.free(result.cells);

    try std.testing.expectEqual(@as(u16, 40), result.width);
    try std.testing.expectEqual(@as(u16, 12), result.height);
    // Centered: (80 - 40) / 2 = 20
    try std.testing.expectEqual(@as(u16, 20), result.col);
    // Centered: (24 - 12) / 2 = 6
    try std.testing.expectEqual(@as(u16, 6), result.row);
}

test "panel: title placement in border row" {
    const config = PanelConfig{
        .title = "My Panel",
        .width = .{ .cells = 30 },
        .height = .{ .cells = 5 },
        .border = .rounded,
    };
    const content = Element{ .text = .{ .content = "Body" } };
    const result = try renderPanel(std.testing.allocator, config, content, 80, 24);
    defer std.testing.allocator.free(result.cells);

    // Title starts at col 3 (index 3) after "corner space"
    // Index 2 = space, index 3 = 'M', index 4 = 'y', ...
    try std.testing.expectEqual(@as(u21, ' '), result.cells[2].char);
    try std.testing.expectEqual(@as(u21, 'M'), result.cells[3].char);
    try std.testing.expectEqual(@as(u21, 'y'), result.cells[4].char);
    try std.testing.expectEqual(@as(u21, ' '), result.cells[5].char);
    try std.testing.expectEqual(@as(u21, 'P'), result.cells[6].char);
}

test "panel: cursor passthrough from input" {
    const config = PanelConfig{
        .width = .{ .cells = 20 },
        .height = .{ .cells = 5 },
        .border = .single,
    };
    const content = Element{ .input = .{
        .value = "abc",
        .cursor_pos = 2,
        .width = .{ .cells = 16 },
    } };
    const result = try renderPanel(std.testing.allocator, config, content, 80, 24);
    defer std.testing.allocator.free(result.cells);

    // Panel is centered at col=30, row=9 (approximately)
    // Cursor within panel cell buffer is at some local position,
    // then offset by panel's grid position
    try std.testing.expect(result.cursor_col != null);
    try std.testing.expect(result.cursor_row != null);
    // Cursor col should be >= panel col (offset applied)
    try std.testing.expect(result.cursor_col.? >= result.col);
    try std.testing.expect(result.cursor_row.? >= result.row);
}

test "panel: too-small panel returns empty" {
    const config = PanelConfig{
        .width = .{ .cells = 2 },
        .height = .{ .cells = 2 },
    };
    const content = Element{ .text = .{ .content = "X" } };
    const result = try renderPanel(std.testing.allocator, config, content, 80, 24);

    try std.testing.expectEqual(@as(u16, 0), result.width);
    try std.testing.expectEqual(@as(u16, 0), result.height);
}

test "panel: zero grid returns empty" {
    const config = PanelConfig{
        .width = .{ .percent = 50 },
        .height = .{ .percent = 50 },
    };
    const content = Element{ .text = .{ .content = "X" } };
    const result = try renderPanel(std.testing.allocator, config, content, 0, 0);

    try std.testing.expectEqual(@as(u16, 0), result.width);
    try std.testing.expectEqual(@as(u16, 0), result.height);
}
