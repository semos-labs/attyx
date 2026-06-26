//! Keypress decoder: stdin bytes → Key events. A tiny escape-sequence state
//! machine that survives partial sequences split across reads (the ESC state
//! persists between feed() calls).
const std = @import("std");

pub const Key = enum {
    up,
    down,
    top, // g / Home
    bottom, // G / End
    enter,
    quit, // q / Ctrl-C
    help, // ?
    refresh, // r
    none,
};

pub const Decoder = struct {
    esc: u8 = 0, // 0=normal, 1=saw ESC, 2=saw ESC[ / ESC O

    fn base(self: *Decoder, byte: u8) ?Key {
        return switch (byte) {
            0x1b => blk: {
                self.esc = 1;
                break :blk null;
            },
            0x03, 'q' => .quit,
            '?' => .help,
            'r' => .refresh,
            '\r', '\n' => .enter,
            'j' => .down,
            'k' => .up,
            'g' => .top,
            'G' => .bottom,
            else => null,
        };
    }

    /// Feed one byte; returns a Key when a complete event is recognized.
    pub fn feed(self: *Decoder, byte: u8) ?Key {
        switch (self.esc) {
            0 => return self.base(byte),
            1 => {
                if (byte == '[' or byte == 'O') {
                    self.esc = 2;
                    return null;
                }
                // Lone ESC (we don't bind it) — drop it and process this byte.
                self.esc = 0;
                return self.base(byte);
            },
            else => {
                self.esc = 0;
                return switch (byte) {
                    'A' => .up,
                    'B' => .down,
                    'H' => .top, // Home
                    'F' => .bottom, // End
                    else => null,
                };
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn collect(bytes: []const u8, out: []Key) usize {
    var d = Decoder{};
    var n: usize = 0;
    for (bytes) |b| {
        if (d.feed(b)) |k| {
            out[n] = k;
            n += 1;
        }
    }
    return n;
}

test "decodes letters and control keys" {
    var out: [16]Key = undefined;
    const n = collect("jkqG g\r\x03?r", &out);
    const want = [_]Key{ .down, .up, .quit, .bottom, .top, .enter, .quit, .help, .refresh };
    try testing.expectEqual(want.len, n);
    for (want, 0..) |k, i| try testing.expectEqual(k, out[i]);
}

test "decodes CSI arrows including split across reads" {
    var out: [8]Key = undefined;
    var n = collect("\x1b[A\x1b[B\x1bOH\x1b[F", &out);
    const want = [_]Key{ .up, .down, .top, .bottom };
    try testing.expectEqual(want.len, n);
    for (want, 0..) |k, i| try testing.expectEqual(k, out[i]);

    // ESC and the rest arrive in separate feeds — state must persist.
    var d = Decoder{};
    try testing.expectEqual(@as(?Key, null), d.feed(0x1b));
    try testing.expectEqual(@as(?Key, null), d.feed('['));
    try testing.expectEqual(@as(?Key, Key.up), d.feed('A'));
    n = 0;
}
