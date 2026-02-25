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

    /// Tracks how many bytes of the literal "Ptmux;]" pattern we've
    /// matched so far.  tmux can render this artifact as plain text
    /// when passthrough sequences are mangled (ESC bytes stripped).
    tmux_match: u4 = 0,

    const tmux_artifact = "Ptmux;]";

    pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !Engine {
        return .{
            .state = try TerminalState.init(allocator, rows, cols),
        };
    }

    pub fn deinit(self: *Engine) void {
        self.state.deinit();
    }

    // Debug: scan for ESC _ (APC introducer) in input bytes
    fn dbgScanApc(bytes: []const u8) void {
        var i: usize = 0;
        while (i + 1 < bytes.len) : (i += 1) {
            if (bytes[i] == 0x1B and bytes[i + 1] == '_') {
                dbgLogEngine("[engine] ESC_ found at offset {d}/{d}, next bytes: {x:0>2} {x:0>2}", .{
                    i, bytes.len,
                    if (i + 2 < bytes.len) bytes[i + 2] else @as(u8, 0),
                    if (i + 3 < bytes.len) bytes[i + 3] else @as(u8, 0),
                });
            }
        }
    }

    fn dbgLogEngine(comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
        const file = std.posix.open("/tmp/attyx_gfx_debug.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch return;
        defer std.posix.close(file);
        _ = std.posix.write(file, msg) catch {};
    }

    /// Feed raw bytes through the parser and apply resulting actions to state.
    pub fn feed(self: *Engine, bytes: []const u8) void {
        dbgScanApc(bytes);
        for (bytes) |byte| {
            // Only try to match the artifact when we're already
            // mid-match, or when a fresh 'P' arrives while the
            // parser is in ground state (the only state where
            // bytes would be printed as visible text).
            if (self.tmux_match > 0 or
                (byte == tmux_artifact[0] and self.parser.state == .ground))
            {
                self.feedFiltered(byte);
            } else {
                if (self.parser.next(byte)) |action| {
                    self.state.apply(action);
                }
            }
        }
    }

    /// Byte-level state machine that detects the literal text "Ptmux;]"
    /// (a known tmux rendering artifact) and suppresses it.  If the
    /// match fails partway, the buffered bytes are flushed through the
    /// parser so nothing is lost.
    fn feedFiltered(self: *Engine, byte: u8) void {
        const idx: usize = self.tmux_match;
        if (byte == tmux_artifact[idx]) {
            self.tmux_match += 1;
            if (self.tmux_match == tmux_artifact.len) {
                self.tmux_match = 0;
            }
            return;
        }
        // Partial match failed — flush the buffered prefix bytes
        // through the parser, then process the current byte.
        const buffered = self.tmux_match;
        self.tmux_match = 0;
        for (tmux_artifact[0..buffered]) |b| {
            if (self.parser.next(b)) |action| {
                self.state.apply(action);
            }
        }
        if (self.parser.next(byte)) |action| {
            self.state.apply(action);
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

test "literal Ptmux;] artifact is suppressed" {
    const alloc = std.testing.allocator;
    var e = try Engine.init(alloc, 2, 40);
    defer e.deinit();

    e.feed("AB" ++ "Ptmux;]" ++ "CD");
    try std.testing.expectEqual(@as(u21, 'A'), e.state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), e.state.grid.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'C'), e.state.grid.getCell(0, 2).char);
    try std.testing.expectEqual(@as(u21, 'D'), e.state.grid.getCell(0, 3).char);
}

test "Ptmux;] filter works across feed boundaries" {
    const alloc = std.testing.allocator;
    var e = try Engine.init(alloc, 2, 40);
    defer e.deinit();

    e.feed("XPtmu");
    e.feed("x;]Y");
    try std.testing.expectEqual(@as(u21, 'X'), e.state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'Y'), e.state.grid.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), e.state.grid.getCell(0, 2).char);
}

test "partial Ptmux match flushes on mismatch" {
    const alloc = std.testing.allocator;
    var e = try Engine.init(alloc, 2, 40);
    defer e.deinit();

    // "Ptm" doesn't complete the pattern — should be printed.
    e.feed("Ptm!");
    try std.testing.expectEqual(@as(u21, 'P'), e.state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 't'), e.state.grid.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'm'), e.state.grid.getCell(0, 2).char);
    try std.testing.expectEqual(@as(u21, '!'), e.state.grid.getCell(0, 3).char);
}
