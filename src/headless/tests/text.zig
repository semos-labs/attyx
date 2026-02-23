const std = @import("std");
const helpers = @import("helpers.zig");
const TerminalState = @import("../../term/state.zig").TerminalState;
const Color = @import("../../term/grid.zig").Color;
const expectSnapshot = helpers.expectSnapshot;

// ===========================================================================
// Basic printing
// ===========================================================================

test "golden: basic printing" {
    try expectSnapshot(3, 5, "Hello",
        "Hello\n" ++
        "     \n" ++
        "     \n");
}

test "golden: multiple characters fill left to right" {
    try expectSnapshot(2, 4, "ABCD",
        "ABCD\n" ++
        "    \n");
}

// ===========================================================================
// Line wrapping
// ===========================================================================

test "golden: text wraps at right edge" {
    try expectSnapshot(2, 3, "ABCDE",
        "ABC\n" ++
        "DE \n");
}

test "golden: wrap triggers scroll when grid is full" {
    // With deferred wrap, printing 'F' at the last column sets wrap_next
    // but doesn't scroll until a 7th character is printed.
    try expectSnapshot(2, 3, "ABCDEF",
        "ABC\n" ++
        "DEF\n");
}

test "golden: deferred wrap scrolls on next char" {
    // 7th char triggers the deferred wrap → scroll.
    try expectSnapshot(2, 3, "ABCDEFG",
        "DEF\n" ++
        "G  \n");
}

// ===========================================================================
// LF / CR
// ===========================================================================

test "golden: LF moves down, preserves column" {
    try expectSnapshot(3, 3, "A\nB",
        "A  \n" ++
        " B \n" ++
        "   \n");
}

test "golden: CR returns to column 0" {
    try expectSnapshot(2, 4, "AB\rC",
        "CB  \n" ++
        "    \n");
}

test "golden: CR LF together makes a traditional newline" {
    try expectSnapshot(3, 4, "AB\r\nCD",
        "AB  \n" ++
        "CD  \n" ++
        "    \n");
}

// ===========================================================================
// Backspace
// ===========================================================================

test "golden: backspace moves cursor left without erasing" {
    try expectSnapshot(2, 4, "AB\x08C",
        "AC  \n" ++
        "    \n");
}

test "golden: backspace clamps at column 0" {
    try expectSnapshot(2, 4, "\x08A",
        "A   \n" ++
        "    \n");
}

// ===========================================================================
// TAB
// ===========================================================================

test "golden: tab advances to next 8-column stop" {
    try expectSnapshot(2, 16, "A\tB",
        "A       B       \n" ++
        "                \n");
}

test "golden: tab clamps at last column" {
    try expectSnapshot(2, 8, "AAAAAAA\tB",
        "AAAAAAAB\n" ++
        "        \n");
}

// ===========================================================================
// Scrolling
// ===========================================================================

test "golden: scroll drops top row when LF at bottom" {
    try expectSnapshot(3, 4, "AAA\r\nBBB\r\nCCC\r\nDDD",
        "BBB \n" ++
        "CCC \n" ++
        "DDD \n");
}

test "golden: multiple scrolls" {
    try expectSnapshot(2, 3, "AB\r\nCD\r\nEF",
        "CD \n" ++
        "EF \n");
}

// ===========================================================================
// State unit tests for basic operations
// ===========================================================================

test "apply print writes to grid and advances cursor" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'A' });
    try std.testing.expectEqual(@as(u21, 'A'), t.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(usize, 0), t.cursor.row);
    try std.testing.expectEqual(@as(usize, 1), t.cursor.col);
}

test "apply control.bs clamps at column 0" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .control = .bs });
    try std.testing.expectEqual(@as(usize, 0), t.cursor.col);
}

test "apply control.cr resets column to 0" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });
    t.apply(.{ .control = .cr });
    try std.testing.expectEqual(@as(usize, 0), t.cursor.col);
    try std.testing.expectEqual(@as(usize, 0), t.cursor.row);
}

test "apply control.lf moves down, preserves column" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 3, 4);
    defer t.deinit();

    t.apply(.{ .print = 'A' });
    t.apply(.{ .control = .lf });
    try std.testing.expectEqual(@as(usize, 1), t.cursor.row);
    try std.testing.expectEqual(@as(usize, 1), t.cursor.col);
}

test "apply control.tab advances to next 8-column stop" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 20);
    defer t.deinit();

    t.apply(.{ .control = .tab });
    try std.testing.expectEqual(@as(usize, 8), t.cursor.col);
    t.apply(.{ .control = .tab });
    try std.testing.expectEqual(@as(usize, 16), t.cursor.col);
}

test "apply nop has no effect" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'X' });
    const row_before = t.cursor.row;
    const col_before = t.cursor.col;
    t.apply(.{ .nop = {} });
    try std.testing.expectEqual(row_before, t.cursor.row);
    try std.testing.expectEqual(col_before, t.cursor.col);
    try std.testing.expectEqual(@as(u21, 'X'), t.grid.getCell(0, 0).char);
}

test "printed cells carry current pen style" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.pen = .{ .fg = Color.red, .bold = true };
    t.apply(.{ .print = 'A' });
    const cell = t.grid.getCell(0, 0);
    try std.testing.expectEqual(Color.red, cell.style.fg);
    try std.testing.expect(cell.style.bold);
}
