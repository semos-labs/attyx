const std = @import("std");

/// Row-level damage bitset for tracking which rows need re-rendering.
/// Fixed capacity of 256 rows (4 x u64), zero allocations.
pub const DirtyRows = struct {
    pub const max_rows = 256;

    bits: [4]u64 = .{ 0, 0, 0, 0 },

    pub fn mark(self: *DirtyRows, row: usize) void {
        if (row >= max_rows) return;
        self.bits[row >> 6] |= @as(u64, 1) << @intCast(row & 63);
    }

    pub fn markRange(self: *DirtyRows, top: usize, bottom: usize) void {
        if (top > bottom) return;
        const t = @min(top, max_rows - 1);
        const b = @min(bottom, max_rows - 1);
        for (t..b + 1) |row| self.mark(row);
    }

    pub fn markAll(self: *DirtyRows, rows: usize) void {
        if (rows == 0) return;
        const n = @min(rows, max_rows);
        // Fill complete u64 words
        const full_words = n >> 6;
        for (0..full_words) |i| self.bits[i] = ~@as(u64, 0);
        // Partial trailing word
        const rem: u6 = @intCast(n & 63);
        if (rem > 0 and full_words < 4) {
            self.bits[full_words] = (@as(u64, 1) << rem) -% 1;
        }
    }

    pub fn isDirty(self: *const DirtyRows, row: usize) bool {
        if (row >= max_rows) return false;
        return (self.bits[row >> 6] & (@as(u64, 1) << @intCast(row & 63))) != 0;
    }

    pub fn any(self: *const DirtyRows) bool {
        return (self.bits[0] | self.bits[1] | self.bits[2] | self.bits[3]) != 0;
    }

    pub fn clear(self: *DirtyRows) void {
        self.bits = .{ 0, 0, 0, 0 };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "mark single row" {
    var d = DirtyRows{};
    d.mark(5);
    try std.testing.expect(d.isDirty(5));
    try std.testing.expect(!d.isDirty(4));
    try std.testing.expect(!d.isDirty(6));
}

test "mark preserves existing bits" {
    var d = DirtyRows{};
    d.mark(0);
    d.mark(63);
    d.mark(64);
    try std.testing.expect(d.isDirty(0));
    try std.testing.expect(d.isDirty(63));
    try std.testing.expect(d.isDirty(64));
}

test "markRange inclusive" {
    var d = DirtyRows{};
    d.markRange(3, 7);
    try std.testing.expect(!d.isDirty(2));
    for (3..8) |r| try std.testing.expect(d.isDirty(r));
    try std.testing.expect(!d.isDirty(8));
}

test "markRange across word boundary" {
    var d = DirtyRows{};
    d.markRange(60, 68);
    for (60..69) |r| try std.testing.expect(d.isDirty(r));
    try std.testing.expect(!d.isDirty(59));
    try std.testing.expect(!d.isDirty(69));
}

test "markAll partial word" {
    var d = DirtyRows{};
    d.markAll(24);
    for (0..24) |r| try std.testing.expect(d.isDirty(r));
    try std.testing.expect(!d.isDirty(24));
}

test "markAll full word boundary" {
    var d = DirtyRows{};
    d.markAll(64);
    for (0..64) |r| try std.testing.expect(d.isDirty(r));
    try std.testing.expect(!d.isDirty(64));
}

test "markAll 256 fills everything" {
    var d = DirtyRows{};
    d.markAll(256);
    for (0..256) |r| try std.testing.expect(d.isDirty(r));
}

test "any returns false on clean" {
    const d = DirtyRows{};
    try std.testing.expect(!d.any());
}

test "any returns true when dirty" {
    var d = DirtyRows{};
    d.mark(200);
    try std.testing.expect(d.any());
}

test "clear resets all bits" {
    var d = DirtyRows{};
    d.markAll(256);
    d.clear();
    try std.testing.expect(!d.any());
}

test "out-of-range row is silently ignored" {
    var d = DirtyRows{};
    d.mark(300);
    try std.testing.expect(!d.any());
    try std.testing.expect(!d.isDirty(300));
}
