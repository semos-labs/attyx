//! Integration tests for daemon hot-upgrade migration.
//! Exercises the serialize → wipe → deserialize path that happens
//! during `performUpgrade()`, ensuring sessions, panes, layouts,
//! ring buffers, and ID counters survive the transition.
const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const protocol = @import("protocol.zig");
const upgrade = @import("upgrade.zig");
const DaemonSession = @import("session.zig").DaemonSession;
const harness = @import("test_harness.zig");
const setup = harness.setup;
const teardown = harness.teardown;
const TestClient = harness.TestClient;

// ── Basic migration ──

test "session survives migration" {
    var env = try setup();
    defer teardown(&env);

    var buf: [4200]u8 = undefined;
    const sid = blk: {
        var client = try TestClient.connect(env.path());
        defer client.deinit();
        const cp = try protocol.encodeCreate(&buf, "migrate-me", 24, 80, "/tmp", "");
        try client.send(.create, cp);
        const created = try client.expect(.created, 5000);
        break :blk try protocol.decodeCreated(created);
    };

    try env.migrateDaemon();

    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();
    try c2.send(.list, &.{});
    const list = try c2.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqual(@as(u16, 1), count);
    try testing.expectEqual(sid, entries[0].id);
    try testing.expectEqualStrings("migrate-me", entries[0].name);
    try testing.expect(entries[0].alive);
}

test "session name survives rename then migration" {
    var env = try setup();
    defer teardown(&env);

    var buf: [4200]u8 = undefined;
    {
        var client = try TestClient.connect(env.path());
        defer client.deinit();
        const cp = try protocol.encodeCreate(&buf, "named-session", 30, 100, "/tmp", "");
        try client.send(.create, cp);
        const created = try client.expect(.created, 5000);
        const sid = try protocol.decodeCreated(created);
        const rp = try protocol.encodeRename(&buf, sid, "renamed-for-migration");
        try client.send(.rename, rp);
        posix.nanosleep(0, 20_000_000);
    }

    try env.migrateDaemon();

    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();
    try c2.send(.list, &.{});
    const list = try c2.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    _ = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqualStrings("renamed-for-migration", entries[0].name);
}

// ── Multiple sessions ──

test "multiple sessions survive migration" {
    var env = try setup();
    defer teardown(&env);

    var buf: [4200]u8 = undefined;
    var sids: [3]u32 = undefined;
    const names = [_][]const u8{ "alpha", "beta", "gamma" };
    {
        var client = try TestClient.connect(env.path());
        defer client.deinit();
        for (names, 0..) |name, i| {
            const cp = try protocol.encodeCreate(&buf, name, 24, 80, "/tmp", "");
            try client.send(.create, cp);
            const created = try client.expect(.created, 5000);
            sids[i] = try protocol.decodeCreated(created);
        }
    }

    try env.migrateDaemon();

    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();
    try c2.send(.list, &.{});
    const list = try c2.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqual(@as(u16, 3), count);

    for (sids, names) |expected_id, expected_name| {
        var found = false;
        for (entries[0..count]) |e| {
            if (e.id == expected_id) {
                try testing.expectEqualStrings(expected_name, e.name);
                try testing.expect(e.alive);
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

// ── Dead sessions ──

test "dead session preserved through migration" {
    var env = try setup();
    defer teardown(&env);

    var buf: [4200]u8 = undefined;
    const sid = blk: {
        var client = try TestClient.connect(env.path());
        defer client.deinit();
        const cp = try protocol.encodeCreate(&buf, "will-die", 24, 80, "/tmp", "");
        try client.send(.create, cp);
        const created = try client.expect(.created, 5000);
        const id = try protocol.decodeCreated(created);

        const kp = try protocol.encodeKill(&buf, id);
        try client.send(.kill, kp);
        posix.nanosleep(0, 50_000_000);

        // Verify dead before migration
        try client.send(.list, &.{});
        const list1 = try client.expect(.session_list, 5000);
        var entries1: [32]protocol.DecodedListEntry = undefined;
        _ = try protocol.decodeSessionList(list1, &entries1);
        try testing.expect(!entries1[0].alive);
        break :blk id;
    };

    try env.migrateDaemon();

    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();
    try c2.send(.list, &.{});
    const list2 = try c2.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list2, &entries);
    try testing.expectEqual(@as(u16, 1), count);
    try testing.expectEqual(sid, entries[0].id);
    try testing.expectEqualStrings("will-die", entries[0].name);
    try testing.expect(!entries[0].alive);
}

test "mix of alive and dead sessions survives migration" {
    var env = try setup();
    defer teardown(&env);

    var buf: [4200]u8 = undefined;
    var alive_id: u32 = undefined;
    var dead_id: u32 = undefined;
    {
        var client = try TestClient.connect(env.path());
        defer client.deinit();

        const cp1 = try protocol.encodeCreate(&buf, "alive-one", 24, 80, "/tmp", "");
        try client.send(.create, cp1);
        const c1 = try client.expect(.created, 5000);
        alive_id = try protocol.decodeCreated(c1);

        const cp2 = try protocol.encodeCreate(&buf, "dead-one", 24, 80, "/tmp", "");
        try client.send(.create, cp2);
        const c2_data = try client.expect(.created, 5000);
        dead_id = try protocol.decodeCreated(c2_data);

        const kp = try protocol.encodeKill(&buf, dead_id);
        try client.send(.kill, kp);
        posix.nanosleep(0, 50_000_000);
    }

    try env.migrateDaemon();

    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();
    try c2.send(.list, &.{});
    const list = try c2.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqual(@as(u16, 2), count);

    for (entries[0..count]) |e| {
        if (e.id == alive_id) {
            try testing.expectEqualStrings("alive-one", e.name);
            try testing.expect(e.alive);
        } else if (e.id == dead_id) {
            try testing.expectEqualStrings("dead-one", e.name);
            try testing.expect(!e.alive);
        } else {
            return error.UnexpectedSessionId;
        }
    }
}

// ── ID counter preservation ──

test "next_session_id and next_pane_id survive migration" {
    var env = try setup();
    defer teardown(&env);

    var buf: [4200]u8 = undefined;
    {
        var client = try TestClient.connect(env.path());
        defer client.deinit();
        for (0..3) |_| {
            const cp = try protocol.encodeCreate(&buf, "id-test", 24, 80, "/tmp", "");
            try client.send(.create, cp);
            _ = try client.expect(.created, 5000);
        }
    }

    try env.migrateDaemon();

    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();
    const cp = try protocol.encodeCreate(&buf, "after-migrate", 24, 80, "/tmp", "");
    try c2.send(.create, cp);
    const created = try c2.expect(.created, 5000);
    const new_id = try protocol.decodeCreated(created);

    // IDs 1, 2, 3 were used. next should be 4.
    try testing.expectEqual(@as(u32, 4), new_id);
}

// ── Ring buffer / replay ──

test "pane replay data survives migration" {
    var env = try setup();
    defer teardown(&env);

    var buf: [4200]u8 = undefined;
    const sid = blk: {
        var client = try TestClient.connect(env.path());
        defer client.deinit();
        const cp = try protocol.encodeCreate(&buf, "replay-test", 24, 80, "/tmp", "");
        try client.send(.create, cp);
        const created = try client.expect(.created, 5000);
        const id = try protocol.decodeCreated(created);

        const ap = try protocol.encodeAttach(&buf, id, 24, 80);
        try client.send(.attach, ap);
        const attached = try client.expect(.attached, 5000);
        const v2 = try protocol.decodeAttachedV2(attached);
        const pane_id = v2.pane_ids[0];

        // Send input that produces output stored in ring buffer
        const ip = try protocol.encodePaneInput(&buf, pane_id, "echo MIGRATE_MARKER_12345\n");
        try client.send(.pane_input, ip);
        posix.nanosleep(0, 200_000_000);
        break :blk id;
    };

    try env.migrateDaemon();

    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();
    try c2.send(.list, &.{});
    const list = try c2.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    _ = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqual(sid, entries[0].id);
    try testing.expect(entries[0].alive);
}

// ── Attach after migration ──

test "attach to migrated session works" {
    var env = try setup();
    defer teardown(&env);

    var buf: [4200]u8 = undefined;
    const sid = blk: {
        var client = try TestClient.connect(env.path());
        defer client.deinit();
        const cp = try protocol.encodeCreate(&buf, "reattach-test", 24, 80, "/tmp", "");
        try client.send(.create, cp);
        const created = try client.expect(.created, 5000);
        break :blk try protocol.decodeCreated(created);
    };

    try env.migrateDaemon();

    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try c2.send(.attach, ap);
    const attached = try c2.expect(.attached, 5000);
    const v2 = try protocol.decodeAttachedV2(attached);

    try testing.expect(v2.pane_count >= 1);
    try testing.expect(v2.pane_ids[0] >= 1);

    // Should be able to send input to the pane
    const ip = try protocol.encodePaneInput(&buf, v2.pane_ids[0], "echo ok\n");
    try c2.send(.pane_input, ip);
    posix.nanosleep(0, 50_000_000);

    try c2.send(.list, &.{});
    const list = try c2.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    _ = try protocol.decodeSessionList(list, &entries);
    try testing.expect(entries[0].alive);
}

// ── Corrupted upgrade data ──

test "corrupted upgrade data returns error" {
    const allocator = testing.allocator;
    var sessions: [32]?DaemonSession = .{null} ** 32;
    var next_sid: u32 = 0;
    var next_pid: u32 = 0;

    // Empty data
    try testing.expectError(error.EndOfStream, upgrade.deserialize(
        &.{}, &sessions, &next_sid, &next_pid, allocator,
    ));
    // Wrong magic
    try testing.expectError(error.InvalidMagic, upgrade.deserialize(
        "NOPE\x02\x00\x00\x00\x01\x00\x00\x00\x01\x00",
        &sessions, &next_sid, &next_pid, allocator,
    ));
    // Right magic, wrong version
    try testing.expectError(error.UnsupportedVersion, upgrade.deserialize(
        "ATUP\xFF\x00\x00\x00\x01\x00\x00\x00\x01\x00",
        &sessions, &next_sid, &next_pid, allocator,
    ));
    // Truncated after magic+version
    try testing.expectError(error.EndOfStream, upgrade.deserialize(
        "ATUP\x02", &sessions, &next_sid, &next_pid, allocator,
    ));
}

test "truncated session data in upgrade does not crash" {
    const allocator = testing.allocator;
    var sessions: [32]?DaemonSession = .{null} ** 32;
    var next_sid: u32 = 0;
    var next_pid: u32 = 0;

    // Valid header claiming 1 session but no session data following
    var data: [14]u8 = undefined;
    @memcpy(data[0..4], "ATUP");
    data[4] = 2; // format version
    std.mem.writeInt(u32, data[5..9], 5, .little);
    std.mem.writeInt(u32, data[9..13], 10, .little);
    data[13] = 1; // session_count = 1

    // Should not crash — deserialize breaks on read error, returns 0 restored
    const count = try upgrade.deserialize(&data, &sessions, &next_sid, &next_pid, allocator);
    try testing.expectEqual(@as(u8, 0), count);
    try testing.expectEqual(@as(u32, 5), next_sid);
    try testing.expectEqual(@as(u32, 10), next_pid);
}

// ── Double migration ──

test "session survives two consecutive migrations" {
    var env = try setup();
    defer teardown(&env);

    var buf: [4200]u8 = undefined;
    const sid = blk: {
        var client = try TestClient.connect(env.path());
        defer client.deinit();
        const cp = try protocol.encodeCreate(&buf, "double-migrate", 24, 80, "/tmp", "");
        try client.send(.create, cp);
        const created = try client.expect(.created, 5000);
        break :blk try protocol.decodeCreated(created);
    };

    try env.migrateDaemon();
    try env.migrateDaemon();

    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();
    try c2.send(.list, &.{});
    const list = try c2.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqual(@as(u16, 1), count);
    try testing.expectEqual(sid, entries[0].id);
    try testing.expectEqualStrings("double-migrate", entries[0].name);
    try testing.expect(entries[0].alive);
}
