const std = @import("std");
const runner = @import("../runner.zig");

/// Helper: create a terminal, feed input, compare snapshot to expected output.
pub fn expectSnapshot(rows: usize, cols: usize, input: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const snap = try runner.run(alloc, rows, cols, input);
    defer alloc.free(snap);
    try std.testing.expectEqualStrings(expected, snap);
}

/// Helper: feed input as separate chunks, compare snapshot.
pub fn expectChunkedSnapshot(rows: usize, cols: usize, chunks: []const []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const snap = try runner.runChunked(alloc, rows, cols, chunks);
    defer alloc.free(snap);
    try std.testing.expectEqualStrings(expected, snap);
}
