const std = @import("std");

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const CellRect = struct {
    col: u16,
    row: u16,
    width: u16,
    height: u16,

    pub fn right(self: CellRect) u16 {
        return self.col +| self.width;
    }

    pub fn bottom(self: CellRect) u16 {
        return self.row +| self.height;
    }
};

pub const AnchorKind = enum(u8) {
    after_command,
    selection_end,
    cursor_line,
    viewport_dock,
};

pub const DockPosition = enum(u8) {
    bottom_right,
    bottom_left,
    top_right,
    top_left,
};

pub const Anchor = struct {
    kind: AnchorKind,
    command_row_hint: ?u16 = null,
    dock: DockPosition = .bottom_right,
};

pub const ViewportInfo = struct {
    grid_cols: u16,
    grid_rows: u16,
    cursor_row: u16,
    cursor_col: u16,
    sel_active: bool,
    sel_end_row: u16,
    sel_end_col: u16,
    alt_active: bool,
};

pub const PlacementConstraints = struct {
    max_width_frac: f32 = 0.75,
    max_height_frac: f32 = 0.40,
    margin: u16 = 1,
};

// ---------------------------------------------------------------------------
// Anchor Resolution
// ---------------------------------------------------------------------------

/// Converts an anchor to a cell rect. Returns null if the anchor is invalid
/// (selection inactive, cursor off-grid, no command hint, etc.).
pub fn resolveAnchor(anchor: Anchor, vp: ViewportInfo) ?CellRect {
    return switch (anchor.kind) {
        .after_command => resolveAfterCommand(anchor, vp),
        .selection_end => resolveSelectionEnd(vp),
        .cursor_line => resolveCursorLine(vp),
        .viewport_dock => resolveViewportDock(anchor, vp),
    };
}

fn resolveAfterCommand(anchor: Anchor, vp: ViewportInfo) ?CellRect {
    const hint = anchor.command_row_hint orelse return null;
    if (hint >= vp.grid_rows) return null;
    return .{
        .col = 0,
        .row = hint,
        .width = vp.grid_cols,
        .height = 1,
    };
}

fn resolveSelectionEnd(vp: ViewportInfo) ?CellRect {
    if (!vp.sel_active) return null;
    if (vp.sel_end_row >= vp.grid_rows or vp.sel_end_col >= vp.grid_cols) return null;
    return .{
        .col = vp.sel_end_col,
        .row = vp.sel_end_row,
        .width = 1,
        .height = 1,
    };
}

fn resolveCursorLine(vp: ViewportInfo) ?CellRect {
    if (vp.cursor_row >= vp.grid_rows or vp.cursor_col >= vp.grid_cols) return null;
    return .{
        .col = vp.cursor_col,
        .row = vp.cursor_row,
        .width = 1,
        .height = 1,
    };
}

fn resolveViewportDock(anchor: Anchor, vp: ViewportInfo) ?CellRect {
    return dockRect(anchor.dock, vp);
}

fn dockRect(dock: DockPosition, vp: ViewportInfo) CellRect {
    return switch (dock) {
        .bottom_right => .{
            .col = if (vp.grid_cols > 0) vp.grid_cols - 1 else 0,
            .row = if (vp.grid_rows > 0) vp.grid_rows - 1 else 0,
            .width = 1,
            .height = 1,
        },
        .bottom_left => .{
            .col = 0,
            .row = if (vp.grid_rows > 0) vp.grid_rows - 1 else 0,
            .width = 1,
            .height = 1,
        },
        .top_right => .{
            .col = if (vp.grid_cols > 0) vp.grid_cols - 1 else 0,
            .row = 0,
            .width = 1,
            .height = 1,
        },
        .top_left => .{
            .col = 0,
            .row = 0,
            .width = 1,
            .height = 1,
        },
    };
}

// ---------------------------------------------------------------------------
// Placement Computation
// ---------------------------------------------------------------------------

/// Compute a placement rectangle for an overlay of desired size, anchored
/// to the given anchor_rect, constrained to the viewport.
pub fn computePlacement(
    anchor_rect: CellRect,
    desired_w: u16,
    desired_h: u16,
    vp: ViewportInfo,
    constraints: PlacementConstraints,
) CellRect {
    const margin = constraints.margin;
    const usable_cols = if (vp.grid_cols > margin * 2) vp.grid_cols - margin * 2 else 1;
    const usable_rows = if (vp.grid_rows > margin * 2) vp.grid_rows - margin * 2 else 1;

    // 1. Clamp desired size to max fractions
    const max_w = clampToFrac(usable_cols, constraints.max_width_frac);
    const max_h = clampToFrac(usable_rows, constraints.max_height_frac);
    const w = clampU16(desired_w, 1, max_w);
    const h = clampU16(desired_h, 1, max_h);

    // 2. Vertical: prefer below anchor, else above, else whichever has more space
    const row = pickVertical(anchor_rect, h, margin, vp.grid_rows);

    // 3. Horizontal: align left to anchor col, clamp right edge
    const col = pickHorizontal(anchor_rect, w, margin, vp.grid_cols);

    return .{ .col = col, .row = row, .width = w, .height = h };
}

fn clampToFrac(usable: u16, frac: f32) u16 {
    const f: f32 = @floatFromInt(usable);
    const result = @as(u16, @intFromFloat(@max(1.0, @min(f, f * frac))));
    return if (result == 0) 1 else result;
}

fn clampU16(val: u16, lo: u16, hi: u16) u16 {
    if (val < lo) return lo;
    if (val > hi) return hi;
    return val;
}

fn pickVertical(anchor_rect: CellRect, h: u16, margin: u16, grid_rows: u16) u16 {
    const anchor_bottom = anchor_rect.bottom();
    const space_below = if (grid_rows > anchor_bottom + margin)
        grid_rows - anchor_bottom - margin
    else
        0;

    if (space_below >= h) {
        // Place below anchor
        return anchor_bottom;
    }

    // Check above
    const space_above = if (anchor_rect.row > margin)
        anchor_rect.row - margin
    else
        0;

    if (space_above >= h) {
        // Place above anchor
        return anchor_rect.row -| h;
    }

    // Pick whichever side has more space, and clamp
    if (space_below >= space_above) {
        // Place below, might overlap
        return if (grid_rows > h + margin) grid_rows - h - margin else 0;
    } else {
        return margin;
    }
}

fn pickHorizontal(anchor_rect: CellRect, w: u16, margin: u16, grid_cols: u16) u16 {
    var col = anchor_rect.col;
    // Clamp right edge within grid_cols - margin
    if (col + w + margin > grid_cols) {
        col = if (grid_cols > w + margin) grid_cols - w - margin else 0;
    }
    // Ensure left edge is at least margin
    if (col < margin) col = margin;
    return col;
}

// ---------------------------------------------------------------------------
// High-Level: placeOverlay
// ---------------------------------------------------------------------------

/// Resolve anchor + compute placement. If the anchor is invalid, falls back
/// to the dock position specified in `anchor.dock`.
pub fn placeOverlay(
    anchor: Anchor,
    desired_w: u16,
    desired_h: u16,
    vp: ViewportInfo,
    constraints: PlacementConstraints,
) CellRect {
    const anchor_rect = resolveAnchor(anchor, vp) orelse dockRect(anchor.dock, vp);
    return computePlacement(anchor_rect, desired_w, desired_h, vp, constraints);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolveAnchor: after_command valid" {
    const vp = ViewportInfo{
        .grid_cols = 80, .grid_rows = 24,
        .cursor_row = 5, .cursor_col = 10,
        .sel_active = false, .sel_end_row = 0, .sel_end_col = 0,
        .alt_active = false,
    };
    const anchor = Anchor{ .kind = .after_command, .command_row_hint = 10 };
    const rect = resolveAnchor(anchor, vp).?;
    try std.testing.expectEqual(@as(u16, 0), rect.col);
    try std.testing.expectEqual(@as(u16, 10), rect.row);
    try std.testing.expectEqual(@as(u16, 80), rect.width);
    try std.testing.expectEqual(@as(u16, 1), rect.height);
}

test "resolveAnchor: after_command null hint" {
    const vp = ViewportInfo{
        .grid_cols = 80, .grid_rows = 24,
        .cursor_row = 5, .cursor_col = 10,
        .sel_active = false, .sel_end_row = 0, .sel_end_col = 0,
        .alt_active = false,
    };
    const anchor = Anchor{ .kind = .after_command, .command_row_hint = null };
    try std.testing.expect(resolveAnchor(anchor, vp) == null);
}

test "resolveAnchor: after_command out of range" {
    const vp = ViewportInfo{
        .grid_cols = 80, .grid_rows = 24,
        .cursor_row = 5, .cursor_col = 10,
        .sel_active = false, .sel_end_row = 0, .sel_end_col = 0,
        .alt_active = false,
    };
    const anchor = Anchor{ .kind = .after_command, .command_row_hint = 30 };
    try std.testing.expect(resolveAnchor(anchor, vp) == null);
}

test "resolveAnchor: selection_end active" {
    const vp = ViewportInfo{
        .grid_cols = 80, .grid_rows = 24,
        .cursor_row = 0, .cursor_col = 0,
        .sel_active = true, .sel_end_row = 15, .sel_end_col = 40,
        .alt_active = false,
    };
    const anchor = Anchor{ .kind = .selection_end };
    const rect = resolveAnchor(anchor, vp).?;
    try std.testing.expectEqual(@as(u16, 40), rect.col);
    try std.testing.expectEqual(@as(u16, 15), rect.row);
}

test "resolveAnchor: selection_end inactive" {
    const vp = ViewportInfo{
        .grid_cols = 80, .grid_rows = 24,
        .cursor_row = 0, .cursor_col = 0,
        .sel_active = false, .sel_end_row = 15, .sel_end_col = 40,
        .alt_active = false,
    };
    const anchor = Anchor{ .kind = .selection_end };
    try std.testing.expect(resolveAnchor(anchor, vp) == null);
}

test "resolveAnchor: cursor_line valid" {
    const vp = ViewportInfo{
        .grid_cols = 80, .grid_rows = 24,
        .cursor_row = 10, .cursor_col = 20,
        .sel_active = false, .sel_end_row = 0, .sel_end_col = 0,
        .alt_active = false,
    };
    const anchor = Anchor{ .kind = .cursor_line };
    const rect = resolveAnchor(anchor, vp).?;
    try std.testing.expectEqual(@as(u16, 20), rect.col);
    try std.testing.expectEqual(@as(u16, 10), rect.row);
}

test "resolveAnchor: viewport_dock always valid" {
    const vp = ViewportInfo{
        .grid_cols = 80, .grid_rows = 24,
        .cursor_row = 0, .cursor_col = 0,
        .sel_active = false, .sel_end_row = 0, .sel_end_col = 0,
        .alt_active = false,
    };
    const anchor = Anchor{ .kind = .viewport_dock, .dock = .bottom_right };
    const rect = resolveAnchor(anchor, vp).?;
    try std.testing.expectEqual(@as(u16, 79), rect.col);
    try std.testing.expectEqual(@as(u16, 23), rect.row);
}

test "computePlacement: prefer below" {
    const vp = ViewportInfo{
        .grid_cols = 80, .grid_rows = 24,
        .cursor_row = 5, .cursor_col = 10,
        .sel_active = false, .sel_end_row = 0, .sel_end_col = 0,
        .alt_active = false,
    };
    const anchor_rect = CellRect{ .col = 10, .row = 5, .width = 1, .height = 1 };
    const result = computePlacement(anchor_rect, 20, 5, vp, .{});
    // Should be placed below anchor (row 6)
    try std.testing.expectEqual(@as(u16, 6), result.row);
    try std.testing.expectEqual(@as(u16, 10), result.col);
}

test "computePlacement: above fallback" {
    const vp = ViewportInfo{
        .grid_cols = 80, .grid_rows = 24,
        .cursor_row = 20, .cursor_col = 10,
        .sel_active = false, .sel_end_row = 0, .sel_end_col = 0,
        .alt_active = false,
    };
    // Anchor near bottom, not enough space below for h=8
    const anchor_rect = CellRect{ .col = 10, .row = 20, .width = 1, .height = 1 };
    const result = computePlacement(anchor_rect, 20, 8, vp, .{});
    // Should be above anchor
    try std.testing.expect(result.row + result.height <= 20);
}

test "computePlacement: horizontal clamp" {
    const vp = ViewportInfo{
        .grid_cols = 80, .grid_rows = 24,
        .cursor_row = 5, .cursor_col = 75,
        .sel_active = false, .sel_end_row = 0, .sel_end_col = 0,
        .alt_active = false,
    };
    // Anchor near right edge, overlay width=20 won't fit starting at col 75
    const anchor_rect = CellRect{ .col = 75, .row = 5, .width = 1, .height = 1 };
    const result = computePlacement(anchor_rect, 20, 3, vp, .{});
    // Right edge should be clamped within grid
    try std.testing.expect(result.col + result.width + 1 <= vp.grid_cols);
}

test "computePlacement: size constraint enforcement" {
    const vp = ViewportInfo{
        .grid_cols = 40, .grid_rows = 20,
        .cursor_row = 5, .cursor_col = 5,
        .sel_active = false, .sel_end_row = 0, .sel_end_col = 0,
        .alt_active = false,
    };
    const anchor_rect = CellRect{ .col = 5, .row = 5, .width = 1, .height = 1 };
    // Request larger than max_width_frac * usable
    const result = computePlacement(anchor_rect, 100, 50, vp, .{});
    const usable_cols = vp.grid_cols - 2; // margin=1 each side
    const usable_rows = vp.grid_rows - 2;
    const max_w = @as(u16, @intFromFloat(@as(f32, @floatFromInt(usable_cols)) * 0.75));
    const max_h = @as(u16, @intFromFloat(@as(f32, @floatFromInt(usable_rows)) * 0.40));
    try std.testing.expect(result.width <= max_w);
    try std.testing.expect(result.height <= max_h);
}

test "placeOverlay: fallback to dock on invalid anchor" {
    const vp = ViewportInfo{
        .grid_cols = 80, .grid_rows = 24,
        .cursor_row = 0, .cursor_col = 0,
        .sel_active = false, .sel_end_row = 0, .sel_end_col = 0,
        .alt_active = false,
    };
    // selection_end with sel_active=false => null anchor => fallback to dock
    const anchor = Anchor{ .kind = .selection_end, .dock = .bottom_right };
    const result = placeOverlay(anchor, 20, 5, vp, .{});
    try std.testing.expect(result.width == 20);
    try std.testing.expect(result.height == 5);
    // Should be placed near bottom-right dock
    try std.testing.expect(result.col + result.width + 1 <= vp.grid_cols);
}

test "placeOverlay: cursor_line positions near cursor" {
    const vp = ViewportInfo{
        .grid_cols = 80, .grid_rows = 24,
        .cursor_row = 10, .cursor_col = 30,
        .sel_active = false, .sel_end_row = 0, .sel_end_col = 0,
        .alt_active = false,
    };
    const anchor = Anchor{ .kind = .cursor_line };
    const result = placeOverlay(anchor, 20, 5, vp, .{});
    // Should be placed below cursor at row 11
    try std.testing.expectEqual(@as(u16, 11), result.row);
    try std.testing.expectEqual(@as(u16, 30), result.col);
}

test "CellRect: right and bottom helpers" {
    const r = CellRect{ .col = 10, .row = 5, .width = 20, .height = 8 };
    try std.testing.expectEqual(@as(u16, 30), r.right());
    try std.testing.expectEqual(@as(u16, 13), r.bottom());
}
