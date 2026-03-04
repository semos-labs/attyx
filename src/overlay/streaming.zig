const std = @import("std");
const overlay = @import("overlay.zig");
const StyledCell = overlay.StyledCell;

// ---------------------------------------------------------------------------
// Streaming state machine
// ---------------------------------------------------------------------------

pub const StreamState = enum(u8) { idle, active, complete };

pub const StreamingOverlay = struct {
    state: StreamState = .idle,
    full_cells: ?[]StyledCell = null, // owned
    full_width: u16 = 0,
    full_height: u16 = 0,
    revealed_height: u16 = 0,
    max_visible_height: u16 = 0, // 0 = no cap (use revealed_height as-is)
    min_height: u16 = 3, // top border + action bar + bottom border
    rows_per_tick: u16 = 2,
    tick_interval_ns: i128 = 40_000_000, // 40ms
    last_tick_ns: i128 = 0,
    col: u16 = 0,
    anchor_bottom_row: u16 = 0, // bottom edge stays fixed here
    user_scroll_back: u16 = 0, // rows scrolled back from latest (0 = follow)
    allocator: std.mem.Allocator,

    /// Begin streaming a pre-laid-out card. Takes ownership of `cells`.
    /// `bottom_row` is the grid row where the bottom border should stay anchored.
    pub fn start(
        self: *StreamingOverlay,
        cells: []StyledCell,
        w: u16,
        h: u16,
        col: u16,
        bottom_row: u16,
        max_vis_h: u16,
        now_ns: i128,
    ) void {
        self.cancel(); // clean up any prior state
        self.full_cells = cells;
        self.full_width = w;
        self.full_height = h;
        self.col = col;
        self.anchor_bottom_row = bottom_row;
        self.max_visible_height = max_vis_h;
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

    /// Compute the top-left row for the overlay (bottom-anchored).
    pub fn topRow(self: *const StreamingOverlay) u16 {
        const vh = self.visibleHeight();
        return if (self.anchor_bottom_row + 1 >= vh)
            self.anchor_bottom_row + 1 - vh
        else
            0;
    }

    /// Effective visible height (capped by max_visible_height).
    fn visibleHeight(self: *const StreamingOverlay) u16 {
        const rh = @min(self.revealed_height, self.full_height);
        if (self.max_visible_height > 0 and rh > self.max_visible_height)
            return self.max_visible_height;
        return rh;
    }

    /// Assemble the currently visible view into `scratch`.
    /// Layout: [top border] + [content rows, possibly scrolled] + [action bar] + [bottom border]
    /// When revealed content exceeds max_visible_height, earlier rows scroll out of view.
    pub fn buildVisibleCells(self: *const StreamingOverlay, scratch: []StyledCell) ?struct { width: u16, height: u16 } {
        const fc = self.full_cells orelse return null;
        if (self.state == .idle) return null;

        const w: usize = self.full_width;
        const fh: usize = self.full_height;
        const vh: usize = self.visibleHeight();

        if (vh < 3 or w == 0) return null;
        const needed = vh * w;
        if (needed > scratch.len) return null;

        // How many content rows are revealed vs how many fit in the visible window
        const revealed_content = @as(usize, @min(self.revealed_height, self.full_height)) -| 3;
        const visible_content = vh -| 3; // rows available for content in the output
        const auto_scroll = revealed_content -| visible_content;
        const scroll_offset = auto_scroll -| @as(usize, @min(self.user_scroll_back, auto_scroll));

        // Top border: row 0 of full_cells
        @memcpy(scratch[0..w], fc[0..w]);

        // Content rows (scrolled window from full_cells)
        if (visible_content > 0) {
            const src_start = (1 + scroll_offset) * w; // row 1 + scroll_offset in full_cells
            const dst_start = w; // row 1 in scratch
            const count = visible_content * w;
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
        self.max_visible_height = 0;
        self.user_scroll_back = 0;
        self.full_width = 0;
        self.full_height = 0;
    }

    /// Adjust scroll position. Positive delta = scroll back (earlier content),
    /// negative = scroll forward (later content). Returns true if position changed.
    pub fn scroll(self: *StreamingOverlay, delta: i16) bool {
        if (self.state == .idle) return false;
        const revealed_content = @as(u16, @min(self.revealed_height, self.full_height)) -| 3;
        const visible_content = self.visibleHeight() -| 3;
        const max_back = revealed_content -| visible_content;

        const old = self.user_scroll_back;
        if (delta > 0) {
            self.user_scroll_back = @min(self.user_scroll_back +| @as(u16, @intCast(delta)), max_back);
        } else if (delta < 0) {
            const abs: u16 = @intCast(-delta);
            self.user_scroll_back = self.user_scroll_back -| abs;
        }
        return self.user_scroll_back != old;
    }

    pub fn isActive(self: *const StreamingOverlay) bool {
        return self.state == .active or self.state == .complete;
    }

    /// Replace the pre-rendered card content. Frees old cells, installs new ones.
    /// Clamps revealed_height if the new card is shorter. If the new card is taller
    /// and state is .active, reveal continues from current position.
    /// Takes ownership of `new_cells`.
    pub fn replaceContent(self: *StreamingOverlay, new_cells: []StyledCell, new_w: u16, new_h: u16) void {
        if (self.full_cells) |old| {
            self.allocator.free(old);
        }
        self.full_cells = new_cells;
        self.full_width = new_w;
        self.full_height = new_h;

        // Clamp revealed height to new card height
        if (self.revealed_height > new_h) {
            self.revealed_height = new_h;
        }

        // If we were complete but new card is taller, re-activate streaming
        if (self.state == .complete and self.revealed_height < new_h) {
            self.state = .active;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "StreamingOverlay: start sets active state" {
    const allocator = std.testing.allocator;
    var so = StreamingOverlay{ .allocator = allocator };
    defer so.cancel();

    const cells = try allocator.alloc(StyledCell, 30); // 10w x 3h
    so.start(cells, 10, 3, 5, 7, 0, 1000); // bottom_row=7, max_vis=0 (no cap)

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
    const cells = try allocator.alloc(StyledCell, @as(usize, w) * h);
    for (cells) |*cell| cell.* = .{};
    so.start(cells, w, h, 0, h - 1, 0, 0);

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

    const cells = try allocator.alloc(StyledCell, 20);
    so.start(cells, 5, 4, 0, 3, 0, 0);
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
    const cells = try allocator.alloc(StyledCell, @as(usize, w) * h);

    // Mark each row with a distinct character
    for (0..h) |r| {
        for (0..w) |cc| {
            cells[r * w + cc] = .{ .char = @intCast(r + 'A') };
        }
    }

    so.start(cells, w, h, 0, h - 1, 0, 0); // bottom_row = 5, no cap

    var scratch: [128]StyledCell = undefined;

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

test "StreamingOverlay: bottom-anchored topRow" {
    const allocator = std.testing.allocator;
    var so = StreamingOverlay{ .allocator = allocator, .rows_per_tick = 1 };
    defer so.cancel();

    const w: u16 = 4;
    const h: u16 = 8;
    const cells = try allocator.alloc(StyledCell, @as(usize, w) * h);
    for (cells) |*cell| cell.* = .{};

    // Anchor bottom at row 20, no height cap
    so.start(cells, w, h, 0, 20, 0, 0);

    // Initially visible = 3 (min_height), so top = 20 - 3 + 1 = 18
    try std.testing.expectEqual(@as(u16, 18), so.topRow());

    // After ticks, visible grows, top moves up
    _ = so.tick(50_000_000);
    try std.testing.expectEqual(@as(u16, 17), so.topRow()); // vis=4, top=17
    _ = so.tick(100_000_000);
    try std.testing.expectEqual(@as(u16, 16), so.topRow()); // vis=5, top=16
}

test "StreamingOverlay: max_visible_height caps and scrolls" {
    const allocator = std.testing.allocator;
    var so = StreamingOverlay{ .allocator = allocator, .rows_per_tick = 2 };
    defer so.cancel();

    const w: u16 = 4;
    const h: u16 = 10; // 10 rows total: border + 7 content + action + border
    const cells = try allocator.alloc(StyledCell, @as(usize, w) * h);

    // Mark each row distinctly
    for (0..h) |r| {
        for (0..w) |cc| {
            cells[r * w + cc] = .{ .char = @intCast(r + 'A') };
        }
    }

    // Cap at 6 rows visible
    so.start(cells, w, h, 0, 20, 6, 0);

    var scratch: [128]StyledCell = undefined;

    // Tick until revealed > max_visible_height
    _ = so.tick(50_000_000); // revealed: 3 -> 5
    _ = so.tick(100_000_000); // revealed: 5 -> 7
    _ = so.tick(150_000_000); // revealed: 7 -> 9

    // revealed=9, but visible capped at 6
    const vis = so.buildVisibleCells(&scratch);
    try std.testing.expect(vis != null);
    try std.testing.expectEqual(@as(u16, 6), vis.?.height);

    // Top row stays anchored: 20 - 6 + 1 = 15
    try std.testing.expectEqual(@as(u16, 15), so.topRow());

    // Content should be scrolled: revealed_content=6, visible_content=3, scroll_offset=3
    // So content rows are from full_cells rows 4,5,6 (E,F,G)
    // scratch: [A] [E] [F] [G] [I] [J]
    try std.testing.expectEqual(@as(u21, 'A'), scratch[0].char); // top border
    try std.testing.expectEqual(@as(u21, 'E'), scratch[1 * w].char); // scrolled content
    try std.testing.expectEqual(@as(u21, 'F'), scratch[2 * w].char);
    try std.testing.expectEqual(@as(u21, 'G'), scratch[3 * w].char);
    try std.testing.expectEqual(@as(u21, 'I'), scratch[4 * w].char); // action bar
    try std.testing.expectEqual(@as(u21, 'J'), scratch[5 * w].char); // bottom border
}

test "StreamingOverlay: timing interval respected" {
    const allocator = std.testing.allocator;
    var so = StreamingOverlay{ .allocator = allocator, .rows_per_tick = 1, .tick_interval_ns = 100 };
    defer so.cancel();

    const cells = try allocator.alloc(StyledCell, 50);
    for (cells) |*cell| cell.* = .{};
    so.start(cells, 5, 10, 0, 9, 0, 0);

    // At t=50, too early
    try std.testing.expect(!so.tick(50));
    try std.testing.expectEqual(@as(u16, 3), so.revealed_height);

    // At t=100, should advance
    try std.testing.expect(so.tick(100));
    try std.testing.expectEqual(@as(u16, 4), so.revealed_height);
}

test "StreamingOverlay: replaceContent preserves reveal" {
    const allocator = std.testing.allocator;
    var so = StreamingOverlay{ .allocator = allocator, .rows_per_tick = 2 };
    defer so.cancel();

    const cells = try allocator.alloc(StyledCell, 30); // 5w x 6h
    for (cells) |*cell| cell.* = .{};
    so.start(cells, 5, 6, 0, 10, 0, 0);

    // Advance reveal
    _ = so.tick(50_000_000);
    try std.testing.expectEqual(@as(u16, 5), so.revealed_height); // 3 + 2

    // Replace with taller card — should re-activate
    const new_cells = try allocator.alloc(StyledCell, 50); // 5w x 10h
    for (new_cells) |*cell| cell.* = .{};
    so.replaceContent(new_cells, 5, 10);

    try std.testing.expectEqual(@as(u16, 5), so.revealed_height); // preserved
    try std.testing.expectEqual(StreamState.active, so.state); // re-activated
    try std.testing.expectEqual(@as(u16, 10), so.full_height);
}

test "StreamingOverlay: replaceContent clamps on shorter card" {
    const allocator = std.testing.allocator;
    var so = StreamingOverlay{ .allocator = allocator, .rows_per_tick = 10 };
    defer so.cancel();

    const cells = try allocator.alloc(StyledCell, 50); // 5w x 10h
    for (cells) |*cell| cell.* = .{};
    so.start(cells, 5, 10, 0, 10, 0, 0);

    // Reveal everything
    _ = so.tick(50_000_000);
    try std.testing.expectEqual(StreamState.complete, so.state);

    // Replace with shorter card
    const new_cells = try allocator.alloc(StyledCell, 20); // 5w x 4h
    for (new_cells) |*cell| cell.* = .{};
    so.replaceContent(new_cells, 5, 4);

    try std.testing.expectEqual(@as(u16, 4), so.revealed_height); // clamped
    try std.testing.expectEqual(@as(u16, 4), so.full_height);
}
