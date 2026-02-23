const std = @import("std");
const grid_mod = @import("grid.zig");
const scrollback_mod = @import("scrollback.zig");

const Cell = grid_mod.Cell;
const Grid = grid_mod.Grid;
const Scrollback = scrollback_mod.Scrollback;

pub const SearchMatch = struct {
    abs_row: usize,
    col_start: usize,
    col_end: usize,
};

const max_matches: usize = 10_000;
const row_buf_size: usize = 512;

pub const SearchState = struct {
    matches: std.ArrayListUnmanaged(SearchMatch) = .{},
    allocator: std.mem.Allocator,
    current: usize = 0,
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,
    case_sensitive: bool = false,

    pub fn init(allocator: std.mem.Allocator) SearchState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SearchState) void {
        self.matches.deinit(self.allocator);
    }

    /// Rescan scrollback + grid for the given query. Replaces all previous results.
    /// Smart-case: if query contains an uppercase letter, match case-sensitively.
    pub fn update(
        self: *SearchState,
        query: []const u8,
        sb: *const Scrollback,
        grid: *const Grid,
    ) void {
        self.matches.clearRetainingCapacity();
        self.current = 0;

        if (query.len == 0) {
            self.query_len = 0;
            return;
        }

        const copy_len = @min(query.len, self.query_buf.len);
        @memcpy(self.query_buf[0..copy_len], query[0..copy_len]);
        self.query_len = copy_len;

        self.case_sensitive = hasUppercase(query);

        var lower_query_buf: [256]u8 = undefined;
        const lower_query = if (!self.case_sensitive) blk: {
            for (0..copy_len) |i| {
                lower_query_buf[i] = asciiLower(query[i]);
            }
            break :blk lower_query_buf[0..copy_len];
        } else query[0..copy_len];

        const sb_count = sb.count;
        const cols = grid.cols;

        // Scan scrollback
        for (0..sb_count) |line_idx| {
            if (self.matches.items.len >= max_matches) break;
            const cells = sb.getLine(line_idx);
            self.scanRow(line_idx, cells, cols, lower_query);
        }

        // Scan grid
        for (0..grid.rows) |row| {
            if (self.matches.items.len >= max_matches) break;
            const start = row * cols;
            const cells = grid.cells[start .. start + cols];
            self.scanRow(sb_count + row, cells, cols, lower_query);
        }
    }

    fn scanRow(self: *SearchState, abs_row: usize, cells: []const Cell, cols: usize, query: []const u8) void {
        if (query.len == 0 or cols == 0) return;

        var row_chars: [row_buf_size]u8 = undefined;
        const len = @min(cols, row_buf_size);
        for (0..len) |i| {
            const ch = cells[i].char;
            const byte: u8 = if (ch >= 32 and ch < 127) @intCast(ch) else ' ';
            row_chars[i] = if (!self.case_sensitive) asciiLower(byte) else byte;
        }

        const row_slice = row_chars[0..len];
        var pos: usize = 0;
        while (pos + query.len <= len) {
            if (std.mem.eql(u8, row_slice[pos .. pos + query.len], query)) {
                self.matches.append(self.allocator, .{
                    .abs_row = abs_row,
                    .col_start = pos,
                    .col_end = pos + query.len,
                }) catch break;
                if (self.matches.items.len >= max_matches) break;
                pos += 1;
            } else {
                pos += 1;
            }
        }
    }

    pub fn matchCount(self: *const SearchState) usize {
        return self.matches.items.len;
    }

    pub fn currentMatch(self: *const SearchState) ?SearchMatch {
        if (self.matches.items.len == 0) return null;
        return self.matches.items[self.current];
    }

    pub fn next(self: *SearchState) ?SearchMatch {
        if (self.matches.items.len == 0) return null;
        self.current = (self.current + 1) % self.matches.items.len;
        return self.matches.items[self.current];
    }

    pub fn prev(self: *SearchState) ?SearchMatch {
        if (self.matches.items.len == 0) return null;
        if (self.current == 0) {
            self.current = self.matches.items.len - 1;
        } else {
            self.current -= 1;
        }
        return self.matches.items[self.current];
    }

    /// Fill `out` with matches whose abs_row falls within [viewport_top, viewport_top + viewport_rows).
    /// Returns number of matches written.
    pub fn visibleMatches(
        self: *const SearchState,
        viewport_top: usize,
        viewport_rows: usize,
        out: []SearchMatch,
    ) usize {
        var count: usize = 0;
        for (self.matches.items) |m| {
            if (count >= out.len) break;
            if (m.abs_row >= viewport_top and m.abs_row < viewport_top + viewport_rows) {
                out[count] = m;
                count += 1;
            }
        }
        return count;
    }

    /// Compute the viewport_offset needed to make the current match visible
    /// within a terminal of `grid_rows` rows, given `sb_count` scrollback lines.
    /// Returns null if no current match.
    pub fn viewportForCurrent(
        self: *const SearchState,
        sb_count: usize,
        grid_rows: usize,
    ) ?usize {
        const m = self.currentMatch() orelse return null;
        const total_rows = sb_count + grid_rows;
        if (total_rows == 0) return null;
        // viewport_top = sb_count - viewport_offset
        // We want m.abs_row to be within [viewport_top, viewport_top + grid_rows)
        // viewport_top = sb_count - offset  =>  offset = sb_count - viewport_top
        // We center the match vertically when possible.
        const center_row = grid_rows / 2;
        const desired_top = if (m.abs_row >= center_row)
            m.abs_row - center_row
        else
            0;
        // viewport_top can range from (sb_count - sb_count) = 0  to  sb_count
        // offset = sb_count - viewport_top
        if (desired_top >= sb_count) {
            return 0; // match is in the grid, no scrollback needed
        }
        return sb_count - desired_top;
    }

    pub fn clear(self: *SearchState) void {
        self.matches.clearRetainingCapacity();
        self.current = 0;
        self.query_len = 0;
    }
};

fn asciiLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn hasUppercase(s: []const u8) bool {
    for (s) |c| {
        if (c >= 'A' and c <= 'Z') return true;
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "search: basic match" {
    var s = SearchState.init(testing.allocator);
    defer s.deinit();

    var sb = try Scrollback.init(testing.allocator, 100, 10);
    defer sb.deinit();
    var g = try Grid.init(testing.allocator, 2, 10);
    defer g.deinit();

    // Put "hello" in grid row 0
    const hello = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    for (hello, 0..) |ch, i| g.setCell(0, i, .{ .char = ch });

    s.update("hello", &sb, &g);
    try testing.expectEqual(@as(usize, 1), s.matchCount());
    const m = s.currentMatch().?;
    try testing.expectEqual(@as(usize, 0), m.abs_row);
    try testing.expectEqual(@as(usize, 0), m.col_start);
    try testing.expectEqual(@as(usize, 5), m.col_end);
}

test "search: case insensitive" {
    var s = SearchState.init(testing.allocator);
    defer s.deinit();

    var sb = try Scrollback.init(testing.allocator, 100, 10);
    defer sb.deinit();
    var g = try Grid.init(testing.allocator, 2, 10);
    defer g.deinit();

    const text = "Hello";
    for (text, 0..) |ch, i| g.setCell(0, i, .{ .char = ch });

    s.update("hello", &sb, &g);
    try testing.expectEqual(@as(usize, 1), s.matchCount());
}

test "search: smart case sensitive" {
    var s = SearchState.init(testing.allocator);
    defer s.deinit();

    var sb = try Scrollback.init(testing.allocator, 100, 20);
    defer sb.deinit();
    var g = try Grid.init(testing.allocator, 2, 20);
    defer g.deinit();

    const hello_lower = "hello";
    for (hello_lower, 0..) |ch, i| g.setCell(0, i, .{ .char = ch });
    const hello_cap = "Hello";
    for (hello_cap, 0..) |ch, i| g.setCell(1, i, .{ .char = ch });

    // Query with uppercase → case-sensitive
    s.update("Hello", &sb, &g);
    try testing.expectEqual(@as(usize, 1), s.matchCount());
    try testing.expectEqual(@as(usize, 1), s.currentMatch().?.abs_row);
}

test "search: empty query" {
    var s = SearchState.init(testing.allocator);
    defer s.deinit();

    var sb = try Scrollback.init(testing.allocator, 100, 10);
    defer sb.deinit();
    var g = try Grid.init(testing.allocator, 2, 10);
    defer g.deinit();

    s.update("", &sb, &g);
    try testing.expectEqual(@as(usize, 0), s.matchCount());
    try testing.expect(s.currentMatch() == null);
}

test "search: no match" {
    var s = SearchState.init(testing.allocator);
    defer s.deinit();

    var sb = try Scrollback.init(testing.allocator, 100, 10);
    defer sb.deinit();
    var g = try Grid.init(testing.allocator, 2, 10);
    defer g.deinit();

    s.update("xyz", &sb, &g);
    try testing.expectEqual(@as(usize, 0), s.matchCount());
}

test "search: next/prev wrap" {
    var s = SearchState.init(testing.allocator);
    defer s.deinit();

    var sb = try Scrollback.init(testing.allocator, 100, 20);
    defer sb.deinit();
    var g = try Grid.init(testing.allocator, 2, 20);
    defer g.deinit();

    const row0 = "aa bb aa";
    for (row0, 0..) |ch, i| g.setCell(0, i, .{ .char = ch });

    s.update("aa", &sb, &g);
    try testing.expectEqual(@as(usize, 2), s.matchCount());
    try testing.expectEqual(@as(usize, 0), s.currentMatch().?.col_start);

    _ = s.next();
    try testing.expectEqual(@as(usize, 6), s.currentMatch().?.col_start);

    _ = s.next(); // wraps
    try testing.expectEqual(@as(usize, 0), s.currentMatch().?.col_start);

    _ = s.prev(); // wraps back
    try testing.expectEqual(@as(usize, 6), s.currentMatch().?.col_start);
}

test "search: scrollback matches" {
    var s = SearchState.init(testing.allocator);
    defer s.deinit();

    var sb = try Scrollback.init(testing.allocator, 100, 10);
    defer sb.deinit();
    var g = try Grid.init(testing.allocator, 2, 10);
    defer g.deinit();

    // Push a line with "error" into scrollback
    var line: [10]Cell = undefined;
    @memset(&line, Cell{});
    const err_text = "error";
    for (err_text, 0..) |ch, i| line[i] = .{ .char = ch };
    sb.pushLine(&line);

    s.update("error", &sb, &g);
    try testing.expectEqual(@as(usize, 1), s.matchCount());
    try testing.expectEqual(@as(usize, 0), s.currentMatch().?.abs_row); // scrollback line 0
}

test "search: visible matches filter" {
    var s = SearchState.init(testing.allocator);
    defer s.deinit();

    var sb = try Scrollback.init(testing.allocator, 100, 10);
    defer sb.deinit();
    var g = try Grid.init(testing.allocator, 4, 10);
    defer g.deinit();

    // Put matches in grid rows 0, 1, 2, 3
    for (0..4) |row| {
        const text = "ab";
        for (text, 0..) |ch, i| g.setCell(row, i, .{ .char = ch });
    }

    s.update("ab", &sb, &g);
    try testing.expectEqual(@as(usize, 4), s.matchCount());

    // Viewport showing only rows 1-2 (abs rows sb.count+1 to sb.count+2)
    var vis: [8]SearchMatch = undefined;
    const count = s.visibleMatches(1, 2, &vis);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual(@as(usize, 1), vis[0].abs_row);
    try testing.expectEqual(@as(usize, 2), vis[1].abs_row);
}
