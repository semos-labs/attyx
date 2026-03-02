const std = @import("std");

/// Fixed-size byte ring buffer for PTY output replay.
/// Stores the most recent bytes, overwriting oldest data when full.
pub const RingBuffer = struct {
    buf: []u8,
    write_pos: usize = 0,
    len: usize = 0,
    allocator: std.mem.Allocator,

    pub const default_capacity = 1024 * 1024; // 1 MB

    pub fn init(allocator: std.mem.Allocator, cap: usize) !RingBuffer {
        const buf = try allocator.alloc(u8, cap);
        return .{ .buf = buf, .allocator = allocator };
    }

    pub fn deinit(self: *RingBuffer) void {
        self.allocator.free(self.buf);
        self.* = undefined;
    }

    pub fn capacity(self: *const RingBuffer) usize {
        return self.buf.len;
    }

    /// Append bytes, overwriting oldest data when full.
    pub fn write(self: *RingBuffer, data: []const u8) void {
        if (data.len == 0) return;
        const cap = self.buf.len;
        if (data.len >= cap) {
            // Data fills or exceeds buffer — keep only the last `cap` bytes.
            @memcpy(self.buf[0..cap], data[data.len - cap ..]);
            self.write_pos = 0;
            self.len = cap;
            return;
        }

        const first_chunk = @min(data.len, cap - self.write_pos);
        @memcpy(self.buf[self.write_pos .. self.write_pos + first_chunk], data[0..first_chunk]);
        if (first_chunk < data.len) {
            const second_chunk = data.len - first_chunk;
            @memcpy(self.buf[0..second_chunk], data[first_chunk..]);
        }
        self.write_pos = (self.write_pos + data.len) % cap;
        self.len = @min(self.len + data.len, cap);
    }

    /// Two slices representing the stored data in order (handles wraparound).
    pub const Slices = struct {
        first: []const u8,
        second: []const u8,

        pub fn totalLen(self: Slices) usize {
            return self.first.len + self.second.len;
        }
    };

    /// Returns two slices covering all stored bytes in chronological order.
    /// If no wraparound, second slice is empty.
    pub fn readSlices(self: *const RingBuffer) Slices {
        if (self.len == 0) return .{ .first = &.{}, .second = &.{} };
        const cap = self.buf.len;

        if (self.len < cap) {
            // Buffer not full — data starts at (write_pos - len)
            if (self.write_pos >= self.len) {
                return .{
                    .first = self.buf[self.write_pos - self.len .. self.write_pos],
                    .second = &.{},
                };
            }
            // Wrapped
            const start = cap - (self.len - self.write_pos);
            return .{
                .first = self.buf[start..cap],
                .second = self.buf[0..self.write_pos],
            };
        }
        // Buffer completely full
        if (self.write_pos == 0) {
            return .{ .first = self.buf[0..cap], .second = &.{} };
        }
        return .{
            .first = self.buf[self.write_pos..cap],
            .second = self.buf[0..self.write_pos],
        };
    }

    pub fn clear(self: *RingBuffer) void {
        self.write_pos = 0;
        self.len = 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "basic write and read" {
    var rb = try RingBuffer.init(std.testing.allocator, 16);
    defer rb.deinit();

    rb.write("hello");
    const slices = rb.readSlices();
    try std.testing.expectEqual(@as(usize, 5), slices.totalLen());
    try std.testing.expectEqualStrings("hello", slices.first);
    try std.testing.expectEqual(@as(usize, 0), slices.second.len);
}

test "wraparound" {
    var rb = try RingBuffer.init(std.testing.allocator, 8);
    defer rb.deinit();

    rb.write("abcdef"); // 6 bytes, no wrap
    rb.write("ghij"); // 4 more, total 10 > 8, wraps

    const slices = rb.readSlices();
    try std.testing.expectEqual(@as(usize, 8), slices.totalLen());

    // Should contain "cdefghij" (last 8 of "abcdefghij")
    var out: [8]u8 = undefined;
    @memcpy(out[0..slices.first.len], slices.first);
    @memcpy(out[slices.first.len .. slices.first.len + slices.second.len], slices.second);
    try std.testing.expectEqualStrings("cdefghij", &out);
}

test "overflow single write" {
    var rb = try RingBuffer.init(std.testing.allocator, 4);
    defer rb.deinit();

    rb.write("abcdefgh"); // 8 bytes into 4-byte buffer
    const slices = rb.readSlices();
    try std.testing.expectEqual(@as(usize, 4), slices.totalLen());
    try std.testing.expectEqualStrings("efgh", slices.first);
}

test "clear" {
    var rb = try RingBuffer.init(std.testing.allocator, 8);
    defer rb.deinit();

    rb.write("data");
    try std.testing.expectEqual(@as(usize, 4), rb.len);
    rb.clear();
    try std.testing.expectEqual(@as(usize, 0), rb.len);
    try std.testing.expectEqual(@as(usize, 0), rb.readSlices().totalLen());
}

test "empty read" {
    var rb = try RingBuffer.init(std.testing.allocator, 8);
    defer rb.deinit();

    const slices = rb.readSlices();
    try std.testing.expectEqual(@as(usize, 0), slices.totalLen());
}

test "exact capacity fill" {
    var rb = try RingBuffer.init(std.testing.allocator, 4);
    defer rb.deinit();

    rb.write("abcd");
    const slices = rb.readSlices();
    try std.testing.expectEqual(@as(usize, 4), slices.totalLen());
    try std.testing.expectEqualStrings("abcd", slices.first);
}
