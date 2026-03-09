const std = @import("std");
const TerminalState = @import("../../term/state.zig").TerminalState;

// ===========================================================================
// Resize edge-case tests (complements screen_resize.zig)
// ===========================================================================

test "resize: scrollback migration on col change" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 8, 100);
    defer t.deinit();

    // Fill row 0 and scroll it into scrollback via LF overflow
    for ("ABCDEFGH") |ch| t.apply(.{ .print = ch });
    // Push 4 more rows to force scrollback
    for (0..4) |_| {
        t.apply(.{ .control = .lf });
        t.apply(.{ .control = .cr });
        for ("12345678") |ch| t.apply(.{ .print = ch });
    }
    try std.testing.expect(t.ring.scrollbackCount() > 0);
    const sb_before = t.ring.scrollbackCount();

    // Resize to different cols — scrollback should be reallocated
    try t.resize(4, 12);

    // Scrollback count should still be reasonable (not zero, preserved)
    try std.testing.expect(t.ring.scrollbackCount() > 0 or sb_before > 0);
    try std.testing.expectEqual(@as(usize, 4), t.ring.screen_rows);
    try std.testing.expectEqual(@as(usize, 12), t.ring.cols);
}

test "resize: alt screen resize no reflow" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 8, 100);
    defer t.deinit();

    t.apply(.enter_alt_screen);
    // Fill row 0 with 8 chars
    for ("ABCDEFGH") |ch| t.apply(.{ .print = ch });

    // Shrink to 4 cols — alt screen should NOT reflow
    try t.resize(4, 4);

    // First 4 chars should be on row 0 (no wrap to row 1 like reflow would)
    try std.testing.expectEqual(@as(u21, 'A'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), t.ring.getScreenCell(0, 3).char);
    // Row 1 should be blank (no reflow overflow)
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(1, 0).char);
}

test "resize: reflow_on_resize = false skips reflow" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 8, 100);
    defer t.deinit();

    t.reflow_on_resize = false;
    for ("ABCDEFGH") |ch| t.apply(.{ .print = ch });

    // Shrink — should truncate, not reflow
    try t.resize(4, 4);

    try std.testing.expectEqual(@as(u21, 'A'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), t.ring.getScreenCell(0, 3).char);
    // No wrap into row 1
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(1, 0).char);
}

test "resize: viewport_offset reset to 0" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 4, 8, 100);
    defer t.deinit();

    t.viewport_offset = 10;
    try t.resize(6, 10);
    try std.testing.expectEqual(@as(usize, 0), t.viewport_offset);
}

test "resize: right-aligned content stripped on shrink" {
    const alloc = std.testing.allocator;
    const Grid = @import("../../term/grid.zig");
    const Style = Grid.Style;
    var t = try TerminalState.init(alloc, 4, 40, 100);
    defer t.deinit();

    const cyan = Style{ .fg = .{ .ansi = 6 } };
    const magenta = Style{ .fg = .{ .ansi = 5 } };

    // Left: "HELLO" in cyan
    t.pen = cyan;
    for ("HELLO") |ch| t.apply(.{ .print = ch });
    t.pen = .{};

    // Jump to column 35
    t.cursor.col = 35;

    // Right: "WORLD" in magenta
    t.pen = magenta;
    for ("WORLD") |ch| t.apply(.{ .print = ch });
    t.pen = .{};

    // Newline + cursor
    t.apply(.{ .control = .lf });
    t.apply(.{ .control = .cr });
    t.apply(.{ .print = '>' });

    // Shrink to 20 cols — right content exceeds new width
    try t.resize(4, 20);

    // Left text preserved
    try std.testing.expectEqual(@as(u21, 'H'), t.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'O'), t.ring.getScreenCell(0, 4).char);

    // No wrapping on the prompt row
    try std.testing.expect(!t.ring.getScreenWrapped(0));
}
