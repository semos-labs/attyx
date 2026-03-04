// Attyx — Cell-level helpers for overlay rendering
// Shared between ui_render.zig and overlay migration code.

const ui = @import("ui.zig");
const StyledCell = ui.StyledCell;
const Rgb = ui.Rgb;
const ResolvedStyle = ui.ResolvedStyle;

pub fn cellIndex(stride: u16, col: u16, row: u16) usize {
    return @as(usize, row) * stride + col;
}

pub fn setCell(
    cells: []StyledCell,
    stride: u16,
    buf_h: u16,
    col: u16,
    row: u16,
    char: u21,
    fg: Rgb,
    bg: Rgb,
    bg_alpha: u8,
    flags: u8,
) void {
    if (col >= stride or row >= buf_h) return;
    const idx = cellIndex(stride, col, row);
    if (idx >= cells.len) return;
    cells[idx] = .{ .char = char, .fg = fg, .bg = bg, .bg_alpha = bg_alpha, .flags = flags };
}

pub fn writeStr(
    cells: []StyledCell,
    stride: u16,
    buf_h: u16,
    x: u16,
    y: u16,
    text: []const u8,
    fg: Rgb,
    bg: Rgb,
    bg_alpha: u8,
    flags: u8,
) void {
    for (text, 0..) |ch, i| {
        const col = x + @as(u16, @intCast(i));
        setCell(cells, stride, buf_h, col, y, ch, fg, bg, bg_alpha, flags);
    }
}

pub fn fillRect(
    cells: []StyledCell,
    stride: u16,
    buf_h: u16,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    rs: ResolvedStyle,
) void {
    for (0..h) |dy| {
        const row = y + @as(u16, @intCast(dy));
        for (0..w) |dx| {
            const col = x + @as(u16, @intCast(dx));
            setCell(cells, stride, buf_h, col, row, ' ', rs.fg, rs.bg, rs.bg_alpha, 0);
        }
    }
}

pub fn drawBorder(
    cells: []StyledCell,
    stride: u16,
    buf_h: u16,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    style: ui.BorderStyle,
    border_color: Rgb,
    rs: ResolvedStyle,
) void {
    const corners = switch (style) {
        .single => [4]u21{ 0x250C, 0x2510, 0x2514, 0x2518 },
        .rounded => [4]u21{ 0x256D, 0x256E, 0x2570, 0x256F },
        .none => return,
    };
    const horiz: u21 = 0x2500;
    const vert: u21 = 0x2502;

    setCell(cells, stride, buf_h, x, y, corners[0], border_color, rs.bg, rs.bg_alpha, 0);
    setCell(cells, stride, buf_h, x + w - 1, y, corners[1], border_color, rs.bg, rs.bg_alpha, 0);
    setCell(cells, stride, buf_h, x, y + h - 1, corners[2], border_color, rs.bg, rs.bg_alpha, 0);
    setCell(cells, stride, buf_h, x + w - 1, y + h - 1, corners[3], border_color, rs.bg, rs.bg_alpha, 0);

    for (1..w - 1) |dx| {
        const col = x + @as(u16, @intCast(dx));
        setCell(cells, stride, buf_h, col, y, horiz, border_color, rs.bg, rs.bg_alpha, 0);
        setCell(cells, stride, buf_h, col, y + h - 1, horiz, border_color, rs.bg, rs.bg_alpha, 0);
    }

    for (1..h - 1) |dy| {
        const row = y + @as(u16, @intCast(dy));
        setCell(cells, stride, buf_h, x, row, vert, border_color, rs.bg, rs.bg_alpha, 0);
        setCell(cells, stride, buf_h, x + w - 1, row, vert, border_color, rs.bg, rs.bg_alpha, 0);
    }
}

pub fn alignOffset(content_w: u16, avail_w: u16, alignment: ui.Align) u16 {
    return switch (alignment) {
        .left => 0,
        .center => if (avail_w > content_w) (avail_w - content_w) / 2 else 0,
        .right => if (avail_w > content_w) avail_w - content_w else 0,
    };
}
