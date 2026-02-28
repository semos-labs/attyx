// Attyx — TabManager: manages multiple tabs, each with a SplitLayout
//
// Holds a fixed-size array of SplitLayouts. Tracks the active
// tab index. Supports add, close, switch, and resize-all operations.
// Each tab can contain multiple split panes via its SplitLayout.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Pane = @import("pane.zig").Pane;
const SplitLayout = @import("split_layout.zig").SplitLayout;

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

        // Insert after active tab: shift everything right
        const insert_at: u8 = self.active + 1;
        var i: u8 = self.count;
        while (i > insert_at) : (i -= 1) {
            self.tabs[i] = self.tabs[i - 1];
        }
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
};
