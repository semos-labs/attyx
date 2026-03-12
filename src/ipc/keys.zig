// Attyx — Send-keys escape processing
//
// Handles C-style escape sequences (\n, \t, \xHH, etc.) and named key
// tokens ({Enter}, {Up}, {Ctrl-c}, {Ctrl-Shift-Up}, etc.) for the
// send-keys IPC command.
//
// Modifier combos on special keys use xterm-style encoding:
//   {Ctrl-Up}       → ESC[1;5A    (modifier 5 = 1 + ctrl)
//   {Shift-Tab}     → ESC[Z       (standard backtab)
//   {Alt-a}         → ESC a       (meta prefix)
//   {Ctrl-Shift-Up} → ESC[1;6A    (modifier 6 = 1 + ctrl + shift)

const std = @import("std");

/// Process C-style escape sequences and {KeyName} tokens in a send-keys string.
pub fn unescapeKeys(input: []const u8, out: []u8) []const u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < input.len and o < out.len) {
        // Named key tokens: {KeyName}
        if (input[i] == '{') {
            if (resolveNamedKey(input[i..], out[o..])) |result| {
                o += result.written;
                i += result.advance;
                continue;
            }
            // Not a valid key name — emit literal '{'
            out[o] = '{';
            o += 1;
            i += 1;
            continue;
        }

        if (input[i] != '\\' or i + 1 >= input.len) {
            out[o] = input[i];
            o += 1;
            i += 1;
            continue;
        }
        // C-style escape sequence
        i += 1; // skip backslash
        switch (input[i]) {
            'n' => {
                out[o] = '\n';
                o += 1;
                i += 1;
            },
            't' => {
                out[o] = '\t';
                o += 1;
                i += 1;
            },
            'r' => {
                out[o] = '\r';
                o += 1;
                i += 1;
            },
            '\\' => {
                out[o] = '\\';
                o += 1;
                i += 1;
            },
            '\'' => {
                out[o] = '\'';
                o += 1;
                i += 1;
            },
            '"' => {
                out[o] = '"';
                o += 1;
                i += 1;
            },
            '0' => {
                out[o] = 0;
                o += 1;
                i += 1;
            },
            'a' => {
                out[o] = 0x07; // BEL
                o += 1;
                i += 1;
            },
            'b' => {
                out[o] = 0x08; // BS
                o += 1;
                i += 1;
            },
            'e' => {
                out[o] = 0x1b; // ESC
                o += 1;
                i += 1;
            },
            'x' => {
                i += 1;
                if (i + 1 < input.len) {
                    if (std.fmt.parseInt(u8, input[i .. i + 2], 16)) |byte| {
                        out[o] = byte;
                        o += 1;
                        i += 2;
                    } else |_| {
                        out[o] = '\\';
                        o += 1;
                        if (o < out.len) {
                            out[o] = 'x';
                            o += 1;
                        }
                    }
                } else {
                    out[o] = '\\';
                    o += 1;
                    if (o < out.len) {
                        out[o] = 'x';
                        o += 1;
                    }
                }
            },
            else => {
                out[o] = '\\';
                o += 1;
                if (o < out.len) {
                    out[o] = input[i];
                    o += 1;
                }
                i += 1;
            },
        }
    }
    return out[0..o];
}

// ---------------------------------------------------------------------------
// Named key resolution
// ---------------------------------------------------------------------------

const ResolvedKey = struct { written: usize, advance: usize };

/// Parse a {KeyName} token at the start of `s`, write the escape sequence
/// into `out`. Returns bytes written + input bytes consumed, or null.
fn resolveNamedKey(s: []const u8, out: []u8) ?ResolvedKey {
    if (s.len < 3 or s[0] != '{') return null;
    const close = std.mem.indexOfScalar(u8, s[1..], '}') orelse return null;
    const name = s[1 .. 1 + close];
    const adv = close + 2; // skip '{' + name + '}'

    // Lowercase the name for case-insensitive matching
    if (name.len == 0 or name.len > 24) return null;
    var lower: [24]u8 = undefined;
    for (name, 0..) |ch, idx| {
        lower[idx] = std.ascii.toLower(ch);
    }
    const key = lower[0..name.len];

    // Parse modifier prefixes: ctrl-, shift-, alt-, super- (combinable)
    var mods = Mods{};
    var base = key;
    while (true) {
        if (startsWith(base, "ctrl-")) {
            mods.ctrl = true;
            base = base[5..];
        } else if (startsWith(base, "shift-")) {
            mods.shift = true;
            base = base[6..];
        } else if (startsWith(base, "alt-")) {
            mods.alt = true;
            base = base[4..];
        } else if (startsWith(base, "super-")) {
            mods.super = true;
            base = base[6..];
        } else break;
    }

    if (base.len == 0) return null;

    const written = encodeKey(base, mods, out) orelse return null;
    return .{ .written = written, .advance = adv };
}

const Mods = struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,

    fn hasMods(self: Mods) bool {
        return self.shift or self.alt or self.ctrl or self.super;
    }

    /// Xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4) + super(8)
    fn toCSI(self: Mods) u8 {
        var m: u8 = 1;
        if (self.shift) m += 1;
        if (self.alt) m += 2;
        if (self.ctrl) m += 4;
        if (self.super) m += 8;
        return m;
    }
};

/// Encode a base key name + modifiers into `out`. Returns bytes written.
fn encodeKey(base: []const u8, mods: Mods, out: []u8) ?usize {
    // Special case: Shift-Tab → backtab
    if (eql(base, "tab") and mods.shift and !mods.ctrl and !mods.alt) {
        return copyStatic("\x1b[Z", out);
    }

    // Single letter with modifiers
    if (base.len == 1 and base[0] >= 'a' and base[0] <= 'z') {
        return encodeSingleChar(base[0], mods, out);
    }

    // Try as a special key (arrow, function, etc.)
    if (specialKeyInfo(base)) |info| {
        return encodeSpecialKey(info, mods, out);
    }

    // Unmodified simple keys (no modifiers parsed, or modifiers not applicable)
    if (!mods.hasMods()) {
        if (simpleKeySeq(base)) |seq| {
            return copyStatic(seq, out);
        }
    }

    return null;
}

/// Encode a single letter with modifiers.
fn encodeSingleChar(ch: u8, mods: Mods, out: []u8) ?usize {
    if (!mods.hasMods()) return null; // bare letter not handled here

    // Ctrl+letter (no other mods) → control byte
    if (mods.ctrl and !mods.shift and !mods.alt and !mods.super) {
        if (out.len < 1) return null;
        out[0] = ch - 'a' + 1;
        return 1;
    }

    // Alt+letter (no other mods) → ESC prefix
    if (mods.alt and !mods.ctrl and !mods.shift and !mods.super) {
        if (out.len < 2) return null;
        out[0] = 0x1b;
        out[1] = ch;
        return 2;
    }

    // Alt+Ctrl+letter → ESC + control byte
    if (mods.alt and mods.ctrl and !mods.shift and !mods.super) {
        if (out.len < 2) return null;
        out[0] = 0x1b;
        out[1] = ch - 'a' + 1;
        return 2;
    }

    // Complex modifier combos on letters → CSI u encoding
    // ESC[{codepoint};{modifier}u
    return fmtCSIu(ch, mods.toCSI(), out);
}

// Keys that use ESC[1;{mod}{final} format when modified
const SpecialKeyInfo = struct {
    // For SS3 keys (F1-F4): unmodified = ESC O {final}, modified = ESC[1;{mod}{final}
    // For CSI keys (arrows, etc.): unmodified = ESC[{final}, modified = ESC[1;{mod}{final}
    // For tilde keys (F5+, Ins, Del, PgUp, PgDn): unmodified = ESC[{N}~, modified = ESC[{N};{mod}~
    kind: enum { csi_final, tilde, ss3 },
    code: u8, // final char for csi_final/ss3, number for tilde
    unmodified: []const u8, // fallback for no-modifier case
};

fn specialKeyInfo(base: []const u8) ?SpecialKeyInfo {
    // Arrows
    if (eql(base, "up")) return .{ .kind = .csi_final, .code = 'A', .unmodified = "\x1b[A" };
    if (eql(base, "down")) return .{ .kind = .csi_final, .code = 'B', .unmodified = "\x1b[B" };
    if (eql(base, "right")) return .{ .kind = .csi_final, .code = 'C', .unmodified = "\x1b[C" };
    if (eql(base, "left")) return .{ .kind = .csi_final, .code = 'D', .unmodified = "\x1b[D" };
    if (eql(base, "home")) return .{ .kind = .csi_final, .code = 'H', .unmodified = "\x1b[H" };
    if (eql(base, "end")) return .{ .kind = .csi_final, .code = 'F', .unmodified = "\x1b[F" };

    // Tilde keys
    if (eql(base, "insert") or eql(base, "ins")) return .{ .kind = .tilde, .code = 2, .unmodified = "\x1b[2~" };
    if (eql(base, "delete") or eql(base, "del")) return .{ .kind = .tilde, .code = 3, .unmodified = "\x1b[3~" };
    if (eql(base, "pgup") or eql(base, "pageup")) return .{ .kind = .tilde, .code = 5, .unmodified = "\x1b[5~" };
    if (eql(base, "pgdn") or eql(base, "pagedown")) return .{ .kind = .tilde, .code = 6, .unmodified = "\x1b[6~" };

    // SS3 function keys (F1-F4)
    if (eql(base, "f1")) return .{ .kind = .ss3, .code = 'P', .unmodified = "\x1bOP" };
    if (eql(base, "f2")) return .{ .kind = .ss3, .code = 'Q', .unmodified = "\x1bOQ" };
    if (eql(base, "f3")) return .{ .kind = .ss3, .code = 'R', .unmodified = "\x1bOR" };
    if (eql(base, "f4")) return .{ .kind = .ss3, .code = 'S', .unmodified = "\x1bOS" };

    // Tilde function keys (F5-F12)
    if (eql(base, "f5")) return .{ .kind = .tilde, .code = 15, .unmodified = "\x1b[15~" };
    if (eql(base, "f6")) return .{ .kind = .tilde, .code = 17, .unmodified = "\x1b[17~" };
    if (eql(base, "f7")) return .{ .kind = .tilde, .code = 18, .unmodified = "\x1b[18~" };
    if (eql(base, "f8")) return .{ .kind = .tilde, .code = 19, .unmodified = "\x1b[19~" };
    if (eql(base, "f9")) return .{ .kind = .tilde, .code = 20, .unmodified = "\x1b[20~" };
    if (eql(base, "f10")) return .{ .kind = .tilde, .code = 21, .unmodified = "\x1b[21~" };
    if (eql(base, "f11")) return .{ .kind = .tilde, .code = 23, .unmodified = "\x1b[23~" };
    if (eql(base, "f12")) return .{ .kind = .tilde, .code = 24, .unmodified = "\x1b[24~" };

    return null;
}

/// Encode a special key (arrow, F-key, etc.) with optional modifiers.
fn encodeSpecialKey(info: SpecialKeyInfo, mods: Mods, out: []u8) ?usize {
    if (!mods.hasMods()) {
        return copyStatic(info.unmodified, out);
    }

    const mod = mods.toCSI();
    var buf: [16]u8 = undefined;

    switch (info.kind) {
        // ESC[1;{mod}{final}
        .csi_final, .ss3 => {
            const n = std.fmt.bufPrint(&buf, "\x1b[1;{d}{c}", .{ mod, info.code }) catch return null;
            return copyStatic(n, out);
        },
        // ESC[{N};{mod}~
        .tilde => {
            const n = std.fmt.bufPrint(&buf, "\x1b[{d};{d}~", .{ info.code, mod }) catch return null;
            return copyStatic(n, out);
        },
    }
}

/// Simple keys that don't take modifiers (unmodified only).
fn simpleKeySeq(base: []const u8) ?[]const u8 {
    if (eql(base, "enter") or eql(base, "return") or eql(base, "cr")) return "\r";
    if (eql(base, "tab")) return "\t";
    if (eql(base, "space")) return " ";
    if (eql(base, "backspace") or eql(base, "bs")) return "\x7f";
    if (eql(base, "escape") or eql(base, "esc")) return "\x1b";
    return null;
}

/// Format CSI u: ESC[{codepoint};{modifier}u
fn fmtCSIu(codepoint: u8, modifier: u8, out: []u8) ?usize {
    var buf: [16]u8 = undefined;
    const n = std.fmt.bufPrint(&buf, "\x1b[{d};{d}u", .{ codepoint, modifier }) catch return null;
    return copyStatic(n, out);
}

fn copyStatic(src: []const u8, dst: []u8) ?usize {
    if (dst.len < src.len) return null;
    @memcpy(dst[0..src.len], src);
    return src.len;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

// ---------------------------------------------------------------------------
// Token iterator — splits input into named-key and text chunks
// ---------------------------------------------------------------------------

pub const Token = struct {
    /// The processed bytes for this token (written into caller's buffer).
    len: usize,
    /// Whether this token came from a {NamedKey} (vs plain text/escapes).
    is_named_key: bool,
};

/// Yields one token at a time from the input. A token is either:
/// - A single {NamedKey} (is_named_key = true)
/// - A run of plain text / C-style escapes up to the next {NamedKey} (is_named_key = false)
///
/// Usage:
///   var iter = KeyTokenIter{ .input = raw_text };
///   while (iter.next(&buf)) |tok| { ... }
pub const KeyTokenIter = struct {
    input: []const u8,
    pos: usize = 0,

    /// Get the next token, writing processed bytes into `out`.
    /// Returns null when input is exhausted.
    pub fn next(self: *KeyTokenIter, out: []u8) ?Token {
        if (self.pos >= self.input.len) return null;

        // If we're at a valid {NamedKey}, emit it as a single token
        if (self.input[self.pos] == '{') {
            if (resolveNamedKey(self.input[self.pos..], out)) |result| {
                self.pos += result.advance;
                return .{ .len = result.written, .is_named_key = true };
            }
        }

        // Consume plain text + C-style escapes until next valid {NamedKey} or end
        var o: usize = 0;
        while (self.pos < self.input.len and o < out.len) {
            // Stop before a valid named key (it becomes the next token)
            if (self.input[self.pos] == '{' and self.pos > 0) {
                // Peek: is this a valid named key?
                if (resolveNamedKey(self.input[self.pos..], out[o..])) |_| {
                    break; // don't consume it — next call will
                }
            } else if (self.input[self.pos] == '{' and o > 0) {
                if (resolveNamedKey(self.input[self.pos..], out[o..])) |_| {
                    break;
                }
            }

            // Process one character (possibly an escape sequence)
            if (self.input[self.pos] == '{') {
                // Invalid named key — emit literal '{'
                out[o] = '{';
                o += 1;
                self.pos += 1;
            } else if (self.input[self.pos] == '\\' and self.pos + 1 < self.input.len) {
                const consumed = unescapeOne(self.input[self.pos..], out[o..]);
                o += consumed.written;
                self.pos += consumed.advance;
            } else {
                out[o] = self.input[self.pos];
                o += 1;
                self.pos += 1;
            }
        }

        if (o == 0) return null;
        return .{ .len = o, .is_named_key = false };
    }
};

const UnescapeOne = struct { written: usize, advance: usize };

/// Process a single C-style escape at `input[0]` (which must be '\\'). Writes to `out`.
fn unescapeOne(input: []const u8, out: []u8) UnescapeOne {
    if (out.len == 0) return .{ .written = 0, .advance = 1 };
    if (input.len < 2 or input[0] != '\\') {
        out[0] = input[0];
        return .{ .written = 1, .advance = 1 };
    }
    switch (input[1]) {
        'n' => { out[0] = '\n'; return .{ .written = 1, .advance = 2 }; },
        't' => { out[0] = '\t'; return .{ .written = 1, .advance = 2 }; },
        'r' => { out[0] = '\r'; return .{ .written = 1, .advance = 2 }; },
        '\\' => { out[0] = '\\'; return .{ .written = 1, .advance = 2 }; },
        '\'' => { out[0] = '\''; return .{ .written = 1, .advance = 2 }; },
        '"' => { out[0] = '"'; return .{ .written = 1, .advance = 2 }; },
        '0' => { out[0] = 0; return .{ .written = 1, .advance = 2 }; },
        'a' => { out[0] = 0x07; return .{ .written = 1, .advance = 2 }; },
        'b' => { out[0] = 0x08; return .{ .written = 1, .advance = 2 }; },
        'e' => { out[0] = 0x1b; return .{ .written = 1, .advance = 2 }; },
        'x' => {
            if (input.len >= 4) {
                if (std.fmt.parseInt(u8, input[2..4], 16)) |byte| {
                    out[0] = byte;
                    return .{ .written = 1, .advance = 4 };
                } else |_| {}
            }
            out[0] = '\\';
            if (out.len > 1) { out[1] = 'x'; return .{ .written = 2, .advance = 2 }; }
            return .{ .written = 1, .advance = 1 };
        },
        else => {
            out[0] = '\\';
            if (out.len > 1) { out[1] = input[1]; return .{ .written = 2, .advance = 2 }; }
            return .{ .written = 1, .advance = 1 };
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "basic escapes" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("hello\\n", &buf);
    try std.testing.expectEqualStrings("hello\n", result);
}

test "named key Enter" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("ls{Enter}", &buf);
    try std.testing.expectEqualStrings("ls\r", result);
}

test "named key arrows" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("{Up}{Down}{Left}{Right}", &buf);
    try std.testing.expectEqualStrings("\x1b[A\x1b[B\x1b[D\x1b[C", result);
}

test "named key Ctrl-c" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("{Ctrl-c}", &buf);
    try std.testing.expectEqualStrings("\x03", result);
}

test "named key case insensitive" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("{ENTER}", &buf);
    try std.testing.expectEqualStrings("\r", result);
}

test "mixed named keys and text" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("hello{Tab}world{Enter}", &buf);
    try std.testing.expectEqualStrings("hello\tworld\r", result);
}

test "invalid brace passthrough" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("{notakey}", &buf);
    try std.testing.expectEqualStrings("{notakey}", result);
}

test "literal brace without close" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("hello{world", &buf);
    try std.testing.expectEqualStrings("hello{world", result);
}

test "function keys" {
    var buf: [256]u8 = undefined;
    const f1 = unescapeKeys("{F1}", &buf);
    try std.testing.expectEqualStrings("\x1bOP", f1);
    const f12 = unescapeKeys("{F12}", &buf);
    try std.testing.expectEqualStrings("\x1b[24~", f12);
}

test "hex escape" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("\\x03", &buf);
    try std.testing.expectEqualStrings("\x03", result);
}

// Modifier combo tests

test "Ctrl-Up arrow" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("{Ctrl-Up}", &buf);
    try std.testing.expectEqualStrings("\x1b[1;5A", result);
}

test "Ctrl-Shift-Up arrow" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("{Ctrl-Shift-Up}", &buf);
    try std.testing.expectEqualStrings("\x1b[1;6A", result);
}

test "Alt-Up arrow" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("{Alt-Up}", &buf);
    try std.testing.expectEqualStrings("\x1b[1;3A", result);
}

test "Shift-Tab backtab" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("{Shift-Tab}", &buf);
    try std.testing.expectEqualStrings("\x1b[Z", result);
}

test "Alt-a meta prefix" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("{Alt-a}", &buf);
    try std.testing.expectEqualStrings("\x1ba", result);
}

test "Alt-Ctrl-a" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("{Alt-Ctrl-a}", &buf);
    try std.testing.expectEqualStrings("\x1b\x01", result);
}

test "Ctrl-Right arrow" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("{Ctrl-Right}", &buf);
    try std.testing.expectEqualStrings("\x1b[1;5C", result);
}

test "Shift-F5" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("{Shift-F5}", &buf);
    try std.testing.expectEqualStrings("\x1b[15;2~", result);
}

test "Ctrl-Delete" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("{Ctrl-Delete}", &buf);
    try std.testing.expectEqualStrings("\x1b[3;5~", result);
}

test "Ctrl-Shift-p CSI u" {
    var buf: [256]u8 = undefined;
    const result = unescapeKeys("{Ctrl-Shift-p}", &buf);
    // Ctrl+Shift on a letter → CSI u: ESC[112;6u (codepoint 'p'=112, mod=6)
    try std.testing.expectEqualStrings("\x1b[112;6u", result);
}

// Token iterator tests

test "token iter: plain text only" {
    var iter = KeyTokenIter{ .input = "hello" };
    var buf: [256]u8 = undefined;
    const t1 = iter.next(&buf).?;
    try std.testing.expectEqualStrings("hello", buf[0..t1.len]);
    try std.testing.expect(!t1.is_named_key);
    try std.testing.expect(iter.next(&buf) == null);
}

test "token iter: named keys only" {
    var iter = KeyTokenIter{ .input = "{Down}{Enter}" };
    var buf: [256]u8 = undefined;
    const t1 = iter.next(&buf).?;
    try std.testing.expectEqualStrings("\x1b[B", buf[0..t1.len]);
    try std.testing.expect(t1.is_named_key);
    const t2 = iter.next(&buf).?;
    try std.testing.expectEqualStrings("\r", buf[0..t2.len]);
    try std.testing.expect(t2.is_named_key);
    try std.testing.expect(iter.next(&buf) == null);
}

test "token iter: mixed text and keys" {
    var iter = KeyTokenIter{ .input = "ls -la{Enter}" };
    var buf: [256]u8 = undefined;
    const t1 = iter.next(&buf).?;
    try std.testing.expectEqualStrings("ls -la", buf[0..t1.len]);
    try std.testing.expect(!t1.is_named_key);
    const t2 = iter.next(&buf).?;
    try std.testing.expectEqualStrings("\r", buf[0..t2.len]);
    try std.testing.expect(t2.is_named_key);
    try std.testing.expect(iter.next(&buf) == null);
}

test "token iter: text between keys" {
    var iter = KeyTokenIter{ .input = "{Escape}:wq{Enter}" };
    var buf: [256]u8 = undefined;
    const t1 = iter.next(&buf).?;
    try std.testing.expectEqualStrings("\x1b", buf[0..t1.len]);
    try std.testing.expect(t1.is_named_key);
    const t2 = iter.next(&buf).?;
    try std.testing.expectEqualStrings(":wq", buf[0..t2.len]);
    try std.testing.expect(!t2.is_named_key);
    const t3 = iter.next(&buf).?;
    try std.testing.expectEqualStrings("\r", buf[0..t3.len]);
    try std.testing.expect(t3.is_named_key);
    try std.testing.expect(iter.next(&buf) == null);
}
