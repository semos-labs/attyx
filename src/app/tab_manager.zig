// Attyx — TabManager: manages multiple tabs, each with a SplitLayout
//
// Holds a fixed-size array of SplitLayouts. Tracks the active
// tab index. Supports add, close, switch, and resize-all operations.
// Each tab can contain multiple split panes via its SplitLayout.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Pane = @import("pane.zig").Pane;
const split_layout_mod = @import("split_layout.zig");
const SplitLayout = split_layout_mod.SplitLayout;
const layout_codec = @import("layout_codec.zig");
const platform = @import("../platform/platform.zig");

pub const max_tabs = 16;

pub const TabManager = struct {
    tabs: [max_tabs]?SplitLayout = .{null} ** max_tabs,
    count: u8 = 0,
    active: u8 = 0,
    allocator: Allocator,
    split_gap_h: u16 = 1,
    split_gap_v: u16 = 1,

    /// Create a TabManager with an initial pane at index 0.
    pub fn init(allocator: Allocator, initial_pane: *Pane) TabManager {
        var mgr = TabManager{
            .allocator = allocator,
        };
        var sl = SplitLayout.init(initial_pane);
        // Set initial rects from the pane's engine dimensions so splitPane()
        // can read correct rects even before the first window resize event.
        sl.layout(
            @intCast(initial_pane.engine.state.grid.rows),
            @intCast(initial_pane.engine.state.grid.cols),
        );
        mgr.tabs[0] = sl;
        mgr.count = 1;
        mgr.active = 0;
        return mgr;
    }

    /// Deinit and free all panes across all tabs.
    pub fn deinit(self: *TabManager) void {
        for (&self.tabs) |*slot| {
            if (slot.*) |*layout| {
                layout.deinitAll(self.allocator);
                slot.* = null;
            }
        }
        self.count = 0;
    }

    /// Return the currently active pane (focused pane of the active tab's layout).
    pub fn activePane(self: *TabManager) *Pane {
        return self.tabs[self.active].?.focusedPane();
    }

    /// Return the active tab's SplitLayout.
    pub fn activeLayout(self: *TabManager) *SplitLayout {
        return &(self.tabs[self.active].?);
    }

    /// Spawn a new tab. Inserts after the active tab.
    /// argv=null spawns the default shell.
    pub fn addTab(
        self: *TabManager,
        rows: u16,
        cols: u16,
        cwd: ?[*:0]const u8,
    ) !void {
        if (self.count >= max_tabs) return error.TooManyTabs;

        const pane = try self.allocator.create(Pane);
        errdefer self.allocator.destroy(pane);
        pane.* = try Pane.spawn(self.allocator, rows, cols, null, cwd);

        self.insertTab(pane, rows, cols);
    }

    /// Add a new tab backed by a daemon PTY (no local PTY spawn).
    pub fn addDaemonTab(self: *TabManager, rows: u16, cols: u16) !*Pane {
        if (self.count >= max_tabs) return error.TooManyTabs;

        const pane = try self.allocator.create(Pane);
        errdefer self.allocator.destroy(pane);
        pane.* = try Pane.initDaemonBacked(self.allocator, rows, cols);

        self.insertTab(pane, rows, cols);
        return pane;
    }

    fn insertTab(self: *TabManager, pane: *Pane, rows: u16, cols: u16) void {
        // Append new tab at the end
        const insert_at: u8 = self.count;
        var layout = SplitLayout.init(pane);
        layout.setGaps(self.split_gap_h, self.split_gap_v);
        layout.layout(rows, cols);
        self.tabs[insert_at] = layout;
        self.count += 1;
        self.active = insert_at;
    }

    /// Close the tab at the given index. Deinits all panes in its layout,
    /// shifts remaining tabs, and adjusts the active index.
    pub fn closeTab(self: *TabManager, index: u8) void {
        if (index >= self.count) return;
        if (self.tabs[index]) |*layout| {
            layout.deinitAll(self.allocator);
        }

        // Shift remaining tabs left
        var i: u8 = index;
        while (i + 1 < self.count) : (i += 1) {
            self.tabs[i] = self.tabs[i + 1];
        }
        self.tabs[self.count - 1] = null;
        self.count -= 1;

        // Adjust active index
        if (self.count == 0) {
            self.active = 0;
        } else if (self.active >= self.count) {
            self.active = self.count - 1;
        } else if (self.active > index) {
            self.active -= 1;
        }
    }

    /// Switch to the tab at the given index.
    pub fn switchTo(self: *TabManager, index: u8) void {
        if (index < self.count) {
            self.active = index;
        }
    }

    /// Switch to the next tab (wraps around).
    pub fn nextTab(self: *TabManager) void {
        if (self.count <= 1) return;
        self.active = (self.active + 1) % self.count;
    }

    /// Switch to the previous tab (wraps around).
    pub fn prevTab(self: *TabManager) void {
        if (self.count <= 1) return;
        if (self.active == 0) {
            self.active = self.count - 1;
        } else {
            self.active -= 1;
        }
    }

    /// Move the active tab one position to the left (wraps around).
    pub fn moveTabLeft(self: *TabManager) void {
        if (self.count <= 1) return;
        const dst = if (self.active == 0) self.count - 1 else self.active - 1;
        const tmp = self.tabs[self.active];
        self.tabs[self.active] = self.tabs[dst];
        self.tabs[dst] = tmp;
        self.active = dst;
    }

    /// Move the active tab one position to the right (wraps around).
    pub fn moveTabRight(self: *TabManager) void {
        if (self.count <= 1) return;
        const dst = if (self.active + 1 >= self.count) 0 else self.active + 1;
        const tmp = self.tabs[self.active];
        self.tabs[self.active] = self.tabs[dst];
        self.tabs[dst] = tmp;
        self.active = dst;
    }

    /// Resize all tabs. For each tab, calls layout() which recursively
    /// resizes all split panes to fit within the given dimensions.
    pub fn resizeAll(self: *TabManager, rows: u16, cols: u16) void {
        for (self.tabs[0..self.count]) |*maybe_layout| {
            if (maybe_layout.*) |*layout| {
                layout.layout(rows, cols);
            }
        }
    }

    /// Update split gap sizes and propagate to all existing tab layouts.
    pub fn updateGaps(self: *TabManager, h: u16, v: u16) void {
        self.split_gap_h = h;
        self.split_gap_v = v;
        for (self.tabs[0..self.count]) |*maybe_layout| {
            if (maybe_layout.*) |*layout| {
                layout.setGaps(h, v);
            }
        }
    }

    /// Reset: deinit all panes/tabs but keep the TabManager alive for reuse.
    pub fn reset(self: *TabManager) void {
        for (&self.tabs) |*slot| {
            if (slot.*) |*lay| {
                lay.deinitAll(self.allocator);
                slot.* = null;
            }
        }
        self.count = 0;
        self.active = 0;
    }

    /// Serialize current tab/split state into a layout blob for the daemon.
    pub fn serializeLayout(self: *TabManager, buf: []u8) !u16 {
        var info = layout_codec.LayoutInfo{};
        info.tab_count = self.count;
        info.active_tab = self.active;
        if (self.count > 0) {
            const ap = self.activePane();
            info.focused_pane_id = ap.daemon_pane_id orelse 0;
        }

        for (0..self.count) |ti| {
            if (self.tabs[ti]) |*lay| {
                var tab = &info.tabs[ti];
                // Remap pool indices to compact indices (skip empty slots)
                var remap: [split_layout_mod.max_nodes]u8 = .{0xFF} ** split_layout_mod.max_nodes;
                var compact_count: u8 = 0;
                for (lay.pool, 0..) |node, ni| {
                    if (node.tag != .empty) {
                        remap[ni] = compact_count;
                        compact_count += 1;
                    }
                }
                tab.node_count = compact_count;
                tab.root_idx = if (lay.root < split_layout_mod.max_nodes) remap[lay.root] else 0;
                tab.focused_idx = if (lay.focused < split_layout_mod.max_nodes) remap[lay.focused] else 0;

                // Capture the displayed tab title using the same fallback chain
                // as resolveTabTitles: OSC title → local proc name → daemon proc name.
                const focused_pane = lay.focusedPane();
                const title_src: ?[]const u8 = focused_pane.engine.state.title orelse blk: {
                    var name_buf: [256]u8 = undefined;
                    if (platform.getForegroundProcessName(focused_pane.pty.master, &name_buf)) |name|
                        break :blk name;
                    break :blk focused_pane.getDaemonProcName();
                };
                if (title_src) |t| {
                    const len = @min(t.len, layout_codec.max_title_len);
                    @memcpy(tab.title[0..len], t[0..len]);
                    tab.title_len = @intCast(len);
                } else {
                    tab.title_len = 0;
                }

                var ci: u8 = 0;
                for (lay.pool) |node| {
                    switch (node.tag) {
                        .leaf => {
                            tab.nodes[ci] = .{
                                .tag = .leaf,
                                .pane_id = if (node.pane) |p| p.daemon_pane_id orelse 0 else 0,
                            };
                            ci += 1;
                        },
                        .branch => {
                            tab.nodes[ci] = .{
                                .tag = .branch,
                                .direction = switch (node.direction) {
                                    .vertical => .vertical,
                                    .horizontal => .horizontal,
                                },
                                .ratio_x100 = @intFromFloat(node.ratio * 100.0),
                                .child_left = if (node.children[0] < split_layout_mod.max_nodes) remap[node.children[0]] else 0xFF,
                                .child_right = if (node.children[1] < split_layout_mod.max_nodes) remap[node.children[1]] else 0xFF,
                            };
                            ci += 1;
                        },
                        .empty => {},
                    }
                }
            }
        }

        return layout_codec.serialize(&info, buf);
    }

    /// Reconstruct tabs/splits from a deserialized layout blob. Creates
    /// daemon-backed panes (engine only, no local PTY) with daemon_pane_id set.
    pub fn reconstructFromLayout(
        self: *TabManager,
        info: *const layout_codec.LayoutInfo,
        rows: u16,
        cols: u16,
    ) !void {
        self.reset();

        for (0..info.tab_count) |ti| {
            const tab = &info.tabs[ti];
            if (tab.node_count == 0) continue;

            var sl = SplitLayout{};
            sl.setGaps(self.split_gap_h, self.split_gap_v);
            var pane_count: u8 = 0;

            for (0..tab.node_count) |ni| {
                const node = &tab.nodes[ni];
                switch (node.tag) {
                    .leaf => {
                        const pane = try self.allocator.create(Pane);
                        errdefer self.allocator.destroy(pane);
                        pane.* = try Pane.initDaemonBacked(self.allocator, rows, cols);
                        pane.daemon_pane_id = node.pane_id;
                        sl.pool[ni] = .{ .tag = .leaf, .pane = pane };
                        pane_count += 1;
                    },
                    .branch => {
                        sl.pool[ni] = .{
                            .tag = .branch,
                            .direction = switch (node.direction) {
                                .vertical => .vertical,
                                .horizontal => .horizontal,
                            },
                            .ratio = @as(f32, @floatFromInt(node.ratio_x100)) / 100.0,
                            .children = .{ node.child_left, node.child_right },
                        };
                    },
                }
            }

            sl.root = tab.root_idx;
            sl.focused = tab.focused_idx;
            sl.pane_count = pane_count;
            sl.layout(rows, cols);

            // Restore tab title as daemon_proc_name (lowest-priority fallback).
            // This shows initially but gets replaced when the daemon reports
            // real process name updates — avoids blocking OSC title resolution.
            if (tab.getTitle()) |title| {
                const pane = sl.focusedPane();
                const len: u8 = @intCast(@min(title.len, 64));
                @memcpy(pane.daemon_proc_name[0..len], title[0..len]);
                pane.daemon_proc_name_len = len;
            }

            self.tabs[self.count] = sl;
            self.count += 1;
        }

        if (info.active_tab < self.count) {
            self.active = info.active_tab;
        }
    }
};
