/// Top-level finder state machine. Combines directory walker + fuzzy matcher.
/// Manages incremental walking, scoring, and sorted result presentation.
const std = @import("std");
const fuzzy_match = @import("fuzzy_match.zig");
const dir_walker = @import("dir_walker.zig");
const DirWalker = dir_walker.DirWalker;

const batch_size: u32 = 200;

pub const FinderState = struct {
    allocator: std.mem.Allocator,
    walker: DirWalker,
    sorted_indices: std.ArrayList(u32),
    sorted_scores: std.ArrayList(i32),
    result_count: u32,
    walking_done: bool,
    query_buf: [128]u8,
    query_len: u8,
    last_scored_count: u32, // how many walker results we've scored so far

    pub fn init(allocator: std.mem.Allocator, root: []const u8, max_depth: u8, show_hidden: bool) !FinderState {
        return .{
            .allocator = allocator,
            .walker = try DirWalker.init(allocator, root, max_depth, show_hidden),
            .sorted_indices = .{},
            .sorted_scores = .{},
            .result_count = 0,
            .walking_done = false,
            .query_buf = .{0} ** 128,
            .query_len = 0,
            .last_scored_count = 0,
        };
    }

    pub fn deinit(self: *FinderState) void {
        self.sorted_indices.deinit(self.allocator);
        self.sorted_scores.deinit(self.allocator);
        self.walker.deinit();
    }

    /// Process one batch of directory walking, score new entries against current query.
    pub fn tick(self: *FinderState) !void {
        if (!self.walking_done) {
            const more = try self.walker.walkBatch(batch_size);
            if (!more) self.walking_done = true;
        }

        // Score any new entries we haven't scored yet
        const total = @as(u32, @intCast(self.walker.entries.items.len));
        if (total > self.last_scored_count and self.query_len > 0) {
            const query = self.query_buf[0..self.query_len];
            const entries = self.walker.entries.items;

            for (self.last_scored_count..total) |i| {
                const path = entries[i].path;
                if (fuzzy_match.matchScore(path, query)) |s| {
                    try self.sorted_indices.append(self.allocator, @intCast(i));
                    try self.sorted_scores.append(self.allocator, s);
                    self.result_count += 1;
                }
            }
            self.last_scored_count = total;

            // Re-sort by score descending
            self.sortResults();
        } else if (self.query_len == 0) {
            self.last_scored_count = total;
        }
    }

    /// Rescore ALL entries against a new query, sort by score desc.
    pub fn updateQuery(self: *FinderState, query: []const u8) void {
        const len = @min(query.len, self.query_buf.len);
        @memcpy(self.query_buf[0..len], query[0..len]);
        self.query_len = @intCast(len);

        // Clear existing results
        self.sorted_indices.clearRetainingCapacity();
        self.sorted_scores.clearRetainingCapacity();
        self.result_count = 0;

        if (len == 0) {
            self.last_scored_count = @intCast(self.walker.entries.items.len);
            return;
        }

        const q = self.query_buf[0..len];
        const entries = self.walker.entries.items;

        for (entries, 0..) |e, i| {
            if (fuzzy_match.matchScore(e.path, q)) |s| {
                self.sorted_indices.append(self.allocator, @intCast(i)) catch continue;
                self.sorted_scores.append(self.allocator, s) catch continue;
                self.result_count += 1;
            }
        }

        self.last_scored_count = @intCast(entries.len);
        self.sortResults();
    }

    /// Get a slice of sorted indices for display.
    pub fn getResults(self: *const FinderState, offset: u32, count: u32) []const u32 {
        if (self.result_count == 0) return &.{};
        const start = @min(offset, self.result_count);
        const end = @min(start + count, self.result_count);
        return self.sorted_indices.items[start..end];
    }

    /// Get the path for a result index (index into walker entries).
    pub fn getPath(self: *const FinderState, index: u32) []const u8 {
        if (index >= self.walker.entries.items.len) return "";
        return self.walker.entries.items[index].path;
    }

    /// Get score for a sorted position.
    pub fn getScore(self: *const FinderState, sorted_pos: u32) i32 {
        if (sorted_pos >= self.sorted_scores.items.len) return 0;
        return self.sorted_scores.items[sorted_pos];
    }

    /// Get the root path this finder is walking.
    pub fn getRootPath(self: *const FinderState) []const u8 {
        return self.walker.root_path;
    }

    fn sortResults(self: *FinderState) void {
        if (self.result_count <= 1) return;

        const indices = self.sorted_indices.items;
        const scores = self.sorted_scores.items;
        const n = self.result_count;

        // Insertion sort (good enough for interactive use)
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const tmp_idx = indices[i];
            const tmp_score = scores[i];
            var j: usize = i;
            while (j > 0 and scores[j - 1] < tmp_score) {
                indices[j] = indices[j - 1];
                scores[j] = scores[j - 1];
                j -= 1;
            }
            indices[j] = tmp_idx;
            scores[j] = tmp_score;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "init and deinit" {
    const allocator = std.testing.allocator;
    var finder = try FinderState.init(allocator, "/tmp", 2, false);
    defer finder.deinit();
    try std.testing.expect(!finder.walking_done);
    try std.testing.expectEqual(@as(u32, 0), finder.result_count);
}

test "tick processes batches" {
    const allocator = std.testing.allocator;
    var finder = try FinderState.init(allocator, "/tmp", 1, false);
    defer finder.deinit();

    // Tick a few times
    try finder.tick();
    try finder.tick();
    // Should terminate without error
}

test "updateQuery rescores" {
    const allocator = std.testing.allocator;
    var finder = try FinderState.init(allocator, "/tmp", 1, false);
    defer finder.deinit();

    // Walk first
    try finder.tick();

    // Update query
    finder.updateQuery("nonexistent_xyz_query_12345");
    // Very unlikely to match anything
    try std.testing.expectEqual(@as(u32, 0), finder.result_count);

    // Clear query
    finder.updateQuery("");
    try std.testing.expectEqual(@as(u32, 0), finder.result_count);
}

test "getResults with empty results" {
    const allocator = std.testing.allocator;
    var finder = try FinderState.init(allocator, "/tmp", 1, false);
    defer finder.deinit();

    const results = finder.getResults(0, 10);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "getPath out of bounds" {
    const allocator = std.testing.allocator;
    var finder = try FinderState.init(allocator, "/tmp", 1, false);
    defer finder.deinit();

    try std.testing.expectEqualStrings("", finder.getPath(9999));
}
