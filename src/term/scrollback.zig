const std = @import("std");
const grid_mod = @import("grid.zig");

pub const Cell = grid_mod.Cell;

/// Bounded ring buffer storing terminal rows that have scrolled off the
/// top of the visible grid.  Only used for the main screen (not alt).
///
/// Memory layout: a single flat allocation of `max_lines * cols` cells.
/// `head` points to the next write slot; `count` tracks how many lines
/// are stored (up to `max_lines`).
pub const Scrollback = struct {
    cells: []Cell,
    cols: usize,
    max_lines: usize,
    head: usize = 0,
    count: usize = 0,
    allocator: std.mem.Allocator,

    pub const default_max_lines: usize = 10_000;

    pub fn init(allocator: std.mem.Allocator, max_lines: usize, cols: usize) !Scrollback {
        std.debug.assert(max_lines > 0 and cols > 0);
        const cells = try allocator.alloc(Cell, max_lines * cols);
        @memset(cells, Cell{});
        return .{
            .cells = cells,
            .cols = cols,
            .max_lines = max_lines,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scrollback) void {
        self.allocator.free(self.cells);
    }

    /// Append a row of cells to the ring.  Accepts any line length:
    /// truncates if longer than `self.cols`, pads with blank cells if shorter.
    pub fn pushLine(self: *Scrollback, line: []const Cell) void {
        const offset = self.head * self.cols;
        const copy_len = @min(line.len, self.cols);
        @memcpy(self.cells[offset .. offset + copy_len], line[0..copy_len]);
        if (copy_len < self.cols) {
            @memset(self.cells[offset + copy_len .. offset + self.cols], Cell{});
        }
        self.head = (self.head + 1) % self.max_lines;
        if (self.count < self.max_lines) self.count += 1;
    }

    /// Read scrollback line `index` (0 = oldest stored line).
    /// Caller must ensure `index < self.count`.
    pub fn getLine(self: *const Scrollback, index: usize) []const Cell {
        std.debug.assert(index < self.count);
        const ring_pos = if (self.count < self.max_lines)
            index
        else
            (self.head + index) % self.max_lines;
        const offset = ring_pos * self.cols;
        return self.cells[offset .. offset + self.cols];
    }

    /// Drop the N most recently pushed lines from the ring.
    /// Used when restoring scrollback content into the visible grid.
    pub fn removeRecent(self: *Scrollback, n: usize) void {
        const remove = @min(n, self.count);
        if (remove == 0) return;
        if (self.head >= remove) {
            self.head -= remove;
        } else {
            self.head = self.max_lines - (remove - self.head);
        }
        self.count -= remove;
    }

    pub fn clear(self: *Scrollback) void {
        self.head = 0;
        self.count = 0;
    }

    /// Resize the ring buffer to `new_max_lines`. Keeps the most recent
    /// min(count, new_max_lines) lines in oldest-first order.
    /// Safe to call from the PTY thread (sole owner of the scrollback buffer).
    pub fn reallocate(self: *Scrollback, new_max_lines: usize) !void {
        std.debug.assert(new_max_lines > 0);
        if (new_max_lines == self.max_lines) return;

        const new_cells = try self.allocator.alloc(Cell, new_max_lines * self.cols);
        errdefer self.allocator.free(new_cells);

        const lines_to_copy = @min(self.count, new_max_lines);
        const oldest = if (self.count < self.max_lines) 0 else self.head;
        for (0..lines_to_copy) |i| {
            const src_idx = (oldest + i) % self.max_lines;
            @memcpy(
                new_cells[i * self.cols .. (i + 1) * self.cols],
                self.cells[src_idx * self.cols .. src_idx * self.cols + self.cols],
            );
        }
        if (lines_to_copy < new_max_lines) {
            @memset(new_cells[lines_to_copy * self.cols ..], Cell{});
        }

        self.allocator.free(self.cells);
        self.cells     = new_cells;
        self.max_lines = new_max_lines;
        self.count     = lines_to_copy;
        self.head      = lines_to_copy % new_max_lines;
    }
};
