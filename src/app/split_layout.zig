// Attyx — SplitLayout: binary tree split pane manager
// Fixed-size node pool (max 15 nodes = 8 leaves + 7 branches).

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
    zoomed_leaf: u8 = null_index, // set when a pane is zoomed to fill the whole area

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

    /// Split the focused pane, spawning a shell inheriting the focused pane's cwd.
    pub fn splitPane(
        self: *SplitLayout,
        dir: Direction,
        allocator: Allocator,
        pty_master: std.posix.fd_t,
        scrollback_lines: usize,
    ) !void {
        const fg_cwd = platform.getForegroundCwd(allocator, pty_master);
        defer if (fg_cwd) |cwd| allocator.free(cwd);
        const cwd_z: ?[:0]u8 = if (fg_cwd) |d| allocator.dupeZ(u8, d) catch null else null;
        defer if (cwd_z) |z| allocator.free(z);

        const rect = self.pool[self.focused].rect;
        const child_size = self.splitChildSize(dir, rect) orelse return error.TooSmall;

        const new_pane = try allocator.create(Pane);
        errdefer allocator.destroy(new_pane);
        new_pane.* = try Pane.spawn(
            allocator,
            child_size.rows,
            child_size.cols,
            null,
            if (cwd_z) |z| z.ptr else null,
            scrollback_lines,
        );

        try self.splitPaneWith(dir, new_pane);
    }

    /// Split the focused pane using a pre-resolved CWD (with full fallback chain).
    /// Preferred over splitPane() which only uses getForegroundCwd.
    pub fn splitPaneResolved(
        self: *SplitLayout,
        dir: Direction,
        allocator: Allocator,
        cwd: ?[]const u8,
        scrollback_lines: usize,
    ) !void {
        const cwd_z: ?[:0]u8 = if (cwd) |d| allocator.dupeZ(u8, d) catch null else null;
        defer if (cwd_z) |z| allocator.free(z);

        const rect = self.pool[self.focused].rect;
        const child_size = self.splitChildSize(dir, rect) orelse return error.TooSmall;

        const new_pane = try allocator.create(Pane);
        errdefer allocator.destroy(new_pane);
        new_pane.* = try Pane.spawn(
            allocator,
            child_size.rows,
            child_size.cols,
            null,
            if (cwd_z) |z| z.ptr else null,
            scrollback_lines,
        );

        try self.splitPaneWith(dir, new_pane);
    }

    /// Split the focused pane, inserting a pre-created pane as the new child.
    pub fn splitPaneWith(self: *SplitLayout, dir: Direction, new_pane: *Pane) !void {
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
                if (rect.cols < min_cols * 2 + self.gap_h) return error.TooSmall;
                const available = rect.cols - self.gap_h;
                const left_cols = @as(u16, @intFromFloat(@as(f32, @floatFromInt(available)) * 0.5));
                const right_cols = available - left_cols;
                left_rect.cols = left_cols;
                right_rect.col = rect.col + left_cols + self.gap_h;
                right_rect.cols = right_cols;
            },
            .horizontal => {
                if (rect.rows < min_rows * 2 + self.gap_v) return error.TooSmall;
                const available = rect.rows - self.gap_v;
                const top_rows = @as(u16, @intFromFloat(@as(f32, @floatFromInt(available)) * 0.5));
                const bottom_rows = available - top_rows;
                left_rect.rows = top_rows;
                right_rect.row = rect.row + top_rows + self.gap_v;
                right_rect.rows = bottom_rows;
            },
        }

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

    pub fn splitChildSize(self: *SplitLayout, dir: Direction, rect: Rect) ?struct { rows: u16, cols: u16 } {
        switch (dir) {
            .vertical => {
                if (rect.cols < 10 + self.gap_h) return null;
                const avail = rect.cols - self.gap_h;
                return .{ .rows = rect.rows, .cols = avail - @as(u16, @intFromFloat(@as(f32, @floatFromInt(avail)) * 0.5)) };
            },
            .horizontal => {
                if (rect.rows < 6 + self.gap_v) return null;
                const avail = rect.rows - self.gap_v;
                return .{ .rows = avail - @as(u16, @intFromFloat(@as(f32, @floatFromInt(avail)) * 0.5)), .cols = rect.cols };
            },
        }
    }

    /// Close the focused pane. Returns .last_pane if this was the only pane.
    pub fn closePane(self: *SplitLayout, allocator: Allocator) CloseResult {
        if (self.pane_count <= 1) return .last_pane;
        const focus_idx = self.focused;
        if (focus_idx == null_index) return .last_pane;

        // Clear zoom if we're closing the zoomed pane
        if (self.zoomed_leaf == focus_idx) self.zoomed_leaf = null_index;

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

    pub fn layout(self: *SplitLayout, total_rows: u16, total_cols: u16) void {
        if (self.root == null_index) return;
        const root_rect = Rect{ .row = 0, .col = 0, .rows = total_rows, .cols = total_cols };
        self.layoutNode(self.root, root_rect);
        // When zoomed, also resize the zoomed pane to fill the entire area
        if (self.isZoomed()) {
            if (self.pool[self.zoomed_leaf].pane) |pane| {
                if (total_rows > 0 and total_cols > 0) {
                    pane.resize(total_rows, total_cols);
                }
            }
        }
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
                target_row = rect.row -| (self.gap_v + 1);
            },
            .down => {
                target_row = rect.row + rect.rows + self.gap_v;
            },
            .left => {
                if (rect.col < self.gap_h + 1) return;
                target_col = rect.col -| (self.gap_h + 1);
            },
            .right => {
                target_col = rect.col + rect.cols + self.gap_h;
            },
        }

        if (self.probeForPane(target_row, target_col, dir, rect)) |target_idx| {
            if (target_idx != self.focused) {
                self.focused = target_idx;
            }
        }
    }

    fn probeForPane(self: *SplitLayout, row: u16, col: u16, dir: NavDirection, src: Rect) ?u8 {
        // Try exact center first
        if (self.paneAt(row, col)) |idx| return idx;

        // Scan outward from center along the source pane's perpendicular span
        const is_horizontal = (dir == .left or dir == .right);
        const span_start: u16 = if (is_horizontal) src.row else src.col;
        const span_end: u16 = span_start + (if (is_horizontal) src.rows else src.cols);
        const center: u16 = if (is_horizontal) row else col;

        var offset: u16 = 1;
        while (offset < span_end - span_start) : (offset += 1) {
            // Try center + offset
            if (center + offset < span_end) {
                const r = if (is_horizontal) center + offset else row;
                const c = if (is_horizontal) col else center + offset;
                if (self.paneAt(r, c)) |idx| return idx;
            }
            // Try center - offset
            if (center >= span_start + offset) {
                const r = if (is_horizontal) center - offset else row;
                const c = if (is_horizontal) col else center - offset;
                if (self.paneAt(r, c)) |idx| return idx;
            }
        }
        return null;
    }

    /// Return the focused pane.
    pub fn focusedPane(self: *SplitLayout) *Pane {
        return self.pool[self.focused].pane.?;
    }

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

    /// Check all leaf panes for child exit. Returns index of first exited, or null.
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

    /// Walk up from focused leaf to find the nearest ancestor branch matching dir.
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

    pub const SmartTarget = struct {
        branch: u8,
        is_first_child: bool, // true = focused pane is in children[0] subtree
        direction: Direction,
    };

    /// Find the immediate parent branch of the focused leaf.
    /// Returns the branch index, its split direction, and whether the focused
    /// pane is in the first (left/top) child subtree.
    pub fn findSmartResizeTarget(self: *SplitLayout) ?SmartTarget {
        const leaf = self.focused;
        if (leaf == null_index) return null;
        const parent = self.findParent(leaf);
        if (parent == null_index) return null;
        return .{
            .branch = parent,
            .is_first_child = self.pool[parent].children[0] == leaf,
            .direction = self.pool[parent].direction,
        };
    }

    pub fn isZoomed(self: *const SplitLayout) bool {
        return self.zoomed_leaf != null_index;
    }

    /// Toggle zoom on the focused pane. No-op if only one pane.
    pub fn toggleZoom(self: *SplitLayout) void {
        if (self.pane_count <= 1) return;
        if (self.isZoomed()) {
            self.zoomed_leaf = null_index;
        } else {
            self.zoomed_leaf = self.focused;
        }
    }

    /// Cycle pane pointers forward through leaf positions.
    /// The last leaf's pane moves to the first position; all others shift right.
    /// Focus follows the originally-focused pane.
    pub fn rotatePanes(self: *SplitLayout) void {
        if (self.pane_count <= 1) return;

        var leaves: [max_panes]LeafEntry = undefined;
        const count = self.collectLeaves(&leaves);
        if (count <= 1) return;

        const last_pane = leaves[count - 1].pane;
        const focused_pane = self.pool[self.focused].pane;

        // Shift pane pointers: each leaf gets the pane from its left neighbor
        var i: u8 = count - 1;
        while (i > 0) : (i -= 1) {
            self.pool[leaves[i].index].pane = self.pool[leaves[i - 1].index].pane;
        }
        self.pool[leaves[0].index].pane = last_pane;

        for (leaves[0..count]) |leaf| {
            if (self.pool[leaf.index].pane == focused_pane) {
                self.focused = leaf.index;
                break;
            }
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

// Tests are in split_layout_test.zig
test {
    _ = @import("split_layout_test.zig");
}
