const std = @import("std");
const log = @import("log.zig");

/// Rolling 2-second throughput window. Reports bytes/sec at debug level.
/// Call add() after each PTY read; reporting is self-throttled.
pub const ThroughputWindow = struct {
    start_ns: i128 = 0,
    window_bytes: u64 = 0,

    pub fn add(self: *ThroughputWindow, bytes: usize) void {
        if (@intFromEnum(log.global.level) < @intFromEnum(log.Level.debug)) return;
        if (self.start_ns == 0) self.start_ns = std.time.nanoTimestamp();
        self.window_bytes += bytes;
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.start_ns;
        if (elapsed_ns < 2 * std.time.ns_per_s) return;
        const bps = self.window_bytes * std.time.ns_per_s / @as(u64, @intCast(elapsed_ns));
        log.debug("pty", "throughput: {d} bytes/s", .{bps});
        self.start_ns = now;
        self.window_bytes = 0;
    }
};
