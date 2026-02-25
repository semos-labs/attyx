const std = @import("std");
const TerminalState = @import("state.zig").TerminalState;

pub fn appendResponse(self: *TerminalState, data: []const u8) void {
    const avail = self.response_buf.len - self.response_len;
    const n = @min(data.len, avail);
    @memcpy(self.response_buf[self.response_len .. self.response_len + n], data[0..n]);
    self.response_len += n;
}

pub fn respondDeviceStatus(self: *TerminalState) void {
    self.appendResponse("\x1b[0n");
}

pub fn respondCursorPosition(self: *TerminalState) void {
    var buf: [32]u8 = undefined;
    const row = self.cursor.row + 1;
    const col = self.cursor.col + 1;
    const len = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ row, col }) catch return;
    self.appendResponse(len);
}

pub fn respondDeviceAttributes(self: *TerminalState) void {
    self.appendResponse("\x1b[?62c");
}

pub fn respondSecondaryDeviceAttributes(self: *TerminalState) void {
    // VT220-like: type 0, version 10, ROM version 1
    self.appendResponse("\x1b[>0;10;1c");
}

pub fn respondDecRequestMode(self: *TerminalState, mode: u16) void {
    // DECRQM response: ESC[?Ps;Pm$y  where Pm = 0 not recognized, 1 set, 2 reset
    const pm: u8 = switch (mode) {
        2026 => if (self.synchronized_output) 1 else 2,
        else => 0,
    };
    var buf: [32]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "\x1b[?{d};{d}$y", .{ mode, pm }) catch return;
    self.appendResponse(resp);
}
