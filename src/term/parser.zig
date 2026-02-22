const std = @import("std");
const actions_mod = @import("actions.zig");
const csi = @import("csi.zig");

pub const Action = actions_mod.Action;
pub const ControlCode = actions_mod.ControlCode;

const State = enum {
    ground,
    escape,
    csi_state,
    osc,
    osc_escape,
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
            .csi_state => self.onCsi(byte),
            .osc => self.onOsc(byte),
            .osc_escape => self.onOscEscape(byte),
        };
    }

    // -- State handlers ----------------------------------------------------

    fn onGround(self: *Parser, byte: u8) ?Action {
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
            else => return .nop,
        }
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

        const params = csi.parseCsiParams(buf);
        return switch (final) {
            'H', 'f' => csi.makeCursorAbs(params),
            'A' => csi.makeCursorRel(params, .up),
            'B' => csi.makeCursorRel(params, .down),
            'C' => csi.makeCursorRel(params, .right),
            'D' => csi.makeCursorRel(params, .left),
            'J' => csi.makeEraseDisplay(params),
            'K' => csi.makeEraseLine(params),
            'm' => csi.makeSgr(params),
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
