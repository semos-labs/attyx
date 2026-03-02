const std = @import("std");
const ai_auth = @import("ai_auth.zig");

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

pub const StreamStatus = enum(u8) {
    idle = 0,
    connecting = 1,
    streaming = 2,
    done = 3,
    errored = 4,
    canceled = 5,
};

pub const SseThread = struct {
    status: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(StreamStatus.idle)),
    cancel: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    first_delta_sent: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
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
        self.first_delta_sent.store(0, .release);
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
        // Read error body — use allocRemaining to avoid readSliceShort panic
        // on content-length responses (Zig stdlib contentLengthStream bug).
        var transfer_buf: [4096]u8 = undefined;
        const err_reader = response.reader(&transfer_buf);
        const err_body = err_reader.allocRemaining(allocator, .limited(4096)) catch "";
        defer if (err_body.len > 0) allocator.free(err_body);

        var code_buf: [16]u8 = undefined;
        const code_str = std.fmt.bufPrint(&code_buf, "{d}", .{status}) catch "unknown";
        const msg = if (err_body.len > 0)
            (ai_auth.extractJsonString(err_body, "message") orelse "Request failed")
        else
            "Request failed";

        self.setError(code_str, msg);
        self.setStatus(.errored);
        return;
    }

    self.setStatus(.streaming);

    // Content-length responses trigger a panic in Zig's HTTP reader
    // (contentLengthStream accesses inactive union field after exhausting
    // content). Read such responses in one shot; stream chunked responses
    // normally since chunkedStream handles the .ready state safely.
    if (response.head.content_length != null) {
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const body_data = reader.allocRemaining(allocator, .limited(256_000)) catch {
            self.setError("read", "Failed to read response");
            self.setStatus(.errored);
            return;
        };
        defer allocator.free(body_data);
        parseSseBuffer(self, body_data);
        if (self.getStatus() == .streaming) {
            self.setStatus(.done);
        }
        return;
    }

    // Parse SSE stream line by line (chunked or close-delimited)
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

/// Parse a complete SSE body (from a content-length response) into events.
fn parseSseBuffer(self: *SseThread, data: []const u8) void {
    var line_buf: [4096]u8 = undefined;
    var line_len: usize = 0;
    var current_event: SseEventType = .unknown;

    for (data) |byte| {
        if (byte == '\n') {
            const line = line_buf[0..line_len];
            processSseLine(self, line, &current_event);
            line_len = 0;

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
                // Show progress on first delta; ignore raw JSON fragments
                if (self.first_delta_sent.load(.acquire) == 0) {
                    _ = self.delta_ring.push("Generating response...");
                    self.first_delta_sent.store(1, .release);
                }
            },
            .error_event => {
                const code = ai_auth.extractJsonString(data, "code") orelse "unknown";
                const msg = ai_auth.extractJsonString(data, "message") orelse "Unknown error";
                self.setError(code, msg);
                self.setStatus(.errored);
            },
            .final_event => {
                formatFinalResponse(self, data);
                self.setStatus(.done);
            },
            else => {},
        }
    }
}

fn formatFinalResponse(self: *SseThread, data: []const u8) void {
    // Edit response: replacement_text found → push raw replacement + \0 + explanation
    if (ai_auth.extractJsonString(data, "replacement_text")) |replacement| {
        _ = self.delta_ring.push(replacement);
        _ = self.delta_ring.push(&[_]u8{0}); // null separator
        if (ai_auth.extractJsonString(data, "short_explanation")) |expl| {
            _ = self.delta_ring.push(expl);
        }
        return;
    }

    if (ai_auth.extractJsonString(data, "summary")) |summary| {
        _ = self.delta_ring.push(summary);
        _ = self.delta_ring.push("\n");
    }
    if (ai_auth.extractJsonString(data, "explanation")) |explanation| {
        _ = self.delta_ring.push("\n");
        _ = self.delta_ring.push(explanation);
        _ = self.delta_ring.push("\n");
    }
    pushJsonStringArray(self, data, "highlights", "Highlights");
    pushJsonStringArray(self, data, "causes", "Causes");
    pushJsonStringArray(self, data, "key_points", "Key Points");
    pushJsonStringArray(self, data, "errors", "Errors");
    pushJsonStringArray(self, data, "warnings", "Warnings");
    pushJsonStringArray(self, data, "next_steps", "Next Steps");
    pushJsonStringArray(self, data, "notes", "Notes");
    pushJsonCommandArray(self, data);
}
fn findJsonArrayStart(json: []const u8, key: []const u8) ?usize {
    var pos: usize = 0;
    while (pos + key.len + 4 < json.len) : (pos += 1) {
        if (json[pos] == '"' and
            pos + 1 + key.len < json.len and
            std.mem.eql(u8, json[pos + 1 .. pos + 1 + key.len], key) and
            json[pos + 1 + key.len] == '"')
        {
            var vpos = pos + 2 + key.len;
            while (vpos < json.len and (json[vpos] == ' ' or json[vpos] == ':')) vpos += 1;
            if (vpos < json.len and json[vpos] == '[') return vpos + 1;
        }
    }
    return null;
}

fn pushJsonStringArray(self: *SseThread, json: []const u8, key: []const u8, header: []const u8) void {
    const start = findJsonArrayStart(json, key) orelse return;
    var header_pushed = false;
    var i = start;
    while (i < json.len) {
        if (json[i] == ']') break;
        if (json[i] == '"') {
            const s = i + 1;
            var e = s;
            while (e < json.len and json[e] != '"') {
                if (json[e] == '\\') e += 1;
                e += 1;
            }
            if (e > s) {
                if (!header_pushed) {
                    _ = self.delta_ring.push("\n");
                    _ = self.delta_ring.push(header);
                    _ = self.delta_ring.push(":\n");
                    header_pushed = true;
                }
                _ = self.delta_ring.push("- ");
                _ = self.delta_ring.push(json[s..e]);
                _ = self.delta_ring.push("\n");
            }
            i = e + 1;
        } else i += 1;
    }
}

fn pushJsonCommandArray(self: *SseThread, json: []const u8) void {
    const start = findJsonArrayStart(json, "commands") orelse return;
    var header_pushed = false;
    var i = start;
    while (i < json.len) {
        if (json[i] == ']') break;
        if (json[i] == '{') {
            var depth: usize = 1;
            var e = i + 1;
            while (e < json.len and depth > 0) : (e += 1) {
                if (json[e] == '{') depth += 1 else if (json[e] == '}') depth -= 1;
            }
            const obj = json[i..e];
            if (ai_auth.extractJsonString(obj, "command")) |cmd| {
                if (!header_pushed) {
                    _ = self.delta_ring.push("\nCommands:\n");
                    header_pushed = true;
                }
                _ = self.delta_ring.push("```\n");
                _ = self.delta_ring.push(cmd);
                _ = self.delta_ring.push("\n```\n");
                if (ai_auth.extractJsonString(obj, "risk")) |risk| {
                    _ = self.delta_ring.push("Risk: ");
                    _ = self.delta_ring.push(risk);
                    _ = self.delta_ring.push("\n");
                }
            }
            i = e;
        } else i += 1;
    }
}

test "DeltaRing: basic, partial drain, reset, wraparound" {
    var ring = DeltaRing{};
    var out: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), ring.drain(&out).len);
    try std.testing.expectEqual(@as(usize, 11), ring.push("hello world"));
    try std.testing.expectEqualStrings("hello world", ring.drain(&out));
    _ = ring.push("hello ");
    _ = ring.push("world");
    try std.testing.expectEqualStrings("hello world", ring.drain(&out));
    // Partial drain
    _ = ring.push("abcdefghij");
    var out5: [5]u8 = undefined;
    try std.testing.expectEqualStrings("abcde", ring.drain(&out5));
    try std.testing.expectEqualStrings("fghij", ring.drain(&out5));
    // Reset
    _ = ring.push("data");
    ring.reset();
    try std.testing.expectEqual(@as(usize, 0), ring.drain(&out).len);
    // Wraparound
    var big: [ring_size - 10]u8 = undefined;
    @memset(&big, 'X');
    _ = ring.push(&big);
    var drain_buf: [ring_size]u8 = undefined;
    _ = ring.drain(&drain_buf);
    _ = ring.push("wrap_around_test");
    try std.testing.expectEqualStrings("wrap_around_test", ring.drain(&drain_buf));
}

test "SseThread: init state" {
    var sse = SseThread.init();
    try std.testing.expectEqual(StreamStatus.idle, sse.getStatus());
    try std.testing.expectEqual(@as(u16, 0), sse.getHttpStatus());
}

test "processSseLine: delta event shows progress" {
    var sse = SseThread.init();
    var event_type: SseEventType = .unknown;

    processSseLine(&sse, "event: delta", &event_type);
    try std.testing.expectEqual(SseEventType.delta, event_type);

    processSseLine(&sse, "data: {\"text\":\"{\\\"su\"}", &event_type);
    var out: [64]u8 = undefined;
    const drained = sse.delta_ring.drain(&out);
    try std.testing.expectEqualStrings("Generating response...", drained);

    // Second delta should not push anything more
    processSseLine(&sse, "data: {\"text\":\"mm\"}", &event_type);
    const drained2 = sse.delta_ring.drain(&out);
    try std.testing.expectEqual(@as(usize, 0), drained2.len);
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

test "processSseLine: final event formats response" {
    var sse = SseThread.init();
    var event_type: SseEventType = .unknown;

    processSseLine(&sse, "event: final", &event_type);
    const json = "data: {\"data\":{\"summary\":\"All good\",\"next_steps\":[\"check logs\"]}}";
    processSseLine(&sse, json, &event_type);

    try std.testing.expectEqual(StreamStatus.done, sse.getStatus());
    var out: [256]u8 = undefined;
    const drained = sse.delta_ring.drain(&out);
    try std.testing.expectEqualStrings("All good\n\nNext Steps:\n- check logs\n", drained);
}

test "processSseLine: comment and blank line" {
    var sse = SseThread.init();
    var event_type: SseEventType = .delta;
    processSseLine(&sse, ": ping", &event_type);
    try std.testing.expectEqual(SseEventType.delta, event_type);
    processSseLine(&sse, "", &event_type);
    try std.testing.expectEqual(SseEventType.unknown, event_type);
}

test "formatFinalResponse: commands, empty arrays" {
    var sse = SseThread.init();
    const json = "{\"data\":{\"summary\":\"Fix it\",\"commands\":[{\"command\":\"rm -rf /tmp\",\"risk\":\"low\"}]}}";
    formatFinalResponse(&sse, json);
    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings("Fix it\n\nCommands:\n```\nrm -rf /tmp\n```\nRisk: low\n", sse.delta_ring.drain(&out));
    // Empty arrays should be skipped
    var sse2 = SseThread.init();
    formatFinalResponse(&sse2, "{\"data\":{\"summary\":\"OK\",\"errors\":[],\"warnings\":[]}}");
    var out2: [128]u8 = undefined;
    try std.testing.expectEqualStrings("OK\n", sse2.delta_ring.drain(&out2));
}

test "formatFinalResponse: edit response with and without explanation" {
    var sse = SseThread.init();
    formatFinalResponse(&sse, "{\"data\":{\"replacement_text\":\"HELLO WORLD\",\"short_explanation\":\"Made uppercase\"}}");
    var out: [256]u8 = undefined;
    const drained = sse.delta_ring.drain(&out);
    const sep = std.mem.indexOfScalar(u8, drained, 0) orelse unreachable;
    try std.testing.expectEqualStrings("HELLO WORLD", drained[0..sep]);
    try std.testing.expectEqualStrings("Made uppercase", drained[sep + 1 ..]);
    // Without explanation
    var sse2 = SseThread.init();
    formatFinalResponse(&sse2, "{\"data\":{\"replacement_text\":\"fixed code\"}}");
    const drained2 = sse2.delta_ring.drain(&out);
    const sep2 = std.mem.indexOfScalar(u8, drained2, 0) orelse unreachable;
    try std.testing.expectEqualStrings("fixed code", drained2[0..sep2]);
    try std.testing.expectEqual(sep2 + 1, drained2.len);
}

test "findJsonArrayStart: found and missing" {
    try std.testing.expectEqual(@as(?usize, 10), findJsonArrayStart("{\"items\":[\"a\",\"b\"]}", "items"));
    try std.testing.expect(findJsonArrayStart("{\"items\":[\"a\"]}", "other") == null);
}
