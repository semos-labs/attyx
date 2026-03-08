//! Integration tests for session restoration, connect/disconnect behavior,
//! and layout persistence across daemon ↔ client interactions.
const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const protocol = @import("protocol.zig");
const layout_codec = @import("../layout_codec.zig");
const harness = @import("test_harness.zig");
const setup = harness.setup;
const teardown = harness.teardown;
const TestClient = harness.TestClient;

test "client disconnect does not destroy session" {
    var env = try setup();
    defer teardown(&env);

    var c1 = try TestClient.connect(env.path());
    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "survive-disconnect", 24, 80, "/tmp", "");
    try c1.send(.create, cp);
    _ = try c1.expect(.created, 5000);
    const ap = try protocol.encodeAttach(&buf, 1, 24, 80);
    try c1.send(.attach, ap);
    _ = try c1.expect(.attached, 5000);

    // Abrupt disconnect (no detach)
    c1.deinit();
    posix.nanosleep(0, 50_000_000);

    // New client sees session alive
    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();
    try c2.send(.list, &.{});
    const list_payload = try c2.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list_payload, &entries);
    try testing.expectEqual(@as(u16, 1), count);
    try testing.expect(entries[0].alive);
    try testing.expectEqualStrings("survive-disconnect", entries[0].name);
}

test "new client inherits layout after previous client disconnects" {
    var env = try setup();
    defer teardown(&env);

    var buf: [4200]u8 = undefined;

    // Client 1: create, attach, save layout, disconnect
    var c1 = try TestClient.connect(env.path());
    const cp = try protocol.encodeCreate(&buf, "handoff-test", 24, 80, "/tmp", "");
    try c1.send(.create, cp);
    const created = try c1.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try c1.send(.attach, ap);
    const attached = try c1.expect(.attached, 5000);
    const v2 = try protocol.decodeAttachedV2(attached);
    const pane_id = v2.pane_ids[0];

    var layout = layout_codec.LayoutInfo{};
    layout.tab_count = 1;
    layout.active_tab = 0;
    layout.focused_pane_id = pane_id;
    layout.tabs[0].node_count = 1;
    layout.tabs[0].root_idx = 0;
    layout.tabs[0].focused_idx = 0;
    layout.tabs[0].nodes[0] = .{ .tag = .leaf, .pane_id = pane_id };

    var layout_buf: [4096]u8 = undefined;
    const layout_len = try layout_codec.serialize(&layout, &layout_buf);
    try c1.send(.save_layout, layout_buf[0..layout_len]);
    posix.nanosleep(0, 30_000_000);

    c1.deinit(); // abrupt disconnect
    posix.nanosleep(0, 50_000_000);

    // Client 2: attach — gets layout from client 1
    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();
    const ap2 = try protocol.encodeAttach(&buf, sid, 24, 80);
    try c2.send(.attach, ap2);
    const reattach = try c2.expect(.attached, 5000);
    const v2b = try protocol.decodeAttachedV2(reattach);

    try testing.expectEqual(sid, v2b.session_id);
    try testing.expect(v2b.layout.len > 0);
    const restored = try layout_codec.deserialize(v2b.layout);
    try testing.expectEqual(@as(u8, 1), restored.tab_count);
    try testing.expectEqual(pane_id, restored.focused_pane_id);
}

test "layout blob preserved across detach/reattach (tabs + active tab)" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "layout-test", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap);
    const attached = try client.expect(.attached, 5000);
    const v2 = try protocol.decodeAttachedV2(attached);
    const pane_id = v2.pane_ids[0];

    // Build layout: 2 tabs, active_tab=1, focused on pane_id
    var layout = layout_codec.LayoutInfo{};
    layout.tab_count = 2;
    layout.active_tab = 1;
    layout.focused_pane_id = pane_id;
    layout.tabs[0].node_count = 1;
    layout.tabs[0].root_idx = 0;
    layout.tabs[0].focused_idx = 0;
    layout.tabs[0].nodes[0] = .{ .tag = .leaf, .pane_id = pane_id };
    @memcpy(layout.tabs[0].title[0..4], "code");
    layout.tabs[0].title_len = 4;
    layout.tabs[1].node_count = 1;
    layout.tabs[1].root_idx = 0;
    layout.tabs[1].focused_idx = 0;
    layout.tabs[1].nodes[0] = .{ .tag = .leaf, .pane_id = pane_id };
    @memcpy(layout.tabs[1].title[0..4], "logs");
    layout.tabs[1].title_len = 4;

    var layout_buf: [4096]u8 = undefined;
    const layout_len = try layout_codec.serialize(&layout, &layout_buf);
    try client.send(.save_layout, layout_buf[0..layout_len]);
    posix.nanosleep(0, 30_000_000);

    try client.send(.detach, &.{});
    posix.nanosleep(0, 20_000_000);

    const ap2 = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap2);
    const reattach = try client.expect(.attached, 5000);
    const v2b = try protocol.decodeAttachedV2(reattach);

    try testing.expect(v2b.layout.len > 0);
    const restored = try layout_codec.deserialize(v2b.layout);
    try testing.expectEqual(@as(u8, 2), restored.tab_count);
    try testing.expectEqual(@as(u8, 1), restored.active_tab);
    try testing.expectEqual(pane_id, restored.focused_pane_id);
    try testing.expectEqualStrings("code", restored.tabs[0].getTitle().?);
    try testing.expectEqualStrings("logs", restored.tabs[1].getTitle().?);
}

test "split layout with focus preserved across detach/reattach" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "split-test", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap);
    const attached = try client.expect(.attached, 5000);
    const v2 = try protocol.decodeAttachedV2(attached);
    const pane1 = v2.pane_ids[0];

    const pp = try protocol.encodeCreatePane(&buf, 24, 80, "/tmp");
    try client.send(.create_pane, pp);
    const pane_resp = try client.expect(.pane_created, 5000);
    const pane2 = try protocol.decodePaneCreated(pane_resp);

    // Save split layout: vertical, focus on pane2 (right)
    var layout = layout_codec.LayoutInfo{};
    layout.tab_count = 1;
    layout.active_tab = 0;
    layout.focused_pane_id = pane2;
    layout.tabs[0].node_count = 3;
    layout.tabs[0].root_idx = 0;
    layout.tabs[0].focused_idx = 2;
    layout.tabs[0].nodes[0] = .{
        .tag = .branch, .direction = .vertical,
        .ratio_x100 = 50, .child_left = 1, .child_right = 2,
    };
    layout.tabs[0].nodes[1] = .{ .tag = .leaf, .pane_id = pane1 };
    layout.tabs[0].nodes[2] = .{ .tag = .leaf, .pane_id = pane2 };

    var layout_buf: [4096]u8 = undefined;
    const layout_len = try layout_codec.serialize(&layout, &layout_buf);
    try client.send(.save_layout, layout_buf[0..layout_len]);
    posix.nanosleep(0, 30_000_000);

    try client.send(.detach, &.{});
    posix.nanosleep(0, 20_000_000);

    const ap2 = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap2);
    const reattach = try client.expect(.attached, 5000);
    const v2b = try protocol.decodeAttachedV2(reattach);

    const restored = try layout_codec.deserialize(v2b.layout);
    try testing.expectEqual(@as(u8, 1), restored.tab_count);
    try testing.expectEqual(pane2, restored.focused_pane_id);
    try testing.expectEqual(@as(u8, 3), restored.tabs[0].node_count);
    try testing.expectEqual(@as(u8, 2), restored.tabs[0].focused_idx);
    try testing.expectEqual(layout_codec.NodeTag.branch, restored.tabs[0].nodes[0].tag);
    try testing.expectEqual(pane1, restored.tabs[0].nodes[1].pane_id);
    try testing.expectEqual(pane2, restored.tabs[0].nodes[2].pane_id);
}

test "kill and reattach revives session with remapped pane IDs" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "revive-test", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap);
    const attached = try client.expect(.attached, 5000);
    const v2 = try protocol.decodeAttachedV2(attached);
    const old_pane = v2.pane_ids[0];

    // Save layout with old pane ID
    var layout = layout_codec.LayoutInfo{};
    layout.tab_count = 1;
    layout.active_tab = 0;
    layout.focused_pane_id = old_pane;
    layout.tabs[0].node_count = 1;
    layout.tabs[0].root_idx = 0;
    layout.tabs[0].focused_idx = 0;
    layout.tabs[0].nodes[0] = .{ .tag = .leaf, .pane_id = old_pane };

    var layout_buf: [4096]u8 = undefined;
    const layout_len = try layout_codec.serialize(&layout, &layout_buf);
    try client.send(.save_layout, layout_buf[0..layout_len]);
    posix.nanosleep(0, 30_000_000);

    try client.send(.detach, &.{});
    posix.nanosleep(0, 20_000_000);

    // Kill (soft-kill) then reattach — revives with fresh pane, remapped layout
    const kp = try protocol.encodeKill(&buf, sid);
    try client.send(.kill, kp);
    posix.nanosleep(0, 50_000_000);

    const ap2 = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap2);
    const reattach = try client.expect(.attached, 5000);
    const v2b = try protocol.decodeAttachedV2(reattach);

    try testing.expectEqual(sid, v2b.session_id);
    try testing.expect(v2b.pane_count >= 1);
    try testing.expect(v2b.pane_ids[0] != old_pane);

    if (v2b.layout.len > 0) {
        const restored = try layout_codec.deserialize(v2b.layout);
        try testing.expectEqual(@as(u8, 1), restored.tab_count);
        // Leaf pane ID remapped to new pane
        try testing.expectEqual(v2b.pane_ids[0], restored.tabs[0].nodes[0].pane_id);
    }
}

test "multiple sessions maintained independently" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;

    const cp1 = try protocol.encodeCreate(&buf, "work", 24, 80, "/tmp", "");
    try client.send(.create, cp1);
    _ = try client.expect(.created, 5000);

    const cp2 = try protocol.encodeCreate(&buf, "build", 24, 80, "/tmp", "");
    try client.send(.create, cp2);
    const c2 = try client.expect(.created, 5000);
    const sid2 = try protocol.decodeCreated(c2);

    const cp3 = try protocol.encodeCreate(&buf, "logs", 24, 80, "/tmp", "");
    try client.send(.create, cp3);
    _ = try client.expect(.created, 5000);

    // Kill session 2 — others unaffected
    const kp = try protocol.encodeKill(&buf, sid2);
    try client.send(.kill, kp);
    posix.nanosleep(0, 50_000_000);

    try client.send(.list, &.{});
    const list_payload = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list_payload, &entries);
    try testing.expectEqual(@as(u16, 3), count);

    var found_dead = false;
    var alive_count: u16 = 0;
    for (entries[0..count]) |e| {
        if (e.id == sid2) {
            try testing.expect(!e.alive);
            found_dead = true;
        } else {
            try testing.expect(e.alive);
            alive_count += 1;
        }
    }
    try testing.expect(found_dead);
    try testing.expectEqual(@as(u16, 2), alive_count);
}

test "layout sync broadcasts to other attached clients" {
    var env = try setup();
    defer teardown(&env);

    var buf: [4200]u8 = undefined;

    var c1 = try TestClient.connect(env.path());
    defer c1.deinit();
    const cp = try protocol.encodeCreate(&buf, "sync-test", 24, 80, "/tmp", "");
    try c1.send(.create, cp);
    const created = try c1.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try c1.send(.attach, ap);
    _ = try c1.expect(.attached, 5000);

    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();
    const ap2 = try protocol.encodeAttach(&buf, sid, 24, 80);
    try c2.send(.attach, ap2);
    _ = try c2.expect(.attached, 5000);

    // Client 1 saves layout → client 2 gets layout_sync
    var layout = layout_codec.LayoutInfo{};
    layout.tab_count = 1;
    layout.active_tab = 0;
    layout.focused_pane_id = 1;
    layout.tabs[0].node_count = 1;
    layout.tabs[0].root_idx = 0;
    layout.tabs[0].nodes[0] = .{ .tag = .leaf, .pane_id = 1 };

    var layout_buf: [4096]u8 = undefined;
    const layout_len = try layout_codec.serialize(&layout, &layout_buf);
    try c1.send(.save_layout, layout_buf[0..layout_len]);

    const sync_payload = try c2.expect(.layout_sync, 5000);
    try testing.expect(sync_payload.len > 0);
    const synced = try protocol.decodeAttachedV2(sync_payload);
    try testing.expectEqual(sid, synced.session_id);
}
