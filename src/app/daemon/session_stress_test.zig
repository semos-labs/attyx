//! Stress tests for daemon concurrency, resource limits, and edge cases.
//! Exercises multi-client scenarios, pane limits, rapid cycling, and
//! boundary conditions that could surface in real usage.
const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const protocol = @import("protocol.zig");
const harness = @import("test_harness.zig");
const setup = harness.setup;
const teardown = harness.teardown;
const TestClient = harness.TestClient;

// ── Terminal edge cases ──

test "zero rows/cols in create and resize" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;

    // Create with 0x0 terminal — shouldn't crash the PTY spawn
    const cp = try protocol.encodeCreate(&buf, "zero-size", 0, 0, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);
    try testing.expect(sid >= 1);

    // Attach and resize to 0x0
    const ap = try protocol.encodeAttach(&buf, sid, 0, 0);
    try client.send(.attach, ap);
    _ = try client.expect(.attached, 5000);

    // Session should still be alive and listable
    try client.send(.list, &.{});
    const list = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    _ = try protocol.decodeSessionList(list, &entries);
    try testing.expect(entries[0].alive);
}

// ── Rapid state transitions ──

test "rapid attach/detach cycling" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "attach-cycle", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    // Attach and detach 20 times in rapid succession
    for (0..20) |_| {
        const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
        try client.send(.attach, ap);
        _ = try client.expect(.attached, 5000);
        try client.send(.detach, &.{});
    }
    posix.nanosleep(0, 20_000_000);

    // Session must still be alive and healthy
    try client.send(.list, &.{});
    const list = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqual(@as(u16, 1), count);
    try testing.expect(entries[0].alive);
}

// ── Multi-client concurrency ──

test "two clients write to same pane simultaneously" {
    var env = try setup();
    defer teardown(&env);

    var buf: [4200]u8 = undefined;

    var c1 = try TestClient.connect(env.path());
    defer c1.deinit();
    const cp = try protocol.encodeCreate(&buf, "shared-pane", 24, 80, "/tmp", "");
    try c1.send(.create, cp);
    const created = try c1.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    // Both clients attach to same session
    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try c1.send(.attach, ap);
    const a1 = try c1.expect(.attached, 5000);
    const v1 = try protocol.decodeAttachedV2(a1);
    const pane_id = v1.pane_ids[0];

    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();
    try c2.send(.attach, ap);
    _ = try c2.expect(.attached, 5000);

    // Both send input simultaneously
    for (0..10) |_| {
        const ip1 = try protocol.encodePaneInput(&buf, pane_id, "a");
        try c1.send(.pane_input, ip1);
        const ip2 = try protocol.encodePaneInput(&buf, pane_id, "b");
        try c2.send(.pane_input, ip2);
    }
    posix.nanosleep(0, 50_000_000);

    // Both can still list — session alive, no corruption
    try c1.send(.list, &.{});
    const list = try c1.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    _ = try protocol.decodeSessionList(list, &entries);
    try testing.expect(entries[0].alive);
}

test "kill session while other client is attached" {
    var env = try setup();
    defer teardown(&env);

    var buf: [4200]u8 = undefined;

    var c1 = try TestClient.connect(env.path());
    defer c1.deinit();
    const cp = try protocol.encodeCreate(&buf, "kill-while-attached", 24, 80, "/tmp", "");
    try c1.send(.create, cp);
    const created = try c1.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try c1.send(.attach, ap);
    _ = try c1.expect(.attached, 5000);

    // Second client kills the session out from under client 1
    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();
    const kp = try protocol.encodeKill(&buf, sid);
    try c2.send(.kill, kp);
    posix.nanosleep(0, 100_000_000);

    // Client 1 tries to send input to the now-dead session
    // This should not crash the daemon
    const ip = try protocol.encodePaneInput(&buf, 1, "ghost input\n");
    c1.send(.pane_input, ip) catch {};
    posix.nanosleep(0, 20_000_000);

    // Both clients can still list
    try c2.send(.list, &.{});
    const list = try c2.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqual(@as(u16, 1), count);
    try testing.expect(!entries[0].alive);
}

// ── Resource limits ──

test "exhaust max panes per session" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "pane-flood", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap);
    _ = try client.expect(.attached, 5000);

    // Session starts with 1 pane. Create 31 more to hit the 32 limit.
    var pane_count: u32 = 1;
    for (0..31) |_| {
        const pp = try protocol.encodeCreatePane(&buf, 24, 80, "/tmp");
        try client.send(.create_pane, pp);
        // Could get pane_created or err
        if (client.expect(.pane_created, 5000)) |_| {
            pane_count += 1;
        } else |_| break;
    }
    try testing.expectEqual(@as(u32, 32), pane_count);

    // One more should fail
    const pp = try protocol.encodeCreatePane(&buf, 24, 80, "/tmp");
    try client.send(.create_pane, pp);
    const err_payload = try client.expect(.err, 5000);
    const err = try protocol.decodeError(err_payload);
    try testing.expectEqual(@as(u8, 3), err.code); // create pane failed

    // Session still alive
    try client.send(.list, &.{});
    const list = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    _ = try protocol.decodeSessionList(list, &entries);
    try testing.expect(entries[0].alive);
}

// ── Boundary values ──

test "rename to empty and max-length names" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [256]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "rename-edge", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    // Rename to empty string
    const rp1 = try protocol.encodeRename(&buf, sid, "");
    try client.send(.rename, rp1);
    posix.nanosleep(0, 20_000_000);

    try client.send(.list, &.{});
    const list1 = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    _ = try protocol.decodeSessionList(list1, &entries);
    try testing.expectEqualStrings("", entries[0].name);

    // Rename to 64-char string (max name_len)
    const long_name = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ__";
    try testing.expectEqual(@as(usize, 64), long_name.len);
    const rp2 = try protocol.encodeRename(&buf, sid, long_name);
    try client.send(.rename, rp2);
    posix.nanosleep(0, 20_000_000);

    try client.send(.list, &.{});
    const list2 = try client.expect(.session_list, 5000);
    _ = try protocol.decodeSessionList(list2, &entries);
    try testing.expectEqualStrings(long_name, entries[0].name);
}
