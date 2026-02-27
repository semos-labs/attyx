const std = @import("std");
const overlay = @import("overlay.zig");
const action_mod = @import("action.zig");
const content = @import("content.zig");
const layout = @import("layout.zig");
const context_mod = @import("context.zig");

const OverlayCell = overlay.OverlayCell;
const OverlayStyle = overlay.OverlayStyle;
const Rgb = overlay.Rgb;
const CardResult = layout.CardResult;
const ContentBlock = content.ContentBlock;
const ContentStyle = content.ContentStyle;
const ContextBundle = context_mod.ContextBundle;

/// Maximum preview lines for long text fields (scrollback, selection).
const max_preview_lines: usize = 20;

/// Fill a single row with a compact context summary string.
/// Used as a footer/info line within the AI demo overlay.
pub fn fillSummaryRow(
    cells: []OverlayCell,
    stride: u16,
    row: u16,
    start_col: u16,
    inner_w: u16,
    bundle: *const ContextBundle,
    style: OverlayStyle,
) void {
    var buf: [256]u8 = undefined;
    const summary = bundle.summaryLine(&buf);

    const max_chars = @min(summary.len, @as(usize, inner_w));
    for (summary[0..max_chars], 0..) |ch, i| {
        const col = @as(usize, start_col) + i;
        const idx = @as(usize, row) * @as(usize, stride) + col;
        if (idx >= cells.len) break;
        cells[idx] = .{
            .char = ch,
            .fg = .{ .r = 160, .g = 160, .b = 180 }, // muted info color
            .bg = style.bg,
            .bg_alpha = style.bg_alpha,
        };
    }
}

/// Truncate text for preview: return a slice up to `max_preview_lines` lines.
/// No allocation — returns a sub-slice of the input.
pub fn truncateForPreview(text: []const u8) []const u8 {
    var lines: usize = 0;
    for (text, 0..) |ch, i| {
        if (ch == '\n') {
            lines += 1;
            if (lines >= max_preview_lines) {
                return text[0..i];
            }
        }
    }
    return text;
}

/// Build a read-only context preview card using layoutStructuredCard.
/// Shows populated fields as labeled sections. Returns the card cells
/// and dimensions (caller must free cells).
pub fn layoutContextPreview(
    allocator: std.mem.Allocator,
    bundle: *const ContextBundle,
    max_width: u16,
    style: ContentStyle,
) !CardResult {
    // Build blocks dynamically based on which fields are populated
    var blocks: [8]ContentBlock = undefined;
    var block_count: usize = 0;

    // Header
    blocks[block_count] = .{ .tag = .header, .text = "Context Preview" };
    block_count += 1;

    // Title
    if (bundle.title) |t| {
        if (t.len > 0) {
            blocks[block_count] = .{ .tag = .paragraph, .text = t };
            block_count += 1;
        }
    }

    // Grid info line
    var info_buf: [64]u8 = undefined;
    const info_text = formatGridInfo(&info_buf, bundle);
    blocks[block_count] = .{ .tag = .paragraph, .text = info_text };
    block_count += 1;

    // Cursor line
    if (bundle.cursor_line) |cl| {
        if (cl.len > 0) {
            blocks[block_count] = .{ .tag = .code_block, .text = truncateForPreview(cl) };
            block_count += 1;
        }
    }

    // Selection
    if (bundle.selection_text) |sel| {
        if (sel.len > 0) {
            blocks[block_count] = .{ .tag = .code_block, .text = truncateForPreview(sel) };
            block_count += 1;
        }
    }

    // Scrollback excerpt
    if (bundle.scrollback_excerpt) |exc| {
        if (exc.len > 0) {
            blocks[block_count] = .{ .tag = .code_block, .text = truncateForPreview(exc) };
            block_count += 1;
        }
    }

    // Action bar: Back + Copy buttons
    var bar = action_mod.ActionBar{};
    bar.add(.dismiss, "Back");
    bar.add(.copy, "Copy");

    return content.layoutStructuredCard(
        allocator,
        "Context Preview",
        blocks[0..block_count],
        max_width,
        style,
        bar,
    );
}

/// Format grid dimensions and flags into a fixed buffer.
fn formatGridInfo(buf: *[64]u8, bundle: *const ContextBundle) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();
    w.print("Grid: {d}x{d}", .{ bundle.grid_cols, bundle.grid_rows }) catch {};
    if (bundle.alt_active) {
        w.writeAll(" (alt screen)") catch {};
    }
    return buf[0..stream.pos];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "fillSummaryRow: renders into cells" {
    const alloc = std.testing.allocator;
    const width: u16 = 40;
    const height: u16 = 3;
    const cell_count = @as(usize, width) * height;
    const cells = try alloc.alloc(OverlayCell, cell_count);
    defer alloc.free(cells);
    for (cells) |*cell| cell.* = OverlayCell{};

    // Minimal bundle
    var bundle = ContextBundle{
        .invocation = .general,
        .title = null,
        .selection_text = null,
        .scrollback_excerpt = null,
        .scrollback_line_count = 0,
        .cursor_line = null,
        .grid_cols = 80,
        .grid_rows = 24,
        .alt_active = false,
        .allocator = alloc,
    };

    fillSummaryRow(cells, width, 1, 2, width - 4, &bundle, .{});

    // Should have rendered "Context: (empty)" starting at col 2, row 1
    const idx = @as(usize, 1) * width + 2;
    try std.testing.expectEqual(@as(u21, 'C'), cells[idx].char);
}

test "layoutContextPreview: dimensions and content" {
    const alloc = std.testing.allocator;

    var bundle = ContextBundle{
        .invocation = .general,
        .title = "bash",
        .selection_text = null,
        .scrollback_excerpt = "line1\nline2",
        .scrollback_line_count = 2,
        .cursor_line = "$ ls -la",
        .grid_cols = 80,
        .grid_rows = 24,
        .alt_active = false,
        .allocator = alloc,
    };

    const result = try layoutContextPreview(alloc, &bundle, 50, .{});
    defer alloc.free(result.cells);

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
    try std.testing.expectEqual(@as(usize, @as(usize, result.width) * result.height), result.cells.len);
}

test "truncateForPreview: short text unchanged" {
    const text = "line1\nline2\nline3";
    const result = truncateForPreview(text);
    try std.testing.expectEqualStrings(text, result);
}

test "truncateForPreview: long text truncated" {
    // Build text with 25 lines
    const text = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n21\n22\n23\n24\n25";
    const result = truncateForPreview(text);
    // Should have at most max_preview_lines newlines
    var nl_count: usize = 0;
    for (result) |ch| {
        if (ch == '\n') nl_count += 1;
    }
    try std.testing.expect(nl_count <= max_preview_lines);
}
