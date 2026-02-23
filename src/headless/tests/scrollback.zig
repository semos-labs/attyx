const std = @import("std");
const Scrollback = @import("../../term/scrollback.zig").Scrollback;
const Cell = @import("../../term/grid.zig").Cell;
const Engine = @import("../../term/engine.zig").Engine;

test "scrollback: push and get single line" {
    const alloc = std.testing.allocator;
    var sb = try Scrollback.init(alloc, 4, 3);
    defer sb.deinit();

    var line: [3]Cell = .{
        .{ .char = 'A' },
        .{ .char = 'B' },
        .{ .char = 'C' },
    };
    sb.pushLine(&line);

    try std.testing.expectEqual(@as(usize, 1), sb.count);
    const got = sb.getLine(0);
    try std.testing.expectEqual(@as(u21, 'A'), got[0].char);
    try std.testing.expectEqual(@as(u21, 'B'), got[1].char);
    try std.testing.expectEqual(@as(u21, 'C'), got[2].char);
}

test "scrollback: ring wrap-around" {
    const alloc = std.testing.allocator;
    var sb = try Scrollback.init(alloc, 3, 2);
    defer sb.deinit();

    // Push 5 lines into a 3-line ring — first 2 should be overwritten
    var line: [2]Cell = undefined;
    for (0..5) |i| {
        line[0] = .{ .char = @intCast('a' + i) };
        line[1] = .{ .char = @intCast('A' + i) };
        sb.pushLine(&line);
    }

    try std.testing.expectEqual(@as(usize, 3), sb.count);
    // Oldest surviving line is line 2 (index 0): 'c','C'
    try std.testing.expectEqual(@as(u21, 'c'), sb.getLine(0)[0].char);
    try std.testing.expectEqual(@as(u21, 'd'), sb.getLine(1)[0].char);
    try std.testing.expectEqual(@as(u21, 'e'), sb.getLine(2)[0].char);
}

test "scrollback: clear resets count" {
    const alloc = std.testing.allocator;
    var sb = try Scrollback.init(alloc, 4, 2);
    defer sb.deinit();

    var line = [2]Cell{ .{ .char = 'X' }, .{ .char = 'Y' } };
    sb.pushLine(&line);
    sb.pushLine(&line);
    try std.testing.expectEqual(@as(usize, 2), sb.count);

    sb.clear();
    try std.testing.expectEqual(@as(usize, 0), sb.count);
}

test "scrollback: integration — scroll_up saves top row" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 3, 4);
    defer engine.deinit();

    // Fill 3 rows
    engine.feed("AAAA\r\nBBBB\r\nCCCC");

    try std.testing.expectEqual(@as(u21, 'A'), engine.state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), engine.state.grid.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), engine.state.grid.getCell(2, 0).char);
    try std.testing.expectEqual(@as(usize, 0), engine.state.scrollback.count);

    // One more line feed at the bottom scrolls row 0 ("AAAA") into scrollback
    engine.feed("\r\nDDDD");

    try std.testing.expectEqual(@as(usize, 1), engine.state.scrollback.count);
    const saved = engine.state.scrollback.getLine(0);
    try std.testing.expectEqual(@as(u21, 'A'), saved[0].char);
    try std.testing.expectEqual(@as(u21, 'A'), saved[1].char);

    // Grid should now be B, C, D
    try std.testing.expectEqual(@as(u21, 'B'), engine.state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), engine.state.grid.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), engine.state.grid.getCell(2, 0).char);
}

test "scrollback: alt screen does not save" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 3, 4);
    defer engine.deinit();

    engine.feed("AAAA\r\nBBBB\r\nCCCC");
    // Enter alt screen
    engine.feed("\x1b[?1049h");
    try std.testing.expect(engine.state.alt_active);

    // Fill and scroll in alt screen
    engine.feed("1111\r\n2222\r\n3333\r\n4444");

    // Nothing should be saved to scrollback (alt screen)
    try std.testing.expectEqual(@as(usize, 0), engine.state.scrollback.count);

    // Leave alt screen
    engine.feed("\x1b[?1049l");
    try std.testing.expect(!engine.state.alt_active);
}

test "scrollback: CSI scroll_up saves multiple rows" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 4, 3);
    defer engine.deinit();

    engine.feed("AAA\r\nBBB\r\nCCC\r\nDDD");
    try std.testing.expectEqual(@as(usize, 0), engine.state.scrollback.count);

    // CSI 2 S — scroll up 2 lines
    engine.feed("\x1b[2S");

    try std.testing.expectEqual(@as(usize, 2), engine.state.scrollback.count);
    try std.testing.expectEqual(@as(u21, 'A'), engine.state.scrollback.getLine(0)[0].char);
    try std.testing.expectEqual(@as(u21, 'B'), engine.state.scrollback.getLine(1)[0].char);
}

test "scrollback: viewport_offset bumped on scroll when >0" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 3, 4);
    defer engine.deinit();

    engine.feed("AAAA\r\nBBBB\r\nCCCC");
    // Scroll once to build some scrollback
    engine.feed("\r\nDDDD");
    try std.testing.expectEqual(@as(usize, 1), engine.state.scrollback.count);

    // Simulate user scrolling up
    engine.state.viewport_offset = 1;

    // More output causes another scroll
    engine.feed("\r\nEEEE");

    // viewport_offset should have been bumped from 1 to 2
    try std.testing.expectEqual(@as(usize, 2), engine.state.viewport_offset);
    try std.testing.expectEqual(@as(usize, 2), engine.state.scrollback.count);
}

test "scrollback: resize migrates scrollback on column change" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 3, 4);
    defer engine.deinit();

    engine.feed("AAAA\r\nBBBB\r\nCCCC\r\nDDDD");
    const count_before = engine.state.scrollback.count;
    try std.testing.expect(count_before > 0);

    try engine.state.resize(3, 6);
    // Scrollback is migrated (not cleared) — content is preserved
    try std.testing.expectEqual(count_before, engine.state.scrollback.count);
    try std.testing.expectEqual(@as(usize, 6), engine.state.scrollback.cols);
    // First saved line should still start with 'A' (padded to 6 cols)
    try std.testing.expectEqual(@as(u21, 'A'), engine.state.scrollback.getLine(0)[0].char);
    try std.testing.expectEqual(@as(usize, 0), engine.state.viewport_offset);
}

test "scrollback: vertical shrink saves content, grow preserves scrollback" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 4, 4);
    defer engine.deinit();

    // Fill all 4 rows, cursor ends at row 3
    engine.feed("AAAA\r\nBBBB\r\nCCCC\r\nDDDD");
    try std.testing.expectEqual(@as(u21, 'A'), engine.state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), engine.state.grid.getCell(3, 0).char);
    try std.testing.expectEqual(@as(usize, 3), engine.state.cursor.row);

    // Shrink to 2 rows — rows A and B should go to scrollback
    try engine.state.resize(2, 4);
    try std.testing.expectEqual(@as(usize, 2), engine.state.scrollback.count);
    try std.testing.expectEqual(@as(u21, 'C'), engine.state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), engine.state.grid.getCell(1, 0).char);
    try std.testing.expectEqual(@as(usize, 1), engine.state.cursor.row);

    // Grow back to 4 rows — scrollback content is preserved (not
    // injected into the grid, which would confuse the shell).  The
    // user can scroll up to see it.  Content is pinned to the bottom
    // because the cursor was at the last row of the 2-row grid.
    try engine.state.resize(4, 4);
    try std.testing.expectEqual(@as(usize, 2), engine.state.scrollback.count);
    try std.testing.expectEqual(@as(u21, 'A'), engine.state.scrollback.getLine(0)[0].char);
    try std.testing.expectEqual(@as(u21, 'B'), engine.state.scrollback.getLine(1)[0].char);
    // Grid content shifted to bottom (rows 2-3), top rows blank
    try std.testing.expectEqual(@as(u21, 'C'), engine.state.grid.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), engine.state.grid.getCell(3, 0).char);
    try std.testing.expectEqual(@as(usize, 3), engine.state.cursor.row);
}

test "scrollback: col-change resize saves dropped rows via reflow" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 4, 6);
    defer engine.deinit();

    // Fill 4 rows at 6 cols, cursor ends at row 3
    engine.feed("ABCDEF\r\nGHIJKL\r\nMNOPQR\r\nSTUVWX");
    try std.testing.expectEqual(@as(usize, 3), engine.state.cursor.row);

    // Shrink cols from 6 to 3 AND rows from 4 to 4.
    // Each 6-char line wraps into 2 rows at 3 cols → 8 rows needed.
    // Cursor maps to row 7. scroll_off = 7 - 4 + 1 = 4.
    // The top 4 reflowed rows (ABC, DEF, GHI, JKL) go to scrollback.
    try engine.state.resize(4, 3);
    try std.testing.expectEqual(@as(usize, 4), engine.state.scrollback.count);
    try std.testing.expectEqual(@as(usize, 3), engine.state.scrollback.cols);
    try std.testing.expectEqual(@as(u21, 'A'), engine.state.scrollback.getLine(0)[0].char);
    try std.testing.expectEqual(@as(u21, 'D'), engine.state.scrollback.getLine(1)[0].char);
    try std.testing.expectEqual(@as(u21, 'G'), engine.state.scrollback.getLine(2)[0].char);
    try std.testing.expectEqual(@as(u21, 'J'), engine.state.scrollback.getLine(3)[0].char);
}

test "scrollback: removeRecent drops most recent lines" {
    const alloc = std.testing.allocator;
    var sb = try Scrollback.init(alloc, 10, 2);
    defer sb.deinit();

    var line: [2]Cell = undefined;
    for (0..5) |i| {
        line[0] = .{ .char = @intCast('A' + i) };
        line[1] = .{ .char = ' ' };
        sb.pushLine(&line);
    }
    try std.testing.expectEqual(@as(usize, 5), sb.count);

    // Remove 2 most recent (D, E)
    sb.removeRecent(2);
    try std.testing.expectEqual(@as(usize, 3), sb.count);
    try std.testing.expectEqual(@as(u21, 'A'), sb.getLine(0)[0].char);
    try std.testing.expectEqual(@as(u21, 'B'), sb.getLine(1)[0].char);
    try std.testing.expectEqual(@as(u21, 'C'), sb.getLine(2)[0].char);
}
