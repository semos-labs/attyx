const std = @import("std");
const helpers = @import("helpers.zig");
const runner = @import("../runner.zig");
const Engine = @import("../../term/engine.zig").Engine;
const Color = @import("../../term/grid.zig").Color;
const expectSnapshot = helpers.expectSnapshot;
const expectChunkedSnapshot = helpers.expectChunkedSnapshot;

// ===========================================================================
// CSI Cursor Position — CUP
// ===========================================================================

test "golden: CUP moves cursor to absolute position" {
    try expectSnapshot(4, 6, "\x1b[3;4HA",
        "      \n" ++
        "      \n" ++
        "   A  \n" ++
        "      \n");
}

test "golden: CUP with no params defaults to home" {
    try expectSnapshot(2, 5, "ABCDE\x1b[HX",
        "XBCDE\n" ++
        "     \n");
}

test "golden: CUP clamps to screen bounds" {
    try expectSnapshot(3, 5, "\x1b[99;99H\x1b[DX",
        "     \n" ++
        "     \n" ++
        "   X \n");
}

test "golden: CUP with f final byte" {
    try expectSnapshot(3, 5, "\x1b[2;3fX",
        "     \n" ++
        "  X  \n" ++
        "     \n");
}

// ===========================================================================
// CSI Cursor Movement — CUU/CUD/CUF/CUB
// ===========================================================================

test "golden: CUF moves cursor right" {
    try expectSnapshot(2, 6, "A\x1b[2CB",
        "A  B  \n" ++
        "      \n");
}

test "golden: CUB moves cursor left" {
    try expectSnapshot(1, 6, "ABCDE\x1b[3DX",
        "ABXDE \n");
}

test "golden: CUU moves cursor up" {
    try expectSnapshot(3, 4, "A\r\nB\r\nC\x1b[2AX",
        "AX  \n" ++
        "B   \n" ++
        "C   \n");
}

test "golden: CUD moves cursor down" {
    try expectSnapshot(3, 4, "A\x1b[2BX",
        "A   \n" ++
        "    \n" ++
        " X  \n");
}

test "golden: cursor movement defaults n to 1" {
    try expectSnapshot(1, 6, "ABC\x1b[DX",
        "ABX   \n");
}

test "golden: cursor movement clamps at boundaries" {
    try expectSnapshot(2, 4, "\x1b[99AX\x1b[99DY",
        "Y   \n" ++
        "    \n");
}

// ===========================================================================
// CSI Erase in Display — ED
// ===========================================================================

test "golden: erase display to end (default)" {
    try expectSnapshot(3, 5, "AAA\r\nBBB\r\nCCC\x1b[2;3H\x1b[J",
        "AAA  \n" ++
        "BB   \n" ++
        "     \n");
}

test "golden: erase display to start" {
    try expectSnapshot(3, 5, "AAAA\r\nBBBB\r\nCCCC\x1b[2;3H\x1b[1J",
        "     \n" ++
        "   B \n" ++
        "CCCC \n");
}

test "golden: erase entire display" {
    try expectSnapshot(2, 5, "AB\r\nCD\x1b[2J",
        "     \n" ++
        "     \n");
}

// ===========================================================================
// CSI Erase in Line — EL
// ===========================================================================

test "golden: erase line to end (default)" {
    try expectSnapshot(2, 7, "Hello!\r\nWorld!\x1b[1;4H\x1b[K",
        "Hel    \n" ++
        "World! \n");
}

test "golden: erase line to start" {
    try expectSnapshot(2, 7, "Hello!\r\nWorld!\x1b[1;4H\x1b[1K",
        "    o! \n" ++
        "World! \n");
}

test "golden: erase entire line" {
    try expectSnapshot(2, 6, "ABCDE\r\nFGHIJ\x1b[1;3H\x1b[2K",
        "      \n" ++
        "FGHIJ \n");
}

// ===========================================================================
// CSI SGR — colors and attributes
// ===========================================================================

test "golden: SGR does not affect character output" {
    try expectSnapshot(2, 4, "\x1b[31mAB\x1b[0mCD",
        "ABCD\n" ++
        "    \n");
}

test "golden: multiple CSI sequences with text" {
    try expectSnapshot(1, 12, "\x1b[1m\x1b[31mHello\x1b[0m World",
        "Hello World \n");
}

test "attr: SGR 31m sets foreground to red" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b[31mA\x1b[0mB");

    const cell_a = engine.state.grid.getCell(0, 0);
    const cell_b = engine.state.grid.getCell(0, 1);
    try std.testing.expectEqual(Color.red, cell_a.style.fg);
    try std.testing.expectEqual(Color.default, cell_b.style.fg);
}

test "attr: SGR 0m resets all attributes" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b[1;31;4mA\x1b[0mB");

    const cell_a = engine.state.grid.getCell(0, 0);
    try std.testing.expectEqual(Color.red, cell_a.style.fg);
    try std.testing.expect(cell_a.style.bold);
    try std.testing.expect(cell_a.style.underline);

    const cell_b = engine.state.grid.getCell(0, 1);
    try std.testing.expectEqual(Color.default, cell_b.style.fg);
    try std.testing.expect(!cell_b.style.bold);
    try std.testing.expect(!cell_b.style.underline);
}

test "attr: SGR sets foreground and background independently" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b[32;43mA");

    const cell = engine.state.grid.getCell(0, 0);
    try std.testing.expectEqual(Color.green, cell.style.fg);
    try std.testing.expectEqual(Color.yellow, cell.style.bg);
}

test "attr: SGR 39 resets fg, 49 resets bg" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b[31;42mA\x1b[39mB\x1b[49mC");

    const cell_a = engine.state.grid.getCell(0, 0);
    try std.testing.expectEqual(Color.red, cell_a.style.fg);
    try std.testing.expectEqual(Color.green, cell_a.style.bg);

    const cell_b = engine.state.grid.getCell(0, 1);
    try std.testing.expectEqual(Color.default, cell_b.style.fg);
    try std.testing.expectEqual(Color.green, cell_b.style.bg);

    const cell_c = engine.state.grid.getCell(0, 2);
    try std.testing.expectEqual(Color.default, cell_c.style.fg);
    try std.testing.expectEqual(Color.default, cell_c.style.bg);
}

test "attr: bold and underline flags" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b[1mB\x1b[4mU\x1b[0mN");

    const cell_b = engine.state.grid.getCell(0, 0);
    try std.testing.expect(cell_b.style.bold);
    try std.testing.expect(!cell_b.style.underline);

    const cell_u = engine.state.grid.getCell(0, 1);
    try std.testing.expect(cell_u.style.bold);
    try std.testing.expect(cell_u.style.underline);

    const cell_n = engine.state.grid.getCell(0, 2);
    try std.testing.expect(!cell_n.style.bold);
    try std.testing.expect(!cell_n.style.underline);
}

// ===========================================================================
// Incremental CSI with semantics
// ===========================================================================

test "golden: CSI cursor movement split across chunks" {
    try expectChunkedSnapshot(3, 5, &.{ "A\x1b[3", ";2HB" },
        "A    \n" ++
        "     \n" ++
        " B   \n");
}

test "golden: CSI SGR split across chunks preserves color" {
    const alloc = std.testing.allocator;
    const snap = try runner.runChunked(alloc, 1, 4, &.{ "\x1b[3", "1mAB" });
    defer alloc.free(snap);
    try std.testing.expectEqualStrings("AB  \n", snap);

    var engine = try Engine.init(alloc, 1, 4);
    defer engine.deinit();
    engine.feed("\x1b[3");
    engine.feed("1mAB");
    try std.testing.expectEqual(Color.red, engine.state.grid.getCell(0, 0).style.fg);
}
