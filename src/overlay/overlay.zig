const std = @import("std");
const anchor_mod = @import("anchor.zig");
const action_mod = @import("action.zig");

pub const OverlayId = enum(u8) { debug_card = 0, anchor_demo = 1 };

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const OverlayStyle = struct {
    bg: Rgb = .{ .r = 30, .g = 30, .b = 40 },
    fg: Rgb = .{ .r = 220, .g = 220, .b = 220 },
    border_color: Rgb = .{ .r = 80, .g = 80, .b = 120 },
    border: bool = true,
    bg_alpha: u8 = 230,
};

pub const OverlayCell = struct {
    char: u21 = ' ',
    fg: Rgb = .{ .r = 220, .g = 220, .b = 220 },
    bg: Rgb = .{ .r = 30, .g = 30, .b = 40 },
    bg_alpha: u8 = 230,
};

pub const OverlayLayer = struct {
    visible: bool = false,
    col: u16 = 0,
    row: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,
    cells: ?[]OverlayCell = null,
    style: OverlayStyle = .{},
    z_order: u8 = 0,
    anchor: ?anchor_mod.Anchor = null,
    placement_constraints: anchor_mod.PlacementConstraints = .{},
    action_bar: ?action_mod.ActionBar = null,
};

pub const max_layers = 16;

pub const OverlayManager = struct {
    layers: [max_layers]OverlayLayer,
    allocator: std.mem.Allocator,
    gen: u32 = 0,
    grid_cols: u16 = 0,
    grid_rows: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) OverlayManager {
        return .{
            .layers = [_]OverlayLayer{.{}} ** max_layers,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OverlayManager) void {
        for (&self.layers) |*layer| {
            if (layer.cells) |cells| {
                self.allocator.free(cells);
                layer.cells = null;
            }
        }
    }

    pub fn show(self: *OverlayManager, id: OverlayId) void {
        self.layers[@intFromEnum(id)].visible = true;
        self.gen +%= 1;
    }

    pub fn hide(self: *OverlayManager, id: OverlayId) void {
        self.layers[@intFromEnum(id)].visible = false;
        self.gen +%= 1;
    }

    pub fn toggle(self: *OverlayManager, id: OverlayId) void {
        const layer = &self.layers[@intFromEnum(id)];
        layer.visible = !layer.visible;
        self.gen +%= 1;
    }

    pub fn isVisible(self: *const OverlayManager, id: OverlayId) bool {
        return self.layers[@intFromEnum(id)].visible;
    }

    pub fn setContent(
        self: *OverlayManager,
        id: OverlayId,
        col: u16,
        row: u16,
        width: u16,
        height: u16,
        cells: []OverlayCell,
    ) !void {
        const idx = @intFromEnum(id);
        const layer = &self.layers[idx];

        if (layer.cells) |old| {
            self.allocator.free(old);
        }

        const new_cells = try self.allocator.alloc(OverlayCell, cells.len);
        @memcpy(new_cells, cells);

        layer.col = col;
        layer.row = row;
        layer.width = width;
        layer.height = height;
        layer.cells = new_cells;
        self.gen +%= 1;
    }

    pub fn relayout(self: *OverlayManager, grid_cols: u16, grid_rows: u16) void {
        self.grid_cols = grid_cols;
        self.grid_rows = grid_rows;

        for (&self.layers) |*layer| {
            if (!layer.visible or layer.cells == null) continue;

            // Clamp position so overlay fits within the grid
            if (layer.width > grid_cols) {
                layer.col = 0;
            } else if (layer.col + layer.width > grid_cols) {
                layer.col = grid_cols - layer.width;
            }

            if (layer.height > grid_rows) {
                layer.row = 0;
            } else if (layer.row + layer.height > grid_rows) {
                layer.row = grid_rows - layer.height;
            }
        }

        self.gen +%= 1;
    }

    /// Relayout with viewport-aware anchor placement. For layers with an
    /// anchor, calls placeOverlay() to recompute position. For layers
    /// without an anchor, uses existing clamp logic.
    pub fn relayoutAnchored(self: *OverlayManager, vp: anchor_mod.ViewportInfo) void {
        self.grid_cols = vp.grid_cols;
        self.grid_rows = vp.grid_rows;

        for (&self.layers) |*layer| {
            if (!layer.visible or layer.cells == null) continue;

            if (layer.anchor) |anch| {
                const rect = anchor_mod.placeOverlay(
                    anch,
                    layer.width,
                    layer.height,
                    vp,
                    layer.placement_constraints,
                );
                layer.col = rect.col;
                layer.row = rect.row;
            } else {
                // Fallback: simple clamp
                if (layer.width > vp.grid_cols) {
                    layer.col = 0;
                } else if (layer.col + layer.width > vp.grid_cols) {
                    layer.col = vp.grid_cols - layer.width;
                }
                if (layer.height > vp.grid_rows) {
                    layer.row = 0;
                } else if (layer.row + layer.height > vp.grid_rows) {
                    layer.row = vp.grid_rows - layer.height;
                }
            }
        }

        self.gen +%= 1;
    }

    /// Advance focus on topmost visible layer with actions. Returns true if focus changed.
    pub fn cycleFocus(self: *OverlayManager) bool {
        var i: usize = max_layers;
        while (i > 0) {
            i -= 1;
            const layer = &self.layers[i];
            if (layer.visible and layer.action_bar != null and layer.action_bar.?.hasActions()) {
                layer.action_bar.?.focusNext();
                self.gen +%= 1;
                return true;
            }
        }
        return false;
    }

    /// Return the focused action's ID on topmost active layer.
    pub fn activateFocused(self: *OverlayManager) ?action_mod.ActionId {
        var i: usize = max_layers;
        while (i > 0) {
            i -= 1;
            const layer = &self.layers[i];
            if (layer.visible and layer.action_bar != null and layer.action_bar.?.hasActions()) {
                return layer.action_bar.?.focusedId();
            }
        }
        return null;
    }

    /// Hide topmost visible layer with actions, clear its action_bar. Returns true if dismissed.
    pub fn dismissActive(self: *OverlayManager) bool {
        var i: usize = max_layers;
        while (i > 0) {
            i -= 1;
            const layer = &self.layers[i];
            if (layer.visible and layer.action_bar != null and layer.action_bar.?.hasActions()) {
                layer.visible = false;
                layer.action_bar = null;
                self.gen +%= 1;
                return true;
            }
        }
        return false;
    }

    /// Returns true if any visible layer has a non-empty action_bar.
    pub fn hasActiveActions(self: *const OverlayManager) bool {
        for (&self.layers) |*layer| {
            if (layer.visible and layer.action_bar != null and layer.action_bar.?.hasActions()) {
                return true;
            }
        }
        return false;
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "OverlayManager: init/deinit" {
    var mgr = OverlayManager.init(std.testing.allocator);
    defer mgr.deinit();

    try std.testing.expect(!mgr.isVisible(.debug_card));
    try std.testing.expectEqual(@as(u32, 0), mgr.gen);
}

test "OverlayManager: show/hide/toggle" {
    var mgr = OverlayManager.init(std.testing.allocator);
    defer mgr.deinit();

    mgr.show(.debug_card);
    try std.testing.expect(mgr.isVisible(.debug_card));
    try std.testing.expectEqual(@as(u32, 1), mgr.gen);

    mgr.hide(.debug_card);
    try std.testing.expect(!mgr.isVisible(.debug_card));
    try std.testing.expectEqual(@as(u32, 2), mgr.gen);

    mgr.toggle(.debug_card);
    try std.testing.expect(mgr.isVisible(.debug_card));
    try std.testing.expectEqual(@as(u32, 3), mgr.gen);
}

test "OverlayManager: setContent" {
    var mgr = OverlayManager.init(std.testing.allocator);
    defer mgr.deinit();

    var cells = [_]OverlayCell{
        .{ .char = 'H' },
        .{ .char = 'i' },
    };
    try mgr.setContent(.debug_card, 5, 3, 2, 1, &cells);

    const layer = mgr.layers[0];
    try std.testing.expectEqual(@as(u16, 5), layer.col);
    try std.testing.expectEqual(@as(u16, 3), layer.row);
    try std.testing.expectEqual(@as(u16, 2), layer.width);
    try std.testing.expectEqual(@as(u16, 1), layer.height);
    try std.testing.expectEqual(@as(usize, 2), layer.cells.?.len);
    try std.testing.expectEqual(@as(u21, 'H'), layer.cells.?[0].char);
}

test "OverlayManager: relayout clamps position" {
    var mgr = OverlayManager.init(std.testing.allocator);
    defer mgr.deinit();

    var cells: [6]OverlayCell = undefined;
    for (&cells) |*cell| cell.* = .{};
    try mgr.setContent(.debug_card, 78, 22, 3, 2, &cells);
    mgr.show(.debug_card);

    // Shrink grid so overlay no longer fits
    mgr.relayout(80, 24);
    try std.testing.expect(mgr.layers[0].col + mgr.layers[0].width <= 80);
    try std.testing.expect(mgr.layers[0].row + mgr.layers[0].height <= 24);
}

test "OverlayManager: cycleFocus advances focus" {
    var mgr = OverlayManager.init(std.testing.allocator);
    defer mgr.deinit();

    // No visible layers with actions — cycleFocus returns false
    try std.testing.expect(!mgr.cycleFocus());

    // Add action bar to debug_card layer
    var bar = action_mod.ActionBar{};
    bar.add(.dismiss, "Dismiss");
    bar.add(.copy, "Copy");
    mgr.layers[0].action_bar = bar;
    mgr.layers[0].visible = true;

    const gen_before = mgr.gen;
    try std.testing.expect(mgr.cycleFocus());
    try std.testing.expect(mgr.gen > gen_before);
    try std.testing.expectEqual(@as(u8, 1), mgr.layers[0].action_bar.?.focused);
}

test "OverlayManager: activateFocused returns correct id" {
    var mgr = OverlayManager.init(std.testing.allocator);
    defer mgr.deinit();

    // No active layers
    try std.testing.expectEqual(@as(?action_mod.ActionId, null), mgr.activateFocused());

    var bar = action_mod.ActionBar{};
    bar.add(.dismiss, "Dismiss");
    bar.add(.insert, "Insert");
    mgr.layers[0].action_bar = bar;
    mgr.layers[0].visible = true;

    try std.testing.expectEqual(@as(?action_mod.ActionId, .dismiss), mgr.activateFocused());

    _ = mgr.cycleFocus();
    try std.testing.expectEqual(@as(?action_mod.ActionId, .insert), mgr.activateFocused());
}

test "OverlayManager: dismissActive hides and clears" {
    var mgr = OverlayManager.init(std.testing.allocator);
    defer mgr.deinit();

    var bar = action_mod.ActionBar{};
    bar.add(.dismiss, "Dismiss");
    mgr.layers[0].action_bar = bar;
    mgr.layers[0].visible = true;

    try std.testing.expect(mgr.hasActiveActions());
    const gen_before = mgr.gen;
    try std.testing.expect(mgr.dismissActive());
    try std.testing.expect(mgr.gen > gen_before);
    try std.testing.expect(!mgr.layers[0].visible);
    try std.testing.expectEqual(@as(?action_mod.ActionBar, null), mgr.layers[0].action_bar);
    try std.testing.expect(!mgr.hasActiveActions());
}

test "OverlayManager: hasActiveActions" {
    var mgr = OverlayManager.init(std.testing.allocator);
    defer mgr.deinit();

    try std.testing.expect(!mgr.hasActiveActions());

    // Visible but no action_bar
    mgr.layers[0].visible = true;
    try std.testing.expect(!mgr.hasActiveActions());

    // Visible with empty action_bar
    mgr.layers[0].action_bar = action_mod.ActionBar{};
    try std.testing.expect(!mgr.hasActiveActions());

    // Visible with non-empty action_bar
    var bar = action_mod.ActionBar{};
    bar.add(.dismiss, "Dismiss");
    mgr.layers[0].action_bar = bar;
    try std.testing.expect(mgr.hasActiveActions());

    // Not visible
    mgr.layers[0].visible = false;
    try std.testing.expect(!mgr.hasActiveActions());
}
