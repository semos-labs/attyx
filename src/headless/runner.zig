const std = @import("std");
const Engine = @import("../term/engine.zig").Engine;
const Scrollback = @import("../term/scrollback.zig").Scrollback;
const snapshot = @import("../term/snapshot.zig");

/// Create a terminal, feed all input at once, return snapshot string.
/// Caller owns the returned slice.
pub fn run(allocator: std.mem.Allocator, rows: usize, cols: usize, input: []const u8) ![]u8 {
    var engine = try Engine.init(allocator, rows, cols, Scrollback.default_max_lines);
    defer engine.deinit();
    engine.feed(input);
    return snapshot.dumpToString(allocator, &engine.state.grid);
}

/// Create a terminal, feed input as separate chunks, return snapshot string.
/// This tests that the parser handles sequences split across chunk boundaries.
pub fn runChunked(allocator: std.mem.Allocator, rows: usize, cols: usize, chunks: []const []const u8) ![]u8 {
    var engine = try Engine.init(allocator, rows, cols, Scrollback.default_max_lines);
    defer engine.deinit();
    for (chunks) |chunk| {
        engine.feed(chunk);
    }
    return snapshot.dumpToString(allocator, &engine.state.grid);
}

// ---------------------------------------------------------------------------
// Smoke test
// ---------------------------------------------------------------------------

test "runner produces expected snapshot" {
    const alloc = std.testing.allocator;
    const snap = try run(alloc, 2, 4, "Hi");
    defer alloc.free(snap);
    try std.testing.expectEqualStrings("Hi  \n    \n", snap);
}

test "runChunked same result as single feed" {
    const alloc = std.testing.allocator;
    const snap = try runChunked(alloc, 2, 4, &.{ "H", "i" });
    defer alloc.free(snap);
    try std.testing.expectEqualStrings("Hi  \n    \n", snap);
}
