const std = @import("std");
const overlay = @import("overlay.zig");
const action_mod = @import("action.zig");
const layout = @import("layout.zig");
const OverlayCell = overlay.OverlayCell;
const OverlayStyle = overlay.OverlayStyle;
const Rgb = overlay.Rgb;
const LineRange = layout.LineRange;
const CardResult = layout.CardResult;
const ActionBarStyle = layout.ActionBarStyle;

// ---------------------------------------------------------------------------
// UTF-8 helpers
// ---------------------------------------------------------------------------

/// Write UTF-8 decoded codepoints from `text` into overlay cells starting at
/// (row, start_col). Advances one cell per codepoint (assumes all are width 1).
/// Stops after `max_cells` cells or end of text. Returns cells written.
fn fillCellsUtf8(
    cells: []OverlayCell,
    stride: usize,
    row: usize,
    start_col: usize,
    text: []const u8,
    max_cells: usize,
    fg: Rgb,
    bg: Rgb,
    bg_alpha: u8,
) usize {
    var ci: usize = 0;
    var pos: usize = 0;
    while (pos < text.len and ci < max_cells) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[pos]) catch {
            pos += 1;
            continue;
        };
        if (pos + cp_len > text.len) break;
        const cp = std.unicode.utf8Decode(text[pos .. pos + cp_len]) catch {
            pos += 1;
            continue;
        };
        const col = start_col + ci;
        const idx = row * stride + col;
        if (idx >= cells.len) break;
        cells[idx] = .{ .char = cp, .fg = fg, .bg = bg, .bg_alpha = bg_alpha };
        ci += 1;
        pos += cp_len;
    }
    return ci;
}

/// Count display-width codepoints in a UTF-8 byte slice (1 cell per codepoint).
fn utf8CharCount(text: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < text.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[pos]) catch {
            pos += 1;
            continue;
        };
        if (pos + cp_len > text.len) break;
        count += 1;
        pos += cp_len;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Content model
// ---------------------------------------------------------------------------

pub const BlockTag = enum(u8) { header, paragraph, code_block, bullet_list };

pub const ContentBlock = struct {
    tag: BlockTag,
    text: []const u8 = "",
    items: []const []const u8 = &.{}, // for bullet_list
};

/// Return the text of the first code_block with non-empty text, or null.
pub fn firstCodeBlock(blocks: []const ContentBlock) ?[]const u8 {
    for (blocks) |block| {
        if (block.tag == .code_block and block.text.len > 0) return block.text;
    }
    return null;
}

pub const ContentStyle = struct {
    base: OverlayStyle = .{},
    code_bg: Rgb = .{ .r = 20, .g = 20, .b = 30 },
    code_fg: Rgb = .{ .r = 130, .g = 200, .b = 130 },
    code_border_fg: Rgb = .{ .r = 80, .g = 140, .b = 80 },
    header_fg: Rgb = .{ .r = 120, .g = 160, .b = 255 },
    bullet_fg: Rgb = .{ .r = 150, .g = 130, .b = 200 },
};

// ---------------------------------------------------------------------------
// Measurement
// ---------------------------------------------------------------------------

const max_lines_buf = 128;

/// Measure one block. Returns number of rows it will occupy.
pub fn measureBlock(block: ContentBlock, inner_w: u16) u16 {
    return switch (block.tag) {
        .header => measureHeader(block.text, inner_w),
        .paragraph => measureParagraph(block.text, inner_w),
        .code_block => measureCodeBlock(block.text),
        .bullet_list => measureBulletList(block.items, inner_w),
    };
}

fn measureHeader(text: []const u8, inner_w: u16) u16 {
    var buf: [max_lines_buf]LineRange = undefined;
    const n = layout.wrapText(text, inner_w, &buf);
    return if (n > 0) n + 1 else 2; // text lines + underline row
}

fn measureParagraph(text: []const u8, inner_w: u16) u16 {
    var buf: [max_lines_buf]LineRange = undefined;
    const n = layout.wrapText(text, inner_w, &buf);
    return if (n > 0) n else 1;
}

fn measureCodeBlock(text: []const u8) u16 {
    if (text.len == 0) return 1;
    var lines: u16 = 1;
    for (text) |ch| {
        if (ch == '\n') lines += 1;
    }
    return lines;
}

fn measureBulletList(items: []const []const u8, inner_w: u16) u16 {
    const bullet_prefix_len: u16 = 4; // "  • "
    const wrap_w = if (inner_w > bullet_prefix_len) inner_w - bullet_prefix_len else 1;
    var total: u16 = 0;
    for (items) |item| {
        var buf: [max_lines_buf]LineRange = undefined;
        const n = layout.wrapText(item, wrap_w, &buf);
        total += if (n > 0) n else 1;
    }
    return total;
}

// ---------------------------------------------------------------------------
// Structured card layout
// ---------------------------------------------------------------------------

pub fn layoutStructuredCard(
    allocator: std.mem.Allocator,
    title: []const u8,
    blocks: []const ContentBlock,
    max_content_width: u16,
    style: ContentStyle,
    action_bar: ?action_mod.ActionBar,
) !CardResult {
    const border_w: u16 = 2; // left + right border
    const padding_w: u16 = 2; // 1 cell padding each side
    const inner_w = if (max_content_width > border_w + padding_w)
        max_content_width - border_w - padding_w
    else
        1;

    // --- Measure pass ---
    var content_h: u16 = 0;
    for (blocks, 0..) |block, bi| {
        content_h += measureBlock(block, inner_w);
        // 1-row separator between blocks (not after last)
        if (bi + 1 < blocks.len) content_h += 1;
    }

    const action_row_count: u16 = if (action_bar != null) 1 else 0;
    const total_h = 1 + content_h + action_row_count + 1; // top border + content + [action] + bottom border
    const total_w = inner_w + border_w + padding_w;

    const cell_count: usize = @as(usize, total_w) * @as(usize, total_h);
    const cells = try allocator.alloc(OverlayCell, cell_count);

    // Fill all cells with background
    for (cells) |*cell| {
        cell.* = .{
            .char = ' ',
            .fg = style.base.fg,
            .bg = style.base.bg,
            .bg_alpha = style.base.bg_alpha,
        };
    }

    // Draw border
    fillBorder(cells, total_w, total_h, style.base);

    // Place title in top border
    placeTitle(cells, total_w, title, style.base);

    // --- Fill pass: render each block ---
    const text_col: u16 = 2; // border + padding
    var cur_row: u16 = 1; // after top border
    const stride = total_w;

    for (blocks, 0..) |block, bi| {
        switch (block.tag) {
            .header => {
                cur_row = fillHeader(cells, stride, text_col, cur_row, inner_w, block.text, style);
            },
            .paragraph => {
                cur_row = fillParagraph(cells, stride, text_col, cur_row, inner_w, block.text, style);
            },
            .code_block => {
                cur_row = fillCodeBlock(cells, stride, text_col, cur_row, inner_w, block.text, style);
            },
            .bullet_list => {
                cur_row = fillBulletList(cells, stride, text_col, cur_row, inner_w, block.items, style);
            },
        }
        // Separator row (blank — already filled with bg)
        if (bi + 1 < blocks.len) cur_row += 1;
    }

    // Fill action bar if present
    if (action_bar) |ab| {
        const action_row = total_h - 2; // row before bottom border
        layout.fillActionBar(
            cells,
            stride,
            action_row,
            1, // after left border
            total_w - 1, // before right border
            ab.actions[0..ab.count],
            ab.focused,
            .{},
            style.base,
        );
    }

    return .{ .cells = cells, .width = total_w, .height = total_h };
}

// ---------------------------------------------------------------------------
// Block renderers
// ---------------------------------------------------------------------------

fn fillHeader(
    cells: []OverlayCell,
    stride: u16,
    start_col: u16,
    start_row: u16,
    inner_w: u16,
    text: []const u8,
    style: ContentStyle,
) u16 {
    var buf: [max_lines_buf]LineRange = undefined;
    const n = layout.wrapText(text, inner_w, &buf);
    const lines = if (n > 0) n else 1;

    // Render header text in accent color
    for (buf[0..lines], 0..) |lr, li| {
        const row = @as(usize, start_row) + li;
        const line_text = text[lr.start..lr.end];
        _ = fillCellsUtf8(cells, stride, row, start_col, line_text, inner_w, style.header_fg, style.base.bg, style.base.bg_alpha);
    }

    // Underline row of ─
    const ul_row = @as(usize, start_row) + lines;
    for (0..inner_w) |ci| {
        const col = @as(usize, start_col) + ci;
        const idx = ul_row * @as(usize, stride) + col;
        if (idx >= cells.len) break;
        cells[idx] = .{
            .char = 0x2500, // ─
            .fg = style.base.border_color,
            .bg = style.base.bg,
            .bg_alpha = style.base.bg_alpha,
        };
    }

    return start_row + lines + 1;
}

fn fillParagraph(
    cells: []OverlayCell,
    stride: u16,
    start_col: u16,
    start_row: u16,
    inner_w: u16,
    text: []const u8,
    style: ContentStyle,
) u16 {
    var buf: [max_lines_buf]LineRange = undefined;
    const n = layout.wrapText(text, inner_w, &buf);
    const lines = if (n > 0) n else 1;

    for (buf[0..@min(n, lines)], 0..) |lr, li| {
        const row = @as(usize, start_row) + li;
        const line_text = text[lr.start..lr.end];
        _ = fillCellsUtf8(cells, stride, row, start_col, line_text, inner_w, style.base.fg, style.base.bg, style.base.bg_alpha);
    }

    return start_row + lines;
}

fn fillCodeBlock(
    cells: []OverlayCell,
    stride: u16,
    start_col: u16,
    start_row: u16,
    inner_w: u16,
    text: []const u8,
    style: ContentStyle,
) u16 {
    // Split on \n, preserve indentation, truncate at width, no word-wrap
    const code_lines = measureCodeBlock(text);

    // Paint code_bg for all code rows across the inner width
    for (0..code_lines) |li| {
        const row = @as(usize, start_row) + li;
        for (0..inner_w) |ci| {
            const col = @as(usize, start_col) + ci;
            const idx = row * @as(usize, stride) + col;
            if (idx >= cells.len) break;
            cells[idx] = .{
                .char = ' ',
                .fg = style.code_fg,
                .bg = style.code_bg,
                .bg_alpha = style.base.bg_alpha,
            };
        }
        // Left border bar │
        {
            const idx = row * @as(usize, stride) + @as(usize, start_col);
            if (idx < cells.len) {
                cells[idx] = .{
                    .char = 0x2502, // │
                    .fg = style.code_border_fg,
                    .bg = style.code_bg,
                    .bg_alpha = style.base.bg_alpha,
                };
            }
        }
    }

    // Fill in the code text
    var line_idx: u16 = 0;
    var pos: usize = 0;
    while (pos <= text.len and line_idx < code_lines) {
        // Find end of current line
        var end = pos;
        while (end < text.len and text[end] != '\n') end += 1;

        const row = @as(usize, start_row) + line_idx;
        const line_text = text[pos..end];
        // Offset by 1 for the │ left border
        const code_start_col = @as(usize, start_col) + 1;
        const max_chars: usize = if (inner_w > 1) inner_w - 1 else 1;
        _ = fillCellsUtf8(cells, stride, row, code_start_col, line_text, max_chars, style.code_fg, style.code_bg, style.base.bg_alpha);

        line_idx += 1;
        pos = if (end < text.len) end + 1 else end + 1;
    }

    return start_row + code_lines;
}

fn fillBulletList(
    cells: []OverlayCell,
    stride: u16,
    start_col: u16,
    start_row: u16,
    inner_w: u16,
    items: []const []const u8,
    style: ContentStyle,
) u16 {
    const bullet_prefix_len: u16 = 4; // "  • "
    const wrap_w = if (inner_w > bullet_prefix_len) inner_w - bullet_prefix_len else 1;
    var cur_row = start_row;

    for (items) |item| {
        var buf: [max_lines_buf]LineRange = undefined;
        const n = layout.wrapText(item, wrap_w, &buf);
        const lines = if (n > 0) n else 1;

        // First line: "  • text"
        // Place bullet marker
        const bullet_chars = [_]u21{ ' ', ' ', 0x2022, ' ' }; // "  • "
        const row0 = @as(usize, cur_row);
        for (bullet_chars, 0..) |bch, bi| {
            const col = @as(usize, start_col) + bi;
            const idx = row0 * @as(usize, stride) + col;
            if (idx >= cells.len) break;
            cells[idx] = .{
                .char = bch,
                .fg = if (bi == 2) style.bullet_fg else style.base.fg,
                .bg = style.base.bg,
                .bg_alpha = style.base.bg_alpha,
            };
        }

        // Fill wrapped text lines
        for (buf[0..@min(n, lines)], 0..) |lr, li| {
            const row = @as(usize, cur_row) + li;
            const line_text = item[lr.start..lr.end];
            const text_start = @as(usize, start_col) + bullet_prefix_len;
            _ = fillCellsUtf8(cells, stride, row, text_start, line_text, wrap_w, style.base.fg, style.base.bg, style.base.bg_alpha);
        }

        cur_row += lines;
    }

    return cur_row;
}

// ---------------------------------------------------------------------------
// Helpers (reused from layout.zig patterns)
// ---------------------------------------------------------------------------

fn fillBorder(cells: []OverlayCell, width: u16, height: u16, style: OverlayStyle) void {
    const w: usize = width;
    const h: usize = height;
    const bc = style.border_color;

    // Corners
    setCellAt(cells, 0, 0, w, 0x250C, bc, style); // ┌
    setCellAt(cells, 0, w - 1, w, 0x2510, bc, style); // ┐
    setCellAt(cells, h - 1, 0, w, 0x2514, bc, style); // └
    setCellAt(cells, h - 1, w - 1, w, 0x2518, bc, style); // ┘

    // Top and bottom edges
    for (1..w - 1) |col| {
        setCellAt(cells, 0, col, w, 0x2500, bc, style); // ─
        setCellAt(cells, h - 1, col, w, 0x2500, bc, style); // ─
    }

    // Left and right edges
    for (1..h - 1) |row| {
        setCellAt(cells, row, 0, w, 0x2502, bc, style); // │
        setCellAt(cells, row, w - 1, w, 0x2502, bc, style); // │
    }
}

fn setCellAt(cells: []OverlayCell, row: usize, col: usize, width: usize, char: u21, fg: Rgb, style: OverlayStyle) void {
    const idx = row * width + col;
    if (idx >= cells.len) return;
    cells[idx] = .{ .char = char, .fg = fg, .bg = style.bg, .bg_alpha = style.bg_alpha };
}

fn placeTitle(cells: []OverlayCell, width: u16, title: []const u8, style: OverlayStyle) void {
    if (title.len == 0) return;
    const w: usize = width;
    const title_start: usize = 2; // after "┌─"

    // Space before title
    setCellAt(cells, 0, title_start, w, ' ', style.border_color, style);
    // Title text (UTF-8 aware)
    const max_title_cells = if (w > title_start + 2) w - title_start - 2 else 1;
    const title_cells = fillCellsUtf8(cells, w, 0, title_start + 1, title, max_title_cells, style.fg, style.bg, style.bg_alpha);
    // Space after title
    const after = title_start + 1 + title_cells;
    if (after < w - 1) {
        setCellAt(cells, 0, after, w, ' ', style.border_color, style);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "measureBlock: header" {
    const h = measureBlock(.{ .tag = .header, .text = "Hello" }, 40);
    try std.testing.expectEqual(@as(u16, 2), h); // 1 text line + 1 underline
}

test "measureBlock: paragraph wrapping" {
    const h = measureBlock(.{ .tag = .paragraph, .text = "short" }, 40);
    try std.testing.expectEqual(@as(u16, 1), h);

    // Force wrapping: 30 chars into width 10
    const h2 = measureBlock(.{ .tag = .paragraph, .text = "word word word word word word" }, 10);
    try std.testing.expect(h2 > 1);
}

test "measureBlock: code block line count" {
    const h = measureBlock(.{ .tag = .code_block, .text = "line1\nline2\nline3" }, 40);
    try std.testing.expectEqual(@as(u16, 3), h);
}

test "measureBlock: bullet list" {
    const items = [_][]const u8{ "first", "second", "third" };
    const h = measureBlock(.{ .tag = .bullet_list, .items = &items }, 40);
    try std.testing.expectEqual(@as(u16, 3), h); // 1 line per item at width 40
}

test "layoutStructuredCard: basic dimensions" {
    const blocks = [_]ContentBlock{
        .{ .tag = .header, .text = "Title" },
        .{ .tag = .paragraph, .text = "Some text here." },
    };
    const result = try layoutStructuredCard(
        std.testing.allocator,
        "Test Card",
        &blocks,
        40,
        .{},
        null,
    );
    defer std.testing.allocator.free(result.cells);

    // width = 40, height = border(1) + header(2) + sep(1) + paragraph(1) + border(1) = 6
    try std.testing.expectEqual(@as(u16, 40), result.width);
    try std.testing.expectEqual(@as(u16, 6), result.height);
    try std.testing.expectEqual(@as(usize, 40 * 6), result.cells.len);
}

test "layoutStructuredCard: code block has code_bg" {
    const blocks = [_]ContentBlock{
        .{ .tag = .code_block, .text = "fn foo() void {}" },
    };
    const cs = ContentStyle{};
    const result = try layoutStructuredCard(
        std.testing.allocator,
        "Code",
        &blocks,
        30,
        cs,
        null,
    );
    defer std.testing.allocator.free(result.cells);

    // Row 1 (after top border) should have code_bg on inner cells
    const stride: usize = result.width;
    const idx = 1 * stride + 3; // row 1, col 3 (inside border+padding)
    try std.testing.expectEqual(cs.code_bg.r, result.cells[idx].bg.r);
    try std.testing.expectEqual(cs.code_bg.g, result.cells[idx].bg.g);
    try std.testing.expectEqual(cs.code_bg.b, result.cells[idx].bg.b);
}

test "layoutStructuredCard: bullet prefix present" {
    const items = [_][]const u8{"item one"};
    const blocks = [_]ContentBlock{
        .{ .tag = .bullet_list, .items = &items },
    };
    const result = try layoutStructuredCard(
        std.testing.allocator,
        "Bullets",
        &blocks,
        30,
        .{},
        null,
    );
    defer std.testing.allocator.free(result.cells);

    // Row 1, col 4 should be the bullet character •  (U+2022)
    const stride: usize = result.width;
    const idx = 1 * stride + 4; // row 1, start_col(2) + bullet offset(2)
    try std.testing.expectEqual(@as(u21, 0x2022), result.cells[idx].char);
}

test "layoutStructuredCard: with action bar" {
    var bar = action_mod.ActionBar{};
    bar.add(.dismiss, "Close");

    const blocks = [_]ContentBlock{
        .{ .tag = .paragraph, .text = "Hello" },
    };
    const result = try layoutStructuredCard(
        std.testing.allocator,
        "Actions",
        &blocks,
        30,
        .{},
        bar,
    );
    defer std.testing.allocator.free(result.cells);

    // height = border(1) + paragraph(1) + action(1) + border(1) = 4
    try std.testing.expectEqual(@as(u16, 4), result.height);

    // Action row should have a bracket '['
    const action_row: usize = result.height - 2; // row before bottom border
    var found_bracket = false;
    for (1..result.width - 1) |col| {
        const idx = action_row * @as(usize, result.width) + col;
        if (result.cells[idx].char == '[') {
            found_bracket = true;
            break;
        }
    }
    try std.testing.expect(found_bracket);
}

test "firstCodeBlock: returns first code block text" {
    const blocks = [_]ContentBlock{
        .{ .tag = .paragraph, .text = "intro" },
        .{ .tag = .code_block, .text = "fn foo() void {}" },
        .{ .tag = .code_block, .text = "fn bar() void {}" },
    };
    const result = firstCodeBlock(&blocks);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("fn foo() void {}", result.?);
}

test "firstCodeBlock: returns null when no code blocks" {
    const blocks = [_]ContentBlock{
        .{ .tag = .paragraph, .text = "just text" },
    };
    try std.testing.expectEqual(@as(?[]const u8, null), firstCodeBlock(&blocks));
}
