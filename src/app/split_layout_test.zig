// Attyx — SplitLayout unit tests

const std = @import("std");
const Allocator = std.mem.Allocator;
const split_layout_mod = @import("split_layout.zig");
const SplitLayout = split_layout_mod.SplitLayout;
const NodeTag = split_layout_mod.NodeTag;
const LeafEntry = split_layout_mod.LeafEntry;
const max_panes = split_layout_mod.max_panes;

const attyx = @import("attyx");
const Engine = attyx.Engine;
const Pane = @import("pane.zig").Pane;

fn createTestPane(allocator: Allocator) !Pane {
    const engine = try Engine.init(allocator, 24, 80, attyx.Scrollback.default_max_lines);
    return Pane{
        .engine = engine,
        .pty = undefined, // Not used in layout tests
        .allocator = allocator,
    };
}

fn destroyTestPane(_: Allocator, pane: *Pane) void {
    pane.engine.deinit();
}

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
    try std.testing.expectEqual(@as(u8, 1), layout.collectLeaves(&leaves));
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

// ---------------------------------------------------------------------------
// Rotate tests
// ---------------------------------------------------------------------------

test "SplitLayout: rotatePanes with 1 pane is no-op" {
    const allocator = std.testing.allocator;
    var pane_stub = try createTestPane(allocator);
    defer destroyTestPane(allocator, &pane_stub);

    var layout = SplitLayout.init(&pane_stub);
    layout.rotatePanes();
    try std.testing.expectEqual(@as(u8, 1), layout.pane_count);
    try std.testing.expectEqual(&pane_stub, layout.pool[layout.focused].pane.?);
}

test "SplitLayout: rotatePanes with 2 panes swaps and focus follows" {
    const allocator = std.testing.allocator;
    var pane_a = try createTestPane(allocator);
    defer destroyTestPane(allocator, &pane_a);

    var layout = SplitLayout.init(&pane_a);
    layout.layout(24, 80);

    // Create second pane manually
    var pane_b = try createTestPane(allocator);
    defer destroyTestPane(allocator, &pane_b);
    try layout.splitPaneWith(.vertical, &pane_b);
    layout.layout(24, 80);

    // Focus is on pane_b (the newly split pane)
    try std.testing.expectEqual(&pane_b, layout.pool[layout.focused].pane.?);

    // Collect leaves before rotate
    var leaves_before: [max_panes]LeafEntry = undefined;
    const count = layout.collectLeaves(&leaves_before);
    try std.testing.expectEqual(@as(u8, 2), count);
    const first_pane_before = leaves_before[0].pane;
    const second_pane_before = leaves_before[1].pane;

    layout.rotatePanes();

    // After rotate: last pane wraps to first position
    var leaves_after: [max_panes]LeafEntry = undefined;
    _ = layout.collectLeaves(&leaves_after);
    try std.testing.expectEqual(second_pane_before, leaves_after[0].pane);
    try std.testing.expectEqual(first_pane_before, leaves_after[1].pane);

    // Focus should still be on pane_b
    try std.testing.expectEqual(&pane_b, layout.pool[layout.focused].pane.?);
}

test "SplitLayout: rotatePanes with 3 panes cycles correctly" {
    const allocator = std.testing.allocator;
    var pane_a = try createTestPane(allocator);
    defer destroyTestPane(allocator, &pane_a);

    var layout = SplitLayout.init(&pane_a);
    layout.layout(24, 80);

    var pane_b = try createTestPane(allocator);
    defer destroyTestPane(allocator, &pane_b);
    try layout.splitPaneWith(.vertical, &pane_b);
    layout.layout(24, 80);

    var pane_c = try createTestPane(allocator);
    defer destroyTestPane(allocator, &pane_c);
    try layout.splitPaneWith(.horizontal, &pane_c);
    layout.layout(24, 80);

    try std.testing.expectEqual(@as(u8, 3), layout.pane_count);

    // Collect before rotate
    var leaves: [max_panes]LeafEntry = undefined;
    _ = layout.collectLeaves(&leaves);
    const p0 = leaves[0].pane;
    const p1 = leaves[1].pane;
    const p2 = leaves[2].pane;

    layout.rotatePanes();

    // After rotate: [p2, p0, p1]
    _ = layout.collectLeaves(&leaves);
    try std.testing.expectEqual(p2, leaves[0].pane);
    try std.testing.expectEqual(p0, leaves[1].pane);
    try std.testing.expectEqual(p1, leaves[2].pane);
}

// ---------------------------------------------------------------------------
// Zoom tests
// ---------------------------------------------------------------------------

test "SplitLayout: toggleZoom with 1 pane is no-op" {
    const allocator = std.testing.allocator;
    var pane_stub = try createTestPane(allocator);
    defer destroyTestPane(allocator, &pane_stub);

    var layout = SplitLayout.init(&pane_stub);
    layout.toggleZoom();
    try std.testing.expect(!layout.isZoomed());
}

test "SplitLayout: toggleZoom sets and clears zoomed_leaf" {
    const allocator = std.testing.allocator;
    var pane_a = try createTestPane(allocator);
    defer destroyTestPane(allocator, &pane_a);

    var layout = SplitLayout.init(&pane_a);
    layout.layout(24, 80);

    var pane_b = try createTestPane(allocator);
    defer destroyTestPane(allocator, &pane_b);
    try layout.splitPaneWith(.vertical, &pane_b);
    layout.layout(24, 80);

    try std.testing.expect(!layout.isZoomed());

    // Zoom
    layout.toggleZoom();
    try std.testing.expect(layout.isZoomed());
    try std.testing.expectEqual(layout.focused, layout.zoomed_leaf);

    // Unzoom
    layout.toggleZoom();
    try std.testing.expect(!layout.isZoomed());
}
