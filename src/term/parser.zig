const std = @import("std");
const actions_mod = @import("actions.zig");
const csi = @import("csi.zig");

pub const Action = actions_mod.Action;
pub const ControlCode = actions_mod.ControlCode;

pub const State = enum {
    ground,
    escape,
    escape_charset,
    csi_state,
    osc,
    osc_escape,
    str_ignore,
    str_ignore_escape,
};

/// Incremental VT parser.
///
/// Consumes one byte at a time via `next()`, returning an optional Action.
/// Maintains internal state across calls so partial escape sequences that
/// span multiple `feed()` chunks are handled correctly.
///
/// Zero allocations — all state lives in fixed-size fields.
pub const Parser = struct {
    pub const osc_buf_size = 4096;

    state: State = .ground,

    /// UTF-8 multi-byte accumulator (no allocations).
    utf8_buf: [4]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_needed: u3 = 0,

    /// Buffer for CSI parameter/intermediate bytes (retained for debug tracing).
    csi_buf: [64]u8 = undefined,
    csi_len: usize = 0,
    /// The final byte of the last completed CSI sequence (for tracing).
    csi_final: u8 = 0,
    /// The byte that followed ESC in the last non-CSI escape (for tracing).
    last_esc_byte: u8 = 0,

    /// Buffer for OSC payload bytes (e.g. "8;;https://example.com").
    osc_buf: [osc_buf_size]u8 = undefined,
    osc_len: u16 = 0,
    osc_overflow: bool = false,

    /// Process a single byte. Returns an Action if one is ready,
    /// or null if the byte was consumed as part of an incomplete sequence.
    ///
    /// NOTE: Actions with borrowed slices (hyperlink_start, set_title) point
    /// into the parser's internal osc_buf and are only valid until the next
    /// call to next(). The Engine.feed() loop consumes them immediately.
    pub fn next(self: *Parser, byte: u8) ?Action {
        return switch (self.state) {
            .ground => self.onGround(byte),
            .escape => self.onEscape(byte),
            .escape_charset => self.onEscapeCharset(byte),
            .csi_state => self.onCsi(byte),
            .osc => self.onOsc(byte),
            .osc_escape => self.onOscEscape(byte),
            .str_ignore => self.onStrIgnore(byte),
            .str_ignore_escape => self.onStrIgnoreEscape(byte),
        };
    }

    // -- State handlers ----------------------------------------------------

    fn onGround(self: *Parser, byte: u8) ?Action {
        // If we're accumulating a UTF-8 multi-byte sequence, handle continuation.
        if (self.utf8_needed > 0) {
            return self.onUtf8Cont(byte);
        }

        switch (byte) {
            0x1B => {
                self.state = .escape;
                return null;
            },
            0x20...0x7E => return .{ .print = byte },
            '\n' => return .{ .control = .lf },
            '\r' => return .{ .control = .cr },
            0x08 => return .{ .control = .bs },
            '\t' => return .{ .control = .tab },
            // C1 string-type controls (8-bit forms): DCS, SOS, PM, APC.
            // Transition to str_ignore so the payload is silently consumed
            // until ST.  Without this, the payload bytes following the C1
            // introducer would be parsed as ground-state printable text.
            0x90, 0x98, 0x9E, 0x9F => {
                self.state = .str_ignore;
                return null;
            },
            0xC2...0xDF => return self.utf8Start(byte, 2),
            0xE0...0xEF => return self.utf8Start(byte, 3),
            0xF0...0xF4 => return self.utf8Start(byte, 4),
            else => return .nop,
        }
    }

    fn utf8Start(self: *Parser, byte: u8, total: u3) ?Action {
        self.utf8_buf[0] = byte;
        self.utf8_len = 1;
        self.utf8_needed = total;
        return null;
    }

    fn onUtf8Cont(self: *Parser, byte: u8) ?Action {
        if (byte & 0xC0 != 0x80) {
            // Not a continuation byte — discard partial sequence and re-process.
            self.utf8_needed = 0;
            self.utf8_len = 0;
            return self.onGround(byte);
        }

        self.utf8_buf[self.utf8_len] = byte;
        self.utf8_len += 1;

        if (self.utf8_len < self.utf8_needed) return null;

        // Sequence complete — decode codepoint.
        const len = self.utf8_needed;
        self.utf8_needed = 0;
        self.utf8_len = 0;

        const cp = std.unicode.utf8Decode(self.utf8_buf[0..len]) catch return .nop;
        return .{ .print = cp };
    }

    fn onEscape(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            '[' => {
                self.state = .csi_state;
                self.csi_len = 0;
                return null;
            },
            'D' => {
                self.state = .ground;
                return .index;
            },
            'M' => {
                self.state = .ground;
                return .reverse_index;
            },
            '7' => {
                self.state = .ground;
                return .save_cursor;
            },
            '8' => {
                self.state = .ground;
                return .restore_cursor;
            },
            ']' => {
                self.state = .osc;
                self.osc_len = 0;
                self.osc_overflow = false;
                return null;
            },
            // Charset designation: ESC ( X, ESC ) X, ESC * X, ESC + X, ESC - X, ESC . X
            // Also ESC # X (DEC line attributes). Consume the next byte silently.
            '(', ')', '*', '+', '-', '.', '#' => {
                self.state = .escape_charset;
                return null;
            },
            // DCS (ESC P), APC (ESC _), PM (ESC ^) — consume payload until ST.
            'P', '_', '^' => {
                self.state = .str_ignore;
                return null;
            },
            // DECKPAM / DECKPNM — application/normal keypad mode, ignored for now.
            '=', '>' => {
                self.state = .ground;
                return .nop;
            },
            0x1B => {
                return .nop;
            },
            else => {
                self.last_esc_byte = byte;
                self.state = .ground;
                return .nop;
            },
        }
    }

    fn onEscapeCharset(self: *Parser, byte: u8) ?Action {
        _ = byte;
        self.state = .ground;
        return .nop;
    }

    // -- DCS / APC / PM string ignore ----------------------------------------

    fn onStrIgnore(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            0x1B => {
                self.state = .str_ignore_escape;
                return null;
            },
            // C1 ST (8-bit String Terminator) ends the sequence.
            // BEL (0x07) is intentionally NOT a terminator here —
            // DCS/APC payloads (e.g. tmux passthrough) may embed
            // inner OSC sequences that use BEL as *their* terminator.
            0x9C => {
                self.state = .ground;
                return .nop;
            },
            else => return null,
        }
    }

    fn onStrIgnoreEscape(self: *Parser, byte: u8) ?Action {
        if (byte == '\\') {
            self.state = .ground;
            return .nop;
        }
        // Not ST — stay in the ignore state.  DCS/APC payloads may
        // contain embedded ESC bytes (e.g. tmux passthrough doubles
        // inner ESCs as ESC ESC).  Breaking out here would cause the
        // inner content to be parsed as real escape sequences.
        self.state = .str_ignore;
        return null;
    }

    fn onCsi(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            0x40...0x7E => {
                self.csi_final = byte;
                self.state = .ground;
                return self.dispatchCsi(byte);
            },
            0x1B => {
                self.state = .escape;
                return .nop;
            },
            else => {
                if (self.csi_len < self.csi_buf.len) {
                    self.csi_buf[self.csi_len] = byte;
                    self.csi_len += 1;
                }
                return null;
            },
        }
    }

    // -- CSI dispatch ------------------------------------------------------

    fn dispatchCsi(self: *Parser, final: u8) Action {
        const buf = self.csi_buf[0..self.csi_len];

        if (buf.len > 0 and buf[0] == '?') {
            return csi.dispatchDecPrivate(final, buf[1..]);
        }
        if (buf.len > 0 and buf[0] == '>') {
            return csi.dispatchSecondaryDA(final, buf[1..]);
        }

        // CSI Ps SP q — DECSCUSR (set cursor shape)
        if (final == 'q' and buf.len > 0 and buf[buf.len - 1] == ' ') {
            return csi.makeCursorShape(csi.parseCsiParams(buf[0 .. buf.len - 1]));
        }

        const params = csi.parseCsiParams(buf);
        return switch (final) {
            'H', 'f' => csi.makeCursorAbs(params),
            'A' => csi.makeCursorRel(params, .up),
            'B' => csi.makeCursorRel(params, .down),
            'C' => csi.makeCursorRel(params, .right),
            'D' => csi.makeCursorRel(params, .left),
            'E' => csi.makeCursorNextLine(params),
            'F' => csi.makeCursorPrevLine(params),
            'G' => csi.makeCursorColAbs(params),
            'J' => csi.makeEraseDisplay(params),
            'K' => csi.makeEraseLine(params),
            'L' => csi.makeCountAction(params, .insert_lines),
            'M' => csi.makeCountAction(params, .delete_lines),
            'P' => csi.makeCountAction(params, .delete_chars),
            'S' => csi.makeCountAction(params, .scroll_up),
            'T' => csi.makeCountAction(params, .scroll_down),
            'X' => csi.makeCountAction(params, .erase_chars),
            '@' => csi.makeCountAction(params, .insert_chars),
            'c' => csi.makeDeviceAttributes(params),
            'd' => csi.makeCursorRowAbs(params),
            'm' => csi.makeSgr(params),
            'n' => csi.makeDeviceStatusReport(params),
            'r' => csi.makeSetScrollRegion(params),
            's' => .save_cursor,
            'u' => .restore_cursor,
            else => .nop,
        };
    }

    // -- OSC handlers ------------------------------------------------------

    fn onOsc(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            0x07, 0x9C => {
                self.state = .ground;
                return self.dispatchOsc();
            },
            0x1B => {
                self.state = .osc_escape;
                return null;
            },
            else => {
                if (!self.osc_overflow) {
                    if (self.osc_len < self.osc_buf.len) {
                        self.osc_buf[self.osc_len] = byte;
                        self.osc_len += 1;
                    } else {
                        self.osc_overflow = true;
                    }
                }
                return null;
            },
        }
    }

    fn onOscEscape(self: *Parser, byte: u8) ?Action {
        if (byte == '\\') {
            self.state = .ground;
            return self.dispatchOsc();
        }
        self.state = .escape;
        return self.onEscape(byte);
    }

    fn dispatchOsc(self: *Parser) Action {
        if (self.osc_overflow) return .nop;
        const payload = self.osc_buf[0..self.osc_len];
        if (payload.len == 0) return .nop;

        var num_end: usize = 0;
        while (num_end < payload.len and
            payload[num_end] >= '0' and payload[num_end] <= '9') : (num_end += 1)
        {}
        if (num_end == 0) return .nop;

        const num = std.fmt.parseInt(u16, payload[0..num_end], 10) catch return .nop;

        const rest: []const u8 = if (num_end < payload.len and payload[num_end] == ';')
            payload[num_end + 1 ..]
        else
            "";

        return switch (num) {
            0, 2 => .{ .set_title = rest },
            8 => csi.makeOscHyperlink(rest),
            else => .nop,
        };
    }
};
