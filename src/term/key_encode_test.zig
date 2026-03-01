/// Tests for key_encode.zig — xterm and Kitty keyboard protocol encoding.
const std = @import("std");
const testing = std.testing;
const ke = @import("key_encode.zig");
const encodeKey = ke.encodeKey;
const KeyCode = ke.KeyCode;

// Kitty flag constants (mirror key_encode.zig internal constants)
const KITTY_DISAMBIGUATE: u5 = 1;
const KITTY_EVENT_TYPES: u5 = 2;
const KITTY_ALL_KEYS: u5 = 8;

// ---------------------------------------------------------------------------
// xterm encoding
// ---------------------------------------------------------------------------

test "xterm: unmodified arrow in normal mode" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .up }, .{}, &buf);
    try testing.expectEqualStrings("\x1b[A", r);
}

test "xterm: unmodified arrow in app mode" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .up }, .{ .cursor_keys_app = true }, &buf);
    try testing.expectEqualStrings("\x1bOA", r);
}

test "xterm: shift+tab" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .tab, .mods = .{ .shift = true } }, .{}, &buf);
    try testing.expectEqualStrings("\x1b[Z", r);
}

test "xterm: plain tab" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .tab }, .{}, &buf);
    try testing.expectEqualStrings("\t", r);
}

test "xterm: shift+up" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .up, .mods = .{ .shift = true } }, .{}, &buf);
    try testing.expectEqualStrings("\x1b[1;2A", r);
}

test "xterm: ctrl+shift+up" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .up, .mods = .{ .shift = true, .ctrl = true } }, .{}, &buf);
    try testing.expectEqualStrings("\x1b[1;6A", r);
}

test "xterm: alt+up" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .up, .mods = .{ .alt = true } }, .{}, &buf);
    try testing.expectEqualStrings("\x1b[1;3A", r);
}

test "xterm: modified home" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .home, .mods = .{ .shift = true } }, .{}, &buf);
    try testing.expectEqualStrings("\x1b[1;2H", r);
}

test "xterm: unmodified home" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .home }, .{}, &buf);
    try testing.expectEqualStrings("\x1b[H", r);
}

test "xterm: F1 unmodified" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .f1 }, .{}, &buf);
    try testing.expectEqualStrings("\x1bOP", r);
}

test "xterm: F1 with shift" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .f1, .mods = .{ .shift = true } }, .{}, &buf);
    try testing.expectEqualStrings("\x1b[1;2P", r);
}

test "xterm: F5 unmodified" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .f5 }, .{}, &buf);
    try testing.expectEqualStrings("\x1b[15~", r);
}

test "xterm: F5 with ctrl" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .f5, .mods = .{ .ctrl = true } }, .{}, &buf);
    try testing.expectEqualStrings("\x1b[15;5~", r);
}

test "xterm: page_up unmodified" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .page_up }, .{}, &buf);
    try testing.expectEqualStrings("\x1b[5~", r);
}

test "xterm: delete with shift" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .delete, .mods = .{ .shift = true } }, .{}, &buf);
    try testing.expectEqualStrings("\x1b[3;2~", r);
}

test "xterm: enter" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .enter }, .{}, &buf);
    try testing.expectEqualStrings("\r", r);
}

test "xterm: backspace" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .backspace }, .{}, &buf);
    try testing.expectEqualStrings("\x7f", r);
}

test "xterm: alt+backspace" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .backspace, .mods = .{ .alt = true } }, .{}, &buf);
    try testing.expectEqualStrings("\x1b\x7f", r);
}

test "xterm: escape" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .escape }, .{}, &buf);
    try testing.expectEqualStrings("\x1b", r);
}

test "xterm: ctrl+a" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .codepoint, .codepoint = 'a', .mods = .{ .ctrl = true } }, .{}, &buf);
    try testing.expectEqual(@as(u8, 1), r[0]);
    try testing.expectEqual(@as(usize, 1), r.len);
}

test "xterm: ctrl+c" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .codepoint, .codepoint = 'c', .mods = .{ .ctrl = true } }, .{}, &buf);
    try testing.expectEqual(@as(u8, 3), r[0]);
}

test "xterm: alt+a" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .codepoint, .codepoint = 'a', .mods = .{ .alt = true } }, .{}, &buf);
    try testing.expectEqualStrings("\x1ba", r);
}

test "xterm: plain 'a'" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .codepoint, .codepoint = 'a' }, .{}, &buf);
    try testing.expectEqualStrings("a", r);
}

test "xterm: release event produces nothing" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .up, .event_type = .release }, .{}, &buf);
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "xterm: modified arrows ignore app mode" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .up, .mods = .{ .shift = true } }, .{ .cursor_keys_app = true }, &buf);
    try testing.expectEqualStrings("\x1b[1;2A", r);
}

test "xterm: all four arrow directions" {
    var buf: [128]u8 = undefined;
    const dirs = [_]struct { key: KeyCode, ch: u8 }{
        .{ .key = .up, .ch = 'A' },
        .{ .key = .down, .ch = 'B' },
        .{ .key = .right, .ch = 'C' },
        .{ .key = .left, .ch = 'D' },
    };
    for (dirs) |d| {
        const r = encodeKey(.{ .key = d.key }, .{}, &buf);
        try testing.expectEqual(@as(u8, 0x1b), r[0]);
        try testing.expectEqual(@as(u8, '['), r[1]);
        try testing.expectEqual(d.ch, r[2]);
    }
}

test "xterm: F12" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .f12 }, .{}, &buf);
    try testing.expectEqualStrings("\x1b[24~", r);
}

test "xterm: insert unmodified" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .insert }, .{}, &buf);
    try testing.expectEqualStrings("\x1b[2~", r);
}

// ---------------------------------------------------------------------------
// Kitty encoding
// ---------------------------------------------------------------------------

test "kitty disambiguate: plain 'a' uses CSI u" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .codepoint, .codepoint = 'a' },
        .{ .kitty_flags = KITTY_DISAMBIGUATE },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[97u", r);
}

test "kitty disambiguate: shift+a uses CSI u" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .codepoint, .codepoint = 'A', .mods = .{ .shift = true } },
        .{ .kitty_flags = KITTY_DISAMBIGUATE },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[65;2u", r);
}

test "kitty disambiguate: arrow keys still use traditional" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .up },
        .{ .kitty_flags = KITTY_DISAMBIGUATE },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[A", r);
}

test "kitty disambiguate: enter uses CSI u" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .enter },
        .{ .kitty_flags = KITTY_DISAMBIGUATE },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[13u", r);
}

test "kitty disambiguate: escape uses CSI u" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .escape },
        .{ .kitty_flags = KITTY_DISAMBIGUATE },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[27u", r);
}

test "kitty event_types: release event encodes" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .codepoint, .codepoint = 'a', .event_type = .release },
        .{ .kitty_flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[97;1:3u", r);
}

test "kitty event_types: repeat event encodes" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .codepoint, .codepoint = 'a', .event_type = .repeat },
        .{ .kitty_flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[97;1:2u", r);
}

test "kitty all_keys: arrow uses CSI u" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .up },
        .{ .kitty_flags = KITTY_ALL_KEYS },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[57419u", r);
}

test "kitty all_keys: ctrl+a uses CSI u with mods" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .codepoint, .codepoint = 'a', .mods = .{ .ctrl = true } },
        .{ .kitty_flags = KITTY_ALL_KEYS },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[97;5u", r);
}

test "kitty: without event_types flag, release is ignored" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .codepoint, .codepoint = 'a', .event_type = .release },
        .{ .kitty_flags = KITTY_DISAMBIGUATE },
        &buf,
    );
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "kitty disambiguate: tab uses CSI u" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .tab },
        .{ .kitty_flags = KITTY_DISAMBIGUATE },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[9u", r);
}

test "kitty disambiguate: backspace uses CSI u" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .backspace },
        .{ .kitty_flags = KITTY_DISAMBIGUATE },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[127u", r);
}

test "kitty all_keys: F1 uses CSI u" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .f1 },
        .{ .kitty_flags = KITTY_ALL_KEYS },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[57364u", r);
}

test "kitty all_keys: shift+F5 uses CSI u with mods" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .f5, .mods = .{ .shift = true } },
        .{ .kitty_flags = KITTY_ALL_KEYS },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[57368;2u", r);
}

// ---------------------------------------------------------------------------
// State tests — kitty flags stack
// ---------------------------------------------------------------------------

test "kitty flags: push and query" {
    const alloc = std.testing.allocator;
    const TerminalState = @import("state.zig").TerminalState;
    var state = try TerminalState.init(alloc, 4, 10);
    defer state.deinit();

    try testing.expectEqual(@as(u5, 0), state.kittyFlags());

    state.apply(.{ .kitty_push_flags = 1 });
    try testing.expectEqual(@as(u5, 1), state.kittyFlags());

    state.apply(.{ .kitty_push_flags = 3 });
    try testing.expectEqual(@as(u5, 3), state.kittyFlags());
}

test "kitty flags: pop" {
    const alloc = std.testing.allocator;
    const TerminalState = @import("state.zig").TerminalState;
    var state = try TerminalState.init(alloc, 4, 10);
    defer state.deinit();

    state.apply(.{ .kitty_push_flags = 1 });
    state.apply(.{ .kitty_push_flags = 5 });
    state.apply(.{ .kitty_pop_flags = 1 });
    try testing.expectEqual(@as(u5, 1), state.kittyFlags());

    state.apply(.{ .kitty_pop_flags = 1 });
    try testing.expectEqual(@as(u5, 0), state.kittyFlags());
}

test "kitty flags: pop more than stack" {
    const alloc = std.testing.allocator;
    const TerminalState = @import("state.zig").TerminalState;
    var state = try TerminalState.init(alloc, 4, 10);
    defer state.deinit();

    state.apply(.{ .kitty_push_flags = 3 });
    state.apply(.{ .kitty_pop_flags = 10 });
    try testing.expectEqual(@as(u5, 0), state.kittyFlags());
}

test "kitty flags: query response" {
    const alloc = std.testing.allocator;
    const TerminalState = @import("state.zig").TerminalState;
    var state = try TerminalState.init(alloc, 4, 10);
    defer state.deinit();

    state.apply(.{ .kitty_push_flags = 5 });
    state.apply(.kitty_query_flags);
    const resp = state.drainResponse() orelse "";
    try testing.expectEqualStrings("\x1b[?5u", resp);
}

test "kitty flags: reset on alt screen enter" {
    const alloc = std.testing.allocator;
    const TerminalState = @import("state.zig").TerminalState;
    var state = try TerminalState.init(alloc, 4, 10);
    defer state.deinit();

    state.apply(.{ .kitty_push_flags = 3 });
    try testing.expectEqual(@as(u5, 3), state.kittyFlags());

    state.apply(.enter_alt_screen);
    try testing.expectEqual(@as(u5, 0), state.kittyFlags());
}

// ---------------------------------------------------------------------------
// Parser tests — kitty CSI sequences
// ---------------------------------------------------------------------------

test "parser: CSI > 1 u → kitty_push_flags" {
    const Parser = @import("parser.zig").Parser;
    var p = Parser{};

    // Feed: ESC [ > 1 u
    _ = p.next(0x1b);
    _ = p.next('[');
    _ = p.next('>');
    _ = p.next('1');
    const action = p.next('u');

    try testing.expect(action != null);
    try testing.expectEqual(@as(u5, 1), action.?.kitty_push_flags);
}

test "parser: CSI < 1 u → kitty_pop_flags" {
    const Parser = @import("parser.zig").Parser;
    var p = Parser{};

    _ = p.next(0x1b);
    _ = p.next('[');
    _ = p.next('<');
    _ = p.next('1');
    const action = p.next('u');

    try testing.expect(action != null);
    try testing.expectEqual(@as(u8, 1), action.?.kitty_pop_flags);
}

test "parser: CSI ? u → kitty_query_flags" {
    const Parser = @import("parser.zig").Parser;
    var p = Parser{};

    _ = p.next(0x1b);
    _ = p.next('[');
    _ = p.next('?');
    const action = p.next('u');

    try testing.expect(action != null);
    try testing.expect(action.? == .kitty_query_flags);
}

test "parser: plain CSI u → restore_cursor (unchanged)" {
    const Parser = @import("parser.zig").Parser;
    var p = Parser{};

    _ = p.next(0x1b);
    _ = p.next('[');
    const action = p.next('u');

    try testing.expect(action != null);
    try testing.expect(action.? == .restore_cursor);
}

// ---------------------------------------------------------------------------
// Parser tests — DECKPAM / DECKPNM
// ---------------------------------------------------------------------------

test "parser: ESC = → set_keypad_app_mode" {
    const Parser = @import("parser.zig").Parser;
    var p = Parser{};

    _ = p.next(0x1b);
    const action = p.next('=');

    try testing.expect(action != null);
    try testing.expect(action.? == .set_keypad_app_mode);
}

test "parser: ESC > → reset_keypad_app_mode" {
    const Parser = @import("parser.zig").Parser;
    var p = Parser{};

    _ = p.next(0x1b);
    const action = p.next('>');

    try testing.expect(action != null);
    try testing.expect(action.? == .reset_keypad_app_mode);
}

// ---------------------------------------------------------------------------
// State tests — keypad_app_mode
// ---------------------------------------------------------------------------

test "state: keypad_app_mode toggle" {
    const alloc = std.testing.allocator;
    const TerminalState = @import("state.zig").TerminalState;
    var state = try TerminalState.init(alloc, 4, 10);
    defer state.deinit();

    try testing.expectEqual(false, state.keypad_app_mode);

    state.apply(.set_keypad_app_mode);
    try testing.expectEqual(true, state.keypad_app_mode);

    state.apply(.reset_keypad_app_mode);
    try testing.expectEqual(false, state.keypad_app_mode);
}

// ---------------------------------------------------------------------------
// xterm numpad encoding
// ---------------------------------------------------------------------------

test "xterm numpad: normal mode sends ASCII digits" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(.{ .key = .kp_5 }, .{}, &buf);
    try testing.expectEqualStrings("5", r);
}

test "xterm numpad: normal mode sends operators" {
    var buf: [128]u8 = undefined;

    try testing.expectEqualStrings("+", encodeKey(.{ .key = .kp_plus }, .{}, &buf));
    try testing.expectEqualStrings("-", encodeKey(.{ .key = .kp_minus }, .{}, &buf));
    try testing.expectEqualStrings("*", encodeKey(.{ .key = .kp_multiply }, .{}, &buf));
    try testing.expectEqualStrings("/", encodeKey(.{ .key = .kp_divide }, .{}, &buf));
    try testing.expectEqualStrings(".", encodeKey(.{ .key = .kp_decimal }, .{}, &buf));
    try testing.expectEqualStrings("=", encodeKey(.{ .key = .kp_equal }, .{}, &buf));
    try testing.expectEqualStrings("\r", encodeKey(.{ .key = .kp_enter }, .{}, &buf));
}

test "xterm numpad: app mode sends SS3 sequences" {
    var buf: [128]u8 = undefined;
    const enc = ke.EncoderState{ .keypad_app_mode = true };

    try testing.expectEqualStrings("\x1bOp", encodeKey(.{ .key = .kp_0 }, enc, &buf));
    try testing.expectEqualStrings("\x1bOq", encodeKey(.{ .key = .kp_1 }, enc, &buf));
    try testing.expectEqualStrings("\x1bOy", encodeKey(.{ .key = .kp_9 }, enc, &buf));
    try testing.expectEqualStrings("\x1bOM", encodeKey(.{ .key = .kp_enter }, enc, &buf));
    try testing.expectEqualStrings("\x1bOk", encodeKey(.{ .key = .kp_plus }, enc, &buf));
    try testing.expectEqualStrings("\x1bOm", encodeKey(.{ .key = .kp_minus }, enc, &buf));
    try testing.expectEqualStrings("\x1bOj", encodeKey(.{ .key = .kp_multiply }, enc, &buf));
    try testing.expectEqualStrings("\x1bOo", encodeKey(.{ .key = .kp_divide }, enc, &buf));
    try testing.expectEqualStrings("\x1bOn", encodeKey(.{ .key = .kp_decimal }, enc, &buf));
    try testing.expectEqualStrings("\x1bOX", encodeKey(.{ .key = .kp_equal }, enc, &buf));
}

test "xterm numpad: modifiers fall back to ASCII even in app mode" {
    var buf: [128]u8 = undefined;
    const enc = ke.EncoderState{ .keypad_app_mode = true };

    const r = encodeKey(.{ .key = .kp_5, .mods = .{ .shift = true } }, enc, &buf);
    try testing.expectEqualStrings("5", r);
}

// ---------------------------------------------------------------------------
// Kitty numpad encoding
// ---------------------------------------------------------------------------

test "kitty disambiguate: numpad uses CSI u with distinct codepoints" {
    var buf: [128]u8 = undefined;

    const r0 = encodeKey(
        .{ .key = .kp_0 },
        .{ .kitty_flags = KITTY_DISAMBIGUATE },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[57399u", r0);

    const r_enter = encodeKey(
        .{ .key = .kp_enter },
        .{ .kitty_flags = KITTY_DISAMBIGUATE },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[57414u", r_enter);

    const r_plus = encodeKey(
        .{ .key = .kp_plus, .mods = .{ .shift = true } },
        .{ .kitty_flags = KITTY_DISAMBIGUATE },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[57413;2u", r_plus);
}

test "kitty all_keys: numpad uses CSI u" {
    var buf: [128]u8 = undefined;

    const r = encodeKey(
        .{ .key = .kp_5 },
        .{ .kitty_flags = KITTY_ALL_KEYS },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[57404u", r);
}
