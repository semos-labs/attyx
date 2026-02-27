const std = @import("std");
const overlay = @import("overlay.zig");
const OverlayCell = overlay.OverlayCell;

// ---------------------------------------------------------------------------
// Streaming state machine
// ---------------------------------------------------------------------------

pub const StreamState = enum(u8) { idle, active, complete };

pub const StreamingOverlay = struct {
    state: StreamState = .idle,
    full_cells: ?[]OverlayCell = null, // owned
    full_width: u16 = 0,
    full_height: u16 = 0,
    revealed_height: u16 = 0,
    min_height: u16 = 3, // top border + action bar + bottom border
    rows_per_tick: u16 = 2,
    tick_interval_ns: i128 = 40_000_000, // 40ms
    last_tick_ns: i128 = 0,
    col: u16 = 0,
    row: u16 = 0,
    allocator: std.mem.Allocator,

    /// Begin streaming a pre-laid-out card. Takes ownership of `cells`.
    pub fn start(
        self: *StreamingOverlay,
        cells: []OverlayCell,
        w: u16,
        h: u16,
        col: u16,
        row_pos: u16,
        now_ns: i128,
    ) void {
        self.cancel(); // clean up any prior state
        self.full_cells = cells;
        self.full_width = w;
        self.full_height = h;
        self.col = col;
        self.row = row_pos;
        self.revealed_height = self.min_height;
        self.last_tick_ns = now_ns;
        self.state = .active;
    }

    /// Advance the reveal by `rows_per_tick` if enough time has elapsed.
    /// Returns true if the visible height changed this call.
    pub fn tick(self: *StreamingOverlay, now_ns: i128) bool {
        if (self.state != .active) return false;

        const elapsed = now_ns - self.last_tick_ns;
        if (elapsed < self.tick_interval_ns) return false;

        self.last_tick_ns = now_ns;

        if (self.revealed_height >= self.full_height) {
            self.state = .complete;
            return false;
        }

        const remaining = self.full_height - self.revealed_height;
        const advance = @min(self.rows_per_tick, remaining);
        self.revealed_height += advance;

        if (self.revealed_height >= self.full_height) {
            self.state = .complete;
        }

        return true;
    }

    /// Assemble the currently visible view into `scratch`.
    /// Layout: [top border row] + [content rows 0..n] + [action bar row] + [bottom border row]
    /// The action bar and bottom border are always the last two rows of `full_cells`.
    /// Returns the visible {width, height} or null if not active.
    pub fn buildVisibleCells(self: *const StreamingOverlay, scratch: []OverlayCell) ?struct { width: u16, height: u16 } {
        const fc = self.full_cells orelse return null;
        if (self.state == .idle) return null;

        const w: usize = self.full_width;
        const fh: usize = self.full_height;
        const vh: usize = @min(self.revealed_height, self.full_height);

        if (vh < 3 or w == 0) return null;
        const needed = vh * w;
        if (needed > scratch.len) return null;

        // Top border: row 0 of full_cells
        @memcpy(scratch[0..w], fc[0..w]);

        // Content rows: rows 1..(vh-2) from full_cells
        if (vh > 3) {
            const content_rows = vh - 3; // exclude top border, action bar, bottom border
            const src_start = w; // row 1 in full_cells
            const dst_start = w; // row 1 in scratch
            const count = content_rows * w;
            @memcpy(scratch[dst_start .. dst_start + count], fc[src_start .. src_start + count]);
        }

        // Action bar row: second-to-last row of full_cells → placed at vh-2 in scratch
        {
            const src_row = fh - 2;
            const dst_row = vh - 2;
            @memcpy(scratch[dst_row * w .. (dst_row + 1) * w], fc[src_row * w .. (src_row + 1) * w]);
        }

        // Bottom border row: last row of full_cells → placed at vh-1 in scratch
        {
            const src_row = fh - 1;
            const dst_row = vh - 1;
            @memcpy(scratch[dst_row * w .. (dst_row + 1) * w], fc[src_row * w .. (src_row + 1) * w]);
        }

        return .{ .width = @intCast(w), .height = @intCast(vh) };
    }

    /// Free owned cells and reset to idle. Safe to call at any time.
    pub fn cancel(self: *StreamingOverlay) void {
        if (self.full_cells) |fc| {
            self.allocator.free(fc);
        }
        self.full_cells = null;
        self.state = .idle;
        self.revealed_height = 0;
        self.full_width = 0;
        self.full_height = 0;
    }

    pub fn isActive(self: *const StreamingOverlay) bool {
        return self.state == .active or self.state == .complete;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "StreamingOverlay: start sets active state" {
    const allocator = std.testing.allocator;
    var so = StreamingOverlay{ .allocator = allocator };
    defer so.cancel();

    const cells = try allocator.alloc(OverlayCell, 30); // 10w x 3h
    so.start(cells, 10, 3, 5, 5, 1000);

    try std.testing.expectEqual(StreamState.active, so.state);
    try std.testing.expectEqual(@as(u16, 3), so.revealed_height); // min_height
    try std.testing.expectEqual(@as(u16, 10), so.full_width);
    try std.testing.expectEqual(@as(u16, 3), so.full_height);
}

test "StreamingOverlay: tick advances revealed_height" {
    const allocator = std.testing.allocator;
    var so = StreamingOverlay{ .allocator = allocator, .rows_per_tick = 1 };
    defer so.cancel();

    const h: u16 = 8;
    const w: u16 = 5;
    const cells = try allocator.alloc(OverlayCell, @as(usize, w) * h);
    for (cells) |*cell| cell.* = .{};
    so.start(cells, w, h, 0, 0, 0);

    // First tick — too early
    try std.testing.expect(!so.tick(10));

    // After interval
    try std.testing.expect(so.tick(50_000_000));
    try std.testing.expectEqual(@as(u16, 4), so.revealed_height); // 3 + 1

    // Several more ticks
    _ = so.tick(100_000_000);
    _ = so.tick(150_000_000);
    _ = so.tick(200_000_000);
    _ = so.tick(250_000_000);

    try std.testing.expectEqual(StreamState.complete, so.state);
    try std.testing.expectEqual(h, so.revealed_height);
}

test "StreamingOverlay: cancel resets to idle" {
    const allocator = std.testing.allocator;
    var so = StreamingOverlay{ .allocator = allocator };

    const cells = try allocator.alloc(OverlayCell, 20);
    so.start(cells, 5, 4, 0, 0, 0);
    try std.testing.expectEqual(StreamState.active, so.state);

    so.cancel();
    try std.testing.expectEqual(StreamState.idle, so.state);
    try std.testing.expect(so.full_cells == null);
}

test "StreamingOverlay: cancel when idle is safe" {
    const allocator = std.testing.allocator;
    var so = StreamingOverlay{ .allocator = allocator };
    so.cancel(); // should not crash
    try std.testing.expectEqual(StreamState.idle, so.state);
}

test "StreamingOverlay: buildVisibleCells correctness" {
    const allocator = std.testing.allocator;
    var so = StreamingOverlay{ .allocator = allocator, .rows_per_tick = 1 };
    defer so.cancel();

    const w: u16 = 4;
    const h: u16 = 6;
    const cells = try allocator.alloc(OverlayCell, @as(usize, w) * h);

    // Mark each row with a distinct character
    for (0..h) |r| {
        for (0..w) |cc| {
            cells[r * w + cc] = .{ .char = @intCast(r + 'A') };
        }
    }

    so.start(cells, w, h, 0, 0, 0);

    var scratch: [128]OverlayCell = undefined;

    // Initially revealed_height = 3 (min_height)
    const v1 = so.buildVisibleCells(&scratch);
    try std.testing.expect(v1 != null);
    try std.testing.expectEqual(@as(u16, 3), v1.?.height);

    // Row 0 = top border (row 'A'=65 from full)
    try std.testing.expectEqual(@as(u21, 'A'), scratch[0].char);
    // Row 1 = action bar (second-to-last of full = row 4 = 'E')
    try std.testing.expectEqual(@as(u21, 'E'), scratch[1 * w].char);
    // Row 2 = bottom border (last of full = row 5 = 'F')
    try std.testing.expectEqual(@as(u21, 'F'), scratch[2 * w].char);

    // Tick to reveal 1 more content row
    _ = so.tick(50_000_000);
    const v2 = so.buildVisibleCells(&scratch);
    try std.testing.expect(v2 != null);
    try std.testing.expectEqual(@as(u16, 4), v2.?.height);

    // Row 0 = top border (A), Row 1 = content row 1 (B),
    // Row 2 = action bar (E), Row 3 = bottom border (F)
    try std.testing.expectEqual(@as(u21, 'A'), scratch[0].char);
    try std.testing.expectEqual(@as(u21, 'B'), scratch[1 * w].char);
    try std.testing.expectEqual(@as(u21, 'E'), scratch[2 * w].char);
    try std.testing.expectEqual(@as(u21, 'F'), scratch[3 * w].char);
}

test "StreamingOverlay: timing interval respected" {
    const allocator = std.testing.allocator;
    var so = StreamingOverlay{ .allocator = allocator, .rows_per_tick = 1, .tick_interval_ns = 100 };
    defer so.cancel();

    const cells = try allocator.alloc(OverlayCell, 50);
    for (cells) |*cell| cell.* = .{};
    so.start(cells, 5, 10, 0, 0, 0);

    // At t=50, too early
    try std.testing.expect(!so.tick(50));
    try std.testing.expectEqual(@as(u16, 3), so.revealed_height);

    // At t=100, should advance
    try std.testing.expect(so.tick(100));
    try std.testing.expectEqual(@as(u16, 4), so.revealed_height);
}
