const std = @import("std");
const RingBuffer = @import("../../term/ring.zig").RingBuffer;
const Cell = @import("../../term/grid.zig").Cell;
const Engine = @import("../../term/engine.zig").Engine;

test "scrollback: push and get single line" {
    const alloc = std.testing.allocator;
    // 1 screen row, 3 cols, 4 scrollback capacity
    var ring = try RingBuffer.init(alloc, 1, 3, 4);
    defer ring.deinit();

    // Write "ABC" on screen row 0
    ring.setScreenCell(0, 0, .{ .char = 'A' });
    ring.setScreenCell(0, 1, .{ .char = 'B' });
    ring.setScreenCell(0, 2, .{ .char = 'C' });
    // Advance to push row into scrollback
    _ = ring.advanceScreen();

    try std.testing.expectEqual(@as(usize, 1), ring.scrollbackCount());
    const got = ring.getRow(0);
    try std.testing.expectEqual(@as(u21, 'A'), got[0].char);
    try std.testing.expectEqual(@as(u21, 'B'), got[1].char);
    try std.testing.expectEqual(@as(u21, 'C'), got[2].char);
}

test "scrollback: ring wrap-around" {
    const alloc = std.testing.allocator;
    // 1 screen row, 2 cols, 3 scrollback capacity
    var ring = try RingBuffer.init(alloc, 1, 2, 3);
    defer ring.deinit();

    // Push 5 lines into a 3-line scrollback — first 2 should be overwritten
    for (0..5) |i| {
        ring.setScreenCell(0, 0, .{ .char = @intCast('a' + i) });
        ring.setScreenCell(0, 1, .{ .char = @intCast('A' + i) });
        _ = ring.advanceScreen();
    }

    try std.testing.expectEqual(@as(usize, 3), ring.scrollbackCount());
    // Oldest surviving line is line 2 (index 0): 'c','C'
    try std.testing.expectEqual(@as(u21, 'c'), ring.getRow(0)[0].char);
    try std.testing.expectEqual(@as(u21, 'd'), ring.getRow(1)[0].char);
    try std.testing.expectEqual(@as(u21, 'e'), ring.getRow(2)[0].char);
}

test "scrollback: clear resets count" {
    const alloc = std.testing.allocator;
    // 1 screen row, 2 cols, 4 scrollback capacity
    var ring = try RingBuffer.init(alloc, 1, 2, 4);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'X' });
    ring.setScreenCell(0, 1, .{ .char = 'Y' });
    _ = ring.advanceScreen();
    ring.setScreenCell(0, 0, .{ .char = 'X' });
    ring.setScreenCell(0, 1, .{ .char = 'Y' });
    _ = ring.advanceScreen();
    try std.testing.expectEqual(@as(usize, 2), ring.scrollbackCount());

    ring.clearScrollback();
    try std.testing.expectEqual(@as(usize, 0), ring.scrollbackCount());
}

test "scrollback: integration — scroll_up saves top row" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 3, 4, 100);
    defer engine.deinit();

    // Fill 3 rows
    engine.feed("AAAA\r\nBBBB\r\nCCCC");

    try std.testing.expectEqual(@as(u21, 'A'), engine.state.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), engine.state.ring.getScreenCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), engine.state.ring.getScreenCell(2, 0).char);
    try std.testing.expectEqual(@as(usize, 0), engine.state.ring.scrollbackCount());

    // One more line feed at the bottom scrolls row 0 ("AAAA") into scrollback
    engine.feed("\r\nDDDD");

    try std.testing.expectEqual(@as(usize, 1), engine.state.ring.scrollbackCount());
    const saved = engine.state.ring.getRow(0);
    try std.testing.expectEqual(@as(u21, 'A'), saved[0].char);
    try std.testing.expectEqual(@as(u21, 'A'), saved[1].char);

    // Grid should now be B, C, D
    try std.testing.expectEqual(@as(u21, 'B'), engine.state.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), engine.state.ring.getScreenCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), engine.state.ring.getScreenCell(2, 0).char);
}

test "scrollback: alt screen does not save" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 3, 4, 100);
    defer engine.deinit();

    engine.feed("AAAA\r\nBBBB\r\nCCCC");
    // Enter alt screen
    engine.feed("\x1b[?1049h");
    try std.testing.expect(engine.state.alt_active);

    // Fill and scroll in alt screen
    engine.feed("1111\r\n2222\r\n3333\r\n4444");

    // Nothing should be saved to scrollback (alt screen)
    try std.testing.expectEqual(@as(usize, 0), engine.state.ring.scrollbackCount());

    // Leave alt screen
    engine.feed("\x1b[?1049l");
    try std.testing.expect(!engine.state.alt_active);
}

test "scrollback: CSI scroll_up saves multiple rows" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 4, 3, 100);
    defer engine.deinit();

    engine.feed("AAA\r\nBBB\r\nCCC\r\nDDD");
    try std.testing.expectEqual(@as(usize, 0), engine.state.ring.scrollbackCount());

    // CSI 2 S — scroll up 2 lines
    engine.feed("\x1b[2S");

    try std.testing.expectEqual(@as(usize, 2), engine.state.ring.scrollbackCount());
    try std.testing.expectEqual(@as(u21, 'A'), engine.state.ring.getRow(0)[0].char);
    try std.testing.expectEqual(@as(u21, 'B'), engine.state.ring.getRow(1)[0].char);
}

test "scrollback: viewport_offset bumped on scroll when >0" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 3, 4, 100);
    defer engine.deinit();

    engine.feed("AAAA\r\nBBBB\r\nCCCC");
    // Scroll once to build some scrollback
    engine.feed("\r\nDDDD");
    try std.testing.expectEqual(@as(usize, 1), engine.state.ring.scrollbackCount());

    // Simulate user scrolling up
    engine.state.viewport_offset = 1;

    // More output causes another scroll
    engine.feed("\r\nEEEE");

    // viewport_offset should have been bumped from 1 to 2
    try std.testing.expectEqual(@as(usize, 2), engine.state.viewport_offset);
    try std.testing.expectEqual(@as(usize, 2), engine.state.ring.scrollbackCount());
}

test "scrollback: resize migrates scrollback on column change" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 3, 4, 100);
    defer engine.deinit();

    engine.feed("AAAA\r\nBBBB\r\nCCCC\r\nDDDD");
    const count_before = engine.state.ring.scrollbackCount();
    try std.testing.expect(count_before > 0);

    try engine.state.resize(3, 6);
    // Scrollback is migrated (not cleared) — content is preserved
    try std.testing.expectEqual(count_before, engine.state.ring.scrollbackCount());
    try std.testing.expectEqual(@as(usize, 6), engine.state.ring.cols);
    // First saved line should still start with 'A' (padded to 6 cols)
    try std.testing.expectEqual(@as(u21, 'A'), engine.state.ring.getRow(0)[0].char);
    try std.testing.expectEqual(@as(usize, 0), engine.state.viewport_offset);
}

test "scrollback: vertical shrink saves content, grow preserves scrollback" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 4, 4, 100);
    defer engine.deinit();

    // Fill all 4 rows, cursor ends at row 3
    engine.feed("AAAA\r\nBBBB\r\nCCCC\r\nDDDD");
    try std.testing.expectEqual(@as(u21, 'A'), engine.state.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), engine.state.ring.getScreenCell(3, 0).char);
    try std.testing.expectEqual(@as(usize, 3), engine.state.cursor.row);

    // Shrink to 2 rows — rows A and B should go to scrollback
    try engine.state.resize(2, 4);
    try std.testing.expectEqual(@as(usize, 2), engine.state.ring.scrollbackCount());
    try std.testing.expectEqual(@as(u21, 'C'), engine.state.ring.getScreenCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), engine.state.ring.getScreenCell(1, 0).char);
    try std.testing.expectEqual(@as(usize, 1), engine.state.cursor.row);

    // Grow back to 4 rows — scrollback content is preserved (not
    // injected into the grid, which would confuse the shell).  The
    // user can scroll up to see it.  Content is pinned to the bottom
    // because the cursor was at the last row of the 2-row grid.
    try engine.state.resize(4, 4);
    try std.testing.expectEqual(@as(usize, 2), engine.state.ring.scrollbackCount());
    try std.testing.expectEqual(@as(u21, 'A'), engine.state.ring.getRow(0)[0].char);
    try std.testing.expectEqual(@as(u21, 'B'), engine.state.ring.getRow(1)[0].char);
    // Grid content shifted to bottom (rows 2-3), top rows blank
    try std.testing.expectEqual(@as(u21, 'C'), engine.state.ring.getScreenCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), engine.state.ring.getScreenCell(3, 0).char);
    try std.testing.expectEqual(@as(usize, 3), engine.state.cursor.row);
}

test "scrollback: col-change resize saves dropped rows via reflow" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 4, 6, 100);
    defer engine.deinit();

    // Fill 4 rows at 6 cols, cursor ends at row 3
    engine.feed("ABCDEF\r\nGHIJKL\r\nMNOPQR\r\nSTUVWX");
    try std.testing.expectEqual(@as(usize, 3), engine.state.cursor.row);

    // Shrink cols from 6 to 3 AND rows from 4 to 4.
    // Each 6-char line wraps into 2 rows at 3 cols → 8 rows needed.
    // Cursor maps to row 7. scroll_off = 7 - 4 + 1 = 4.
    // The top 4 reflowed rows (ABC, DEF, GHI, JKL) go to scrollback.
    try engine.state.resize(4, 3);
    try std.testing.expectEqual(@as(usize, 4), engine.state.ring.scrollbackCount());
    try std.testing.expectEqual(@as(usize, 3), engine.state.ring.cols);
    try std.testing.expectEqual(@as(u21, 'A'), engine.state.ring.getRow(0)[0].char);
    try std.testing.expectEqual(@as(u21, 'D'), engine.state.ring.getRow(1)[0].char);
    try std.testing.expectEqual(@as(u21, 'G'), engine.state.ring.getRow(2)[0].char);
    try std.testing.expectEqual(@as(u21, 'J'), engine.state.ring.getRow(3)[0].char);
}
