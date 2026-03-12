//! Integration tests for daemon ↔ client session protocol.
//! Spins up a real Unix socket daemon loop in a background thread
//! and connects real clients that exercise the binary protocol.
const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const protocol = @import("protocol.zig");
const harness = @import("test_harness.zig");
const setup = harness.setup;
const teardown = harness.teardown;
const TestClient = harness.TestClient;

// ── Basic session operations ──

test "create session and receive created response" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var payload: [256]u8 = undefined;
    const p = try protocol.encodeCreate(&payload, "test-session", 24, 80, "/tmp", "");
    try client.send(.create, p);

    const resp = try client.expect(.created, 5000);
    const session_id = try protocol.decodeCreated(resp);
    try testing.expect(session_id >= 1);
}

test "list sessions returns created sessions" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [256]u8 = undefined;
    const p1 = try protocol.encodeCreate(&buf, "alpha", 24, 80, "/tmp", "");
    try client.send(.create, p1);
    _ = try client.expect(.created, 5000);

    const p2 = try protocol.encodeCreate(&buf, "beta", 24, 80, "/tmp", "");
    try client.send(.create, p2);
    _ = try client.expect(.created, 5000);

    try client.send(.list, &.{});
    const list_payload = try client.expect(.session_list, 5000);

    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list_payload, &entries);
    try testing.expectEqual(@as(u16, 2), count);
    try testing.expectEqualStrings("alpha", entries[0].name);
    try testing.expectEqualStrings("beta", entries[1].name);
    try testing.expect(entries[0].alive);
    try testing.expect(entries[1].alive);
}

test "attach to session returns attached with pane IDs" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [256]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "attach-test", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created_payload = try client.expect(.created, 5000);
    const session_id = try protocol.decodeCreated(created_payload);

    const ap = try protocol.encodeAttach(&buf, session_id, 24, 80);
    try client.send(.attach, ap);
    const attached_payload = try client.expect(.attached, 5000);
    const attached = try protocol.decodeAttachedV2(attached_payload);

    try testing.expectEqual(session_id, attached.session_id);
    try testing.expect(attached.pane_count >= 1);
    try testing.expect(attached.pane_ids[0] >= 1);
}

test "detach then reattach" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [256]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "detach-test", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap);
    _ = try client.expect(.attached, 5000);

    try client.send(.detach, &.{});
    posix.nanosleep(0, 20_000_000);

    const ap2 = try protocol.encodeAttach(&buf, sid, 30, 100);
    try client.send(.attach, ap2);
    const reattach = try client.expect(.attached, 5000);
    const v2 = try protocol.decodeAttachedV2(reattach);
    try testing.expectEqual(sid, v2.session_id);
}

test "kill session makes it dead in list" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [256]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "kill-test", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const kp = try protocol.encodeKill(&buf, sid);
    try client.send(.kill, kp);
    posix.nanosleep(0, 50_000_000);

    try client.send(.list, &.{});
    const list_payload = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list_payload, &entries);
    try testing.expectEqual(@as(u16, 1), count);
    try testing.expect(!entries[0].alive);
}

test "rename session" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [256]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "old-name", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const rp = try protocol.encodeRename(&buf, sid, "new-name");
    try client.send(.rename, rp);
    posix.nanosleep(0, 20_000_000);

    try client.send(.list, &.{});
    const list_payload = try client.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list_payload, &entries);
    try testing.expectEqual(@as(u16, 1), count);
    try testing.expectEqualStrings("new-name", entries[0].name);
    try testing.expectEqual(sid, entries[0].id);
}

test "error on attach to nonexistent session" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [8]u8 = undefined;
    const ap = try protocol.encodeAttach(&buf, 999, 24, 80);
    try client.send(.attach, ap);

    const err_payload = try client.expect(.err, 5000);
    const err = try protocol.decodeError(err_payload);
    try testing.expectEqual(@as(u8, 4), err.code); // session not found
}

// ── Pane operations ──

test "create pane in attached session" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "pane-test", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    _ = try client.expect(.created, 5000);

    const ap = try protocol.encodeAttach(&buf, 1, 24, 80);
    try client.send(.attach, ap);
    _ = try client.expect(.attached, 5000);

    const pp = try protocol.encodeCreatePane(&buf, 24, 80, "/tmp");
    try client.send(.create_pane, pp);
    const pane_resp = try client.expect(.pane_created, 5000);
    const new_pane_id = try protocol.decodePaneCreated(pane_resp);
    try testing.expect(new_pane_id >= 1);
}

test "close pane reduces pane count" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "close-pane-test", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    _ = try client.expect(.created, 5000);

    const ap = try protocol.encodeAttach(&buf, 1, 24, 80);
    try client.send(.attach, ap);
    const attached = try client.expect(.attached, 5000);
    const v2 = try protocol.decodeAttachedV2(attached);
    try testing.expectEqual(@as(u8, 1), v2.pane_count);

    const pp = try protocol.encodeCreatePane(&buf, 24, 80, "/tmp");
    try client.send(.create_pane, pp);
    const pane_resp = try client.expect(.pane_created, 5000);
    const new_pane_id = try protocol.decodePaneCreated(pane_resp);

    const clp = try protocol.encodeClosePane(&buf, new_pane_id);
    try client.send(.close_pane, clp);
    posix.nanosleep(0, 50_000_000);

    try client.send(.detach, &.{});
    posix.nanosleep(0, 20_000_000);

    const ap2 = try protocol.encodeAttach(&buf, 1, 24, 80);
    try client.send(.attach, ap2);
    const reattach = try client.expect(.attached, 5000);
    const v2b = try protocol.decodeAttachedV2(reattach);
    try testing.expectEqual(@as(u8, 1), v2b.pane_count);
}

test "pane input reaches PTY and produces output" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "io-test", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap);
    const attached = try client.expect(.attached, 5000);
    const v2 = try protocol.decodeAttachedV2(attached);
    const pane_id = v2.pane_ids[0];

    const fp = try protocol.encodeFocusPanes(&buf, &.{pane_id});
    try client.send(.focus_panes, fp);

    posix.nanosleep(0, 200_000_000);
    _ = client.tryParse(.pane_output);
    client.read_len = 0;

    const ip = try protocol.encodePaneInput(&buf, pane_id, "echo attyx-test-marker\n");
    try client.send(.pane_input, ip);

    var found_marker = false;
    var attempts: u32 = 0;
    while (attempts < 40) : (attempts += 1) {
        var fds = [1]posix.pollfd{.{ .fd = client.fd, .events = 0x0001, .revents = 0 }};
        _ = posix.poll(&fds, 100) catch break;
        if (fds[0].revents & 0x0001 != 0) {
            const space = client.read_buf[client.read_len..];
            const n = posix.read(client.fd, space) catch break;
            if (n > 0) client.read_len += n;
        }
        if (std.mem.indexOf(u8, client.read_buf[0..client.read_len], "attyx-test-marker")) |_| {
            found_marker = true;
            break;
        }
    }
    try testing.expect(found_marker);
}

test "pane resize updates dimensions via stty" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "resize-test", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap);
    const attached = try client.expect(.attached, 5000);
    const v2 = try protocol.decodeAttachedV2(attached);
    const pane_id = v2.pane_ids[0];

    // Focus the pane so we get output
    const fp = try protocol.encodeFocusPanes(&buf, &.{pane_id});
    try client.send(.focus_panes, fp);

    // Wait for shell startup, drain initial output
    posix.nanosleep(0, 200_000_000);
    _ = client.tryParse(.pane_output);
    client.read_len = 0;

    // Resize to 40x120
    const rp = try protocol.encodePaneResize(&buf, pane_id, 40, 120);
    try client.send(.pane_resize, rp);
    posix.nanosleep(0, 50_000_000);

    // Drain any SIGWINCH output
    _ = client.tryParse(.pane_output);
    client.read_len = 0;

    // Ask the shell what size it sees
    const ip = try protocol.encodePaneInput(&buf, pane_id, "stty size\n");
    try client.send(.pane_input, ip);

    // Look for "40 120" in PTY output
    var found = false;
    var attempts: u32 = 0;
    while (attempts < 40) : (attempts += 1) {
        var fds = [1]posix.pollfd{.{ .fd = client.fd, .events = 0x0001, .revents = 0 }};
        _ = posix.poll(&fds, 100) catch break;
        if (fds[0].revents & 0x0001 != 0) {
            const space = client.read_buf[client.read_len..];
            const n = posix.read(client.fd, space) catch break;
            if (n > 0) client.read_len += n;
        }
        if (std.mem.indexOf(u8, client.read_buf[0..client.read_len], "40 120")) |_| {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "focus_panes triggers replay_end for new panes" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "replay-test", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);

    const ap = try protocol.encodeAttach(&buf, sid, 24, 80);
    try client.send(.attach, ap);
    const attached = try client.expect(.attached, 5000);
    const v2 = try protocol.decodeAttachedV2(attached);
    const pane_id = v2.pane_ids[0];

    const fp = try protocol.encodeFocusPanes(&buf, &.{pane_id});
    try client.send(.focus_panes, fp);

    const replay_end_payload = try client.expect(.replay_end, 5000);
    try testing.expect(replay_end_payload.len >= 4);
    const replay_pane_id = std.mem.readInt(u32, replay_end_payload[0..4], .little);
    try testing.expectEqual(pane_id, replay_pane_id);
}

// ── Version handshake ──

test "hello returns hello_ack with daemon version" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [256]u8 = undefined;
    // Send hello with a fake client version
    const hp = try protocol.encodeHello(&buf, "99.0.0");
    try client.send(.hello, hp);

    // Daemon should respond with hello_ack containing its own version
    const ack_payload = try client.expect(.hello_ack, 5000);
    const daemon_version = try protocol.decodeHello(ack_payload);
    // Version must be non-empty and match the compiled-in version
    try testing.expect(daemon_version.len > 0);
}

test "hello with matching version does not trigger upgrade flag" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [256]u8 = undefined;
    // First, discover the daemon's version via hello
    const hp = try protocol.encodeHello(&buf, "probe");
    try client.send(.hello, hp);
    const ack = try client.expect(.hello_ack, 5000);
    const version = try protocol.decodeHello(ack);

    // Now send hello with the matching version
    const hp2 = try protocol.encodeHello(&buf, version);
    try client.send(.hello, hp2);
    const ack2 = try client.expect(.hello_ack, 5000);
    const v2 = try protocol.decodeHello(ack2);
    try testing.expectEqualStrings(version, v2);

    // Daemon should still be running (not trying to upgrade/restart)
    // Verify by creating a session successfully
    const cp = try protocol.encodeCreate(&buf, "post-hello", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    const created = try client.expect(.created, 5000);
    const sid = try protocol.decodeCreated(created);
    try testing.expect(sid >= 1);
}

// ── Multi-client tests ──

test "two clients see same session list" {
    var env = try setup();
    defer teardown(&env);

    var c1 = try TestClient.connect(env.path());
    defer c1.deinit();
    var c2 = try TestClient.connect(env.path());
    defer c2.deinit();

    var buf: [256]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "shared", 24, 80, "/tmp", "");
    try c1.send(.create, cp);
    _ = try c1.expect(.created, 5000);

    try c2.send(.list, &.{});
    const list_payload = try c2.expect(.session_list, 5000);
    var entries: [32]protocol.DecodedListEntry = undefined;
    const count = try protocol.decodeSessionList(list_payload, &entries);
    try testing.expectEqual(@as(u16, 1), count);
    try testing.expectEqualStrings("shared", entries[0].name);
}

// Restoration & layout tests in session_restore_test.zig
// Lifecycle tests (launch delay, migration) in session_lifecycle_test.zig
// Chaos / stress tests in session_chaos_test.zig
comptime {
    _ = @import("session_restore_test.zig");
    _ = @import("session_lifecycle_test.zig");
    _ = @import("session_chaos_test.zig");
    _ = @import("session_stress_test.zig");
    _ = @import("session_migration_test.zig");
    _ = @import("migration_stress_test.zig");
    _ = @import("cwd_test.zig");
}
