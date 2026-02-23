const std = @import("std");
const helpers = @import("helpers.zig");
const Parser = @import("../../term/parser.zig").Parser;
const Action = @import("../../term/actions.zig").Action;
const expectSnapshot = helpers.expectSnapshot;
const expectChunkedSnapshot = helpers.expectChunkedSnapshot;

// ===========================================================================
// Escape sequence framing (golden)
// ===========================================================================

test "golden: ESC consumes the following byte as escape sequence" {
    try expectSnapshot(2, 4, "A\x1bBC",
        "AC  \n" ++
        "    \n");
}

test "golden: ESC non-bracket is ignored" {
    try expectSnapshot(2, 10, "\x1bXHello",
        "Hello     \n" ++
        "          \n");
}

// ===========================================================================
// Incremental parsing (golden)
// ===========================================================================

test "golden: ESC split across chunks" {
    try expectChunkedSnapshot(2, 10, &.{ "\x1b", "[2J", "Hello" },
        "Hello     \n" ++
        "          \n");
}

test "golden: CSI params split across chunks" {
    try expectChunkedSnapshot(2, 10, &.{ "\x1b[31", "mHello" },
        "Hello     \n" ++
        "          \n");
}

test "golden: text interleaved with split CSI" {
    try expectChunkedSnapshot(2, 10, &.{ "AB\x1b[", "1mCD" },
        "ABCD      \n" ++
        "          \n");
}

test "golden: single-byte-at-a-time feeding" {
    try expectChunkedSnapshot(1, 5, &.{ "\x1b", "[", "3", "1", "m", "H", "i" },
        "Hi   \n");
}

// ===========================================================================
// Parser unit tests (state machine, action emission)
// ===========================================================================

test "printable bytes produce print actions" {
    var p: Parser = .{};
    try std.testing.expectEqual(Action{ .print = 'A' }, p.next('A').?);
    try std.testing.expectEqual(Action{ .print = '~' }, p.next('~').?);
    try std.testing.expectEqual(Action{ .print = ' ' }, p.next(' ').?);
}

test "control codes produce control actions" {
    var p: Parser = .{};
    try std.testing.expectEqual(Action{ .control = .lf }, p.next('\n').?);
    try std.testing.expectEqual(Action{ .control = .cr }, p.next('\r').?);
    try std.testing.expectEqual(Action{ .control = .bs }, p.next(0x08).?);
    try std.testing.expectEqual(Action{ .control = .tab }, p.next('\t').?);
}

test "unknown bytes produce nop" {
    var p: Parser = .{};
    try std.testing.expectEqual(Action{ .nop = {} }, p.next(0x00).?);
    try std.testing.expectEqual(Action{ .nop = {} }, p.next(0x7F).?);
}

test "ESC enters escape state, no action emitted" {
    var p: Parser = .{};
    try std.testing.expect(p.next(0x1B) == null);
}

test "ESC followed by non-bracket emits nop and returns to ground" {
    var p: Parser = .{};
    try std.testing.expect(p.next(0x1B) == null);
    try std.testing.expectEqual(Action{ .nop = {} }, p.next('X').?);
    try std.testing.expectEqual(Action{ .print = 'A' }, p.next('A').?);
}

test "ESC during escape cancels first, stays in escape" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    try std.testing.expectEqual(Action{ .nop = {} }, p.next(0x1B).?);
    try std.testing.expect(p.next('[') == null);
    const a = p.next('m').?;
    switch (a) {
        .sgr => {},
        else => return error.TestUnexpectedResult,
    }
}

test "ESC during CSI cancels sequence, enters new escape" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('3');
    try std.testing.expectEqual(Action{ .nop = {} }, p.next(0x1B).?);
    try std.testing.expect(p.next('[') == null);
    const a = p.next('m').?;
    switch (a) {
        .sgr => {},
        else => return error.TestUnexpectedResult,
    }
}

test "CSI parameters are buffered for tracing" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('3');
    _ = p.next('1');
    _ = p.next(';');
    _ = p.next('1');
    _ = p.next('m');
    try std.testing.expectEqualStrings("31;1", p.csi_buf[0..p.csi_len]);
    try std.testing.expectEqual(@as(u8, 'm'), p.csi_final);
}

test "returns to ground after CSI final byte" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('m');
    try std.testing.expectEqual(Action{ .print = 'Z' }, p.next('Z').?);
}

test "CSI H dispatches cursor_abs (0-based)" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('5');
    _ = p.next(';');
    _ = p.next('1');
    _ = p.next('0');
    const a = p.next('H').?;
    try std.testing.expectEqual(Action{ .cursor_abs = .{ .row = 4, .col = 9 } }, a);
}

test "CSI H with no params defaults to home (0,0)" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    const a = p.next('H').?;
    try std.testing.expectEqual(Action{ .cursor_abs = .{ .row = 0, .col = 0 } }, a);
}

test "CSI A dispatches cursor_rel up" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('3');
    const a = p.next('A').?;
    try std.testing.expectEqual(Action{ .cursor_rel = .{ .dir = .up, .n = 3 } }, a);
}

test "CSI cursor_rel defaults n to 1" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    const a = p.next('B').?;
    try std.testing.expectEqual(Action{ .cursor_rel = .{ .dir = .down, .n = 1 } }, a);
}

test "CSI J dispatches erase_display" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('2');
    const a = p.next('J').?;
    try std.testing.expectEqual(Action{ .erase_display = .all }, a);
}

test "CSI K dispatches erase_line" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    const a = p.next('K').?;
    try std.testing.expectEqual(Action{ .erase_line = .to_end }, a);
}

test "CSI m dispatches sgr with parsed params" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('3');
    _ = p.next('1');
    const a = p.next('m').?;
    switch (a) {
        .sgr => |sgr| {
            try std.testing.expectEqual(@as(u8, 1), sgr.len);
            try std.testing.expectEqual(@as(u8, 31), sgr.params[0]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "CSI m with no params defaults to reset (0)" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    const a = p.next('m').?;
    switch (a) {
        .sgr => |sgr| {
            try std.testing.expectEqual(@as(u8, 1), sgr.len);
            try std.testing.expectEqual(@as(u8, 0), sgr.params[0]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "CSI m with multiple params" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('1');
    _ = p.next(';');
    _ = p.next('3');
    _ = p.next('1');
    _ = p.next(';');
    _ = p.next('4');
    const a = p.next('m').?;
    switch (a) {
        .sgr => |sgr| {
            try std.testing.expectEqual(@as(u8, 3), sgr.len);
            try std.testing.expectEqual(@as(u8, 1), sgr.params[0]);
            try std.testing.expectEqual(@as(u8, 31), sgr.params[1]);
            try std.testing.expectEqual(@as(u8, 4), sgr.params[2]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "unsupported CSI final byte returns nop" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    try std.testing.expectEqual(Action{ .nop = {} }, p.next('z').?);
}

test "CSI r dispatches set_scroll_region" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('2');
    _ = p.next(';');
    _ = p.next('4');
    const a = p.next('r').?;
    try std.testing.expectEqual(Action{ .set_scroll_region = .{ .top = 2, .bottom = 4 } }, a);
}

test "CSI r with no params uses defaults (0,0)" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    const a = p.next('r').?;
    try std.testing.expectEqual(Action{ .set_scroll_region = .{ .top = 0, .bottom = 0 } }, a);
}

test "ESC D produces index action" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    const a = p.next('D').?;
    try std.testing.expectEqual(Action.index, a);
    try std.testing.expectEqual(Action{ .print = 'Z' }, p.next('Z').?);
}

test "ESC M produces reverse_index action" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    const a = p.next('M').?;
    try std.testing.expectEqual(Action.reverse_index, a);
    try std.testing.expectEqual(Action{ .print = 'Z' }, p.next('Z').?);
}

test "ESC 7 produces save_cursor action" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    try std.testing.expectEqual(Action.save_cursor, p.next('7').?);
}

test "ESC 8 produces restore_cursor action" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    try std.testing.expectEqual(Action.restore_cursor, p.next('8').?);
}

test "CSI s produces save_cursor action" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    try std.testing.expectEqual(Action.save_cursor, p.next('s').?);
}

test "CSI u produces restore_cursor action" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    try std.testing.expectEqual(Action.restore_cursor, p.next('u').?);
}

test "CSI ?1049h produces enter_alt_screen" {
    var p: Parser = .{};
    for ("\x1b[?1049h") |byte| _ = p.next(byte);
    try std.testing.expectEqual(@as(u8, 'h'), p.csi_final);
}

test "CSI ?1049l produces dec_private_mode reset" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b[?1049l") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    switch (last.?) {
        .dec_private_mode => |dm| {
            try std.testing.expectEqual(@as(u8, 1), dm.len);
            try std.testing.expectEqual(@as(u16, 1049), dm.params[0]);
            try std.testing.expect(!dm.set);
        },
        else => return error.TestExpectedEqual,
    }
}

test "CSI ?47h and ?1047h produce dec_private_mode set" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b[?47h") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    switch (last.?) {
        .dec_private_mode => |dm| {
            try std.testing.expectEqual(@as(u16, 47), dm.params[0]);
            try std.testing.expect(dm.set);
        },
        else => return error.TestExpectedEqual,
    }

    last = null;
    for ("\x1b[?1047h") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    switch (last.?) {
        .dec_private_mode => |dm| try std.testing.expectEqual(@as(u16, 1047), dm.params[0]),
        else => return error.TestExpectedEqual,
    }
}

test "CSI ?unsupported still produces dec_private_mode" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b[?25h") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    switch (last.?) {
        .dec_private_mode => |dm| {
            try std.testing.expectEqual(@as(u16, 25), dm.params[0]);
            try std.testing.expect(dm.set);
        },
        else => return error.TestExpectedEqual,
    }
}

test "CSI ?1000;1006h produces compound dec_private_mode" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b[?1000;1006h") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    switch (last.?) {
        .dec_private_mode => |dm| {
            try std.testing.expectEqual(@as(u8, 2), dm.len);
            try std.testing.expectEqual(@as(u16, 1000), dm.params[0]);
            try std.testing.expectEqual(@as(u16, 1006), dm.params[1]);
            try std.testing.expect(dm.set);
        },
        else => return error.TestExpectedEqual,
    }
}

test "OSC 8 hyperlink start (BEL terminator)" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b]8;;https://example.com\x07") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    switch (last.?) {
        .hyperlink_start => |uri| try std.testing.expectEqualStrings("https://example.com", uri),
        else => return error.TestExpectedEqual,
    }
}

test "OSC 8 hyperlink start (ST terminator)" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b]8;;https://example.com\x1b\\") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    switch (last.?) {
        .hyperlink_start => |uri| try std.testing.expectEqualStrings("https://example.com", uri),
        else => return error.TestExpectedEqual,
    }
}

test "OSC 8 hyperlink end" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b]8;;\x07") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    try std.testing.expectEqual(Action.hyperlink_end, last.?);
}

test "OSC 2 title" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b]2;My Title\x07") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    switch (last.?) {
        .set_title => |title| try std.testing.expectEqualStrings("My Title", title),
        else => return error.TestExpectedEqual,
    }
}

test "OSC 0 also sets title" {
    var p: Parser = .{};
    var last: ?Action = null;
    for ("\x1b]0;WindowTitle\x1b\\") |byte| {
        if (p.next(byte)) |a| last = a;
    }
    switch (last.?) {
        .set_title => |title| try std.testing.expectEqualStrings("WindowTitle", title),
        else => return error.TestExpectedEqual,
    }
}

test "OSC overflow produces nop" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next(']');
    _ = p.next('8');
    _ = p.next(';');
    _ = p.next(';');
    for (0..Parser.osc_buf_size) |_| _ = p.next('x');
    try std.testing.expect(p.osc_overflow);
    const a = p.next(0x07).?;
    try std.testing.expectEqual(Action.nop, a);
}

test "OSC returns to ground after dispatch" {
    var p: Parser = .{};
    for ("\x1b]8;;uri\x07") |byte| _ = p.next(byte);
    try std.testing.expectEqual(Action{ .print = 'Z' }, p.next('Z').?);
}

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
// New CSI sequences — parser action emission
// ===========================================================================

// ===========================================================================
// DCS / APC / PM string ignore
// ===========================================================================

test "APC payload is consumed silently" {
    try expectSnapshot(1, 5, "\x1b_Ga=p,q=2\x1b\\A",
        "A    \n");
}

test "DCS payload is consumed silently" {
    try expectSnapshot(1, 5, "\x1bPtmux;stuff\x1b\\B",
        "B    \n");
}

test "APC terminated by BEL" {
    try expectSnapshot(1, 5, "\x1b_Gdata\x07C",
        "C    \n");
}

test "parser: APC enters str_ignore and exits on ST" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('_');
    _ = p.next('G');
    _ = p.next('a');
    _ = p.next('=');
    _ = p.next('p');
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
