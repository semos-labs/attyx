const std = @import("std");
const TerminalState = @import("../../term/state.zig").TerminalState;

// ===========================================================================
// Resize (with reflow)
// ===========================================================================

test "resize: grow preserves content" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4, 100);
    defer t.deinit();

    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });

    try t.resize(4, 8);

    try std.testing.expectEqual(@as(usize, 4), t.ring.screen_rows);
    try std.testing.expectEqual(@as(usize, 8), t.ring.cols);
    try std.testing.expectEqual(@as(u21, 'A'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), t.ring.getScreenCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(0, 4).char);
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(3, 0).char);
}

test "resize: shrink reflows content" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 8, 100);
    defer t.deinit();

    // Print "ABCD" — 4 chars at 8-col width, NOT a wrapped line
    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });
    t.apply(.{ .print = 'C' });
    t.apply(.{ .print = 'D' });

    // Move cursor below content (simulates prompt position in real usage)
    t.cursor.row = 1;
    t.cursor.col = 0;

    try t.resize(4, 3);

    try std.testing.expectEqual(@as(usize, 4), t.ring.screen_rows);
    try std.testing.expectEqual(@as(usize, 3), t.ring.cols);
    // "ABCD" reflows: row 0 = "ABC" (wrapped), row 1 = "D"
    try std.testing.expectEqual(@as(u21, 'A'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), t.ring.getScreenCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'C'), t.ring.getScreenCell(0, 2).char);
    try std.testing.expect(t.ring.getScreenWrapped(0));
    try std.testing.expectEqual(@as(u21, 'D'), t.ring.getScreenCell(1, 0).char);
    try std.testing.expect(!t.ring.getScreenWrapped(1));
}

test "resize: shrink then grow restores content" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 8, 100);
    defer t.deinit();

    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });
    t.apply(.{ .print = 'C' });
    t.apply(.{ .print = 'D' });
    t.apply(.{ .print = 'E' });
    t.apply(.{ .print = 'F' });

    // Move cursor below content (simulates prompt position)
    t.cursor.row = 1;
    t.cursor.col = 0;

    try t.resize(4, 3);
    try std.testing.expectEqual(@as(u21, 'D'), t.ring.getScreenCell(1, 0).char);

    try t.resize(4, 8);
    try std.testing.expectEqual(@as(u21, 'A'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'F'), t.ring.getScreenCell(0, 5).char);
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(1, 0).char);
}

test "resize: cursor mapped through reflow" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 8, 100);
    defer t.deinit();

    // Print 6 chars, cursor ends at (0, 6)
    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });
    t.apply(.{ .print = 'C' });
    t.apply(.{ .print = 'D' });
    t.apply(.{ .print = 'E' });
    t.apply(.{ .print = 'F' });
    try std.testing.expectEqual(@as(usize, 0), t.cursor.row);
    try std.testing.expectEqual(@as(usize, 6), t.cursor.col);

    try t.resize(4, 3);

    // Reflow maps cursor to row 2, col 0 in the reflowed content, but
    // state_resize clamps it back to the old screen row (0) so the
    // shell's SIGWINCH redraw doesn't leave ghost prompt lines.
    try std.testing.expectEqual(@as(usize, 0), t.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), t.cursor.col);
}

test "resize: cursor clamped to new bounds" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 10, 20, 100);
    defer t.deinit();

    t.cursor = .{ .row = 8, .col = 15 };

    try t.resize(5, 10);

    try std.testing.expect(t.cursor.row <= 4);
    try std.testing.expect(t.cursor.col <= 9);
}

test "resize: scroll region reset when invalid" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 10, 20, 100);
    defer t.deinit();

    t.scroll_top = 2;
    t.scroll_bottom = 8;

    try t.resize(3, 20);

    try std.testing.expectEqual(@as(usize, 0), t.scroll_top);
    try std.testing.expectEqual(@as(usize, 2), t.scroll_bottom);
}

test "resize: saved cursor clamped" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 10, 20, 100);
    defer t.deinit();

    t.cursor = .{ .row = 7, .col = 15 };
    t.apply(.save_cursor);

    try t.resize(5, 10);

    const saved = t.saved_cursor.?;
    try std.testing.expect(saved.cursor.row <= 4);
    try std.testing.expect(saved.cursor.col <= 9);
}

test "resize: both buffers resized" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 8, 100);
    defer t.deinit();

    t.apply(.{ .print = 'M' });
    t.apply(.enter_alt_screen);
    t.apply(.{ .print = 'A' });

    try t.resize(6, 12);

    try std.testing.expectEqual(@as(usize, 6), t.ring.screen_rows);
    try std.testing.expectEqual(@as(usize, 12), t.ring.cols);
    try std.testing.expectEqual(@as(u21, 'A'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(usize, 6), t.inactive_grid.rows);
    try std.testing.expectEqual(@as(usize, 12), t.inactive_grid.cols);
    try std.testing.expectEqual(@as(u21, 'M'), t.inactive_grid.getCell(0, 0).char);
}

test "resize: wrap_next cleared" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4, 100);
    defer t.deinit();

    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });
    t.apply(.{ .print = 'C' });
    t.apply(.{ .print = 'D' });
    try std.testing.expect(t.wrap_next);

    try t.resize(2, 8);

    try std.testing.expect(!t.wrap_next);
}

test "resize: same size is no-op" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 8, 100);
    defer t.deinit();

    t.apply(.{ .print = 'X' });
    const ptr_before = t.ring.cells.ptr;

    try t.resize(4, 8);

    try std.testing.expectEqual(ptr_before, t.ring.cells.ptr);
    try std.testing.expectEqual(@as(u21, 'X'), t.ring.getScreenCell(0, 0).char);
}

test "resize: marks all rows dirty" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 8, 100);
    defer t.deinit();

    t.dirty.clear();

    try t.resize(6, 10);

    for (0..6) |row| {
        try std.testing.expect(t.dirty.isDirty(row));
    }
}
