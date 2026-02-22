const std = @import("std");

pub const SessionLog = struct {
    pub const default_max_events: usize = 4096;
    pub const default_max_bytes: usize = 4 * 1024 * 1024;

    pub const Event = union(enum) {
        output_chunk: ByteEvent,
        input_chunk: ByteEvent,
        frame: FrameEvent,
    };

    pub const ByteEvent = struct {
        ts_ns: u64,
        bytes: []u8,
    };

    pub const FrameEvent = struct {
        ts_ns: u64,
        frame_id: u64,
        grid_hash: u64,
        alt_active: bool,
    };

    pub const Stats = struct {
        event_count: usize,
        total_bytes: usize,
    };

    events: []Event,
    count: usize = 0,
    byte_count: usize = 0,
    frame_counter: u64 = 0,
    last_hash: ?u64 = null,
    max_events: usize,
    max_bytes: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !SessionLog {
        return initBounded(allocator, default_max_events, default_max_bytes);
    }

    pub fn initBounded(allocator: std.mem.Allocator, max_ev: usize, max_b: usize) !SessionLog {
        return .{
            .events = try allocator.alloc(Event, max_ev),
            .max_events = max_ev,
            .max_bytes = max_b,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionLog) void {
        for (self.events[0..self.count]) |event| freeBytes(self.allocator, event);
        self.allocator.free(self.events);
    }

    pub fn appendOutput(self: *SessionLog, bytes: []const u8) void {
        const copy = self.allocator.dupe(u8, bytes) catch return;
        self.push(.{ .output_chunk = .{ .ts_ns = timestamp(), .bytes = copy } }, bytes.len);
    }

    pub fn appendInput(self: *SessionLog, bytes: []const u8) void {
        const copy = self.allocator.dupe(u8, bytes) catch return;
        self.push(.{ .input_chunk = .{ .ts_ns = timestamp(), .bytes = copy } }, bytes.len);
    }

    /// Append a frame event only if the grid hash changed since the last frame.
    pub fn appendFrame(self: *SessionLog, grid_hash: u64, alt_active: bool) void {
        if (self.last_hash) |h| {
            if (h == grid_hash) return;
        }
        self.last_hash = grid_hash;
        self.frame_counter += 1;
        self.push(.{ .frame = .{
            .ts_ns = timestamp(),
            .frame_id = self.frame_counter,
            .grid_hash = grid_hash,
            .alt_active = alt_active,
        } }, 0);
    }

    /// Return the last `n` events as a contiguous slice (or fewer if less exist).
    pub fn lastEvents(self: *const SessionLog, n: usize) []const Event {
        const actual = @min(n, self.count);
        return self.events[self.count - actual .. self.count];
    }

    pub fn stats(self: *const SessionLog) Stats {
        return .{ .event_count = self.count, .total_bytes = self.byte_count };
    }

    // -- internals --

    fn push(self: *SessionLog, event: Event, byte_len: usize) void {
        self.makeRoom(byte_len);
        self.events[self.count] = event;
        self.count += 1;
        self.byte_count += byte_len;
    }

    fn makeRoom(self: *SessionLog, needed: usize) void {
        var drop: usize = 0;
        var freed: usize = 0;

        while (drop < self.count) {
            const rem_count = self.count - drop;
            const rem_bytes = self.byte_count - freed;
            if (rem_count < self.max_events and rem_bytes + needed <= self.max_bytes) break;
            freed += eventByteLen(self.events[drop]);
            drop += 1;
        }

        if (drop == 0) return;

        for (self.events[0..drop]) |ev| freeBytes(self.allocator, ev);

        const remaining = self.count - drop;
        if (remaining > 0) {
            std.mem.copyForwards(Event, self.events[0..remaining], self.events[drop..self.count]);
        }
        self.count = remaining;
        self.byte_count -= freed;
    }

    fn freeBytes(allocator: std.mem.Allocator, event: Event) void {
        switch (event) {
            .output_chunk => |c| allocator.free(c.bytes),
            .input_chunk => |c| allocator.free(c.bytes),
            .frame => {},
        }
    }

    fn eventByteLen(event: Event) usize {
        return switch (event) {
            .output_chunk => |c| c.bytes.len,
            .input_chunk => |c| c.bytes.len,
            .frame => 0,
        };
    }

    fn timestamp() u64 {
        const ts = std.time.nanoTimestamp();
        return if (ts < 0) 0 else @intCast(ts);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "drops oldest when event limit reached" {
    var log = try SessionLog.initBounded(testing.allocator, 3, 4096);
    defer log.deinit();

    log.appendOutput("aaa");
    log.appendOutput("bbb");
    log.appendOutput("ccc");
    log.appendOutput("ddd");

    try testing.expectEqual(@as(usize, 3), log.stats().event_count);
    const evs = log.lastEvents(3);
    try testing.expectEqualStrings("bbb", evs[0].output_chunk.bytes);
    try testing.expectEqualStrings("ccc", evs[1].output_chunk.bytes);
    try testing.expectEqualStrings("ddd", evs[2].output_chunk.bytes);
}

test "drops oldest when byte limit reached" {
    var log = try SessionLog.initBounded(testing.allocator, 100, 10);
    defer log.deinit();

    log.appendOutput("12345");
    log.appendOutput("67890");
    log.appendOutput("abc");

    try testing.expectEqual(@as(usize, 2), log.stats().event_count);
    try testing.expectEqual(@as(usize, 8), log.stats().total_bytes);
    const evs = log.lastEvents(2);
    try testing.expectEqualStrings("67890", evs[0].output_chunk.bytes);
    try testing.expectEqualStrings("abc", evs[1].output_chunk.bytes);
}

test "input and output append in order" {
    var log = try SessionLog.initBounded(testing.allocator, 100, 4096);
    defer log.deinit();

    log.appendOutput("from pty");
    log.appendInput("from user");
    log.appendOutput("response");

    const evs = log.lastEvents(3);
    try testing.expect(evs[0] == .output_chunk);
    try testing.expect(evs[1] == .input_chunk);
    try testing.expect(evs[2] == .output_chunk);
    try testing.expectEqualStrings("from user", evs[1].input_chunk.bytes);
}

test "frame id increments" {
    var log = try SessionLog.initBounded(testing.allocator, 100, 4096);
    defer log.deinit();

    log.appendFrame(111, false);
    log.appendFrame(222, false);
    log.appendFrame(333, true);

    try testing.expectEqual(@as(usize, 3), log.stats().event_count);
    const evs = log.lastEvents(3);
    try testing.expectEqual(@as(u64, 1), evs[0].frame.frame_id);
    try testing.expectEqual(@as(u64, 2), evs[1].frame.frame_id);
    try testing.expectEqual(@as(u64, 3), evs[2].frame.frame_id);
    try testing.expect(evs[2].frame.alt_active);
}

test "unchanged hash skips frame" {
    var log = try SessionLog.initBounded(testing.allocator, 100, 4096);
    defer log.deinit();

    log.appendFrame(111, false);
    log.appendFrame(111, false);
    log.appendFrame(222, false);

    try testing.expectEqual(@as(usize, 2), log.stats().event_count);
    try testing.expectEqual(@as(u64, 1), log.lastEvents(2)[0].frame.frame_id);
    try testing.expectEqual(@as(u64, 2), log.lastEvents(2)[1].frame.frame_id);
}

test "lastEvents returns fewer when n > count" {
    var log = try SessionLog.initBounded(testing.allocator, 100, 4096);
    defer log.deinit();

    log.appendOutput("only");
    try testing.expectEqual(@as(usize, 1), log.lastEvents(50).len);
}

test "stats tracks bytes across event types" {
    var log = try SessionLog.initBounded(testing.allocator, 100, 4096);
    defer log.deinit();

    log.appendOutput("hello");
    log.appendInput("world");
    log.appendFrame(42, false);

    const s = log.stats();
    try testing.expectEqual(@as(usize, 3), s.event_count);
    try testing.expectEqual(@as(usize, 10), s.total_bytes);
}
