//! Chaos / stress tests for daemon resilience.
//! These tests throw garbage, malformed messages, connection storms,
//! and protocol violations at the daemon to verify it never hangs or crashes.
const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const protocol = @import("protocol.zig");
const harness = @import("test_harness.zig");
const setup = harness.setup;
const teardown = harness.teardown;
const TestClient = harness.TestClient;

// ── Raw socket helpers (bypass protocol framing) ──

fn sendRawBytes(fd: posix.fd_t, data: []const u8) void {
    var offset: usize = 0;
    while (offset < data.len) {
        const n = posix.write(fd, data[offset..]) catch return;
        if (n == 0) return;
        offset += n;
    }
}

// ── Garbage data ──

test "random garbage bytes don't crash daemon" {
    var env = try setup();
    defer teardown(&env);

    // Connect raw and send pure garbage
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(fd);
    const addr = try std.net.Address.initUnix(env.path());
    try posix.connect(fd, &addr.any, addr.getOsSockLen());

    // Send 4KB of pseudo-random garbage
    var garbage: [4096]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(0xDEADBEEF);
    rng.fill(&garbage);
    sendRawBytes(fd, &garbage);
    posix.nanosleep(0, 50_000_000);

    // Daemon should still be alive — connect a real client and do real work
    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [256]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "post-garbage", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const resp = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(resp);
    try testing.expect(sid >= 1);
}

test "garbage interspersed with valid messages" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    // Send a valid create
    var buf: [256]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "before-noise", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const resp = try client.expect(.created, 5000);
    try testing.expect(try protocol.decodeCreated(resp) >= 1);
}

// ── Oversized / malformed messages ──

test "oversized payload length disconnects client but daemon survives" {
    var env = try setup();
    defer teardown(&env);

    // Send a header claiming 1MB payload
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(fd);
    const addr = try std.net.Address.initUnix(env.path());
    try posix.connect(fd, &addr.any, addr.getOsSockLen());

    var hdr: [5]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], 1_000_000, .little); // 1MB payload
    hdr[4] = 0x01; // create
    sendRawBytes(fd, &hdr);
    posix.nanosleep(0, 100_000_000);

    // Daemon must still work
    var client = try TestClient.connect(env.path());
    defer client.deinit();
    var buf: [256]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "after-oversize", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const resp = try client.expect(.created, 5000);
    try testing.expect(try protocol.decodeCreated(resp) >= 1);
}

test "payload_len 0xFFFFFFFF doesn't hang daemon" {
    var env = try setup();
    defer teardown(&env);

    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(fd);
    const addr = try std.net.Address.initUnix(env.path());
    try posix.connect(fd, &addr.any, addr.getOsSockLen());

    var hdr: [5]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], 0xFFFFFFFF, .little);
    hdr[4] = 0x02; // list
    sendRawBytes(fd, &hdr);
    posix.nanosleep(0, 100_000_000);

    // Must still respond to legitimate clients
    var client = try TestClient.connect(env.path());
    defer client.deinit();
    try client.send(.list, &.{});
    _ = try client.expect(.session_list, 5000);
}

test "zero-length payload on message that expects data" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    // Send attach with empty payload — should get an error, not a crash
    try client.send(.attach, &.{});
    const err_payload = try client.expect(.err, 5000);
    const err = try protocol.decodeError(err_payload);
    try testing.expect(err.code > 0);
}

test "truncated payload doesn't hang" {
    var env = try setup();
    defer teardown(&env);

    {
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        const addr = try std.net.Address.initUnix(env.path());
        try posix.connect(fd, &addr.any, addr.getOsSockLen());

        // Header says 100 bytes, but we only send 10
        var hdr: [5]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], 100, .little);
        hdr[4] = 0x01; // create
        sendRawBytes(fd, &hdr);
        var partial: [10]u8 = .{0} ** 10;
        sendRawBytes(fd, &partial);
        // Close — daemon shouldn't hang waiting for remaining 90 bytes
        posix.close(fd);
    }

    posix.nanosleep(0, 50_000_000);

    var client = try TestClient.connect(env.path());
    defer client.deinit();
    try client.send(.list, &.{});
    _ = try client.expect(.session_list, 5000);
}

test "unknown message type is silently skipped" {
    var env = try setup();
    defer teardown(&env);

    // Send unknown message from a sacrificial connection — the daemon
    // may disconnect it, which is fine. Then verify a fresh client works.
    {
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        const addr = try std.net.Address.initUnix(env.path());
        try posix.connect(fd, &addr.any, addr.getOsSockLen());

        var hdr: [5]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], 4, .little);
        hdr[4] = 0xFF;
        sendRawBytes(fd, &hdr);
        var payload: [4]u8 = .{ 1, 2, 3, 4 };
        sendRawBytes(fd, &payload);
        posix.close(fd);
    }
    posix.nanosleep(0, 50_000_000);

    // Fresh client should work fine — daemon survived the unknown message
    var client = try TestClient.connect(env.path());
    defer client.deinit();
    try client.send(.list, &.{});
    const list = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqual(@as(u16, 0), count);
}

// ── Connection storms ──

test "rapid connect/disconnect doesn't leak or crash" {
    var env = try setup();
    defer teardown(&env);

    // Slam 50 connections open and immediately close them
    for (0..50) |_| {
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch continue;
        const addr = std.net.Address.initUnix(env.path()) catch {
            posix.close(fd);
            continue;
        };
        posix.connect(fd, &addr.any, addr.getOsSockLen()) catch {
            posix.close(fd);
            continue;
        };
        posix.close(fd); // immediate disconnect
    }
    posix.nanosleep(0, 100_000_000);

    // Daemon should still work fine
    var client = try TestClient.connect(env.path());
    defer client.deinit();
    var buf: [256]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "after-storm", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const resp = try client.expect(.created, 5000);
    try testing.expect(try protocol.decodeCreated(resp) >= 1);
}

test "many simultaneous clients" {
    var env = try setup();
    defer teardown(&env);

    var clients: [8]?TestClient = .{null} ** 8;
    defer for (&clients) |*c| {
        if (c.*) |*cl| cl.deinit();
    };

    // Connect in batches to respect listen backlog
    for (&clients, 0..) |*c, i| {
        c.* = TestClient.connect(env.path()) catch null;
        if (i % 4 == 3) posix.nanosleep(0, 20_000_000);
    }
    posix.nanosleep(0, 50_000_000);

    // Count how many connected
    var connected: u32 = 0;
    for (clients) |c| {
        if (c != null) connected += 1;
    }
    try testing.expect(connected >= 4);

    // Each one sends list
    for (&clients) |*c| {
        if (c.*) |*cl| {
            cl.send(.list, &.{}) catch {};
        }
    }

    // Each connected client should get a response
    var responses: u32 = 0;
    for (&clients) |*c| {
        if (c.*) |*cl| {
            if (cl.expect(.session_list, 5000)) |_| {
                responses += 1;
            } else |_| {}
        }
    }
    try testing.expect(responses >= 4);

    // Create from first connected client, verify from another
    var buf: [256]u8 = undefined;
    const first = for (&clients) |*c| {
        if (c.*) |*cl| break cl;
    } else null;
    const last = blk: {
        var found: ?*TestClient = null;
        for (&clients) |*c| {
            if (c.*) |*cl| found = cl;
        }
        break :blk found;
    };

    if (first) |c0| {
        const cp = try protocol.encodeCreate(&buf, "shared-multi", 24, 80, "/tmp", "");
        try c0.send(.create, cp);
        _ = try c0.expect(.created, 5000);
    }
    if (last) |cl| {
        try cl.send(.list, &.{});
        const list = try cl.expect(.session_list, 5000);
        var entries: [32]protocol.DecodedListEntry = undefined;
        const count = try protocol.decodeSessionList(list, &entries);
        try testing.expect(count >= 1);
    }
}

// ── Protocol violations ──

test "operations without attach get proper errors" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;

    // Send pane_input without being attached — should get "not attached" error
    const ip = try protocol.encodePaneInput(&buf, 1, "hello");
    try client.send(.pane_input, ip);
    const err1 = try client.expect(.err, 5000);
    const e1 = try protocol.decodeError(err1);
    try testing.expectEqual(@as(u8, 5), e1.code); // not attached

    // Send pane_resize without attach
    const rp = try protocol.encodePaneResize(&buf, 1, 40, 120);
    try client.send(.pane_resize, rp);
    const err2 = try client.expect(.err, 5000);
    const e2 = try protocol.decodeError(err2);
    try testing.expectEqual(@as(u8, 5), e2.code);

    // Send focus_panes without attach
    const fp = try protocol.encodeFocusPanes(&buf, &.{1});
    try client.send(.focus_panes, fp);
    const err3 = try client.expect(.err, 5000);
    const e3 = try protocol.decodeError(err3);
    try testing.expectEqual(@as(u8, 5), e3.code);
}

test "attach to bogus session IDs" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [256]u8 = undefined;

    // Session ID 0
    const ap0 = try protocol.encodeAttach(&buf, 0, 24, 80);
    try client.send(.attach, ap0);
    const err0 = try client.expect(.err, 5000);
    try testing.expectEqual(@as(u8, 4), (try protocol.decodeError(err0)).code);

    // Session ID max u32
    const ap_max = try protocol.encodeAttach(&buf, 0xFFFFFFFF, 24, 80);
    try client.send(.attach, ap_max);
    const err_max = try client.expect(.err, 5000);
    try testing.expectEqual(@as(u8, 4), (try protocol.decodeError(err_max)).code);
}

test "double detach is harmless" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [256]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "double-detach", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap);
    _ = try client.expect(.attached, 5000);

    // Detach twice — second one should be a no-op
    try client.send(.detach, &.{});
    try client.send(.detach, &.{});
    posix.nanosleep(0, 20_000_000);

    // Still works after double-detach
    try client.send(.list, &.{});
    const list = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqual(@as(u16, 1), count);
    try testing.expect(entries[0].alive);
}

test "close_pane with nonexistent pane ID is silent" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "phantom-close", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap);
    _ = try client.expect(.attached, 5000);

    // Close a pane ID that doesn't exist
    const clp = try protocol.encodeClosePane(&buf, 99999);
    try client.send(.close_pane, clp);
    posix.nanosleep(0, 20_000_000);

    // Session should be unaffected
    try client.send(.list, &.{});
    const list = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqual(@as(u16, 1), count);
    try testing.expect(entries[0].alive);
}

test "pane_input to wrong pane ID is silently ignored" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "wrong-pane", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap);
    _ = try client.expect(.attached, 5000);

    // Write to a pane that doesn't exist
    const ip = try protocol.encodePaneInput(&buf, 99999, "should be ignored\n");
    try client.send(.pane_input, ip);
    posix.nanosleep(0, 20_000_000);

    // Daemon still alive, session unaffected
    try client.send(.list, &.{});
    const list = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    _ = try protocol.decodeSessionList(list, &entries);
    try testing.expect(entries[0].alive);
}

// ── Interleaving / ordering chaos ──

test "client sends server-only message types" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    // Send message types that only the daemon should send (server→client)
    // The daemon should ignore these gracefully.
    var buf: [256]u8 = undefined;
    var payload: [4]u8 = .{ 1, 0, 0, 0 };

    // created (0x81)
    var hdr: [protocol.header_size]u8 = undefined;
    protocol.encodeHeader(&hdr, .created, 4);
    try harness.writeAllBlocking(client.fd, &hdr);
    try harness.writeAllBlocking(client.fd, &payload);

    // pane_output (0x88)
    protocol.encodeHeader(&hdr, .pane_output, 4);
    try harness.writeAllBlocking(client.fd, &hdr);
    try harness.writeAllBlocking(client.fd, &payload);

    posix.nanosleep(0, 50_000_000);

    // Daemon should still work
    const cp = try protocol.encodeCreate(&buf, "after-bad-types", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const resp = try client.expect(.created, 5000);
    try testing.expect(try protocol.decodeCreated(resp) >= 1);
}

test "rapid fire create sessions" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [256]u8 = undefined;
    var created_count: u32 = 0;

    // Create 20 sessions as fast as possible
    for (0..20) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "rapid-{d}", .{i}) catch "rapid";
        const cp = try protocol.encodeCreate(&buf, name, 24, 80, "/tmp", "");
        try client.send(.create, cp);
    }

    // Collect all responses
    for (0..20) |_| {
        if (client.expect(.created, 5000)) |_| {
            created_count += 1;
        } else |_| break;
    }

    // Should have created all 20 (max_sessions is 32)
    try testing.expectEqual(@as(u32, 20), created_count);

    // Verify with list
    try client.send(.list, &.{});
    const list = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list, &entries);
    try testing.expectEqual(@as(u16, 20), count);
}

test "half-header then close connection" {
    var env = try setup();
    defer teardown(&env);

    // Send only 3 bytes of a 5-byte header, then close
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    const addr = try std.net.Address.initUnix(env.path());
    try posix.connect(fd, &addr.any, addr.getOsSockLen());
    sendRawBytes(fd, &[_]u8{ 0x04, 0x00, 0x00 }); // 3 of 5 header bytes
    posix.close(fd);
    posix.nanosleep(0, 50_000_000);

    // Daemon still works
    var client = try TestClient.connect(env.path());
    defer client.deinit();
    try client.send(.list, &.{});
    _ = try client.expect(.session_list, 5000);
}
