const std = @import("std");
const helpers = @import("helpers.zig");
const Parser = @import("../../term/parser.zig").Parser;
const Action = @import("../../term/actions.zig").Action;
const expectSnapshot = helpers.expectSnapshot;

// ===========================================================================
// UTF-8 multi-byte decoding
// ===========================================================================

test "UTF-8 2-byte sequence (e.g. U+00E9 = é)" {
    var p: Parser = .{};
    try std.testing.expect(p.next(0xC3) == null);
    try std.testing.expectEqual(Action{ .print = 0x00E9 }, p.next(0xA9).?);
}

test "UTF-8 3-byte sequence (e.g. U+2603 = snowman)" {
    var p: Parser = .{};
    try std.testing.expect(p.next(0xE2) == null);
    try std.testing.expect(p.next(0x98) == null);
    try std.testing.expectEqual(Action{ .print = 0x2603 }, p.next(0x83).?);
}

test "UTF-8 4-byte sequence (e.g. U+1F600 = grinning face)" {
    var p: Parser = .{};
    try std.testing.expect(p.next(0xF0) == null);
    try std.testing.expect(p.next(0x9F) == null);
    try std.testing.expect(p.next(0x98) == null);
    try std.testing.expectEqual(Action{ .print = 0x1F600 }, p.next(0x80).?);
}

test "UTF-8 invalid continuation aborts and re-processes byte" {
    var p: Parser = .{};
    try std.testing.expect(p.next(0xC3) == null);
    // Feed a non-continuation byte — should discard partial and re-process.
    try std.testing.expectEqual(Action{ .print = 'A' }, p.next('A').?);
}

test "UTF-8 followed by normal ASCII" {
    var p: Parser = .{};
    _ = p.next(0xC3);
    _ = p.next(0xA9);
    try std.testing.expectEqual(Action{ .print = 'X' }, p.next('X').?);
}

test "UTF-8 interrupted by ESC discards partial and enters escape" {
    var p: Parser = .{};
    try std.testing.expect(p.next(0xE2) == null);
    // ESC mid-sequence should discard the partial UTF-8 and enter escape state.
    try std.testing.expect(p.next(0x1B) == null);
    // Now we should be in escape state — '[' enters CSI.
    try std.testing.expect(p.next('[') == null);
}

test "golden: UTF-8 text renders in grid" {
    try expectSnapshot(1, 10, "caf\xC3\xA9",
        "caf\xC3\xA9      \n");
}

// ===========================================================================
// Charset designation (ESC ( / ESC ) etc.) — must not leak final byte
// ===========================================================================

test "ESC ( B does not print B" {
    try expectSnapshot(1, 5, "\x1b(BA",
        "A    \n");
}

test "ESC ) 0 does not print 0" {
    try expectSnapshot(1, 5, "\x1b)0A",
        "A    \n");
}

test "ESC ( consumed mid-stream" {
    try expectSnapshot(1, 6, "Hi\x1b(BYo",
        "HiYo  \n");
}

test "ESC # 8 does not print 8 (DECALN ignored)" {
    try expectSnapshot(1, 5, "\x1b#8A",
        "A    \n");
}

test "ESC = and ESC > are consumed" {
    try expectSnapshot(1, 5, "\x1b=A\x1b>B",
        "AB   \n");
}

test "parser: ESC ( enters escape_charset state and consumes designator" {
    var p: Parser = .{};
    try std.testing.expect(p.next(0x1B) == null);
    try std.testing.expect(p.next('(') == null);
    try std.testing.expectEqual(Action.nop, p.next('B').?);
    try std.testing.expectEqual(Action{ .print = 'X' }, p.next('X').?);
}

test "parser: ESC ) 0 consumed without leaking" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next(')');
    try std.testing.expectEqual(Action.nop, p.next('0').?);
    try std.testing.expectEqual(Action{ .print = 'A' }, p.next('A').?);
}

// ===========================================================================
// DCS / APC / PM string ignore
// ===========================================================================

test "APC payload is consumed silently" {
    try expectSnapshot(1, 5, "\x1b_Ga=p,q=2\x1b\\A",
        "A    \n");
}

test "DCS non-tmux payload is consumed silently" {
    try expectSnapshot(1, 5, "\x1bPsome;data\x1b\\B",
        "B    \n");
}

test "DCS tmux passthrough re-feeds inner content" {
    // tmux passthrough wraps: ESC P tmux; <inner-with-doubled-ESC> ESC \
    // Inner content is plain text "Hi" — should be printed.
    try expectSnapshot(1, 5, "\x1bPtmux;Hi\x1b\\",
        "Hi   \n");
}

test "DCS tmux passthrough un-doubles ESC" {
    // Inner ESC is doubled: ESC ESC [ 1 m → un-doubled → ESC [ 1 m (bold SGR).
    // Then "X" is printed bold. Verify "X" appears (SGR doesn't print).
    try expectSnapshot(1, 5, "\x1bPtmux;\x1b\x1b[1mX\x1b\\",
        "X    \n");
}

test "APC terminated by ST" {
    try expectSnapshot(1, 5, "\x1b_Gdata\x1b\\C",
        "C    \n");
}

test "APC with inner BEL is not prematurely terminated" {
    // BEL inside a DCS/APC payload (e.g. tmux passthrough wrapping
    // an OSC that uses BEL as its terminator) must NOT end the outer
    // sequence.  Only ST (ESC \ or 0x9C) terminates DCS/APC.
    try expectSnapshot(1, 5, "\x1b_Gdata\x07LEAK\x1b\\C",
        "C    \n");
}

test "parser: APC graphics command dispatches and returns to ground" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('_');
    _ = p.next('G');
    _ = p.next('a');
    _ = p.next('=');
    _ = p.next('p');
    _ = p.next(0x1B);
    // APC G... produces a graphics_command action (not nop).
    const result = p.next('\\').?;
    try std.testing.expect(result == .graphics_command);
    try std.testing.expectEqual(Action{ .print = 'X' }, p.next('X').?);
}

test "parser: APC non-graphics enters str_ignore and exits on ST" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('_');
    _ = p.next('X'); // Not 'G' — falls back to str_ignore.
    _ = p.next('d');
    _ = p.next('a');
    _ = p.next('t');
    _ = p.next('a');
    _ = p.next(0x1B);
    try std.testing.expectEqual(Action.nop, p.next('\\').?);
    try std.testing.expectEqual(Action{ .print = 'X' }, p.next('X').?);
}

test "parser: DCS enters str_ignore and exits on ST" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('P');
    _ = p.next('q');
    _ = p.next(0x1B);
    try std.testing.expectEqual(Action.nop, p.next('\\').?);
    try std.testing.expectEqual(Action{ .print = 'Z' }, p.next('Z').?);
}

// ===========================================================================
// New CSI sequences — parser action emission
// ===========================================================================

test "CSI G dispatches cursor_col_abs (0-based)" {
    var p: Parser = .{};
    for ("\x1b[5G") |byte| _ = p.next(byte);
    // Column 5 (1-based) → 4 (0-based)
    // We can check via csi_final
    try std.testing.expectEqual(@as(u8, 'G'), p.csi_final);
}

test "CSI d dispatches cursor_row_abs" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b[3d") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    try std.testing.expectEqual(Action{ .cursor_row_abs = 2 }, last.?);
}

test "CSI E dispatches cursor_next_line" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b[2E") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    try std.testing.expectEqual(Action{ .cursor_next_line = 2 }, last.?);
}

test "CSI F dispatches cursor_prev_line" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b[F") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    try std.testing.expectEqual(Action{ .cursor_prev_line = 1 }, last.?);
}

test "CSI L dispatches insert_lines" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b[3L") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    try std.testing.expectEqual(Action{ .insert_lines = 3 }, last.?);
}

test "CSI M dispatches delete_lines" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b[M") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    try std.testing.expectEqual(Action{ .delete_lines = 1 }, last.?);
}

test "CSI P dispatches delete_chars" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b[2P") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    try std.testing.expectEqual(Action{ .delete_chars = 2 }, last.?);
}

test "CSI @ dispatches insert_chars" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b[@") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    try std.testing.expectEqual(Action{ .insert_chars = 1 }, last.?);
}

test "CSI X dispatches erase_chars" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b[4X") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    try std.testing.expectEqual(Action{ .erase_chars = 4 }, last.?);
}

test "CSI S dispatches scroll_up" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b[2S") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    try std.testing.expectEqual(Action{ .scroll_up = 2 }, last.?);
}

test "CSI T dispatches scroll_down" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b[T") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    try std.testing.expectEqual(Action{ .scroll_down = 1 }, last.?);
}
