// Attyx — SplitLayout: binary tree split pane manager
//
// Each tab holds a SplitLayout. A leaf node wraps a *Pane; a branch node
// splits its rectangle into two children. Fixed-size node pool (max 15
// nodes = 8 leaves + 7 branches). No heap allocation for the tree itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Pane = @import("pane.zig").Pane;
const platform = @import("../platform/platform.zig");
const logging = @import("../logging/log.zig");

pub const max_panes = 8;
pub const max_nodes = max_panes * 2 - 1; // 15

pub const Direction = enum { horizontal, vertical };
pub const NavDirection = enum { up, down, left, right };

pub const Rect = struct {
    row: u16,
    col: u16,
    rows: u16,
    cols: u16,
};

const null_index: u8 = 0xFF;

pub const NodeTag = enum { empty, leaf, branch };

pub const Node = struct {
    tag: NodeTag = .empty,
    pane: ?*Pane = null,
    direction: Direction = .horizontal,
    ratio: f32 = 0.5,
    children: [2]u8 = .{ null_index, null_index },
    rect: Rect = .{ .row = 0, .col = 0, .rows = 0, .cols = 0 },
};

pub const LeafEntry = struct {
    index: u8,
    pane: *Pane,
    rect: Rect,
};

pub const CloseResult = enum { closed, last_pane };

pub const SplitLayout = struct {
    pool: [max_nodes]Node = .{Node{}} ** max_nodes,
    root: u8 = null_index,
    focused: u8 = null_index,
    pane_count: u8 = 0,
    gap_h: u16 = 1, // gap columns for vertical splits (horizontal spacing)
    gap_v: u16 = 1, // gap rows for horizontal splits (vertical spacing)

    pub fn setGaps(self: *SplitLayout, h: u16, v: u16) void {
        self.gap_h = h;
        self.gap_v = v;
    }

    pub fn init(initial_pane: *Pane) SplitLayout {
        var sl = SplitLayout{};
        sl.pool[0] = .{
            .tag = .leaf,
            .pane = initial_pane,
        };
        sl.root = 0;
        sl.focused = 0;
        sl.pane_count = 1;
        return sl;
    }

    /// Split the focused pane in the given direction. Creates a new pane
    /// (spawning a shell inheriting the focused pane's cwd).
    pub fn splitPane(
        self: *SplitLayout,
        dir: Direction,
        allocator: Allocator,
        pty_master: std.posix.fd_t,
    ) !void {
        if (self.pane_count >= max_panes) return error.TooManyPanes;
        const focus_idx = self.focused;
        if (focus_idx == null_index) return error.NoFocusedPane;
        const old_pane = self.pool[focus_idx].pane orelse return error.NoFocusedPane;

        // Allocate two child node slots
        const left_idx = self.allocNode() orelse return error.PoolFull;
        const right_idx = self.allocNode() orelse {
            self.pool[left_idx].tag = .empty;
            return error.PoolFull;
        };

        // Compute child dimensions from focused pane's rect
        const rect = self.pool[focus_idx].rect;
        var left_rect = rect;
        var right_rect = rect;

        const min_cols: u16 = 5;
        const min_rows: u16 = 3;

        switch (dir) {
            .vertical => {
                // Split left/right (subtract gap_h cols for separator + padding)
                if (rect.cols < min_cols * 2 + self.gap_h) return error.TooSmall;
                const available = rect.cols - self.gap_h;
                const left_cols = @as(u16, @intFromFloat(@as(f32, @floatFromInt(available)) * 0.5));
                const right_cols = available - left_cols;
                left_rect.cols = left_cols;
                right_rect.col = rect.col + left_cols + self.gap_h;
                right_rect.cols = right_cols;
            },
            .horizontal => {
                // Split top/bottom (subtract gap_v rows for separator + padding)
                if (rect.rows < min_rows * 2 + self.gap_v) return error.TooSmall;
                const available = rect.rows - self.gap_v;
                const top_rows = @as(u16, @intFromFloat(@as(f32, @floatFromInt(available)) * 0.5));
                const bottom_rows = available - top_rows;
                left_rect.rows = top_rows;
                right_rect.row = rect.row + top_rows + self.gap_v;
                right_rect.rows = bottom_rows;
            },
        }

        // Spawn new pane with cwd from the foreground process of the focused pane
        const new_pane = try allocator.create(Pane);
        errdefer allocator.destroy(new_pane);

        const fg_cwd = platform.getForegroundCwd(allocator, pty_master);
        defer if (fg_cwd) |cwd| allocator.free(cwd);
        const cwd_z: ?[:0]u8 = if (fg_cwd) |d| allocator.dupeZ(u8, d) catch null else null;
        defer if (cwd_z) |z| allocator.free(z);

        new_pane.* = try Pane.spawn(
            allocator,
            right_rect.rows,
            right_rect.cols,
            null,
            if (cwd_z) |z| z.ptr else null,
        );

        // Resize old pane to its new (smaller) rect
        old_pane.resize(left_rect.rows, left_rect.cols);

        // Left child inherits old pane
        self.pool[left_idx] = .{
            .tag = .leaf,
            .pane = old_pane,
            .rect = left_rect,
        };

        // Right child gets new pane
        self.pool[right_idx] = .{
            .tag = .leaf,
            .pane = new_pane,
            .rect = right_rect,
        };

        // Convert focused node from leaf → branch
        self.pool[focus_idx] = .{
            .tag = .branch,
            .pane = null,
            .direction = dir,
            .ratio = 0.5,
            .children = .{ left_idx, right_idx },
            .rect = rect,
        };

        self.pane_count += 1;
        self.focused = right_idx;
    }

    /// Close the focused pane. Returns .last_pane if this was the only pane.
    pub fn closePane(self: *SplitLayout, allocator: Allocator) CloseResult {
        if (self.pane_count <= 1) return .last_pane;
        const focus_idx = self.focused;
        if (focus_idx == null_index) return .last_pane;

        // Deinit and free the focused pane
        if (self.pool[focus_idx].pane) |pane| {
            pane.deinit();
            allocator.destroy(pane);
            self.pool[focus_idx].pane = null;
        }

        // Find parent of focused
        const parent_idx = self.findParent(focus_idx);
        if (parent_idx == null_index) {
            // Focused is root and only pane — shouldn't reach here due to count check
            return .last_pane;
        }

        // Identify sibling
        const children = self.pool[parent_idx].children;
        const sibling_idx = if (children[0] == focus_idx) children[1] else children[0];

        // Promote sibling into parent's slot
        const sibling = self.pool[sibling_idx];
        self.pool[parent_idx] = sibling;
        // Update children references if sibling was a branch
        // (children already reference correct pool indices)

        // Free old slots
        self.pool[focus_idx].tag = .empty;
        self.pool[focus_idx].pane = null;
        self.pool[sibling_idx].tag = .empty;
        self.pool[sibling_idx].pane = null;

        self.pane_count -= 1;

        // Focus the leftmost leaf of the promoted subtree
        self.focused = self.leftmostLeaf(parent_idx);
        return .closed;
    }

    /// Recursively compute rects for all nodes given the total available area.
    pub fn layout(self: *SplitLayout, total_rows: u16, total_cols: u16) void {
        if (self.root == null_index) return;
        const root_rect = Rect{ .row = 0, .col = 0, .rows = total_rows, .cols = total_cols };
        self.layoutNode(self.root, root_rect);
    }

    fn layoutNode(self: *SplitLayout, idx: u8, rect: Rect) void {
        if (idx == null_index) return;
        self.pool[idx].rect = rect;

        switch (self.pool[idx].tag) {
            .leaf => {
                // Resize the pane's engine/PTY to match
                if (self.pool[idx].pane) |pane| {
                    if (rect.rows > 0 and rect.cols > 0) {
                        pane.resize(rect.rows, rect.cols);
                    }
                }
            },
            .branch => {
                const dir = self.pool[idx].direction;
                const ratio = self.pool[idx].ratio;
                const children = self.pool[idx].children;
                var left_rect = rect;
                var right_rect = rect;

                const min_cols: u16 = 5;
                const min_rows: u16 = 3;

                switch (dir) {
                    .vertical => {
                        if (rect.cols <= min_cols * 2) {
                            // Too small to split — give all to left
                            right_rect.cols = 0;
                        } else {
                            const available = rect.cols -| self.gap_h;
                            var left_cols = @as(u16, @intFromFloat(@as(f32, @floatFromInt(available)) * ratio));
                            left_cols = @max(min_cols, @min(left_cols, available -| min_cols));
                            const right_cols = available - left_cols;
                            left_rect.cols = left_cols;
                            right_rect.col = rect.col + left_cols + self.gap_h;
                            right_rect.cols = right_cols;
                        }
                    },
                    .horizontal => {
                        if (rect.rows <= min_rows * 2) {
                            right_rect.rows = 0;
                        } else {
                            const available = rect.rows -| self.gap_v;
                            var top_rows = @as(u16, @intFromFloat(@as(f32, @floatFromInt(available)) * ratio));
                            top_rows = @max(min_rows, @min(top_rows, available -| min_rows));
                            const bottom_rows = available - top_rows;
                            left_rect.rows = top_rows;
                            right_rect.row = rect.row + top_rows + self.gap_v;
                            right_rect.rows = bottom_rows;
                        }
                    },
                }

                self.layoutNode(children[0], left_rect);
                self.layoutNode(children[1], right_rect);
            },
            .empty => {},
        }
    }

    /// Find which leaf node contains the given grid position.
    pub fn paneAt(self: *SplitLayout, row: u16, col: u16) ?u8 {
        return self.paneAtNode(self.root, row, col);
    }

    fn paneAtNode(self: *SplitLayout, idx: u8, row: u16, col: u16) ?u8 {
        if (idx == null_index) return null;
        const r = self.pool[idx].rect;
        if (row < r.row or row >= r.row + r.rows) return null;
        if (col < r.col or col >= r.col + r.cols) return null;

        return switch (self.pool[idx].tag) {
            .leaf => idx,
            .branch => {
                const children = self.pool[idx].children;
                return self.paneAtNode(children[0], row, col) orelse
                    self.paneAtNode(children[1], row, col);
            },
            .empty => null,
        };
    }

    /// Navigate focus in the given direction using center-ray projection.
    pub fn navigate(self: *SplitLayout, dir: NavDirection) void {
        if (self.pane_count <= 1) return;
        if (self.focused == null_index) return;

        const rect = self.pool[self.focused].rect;
        const center_row = rect.row + rect.rows / 2;
        const center_col = rect.col + rect.cols / 2;

        // Project a point just past the edge in the desired direction
        var target_row: u16 = center_row;
        var target_col: u16 = center_col;

        switch (dir) {
            .up => {
                if (rect.row < self.gap_v + 1) return;
                target_row = rect.row -| (self.gap_v + 1); // skip past gap
            },
            .down => {
                target_row = rect.row + rect.rows + self.gap_v; // skip past gap
            },
            .left => {
                if (rect.col < self.gap_h + 1) return;
                target_col = rect.col -| (self.gap_h + 1); // skip past gap
            },
            .right => {
                target_col = rect.col + rect.cols + self.gap_h; // skip past gap
            },
        }

        if (self.paneAt(target_row, target_col)) |target_idx| {
            if (target_idx != self.focused) {
                self.focused = target_idx;
            }
        }
    }

    /// Return the focused pane.
    pub fn focusedPane(self: *SplitLayout) *Pane {
        return self.pool[self.focused].pane.?;
    }

    /// Collect all leaf entries (pane + rect) into the output buffer.
    pub fn collectLeaves(self: *SplitLayout, out: []LeafEntry) u8 {
        var count: u8 = 0;
        self.collectLeavesNode(self.root, out, &count);
        return count;
    }

    fn collectLeavesNode(self: *SplitLayout, idx: u8, out: []LeafEntry, count: *u8) void {
        if (idx == null_index) return;
        switch (self.pool[idx].tag) {
            .leaf => {
                if (count.* < out.len) {
                    out[count.*] = .{
                        .index = idx,
                        .pane = self.pool[idx].pane.?,
                        .rect = self.pool[idx].rect,
                    };
                    count.* += 1;
                }
            },
            .branch => {
                self.collectLeavesNode(self.pool[idx].children[0], out, count);
                self.collectLeavesNode(self.pool[idx].children[1], out, count);
            },
            .empty => {},
        }
    }

    /// Deinit and free all panes in the tree.
    pub fn deinitAll(self: *SplitLayout, allocator: Allocator) void {
        for (&self.pool) |*node| {
            if (node.tag == .leaf) {
                if (node.pane) |pane| {
                    pane.deinit();
                    allocator.destroy(pane);
                    node.pane = null;
                }
            }
            node.tag = .empty;
        }
        self.pane_count = 0;
        self.root = null_index;
        self.focused = null_index;
    }

    /// Check all leaf panes for child exit. Returns the index of the first
    /// exited pane, or null if none.
    pub fn findExitedPane(self: *SplitLayout) ?u8 {
        for (&self.pool, 0..) |*node, i| {
            if (node.tag == .leaf) {
                if (node.pane) |pane| {
                    if (pane.childExited()) return @intCast(i);
                }
            }
        }
        return null;
    }

    /// Close a specific pane by node index.
    pub fn closePaneAt(self: *SplitLayout, idx: u8, allocator: Allocator) CloseResult {
        if (self.pane_count <= 1) return .last_pane;
        // Temporarily focus the target pane, close it, then don't restore
        const old_focused = self.focused;
        self.focused = idx;
        const result = self.closePane(allocator);
        // If close failed to find parent (shouldn't happen), restore
        if (result == .last_pane) self.focused = old_focused;
        return result;
    }

    /// Hit-test: find the branch node whose separator gap contains (row, col).
    /// Returns the pool index of the branch, or null if no separator at that position.
    pub fn separatorAt(self: *SplitLayout, row: u16, col: u16) ?u8 {
        for (&self.pool, 0..) |*node, i| {
            if (node.tag != .branch) continue;
            const rect = node.rect;
            // Check that the point is within the branch's rect
            if (row < rect.row or row >= rect.row + rect.rows) continue;
            if (col < rect.col or col >= rect.col + rect.cols) continue;

            switch (node.direction) {
                .vertical => {
                    const available = rect.cols -| self.gap_h;
                    const left_cols = @as(u16, @intFromFloat(@as(f32, @floatFromInt(available)) * node.ratio));
                    const gap_start = rect.col + left_cols;
                    if (col >= gap_start and col < gap_start + self.gap_h) return @intCast(i);
                },
                .horizontal => {
                    const available = rect.rows -| self.gap_v;
                    const top_rows = @as(u16, @intFromFloat(@as(f32, @floatFromInt(available)) * node.ratio));
                    const gap_start = rect.row + top_rows;
                    if (row >= gap_start and row < gap_start + self.gap_v) return @intCast(i);
                },
            }
        }
        return null;
    }

    /// Adjust a branch node's ratio by delta, clamped to [0.05, 0.95].
    /// Re-layouts the tree and returns true if the ratio actually changed.
    pub fn resizeNode(self: *SplitLayout, branch_idx: u8, delta: f32, total_rows: u16, total_cols: u16) bool {
        if (branch_idx >= max_nodes or self.pool[branch_idx].tag != .branch) return false;
        const old = self.pool[branch_idx].ratio;
        var new_ratio = old + delta;
        new_ratio = @max(0.05, @min(0.95, new_ratio));
        if (new_ratio == old) return false;
        self.pool[branch_idx].ratio = new_ratio;
        self.layout(total_rows, total_cols);
        return true;
    }

    /// Walk up from focused leaf to find the nearest ancestor branch
    /// matching the given split direction. For keyboard resize.
    pub fn findResizeTarget(self: *SplitLayout, dir: Direction) ?u8 {
        var cur = self.focused;
        if (cur == null_index) return null;
        while (true) {
            const parent = self.findParent(cur);
            if (parent == null_index) return null;
            if (self.pool[parent].direction == dir) return parent;
            cur = parent;
        }
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    fn allocNode(self: *SplitLayout) ?u8 {
        for (&self.pool, 0..) |*node, i| {
            if (node.tag == .empty) {
                // Mark as reserved so the next allocNode call doesn't
                // return the same slot.
                node.tag = .leaf;
                return @intCast(i);
            }
        }
        return null;
    }

    pub fn findParent(self: *SplitLayout, child_idx: u8) u8 {
        for (&self.pool, 0..) |*node, i| {
            if (node.tag == .branch) {
                if (node.children[0] == child_idx or node.children[1] == child_idx) {
                    return @intCast(i);
                }
            }
        }
        return null_index;
    }

    fn leftmostLeaf(self: *SplitLayout, idx: u8) u8 {
        if (idx == null_index) return null_index;
        var cur = idx;
        while (self.pool[cur].tag == .branch) {
            cur = self.pool[cur].children[0];
            if (cur == null_index) break;
        }
        return cur;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "SplitLayout: init creates single-pane layout" {
    const allocator = std.testing.allocator;
    var pane_stub = try createTestPane(allocator);
    defer destroyTestPane(allocator, &pane_stub);

    const layout = SplitLayout.init(&pane_stub);
    try std.testing.expectEqual(@as(u8, 1), layout.pane_count);
    try std.testing.expectEqual(@as(u8, 0), layout.root);
    try std.testing.expectEqual(@as(u8, 0), layout.focused);
    try std.testing.expectEqual(NodeTag.leaf, layout.pool[0].tag);
}

test "SplitLayout: layout sets rect on single pane" {
    const allocator = std.testing.allocator;
    var pane_stub = try createTestPane(allocator);
    defer destroyTestPane(allocator, &pane_stub);

    var layout = SplitLayout.init(&pane_stub);
    layout.layout(24, 80);

    try std.testing.expectEqual(@as(u16, 0), layout.pool[0].rect.row);
    try std.testing.expectEqual(@as(u16, 0), layout.pool[0].rect.col);
    try std.testing.expectEqual(@as(u16, 24), layout.pool[0].rect.rows);
    try std.testing.expectEqual(@as(u16, 80), layout.pool[0].rect.cols);
}

test "SplitLayout: collectLeaves returns all leaves" {
    const allocator = std.testing.allocator;
    var pane_stub = try createTestPane(allocator);
    defer destroyTestPane(allocator, &pane_stub);

    var layout = SplitLayout.init(&pane_stub);
    layout.layout(24, 80);

    var leaves: [max_panes]LeafEntry = undefined;
    const count = layout.collectLeaves(&leaves);
    try std.testing.expectEqual(@as(u8, 1), count);
    try std.testing.expectEqual(&pane_stub, leaves[0].pane);
}

test "SplitLayout: paneAt finds leaf" {
    const allocator = std.testing.allocator;
    var pane_stub = try createTestPane(allocator);
    defer destroyTestPane(allocator, &pane_stub);

    var layout = SplitLayout.init(&pane_stub);
    layout.layout(24, 80);

    const found = layout.paneAt(10, 40);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u8, 0), found.?);

    // Out of bounds
    try std.testing.expect(layout.paneAt(25, 40) == null);
}

// Test helper: create a minimal Pane for unit tests (engine-only, no PTY spawn)
const attyx = @import("attyx");
const Engine = attyx.Engine;

fn createTestPane(allocator: Allocator) !Pane {
    const engine = try Engine.init(allocator, 24, 80);
    return Pane{
        .engine = engine,
        .pty = undefined, // Not used in layout tests
        .allocator = allocator,
    };
}

fn destroyTestPane(_: Allocator, pane: *Pane) void {
    pane.engine.deinit();
}
