const std = @import("std");
const parser_mod = @import("parser.zig");
const state_mod = @import("state.zig");

pub const Parser = parser_mod.Parser;
pub const TerminalState = state_mod.TerminalState;

/// High-level terminal engine that connects a Parser and TerminalState.
///
/// Owns both the parser (stateless, no alloc) and the terminal state
/// (owns the grid allocation). Provides a `feed(bytes)` API identical
/// to the old TerminalState.feed — callers don't need to think about
/// Actions or parsing.
pub const Engine = struct {
    parser: Parser = .{},
    state: TerminalState,

    pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !Engine {
        return .{
            .state = try TerminalState.init(allocator, rows, cols),
        };
    }

    pub fn deinit(self: *Engine) void {
        self.state.deinit();
    }

    /// Feed raw bytes through the parser and apply resulting actions to state.
    pub fn feed(self: *Engine, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.parser.next(byte)) |action| {
                self.state.apply(action);
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Smoke test
// ---------------------------------------------------------------------------

test "engine feed produces same result as direct apply" {
    const alloc = std.testing.allocator;
    var e = try Engine.init(alloc, 2, 4);
    defer e.deinit();

    e.feed("Hi");
    try std.testing.expectEqual(@as(u21, 'H'), e.state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), e.state.grid.getCell(0, 1).char);
    try std.testing.expectEqual(@as(usize, 2), e.state.cursor.col);
}
