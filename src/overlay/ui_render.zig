// Attyx — Declarative overlay layout engine
// Two-pass recursive layout: measure → render.

const std = @import("std");
const ui = @import("ui.zig");
const layout_mod = @import("layout.zig");
const ui_cell = @import("ui_cell.zig");

const StyledCell = ui.StyledCell;
const Rgb = ui.Rgb;
const Element = ui.Element;
const Style = ui.Style;
const ResolvedStyle = ui.ResolvedStyle;
const OverlayTheme = ui.OverlayTheme;
const Size = ui.Size;
const SizeValue = ui.SizeValue;
const TextFlags = ui.TextFlags;
const Padding = ui.Padding;
const LineRange = layout_mod.LineRange;

pub const RenderResult = struct {
    width: u16,
    height: u16,
    cursor_col: ?u16 = null,
    cursor_row: ?u16 = null,
};

// ---------------------------------------------------------------------------
// Measure pass — compute required Size for an element
// ---------------------------------------------------------------------------

pub fn measure(elem: Element, max_w: u16, theme: OverlayTheme) Size {
    _ = theme;
    return switch (elem) {
        .box => |b| measureBox(b, max_w),
        .text => |t| measureText(t, max_w),
        .input => |inp| measureInput(inp, max_w),
        .list => |l| measureList(l, max_w),
        .menu => |m| measureMenu(m, max_w),
        .hint => |h| measureHint(h, max_w),
    };
}

fn measureBox(b: Element.Box, max_w: u16) Size {
    const border_cost: u16 = if (b.border != .none) 2 else 0;
    const pad_h = b.padding.left + b.padding.right;
    const pad_v = b.padding.top + b.padding.bottom;
    const overhead_w = border_cost + pad_h;
    const overhead_h = border_cost + pad_v;

    // Resolve explicit width constraint
    const avail_outer = if (b.width) |w| w.resolve(max_w) else max_w;
    const inner_max = if (avail_outer > overhead_w) avail_outer - overhead_w else 0;

    var content_w: u16 = 0;
    var content_h: u16 = 0;

    for (b.children) |child| {
        const child_max = if (b.direction == .horizontal)
            (if (inner_max > content_w) inner_max - content_w else 0)
        else
            inner_max;
        const cs = measure(child, child_max, .{});
        switch (b.direction) {
            .vertical => {
                content_w = @max(content_w, cs.width);
                content_h += cs.height;
            },
            .horizontal => {
                content_w += cs.width;
                content_h = @max(content_h, cs.height);
            },
        }
    }

    var w = content_w + overhead_w;
    var h = content_h + overhead_h;

    // Apply min/max constraints
    if (b.min_width) |mw| w = @max(w, mw.resolve(max_w));
    if (b.max_width) |mw| w = @min(w, mw.resolve(max_w));
    if (b.width) |ew| w = ew.resolve(max_w);
    if (b.fill_width) w = max_w;

    if (b.min_height) |mh| h = @max(h, mh.resolve(max_w));
    if (b.max_height) |mh| h = @min(h, mh.resolve(max_w));
    if (b.height) |eh| h = eh.resolve(max_w);

    return .{ .width = @min(w, max_w), .height = h };
}

fn measureText(t: Element.Text, max_w: u16) Size {
    if (t.content.len == 0 or max_w == 0) return .{ .width = 0, .height = 0 };
    if (!t.wrap) {
        const cp_count = utf8Count(t.content);
        const len: u16 = @min(cp_count, max_w);
        return .{ .width = len, .height = 1 };
    }
    var lines_buf: [128]LineRange = undefined;
    const line_count = layout_mod.wrapText(t.content, max_w, &lines_buf);
    if (line_count == 0) return .{ .width = 0, .height = 0 };
    var max_line_w: u16 = 0;
    for (lines_buf[0..line_count]) |lr| {
        max_line_w = @max(max_line_w, utf8Count(t.content[lr.start..lr.end]));
    }
    return .{ .width = max_line_w, .height = line_count };
}

fn measureInput(inp: Element.Input, max_w: u16) Size {
    const w = if (inp.width) |sv| sv.resolve(max_w) else max_w;
    return .{ .width = @min(w, max_w), .height = 1 };
}

fn measureList(l: Element.List, max_w: u16) Size {
    var total_h: u16 = 0;
    var max_item_w: u16 = 0;
    for (l.items) |item| {
        const s = measure(item, max_w, .{});
        max_item_w = @max(max_item_w, s.width);
        total_h += s.height;
    }
    const visible = if (l.visible_count) |vc| @min(vc, total_h) else total_h;
    return .{ .width = max_item_w, .height = visible };
}

fn measureMenu(m: Element.Menu, max_w: u16) Size {
    var max_item_w: u16 = 0;
    for (m.items) |item| {
        var item_w: u16 = @min(utf8Count(item.label), max_w);
        if (item.hint_text.len > 0) {
            item_w += @min(utf8Count(item.hint_text) + 2, max_w); // "  hint"
        }
        max_item_w = @max(max_item_w, item_w);
    }
    const item_count: u16 = @intCast(m.items.len);
    const visible = if (m.visible_count) |vc| @min(vc, item_count) else item_count;
    return .{ .width = @min(max_item_w, max_w), .height = visible };
}

fn measureHint(h: Element.Hint, max_w: u16) Size {
    return measureText(.{
        .content = h.content,
        .alignment = h.alignment,
    }, max_w);
}

// ---------------------------------------------------------------------------
// Render pass — fill cells array with content
// ---------------------------------------------------------------------------

pub fn render(
    cells: []StyledCell,
    stride: u16,
    max_h: u16,
    elem: Element,
    theme: OverlayTheme,
) RenderResult {
    const rs = theme.rootStyle();
    return renderElem(cells, stride, max_h, 0, 0, stride, max_h, elem, rs, theme);
}

fn renderElem(
    cells: []StyledCell,
    stride: u16,
    buf_h: u16,
    x: u16,
    y: u16,
    avail_w: u16,
    avail_h: u16,
    elem: Element,
    parent_style: ResolvedStyle,
    theme: OverlayTheme,
) RenderResult {
    return switch (elem) {
        .box => |b| renderBox(cells, stride, buf_h, x, y, avail_w, avail_h, b, parent_style, theme),
        .text => |t| renderText(cells, stride, buf_h, x, y, avail_w, avail_h, t, parent_style),
        .input => |inp| renderInput(cells, stride, buf_h, x, y, avail_w, inp, parent_style, theme),
        .list => |l| renderList(cells, stride, buf_h, x, y, avail_w, avail_h, l, parent_style, theme),
        .menu => |m| renderMenu(cells, stride, buf_h, x, y, avail_w, avail_h, m, parent_style, theme),
        .hint => |h| renderHint(cells, stride, buf_h, x, y, avail_w, avail_h, h, parent_style),
    };
}

fn renderBox(
    cells: []StyledCell,
    stride: u16,
    buf_h: u16,
    x: u16,
    y: u16,
    avail_w: u16,
    avail_h: u16,
    b: Element.Box,
    parent_style: ResolvedStyle,
    theme: OverlayTheme,
) RenderResult {
    const rs = parent_style.merge(b.style);
    const sz = measureBox(b, avail_w);
    const w = @min(sz.width, avail_w);
    const h = @min(sz.height, avail_h);

    // Fill background
    fillRect(cells, stride, buf_h, x, y, w, h, rs);

    // Draw border
    const has_border = b.border != .none;
    if (has_border and w >= 2 and h >= 2) {
        drawBorder(cells, stride, buf_h, x, y, w, h, b.border, theme.border_color, rs);
    }

    // Content area
    const border_off: u16 = if (has_border) 1 else 0;
    const cx = x + border_off + b.padding.left;
    const cy = y + border_off + b.padding.top;
    const overhead_w = (border_off * 2) + b.padding.left + b.padding.right;
    const overhead_h = (border_off * 2) + b.padding.top + b.padding.bottom;
    const cw = if (w > overhead_w) w - overhead_w else 0;
    const ch = if (h > overhead_h) h - overhead_h else 0;

    var off_x: u16 = 0;
    var off_y: u16 = 0;
    var result = RenderResult{ .width = w, .height = h };

    for (b.children) |child| {
        const child_avail_w = if (b.direction == .horizontal)
            (if (cw > off_x) cw - off_x else 0)
        else
            cw;
        const child_avail_h = if (b.direction == .vertical)
            (if (ch > off_y) ch - off_y else 0)
        else
            ch;
        if (child_avail_w == 0 or child_avail_h == 0) break;

        const cr = renderElem(
            cells,
            stride,
            buf_h,
            cx + off_x,
            cy + off_y,
            child_avail_w,
            child_avail_h,
            child,
            rs,
            theme,
        );

        // Propagate cursor position
        if (cr.cursor_col) |cc| {
            result.cursor_col = cc;
            result.cursor_row = cr.cursor_row;
        }

        switch (b.direction) {
            .vertical => off_y += cr.height,
            .horizontal => off_x += cr.width,
        }
    }

    return result;
}

fn renderText(
    cells: []StyledCell,
    stride: u16,
    buf_h: u16,
    x: u16,
    y: u16,
    avail_w: u16,
    avail_h: u16,
    t: Element.Text,
    parent_style: ResolvedStyle,
) RenderResult {
    const rs = parent_style.merge(t.style);
    if (t.content.len == 0 or avail_w == 0 or avail_h == 0)
        return .{ .width = 0, .height = 0 };

    const flags_u8 = rs.text_flags.toU8();

    if (!t.wrap) {
        const cp_count = utf8Count(t.content);
        const vis_cps = @min(cp_count, avail_w);
        const byte_end = utf8ByteOffset(t.content, vis_cps);
        const off = alignOffset(vis_cps, avail_w, t.alignment);
        writeStr(cells, stride, buf_h, x + off, y, t.content[0..byte_end], rs.fg, rs.bg, rs.bg_alpha, flags_u8);
        return .{ .width = vis_cps, .height = 1 };
    }

    var lines_buf: [128]LineRange = undefined;
    const line_count = layout_mod.wrapText(t.content, avail_w, &lines_buf);
    const visible = @min(line_count, avail_h);

    var max_w: u16 = 0;
    for (lines_buf[0..visible], 0..) |lr, li| {
        const row = y + @as(u16, @intCast(li));
        const line_slice = t.content[lr.start..lr.end];
        const line_cps = utf8Count(line_slice);
        const off = alignOffset(line_cps, avail_w, t.alignment);
        writeStr(cells, stride, buf_h, x + off, row, line_slice, rs.fg, rs.bg, rs.bg_alpha, flags_u8);
        max_w = @max(max_w, line_cps);
    }

    return .{ .width = max_w, .height = visible };
}

fn renderInput(
    cells: []StyledCell,
    stride: u16,
    buf_h: u16,
    x: u16,
    y: u16,
    avail_w: u16,
    inp: Element.Input,
    parent_style: ResolvedStyle,
    theme: OverlayTheme,
) RenderResult {
    const rs = parent_style.merge(inp.style);
    const w = if (inp.width) |sv| @min(sv.resolve(avail_w), avail_w) else avail_w;
    if (w == 0 or y >= buf_h) return .{ .width = 0, .height = 0 };

    // Determine display text
    const display = if (inp.value.len > 0) inp.value else inp.placeholder;
    const is_placeholder = inp.value.len == 0;
    const text_fg = if (is_placeholder)
        theme.hint_fg
    else
        rs.fg;
    const text_flags: u8 = if (is_placeholder)
        (TextFlags{ .dim = true }).toU8()
    else
        rs.text_flags.toU8();

    const cp_count = utf8Count(display);
    const vis_cps = @min(cp_count, w);
    const byte_end = utf8ByteOffset(display, vis_cps);
    writeStr(cells, stride, buf_h, x, y, display[0..byte_end], text_fg, rs.bg, rs.bg_alpha, text_flags);

    // Fill remaining width with bg
    if (vis_cps < w) {
        for (vis_cps..w) |ci| {
            const col = x + @as(u16, @intCast(ci));
            setCell(cells, stride, buf_h, col, y, ' ', rs.fg, rs.bg, rs.bg_alpha, 0);
        }
    }

    // Cursor highlight
    const cursor_col = @min(inp.cursor_pos, w -| 1);
    const abs_col = x + cursor_col;
    const idx = cellIndex(stride, abs_col, y);
    if (idx < cells.len) {
        cells[idx].fg = inp.cursor_style.fg orelse theme.cursor_fg;
        cells[idx].bg = inp.cursor_style.bg orelse theme.cursor_bg;
        cells[idx].bg_alpha = 255;
    }

    return .{
        .width = w,
        .height = 1,
        .cursor_col = abs_col,
        .cursor_row = y,
    };
}

fn renderList(
    cells: []StyledCell,
    stride: u16,
    buf_h: u16,
    x: u16,
    y: u16,
    avail_w: u16,
    avail_h: u16,
    l: Element.List,
    parent_style: ResolvedStyle,
    theme: OverlayTheme,
) RenderResult {
    const rs = parent_style.merge(l.style);
    const item_count: u16 = @intCast(l.items.len);
    const visible = if (l.visible_count) |vc| @min(vc, avail_h) else avail_h;
    const start = @min(l.scroll_offset, item_count);
    const end = @min(start + visible, item_count);

    var off_y: u16 = 0;
    var max_w: u16 = 0;
    for (l.items[start..end]) |item| {
        if (off_y >= visible) break;
        const remaining = visible - off_y;
        const cr = renderElem(cells, stride, buf_h, x, y + off_y, avail_w, remaining, item, rs, theme);
        max_w = @max(max_w, cr.width);
        off_y += cr.height;
    }

    return .{ .width = max_w, .height = off_y };
}

fn renderMenu(
    cells: []StyledCell,
    stride: u16,
    buf_h: u16,
    x: u16,
    y: u16,
    avail_w: u16,
    avail_h: u16,
    m: Element.Menu,
    parent_style: ResolvedStyle,
    theme: OverlayTheme,
) RenderResult {
    _ = theme;
    const rs = parent_style.merge(m.style);
    const item_count: u16 = @intCast(m.items.len);
    const visible = if (m.visible_count) |vc| @min(vc, avail_h) else avail_h;
    const start = @min(m.scroll_offset, item_count);
    const end = @min(start + visible, item_count);

    var row: u16 = 0;
    var max_w: u16 = 0;
    for (m.items[start..end], start..) |item, abs_idx| {
        if (row >= visible) break;
        const is_selected = @as(u16, @intCast(abs_idx)) == m.selected;
        const item_rs = if (is_selected) rs.merge(m.selected_style) else rs;

        // Fill row background
        fillRect(cells, stride, buf_h, x, y + row, avail_w, 1, item_rs);

        // Write label (dim disabled items)
        const label_cps = utf8Count(item.label);
        const vis_label = @min(label_cps, avail_w);
        const label_byte_end = utf8ByteOffset(item.label, vis_label);
        const label_flags = if (item.enabled) item_rs.text_flags.toU8() else (TextFlags{ .dim = true }).toU8();
        writeStr(cells, stride, buf_h, x, y + row, item.label[0..label_byte_end], item_rs.fg, item_rs.bg, item_rs.bg_alpha, label_flags);

        var item_w = vis_label;
        // Write hint right-aligned
        if (item.hint_text.len > 0) {
            const hint_cps = utf8Count(item.hint_text);
            const vis_hint = @min(hint_cps, avail_w);
            if (vis_hint + vis_label + 2 <= avail_w) {
                const hint_byte_end = utf8ByteOffset(item.hint_text, vis_hint);
                const hint_x = x + avail_w - vis_hint;
                const hint_flags = if (is_selected) item_rs.text_flags.toU8() else (TextFlags{ .dim = true }).toU8();
                writeStr(cells, stride, buf_h, hint_x, y + row, item.hint_text[0..hint_byte_end], item_rs.fg, item_rs.bg, item_rs.bg_alpha, hint_flags);
                item_w = avail_w;
            }
        }
        max_w = @max(max_w, item_w);
        row += 1;
    }

    return .{ .width = max_w, .height = row };
}

fn renderHint(
    cells: []StyledCell,
    stride: u16,
    buf_h: u16,
    x: u16,
    y: u16,
    avail_w: u16,
    avail_h: u16,
    h: Element.Hint,
    parent_style: ResolvedStyle,
) RenderResult {
    return renderText(cells, stride, buf_h, x, y, avail_w, avail_h, .{
        .content = h.content,
        .style = h.style,
        .alignment = h.alignment,
    }, parent_style);
}

// ---------------------------------------------------------------------------
// Convenience: measure + allocate + render
// ---------------------------------------------------------------------------

pub fn renderAlloc(
    allocator: std.mem.Allocator,
    elem: Element,
    max_w: u16,
    theme: OverlayTheme,
) !struct { cells: []StyledCell, result: RenderResult } {
    const sz = measure(elem, max_w, theme);
    if (sz.width == 0 or sz.height == 0) {
        return .{
            .cells = &.{},
            .result = .{ .width = 0, .height = 0 },
        };
    }
    const total: usize = @as(usize, sz.width) * sz.height;
    const out = try allocator.alloc(StyledCell, total);
    // Initialize all cells to default (space, theme bg)
    const rs = theme.rootStyle();
    for (out) |*cell| {
        cell.* = .{ .fg = rs.fg, .bg = rs.bg, .bg_alpha = rs.bg_alpha };
    }
    const result = render(out, sz.width, sz.height, elem, theme);
    return .{ .cells = out, .result = result };
}

// Cell helpers — delegated to ui_cell.zig
const setCell = ui_cell.setCell;
const writeStr = ui_cell.writeStr;
const fillRect = ui_cell.fillRect;
const drawBorder = ui_cell.drawBorder;
const cellIndex = ui_cell.cellIndex;
const alignOffset = ui_cell.alignOffset;
const utf8Count = ui_cell.utf8Count;
const utf8ByteOffset = ui_cell.utf8ByteOffset;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "measure text and box" {
    // No-wrap text
    const sz1 = measure(.{ .text = .{ .content = "hello", .wrap = false } }, 80, .{});
    try std.testing.expectEqual(@as(u16, 5), sz1.width);
    try std.testing.expectEqual(@as(u16, 1), sz1.height);
    // Wrapping text
    const sz2 = measure(.{ .text = .{ .content = "hello world this is long" } }, 10, .{});
    try std.testing.expect(sz2.width <= 10);
    try std.testing.expect(sz2.height >= 2);
    // Box with border + padding
    const text_elem = Element{ .text = .{ .content = "Hi", .wrap = false } };
    const sz3 = measure(.{ .box = .{
        .children = &[_]Element{text_elem},
        .border = .single,
        .padding = ui.Padding.uniform(1),
    } }, 80, .{});
    try std.testing.expectEqual(@as(u16, 6), sz3.width);
    try std.testing.expectEqual(@as(u16, 5), sz3.height);
    // Percent width
    const sz4 = measure(.{ .box = .{ .width = .{ .percent = 50 } } }, 80, .{});
    try std.testing.expectEqual(@as(u16, 40), sz4.width);
    // Input
    const sz5 = measure(.{ .input = .{ .width = .{ .cells = 20 } } }, 80, .{});
    try std.testing.expectEqual(@as(u16, 20), sz5.width);
    try std.testing.expectEqual(@as(u16, 1), sz5.height);
    // Menu
    const items = [_]Element.MenuItem{ .{ .label = "Open" }, .{ .label = "Save" }, .{ .label = "Quit" } };
    const sz6 = measure(.{ .menu = .{ .items = &items, .visible_count = 2 } }, 80, .{});
    try std.testing.expectEqual(@as(u16, 4), sz6.width);
    try std.testing.expectEqual(@as(u16, 2), sz6.height);
}

test "render text into cells" {
    const theme = OverlayTheme{};
    const out = try std.testing.allocator.alloc(StyledCell, 10);
    defer std.testing.allocator.free(out);
    for (out) |*c| c.* = .{};

    const result = render(out, 10, 1, .{ .text = .{ .content = "Hello", .wrap = false } }, theme);
    try std.testing.expectEqual(@as(u16, 5), result.width);
    try std.testing.expectEqual(@as(u21, 'H'), out[0].char);
    try std.testing.expectEqual(@as(u21, 'o'), out[4].char);
}

test "render box with border draws corners" {
    const theme = OverlayTheme{};
    const elem = Element{ .box = .{
        .border = .single,
        .width = .{ .cells = 5 },
        .height = .{ .cells = 3 },
    } };
    const r = try renderAlloc(std.testing.allocator, elem, 80, theme);
    defer std.testing.allocator.free(r.cells);
    // Top-left corner = 0x250C
    try std.testing.expectEqual(@as(u21, 0x250C), r.cells[0].char);
    // Top-right corner = 0x2510
    try std.testing.expectEqual(@as(u21, 0x2510), r.cells[4].char);
}

test "render input with cursor" {
    const theme = OverlayTheme{};
    const elem = Element{ .input = .{
        .value = "abc",
        .cursor_pos = 1,
        .width = .{ .cells = 10 },
    } };
    const r = try renderAlloc(std.testing.allocator, elem, 80, theme);
    defer std.testing.allocator.free(r.cells);

    try std.testing.expectEqual(@as(u16, 1), r.result.cursor_col.?);
    try std.testing.expectEqual(@as(u16, 0), r.result.cursor_row.?);
    // Cursor cell should have cursor_bg
    try std.testing.expectEqual(theme.cursor_bg.r, r.cells[1].bg.r);
}

test "render text flags propagation" {
    const theme = OverlayTheme{};
    const elem = Element{ .text = .{
        .content = "bold",
        .style = .{ .text_flags = .{ .bold = true } },
        .wrap = false,
    } };
    const r = try renderAlloc(std.testing.allocator, elem, 80, theme);
    defer std.testing.allocator.free(r.cells);

    try std.testing.expectEqual(@as(u8, 0x01), r.cells[0].flags);
}

test "renderAlloc empty element" {
    const theme = OverlayTheme{};
    const elem = Element{ .text = .{ .content = "" } };
    const r = try renderAlloc(std.testing.allocator, elem, 80, theme);
    try std.testing.expectEqual(@as(u16, 0), r.result.width);
    try std.testing.expectEqual(@as(u16, 0), r.result.height);
}
