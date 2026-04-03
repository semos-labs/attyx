const std = @import("std");

pub const TargetedRename = struct {
    tab_idx: u8,
    name: []const u8,
};

pub fn parseActivePayload(payload: []const u8) ![]const u8 {
    if (payload.len == 0) return error.MissingTabTitle;
    return payload;
}

pub fn parseTargetedPayload(payload: []const u8) !TargetedRename {
    if (payload.len == 0) return error.MissingTabIndex;
    if (payload.len == 1) return error.MissingTabTitle;
    return .{
        .tab_idx = payload[0],
        .name = payload[1..],
    };
}

test "parseActivePayload requires a non-empty title" {
    try std.testing.expectError(error.MissingTabTitle, parseActivePayload(""));
    try std.testing.expectEqualStrings("editor", try parseActivePayload("editor"));
}

test "parseTargetedPayload requires both tab index and title" {
    try std.testing.expectError(error.MissingTabIndex, parseTargetedPayload(""));
    try std.testing.expectError(error.MissingTabTitle, parseTargetedPayload(&.{1}));

    const parsed = try parseTargetedPayload(&.{ 3, 'l', 'o', 'g', 's' });
    try std.testing.expectEqual(@as(u8, 3), parsed.tab_idx);
    try std.testing.expectEqualStrings("logs", parsed.name);
}
