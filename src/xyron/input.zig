// input.zig — Line buffer for xyron command input.
//
// When xyron is idle (no command running), keystrokes are buffered here.
// On Enter, the buffer is sent as a run_command request.
// While a command runs, input goes directly via send_input.

const std = @import("std");

pub const max_input = 4096;

pub const InputBuffer = struct {
    buf: [max_input]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0, // byte position of cursor

    /// Insert bytes at cursor position.
    pub fn insert(self: *InputBuffer, bytes: []const u8) void {
        if (self.len + bytes.len > max_input) return;
        // Shift right
        if (self.cursor < self.len) {
            std.mem.copyBackwards(
                u8,
                self.buf[self.cursor + bytes.len .. self.len + bytes.len],
                self.buf[self.cursor..self.len],
            );
        }
        @memcpy(self.buf[self.cursor..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.cursor += bytes.len;
    }

    /// Delete one byte before cursor (backspace).
    pub fn backspace(self: *InputBuffer) void {
        if (self.cursor == 0) return;
        if (self.cursor < self.len) {
            std.mem.copyForwards(
                u8,
                self.buf[self.cursor - 1 .. self.len - 1],
                self.buf[self.cursor..self.len],
            );
        }
        self.cursor -= 1;
        self.len -= 1;
    }

    /// Delete one byte at cursor (delete key).
    pub fn delete(self: *InputBuffer) void {
        if (self.cursor >= self.len) return;
        if (self.cursor + 1 < self.len) {
            std.mem.copyForwards(
                u8,
                self.buf[self.cursor .. self.len - 1],
                self.buf[self.cursor + 1 .. self.len],
            );
        }
        self.len -= 1;
    }

    /// Move cursor left.
    pub fn cursorLeft(self: *InputBuffer) void {
        if (self.cursor > 0) self.cursor -= 1;
    }

    /// Move cursor right.
    pub fn cursorRight(self: *InputBuffer) void {
        if (self.cursor < self.len) self.cursor += 1;
    }

    /// Move cursor to start.
    pub fn cursorHome(self: *InputBuffer) void {
        self.cursor = 0;
    }

    /// Move cursor to end.
    pub fn cursorEnd(self: *InputBuffer) void {
        self.cursor = self.len;
    }

    /// Kill from cursor to end of line (Ctrl+K).
    pub fn killToEnd(self: *InputBuffer) void {
        self.len = self.cursor;
    }

    /// Kill from start to cursor (Ctrl+U).
    pub fn killToStart(self: *InputBuffer) void {
        if (self.cursor == 0) return;
        std.mem.copyForwards(u8, self.buf[0 .. self.len - self.cursor], self.buf[self.cursor..self.len]);
        self.len -= self.cursor;
        self.cursor = 0;
    }

    /// Get the current content.
    pub fn text(self: *const InputBuffer) []const u8 {
        return self.buf[0..self.len];
    }

    /// Clear the buffer.
    pub fn clear(self: *InputBuffer) void {
        self.len = 0;
        self.cursor = 0;
    }
};
