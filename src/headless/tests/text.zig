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

// ===========================================================================
// Combining marks
// ===========================================================================

test "combining diacritical attaches to previous cell" {
    // 'a' + U+0308 (combining diaeresis) → cell has base 'a' + combining[0] = 0x0308
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'a' });
    t.apply(.{ .print = 0x0308 }); // combining diaeresis
    const cell = t.grid.getCell(0, 0);
    try std.testing.expectEqual(@as(u21, 'a'), cell.char);
    try std.testing.expectEqual(@as(u21, 0x0308), cell.combining[0]);
    try std.testing.expectEqual(@as(u21, 0), cell.combining[1]);
    // Cursor should still be at col 1 (combining mark doesn't advance)
    try std.testing.expectEqual(@as(usize, 1), t.cursor.col);
}

test "two combining marks attach to same cell" {
    // 'a' + U+0308 (diaeresis) + U+0301 (acute) → both slots filled
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'a' });
    t.apply(.{ .print = 0x0308 });
    t.apply(.{ .print = 0x0301 });
    const cell = t.grid.getCell(0, 0);
    try std.testing.expectEqual(@as(u21, 'a'), cell.char);
    try std.testing.expectEqual(@as(u21, 0x0308), cell.combining[0]);
    try std.testing.expectEqual(@as(u21, 0x0301), cell.combining[1]);
}

test "Thai combining marks stored in cell" {
    // Thai: ko kai (U+0E01) + sara i (U+0E34) + mai ek (U+0E48)
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 0x0E01 }); // ko kai (base consonant)
    t.apply(.{ .print = 0x0E34 }); // sara i (above vowel)
    t.apply(.{ .print = 0x0E48 }); // mai ek (tone mark)
    const cell = t.grid.getCell(0, 0);
    try std.testing.expectEqual(@as(u21, 0x0E01), cell.char);
    try std.testing.expectEqual(@as(u21, 0x0E34), cell.combining[0]);
    try std.testing.expectEqual(@as(u21, 0x0E48), cell.combining[1]);
}

test "combining mark at column 0 is absorbed without crash" {
    // Sending a combining mark as the very first character
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 0x0308 }); // combining diaeresis at col 0
    // Should not crash; mark is silently dropped since there's no previous cell
    try std.testing.expectEqual(@as(usize, 0), t.cursor.col);
    try std.testing.expectEqual(@as(u21, ' '), t.grid.getCell(0, 0).char);
}

test "golden: combining mark in snapshot output" {
    // 'a' + combining diaeresis should produce "a\xCC\x88" in UTF-8
    try expectSnapshot(1, 4, "a\xCC\x88b",
        "a\xCC\x88b  \n");
}

test "Thai UTF-8 combining marks are zero-width through engine" {
    // Feed raw UTF-8 Thai bytes through the full Engine (parser → state)
    // and verify cursor ends at the correct column.
    // "แผ่นดิน" = แ(1) + ผ(1) + ่(0) + น(1) + ด(1) + ิ(0) + น(1) = 5 cells
    const alloc = std.testing.allocator;
    const Engine = @import("../../term/engine.zig").Engine;
    var e = try Engine.init(alloc, 2, 20);
    defer e.deinit();

    // แ=E0B981  ผ=E0B89C  ่=E0B988  น=E0B899  ด=E0B894  ิ=E0B8B4  น=E0B899
    e.feed("\xe0\xb9\x81\xe0\xb8\x9c\xe0\xb9\x88\xe0\xb8\x99\xe0\xb8\x94\xe0\xb8\xb4\xe0\xb8\x99");

    try std.testing.expectEqual(@as(usize, 5), e.state.cursor.col);
    // ผ at col 1 should have ่ (U+0E48) as combining mark
    const cell1 = e.state.grid.getCell(0, 1);
    try std.testing.expectEqual(@as(u21, 0x0E1C), cell1.char); // ผ
    try std.testing.expectEqual(@as(u21, 0x0E48), cell1.combining[0]); // ่
    // ด at col 3 should have ิ (U+0E34) as combining mark
    const cell3 = e.state.grid.getCell(0, 3);
    try std.testing.expectEqual(@as(u21, 0x0E14), cell3.char); // ด
    try std.testing.expectEqual(@as(u21, 0x0E34), cell3.combining[0]); // ิ
}

test "Thai two-column alignment: cursor position matches pipe separator" {
    // The UTF-8 demo line 122: "  [----------------------------|------------------------]"
    // The pipe is at column 31.
    // Line 123 first half + gap should leave cursor at column 31.
    // Bytes extracted from actual file hex dump.
    const alloc = std.testing.allocator;
    const Engine = @import("../../term/engine.zig").Engine;
    var e = try Engine.init(alloc, 2, 80);
    defer e.deinit();

    // "    ๏ แผ่นดินฮั่นเสื่อมโทรมแสนสังเวช  "
    // Actual UTF-8 bytes from hex dump of test/UTF-8-demo.txt line 123:
    e.feed(
        "\x20\x20\x20\x20" ++ // 4 spaces
        "\xe0\xb9\x8f\x20" ++ // ๏ + space
        "\xe0\xb9\x81" ++ // แ U+0E41
        "\xe0\xb8\x9c" ++ // ผ U+0E1C
        "\xe0\xb9\x88" ++ // ่ U+0E48 combining
        "\xe0\xb8\x99" ++ // น U+0E19
        "\xe0\xb8\x94" ++ // ด U+0E14
        "\xe0\xb8\xb4" ++ // ิ U+0E34 combining
        "\xe0\xb8\x99" ++ // น U+0E19
        "\xe0\xb8\xae" ++ // ฮ U+0E2E
        "\xe0\xb8\xb1" ++ // ั U+0E31 combining
        "\xe0\xb9\x88" ++ // ่ U+0E48 combining
        "\xe0\xb8\x99" ++ // น U+0E19
        "\xe0\xb9\x80" ++ // เ U+0E40
        "\xe0\xb8\xaa" ++ // ส U+0E2A
        "\xe0\xb8\xb7" ++ // ื U+0E37 combining
        "\xe0\xb9\x88" ++ // ่ U+0E48 combining
        "\xe0\xb8\xad" ++ // อ U+0E2D
        "\xe0\xb8\xa1" ++ // ม U+0E21
        "\xe0\xb9\x82" ++ // โ U+0E42
        "\xe0\xb8\x97" ++ // ท U+0E17
        "\xe0\xb8\xa3" ++ // ร U+0E23
        "\xe0\xb8\xa1" ++ // ม U+0E21
        "\xe0\xb9\x81" ++ // แ U+0E41
        "\xe0\xb8\xaa" ++ // ส U+0E2A
        "\xe0\xb8\x99" ++ // น U+0E19
        "\xe0\xb8\xaa" ++ // ส U+0E2A
        "\xe0\xb8\xb1" ++ // ั U+0E31 combining
        "\xe0\xb8\x87" ++ // ง U+0E07
        "\xe0\xb9\x80" ++ // เ U+0E40
        "\xe0\xb8\xa7" ++ // ว U+0E27
        "\xe0\xb8\x8a" ++ // ช U+0E0A
        "\x20\x20", // 2 gap spaces
    );

    try std.testing.expectEqual(@as(usize, 31), e.state.cursor.col);
}
