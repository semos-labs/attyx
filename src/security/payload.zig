const std = @import("std");
const Allocator = std.mem.Allocator;
const redaction = @import("redaction.zig");
const FindingType = redaction.FindingType;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const SafePayload = struct {
    mode: []const u8,
    command: ?[]const u8,
    output_tail: ?[]u8,
};

pub const PayloadReport = struct {
    findings: [redaction.max_findings]FindingType = undefined,
    finding_count: u8 = 0,
    truncated: bool = false,
    bytes_before: usize = 0,
    bytes_after: usize = 0,

    pub fn findingSlice(self: *const PayloadReport) []const FindingType {
        return self.findings[0..self.finding_count];
    }
};

pub const SafePayloadResult = struct {
    payload: SafePayload,
    report: PayloadReport,

    pub fn deinit(self: *SafePayloadResult, allocator: Allocator) void {
        if (self.payload.output_tail) |t| allocator.free(t);
    }
};

pub const PayloadInput = struct {
    mode: []const u8,
    command: ?[]const u8 = null,
    output: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

const default_max_lines: usize = 50;
const default_max_bytes: usize = 16_000;

pub fn buildSafeAIPayload(allocator: Allocator, input: PayloadInput) !SafePayloadResult {
    return buildSafeAIPayloadWithLimits(allocator, input, default_max_lines, default_max_bytes);
}

pub fn buildSafeAIPayloadWithLimits(
    allocator: Allocator,
    input: PayloadInput,
    max_lines: usize,
    max_bytes: usize,
) !SafePayloadResult {
    var report = PayloadReport{};

    const raw_output = input.output orelse {
        return .{
            .payload = .{
                .mode = input.mode,
                .command = input.command,
                .output_tail = null,
            },
            .report = report,
        };
    };

    report.bytes_before = raw_output.len;

    // Step 1: Limit output size (keep tail)
    const limited = limitText(raw_output, max_lines, max_bytes);
    if (limited.len < raw_output.len) report.truncated = true;

    // Step 2: Redact
    var redact_result = try redaction.redactText(allocator, limited);
    // Copy findings into report
    report.finding_count = redact_result.finding_count;
    if (redact_result.finding_count > 0) {
        @memcpy(
            report.findings[0..redact_result.finding_count],
            redact_result.findings[0..redact_result.finding_count],
        );
    }

    // Step 3: Enforce maxBytes again after redaction
    if (redact_result.text.len > max_bytes) {
        const tail = limitTextOwned(redact_result.text, max_bytes);
        if (tail.ptr != redact_result.text.ptr) {
            // We need a new allocation for the tail portion
            const new_text = try allocator.dupe(u8, tail);
            allocator.free(redact_result.text);
            redact_result.text = new_text;
        }
        report.truncated = true;
    }

    report.bytes_after = redact_result.text.len;

    return .{
        .payload = .{
            .mode = input.mode,
            .command = input.command,
            .output_tail = redact_result.text,
        },
        .report = report,
    };
}

// ---------------------------------------------------------------------------
// Text limiter
// ---------------------------------------------------------------------------

/// Return a slice of the last `max_lines` lines and at most `max_bytes` bytes.
/// Returns a view into the original text (no allocation).
pub fn limitText(text: []const u8, max_lines: usize, max_bytes: usize) []const u8 {
    if (text.len == 0) return text;

    // First: byte limit (keep tail)
    var start: usize = 0;
    if (text.len > max_bytes) {
        start = text.len - max_bytes;
        // Align to next newline to avoid partial first line
        while (start < text.len and text[start] != '\n') start += 1;
        if (start < text.len) start += 1; // skip the newline
    }

    // Second: line limit (keep last N lines)
    const tail = text[start..];
    var newline_count: usize = 0;
    var pos = tail.len;
    while (pos > 0) {
        pos -= 1;
        if (tail[pos] == '\n') {
            newline_count += 1;
            if (newline_count >= max_lines) {
                return tail[pos + 1 ..];
            }
        }
    }

    return tail;
}

/// Like limitText but only enforces byte limit on an already-owned slice.
fn limitTextOwned(text: []u8, max_bytes: usize) []u8 {
    if (text.len <= max_bytes) return text;
    var start = text.len - max_bytes;
    while (start < text.len and text[start] != '\n') start += 1;
    if (start < text.len) start += 1;
    return text[start..];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "limitText: short text passes through" {
    const text = "line1\nline2\nline3";
    const result = limitText(text, 50, 16000);
    try std.testing.expectEqualStrings(text, result);
}

test "limitText: line limit keeps tail" {
    const text = "line1\nline2\nline3\nline4\nline5";
    const result = limitText(text, 2, 16000);
    try std.testing.expectEqualStrings("line4\nline5", result);
}

test "limitText: byte limit keeps tail" {
    const text = "aaaa\nbbbb\ncccc\ndddd";
    const result = limitText(text, 100, 10);
    // Should start at a line boundary within the last 10 bytes
    try std.testing.expect(result.len <= 10);
    try std.testing.expect(std.mem.indexOf(u8, result, "dddd") != null);
}

test "buildSafeAIPayload: no output" {
    const alloc = std.testing.allocator;
    var result = try buildSafeAIPayload(alloc, .{ .mode = "fix", .command = "ls" });
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("fix", result.payload.mode);
    try std.testing.expectEqual(@as(?[]u8, null), result.payload.output_tail);
    try std.testing.expect(!result.report.truncated);
}

test "buildSafeAIPayload: redacts secrets in output" {
    const alloc = std.testing.allocator;
    var result = try buildSafeAIPayload(alloc, .{
        .mode = "fix",
        .command = "env",
        .output = "PATH=/usr/bin\nDB_PASSWORD=hunter2\nHOME=/home/user",
    });
    defer result.deinit(alloc);
    const out = result.payload.output_tail.?;
    try std.testing.expect(std.mem.indexOf(u8, out, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[REDACTED]") != null);
    try std.testing.expect(result.report.finding_count > 0);
}

test "buildSafeAIPayload: truncation reported" {
    const alloc = std.testing.allocator;
    // Build 100 lines
    var big_buf: [5000]u8 = undefined;
    var pos: usize = 0;
    for (0..100) |i| {
        const line = std.fmt.bufPrint(big_buf[pos..], "line {d}\n", .{i}) catch break;
        pos += line.len;
    }
    var result = try buildSafeAIPayloadWithLimits(alloc, .{
        .mode = "explain",
        .output = big_buf[0..pos],
    }, 10, 16000);
    defer result.deinit(alloc);
    try std.testing.expect(result.report.truncated);
    try std.testing.expect(result.report.bytes_after < result.report.bytes_before);
}

test "buildSafeAIPayload: respects maxBytes" {
    const alloc = std.testing.allocator;
    var big_buf: [2000]u8 = undefined;
    @memset(&big_buf, 'x');
    // Add newlines every 50 chars
    var i: usize = 49;
    while (i < big_buf.len) : (i += 50) big_buf[i] = '\n';
    var result = try buildSafeAIPayloadWithLimits(alloc, .{
        .mode = "fix",
        .output = &big_buf,
    }, 1000, 500);
    defer result.deinit(alloc);
    try std.testing.expect(result.payload.output_tail.?.len <= 500);
    try std.testing.expect(result.report.truncated);
}

test "buildSafeAIPayload: report has correct findings" {
    const alloc = std.testing.allocator;
    var result = try buildSafeAIPayload(alloc, .{
        .mode = "fix",
        .command = "curl",
        .output = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9\nOK",
    });
    defer result.deinit(alloc);
    try std.testing.expect(result.report.finding_count > 0);
    // Should find auth_token
    var found_auth = false;
    for (result.report.findingSlice()) |f| {
        if (f == .auth_token) found_auth = true;
    }
    try std.testing.expect(found_auth);
}
