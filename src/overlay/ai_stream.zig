const std = @import("std");
const ai_auth = @import("ai_auth.zig");

// ---------------------------------------------------------------------------
// DeltaRing — lock-free SPSC ring buffer for streaming text deltas
// ---------------------------------------------------------------------------

pub const ring_size: u32 = 16384;

pub const DeltaRing = struct {
    buf: [ring_size]u8 = undefined,
    write_pos: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    read_pos: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Push data into the ring. Returns number of bytes actually written.
    /// Called from SSE thread (single producer).
    pub fn push(self: *DeltaRing, data: []const u8) usize {
        const wp = self.write_pos.load(.acquire);
        const rp = self.read_pos.load(.acquire);

        const available = ring_size - (wp -% rp);
        const to_write = @min(data.len, available);
        if (to_write == 0) return 0;

        for (0..to_write) |i| {
            self.buf[(wp +% @as(u32, @intCast(i))) % ring_size] = data[i];
        }

        self.write_pos.store(wp +% @as(u32, @intCast(to_write)), .release);
        return to_write;
    }

    /// Drain available data into out_buf. Returns the filled slice.
    /// Called from PTY thread (single consumer).
    pub fn drain(self: *DeltaRing, out_buf: []u8) []u8 {
        const wp = self.write_pos.load(.acquire);
        const rp = self.read_pos.load(.acquire);

        const avail = wp -% rp;
        if (avail == 0) return out_buf[0..0];

        const to_read = @min(avail, @as(u32, @intCast(out_buf.len)));
        for (0..to_read) |i| {
            out_buf[i] = self.buf[(rp +% @as(u32, @intCast(i))) % ring_size];
        }

        self.read_pos.store(rp +% to_read, .release);
        return out_buf[0..to_read];
    }

    pub fn reset(self: *DeltaRing) void {
        self.write_pos.store(0, .release);
        self.read_pos.store(0, .release);
    }
};

// ---------------------------------------------------------------------------
// Stream status
// ---------------------------------------------------------------------------

pub const StreamStatus = enum(u8) {
    idle = 0,
    connecting = 1,
    streaming = 2,
    done = 3,
    errored = 4,
    canceled = 5,
};

// ---------------------------------------------------------------------------
// SSE thread
// ---------------------------------------------------------------------------

pub const SseThread = struct {
    status: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(StreamStatus.idle)),
    cancel: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    delta_ring: DeltaRing = .{},

    error_code: [64]u8 = .{0} ** 64,
    error_code_len: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    error_msg: [256]u8 = .{0} ** 256,
    error_msg_len: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
    http_status: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),

    thread: ?std.Thread = null,

    pub fn init() SseThread {
        return .{};
    }

    pub fn getStatus(self: *const SseThread) StreamStatus {
        return @enumFromInt(self.status.load(.acquire));
    }

    pub fn getHttpStatus(self: *const SseThread) u16 {
        return self.http_status.load(.acquire);
    }

    pub fn getErrorCode(self: *const SseThread) []const u8 {
        const len = self.error_code_len.load(.acquire);
        return self.error_code[0..len];
    }

    pub fn getErrorMsg(self: *const SseThread) []const u8 {
        const len = self.error_msg_len.load(.acquire);
        return self.error_msg[0..len];
    }

    pub fn start(self: *SseThread, allocator: std.mem.Allocator, url: []const u8, access_token: []const u8, body: []const u8) !void {
        if (self.thread != null) return;
        self.cancel.store(0, .release);
        self.status.store(@intFromEnum(StreamStatus.idle), .release);
        self.error_code_len.store(0, .release);
        self.error_msg_len.store(0, .release);
        self.http_status.store(0, .release);
        self.delta_ring.reset();

        const url_copy = try allocator.dupe(u8, url);
        const token_copy = try allocator.dupe(u8, access_token);
        const body_copy = try allocator.dupe(u8, body);

        self.thread = try std.Thread.spawn(.{}, sseWorker, .{ self, allocator, url_copy, token_copy, body_copy });
    }

    pub fn requestCancel(self: *SseThread) void {
        self.cancel.store(1, .release);
    }

    pub fn tryJoin(self: *SseThread) bool {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
            return true;
        }
        return false;
    }

    fn setStatus(self: *SseThread, s: StreamStatus) void {
        self.status.store(@intFromEnum(s), .release);
    }

    fn setError(self: *SseThread, code: []const u8, msg: []const u8) void {
        const cl: u8 = @intCast(@min(code.len, self.error_code.len));
        @memcpy(self.error_code[0..cl], code[0..cl]);
        self.error_code_len.store(cl, .release);

        const ml: u16 = @intCast(@min(msg.len, self.error_msg.len));
        @memcpy(self.error_msg[0..ml], msg[0..ml]);
        self.error_msg_len.store(ml, .release);
    }

    fn isCanceled(self: *SseThread) bool {
        return self.cancel.load(.acquire) != 0;
    }
};

fn sseWorker(self: *SseThread, allocator: std.mem.Allocator, url: []u8, access_token: []u8, body: []u8) void {
    defer allocator.free(url);
    defer allocator.free(access_token);
    defer allocator.free(body);

    if (self.isCanceled()) {
        self.setStatus(.canceled);
        return;
    }

    self.setStatus(.connecting);

    sseWorkerInner(self, allocator, url, access_token, body) catch {
        if (self.isCanceled()) {
            self.setStatus(.canceled);
            return;
        }
        if (self.getStatus() != .errored) {
            self.setError("connection", "Failed to connect to AI backend");
            self.setStatus(.errored);
        }
    };
}

fn sseWorkerInner(self: *SseThread, allocator: std.mem.Allocator, url: []const u8, access_token: []const u8, body: []const u8) !void {
    const uri = try std.Uri.parse(url);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build Authorization header value
    var auth_buf: [2100]u8 = undefined;
    const auth_val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{access_token}) catch return error.BufferOverflow;

    const extra_headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth_val },
        .{ .name = "Accept", .value = "text/event-stream" },
    };

    var req = try client.request(.POST, uri, .{
        .keep_alive = false,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = &extra_headers,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.writer.writeAll(body);
    try bw.end();
    try req.connection.?.flush();

    var redirect_buf: [0]u8 = .{};
    var response = try req.receiveHead(&redirect_buf);

    const status: u16 = @intFromEnum(response.head.status);
    self.http_status.store(status, .release);

    if (status != 200) {
        // Read error body
        var transfer_buf: [4096]u8 = undefined;
        const err_reader = response.reader(&transfer_buf);
        var err_list: std.ArrayList(u8) = .{};
        defer err_list.deinit(allocator);
        var tmp: [1024]u8 = undefined;
        while (true) {
            const n = err_reader.readSliceShort(&tmp) catch break;
            if (n == 0) break;
            err_list.appendSlice(allocator, tmp[0..n]) catch break;
            if (err_list.items.len > 4096) break;
        }

        var code_buf: [16]u8 = undefined;
        const code_str = std.fmt.bufPrint(&code_buf, "{d}", .{status}) catch "unknown";
        const msg = if (err_list.items.len > 0)
            (ai_auth.extractJsonString(err_list.items, "message") orelse "Request failed")
        else
            "Request failed";

        self.setError(code_str, msg);
        self.setStatus(.errored);
        return;
    }

    self.setStatus(.streaming);

    // Parse SSE stream line by line
    var transfer_buf: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    var line_buf: [4096]u8 = undefined;
    var line_len: usize = 0;
    var current_event: SseEventType = .unknown;
    var read_buf: [1024]u8 = undefined;

    while (true) {
        if (self.isCanceled()) {
            self.setStatus(.canceled);
            return;
        }

        const n = reader.readSliceShort(&read_buf) catch break;
        if (n == 0) break;

        // Process bytes, accumulate lines
        for (read_buf[0..n]) |byte| {
            if (byte == '\n') {
                const line = line_buf[0..line_len];
                processSseLine(self, line, &current_event);
                line_len = 0;

                // Check for terminal states
                const s = self.getStatus();
                if (s == .done or s == .errored or s == .canceled) return;
            } else if (byte != '\r') {
                if (line_len < line_buf.len) {
                    line_buf[line_len] = byte;
                    line_len += 1;
                }
            }
        }
    }

    // End of stream — if we were streaming, mark as done
    if (self.getStatus() == .streaming) {
        self.setStatus(.done);
    }
}

const SseEventType = enum { unknown, meta, progress, delta, final_event, error_event };

fn parseSseEventType(name: []const u8) SseEventType {
    if (std.mem.eql(u8, name, "meta")) return .meta;
    if (std.mem.eql(u8, name, "progress")) return .progress;
    if (std.mem.eql(u8, name, "delta")) return .delta;
    if (std.mem.eql(u8, name, "final")) return .final_event;
    if (std.mem.eql(u8, name, "error")) return .error_event;
    return .unknown;
}

fn processSseLine(self: *SseThread, line: []const u8, current_event: *SseEventType) void {
    if (line.len == 0) {
        // Blank line: reset event type (SSE dispatch)
        current_event.* = .unknown;
        return;
    }

    // Comment lines (keepalive pings)
    if (line[0] == ':') return;

    // "event: <type>"
    if (std.mem.startsWith(u8, line, "event:")) {
        var name = line["event:".len..];
        // Trim leading space
        while (name.len > 0 and name[0] == ' ') name = name[1..];
        current_event.* = parseSseEventType(name);
        return;
    }

    // "data: <json>"
    if (std.mem.startsWith(u8, line, "data:")) {
        var data = line["data:".len..];
        while (data.len > 0 and data[0] == ' ') data = data[1..];

        switch (current_event.*) {
            .delta => {
                // Extract "text" field and push to ring
                if (ai_auth.extractJsonString(data, "text")) |text| {
                    _ = self.delta_ring.push(text);
                }
            },
            .error_event => {
                const code = ai_auth.extractJsonString(data, "code") orelse "unknown";
                const msg = ai_auth.extractJsonString(data, "message") orelse "Unknown error";
                self.setError(code, msg);
                self.setStatus(.errored);
            },
            .final_event => {
                // Final event may contain text in data field
                if (ai_auth.extractJsonString(data, "text")) |text| {
                    _ = self.delta_ring.push(text);
                }
                self.setStatus(.done);
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "DeltaRing: push and drain" {
    var ring = DeltaRing{};
    const written = ring.push("hello world");
    try std.testing.expectEqual(@as(usize, 11), written);

    var out: [32]u8 = undefined;
    const drained = ring.drain(&out);
    try std.testing.expectEqualStrings("hello world", drained);
}

test "DeltaRing: empty drain" {
    var ring = DeltaRing{};
    var out: [32]u8 = undefined;
    const drained = ring.drain(&out);
    try std.testing.expectEqual(@as(usize, 0), drained.len);
}

test "DeltaRing: multiple pushes and single drain" {
    var ring = DeltaRing{};
    _ = ring.push("hello ");
    _ = ring.push("world");

    var out: [32]u8 = undefined;
    const drained = ring.drain(&out);
    try std.testing.expectEqualStrings("hello world", drained);
}

test "DeltaRing: partial drain" {
    var ring = DeltaRing{};
    _ = ring.push("abcdefghij");

    var out: [5]u8 = undefined;
    const d1 = ring.drain(&out);
    try std.testing.expectEqualStrings("abcde", d1);

    const d2 = ring.drain(&out);
    try std.testing.expectEqualStrings("fghij", d2);
}

test "DeltaRing: reset clears state" {
    var ring = DeltaRing{};
    _ = ring.push("data");
    ring.reset();

    var out: [32]u8 = undefined;
    const drained = ring.drain(&out);
    try std.testing.expectEqual(@as(usize, 0), drained.len);
}

test "DeltaRing: wraparound" {
    var ring = DeltaRing{};
    // Fill most of the ring
    var big: [ring_size - 10]u8 = undefined;
    @memset(&big, 'X');
    _ = ring.push(&big);
    // Drain it
    var drain_buf: [ring_size]u8 = undefined;
    _ = ring.drain(&drain_buf);
    // Now push data that wraps around
    _ = ring.push("wrap_around_test");
    const drained = ring.drain(&drain_buf);
    try std.testing.expectEqualStrings("wrap_around_test", drained);
}

test "SseThread: init state" {
    var sse = SseThread.init();
    try std.testing.expectEqual(StreamStatus.idle, sse.getStatus());
    try std.testing.expectEqual(@as(u16, 0), sse.getHttpStatus());
}

test "processSseLine: delta event" {
    var sse = SseThread.init();
    var event_type: SseEventType = .unknown;

    processSseLine(&sse, "event: delta", &event_type);
    try std.testing.expectEqual(SseEventType.delta, event_type);

    processSseLine(&sse, "data: {\"text\":\"hello\"}", &event_type);
    var out: [32]u8 = undefined;
    const drained = sse.delta_ring.drain(&out);
    try std.testing.expectEqualStrings("hello", drained);
}

test "processSseLine: error event" {
    var sse = SseThread.init();
    var event_type: SseEventType = .unknown;

    processSseLine(&sse, "event: error", &event_type);
    processSseLine(&sse, "data: {\"code\":\"rate_limit\",\"message\":\"Too many requests\"}", &event_type);

    try std.testing.expectEqual(StreamStatus.errored, sse.getStatus());
    try std.testing.expectEqualStrings("rate_limit", sse.getErrorCode());
    try std.testing.expectEqualStrings("Too many requests", sse.getErrorMsg());
}

test "processSseLine: final event" {
    var sse = SseThread.init();
    var event_type: SseEventType = .unknown;

    processSseLine(&sse, "event: final", &event_type);
    processSseLine(&sse, "data: {\"text\":\"done\"}", &event_type);

    try std.testing.expectEqual(StreamStatus.done, sse.getStatus());
    var out: [32]u8 = undefined;
    const drained = sse.delta_ring.drain(&out);
    try std.testing.expectEqualStrings("done", drained);
}

test "processSseLine: comment ignored" {
    var sse = SseThread.init();
    var event_type: SseEventType = .delta;
    processSseLine(&sse, ": ping", &event_type);
    // Event type should not change
    try std.testing.expectEqual(SseEventType.delta, event_type);
}

test "processSseLine: blank line resets event" {
    var sse = SseThread.init();
    var event_type: SseEventType = .delta;
    processSseLine(&sse, "", &event_type);
    try std.testing.expectEqual(SseEventType.unknown, event_type);
    try std.testing.expectEqual(StreamStatus.idle, sse.getStatus());
}
