const std = @import("std");
const Allocator = std.mem.Allocator;

/// Redact lines containing sensitive patterns. Each matching line is
/// replaced with "[REDACTED]". Returns a new owned slice.
pub fn redactSensitive(allocator: Allocator, input: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);
    const w = list.writer(allocator);

    var it = std.mem.splitScalar(u8, input, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try w.writeByte('\n');
        first = false;
        if (isSensitiveLine(line)) {
            try w.writeAll("[REDACTED]");
        } else {
            try w.writeAll(line);
        }
    }

    return list.toOwnedSlice(allocator);
}

fn isSensitiveLine(line: []const u8) bool {
    // Key / certificate patterns
    if (containsCI(line, "PRIVATE KEY")) return true;
    if (containsCI(line, "BEGIN RSA")) return true;
    if (containsCI(line, "BEGIN OPENSSH")) return true;

    // Cloud / API key patterns
    if (containsCI(line, "AWS_SECRET")) return true;
    if (hasAkiaPattern(line)) return true;

    // Environment variable secrets
    if (containsCI(line, "TOKEN=")) return true;
    if (containsCI(line, "SECRET=")) return true;
    if (containsCI(line, "PASSWORD=")) return true;

    // Auth headers
    if (containsCI(line, "Bearer ")) return true;
    if (containsCI(line, "Authorization:")) return true;

    // Long base64-like strings (potential encoded secrets)
    if (hasLongBase64Run(line, 100)) return true;

    return false;
}

/// Case-insensitive substring search.
fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        if (eqlCI(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn eqlCI(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (toLower(ac) != toLower(bc)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Check for AKIA followed by 16+ alphanumeric characters.
fn hasAkiaPattern(line: []const u8) bool {
    if (line.len < 20) return false; // "AKIA" + 16
    for (0..line.len - 3) |i| {
        if (line[i] == 'A' and line[i + 1] == 'K' and line[i + 2] == 'I' and line[i + 3] == 'A') {
            var count: usize = 0;
            var j = i + 4;
            while (j < line.len and isAlnum(line[j])) : (j += 1) {
                count += 1;
            }
            if (count >= 16) return true;
        }
    }
    return false;
}

/// Check for a run of 100+ consecutive base64-like characters.
fn hasLongBase64Run(line: []const u8, threshold: usize) bool {
    var run: usize = 0;
    for (line) |ch| {
        if (isBase64Char(ch)) {
            run += 1;
            if (run >= threshold) return true;
        } else {
            run = 0;
        }
    }
    return false;
}

fn isAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

fn isBase64Char(c: u8) bool {
    return isAlnum(c) or c == '+' or c == '/' or c == '=';
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "redact: private key line" {
    const alloc = std.testing.allocator;
    const result = try redactSensitive(alloc, "-----BEGIN RSA PRIVATE KEY-----");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[REDACTED]", result);
}

test "redact: openssh key" {
    const alloc = std.testing.allocator;
    const result = try redactSensitive(alloc, "-----BEGIN OPENSSH PRIVATE KEY-----");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[REDACTED]", result);
}

test "redact: AWS secret" {
    const alloc = std.testing.allocator;
    const result = try redactSensitive(alloc, "AWS_SECRET_ACCESS_KEY=abcdef1234567890");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[REDACTED]", result);
}

test "redact: AKIA key" {
    const alloc = std.testing.allocator;
    const result = try redactSensitive(alloc, "AKIAIOSFODNN7EXAMPLE1");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[REDACTED]", result);
}

test "redact: TOKEN= pattern" {
    const alloc = std.testing.allocator;
    const result = try redactSensitive(alloc, "GITHUB_TOKEN=ghp_abc123");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[REDACTED]", result);
}

test "redact: Bearer token" {
    const alloc = std.testing.allocator;
    const result = try redactSensitive(alloc, "Authorization: Bearer eyJhbGciOiJI");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[REDACTED]", result);
}

test "redact: safe lines pass through" {
    const alloc = std.testing.allocator;
    const result = try redactSensitive(alloc, "total 42\n-rw-r--r-- 1 user user 1234 file.txt");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("total 42\n-rw-r--r-- 1 user user 1234 file.txt", result);
}

test "redact: mixed lines" {
    const alloc = std.testing.allocator;
    const result = try redactSensitive(alloc, "line1\nPASSWORD=secret\nline3");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("line1\n[REDACTED]\nline3", result);
}

test "redact: long base64 run" {
    const alloc = std.testing.allocator;
    var buf: [110]u8 = undefined;
    @memset(&buf, 'A');
    const result = try redactSensitive(alloc, &buf);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[REDACTED]", result);
}
