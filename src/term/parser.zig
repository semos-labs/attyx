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
    apc,
    apc_escape,
    dcs,
    dcs_escape,
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
    pub const apc_buf_size = 65536;

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

    /// Buffer for APC graphics payload (after the 'G' prefix).
    apc_buf: [apc_buf_size]u8 = undefined,
    apc_len: u32 = 0,
    apc_overflow: bool = false,

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
            .apc => self.onApc(byte),
            .apc_escape => self.onApcEscape(byte),
            .dcs => self.onDcs(byte),
            .dcs_escape => self.onDcsEscape(byte),
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
            // C1 DCS (8-bit form) — may be tmux passthrough.
            0x90 => {
                self.state = .dcs;
                self.apc_len = 0;
                self.apc_overflow = false;
                return null;
            },
            // C1 string-type controls (8-bit forms): SOS, PM.
            0x98, 0x9E => {
                self.state = .str_ignore;
                return null;
            },
            // C1 APC (8-bit form) — may be a Kitty graphics command.
            0x9F => {
                self.state = .apc;
                self.apc_len = 0;
                self.apc_overflow = false;
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
            // PM (ESC ^) — consume payload until ST.
            '^' => {
                self.state = .str_ignore;
                return null;
            },
            // DCS (ESC P) — may be tmux passthrough.
            'P' => {
                self.state = .dcs;
                self.apc_len = 0;
                self.apc_overflow = false;
                return null;
            },
            // APC (ESC _) — may be a Kitty graphics command (ESC _ G ...).
            '_' => {
                self.state = .apc;
                self.apc_len = 0;
                self.apc_overflow = false;
                return null;
            },
            // DECKPAM — application keypad mode.
            '=' => {
                self.state = .ground;
                return .set_keypad_app_mode;
            },
            // DECKPNM — normal (numeric) keypad mode.
            '>' => {
                self.state = .ground;
                return .reset_keypad_app_mode;
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

    // -- APC handler (Kitty graphics protocol) --------------------------------

    fn onApc(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            0x1B => {
                self.state = .apc_escape;
                return null;
            },
            0x9C => return self.dispatchApc(),
            else => {
                // First byte must be 'G' for a graphics command.
                if (self.apc_len == 0 and byte != 'G') {
                    self.state = .str_ignore;
                    return null;
                }
                // Accumulate into buffer (including the 'G' prefix;
                // dispatchApc strips it before emitting the action).
                if (!self.apc_overflow) {
                    if (self.apc_len < self.apc_buf.len) {
                        self.apc_buf[self.apc_len] = byte;
                        self.apc_len += 1;
                    } else {
                        self.apc_overflow = true;
                    }
                }
                return null;
            },
        }
    }

    fn onApcEscape(self: *Parser, byte: u8) ?Action {
        if (byte == '\\') {
            return self.dispatchApc();
        }
        // Not ST — continue accumulating in APC state.
        self.state = .apc;
        // The ESC byte itself is part of the payload in some protocols,
        // but for Kitty graphics it shouldn't appear. Just drop it.
        return null;
    }

    fn dispatchApc(self: *Parser) Action {
        self.state = .ground;
        if (self.apc_overflow) return .nop;
        if (self.apc_len < 1) return .nop;
        // First byte must be 'G' (verified on entry).
        if (self.apc_buf[0] != 'G') return .nop;
        // Payload after 'G' is the graphics command data.
        const payload = self.apc_buf[1..self.apc_len];
        return .{ .graphics_command = payload };
    }

    // -- DCS handler (tmux passthrough) ---------------------------------------

    fn onDcs(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            0x1B => {
                self.state = .dcs_escape;
                return null;
            },
            0x9C => return self.dispatchDcs(),
            else => {
                if (!self.apc_overflow) {
                    if (self.apc_len < self.apc_buf.len) {
                        self.apc_buf[self.apc_len] = byte;
                        self.apc_len += 1;
                    } else {
                        self.apc_overflow = true;
                    }
                }
                return null;
            },
        }
    }

    fn onDcsEscape(self: *Parser, byte: u8) ?Action {
        if (byte == '\\') {
            return self.dispatchDcs();
        }
        // ESC ESC → doubled ESC in tmux passthrough. Accumulate one ESC.
        if (byte == 0x1B) {
            if (!self.apc_overflow) {
                if (self.apc_len < self.apc_buf.len) {
                    self.apc_buf[self.apc_len] = 0x1B;
                    self.apc_len += 1;
                } else {
                    self.apc_overflow = true;
                }
            }
            self.state = .dcs;
            return null;
        }
        // Not ST and not doubled ESC — ignore malformed sequence.
        self.state = .dcs;
        return null;
    }

    fn dispatchDcs(self: *Parser) Action {
        self.state = .ground;
        if (self.apc_overflow) return .nop;
        const payload = self.apc_buf[0..self.apc_len];
        const prefix = "tmux;";
        if (payload.len >= prefix.len and
            std.mem.eql(u8, payload[0..prefix.len], prefix))
        {
            return .{ .dcs_passthrough = payload[prefix.len..] };
        }
        return .nop;
    }

    // -- DCS / PM string ignore ----------------------------------------------

    fn onStrIgnore(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            0x1B => {
                self.state = .str_ignore_escape;
                return null;
            },
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
            if (final == 'u') return csi.dispatchKittyQuery(buf[1..]);
            return csi.dispatchDecPrivate(final, buf[1..]);
        }
        if (buf.len > 0 and buf[0] == '>') {
            if (final == 'u') return csi.dispatchKittyPush(buf[1..]);
            return csi.dispatchSecondaryDA(final, buf[1..]);
        }
        if (buf.len > 0 and buf[0] == '<') {
            if (final == 'u') return csi.dispatchKittyPop(buf[1..]);
            return .nop;
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
            0x07 => {
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

    fn dispatchOsc7337(rest: []const u8) Action {
        // Format: "write-main;<payload>"
        const write_prefix = "write-main;";
        if (rest.len >= write_prefix.len and std.mem.eql(u8, rest[0..write_prefix.len], write_prefix)) {
            return .{ .inject_into_main = rest[write_prefix.len..] };
        }
        // Format: "set-path;<PATH>"
        const path_prefix = "set-path;";
        if (rest.len >= path_prefix.len and std.mem.eql(u8, rest[0..path_prefix.len], path_prefix)) {
            return .{ .set_shell_path = rest[path_prefix.len..] };
        }
        return .nop;
    }

    /// Parse OSC 4;N;? — palette color query.
    fn parseOscPaletteQuery(rest: []const u8) Action {
        // Format: "N;?" where N is palette index 0–255
        const semi = std.mem.indexOfScalar(u8, rest, ';') orelse return .nop;
        if (!std.mem.eql(u8, rest[semi + 1 ..], "?")) return .nop;
        const idx = std.fmt.parseInt(u8, rest[0..semi], 10) catch return .nop;
        return .{ .query_palette_color = idx };
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
            0, 1, 2 => .{ .set_title = rest },
            4 => parseOscPaletteQuery(rest),
            7 => .{ .set_cwd = rest },
            8 => csi.makeOscHyperlink(rest),
            10 => if (std.mem.eql(u8, rest, "?")) .{ .query_color = .foreground } else .nop,
            11 => if (std.mem.eql(u8, rest, "?")) .{ .query_color = .background } else .nop,
            12 => if (std.mem.eql(u8, rest, "?")) .{ .query_color = .cursor } else .nop,
            7337 => dispatchOsc7337(rest),
            else => .nop,
        };
    }
};
