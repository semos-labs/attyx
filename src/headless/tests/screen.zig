const std = @import("std");
const helpers = @import("helpers.zig");
const Engine = @import("../../term/engine.zig").Engine;
const TerminalState = @import("../../term/state.zig").TerminalState;
const Color = @import("../../term/grid.zig").Color;
const expectSnapshot = helpers.expectSnapshot;

// ===========================================================================
// Alternate screen
// ===========================================================================

test "golden: alt screen preserves main buffer" {
    try expectSnapshot(2, 5,
        "MAIN" ++
        "\x1b[?1049h" ++
        "ALT" ++
        "\x1b[?1049l",
        "MAIN \n" ++
        "     \n");
}

test "golden: alt screen is cleared on each entry" {
    try expectSnapshot(2, 5,
        "\x1b[?1049h" ++
        "ALT" ++
        "\x1b[?1049l" ++
        "\x1b[?1049h",
        "     \n" ++
        "     \n");
}

test "golden: alt screen with ?47h variant" {
    try expectSnapshot(2, 5,
        "MAIN" ++
        "\x1b[?47h" ++
        "ALT" ++
        "\x1b[?47l",
        "MAIN \n" ++
        "     \n");
}

test "golden: alt screen with ?1047h variant" {
    try expectSnapshot(2, 5,
        "MAIN" ++
        "\x1b[?1047h" ++
        "ALT" ++
        "\x1b[?1047l",
        "MAIN \n" ++
        "     \n");
}

test "golden: entering alt twice is idempotent" {
    try expectSnapshot(2, 5,
        "MAIN" ++
        "\x1b[?1049h" ++
        "\x1b[?1049h" ++
        "ALT" ++
        "\x1b[?1049l",
        "MAIN \n" ++
        "     \n");
}

test "attr: cursor restored when leaving alt screen" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 3, 5);
    defer engine.deinit();

    engine.feed("\x1b[2;3H");
    try std.testing.expectEqual(@as(usize, 1), engine.state.cursor.row);
    try std.testing.expectEqual(@as(usize, 2), engine.state.cursor.col);

    engine.feed("\x1b[?1049h");
    try std.testing.expectEqual(@as(usize, 0), engine.state.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), engine.state.cursor.col);

    engine.feed("\x1b[?1049l");
    try std.testing.expectEqual(@as(usize, 1), engine.state.cursor.row);
    try std.testing.expectEqual(@as(usize, 2), engine.state.cursor.col);
}

// ===========================================================================
// Cursor save / restore
// ===========================================================================

test "golden: DECSC/DECRC save and restore cursor" {
    try expectSnapshot(2, 5,
        "AB" ++
        "\x1b7" ++
        "\x1b[2;4H" ++
        "X" ++
        "\x1b8" ++
        "C",
        "ABC  \n" ++
        "   X \n");
}

test "golden: CSI s/u save and restore cursor" {
    try expectSnapshot(2, 5,
        "AB" ++
        "\x1b[s" ++
        "\x1b[2;4H" ++
        "X" ++
        "\x1b[u" ++
        "C",
        "ABC  \n" ++
        "   X \n");
}

test "attr: save/restore preserves pen attributes" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5);
    defer engine.deinit();

    engine.feed("\x1b[31m");
    engine.feed("\x1b7");
    engine.feed("\x1b[0m");
    engine.feed("\x1b8");
    engine.feed("X");

    try std.testing.expectEqual(Color.red, engine.state.grid.getCell(0, 0).style.fg);
}

test "attr: saved cursor is per-buffer" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 3, 5);
    defer engine.deinit();

    engine.feed("\x1b[2;3H");
    engine.feed("\x1b7");

    engine.feed("\x1b[?1049h");
    engine.feed("\x1b[1;5H");
    engine.feed("\x1b7");

    engine.feed("\x1b[?1049l");
    engine.feed("\x1b8");

    try std.testing.expectEqual(@as(usize, 1), engine.state.cursor.row);
    try std.testing.expectEqual(@as(usize, 2), engine.state.cursor.col);
}

// ===========================================================================
// State unit tests for alt screen
// ===========================================================================

test "enter alt screen clears grid and resets cursor" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'X' });
    t.apply(.enter_alt_screen);

    try std.testing.expect(t.alt_active);
    try std.testing.expectEqual(@as(usize, 0), t.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), t.cursor.col);
    try std.testing.expectEqual(@as(u8, ' '), t.grid.getCell(0, 0).char);
}

test "leave alt screen restores main buffer" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'M' });
    const saved_col = t.cursor.col;
    t.apply(.enter_alt_screen);
    t.apply(.{ .print = 'A' });
    t.apply(.leave_alt_screen);

    try std.testing.expect(!t.alt_active);
    try std.testing.expectEqual(@as(u8, 'M'), t.grid.getCell(0, 0).char);
    try std.testing.expectEqual(saved_col, t.cursor.col);
}

test "save and restore cursor" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 3, 4);
    defer t.deinit();

    t.cursor = .{ .row = 1, .col = 2 };
    t.pen = .{ .fg = Color.red };
    t.apply(.save_cursor);

    t.cursor = .{ .row = 0, .col = 0 };
    t.pen = .{};
    t.apply(.restore_cursor);

    try std.testing.expectEqual(@as(usize, 1), t.cursor.row);
    try std.testing.expectEqual(@as(usize, 2), t.cursor.col);
    try std.testing.expectEqual(Color.red, t.pen.fg);
}
