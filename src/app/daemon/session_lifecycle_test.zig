//! Integration tests for daemon lifecycle: launch delay, daemon restart/migration,
//! and client resilience across daemon restarts.
const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const protocol = @import("protocol.zig");
const layout_codec = @import("../layout_codec.zig");
const harness = @import("test_harness.zig");
const setup = harness.setup;
const setupDelayed = harness.setupDelayed;
const teardown = harness.teardown;
const TestClient = harness.TestClient;

// ── Launch delay simulation ──

test "client connects to socket before daemon starts processing" {
    // Socket is bound+listening but daemon thread isn't running yet.
    // The kernel backlog accepts the TCP-level connect, but no one reads messages.
    // Once we start the daemon, it should pick up the queued connection and process.
    var env = try setupDelayed();
    defer teardown(&env);

    // Client connects — this succeeds because the kernel accepts on the backlog
    var client = try TestClient.connect(env.path());
    defer client.deinit();

    // Send a create before daemon is running — sits in socket buffer
    var buf: [256]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "early-bird", 24, 80, "/tmp", "");
    try client.send(.create, cp);

    // Now start the daemon — it should process the queued message
    try env.startDaemon();

    const resp = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(resp);
    try testing.expect(sid >= 1);

    // Verify session actually exists
    try client.send(.list, &.{});
    const list = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqual(@as(u16, 1), count);
    try testing.expectEqualStrings("early-bird", entries[0].name);
}

test "multiple clients queue messages during launch delay" {
    var env = try setupDelayed();
    defer teardown(&env);

    // Two clients connect and send commands before daemon starts
    var c1 = try TestClient.connect(env.path());
    defer c1.deinit();
    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();

    var buf: [256]u8 = undefined;
    const cp1 = try protocol.encodeCreate(&buf, "queued-1", 24, 80, "/tmp", "");
    try c1.send(.create, cp1);

    const cp2 = try protocol.encodeCreate(&buf, "queued-2", 24, 80, "/tmp", "");
    try c2.send(.create, cp2);

    // Start daemon — both queued messages should be processed
    try env.startDaemon();

    _ = try c1.expect(.created, 5000);
    _ = try c2.expect(.created, 5000);

    // Both sessions visible from either client
    try c1.send(.list, &.{});
    const list = try c1.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqual(@as(u16, 2), count);
}

// ── Daemon restart / migration simulation ──

test "daemon restart: old sessions gone, new sessions work" {
    var env = try setup();
    defer teardown(&env);

    // Create a session on the "old" daemon
    var c1 = try TestClient.connect(env.path());
    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "before-restart", 24, 80, "/tmp", "");
    try c1.send(.create, cp);
    const created = try c1.expect(.created, 5000);
    const old_sid = try protocol.decodeCreated(created);
    try testing.expect(old_sid >= 1);
    c1.deinit();

    // Restart daemon — simulates upgrade: all state is wiped
    try env.restartDaemon();

    // New client connects to restarted daemon
    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();

    // Old session is gone
    try c2.send(.list, &.{});
    const list = try c2.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqual(@as(u16, 0), count);

    // But we can create new sessions
    const cp2 = try protocol.encodeCreate(&buf, "after-restart", 24, 80, "/tmp", "");
    try c2.send(.create, cp2);
    const created2 = try c2.expect(.created, 5000);
    const new_sid = try protocol.decodeCreated(created2);
    try testing.expect(new_sid >= 1);
}

test "client reconnects after daemon restart and creates new session" {
    var env = try setup();
    defer teardown(&env);

    var buf: [4200]u8 = undefined;

    // Client 1 creates session, attaches, saves layout, disconnects
    var c1 = try TestClient.connect(env.path());
    const cp = try protocol.encodeCreate(&buf, "persist-me", 24, 80, "/tmp", "");
    try c1.send(.create, cp);
    const created = try c1.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try c1.send(.attach, ap);
    const attached = try c1.expect(.attached, 5000);
    const v2 = try protocol.decodeAttachedV2(attached);
    const pane_id = v2.pane_ids[0];

    // Save a layout so we can check if it survives
    var layout = layout_codec.LayoutInfo{};
    layout.tab_count = 2;
    layout.active_tab = 1;
    layout.focused_pane_id = pane_id;
    layout.tabs[0].node_count = 1;
    layout.tabs[0].root_idx = 0;
    layout.tabs[0].focused_idx = 0;
    layout.tabs[0].nodes[0] = .{ .tag = .leaf, .pane_id = pane_id };
    @memcpy(layout.tabs[0].title[0..4], "work");
    layout.tabs[0].title_len = 4;
    layout.tabs[1].node_count = 1;
    layout.tabs[1].root_idx = 0;
    layout.tabs[1].focused_idx = 0;
    layout.tabs[1].nodes[0] = .{ .tag = .leaf, .pane_id = pane_id };
    @memcpy(layout.tabs[1].title[0..4], "logs");
    layout.tabs[1].title_len = 4;

    var layout_buf: [4096]u8 = undefined;
    const layout_len = try layout_codec.serialize(&layout, &layout_buf);
    try c1.send(.save_layout, layout_buf[0..layout_len]);
    posix.nanosleep(0, 30_000_000);

    c1.deinit();
    posix.nanosleep(0, 50_000_000);

    // Daemon restarts (state lost — real upgrade would serialize/restore,
    // but this tests the "clean restart" path where client must recreate)
    try env.restartDaemon();

    // Client 2 connects to the new daemon
    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();

    // Old session no longer exists — attach should fail
    const ap2 = try protocol.encodeAttach(&buf, sid, 24, 80);
    try c2.send(.attach, ap2);
    const err_payload = try c2.expect(.err, 5000);
    const err = try protocol.decodeError(err_payload);
    try testing.expectEqual(@as(u8, 4), err.code); // session not found

    // Client creates a fresh session on the new daemon
    const cp2 = try protocol.encodeCreate(&buf, "reborn", 24, 80, "/tmp", "");
    try c2.send(.create, cp2);
    const c2_created = try c2.expect(.created, 5000);
    const new_sid = try protocol.decodeCreated(c2_created);
    try testing.expect(new_sid >= 1);

    // Full attach/layout cycle works on new daemon
    const ap3 = try protocol.encodeAttach(&buf, new_sid, 24, 80);
    try c2.send(.attach, ap3);
    const a3 = try c2.expect(.attached, 5000);
    const v3 = try protocol.decodeAttachedV2(a3);
    try testing.expectEqual(new_sid, v3.session_id);
    try testing.expect(v3.pane_count >= 1);
}

test "hello handshake works across daemon restart" {
    var env = try setup();
    defer teardown(&env);

    var buf: [256]u8 = undefined;

    // Get version from original daemon
    var c1 = try TestClient.connect(env.path());
    const hp = try protocol.encodeHello(&buf, "0.0.1");
    try c1.send(.hello, hp);
    const ack1 = try c1.expect(.hello_ack, 5000);
    const v1 = try protocol.decodeHello(ack1);
    try testing.expect(v1.len > 0);
    c1.deinit();

    // Restart daemon
    try env.restartDaemon();

    // New connection, hello still works
    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();
    const hp2 = try protocol.encodeHello(&buf, "0.0.1");
    try c2.send(.hello, hp2);
    const ack2 = try c2.expect(.hello_ack, 5000);
    const v2 = try protocol.decodeHello(ack2);
    // Same compiled binary, so version should match
    try testing.expectEqualStrings(v1, v2);
}

// ── Edge cases ──

test "rapid create-kill-create cycle" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;

    // Rapid cycle: create, kill, create again
    const cp1 = try protocol.encodeCreate(&buf, "ephemeral", 24, 80, "/tmp", "");
    try client.send(.create, cp1);
    const c1 = try client.expect(.created, 5000);
    const sid1 = try protocol.decodeCreated(c1);

    const kp = try protocol.encodeKill(&buf, sid1);
    try client.send(.kill, kp);
    posix.nanosleep(0, 50_000_000);

    const cp2 = try protocol.encodeCreate(&buf, "phoenix", 24, 80, "/tmp", "");
    try client.send(.create, cp2);
    const c2 = try client.expect(.created, 5000);
    const sid2 = try protocol.decodeCreated(c2);

    // New session got a different ID
    try testing.expect(sid2 != sid1);

    // List shows both: one dead, one alive
    try client.send(.list, &.{});
    const list = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqual(@as(u16, 2), count);

    var dead_count: u16 = 0;
    var alive_count: u16 = 0;
    for (entries[0..count]) |e| {
        if (e.alive) alive_count += 1 else dead_count += 1;
    }
    try testing.expectEqual(@as(u16, 1), dead_count);
    try testing.expectEqual(@as(u16, 1), alive_count);
}

test "closing last pane marks session dead" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "close-last", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap);
    const attached = try client.expect(.attached, 5000);
    const v2 = try protocol.decodeAttachedV2(attached);
    const pane_id = v2.pane_ids[0];
    try testing.expectEqual(@as(u8, 1), v2.pane_count);

    // Close the only pane — session should become dead
    const clp = try protocol.encodeClosePane(&buf, pane_id);
    try client.send(.close_pane, clp);
    posix.nanosleep(0, 50_000_000);

    try client.send(.detach, &.{});
    posix.nanosleep(0, 20_000_000);

    try client.send(.list, &.{});
    const list = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqual(@as(u16, 1), count);
    try testing.expect(!entries[0].alive);
}

test "create after kill reuses freed session slot" {
    // This test exercises the eviction path in handleCreate.
    // Before the fix, session_count wasn't decremented on eviction,
    // causing the counter to drift up and eventually block new sessions.
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    var last_sid: u32 = 0;

    // Create and kill several sessions in a loop
    for (0..5) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "cycle-{d}", .{i}) catch "cycle";
        const cp = try protocol.encodeCreate(&buf, name, 24, 80, "/tmp", "");
        try client.send(.create, cp);
        const created = try client.expect(.created, 5000);
        last_sid = try protocol.decodeCreated(created);

        const kp = try protocol.encodeKill(&buf, last_sid);
        try client.send(.kill, kp);
        posix.nanosleep(0, 50_000_000);
    }

    // Now create one more — if session_count is corrupted, this would fail
    const cp = try protocol.encodeCreate(&buf, "final", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const final_sid = try protocol.decodeCreated(created);
    try testing.expect(final_sid > last_sid);

    // Verify the final session is alive and listed
    try client.send(.list, &.{});
    const list = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list, &entries);

    // Should have 5 dead + 1 alive = 6 total
    var alive_count: u16 = 0;
    for (entries[0..count]) |e| {
        if (e.alive) alive_count += 1;
    }
    try testing.expectEqual(@as(u16, 1), alive_count);
}

test "double-kill first soft-kills then fully destroys" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "double-kill", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    // First kill: soft-kill (keeps session as dead entry)
    const kp = try protocol.encodeKill(&buf, sid);
    try client.send(.kill, kp);
    posix.nanosleep(0, 50_000_000);

    try client.send(.list, &.{});
    const list1 = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count1 = try protocol.decodeSessionList(list1, &entries);
    try testing.expectEqual(@as(u16, 1), count1);
    try testing.expect(!entries[0].alive);

    // Second kill: fully destroys (removes from slot)
    try client.send(.kill, kp);
    posix.nanosleep(0, 50_000_000);

    try client.send(.list, &.{});
    const list2 = try client.expect(.session_list, 5000);
    var entries2: [32]protocol.DecodedListEntry = undefined;
    const count2 = try protocol.decodeSessionList(list2, &entries2);
    try testing.expectEqual(@as(u16, 0), count2);
}

test "attach to killed session revives it with fresh pane" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "lazarus", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    // Attach to get initial pane ID
    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap);
    const attached = try client.expect(.attached, 5000);
    const v2 = try protocol.decodeAttachedV2(attached);
    const original_pane = v2.pane_ids[0];

    try client.send(.detach, &.{});
    posix.nanosleep(0, 20_000_000);

    // Kill the session
    const kp = try protocol.encodeKill(&buf, sid);
    try client.send(.kill, kp);
    posix.nanosleep(0, 50_000_000);

    // Verify it's dead
    try client.send(.list, &.{});
    const list = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    _ = try protocol.decodeSessionList(list, &entries);
    try testing.expect(!entries[0].alive);

    // Reattach — should revive with a new pane
    const ap2 = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap2);
    const reattach = try client.expect(.attached, 5000);
    const v2b = try protocol.decodeAttachedV2(reattach);

    try testing.expectEqual(sid, v2b.session_id);
    try testing.expect(v2b.pane_count >= 1);
    // Pane ID must be different — old pane was killed
    try testing.expect(v2b.pane_ids[0] != original_pane);

    // Session is alive again
    try client.send(.list, &.{});
    const list2 = try client.expect(.session_list, 5000);
    var entries2: [32]protocol.DecodedListEntry = undefined;
    _ = try protocol.decodeSessionList(list2, &entries2);
    try testing.expect(entries2[0].alive);
}
