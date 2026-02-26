const std = @import("std");
const grid_mod = @import("grid.zig");

/// Serialize the grid to a plain-text UTF-8 string for golden-test comparison.
///
/// Each cell is encoded as its UTF-8 representation, one cell per column,
/// with each row terminated by '\n'.
///
/// For pure-ASCII content the output is identical to the old format
/// (one byte per cell). Non-ASCII codepoints produce multi-byte output.
///
/// Caller owns the returned slice and must free it with `allocator`.
pub fn dumpToString(allocator: std.mem.Allocator, grid: *const grid_mod.Grid) ![]u8 {
    // Worst case: every cell is a 4-byte base + 2×4-byte combining + newlines.
    const max_len = grid.rows * (grid.cols * 12 + 1);
    const buf = try allocator.alloc(u8, max_len);

    var pos: usize = 0;
    for (0..grid.rows) |row| {
        for (0..grid.cols) |col| {
            const cell = grid.getCell(row, col);
            const n = std.unicode.utf8Encode(cell.char, buf[pos..]) catch 1;
            pos += n;
            // Emit combining marks
            for (cell.combining) |cm| {
                if (cm == 0) break;
                const cn = std.unicode.utf8Encode(cm, buf[pos..]) catch 1;
                pos += cn;
            }
        }
        buf[pos] = '\n';
        pos += 1;
    }

    // Shrink to actual size.
    if (pos < max_len) {
        return allocator.realloc(buf, pos);
    }
    return buf;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "snapshot of empty grid is all spaces" {
    const alloc = std.testing.allocator;
    var g = try grid_mod.Grid.init(alloc, 2, 3);
    defer g.deinit();

    const snap = try dumpToString(alloc, &g);
    defer alloc.free(snap);

    try std.testing.expectEqualStrings("   \n   \n", snap);
}

test "snapshot preserves content and trailing spaces" {
    const alloc = std.testing.allocator;
    var g = try grid_mod.Grid.init(alloc, 2, 4);
    defer g.deinit();

    g.setCell(0, 0, .{ .char = 'H' });
    g.setCell(0, 1, .{ .char = 'i' });

    const snap = try dumpToString(alloc, &g);
    defer alloc.free(snap);

    try std.testing.expectEqualStrings("Hi  \n    \n", snap);
}
