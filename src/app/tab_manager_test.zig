// Attyx — TabManager unit tests: IPC ID stability across session switches

const std = @import("std");
const Allocator = std.mem.Allocator;
const TabManager = @import("tab_manager.zig").TabManager;
const Pane = @import("pane.zig").Pane;
const layout_codec = @import("layout_codec.zig");
const split_layout_mod = @import("split_layout.zig");
const SplitLayout = split_layout_mod.SplitLayout;

const attyx = @import("attyx");
const Engine = attyx.Engine;

fn createTestPane(allocator: Allocator) !*Pane {
    const pane = try allocator.create(Pane);
    pane.* = .{
        .engine = try Engine.init(allocator, 24, 80, attyx.RingBuffer.default_max_scrollback),
        .pty = undefined,
        .allocator = allocator,
    };
    return pane;
}

fn createManagedTestPane(allocator: Allocator, daemon_pane_id: u32) !*Pane {
    const pane = try allocator.create(Pane);
    errdefer allocator.destroy(pane);
    pane.* = try Pane.initDaemonBacked(allocator, 24, 80, attyx.RingBuffer.default_max_scrollback);
    pane.daemon_pane_id = daemon_pane_id;
    pane.ipc_id = daemon_pane_id;
    return pane;
}

/// Build a LayoutInfo with a single tab containing N leaf panes with given daemon IDs.
fn makeLayout(pane_ids: []const u32) layout_codec.LayoutInfo {
    var info = layout_codec.LayoutInfo{};
    info.tab_count = 1;
    info.active_tab = 0;
    info.focused_pane_id = pane_ids[0];

    if (pane_ids.len == 1) {
        info.tabs[0].node_count = 1;
        info.tabs[0].root_idx = 0;
        info.tabs[0].focused_idx = 0;
        info.tabs[0].nodes[0] = .{ .tag = .leaf, .pane_id = pane_ids[0] };
    } else if (pane_ids.len == 2) {
        // branch(0) -> leaf(1), leaf(2)
        info.tabs[0].node_count = 3;
        info.tabs[0].root_idx = 0;
        info.tabs[0].focused_idx = 1;
        info.tabs[0].nodes[0] = .{
            .tag = .branch,
            .direction = .vertical,
            .ratio_x100 = 50,
            .child_left = 1,
            .child_right = 2,
        };
        info.tabs[0].nodes[1] = .{ .tag = .leaf, .pane_id = pane_ids[0] };
        info.tabs[0].nodes[2] = .{ .tag = .leaf, .pane_id = pane_ids[1] };
    } else if (pane_ids.len == 3) {
        // branch(0) -> leaf(1), branch(2) -> leaf(3), leaf(4)
        info.tabs[0].node_count = 5;
        info.tabs[0].root_idx = 0;
        info.tabs[0].focused_idx = 1;
        info.tabs[0].nodes[0] = .{
            .tag = .branch,
            .direction = .vertical,
            .ratio_x100 = 50,
            .child_left = 1,
            .child_right = 2,
        };
        info.tabs[0].nodes[1] = .{ .tag = .leaf, .pane_id = pane_ids[0] };
        info.tabs[0].nodes[2] = .{
            .tag = .branch,
            .direction = .horizontal,
            .ratio_x100 = 50,
            .child_left = 3,
            .child_right = 4,
        };
        info.tabs[0].nodes[3] = .{ .tag = .leaf, .pane_id = pane_ids[1] };
        info.tabs[0].nodes[4] = .{ .tag = .leaf, .pane_id = pane_ids[2] };
    }
    return info;
}

/// Collect ipc_ids from all panes in the TabManager (in tab/tree order).
fn collectIpcIds(mgr: *TabManager, out: []u32) u32 {
    var count: u32 = 0;
    for (&mgr.tabs) |*slot| {
        const lay = &(slot.* orelse continue);
        for (&lay.pool) |*node| {
            if (node.tag == .leaf) {
                if (node.pane) |pane| {
                    if (count < out.len) {
                        out[count] = pane.ipc_id;
                        count += 1;
                    }
                }
            }
        }
    }
    return count;
}

fn destroyMgr(mgr: *TabManager) void {
    for (&mgr.tabs) |*slot| {
        if (slot.*) |*lay| {
            lay.deinitAll(mgr.allocator);
            slot.* = null;
        }
    }
}

test "reconstructFromLayout: ipc_ids match daemon pane ids" {
    const allocator = std.testing.allocator;
    const daemon_ids = [_]u32{ 42, 99 };
    var layout = makeLayout(&daemon_ids);

    var mgr = TabManager{ .allocator = allocator };
    try mgr.reconstructFromLayout(&layout, 24, 80, 100);
    defer destroyMgr(&mgr);

    var ids: [8]u32 = undefined;
    const count = collectIpcIds(&mgr, &ids);
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expectEqual(@as(u32, 42), ids[0]);
    try std.testing.expectEqual(@as(u32, 99), ids[1]);
}

test "reconstructFromLayout: ids stable after switching sessions" {
    // Simulate: reconstruct session A, then session B, then session A again.
    // Pane IDs in A must be identical both times.
    const allocator = std.testing.allocator;

    const session_a_ids = [_]u32{ 10, 20, 30 };
    const session_b_ids = [_]u32{ 50, 60 };

    var layout_a = makeLayout(&session_a_ids);
    var layout_b = makeLayout(&session_b_ids);

    var mgr = TabManager{ .allocator = allocator };

    // Load session A
    try mgr.reconstructFromLayout(&layout_a, 24, 80, 100);
    var ids: [8]u32 = undefined;
    var count = collectIpcIds(&mgr, &ids);
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqual(@as(u32, 10), ids[0]);
    try std.testing.expectEqual(@as(u32, 20), ids[1]);
    try std.testing.expectEqual(@as(u32, 30), ids[2]);

    // Switch to session B
    try mgr.reconstructFromLayout(&layout_b, 24, 80, 100);
    count = collectIpcIds(&mgr, &ids);
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expectEqual(@as(u32, 50), ids[0]);
    try std.testing.expectEqual(@as(u32, 60), ids[1]);

    // Switch back to session A — IDs must be the same as the first time
    try mgr.reconstructFromLayout(&layout_a, 24, 80, 100);
    count = collectIpcIds(&mgr, &ids);
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqual(@as(u32, 10), ids[0]);
    try std.testing.expectEqual(@as(u32, 20), ids[1]);
    try std.testing.expectEqual(@as(u32, 30), ids[2]);

    destroyMgr(&mgr);
}

test "reconstructFromLayout: next_ipc_id stays above max daemon id" {
    // After reconstruction, locally created panes must not collide with daemon IDs.
    const allocator = std.testing.allocator;

    const daemon_ids = [_]u32{ 100, 200 };
    var layout = makeLayout(&daemon_ids);

    var mgr = TabManager{ .allocator = allocator };
    try mgr.reconstructFromLayout(&layout, 24, 80, 100);
    defer destroyMgr(&mgr);

    // next_ipc_id must be > 200 (the max daemon id)
    try std.testing.expect(mgr.next_ipc_id > 200);

    // Simulate creating a local pane — its ID must not collide
    var local_pane = try createTestPane(allocator);
    defer {
        local_pane.engine.deinit();
        allocator.destroy(local_pane);
    }
    mgr.assignIpcId(local_pane);
    try std.testing.expect(local_pane.ipc_id > 200);
    try std.testing.expect(local_pane.ipc_id != 100);
}

test "reconstructFromLayout: high daemon ids near u32 max" {
    const allocator = std.testing.allocator;

    // Use a daemon ID near the u32 max to test wrapping
    const daemon_ids = [_]u32{std.math.maxInt(u32)};
    var layout = makeLayout(&daemon_ids);

    var mgr = TabManager{ .allocator = allocator };
    try mgr.reconstructFromLayout(&layout, 24, 80, 100);
    defer destroyMgr(&mgr);

    var ids: [8]u32 = undefined;
    const count = collectIpcIds(&mgr, &ids);
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(std.math.maxInt(u32), ids[0]);

    // next_ipc_id should have wrapped past 0 to 1
    try std.testing.expectEqual(@as(u32, 1), mgr.next_ipc_id);
}

test "serialize/reconstruct preserves explicit tab titles" {
    const allocator = std.testing.allocator;

    const first = try createManagedTestPane(allocator, 1);
    var mgr = TabManager.init(allocator, first);
    defer destroyMgr(&mgr);

    const second = try createManagedTestPane(allocator, 2);
    mgr.tabs[1] = SplitLayout.init(second);
    mgr.count = 2;
    mgr.tabs[0].?.setTitle("editor");
    mgr.tabs[1].?.setTitle("logs");

    var buf: [4096]u8 = undefined;
    const len = try mgr.serializeLayout(&buf);
    const layout = try layout_codec.deserialize(buf[0..len]);

    try std.testing.expect(layout.tabs[0].isExplicitTitle());
    try std.testing.expect(layout.tabs[1].isExplicitTitle());
    var restored = TabManager{ .allocator = allocator };
    try restored.reconstructFromLayout(&layout, 24, 80, 100);
    defer destroyMgr(&restored);

    try std.testing.expectEqualStrings("editor", restored.tabs[0].?.getTitle().?);
    try std.testing.expectEqualStrings("logs", restored.tabs[1].?.getTitle().?);
}

test "serialize/reconstruct preserves fallback title hints for unnamed tabs" {
    const allocator = std.testing.allocator;

    const first = try createManagedTestPane(allocator, 1);
    var mgr = TabManager.init(allocator, first);
    defer destroyMgr(&mgr);

    mgr.tabs[0].?.focusedPane().engine.feed("\x1b]0;htop\x07");

    var buf: [4096]u8 = undefined;
    const len = try mgr.serializeLayout(&buf);
    const layout = try layout_codec.deserialize(buf[0..len]);

    try std.testing.expect(!layout.tabs[0].isExplicitTitle());
    try std.testing.expectEqualStrings("htop", layout.tabs[0].getTitle().?);

    var restored = TabManager{ .allocator = allocator };
    try restored.reconstructFromLayout(&layout, 24, 80, 100);
    defer destroyMgr(&restored);

    try std.testing.expect(restored.tabs[0].?.getTitle() == null);
    try std.testing.expectEqualStrings("htop", restored.tabs[0].?.getHintTitle().?);
    try std.testing.expect(restored.tabs[0].?.focusedPane().getDaemonProcName() == null);
}

test "moveTabTo keeps explicit tab titles attached to the tab" {
    const allocator = std.testing.allocator;

    const first = try createManagedTestPane(allocator, 1);

    var mgr = TabManager.init(allocator, first);
    defer destroyMgr(&mgr);

    const second = try createManagedTestPane(allocator, 2);
    mgr.tabs[1] = SplitLayout.init(second);
    mgr.count = 2;
    mgr.active = 0;
    mgr.tabs[0].?.setTitle("editor");
    mgr.tabs[1].?.setTitle("logs");

    mgr.moveTabTo(0, 1);

    try std.testing.expectEqual(@as(u8, 1), mgr.active);
    try std.testing.expectEqualStrings("logs", mgr.tabs[0].?.getTitle().?);
    try std.testing.expectEqualStrings("editor", mgr.tabs[1].?.getTitle().?);
}

test "explicit tab title survives focus changes within a split tab" {
    const allocator = std.testing.allocator;

    const first = try createManagedTestPane(allocator, 1);
    var mgr = TabManager.init(allocator, first);
    defer destroyMgr(&mgr);

    const second = try createManagedTestPane(allocator, 2);
    try mgr.tabs[0].?.splitPaneWith(.vertical, second);
    mgr.tabs[0].?.setTitle("editor");

    var leaves: [8]split_layout_mod.LeafEntry = undefined;
    const leaf_count = mgr.tabs[0].?.collectLeaves(&leaves);
    try std.testing.expectEqual(@as(u8, 2), leaf_count);

    const original_focus = mgr.tabs[0].?.focused;
    const next_focus = if (leaves[0].index == original_focus) leaves[1].index else leaves[0].index;
    mgr.tabs[0].?.focused = next_focus;

    try std.testing.expectEqualStrings("editor", mgr.tabs[0].?.getTitle().?);

    var buf: [4096]u8 = undefined;
    const len = try mgr.serializeLayout(&buf);
    const layout = try layout_codec.deserialize(buf[0..len]);

    try std.testing.expect(layout.tabs[0].isExplicitTitle());
    try std.testing.expectEqualStrings("editor", layout.tabs[0].getTitle().?);
}

test "syncFromLayout preserves explicit tab titles" {
    const allocator = std.testing.allocator;

    const first = try createManagedTestPane(allocator, 1);
    var mgr = TabManager.init(allocator, first);
    defer destroyMgr(&mgr);

    var layout = makeLayout(&[_]u32{1});
    @memcpy(layout.tabs[0].title[0..6], "editor");
    layout.tabs[0].title_len = 6;
    layout.tabs[0].title_flags = layout_codec.title_flag_explicit;

    try mgr.syncFromLayout(&layout, 24, 80, 100);

    try std.testing.expectEqualStrings("editor", mgr.tabs[0].?.getTitle().?);
}

test "syncFromLayout clears stale unnamed-tab hints when new layout has no title" {
    const allocator = std.testing.allocator;

    const first = try createManagedTestPane(allocator, 1);
    var mgr = TabManager.init(allocator, first);
    defer destroyMgr(&mgr);

    var hinted = makeLayout(&[_]u32{1});
    @memcpy(hinted.tabs[0].title[0..4], "htop");
    hinted.tabs[0].title_len = 4;

    try mgr.syncFromLayout(&hinted, 24, 80, 100);
    try std.testing.expectEqualStrings("htop", mgr.tabs[0].?.getHintTitle().?);

    var clear = makeLayout(&[_]u32{1});
    try mgr.syncFromLayout(&clear, 24, 80, 100);

    try std.testing.expect(mgr.tabs[0].?.getTitle() == null);
    try std.testing.expect(mgr.tabs[0].?.getHintTitle() == null);
}
