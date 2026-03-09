const std = @import("std");
const grid_mod = @import("grid.zig");
const ring_mod = @import("ring.zig");

/// Serialize the visible screen to a plain-text UTF-8 string for golden-test comparison.
///
/// Each cell is encoded as its UTF-8 representation, one cell per column,
/// with each row terminated by '\n'.
///
/// Caller owns the returned slice and must free it with `allocator`.
pub fn dumpToString(allocator: std.mem.Allocator, ring: *const ring_mod.RingBuffer) ![]u8 {
    const rows = ring.screen_rows;
    const cols = ring.cols;
    // Worst case: every cell is a 4-byte base + 2×4-byte combining + newlines.
    const max_len = rows * (cols * 12 + 1);
    const buf = try allocator.alloc(u8, max_len);

    var pos: usize = 0;
    for (0..rows) |row| {
        const row_cells = ring.getScreenRow(row);
        for (0..cols) |col| {
            const cell = row_cells[col];
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

test "snapshot of empty screen is all spaces" {
    const alloc = std.testing.allocator;
    var ring = try ring_mod.RingBuffer.init(alloc, 2, 3, 10);
    defer ring.deinit();

    const snap = try dumpToString(alloc, &ring);
    defer alloc.free(snap);

    try std.testing.expectEqualStrings("   \n   \n", snap);
}

test "snapshot preserves content and trailing spaces" {
    const alloc = std.testing.allocator;
    var ring = try ring_mod.RingBuffer.init(alloc, 2, 4, 10);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'H' });
    ring.setScreenCell(0, 1, .{ .char = 'i' });

    const snap = try dumpToString(alloc, &ring);
    defer alloc.free(snap);

    try std.testing.expectEqualStrings("Hi  \n    \n", snap);
}
