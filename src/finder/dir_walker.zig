/// Incremental recursive directory walker. Yields directory paths only (not files).
/// Processes entries in batches to avoid blocking the event loop.
const std = @import("std");

pub const PathEntry = struct {
    path: []const u8, // allocated, relative to root
};

const max_results: usize = 8192;
const max_stack_depth: usize = 32;

const skip_dirs = [_][]const u8{
    ".git",
    "node_modules",
    ".cache",
    "__pycache__",
    "vendor",
    ".venv",
    "venv",
    ".next",
    "target",
    "build",
    "dist",
    ".svn",
    ".hg",
    "zig-out",
    "zig-cache",
    ".zig-cache",
    ".Trash",
    "Library",
};

fn shouldSkip(name: []const u8) bool {
    for (skip_dirs) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

const StackEntry = struct {
    dir: std.fs.Dir,
    iter: std.fs.Dir.Iterator,
    prefix: []const u8, // allocated path prefix for this level
};

pub const DirWalker = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(PathEntry),
    stack: [max_stack_depth]?StackEntry,
    stack_len: u8,
    max_depth: u8,
    show_hidden: bool,
    done: bool,
    root_path: []const u8, // allocated copy

    pub fn init(allocator: std.mem.Allocator, root: []const u8, max_depth: u8, show_hidden: bool) !DirWalker {
        // Expand ~ to $HOME
        const resolved = if (root.len > 0 and root[0] == '~') blk: {
            const home = std.posix.getenv("HOME") orelse "/";
            if (root.len == 1) {
                break :blk try allocator.dupe(u8, home);
            } else {
                break :blk try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, root[1..] });
            }
        } else try allocator.dupe(u8, root);

        var self = DirWalker{
            .allocator = allocator,
            .entries = .{},
            .stack = .{null} ** max_stack_depth,
            .stack_len = 0,
            .max_depth = max_depth,
            .show_hidden = show_hidden,
            .done = false,
            .root_path = resolved,
        };

        // Open root directory
        const dir = std.fs.openDirAbsolute(resolved, .{ .iterate = true }) catch {
            self.done = true;
            return self;
        };
        const prefix = try allocator.dupe(u8, "");
        self.stack[0] = .{
            .dir = dir,
            .iter = dir.iterate(),
            .prefix = prefix,
        };
        self.stack_len = 1;

        return self;
    }

    pub fn deinit(self: *DirWalker) void {
        // Close all open dirs and free prefixes
        for (0..self.stack_len) |i| {
            if (self.stack[i]) |*entry| {
                entry.dir.close();
                self.allocator.free(entry.prefix);
                self.stack[i] = null;
            }
        }
        // Free all path entries
        for (self.entries.items) |e| {
            self.allocator.free(e.path);
        }
        self.entries.deinit(self.allocator);
        self.allocator.free(self.root_path);
    }

    /// Process up to batch_size directory entries. Returns true if more work remains.
    pub fn walkBatch(self: *DirWalker, batch_size: u32) !bool {
        if (self.done) return false;

        var processed: u32 = 0;
        while (processed < batch_size) {
            if (self.stack_len == 0) {
                self.done = true;
                return false;
            }

            const top_idx = self.stack_len - 1;
            var top = &(self.stack[top_idx].?);

            const maybe_entry = top.iter.next() catch {
                // Permission error or similar — pop this level
                self.popStack();
                continue;
            };

            if (maybe_entry) |entry| {
                processed += 1;

                // Skip non-directories
                if (entry.kind != .directory) continue;

                // Skip symlinks
                if (entry.kind == .sym_link) continue;

                const name = entry.name;

                // Skip hidden dirs unless show_hidden is true
                if (!self.show_hidden and name.len > 0 and name[0] == '.') continue;

                // Skip known uninteresting dirs
                if (shouldSkip(name)) continue;

                // Build relative path
                const rel_path = if (top.prefix.len == 0)
                    try self.allocator.dupe(u8, name)
                else
                    try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ top.prefix, name });

                // Add to results
                if (self.entries.items.len < max_results) {
                    try self.entries.append(self.allocator, .{ .path = rel_path });
                } else {
                    self.allocator.free(rel_path);
                    self.done = true;
                    return false;
                }

                // Push subdirectory if within depth limit
                const current_depth = self.stack_len;
                if (current_depth < self.max_depth and self.stack_len < max_stack_depth) {
                    const sub_dir = top.dir.openDir(name, .{ .iterate = true }) catch continue;
                    const new_prefix = try self.allocator.dupe(u8, rel_path);
                    self.stack[self.stack_len] = .{
                        .dir = sub_dir,
                        .iter = sub_dir.iterate(),
                        .prefix = new_prefix,
                    };
                    self.stack_len += 1;
                }
            } else {
                // Iterator exhausted — pop this level
                self.popStack();
            }
        }

        return self.stack_len > 0;
    }

    fn popStack(self: *DirWalker) void {
        if (self.stack_len == 0) return;
        const idx = self.stack_len - 1;
        if (self.stack[idx]) |*entry| {
            entry.dir.close();
            self.allocator.free(entry.prefix);
            self.stack[idx] = null;
        }
        self.stack_len -= 1;
    }

    /// Return accumulated results so far.
    pub fn results(self: *const DirWalker) []const PathEntry {
        return self.entries.items;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "shouldSkip: known dirs" {
    try std.testing.expect(shouldSkip(".git"));
    try std.testing.expect(shouldSkip("node_modules"));
    try std.testing.expect(shouldSkip("Library"));
    try std.testing.expect(!shouldSkip("src"));
    try std.testing.expect(!shouldSkip("my_project"));
}

test "init and deinit with nonexistent dir" {
    const allocator = std.testing.allocator;
    var walker = try DirWalker.init(allocator, "/nonexistent_path_12345", 3, false);
    defer walker.deinit();
    try std.testing.expect(walker.done);
}

test "walk /tmp with depth 1" {
    const allocator = std.testing.allocator;
    var walker = try DirWalker.init(allocator, "/tmp", 1, false);
    defer walker.deinit();

    // Process some entries
    _ = try walker.walkBatch(100);
    // Should have found some results (or none, if /tmp is empty)
    // Just verify it doesn't crash
    _ = walker.results();
}

test "batch incremental walking" {
    const allocator = std.testing.allocator;
    var walker = try DirWalker.init(allocator, "/tmp", 2, false);
    defer walker.deinit();

    // Walk in small batches
    var total_batches: u32 = 0;
    while (try walker.walkBatch(5)) {
        total_batches += 1;
        if (total_batches > 1000) break; // safety
    }
    // Just verify we terminate
    try std.testing.expect(total_batches <= 1000);
}
