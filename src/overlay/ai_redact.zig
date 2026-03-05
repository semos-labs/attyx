const std = @import("std");
const Allocator = std.mem.Allocator;
const redaction = @import("../security/redaction.zig");

/// Redact sensitive content. Returns a new owned slice with secrets replaced.
/// This is the compatibility wrapper around security/redaction.zig.
pub fn redactSensitive(allocator: Allocator, input: []const u8) ![]u8 {
    const result = try redaction.redactText(allocator, input);
    return result.text;
}

/// Full redaction with findings report.
pub fn redactWithFindings(allocator: Allocator, input: []const u8) !redaction.RedactionResult {
    return redaction.redactText(allocator, input);
}

pub const RedactionResult = redaction.RedactionResult;
pub const FindingType = redaction.FindingType;

// Re-export payload builder
pub const payload = @import("../security/payload.zig");

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "redact: private key line" {
    const alloc = std.testing.allocator;
    const result = try redactSensitive(alloc, "-----BEGIN RSA PRIVATE KEY-----\ndata\n-----END RSA PRIVATE KEY-----");
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED_PRIVATE_KEY]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "data") == null);
}

test "redact: openssh key" {
    const alloc = std.testing.allocator;
    const result = try redactSensitive(alloc, "-----BEGIN OPENSSH PRIVATE KEY-----\nkey\n-----END OPENSSH PRIVATE KEY-----");
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED_PRIVATE_KEY]") != null);
}

test "redact: AWS secret" {
    const alloc = std.testing.allocator;
    const result = try redactSensitive(alloc, "AWS_SECRET_ACCESS_KEY=abcdef1234567890");
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "abcdef1234567890") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED]") != null);
}

test "redact: AKIA key" {
    const alloc = std.testing.allocator;
    const result = try redactSensitive(alloc, "AKIAIOSFODNN7EXAMPLE1");
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "[REDACTED_TOKEN]") != null);
}

test "redact: TOKEN= pattern" {
    const alloc = std.testing.allocator;
    const result = try redactSensitive(alloc, "GITHUB_TOKEN=ghp_abc123def456ghi");
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "ghp_abc123") == null);
}

test "redact: Bearer token" {
    const alloc = std.testing.allocator;
    const result = try redactSensitive(alloc, "Authorization: Bearer eyJhbGciOiJI");
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "eyJhbGci") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, result, "line1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\nline3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "secret") == null);
}
