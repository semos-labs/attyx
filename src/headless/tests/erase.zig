const std = @import("std");
const TerminalState = @import("../../term/state.zig").TerminalState;
const Cell = @import("../../term/grid.zig").Cell;

// ===========================================================================
// Erase Display — state-level tests
// ===========================================================================

test "ED to_end: marks dirty rows from cursor to end" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 6, 100);
    defer t.deinit();

    for ("Hello!") |ch| t.apply(.{ .print = ch });
    t.apply(.{ .control = .lf });
    t.apply(.{ .control = .cr });
    for ("World!") |ch| t.apply(.{ .print = ch });

    // Position cursor at row 1, col 2
    t.cursor.row = 1;
    t.cursor.col = 2;
    t.dirty.clear();

    t.apply(.{ .erase_display = .to_end });

    // Rows 1-3 should be dirty, row 0 should not
    try std.testing.expect(!t.dirty.isDirty(0));
    try std.testing.expect(t.dirty.isDirty(1));
    try std.testing.expect(t.dirty.isDirty(2));
    try std.testing.expect(t.dirty.isDirty(3));

    // Content before cursor (row 0, row 1 cols 0-1) preserved
    try std.testing.expectEqual(@as(u21, 'H'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'W'), t.ring.getScreenCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'o'), t.ring.getScreenCell(1, 1).char);
    // At and after cursor cleared
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(1, 2).char);
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(2, 0).char);
}

test "ED to_start: marks dirty rows from start to cursor" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 6, 100);
    defer t.deinit();

    for ("AAAAAA") |ch| t.apply(.{ .print = ch });
    t.apply(.{ .control = .lf });
    t.apply(.{ .control = .cr });
    for ("BBBBBB") |ch| t.apply(.{ .print = ch });
    t.apply(.{ .control = .lf });
    t.apply(.{ .control = .cr });
    for ("CCCCCC") |ch| t.apply(.{ .print = ch });

    // Position cursor at row 1, col 3
    t.cursor.row = 1;
    t.cursor.col = 3;
    t.dirty.clear();

    t.apply(.{ .erase_display = .to_start });

    // Rows 0-1 should be dirty
    try std.testing.expect(t.dirty.isDirty(0));
    try std.testing.expect(t.dirty.isDirty(1));
    // Rows 2-3 should not be dirty
    try std.testing.expect(!t.dirty.isDirty(2));
    try std.testing.expect(!t.dirty.isDirty(3));

    // Row 0 fully cleared
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(0, 0).char);
    // Row 1 cols 0-3 cleared, cols 4-5 preserved
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(1, 3).char);
    try std.testing.expectEqual(@as(u21, 'B'), t.ring.getScreenCell(1, 4).char);
    // Row 2 preserved
    try std.testing.expectEqual(@as(u21, 'C'), t.ring.getScreenCell(2, 0).char);
}

test "ED all (main): saves content to scrollback before clear" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 4, 100);
    defer t.deinit();

    for ("ABCD") |ch| t.apply(.{ .print = ch });
    t.apply(.{ .control = .lf });
    t.apply(.{ .control = .cr });
    for ("EFGH") |ch| t.apply(.{ .print = ch });

    const count_before = t.ring.scrollbackCount();

    t.apply(.{ .erase_display = .all });

    // Scrollback should have increased (rows 0-1 had content)
    try std.testing.expect(t.ring.scrollbackCount() > count_before);
    // Screen should be clear
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(1, 0).char);
}

test "ED all (alt): does NOT save to scrollback" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 4, 100);
    defer t.deinit();

    t.apply(.enter_alt_screen);
    for ("ABCD") |ch| t.apply(.{ .print = ch });

    const count_before = t.ring.scrollbackCount();

    t.apply(.{ .erase_display = .all });

    // Scrollback unchanged on alt screen
    try std.testing.expectEqual(count_before, t.ring.scrollbackCount());
    // Screen cleared
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(0, 0).char);
}

test "ED scrollback: clears scrollback and resets viewport_offset" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 4, 100);
    defer t.deinit();

    // Push some lines to scrollback via ED all
    for ("ABCD") |ch| t.apply(.{ .print = ch });
    t.apply(.{ .erase_display = .all });
    try std.testing.expect(t.ring.scrollbackCount() > 0);

    // Simulate user scrolled back
    t.viewport_offset = 5;

    t.apply(.{ .erase_display = .scrollback });

    try std.testing.expectEqual(@as(usize, 0), t.ring.scrollbackCount());
    try std.testing.expectEqual(@as(usize, 0), t.viewport_offset);
}

// ===========================================================================
// Erase Line — state-level tests
// ===========================================================================

test "EL to_end: clears row_wrapped flag" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 4, 100);
    defer t.deinit();

    // Fill row and trigger wrap
    for ("ABCDE") |ch| t.apply(.{ .print = ch });
    try std.testing.expect(t.ring.getScreenWrapped(0));

    // Move back to row 0 and erase to end
    t.cursor.row = 0;
    t.cursor.col = 2;
    t.apply(.{ .erase_line = .to_end });

    try std.testing.expect(!t.ring.getScreenWrapped(0));
    try std.testing.expectEqual(@as(u21, 'A'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), t.ring.getScreenCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(0, 2).char);
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(0, 3).char);
}

test "EL to_start: clears cells from start to cursor inclusive" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 6, 100);
    defer t.deinit();

    for ("ABCDEF") |ch| t.apply(.{ .print = ch });
    t.cursor.row = 0;
    t.cursor.col = 3;

    t.apply(.{ .erase_line = .to_start });

    // Cols 0-3 cleared
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(0, 3).char);
    // Cols 4-5 preserved
    try std.testing.expectEqual(@as(u21, 'E'), t.ring.getScreenCell(0, 4).char);
    try std.testing.expectEqual(@as(u21, 'F'), t.ring.getScreenCell(0, 5).char);
}

test "EL all: clears entire row" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 6, 100);
    defer t.deinit();

    for ("ABCDEF") |ch| t.apply(.{ .print = ch });
    t.cursor.row = 0;
    t.cursor.col = 2;

    t.apply(.{ .erase_line = .all });

    for (0..6) |c| {
        try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(0, c).char);
    }
}
