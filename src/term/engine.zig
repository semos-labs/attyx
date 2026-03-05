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

    pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize, scrollback_lines: usize) !Engine {
        return .{
            .state = try TerminalState.init(allocator, rows, cols, scrollback_lines),
        };
    }

    pub fn deinit(self: *Engine) void {
        self.state.deinit();
    }

    /// Feed raw bytes through the parser and apply resulting actions to state.
    pub fn feed(self: *Engine, bytes: []const u8) void {
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
                self.feedOne(byte);
            }
        }
    }

    fn feedOne(self: *Engine, byte: u8) void {
        const action = self.parser.next(byte) orelse return;
        switch (action) {
            .dcs_passthrough => |inner| self.handleDcsPassthrough(inner),
            else => self.state.apply(action),
        }
    }

    /// Re-feed un-doubled tmux DCS passthrough payload through the parser.
    /// The payload lives in apc_buf, so we copy it first since re-feeding
    /// will reuse that buffer for inner APC (kitty graphics) commands.
    fn handleDcsPassthrough(self: *Engine, inner: []const u8) void {
        var buf: [Parser.apc_buf_size]u8 = undefined;
        const n = @min(inner.len, buf.len);
        @memcpy(buf[0..n], inner[0..n]);
        for (buf[0..n]) |b| {
            self.feedOne(b);
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
            self.feedOne(b);
        }
        self.feedOne(byte);
    }
};

// ---------------------------------------------------------------------------
// Smoke test
// ---------------------------------------------------------------------------

test "engine feed produces same result as direct apply" {
    const alloc = std.testing.allocator;
    var e = try Engine.init(alloc, 2, 4, 100);
    defer e.deinit();

    e.feed("Hi");
    try std.testing.expectEqual(@as(u21, 'H'), e.state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), e.state.grid.getCell(0, 1).char);
    try std.testing.expectEqual(@as(usize, 2), e.state.cursor.col);
}

test "literal Ptmux;] artifact is suppressed" {
    const alloc = std.testing.allocator;
    var e = try Engine.init(alloc, 2, 40, 100);
    defer e.deinit();

    e.feed("AB" ++ "Ptmux;]" ++ "CD");
    try std.testing.expectEqual(@as(u21, 'A'), e.state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), e.state.grid.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'C'), e.state.grid.getCell(0, 2).char);
    try std.testing.expectEqual(@as(u21, 'D'), e.state.grid.getCell(0, 3).char);
}

test "Ptmux;] filter works across feed boundaries" {
    const alloc = std.testing.allocator;
    var e = try Engine.init(alloc, 2, 40, 100);
    defer e.deinit();

    e.feed("XPtmu");
    e.feed("x;]Y");
    try std.testing.expectEqual(@as(u21, 'X'), e.state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'Y'), e.state.grid.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), e.state.grid.getCell(0, 2).char);
}

test "partial Ptmux match flushes on mismatch" {
    const alloc = std.testing.allocator;
    var e = try Engine.init(alloc, 2, 40, 100);
    defer e.deinit();

    // "Ptm" doesn't complete the pattern — should be printed.
    e.feed("Ptm!");
    try std.testing.expectEqual(@as(u21, 'P'), e.state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 't'), e.state.grid.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'm'), e.state.grid.getCell(0, 2).char);
    try std.testing.expectEqual(@as(u21, '!'), e.state.grid.getCell(0, 3).char);
}

test "OSC 0 sets window title" {
    const alloc = std.testing.allocator;
    var e = try Engine.init(alloc, 4, 20, 100);
    defer e.deinit();

    // OSC 0 ; title BEL
    e.feed("\x1b]0;hello world\x07");
    try std.testing.expect(e.state.title != null);
    try std.testing.expectEqualStrings("hello world", e.state.title.?);
}

test "OSC 2 sets window title" {
    const alloc = std.testing.allocator;
    var e = try Engine.init(alloc, 4, 20, 100);
    defer e.deinit();

    // OSC 2 ; title ST (ESC \)
    e.feed("\x1b]2;my title\x1b\\");
    try std.testing.expect(e.state.title != null);
    try std.testing.expectEqualStrings("my title", e.state.title.?);
}
