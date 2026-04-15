const std = @import("std");
const grid_mod = @import("grid.zig");

pub const Cell = grid_mod.Cell;
pub const isDefaultCell = grid_mod.isDefaultCell;

/// Unified ring buffer storing all terminal rows (scrollback + visible screen).
/// The visible screen is a window at the tail of the ring. "Scrolling into
/// scrollback" means advancing the window — no copy.
pub const RingBuffer = struct {
    cells: []Cell,
    wrapped: []bool,
    cols: usize,
    capacity: usize, // total row slots (screen_rows + max_scrollback)
    screen_rows: usize, // visible rows (viewport height)
    head: usize, // ring slot of oldest row
    count: usize, // total rows written (≤ capacity)
    allocator: std.mem.Allocator,

    pub const default_max_scrollback: usize = 5_000;

    pub fn init(
        allocator: std.mem.Allocator,
        screen_rows: usize,
        cols: usize,
        max_scrollback: usize,
    ) !RingBuffer {
        std.debug.assert(screen_rows > 0 and cols > 0);
        const capacity = screen_rows + max_scrollback;
        const cells = try allocator.alloc(Cell, capacity * cols);
        @memset(cells, Cell{});
        const wrapped = try allocator.alloc(bool, capacity);
        errdefer allocator.free(cells);
        @memset(wrapped, false);
        return .{
            .cells = cells,
            .wrapped = wrapped,
            .cols = cols,
            .capacity = capacity,
            .screen_rows = screen_rows,
            .head = 0,
            .count = screen_rows, // screen starts with screen_rows blank rows
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RingBuffer) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.wrapped);
    }

    /// Change scrollback capacity, preserving newest content.
    /// Screen rows are unchanged; only the max scrollback depth changes.
    pub fn resizeScrollback(self: *RingBuffer, new_max_scrollback: usize) !void {
        const new_cap = self.screen_rows + new_max_scrollback;
        if (new_cap == self.capacity) return;

        const new_cells = try self.allocator.alloc(Cell, new_cap * self.cols);
        @memset(new_cells, Cell{});
        const new_wrapped = try self.allocator.alloc(bool, new_cap);
        errdefer self.allocator.free(new_cells);
        @memset(new_wrapped, false);

        // Copy newest rows that fit into the new capacity.
        const rows_to_keep = @min(self.count, new_cap);
        const skip = self.count - rows_to_keep;
        for (0..rows_to_keep) |i| {
            const src_slot = self.ringSlot(skip + i);
            const src_off = src_slot * self.cols;
            const dst_off = i * self.cols;
            @memcpy(new_cells[dst_off..][0..self.cols], self.cells[src_off..][0..self.cols]);
            new_wrapped[i] = self.wrapped[src_slot];
        }

        self.allocator.free(self.cells);
        self.allocator.free(self.wrapped);
        self.cells = new_cells;
        self.wrapped = new_wrapped;
        self.capacity = new_cap;
        self.count = rows_to_keep;
        self.head = 0;
    }

    // -- Row addressing --

    /// Number of scrollback rows (rows above the visible screen).
    pub fn scrollbackCount(self: *const RingBuffer) usize {
        return if (self.count > self.screen_rows) self.count - self.screen_rows else 0;
    }

    /// Ring slot for absolute row `i` (0 = oldest).
    fn ringSlot(self: *const RingBuffer, abs: usize) usize {
        return (self.head + abs) % self.capacity;
    }

    /// Get a row slice by absolute index (0 = oldest stored row).
    pub fn getRow(self: *const RingBuffer, abs: usize) []const Cell {
        std.debug.assert(abs < self.count);
        const slot = self.ringSlot(abs);
        const offset = slot * self.cols;
        return self.cells[offset .. offset + self.cols];
    }

    /// Get a mutable row slice by absolute index.
    pub fn getRowMut(self: *RingBuffer, abs: usize) []Cell {
        std.debug.assert(abs < self.count);
        const slot = self.ringSlot(abs);
        const offset = slot * self.cols;
        return self.cells[offset .. offset + self.cols];
    }

    /// Get wrapped flag by absolute index.
    pub fn getWrapped(self: *const RingBuffer, abs: usize) bool {
        std.debug.assert(abs < self.count);
        return self.wrapped[self.ringSlot(abs)];
    }

    /// Set wrapped flag by absolute index.
    pub fn setWrapped(self: *RingBuffer, abs: usize, val: bool) void {
        std.debug.assert(abs < self.count);
        self.wrapped[self.ringSlot(abs)] = val;
    }

    // -- Screen row access (row 0 = top of visible screen) --

    /// Absolute index of screen row `r`.
    pub fn screenAbsRow(self: *const RingBuffer, r: usize) usize {
        return self.scrollbackCount() + r;
    }

    pub fn getScreenCell(self: *const RingBuffer, row: usize, col: usize) Cell {
        const abs = self.screenAbsRow(row);
        const slot = self.ringSlot(abs);
        return self.cells[slot * self.cols + col];
    }

    pub fn setScreenCell(self: *RingBuffer, row: usize, col: usize, cell: Cell) void {
        const abs = self.screenAbsRow(row);
        const slot = self.ringSlot(abs);
        self.cells[slot * self.cols + col] = cell;
    }

    /// Get a const slice for screen row `r`.
    pub fn getScreenRow(self: *const RingBuffer, r: usize) []const Cell {
        return self.getRow(self.screenAbsRow(r));
    }

    /// Get a mutable slice for screen row `r`.
    pub fn getScreenRowMut(self: *RingBuffer, r: usize) []Cell {
        return self.getRowMut(self.screenAbsRow(r));
    }

    /// Get screen row wrapped flag.
    pub fn getScreenWrapped(self: *const RingBuffer, r: usize) bool {
        return self.getWrapped(self.screenAbsRow(r));
    }

    /// Set screen row wrapped flag.
    pub fn setScreenWrapped(self: *RingBuffer, r: usize, val: bool) void {
        self.setWrapped(self.screenAbsRow(r), val);
    }

    /// Clear a screen row to default cells.
    pub fn clearScreenRow(self: *RingBuffer, r: usize) void {
        const row_cells = self.getScreenRowMut(r);
        @memset(row_cells, Cell{});
        self.setScreenWrapped(r, false);
    }

    // -- Viewport access --

    /// Get a row for viewport rendering.
    /// viewport_offset=0 → screen row r. viewport_offset>0 → scroll into scrollback.
    pub fn viewportRow(self: *const RingBuffer, viewport_offset: usize, r: usize) []const Cell {
        const sb = self.scrollbackCount();
        const effective_vp = @min(viewport_offset, sb);
        const abs = sb - effective_vp + r;
        return self.getRow(abs);
    }

    /// Get wrapped flag for a viewport row.
    pub fn viewportRowWrapped(self: *const RingBuffer, viewport_offset: usize, r: usize) bool {
        const sb = self.scrollbackCount();
        const effective_vp = @min(viewport_offset, sb);
        const abs = sb - effective_vp + r;
        return self.getWrapped(abs);
    }

    // -- Screen mutation: scroll operations --

    /// Prepend a single row to the beginning of scrollback (abs=0, oldest).
    /// Used by grid-sync clients to hydrate scrollback from the daemon
    /// without disturbing the current screen contents. No-op if the ring
    /// is already at capacity. Returns true on success.
    pub fn prependRow(self: *RingBuffer, cells: []const Cell, wrapped: bool) bool {
        if (self.count >= self.capacity) return false;
        // Move head one slot back (wrap), growing scrollback by 1 without
        // touching the slots currently used by the screen — screen row r
        // stays at slot (new_head + scrollbackCount + r) = (old_head + r).
        self.head = (self.head + self.capacity - 1) % self.capacity;
        self.count += 1;
        const slot = self.ringSlot(0);
        const offset = slot * self.cols;
        const copy_n = @min(cells.len, self.cols);
        @memcpy(self.cells[offset .. offset + copy_n], cells[0..copy_n]);
        if (copy_n < self.cols) {
            for (self.cells[offset + copy_n .. offset + self.cols]) |*c| c.* = .{};
        }
        self.wrapped[slot] = wrapped;
        return true;
    }

    /// Advance screen: push top screen row into scrollback, clear new bottom row.
    /// Zero-copy when scroll_top=0 (the common case for full-screen scroll).
    /// Returns true if a row was actually pushed into scrollback (for viewport bumping).
    pub fn advanceScreen(self: *RingBuffer) bool {
        if (self.count < self.capacity) {
            // Ring not full yet — just grow count
            self.count += 1;
        } else {
            // Ring full — oldest row is overwritten, advance head
            self.head = (self.head + 1) % self.capacity;
            // count stays at capacity
        }
        // Clear the new bottom screen row
        self.clearScreenRow(self.screen_rows - 1);
        return true;
    }

    /// Scroll up within a scroll region [top, bottom] of the screen.
    /// Shifts cells: row top+1 → top, top+2 → top+1, etc. Row bottom is cleared.
    /// Does NOT push to scrollback — caller must handle that separately.
    pub fn scrollUpRegion(self: *RingBuffer, top: usize, bottom: usize, blank: Cell) void {
        if (top >= bottom) return;
        var r = top;
        while (r < bottom) : (r += 1) {
            const dst = self.getScreenRowMut(r);
            const src = self.getScreenRow(r + 1);
            @memcpy(dst, src);
            self.setScreenWrapped(r, self.getScreenWrapped(r + 1));
        }
        @memset(self.getScreenRowMut(bottom), blank);
        self.setScreenWrapped(bottom, false);
    }

    /// Scroll down within a scroll region [top, bottom] of the screen.
    /// Row `bottom` is lost, rows shift down, row `top` is cleared.
    pub fn scrollDownRegion(self: *RingBuffer, top: usize, bottom: usize, blank: Cell) void {
        if (top >= bottom) return;
        var r = bottom;
        while (r > top) : (r -= 1) {
            const dst = self.getScreenRowMut(r);
            const src = self.getScreenRow(r - 1);
            @memcpy(dst, src);
            self.setScreenWrapped(r, self.getScreenWrapped(r - 1));
        }
        @memset(self.getScreenRowMut(top), blank);
        self.setScreenWrapped(top, false);
    }

    /// Scroll up N times.
    pub fn scrollUpRegionN(self: *RingBuffer, top: usize, bottom: usize, n: usize, blank: Cell) void {
        if (top >= bottom or n == 0) return;
        const count = @min(n, bottom - top + 1);
        for (0..count) |_| self.scrollUpRegion(top, bottom, blank);
    }

    /// Scroll up within a top-anchored scroll region [0, bottom], preserving
    /// rows below the region while still pushing the old row 0 into scrollback.
    pub fn scrollUpTopAnchoredRegionWithScrollback(self: *RingBuffer, bottom: usize, blank: Cell) void {
        if (bottom >= self.screen_rows) return;

        _ = self.advanceScreen();

        if (bottom + 1 < self.screen_rows) {
            var r = self.screen_rows - 1;
            while (r > bottom) : (r -= 1) {
                const dst = self.getScreenRowMut(r);
                const src = self.getScreenRow(r - 1);
                @memcpy(dst, src);
                self.setScreenWrapped(r, self.getScreenWrapped(r - 1));
            }
        }

        @memset(self.getScreenRowMut(bottom), blank);
        self.setScreenWrapped(bottom, false);
    }

    /// Scroll down N times.
    pub fn scrollDownRegionN(self: *RingBuffer, top: usize, bottom: usize, n: usize, blank: Cell) void {
        if (top >= bottom or n == 0) return;
        const count = @min(n, bottom - top + 1);
        for (0..count) |_| self.scrollDownRegion(top, bottom, blank);
    }

    // -- Character insertion/deletion within screen rows --

    pub fn insertChars(self: *RingBuffer, row: usize, col: usize, n: usize, blank: Cell) void {
        if (n == 0 or col >= self.cols) return;
        const cells = self.getScreenRowMut(row);
        const count = @min(n, self.cols - col);
        const slice = cells[col..];
        if (count < slice.len) {
            std.mem.copyBackwards(Cell, slice[count..], slice[0 .. slice.len - count]);
        }
        @memset(slice[0..count], blank);
    }

    pub fn deleteChars(self: *RingBuffer, row: usize, col: usize, n: usize, blank: Cell) void {
        if (n == 0 or col >= self.cols) return;
        const cells = self.getScreenRowMut(row);
        const count = @min(n, self.cols - col);
        const slice = cells[col..];
        if (count < slice.len) {
            std.mem.copyForwards(Cell, slice[0 .. slice.len - count], slice[count..]);
        }
        @memset(slice[slice.len - count ..], blank);
    }

    pub fn eraseChars(self: *RingBuffer, row: usize, col: usize, n: usize, blank: Cell) void {
        if (n == 0 or col >= self.cols) return;
        const cells = self.getScreenRowMut(row);
        const count = @min(n, self.cols - col);
        @memset(cells[col .. col + count], blank);
    }

    /// Clear all scrollback, keeping only screen rows.
    pub fn clearScrollback(self: *RingBuffer) void {
        if (self.count <= self.screen_rows) return;
        // Move head forward past scrollback
        const sb = self.scrollbackCount();
        self.head = (self.head + sb) % self.capacity;
        self.count = self.screen_rows;
    }

    /// Direct access to all screen cells as a contiguous slice.
    /// Only valid when the screen rows are contiguous in the ring
    /// (not wrapping around). For general access, use getScreenRow.
    /// This is provided for compatibility with code that needs raw cell access.
    pub fn screenCellsDirect(self: *const RingBuffer) ?[]const Cell {
        if (self.count == 0) return null;
        const first_screen_abs = self.screenAbsRow(0);
        const first_slot = self.ringSlot(first_screen_abs);
        const last_slot = self.ringSlot(first_screen_abs + self.screen_rows - 1);
        // Only contiguous if last_slot >= first_slot
        if (last_slot >= first_slot) {
            const start = first_slot * self.cols;
            return self.cells[start .. start + self.screen_rows * self.cols];
        }
        return null;
    }

    /// Mutable version of screenCellsDirect.
    pub fn screenCellsDirectMut(self: *RingBuffer) ?[]Cell {
        if (self.count == 0) return null;
        const first_screen_abs = self.screenAbsRow(0);
        const first_slot = self.ringSlot(first_screen_abs);
        const last_slot = self.ringSlot(first_screen_abs + self.screen_rows - 1);
        if (last_slot >= first_slot) {
            const start = first_slot * self.cols;
            return self.cells[start .. start + self.screen_rows * self.cols];
        }
        return null;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "ring: init creates blank screen rows" {
    const alloc = testing.allocator;
    var ring = try RingBuffer.init(alloc, 3, 4, 10);
    defer ring.deinit();

    try testing.expectEqual(@as(usize, 3), ring.screen_rows);
    try testing.expectEqual(@as(usize, 0), ring.scrollbackCount());
    try testing.expectEqual(@as(usize, 3), ring.count);

    for (0..3) |r| {
        for (0..4) |c| {
            try testing.expectEqual(@as(u21, ' '), ring.getScreenCell(r, c).char);
        }
    }
}

test "ring: setScreenCell and getScreenCell round-trip" {
    const alloc = testing.allocator;
    var ring = try RingBuffer.init(alloc, 2, 2, 10);
    defer ring.deinit();

    ring.setScreenCell(0, 1, .{ .char = 'X' });
    try testing.expectEqual(@as(u21, 'X'), ring.getScreenCell(0, 1).char);
    try testing.expectEqual(@as(u21, ' '), ring.getScreenCell(0, 0).char);
}

test "ring: advanceScreen pushes to scrollback" {
    const alloc = testing.allocator;
    var ring = try RingBuffer.init(alloc, 3, 2, 10);
    defer ring.deinit();

    // Write "AB" on screen row 0
    ring.setScreenCell(0, 0, .{ .char = 'A' });
    ring.setScreenCell(0, 1, .{ .char = 'B' });
    ring.setScreenCell(1, 0, .{ .char = 'C' });
    ring.setScreenCell(2, 0, .{ .char = 'D' });

    _ = ring.advanceScreen();

    try testing.expectEqual(@as(usize, 1), ring.scrollbackCount());
    // Old row 0 is now in scrollback (abs row 0)
    try testing.expectEqual(@as(u21, 'A'), ring.getRow(0)[0].char);
    // Screen rows shifted: old row 1 is now screen row 0
    try testing.expectEqual(@as(u21, 'C'), ring.getScreenCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'D'), ring.getScreenCell(1, 0).char);
    // New bottom row is blank
    try testing.expectEqual(@as(u21, ' '), ring.getScreenCell(2, 0).char);
}

test "ring: scrollUpRegion partial" {
    const alloc = testing.allocator;
    var ring = try RingBuffer.init(alloc, 5, 2, 10);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'A' });
    ring.setScreenCell(1, 0, .{ .char = 'B' });
    ring.setScreenCell(2, 0, .{ .char = 'C' });
    ring.setScreenCell(3, 0, .{ .char = 'D' });
    ring.setScreenCell(4, 0, .{ .char = 'E' });

    ring.scrollUpRegion(1, 3, Cell{});

    try testing.expectEqual(@as(u21, 'A'), ring.getScreenCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'C'), ring.getScreenCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'D'), ring.getScreenCell(2, 0).char);
    try testing.expectEqual(@as(u21, ' '), ring.getScreenCell(3, 0).char);
    try testing.expectEqual(@as(u21, 'E'), ring.getScreenCell(4, 0).char);
}

test "ring: scrollDownRegion partial" {
    const alloc = testing.allocator;
    var ring = try RingBuffer.init(alloc, 5, 2, 10);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'A' });
    ring.setScreenCell(1, 0, .{ .char = 'B' });
    ring.setScreenCell(2, 0, .{ .char = 'C' });
    ring.setScreenCell(3, 0, .{ .char = 'D' });
    ring.setScreenCell(4, 0, .{ .char = 'E' });

    ring.scrollDownRegion(1, 3, Cell{});

    try testing.expectEqual(@as(u21, 'A'), ring.getScreenCell(0, 0).char);
    try testing.expectEqual(@as(u21, ' '), ring.getScreenCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'B'), ring.getScreenCell(2, 0).char);
    try testing.expectEqual(@as(u21, 'C'), ring.getScreenCell(3, 0).char);
    try testing.expectEqual(@as(u21, 'E'), ring.getScreenCell(4, 0).char);
}

test "ring: scrollUpTopAnchoredRegionWithScrollback preserves fixed tail rows" {
    const alloc = testing.allocator;
    var ring = try RingBuffer.init(alloc, 5, 1, 10);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'A' });
    ring.setScreenCell(1, 0, .{ .char = 'B' });
    ring.setScreenCell(2, 0, .{ .char = 'C' });
    ring.setScreenCell(3, 0, .{ .char = 'D' });
    ring.setScreenCell(4, 0, .{ .char = 'E' });

    ring.scrollUpTopAnchoredRegionWithScrollback(2, Cell{});

    try testing.expectEqual(@as(usize, 1), ring.scrollbackCount());
    try testing.expectEqual(@as(u21, 'A'), ring.getRow(0)[0].char);
    try testing.expectEqual(@as(u21, 'B'), ring.getScreenCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'C'), ring.getScreenCell(1, 0).char);
    try testing.expectEqual(@as(u21, ' '), ring.getScreenCell(2, 0).char);
    try testing.expectEqual(@as(u21, 'D'), ring.getScreenCell(3, 0).char);
    try testing.expectEqual(@as(u21, 'E'), ring.getScreenCell(4, 0).char);
}

test "ring: viewport access" {
    const alloc = testing.allocator;
    var ring = try RingBuffer.init(alloc, 3, 2, 10);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'A' });
    ring.setScreenCell(1, 0, .{ .char = 'B' });
    ring.setScreenCell(2, 0, .{ .char = 'C' });

    _ = ring.advanceScreen();
    ring.setScreenCell(2, 0, .{ .char = 'D' });

    // viewport_offset=0 → screen rows
    try testing.expectEqual(@as(u21, 'B'), ring.viewportRow(0, 0)[0].char);
    try testing.expectEqual(@as(u21, 'C'), ring.viewportRow(0, 1)[0].char);
    try testing.expectEqual(@as(u21, 'D'), ring.viewportRow(0, 2)[0].char);

    // viewport_offset=1 → scroll back 1 row
    try testing.expectEqual(@as(u21, 'A'), ring.viewportRow(1, 0)[0].char);
    try testing.expectEqual(@as(u21, 'B'), ring.viewportRow(1, 1)[0].char);
    try testing.expectEqual(@as(u21, 'C'), ring.viewportRow(1, 2)[0].char);
}

test "ring: clearScrollback" {
    const alloc = testing.allocator;
    var ring = try RingBuffer.init(alloc, 2, 2, 10);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'A' });
    ring.setScreenCell(1, 0, .{ .char = 'B' });
    _ = ring.advanceScreen();
    ring.setScreenCell(1, 0, .{ .char = 'C' });
    _ = ring.advanceScreen();
    ring.setScreenCell(1, 0, .{ .char = 'D' });

    try testing.expectEqual(@as(usize, 2), ring.scrollbackCount());

    ring.clearScrollback();
    try testing.expectEqual(@as(usize, 0), ring.scrollbackCount());
    // Screen rows are preserved
    try testing.expectEqual(@as(u21, 'C'), ring.getScreenCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'D'), ring.getScreenCell(1, 0).char);
}

test "ring: ring wraps around at capacity" {
    const alloc = testing.allocator;
    // 2 screen rows + 3 scrollback = 5 capacity
    var ring = try RingBuffer.init(alloc, 2, 1, 3);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'A' });
    ring.setScreenCell(1, 0, .{ .char = 'B' });

    // Advance 5 times — should wrap ring
    for (0..5) |i| {
        _ = ring.advanceScreen();
        ring.setScreenCell(1, 0, .{ .char = @intCast('C' + i) });
    }

    // Should have 3 scrollback rows (max)
    try testing.expectEqual(@as(usize, 3), ring.scrollbackCount());
    // After 5 advances with capacity 5: oldest surviving scrollback rows are
    // the ones pushed by advances 2,3,4 (0-indexed). Advance 0 pushes 'A',
    // advance 1 pushes 'C' (row 0 after first advance), etc.
    // The content depends on what was in screen row 0 at each advance.
    // Let's just verify count and screen content.
    try testing.expectEqual(@as(u21, 'F'), ring.getScreenCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'G'), ring.getScreenCell(1, 0).char);
}

test "ring: wrapped flag through scrollback" {
    const alloc = testing.allocator;
    var ring = try RingBuffer.init(alloc, 2, 2, 10);
    defer ring.deinit();

    ring.setScreenWrapped(0, true);
    ring.setScreenCell(0, 0, .{ .char = 'A' });
    _ = ring.advanceScreen();

    try testing.expectEqual(@as(usize, 1), ring.scrollbackCount());
    try testing.expect(ring.getWrapped(0)); // scrollback row 0 is wrapped
    try testing.expect(!ring.getScreenWrapped(0)); // new screen row 0 is not wrapped
}

test "ring: insertChars" {
    const alloc = testing.allocator;
    var ring = try RingBuffer.init(alloc, 1, 5, 5);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'A' });
    ring.setScreenCell(0, 1, .{ .char = 'B' });
    ring.setScreenCell(0, 2, .{ .char = 'C' });

    ring.insertChars(0, 1, 2, Cell{});

    try testing.expectEqual(@as(u21, 'A'), ring.getScreenCell(0, 0).char);
    try testing.expectEqual(@as(u21, ' '), ring.getScreenCell(0, 1).char);
    try testing.expectEqual(@as(u21, ' '), ring.getScreenCell(0, 2).char);
    try testing.expectEqual(@as(u21, 'B'), ring.getScreenCell(0, 3).char);
    try testing.expectEqual(@as(u21, 'C'), ring.getScreenCell(0, 4).char);
}

test "ring: deleteChars" {
    const alloc = testing.allocator;
    var ring = try RingBuffer.init(alloc, 1, 5, 5);
    defer ring.deinit();

    ring.setScreenCell(0, 0, .{ .char = 'A' });
    ring.setScreenCell(0, 1, .{ .char = 'B' });
    ring.setScreenCell(0, 2, .{ .char = 'C' });
    ring.setScreenCell(0, 3, .{ .char = 'D' });
    ring.setScreenCell(0, 4, .{ .char = 'E' });

    ring.deleteChars(0, 1, 2, Cell{});

    try testing.expectEqual(@as(u21, 'A'), ring.getScreenCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'D'), ring.getScreenCell(0, 1).char);
    try testing.expectEqual(@as(u21, 'E'), ring.getScreenCell(0, 2).char);
    try testing.expectEqual(@as(u21, ' '), ring.getScreenCell(0, 3).char);
    try testing.expectEqual(@as(u21, ' '), ring.getScreenCell(0, 4).char);
}
