//! Pure formatting helpers for the dashboard: humanize token counts, cost,
//! context, and durations. Each writes into a caller buffer and returns a slice.
const std = @import("std");

const dash = "\xe2\x80\x94"; // —

/// `1.2M`, `842K`, `500`.
pub fn tokens(buf: []u8, n: u64) []const u8 {
    if (n >= 1_000_000) {
        const m = @as(f64, @floatFromInt(n)) / 1_000_000.0;
        return std.fmt.bufPrint(buf, "{d:.1}M", .{m}) catch buf[0..0];
    } else if (n >= 1_000) {
        return std.fmt.bufPrint(buf, "{d}K", .{n / 1000}) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch buf[0..0];
}

/// `1.2M` or `—` for null.
pub fn tokensOpt(buf: []u8, n: ?u64) []const u8 {
    return if (n) |v| tokens(buf, v) else dash;
}

/// `$0.42`, `~$0.31` (estimate), or `—`.
pub fn cost(buf: []u8, c: ?f64, estimate: bool) []const u8 {
    if (c) |v| return std.fmt.bufPrint(buf, "{s}${d:.2}", .{ if (estimate) "~" else "", v }) catch buf[0..0];
    return dash;
}

/// `82K/200K`, `82K`, or `—`.
pub fn ctx(buf: []u8, used: ?u64, max: ?u64) []const u8 {
    if (used) |u| {
        var ub: [16]u8 = undefined;
        const us = tokens(&ub, u);
        if (max) |mx| {
            var mb: [16]u8 = undefined;
            return std.fmt.bufPrint(buf, "{s}/{s}", .{ us, tokens(&mb, mx) }) catch buf[0..0];
        }
        return std.fmt.bufPrint(buf, "{s}", .{us}) catch buf[0..0];
    }
    return dash;
}

/// Humanize a duration in seconds: `18s`, `1m12s`, `2h3m`.
pub fn duration(buf: []u8, secs: u64) []const u8 {
    if (secs < 60) return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch buf[0..0];
    if (secs < 3600) {
        return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ secs / 60, secs % 60 }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d}h{d:0>2}m", .{ secs / 3600, (secs % 3600) / 60 }) catch buf[0..0];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "tokens humanization" {
    var b: [16]u8 = undefined;
    try testing.expectEqualStrings("500", tokens(&b, 500));
    try testing.expectEqualStrings("1K", tokens(&b, 1234));
    try testing.expectEqualStrings("842K", tokens(&b, 842_000));
    try testing.expectEqualStrings("1.6M", tokens(&b, 1_600_000));
    try testing.expectEqualStrings("\xe2\x80\x94", tokensOpt(&b, null));
}

test "cost formatting" {
    var b: [16]u8 = undefined;
    try testing.expectEqualStrings("$0.42", cost(&b, 0.4213, false));
    try testing.expectEqualStrings("~$0.31", cost(&b, 0.31, true));
    try testing.expectEqualStrings("\xe2\x80\x94", cost(&b, null, false));
}

test "ctx and duration" {
    var b: [24]u8 = undefined;
    try testing.expectEqualStrings("82K/200K", ctx(&b, 82_000, 200_000));
    try testing.expectEqualStrings("\xe2\x80\x94", ctx(&b, null, null));
    try testing.expectEqualStrings("18s", duration(&b, 18));
    try testing.expectEqualStrings("1m12s", duration(&b, 72));
    try testing.expectEqualStrings("2h03m", duration(&b, 7380));
}
