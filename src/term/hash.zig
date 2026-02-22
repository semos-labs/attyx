const std = @import("std");
const grid_mod = @import("grid.zig");
const state_mod = @import("state.zig");

/// Compute a stable 64-bit hash of the visible terminal state.
///
/// Covers: active buffer flag, cursor position, and every cell's
/// character + style attributes. Used to detect whether the screen
/// changed between frames (snapshot gating).
///
/// Pure function — no allocations, no side effects.
pub fn hash(st: *const state_mod.TerminalState) u64 {
    var h = std.hash.Fnv1a_64.init();

    h.update(std.mem.asBytes(&st.alt_active));
    h.update(std.mem.asBytes(&st.cursor.row));
    h.update(std.mem.asBytes(&st.cursor.col));

    for (st.grid.cells) |cell| {
        h.update(std.mem.asBytes(&cell.char));
        h.update(std.mem.asBytes(&cell.style));
    }

    return h.final();
}

test "identical states produce same hash" {
    const alloc = std.testing.allocator;
    var s1 = try state_mod.TerminalState.init(alloc, 4, 6);
    defer s1.deinit();
    var s2 = try state_mod.TerminalState.init(alloc, 4, 6);
    defer s2.deinit();

    try std.testing.expectEqual(hash(&s1), hash(&s2));
}

test "different content produces different hash" {
    const alloc = std.testing.allocator;
    var s1 = try state_mod.TerminalState.init(alloc, 4, 6);
    defer s1.deinit();
    var s2 = try state_mod.TerminalState.init(alloc, 4, 6);
    defer s2.deinit();

    s2.grid.setCell(0, 0, .{ .char = 'X' });

    try std.testing.expect(hash(&s1) != hash(&s2));
}

test "cursor move changes hash" {
    const alloc = std.testing.allocator;
    var s1 = try state_mod.TerminalState.init(alloc, 4, 6);
    defer s1.deinit();
    var s2 = try state_mod.TerminalState.init(alloc, 4, 6);
    defer s2.deinit();

    s2.cursor.col = 3;

    try std.testing.expect(hash(&s1) != hash(&s2));
}
