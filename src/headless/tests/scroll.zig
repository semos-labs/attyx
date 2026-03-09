const std = @import("std");
const helpers = @import("helpers.zig");
const Engine = @import("../../term/engine.zig").Engine;
const TerminalState = @import("../../term/state.zig").TerminalState;
const expectSnapshot = helpers.expectSnapshot;

// ===========================================================================
// DECSTBM scroll regions
// ===========================================================================

test "attr: scroll region set and reset" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 6, 100);
    defer engine.deinit();

    try std.testing.expectEqual(@as(usize, 0), engine.state.scroll_top);
    try std.testing.expectEqual(@as(usize, 4), engine.state.scroll_bottom);

    engine.feed("\x1b[2;4r");
    try std.testing.expectEqual(@as(usize, 1), engine.state.scroll_top);
    try std.testing.expectEqual(@as(usize, 3), engine.state.scroll_bottom);

    engine.feed("\x1b[r");
    try std.testing.expectEqual(@as(usize, 0), engine.state.scroll_top);
    try std.testing.expectEqual(@as(usize, 4), engine.state.scroll_bottom);
}

test "attr: invalid scroll region is ignored" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 6, 100);
    defer engine.deinit();

    engine.feed("\x1b[2;4r");
    engine.feed("\x1b[4;2r");
    try std.testing.expectEqual(@as(usize, 1), engine.state.scroll_top);
    try std.testing.expectEqual(@as(usize, 3), engine.state.scroll_bottom);

    engine.feed("\x1b[3;3r");
    try std.testing.expectEqual(@as(usize, 1), engine.state.scroll_top);
    try std.testing.expectEqual(@as(usize, 3), engine.state.scroll_bottom);
}

test "golden: LF at region bottom scrolls within region" {
    try expectSnapshot(5, 6,
        "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE" ++
        "\x1b[2;4r" ++
        "\x1b[4;1H" ++
        "\nX",
        "AAAAA \n" ++
        "CCCCC \n" ++
        "DDDDD \n" ++
        "X     \n" ++
        "EEEEE \n");
}

test "golden: multiple LFs scroll within region repeatedly" {
    try expectSnapshot(5, 4,
        "AAA\r\nBBB\r\nCCC\r\nDDD\r\nEEE" ++
        "\x1b[2;4r" ++
        "\x1b[4;1H" ++
        "\nX\r\nY",
        "AAA \n" ++
        "DDD \n" ++
        "X   \n" ++
        "Y   \n" ++
        "EEE \n");
}

test "golden: wrap at region bottom triggers region scroll" {
    // With deferred wrap, 'Y' at the last column sets wrap_next but
    // doesn't scroll the region until a third character is printed.
    try expectSnapshot(5, 6,
        "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE" ++
        "\x1b[2;4r" ++
        "\x1b[4;5H" ++
        "XY",
        "AAAAA \n" ++
        "BBBBB \n" ++
        "CCCCC \n" ++
        "DDDDXY\n" ++
        "EEEEE \n");
}

test "golden: deferred wrap triggers region scroll on next char" {
    // Cursor at (row 3, col 5). X writes at col 5 → wrap_next.
    // Y triggers wrap+scroll, then writes at (3,0). Z at (3,1).
    try expectSnapshot(5, 6,
        "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE" ++
        "\x1b[2;4r" ++
        "\x1b[4;6H" ++
        "XYZ",
        "AAAAA \n" ++
        "CCCCC \n" ++
        "DDDDDX\n" ++
        "YZ    \n" ++
        "EEEEE \n");
}

test "golden: ESC[r resets scroll region to full screen" {
    try expectSnapshot(3, 4,
        "AAA\r\nBBB\r\nCCC" ++
        "\x1b[2;3r" ++
        "\x1b[r" ++
        "\x1b[3;1H\n" ++
        "X",
        "BBB \n" ++
        "CCC \n" ++
        "X   \n");
}

test "golden: LF outside region does not trigger region scroll" {
    try expectSnapshot(5, 6,
        "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE" ++
        "\x1b[2;3r" ++
        "\x1b[5;1H\n",
        "AAAAA \n" ++
        "BBBBB \n" ++
        "CCCCC \n" ++
        "DDDDD \n" ++
        "EEEEE \n");
}

test "golden: CUP moves cursor outside scroll region" {
    try expectSnapshot(5, 6,
        "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE" ++
        "\x1b[2;4r" ++
        "\x1b[1;1HX" ++
        "\x1b[5;1HY",
        "XAAAA \n" ++
        "BBBBB \n" ++
        "CCCCC \n" ++
        "DDDDD \n" ++
        "YEEEE \n");
}

// ===========================================================================
// IND / RI — Index and Reverse Index
// ===========================================================================

test "golden: IND at region bottom scrolls within region" {
    try expectSnapshot(5, 6,
        "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE" ++
        "\x1b[2;4r" ++
        "\x1b[4;1H" ++
        "\x1bDX",
        "AAAAA \n" ++
        "CCCCC \n" ++
        "DDDDD \n" ++
        "X     \n" ++
        "EEEEE \n");
}

test "golden: RI at region top scrolls down within region" {
    try expectSnapshot(5, 6,
        "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE" ++
        "\x1b[2;4r" ++
        "\x1b[2;1H" ++
        "\x1bMX",
        "AAAAA \n" ++
        "X     \n" ++
        "BBBBB \n" ++
        "CCCCC \n" ++
        "EEEEE \n");
}

test "golden: RI outside region just moves cursor up" {
    try expectSnapshot(3, 4,
        "\x1b[2;3r" ++
        "\x1b[3;1HA\r" ++
        "\x1bMB",
        "    \n" ++
        "B   \n" ++
        "A   \n");
}

// ===========================================================================
// State unit tests for scroll regions
// ===========================================================================

test "default scroll region is full screen" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 5, 4, 100);
    defer t.deinit();

    try std.testing.expectEqual(@as(usize, 0), t.scroll_top);
    try std.testing.expectEqual(@as(usize, 4), t.scroll_bottom);
}

test "reverse index at top of region scrolls down" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 5, 2, 100);
    defer t.deinit();

    t.ring.setScreenCell(1, 0, .{ .char = 'B' });
    t.ring.setScreenCell(2, 0, .{ .char = 'C' });
    t.ring.setScreenCell(3, 0, .{ .char = 'D' });
    t.scroll_top = 1;
    t.scroll_bottom = 3;
    t.cursor.row = 1;
    t.apply(.reverse_index);

    try std.testing.expectEqual(@as(usize, 1), t.cursor.row);
    try std.testing.expectEqual(@as(u21, ' '), t.ring.getScreenCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), t.ring.getScreenCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), t.ring.getScreenCell(3, 0).char);
}
