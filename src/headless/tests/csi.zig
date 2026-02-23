const std = @import("std");
const helpers = @import("helpers.zig");
const runner = @import("../runner.zig");
const Engine = @import("../../term/engine.zig").Engine;
const Color = @import("../../term/grid.zig").Color;
const CursorShape = @import("../../term/actions.zig").CursorShape;
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
// CSI G — Cursor Character Absolute (CHA)
// ===========================================================================

test "golden: CHA moves cursor to column" {
    try expectSnapshot(1, 8, "ABCDEFGH\x1b[4GX",
        "ABCXEFGH\n");
}

test "golden: CHA default is column 1" {
    try expectSnapshot(1, 5, "ABC\x1b[GX",
        "XBC  \n");
}

// ===========================================================================
// CSI d — Line Position Absolute (VPA)
// ===========================================================================

test "golden: VPA moves cursor to row" {
    try expectSnapshot(4, 5, "\x1b[3dX",
        "     \n" ++
        "     \n" ++
        "X    \n" ++
        "     \n");
}

// ===========================================================================
// CSI E — Cursor Next Line (CNL)
// ===========================================================================

test "golden: CNL moves down and to column 0" {
    try expectSnapshot(3, 6, "ABC\x1b[EX",
        "ABC   \n" ++
        "X     \n" ++
        "      \n");
}

test "golden: CNL n=2 moves down 2 rows" {
    try expectSnapshot(4, 5, "ABC\x1b[2EX",
        "ABC  \n" ++
        "     \n" ++
        "X    \n" ++
        "     \n");
}

// ===========================================================================
// CSI F — Cursor Previous Line (CPL)
// ===========================================================================

test "golden: CPL moves up and to column 0" {
    try expectSnapshot(3, 6, "\x1b[3;4HA\x1b[FX",
        "      \n" ++
        "X     \n" ++
        "   A  \n");
}

// ===========================================================================
// CSI L — Insert Lines (IL)
// ===========================================================================

test "golden: IL inserts blank line pushing content down" {
    try expectSnapshot(4, 5, "AAAA\r\nBBBB\r\nCCCC\r\nDDDD\x1b[2;1H\x1b[L",
        "AAAA \n" ++
        "     \n" ++
        "BBBB \n" ++
        "CCCC \n");
}

test "golden: IL inserts 2 blank lines" {
    try expectSnapshot(4, 5, "AAAA\r\nBBBB\r\nCCCC\r\nDDDD\x1b[2;1H\x1b[2L",
        "AAAA \n" ++
        "     \n" ++
        "     \n" ++
        "BBBB \n");
}

// ===========================================================================
// CSI M — Delete Lines (DL)
// ===========================================================================

test "golden: DL deletes line pulling content up" {
    try expectSnapshot(4, 5, "AAAA\r\nBBBB\r\nCCCC\r\nDDDD\x1b[2;1H\x1b[M",
        "AAAA \n" ++
        "CCCC \n" ++
        "DDDD \n" ++
        "     \n");
}

test "golden: DL deletes 2 lines" {
    try expectSnapshot(4, 5, "AAAA\r\nBBBB\r\nCCCC\r\nDDDD\x1b[2;1H\x1b[2M",
        "AAAA \n" ++
        "DDDD \n" ++
        "     \n" ++
        "     \n");
}

// ===========================================================================
// CSI @ — Insert Characters (ICH)
// ===========================================================================

test "golden: ICH inserts blank chars shifting right" {
    try expectSnapshot(1, 8, "ABCDEFGH\x1b[1;3H\x1b[2@",
        "AB  CDEF\n");
}

// ===========================================================================
// CSI P — Delete Characters (DCH)
// ===========================================================================

test "golden: DCH deletes chars shifting left" {
    try expectSnapshot(1, 8, "ABCDEFGH\x1b[1;3H\x1b[2P",
        "ABEFGH  \n");
}

// ===========================================================================
// CSI X — Erase Characters (ECH)
// ===========================================================================

test "golden: ECH erases chars without shifting" {
    try expectSnapshot(1, 8, "ABCDEFGH\x1b[1;3H\x1b[3X",
        "AB   FGH\n");
}

// ===========================================================================
// CSI S — Scroll Up (SU)
// ===========================================================================

test "golden: SU scrolls screen up" {
    try expectSnapshot(3, 5, "AAAA\r\nBBBB\r\nCCCC\x1b[S",
        "BBBB \n" ++
        "CCCC \n" ++
        "     \n");
}

// ===========================================================================
// CSI T — Scroll Down (SD)
// ===========================================================================

test "golden: SD scrolls screen down" {
    try expectSnapshot(3, 5, "AAAA\r\nBBBB\r\nCCCC\x1b[T",
        "     \n" ++
        "AAAA \n" ++
        "BBBB \n");
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

// ===========================================================================
// Device Status Report (DSR) / Device Attributes (DA)
// ===========================================================================

test "CSI 6 n: cursor position report" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 10, 20);
    defer engine.deinit();

    engine.feed("\x1b[5;12H");
    engine.feed("\x1b[6n");

    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("\x1b[5;12R", resp.?);
}

test "CSI 6 n: cursor at origin" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 5);
    defer engine.deinit();

    engine.feed("\x1b[6n");

    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("\x1b[1;1R", resp.?);
}

test "CSI 5 n: device status OK" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 5);
    defer engine.deinit();

    engine.feed("\x1b[5n");

    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("\x1b[0n", resp.?);
}

test "CSI c: primary device attributes" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 5);
    defer engine.deinit();

    engine.feed("\x1b[c");

    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("\x1b[?62c", resp.?);
}

test "CSI 0 c: primary device attributes explicit param" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 5);
    defer engine.deinit();

    engine.feed("\x1b[0c");

    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("\x1b[?62c", resp.?);
}

test "CSI > c: secondary device attributes" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 5);
    defer engine.deinit();

    engine.feed("\x1b[>c");

    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("\x1b[>0;10;1c", resp.?);
}

test "CSI > 0 c: secondary device attributes explicit param" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 5);
    defer engine.deinit();

    engine.feed("\x1b[>0c");

    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("\x1b[>0;10;1c", resp.?);
}

test "drainResponse clears buffer" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 5);
    defer engine.deinit();

    engine.feed("\x1b[6n");
    _ = engine.state.drainResponse();

    try std.testing.expectEqual(@as(?[]const u8, null), engine.state.drainResponse());
}

test "multiple DSR responses accumulate" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 5);
    defer engine.deinit();

    engine.feed("\x1b[5n\x1b[6n");

    const resp = engine.state.drainResponse();
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("\x1b[0n\x1b[1;1R", resp.?);
}

test "tmux passthrough with inner OSC hyperlink is silently consumed" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 40);
    defer engine.deinit();

    // Simulate: "AB" then tmux passthrough wrapping OSC 8 hyperlink
    // (inner ESCs doubled, inner OSC terminated by BEL), then "CD".
    // Only "ABCD" should appear on screen — the passthrough must be
    // fully consumed without leaking "Ptmux;", "]", URL bytes, etc.
    engine.feed("AB" ++
        "\x1bPtmux;\x1b\x1b]8;;https://example.com\x07\x1b\\" ++
        "CD");

    try std.testing.expectEqual(@as(u21, 'A'), engine.state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), engine.state.grid.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'C'), engine.state.grid.getCell(0, 2).char);
    try std.testing.expectEqual(@as(u21, 'D'), engine.state.grid.getCell(0, 3).char);
    try std.testing.expectEqual(@as(u21, ' '), engine.state.grid.getCell(0, 4).char);
}

test "C1 DCS (0x90) payload is silently consumed" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 20);
    defer engine.deinit();

    // 8-bit DCS: \x90 payload \x9C (C1 ST).  Nothing should print.
    engine.feed("X" ++ "\x90" ++ "qpayload" ++ "\x9C" ++ "Y");

    try std.testing.expectEqual(@as(u21, 'X'), engine.state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'Y'), engine.state.grid.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), engine.state.grid.getCell(0, 2).char);
}

test "APC Kitty graphics payload is silently consumed" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 40);
    defer engine.deinit();

    // ESC _ G ... ESC \  (Kitty graphics protocol)
    engine.feed("A" ++ "\x1b_Ga=T,f=24,s=1,v=1;AAAA\x1b\\" ++ "B");

    try std.testing.expectEqual(@as(u21, 'A'), engine.state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), engine.state.grid.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), engine.state.grid.getCell(0, 2).char);
}

// ===========================================================================
// DECSCUSR — cursor shape
// ===========================================================================

test "DECSCUSR: CSI 2 SP q sets steady block" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10);
    defer engine.deinit();

    try std.testing.expectEqual(CursorShape.blinking_block, engine.state.cursor_shape);
    engine.feed("\x1b[2 q");
    try std.testing.expectEqual(CursorShape.steady_block, engine.state.cursor_shape);
}

test "DECSCUSR: CSI 5 SP q sets blinking bar" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10);
    defer engine.deinit();

    engine.feed("\x1b[5 q");
    try std.testing.expectEqual(CursorShape.blinking_bar, engine.state.cursor_shape);
}

test "DECSCUSR: CSI 0 SP q resets to blinking block" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10);
    defer engine.deinit();

    engine.feed("\x1b[6 q");
    try std.testing.expectEqual(CursorShape.steady_bar, engine.state.cursor_shape);
    engine.feed("\x1b[0 q");
    try std.testing.expectEqual(CursorShape.blinking_block, engine.state.cursor_shape);
}

test "DECSCUSR: CSI 3 SP q sets blinking underline" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10);
    defer engine.deinit();

    engine.feed("\x1b[3 q");
    try std.testing.expectEqual(CursorShape.blinking_underline, engine.state.cursor_shape);
}

test "DECSCUSR: CSI 4 SP q sets steady underline" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10);
    defer engine.deinit();

    engine.feed("\x1b[4 q");
    try std.testing.expectEqual(CursorShape.steady_underline, engine.state.cursor_shape);
}

// ===========================================================================
// DEC mode 25 — cursor visibility
// ===========================================================================

test "DEC mode 25: CSI ?25l hides cursor" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10);
    defer engine.deinit();

    try std.testing.expect(engine.state.cursor_visible);
    engine.feed("\x1b[?25l");
    try std.testing.expect(!engine.state.cursor_visible);
}

test "DEC mode 25: CSI ?25h shows cursor" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10);
    defer engine.deinit();

    engine.feed("\x1b[?25l");
    try std.testing.expect(!engine.state.cursor_visible);
    engine.feed("\x1b[?25h");
    try std.testing.expect(engine.state.cursor_visible);
}

// ===========================================================================
// Combined: DECSCUSR + mode 25
// ===========================================================================

test "cursor shape + visibility combined" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10);
    defer engine.deinit();

    engine.feed("\x1b[5 q");
    try std.testing.expectEqual(CursorShape.blinking_bar, engine.state.cursor_shape);
    try std.testing.expect(engine.state.cursor_visible);

    engine.feed("\x1b[?25l");
    try std.testing.expect(!engine.state.cursor_visible);
    try std.testing.expectEqual(CursorShape.blinking_bar, engine.state.cursor_shape);

    engine.feed("\x1b[2 q");
    try std.testing.expectEqual(CursorShape.steady_block, engine.state.cursor_shape);
    try std.testing.expect(!engine.state.cursor_visible);

    engine.feed("\x1b[?25h");
    try std.testing.expect(engine.state.cursor_visible);
    try std.testing.expectEqual(CursorShape.steady_block, engine.state.cursor_shape);
}

test "cursor shape persists across alt screen switch" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 10);
    defer engine.deinit();

    engine.feed("\x1b[4 q");
    try std.testing.expectEqual(CursorShape.steady_underline, engine.state.cursor_shape);

    engine.feed("\x1b[?1049h");
    try std.testing.expectEqual(CursorShape.steady_underline, engine.state.cursor_shape);

    engine.feed("\x1b[6 q");
    try std.testing.expectEqual(CursorShape.steady_bar, engine.state.cursor_shape);

    engine.feed("\x1b[?1049l");
    try std.testing.expectEqual(CursorShape.steady_bar, engine.state.cursor_shape);
}
