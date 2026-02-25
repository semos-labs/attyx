/// Key encoding for terminal input — supports xterm and Kitty keyboard protocol.
///
/// Pure, deterministic module with no side effects. Translates key events
/// into escape sequences based on terminal mode flags.
const std = @import("std");

pub const KeyCode = enum(u16) {
    // Navigation
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    insert,
    delete,

    // Editing
    backspace,
    enter,
    tab,
    escape,

    // Function keys
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,

    // A Unicode codepoint (printable key). The actual codepoint is in KeyEvent.codepoint.
    codepoint,
};

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super_key: bool = false,
    _pad: u4 = 0,

    pub fn toCSI(self: Modifiers) u8 {
        var m: u8 = 1;
        if (self.shift) m += 1;
        if (self.alt) m += 2;
        if (self.ctrl) m += 4;
        if (self.super_key) m += 8;
        return m;
    }

    pub fn any(self: Modifiers) bool {
        return self.shift or self.alt or self.ctrl or self.super_key;
    }
};

pub const EventType = enum(u8) {
    press = 1,
    repeat = 2,
    release = 3,
};

pub const KeyEvent = struct {
    key: KeyCode,
    mods: Modifiers = .{},
    event_type: EventType = .press,
    codepoint: u21 = 0,
};

pub const EncoderState = struct {
    cursor_keys_app: bool = false,
    kitty_flags: u5 = 0,
};

// Kitty flag bits
const KITTY_DISAMBIGUATE: u5 = 1;
const KITTY_EVENT_TYPES: u5 = 2;
const KITTY_ALL_KEYS: u5 = 8;

/// Encode a key event into an escape sequence.
/// Returns a slice of `out` containing the encoded bytes.
pub fn encodeKey(event: KeyEvent, enc_state: EncoderState, out: *[128]u8) []const u8 {
    if (enc_state.kitty_flags != 0) {
        return encodeKitty(event, enc_state, out);
    }
    return encodeXterm(event, enc_state, out);
}

// ---------------------------------------------------------------------------
// xterm encoding (kitty_flags == 0)
// ---------------------------------------------------------------------------

fn encodeXterm(event: KeyEvent, enc_state: EncoderState, out: *[128]u8) []const u8 {
    // Only encode press/repeat in xterm mode
    if (event.event_type == .release) return out[0..0];

    const mods = event.mods;

    switch (event.key) {
        .tab => {
            if (mods.shift) return writeStr(out, "\x1b[Z");
            return writeStr(out, "\t");
        },
        .enter => return writeStr(out, "\r"),
        .backspace => {
            if (mods.alt) {
                return writeStr(out, "\x1b\x7f");
            }
            return writeStr(out, "\x7f");
        },
        .escape => return writeStr(out, "\x1b"),

        .up, .down, .left, .right => {
            return encodeArrow(event.key, mods, enc_state.cursor_keys_app, out);
        },

        .home, .end => {
            return encodeHomeEnd(event.key, mods, out);
        },

        .f1, .f2, .f3, .f4 => {
            return encodeFKey1to4(event.key, mods, out);
        },

        .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => {
            return encodeFKey5to12(event.key, mods, out);
        },

        .page_up, .page_down, .insert, .delete => {
            return encodeTildeKey(event.key, mods, out);
        },

        .codepoint => {
            return encodeCodepoint(event.codepoint, mods, out);
        },
    }
}

fn encodeArrow(key: KeyCode, mods: Modifiers, app_mode: bool, out: *[128]u8) []const u8 {
    const letter: u8 = switch (key) {
        .up => 'A',
        .down => 'B',
        .right => 'C',
        .left => 'D',
        else => unreachable,
    };

    if (mods.any()) {
        // Modified: ESC[1;{mod}X
        return bufPrint(out, "\x1b[1;{d}{c}", .{ mods.toCSI(), letter });
    }

    if (app_mode) {
        // Application mode: ESC O X
        out[0] = 0x1b;
        out[1] = 'O';
        out[2] = letter;
        return out[0..3];
    }

    // Normal mode: ESC [ X
    out[0] = 0x1b;
    out[1] = '[';
    out[2] = letter;
    return out[0..3];
}

fn encodeHomeEnd(key: KeyCode, mods: Modifiers, out: *[128]u8) []const u8 {
    const letter: u8 = if (key == .home) 'H' else 'F';
    if (mods.any()) {
        return bufPrint(out, "\x1b[1;{d}{c}", .{ mods.toCSI(), letter });
    }
    out[0] = 0x1b;
    out[1] = '[';
    out[2] = letter;
    return out[0..3];
}

fn encodeFKey1to4(key: KeyCode, mods: Modifiers, out: *[128]u8) []const u8 {
    const letter: u8 = switch (key) {
        .f1 => 'P',
        .f2 => 'Q',
        .f3 => 'R',
        .f4 => 'S',
        else => unreachable,
    };
    if (mods.any()) {
        return bufPrint(out, "\x1b[1;{d}{c}", .{ mods.toCSI(), letter });
    }
    out[0] = 0x1b;
    out[1] = 'O';
    out[2] = letter;
    return out[0..3];
}

fn encodeFKey5to12(key: KeyCode, mods: Modifiers, out: *[128]u8) []const u8 {
    const code: u8 = switch (key) {
        .f5 => 15,
        .f6 => 17,
        .f7 => 18,
        .f8 => 19,
        .f9 => 20,
        .f10 => 21,
        .f11 => 23,
        .f12 => 24,
        else => unreachable,
    };
    if (mods.any()) {
        return bufPrint(out, "\x1b[{d};{d}~", .{ code, mods.toCSI() });
    }
    return bufPrint(out, "\x1b[{d}~", .{code});
}

fn encodeTildeKey(key: KeyCode, mods: Modifiers, out: *[128]u8) []const u8 {
    const code: u8 = switch (key) {
        .page_up => 5,
        .page_down => 6,
        .insert => 2,
        .delete => 3,
        else => unreachable,
    };
    if (mods.any()) {
        return bufPrint(out, "\x1b[{d};{d}~", .{ code, mods.toCSI() });
    }
    return bufPrint(out, "\x1b[{d}~", .{code});
}

fn encodeCodepoint(cp: u21, mods: Modifiers, out: *[128]u8) []const u8 {
    // Ctrl+letter → control byte
    if (mods.ctrl and !mods.alt and !mods.super_key) {
        if (cp >= 'a' and cp <= 'z') {
            out[0] = @intCast(cp - 'a' + 1);
            return out[0..1];
        }
        if (cp >= 'A' and cp <= 'Z') {
            out[0] = @intCast(cp - 'A' + 1);
            return out[0..1];
        }
        if (cp == '[') return writeStr(out, "\x1b");
        if (cp == ']') {
            out[0] = 0x1d;
            return out[0..1];
        }
        if (cp == '\\') {
            out[0] = 0x1c;
            return out[0..1];
        }
        if (cp == '^' or cp == '6') {
            out[0] = 0x1e;
            return out[0..1];
        }
        if (cp == '_' or cp == '-') {
            out[0] = 0x1f;
            return out[0..1];
        }
        if (cp == '@' or cp == ' ' or cp == '2') {
            out[0] = 0x00;
            return out[0..1];
        }
        // Unknown ctrl combination — send nothing
        return out[0..0];
    }

    // Alt+key → ESC prefix + character
    if (mods.alt and !mods.ctrl and !mods.super_key) {
        out[0] = 0x1b;
        const utf8_len = std.unicode.utf8Encode(cp, out[1..5]) catch return out[0..0];
        return out[0 .. 1 + utf8_len];
    }

    // Plain codepoint → UTF-8
    if (!mods.any()) {
        const utf8_len = std.unicode.utf8Encode(cp, out[0..4]) catch return out[0..0];
        return out[0..utf8_len];
    }

    return out[0..0];
}

// ---------------------------------------------------------------------------
// Kitty keyboard protocol encoding
// ---------------------------------------------------------------------------

fn encodeKitty(event: KeyEvent, enc_state: EncoderState, out: *[128]u8) []const u8 {
    const flags = enc_state.kitty_flags;

    // Without event_types flag, only encode press
    if (flags & KITTY_EVENT_TYPES == 0 and event.event_type != .press) {
        return out[0..0];
    }

    // all_keys flag: everything uses CSI u format
    if (flags & KITTY_ALL_KEYS != 0) {
        return encodeKittyCSIu(event, enc_state, out);
    }

    // disambiguate flag: only ambiguous keys use CSI u
    if (flags & KITTY_DISAMBIGUATE != 0) {
        // Special keys still use their traditional sequences with modifiers
        switch (event.key) {
            .up, .down, .left, .right => {
                return encodeArrow(event.key, event.mods, enc_state.cursor_keys_app, out);
            },
            .home, .end => return encodeHomeEnd(event.key, event.mods, out),
            .f1, .f2, .f3, .f4 => return encodeFKey1to4(event.key, event.mods, out),
            .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => return encodeFKey5to12(event.key, event.mods, out),
            .page_up, .page_down, .insert, .delete => return encodeTildeKey(event.key, event.mods, out),
            // Ambiguous keys use CSI u
            .enter, .tab, .backspace, .escape, .codepoint => {
                return encodeKittyCSIu(event, enc_state, out);
            },
        }
    }

    // Just event_types flag but no disambiguate — use xterm for press,
    // but need CSI u for release/repeat
    if (event.event_type != .press) {
        return encodeKittyCSIu(event, enc_state, out);
    }
    return encodeXterm(event, enc_state, out);
}

fn encodeKittyCSIu(event: KeyEvent, enc_state: EncoderState, out: *[128]u8) []const u8 {
    const flags = enc_state.kitty_flags;
    const cp: u21 = kittyCodepoint(event);

    const mod_val = event.mods.toCSI();
    const need_event = (flags & KITTY_EVENT_TYPES != 0) and event.event_type != .press;
    const need_mods = mod_val > 1 or need_event;

    if (need_mods) {
        if (need_event) {
            const et: u8 = @intFromEnum(event.event_type);
            return bufPrint(out, "\x1b[{d};{d}:{d}u", .{ cp, mod_val, et });
        }
        return bufPrint(out, "\x1b[{d};{d}u", .{ cp, mod_val });
    }

    return bufPrint(out, "\x1b[{d}u", .{cp});
}

fn kittyCodepoint(event: KeyEvent) u21 {
    return switch (event.key) {
        .escape => 27,
        .enter => 13,
        .tab => 9,
        .backspace => 127,
        .insert => 2,
        .delete => 3,
        .left => 57417,
        .right => 57418,
        .up => 57419,
        .down => 57420,
        .page_up => 57421,
        .page_down => 57422,
        .home => 57423,
        .end => 57424,
        .f1 => 57364,
        .f2 => 57365,
        .f3 => 57366,
        .f4 => 57367,
        .f5 => 57368,
        .f6 => 57369,
        .f7 => 57370,
        .f8 => 57371,
        .f9 => 57372,
        .f10 => 57373,
        .f11 => 57374,
        .f12 => 57375,
        .codepoint => event.codepoint,
    };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn writeStr(out: *[128]u8, s: []const u8) []const u8 {
    @memcpy(out[0..s.len], s);
    return out[0..s.len];
}

fn bufPrint(out: *[128]u8, comptime fmt: []const u8, args: anytype) []const u8 {
    const result = std.fmt.bufPrint(out, fmt, args) catch return out[0..0];
    return result;
}

// Tests are in key_encode_test.zig
test {
    _ = @import("key_encode_test.zig");
}
