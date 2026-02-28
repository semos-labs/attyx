// Attyx — TabManager: manages multiple Panes (tabs) with switching
//
// Holds a fixed-size array of heap-allocated Panes. Tracks the active
// tab index. Supports add, close, switch, and resize-all operations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Pane = @import("pane.zig").Pane;

pub const max_tabs = 16;

pub const TabManager = struct {
    tabs: [max_tabs]?*Pane = .{null} ** max_tabs,
    count: u8 = 0,
    active: u8 = 0,
    allocator: Allocator,

    /// Create a TabManager with an initial pane at index 0.
    pub fn init(allocator: Allocator, initial_pane: *Pane) TabManager {
        var mgr = TabManager{
            .allocator = allocator,
        };
        mgr.tabs[0] = initial_pane;
        mgr.count = 1;
        mgr.active = 0;
        return mgr;
    }

    /// Deinit and free all panes.
    pub fn deinit(self: *TabManager) void {
        for (&self.tabs) |*slot| {
            if (slot.*) |pane| {
                pane.deinit();
                self.allocator.destroy(pane);
                slot.* = null;
            }
        }
        self.count = 0;
    }

    /// Return the currently active pane.
    pub fn activePane(self: *TabManager) *Pane {
        return self.tabs[self.active].?;
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
        self.tabs[insert_at] = pane;
        self.count += 1;
        self.active = insert_at;
    }

    /// Close the tab at the given index. Deinits the pane, shifts
    /// remaining tabs, and adjusts the active index.
    pub fn closeTab(self: *TabManager, index: u8) void {
        if (index >= self.count) return;
        if (self.tabs[index]) |pane| {
            pane.deinit();
            self.allocator.destroy(pane);
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

    /// Resize all panes to the given dimensions.
    pub fn resizeAll(self: *TabManager, rows: u16, cols: u16) void {
        for (self.tabs[0..self.count]) |maybe_pane| {
            if (maybe_pane) |pane| {
                pane.resize(rows, cols);
            }
        }
    }
};
