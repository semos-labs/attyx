//! Tests for working directory (--working-directory / -d) handling.
//! Verifies that the cwd is correctly propagated to spawned PTY processes
//! in both direct (no daemon) and daemon-backed session modes.
const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const protocol = @import("protocol.zig");
const harness = @import("test_harness.zig");
const setup = harness.setup;
const teardown = harness.teardown;
const TestClient = harness.TestClient;
const Pty = @import("../pty.zig").Pty;

// ── Direct PTY tests (no daemon) ──

test "direct pty: explicit cwd sets child working directory" {
    var pty = try Pty.spawn(.{
        .rows = 24,
        .cols = 80,
        .cwd = "/tmp",
        .argv = &.{ "/bin/sh", "-c", "pwd" },
        .capture_stdout = true,
        .skip_shell_integration = true,
    });
    defer pty.deinit();

    const output = try waitForOutput(&pty, 5000);
    const trimmed = std.mem.trim(u8, output, " \t\n\r");
    // macOS resolves /tmp → /private/tmp
    try testing.expect(
        std.mem.eql(u8, trimmed, "/tmp") or std.mem.eql(u8, trimmed, "/private/tmp"),
    );
}

test "direct pty: null cwd falls back to HOME" {
    const home = std.posix.getenv("HOME") orelse return; // skip if no HOME
    var pty = try Pty.spawn(.{
        .rows = 24,
        .cols = 80,
        .cwd = null,
        .argv = &.{ "/bin/sh", "-c", "pwd" },
        .capture_stdout = true,
        .skip_shell_integration = true,
    });
    defer pty.deinit();

    const output = try waitForOutput(&pty, 5000);
    const trimmed = std.mem.trim(u8, output, " \t\n\r");
    try testing.expectEqualStrings(home, trimmed);
}

test "direct pty: cwd with spaces works" {
    // Create a temp dir with a space in the name
    const dir_path = "/tmp/attyx test cwd";
    std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    defer std.fs.deleteDirAbsolute(dir_path) catch {};

    var pty = try Pty.spawn(.{
        .rows = 24,
        .cols = 80,
        .cwd = dir_path,
        .argv = &.{ "/bin/sh", "-c", "pwd" },
        .capture_stdout = true,
        .skip_shell_integration = true,
    });
    defer pty.deinit();

    const output = try waitForOutput(&pty, 5000);
    const trimmed = std.mem.trim(u8, output, " \t\n\r");
    // macOS may resolve /tmp → /private/tmp
    try testing.expect(
        std.mem.eql(u8, trimmed, dir_path) or
            std.mem.eql(u8, trimmed, "/private/tmp/attyx test cwd"),
    );
}

test "direct pty: nonexistent cwd falls back gracefully" {
    // When cwd doesn't exist, chdir fails silently and the child
    // inherits the parent's cwd. The process should still spawn.
    var pty = try Pty.spawn(.{
        .rows = 24,
        .cols = 80,
        .cwd = "/nonexistent/path/that/should/not/exist",
        .argv = &.{ "/bin/sh", "-c", "echo ok" },
        .capture_stdout = true,
        .skip_shell_integration = true,
    });
    defer pty.deinit();

    const output = try waitForOutput(&pty, 5000);
    const trimmed = std.mem.trim(u8, output, " \t\n\r");
    try testing.expectEqualStrings("ok", trimmed);
}

// ── Daemon session tests ──

test "daemon: session created with cwd spawns shell in that directory" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "cwd-test", 24, 80, "/tmp", "");
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

    // Wait for shell startup, drain initial output
    posix.nanosleep(0, 200_000_000);
    _ = client.tryParse(.pane_output);
    client.read_len = 0;

    // Ask the shell for its working directory
    const ip = try protocol.encodePaneInput(&buf, pane_id, "pwd\n");
    try client.send(.pane_input, ip);

    // /tmp may resolve to /private/tmp on macOS
    const found = try pollForOutput(&client, &.{ "/tmp", "/private/tmp" }, 4000);
    try testing.expect(found);
}

test "daemon: session with home cwd spawns in home" {
    const home = std.posix.getenv("HOME") orelse return;

    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    const cp = try protocol.encodeCreate(&buf, "home-cwd", 24, 80, home, "");
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

    const ip = try protocol.encodePaneInput(&buf, pane_id, "pwd\n");
    try client.send(.pane_input, ip);

    const found = try pollForOutput(&client, &.{home}, 4000);
    try testing.expect(found);
}

test "daemon: new pane inherits session cwd" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;
    // Create session with /tmp as cwd
    const cp = try protocol.encodeCreate(&buf, "pane-cwd", 24, 80, "/tmp", "");
    try client.send(.create, cp);
    _ = try client.expect(.created, 5000);

    const ap = try protocol.encodeAttach(&buf, 1, 24, 80);
    try client.send(.attach, ap);
    _ = try client.expect(.attached, 5000);

    // Create a second pane — should inherit session cwd (/tmp)
    const pp = try protocol.encodeCreatePane(&buf, 24, 80, "/tmp");
    try client.send(.create_pane, pp);
    const pane_resp = try client.expect(.pane_created, 5000);
    const new_pane_id = try protocol.decodePaneCreated(pane_resp);

    // Focus the new pane
    const fp = try protocol.encodeFocusPanes(&buf, &.{new_pane_id});
    try client.send(.focus_panes, fp);

    posix.nanosleep(0, 200_000_000);
    _ = client.tryParse(.pane_output);
    client.read_len = 0;

    const ip = try protocol.encodePaneInput(&buf, new_pane_id, "pwd\n");
    try client.send(.pane_input, ip);

    const found = try pollForOutput(&client, &.{ "/tmp", "/private/tmp" }, 4000);
    try testing.expect(found);
}

test "daemon: two sessions with different cwds" {
    var env = try setup();
    defer teardown(&env);

    var client = try TestClient.connect(env.path());
    defer client.deinit();

    var buf: [4200]u8 = undefined;

    // Session 1 in /tmp
    const cp1 = try protocol.encodeCreate(&buf, "session-tmp", 24, 80, "/tmp", "");
    try client.send(.create, cp1);
    const created1 = try client.expect(.created, 5000);
    const sid1 = try protocol.decodeCreated(created1);

    // Session 2 in /var
    const cp2 = try protocol.encodeCreate(&buf, "session-var", 24, 80, "/var", "");
    try client.send(.create, cp2);
    const created2 = try client.expect(.created, 5000);
    const sid2 = try protocol.decodeCreated(created2);

    // Attach to session 1, verify cwd
    {
        const ap = try protocol.encodeAttach(&buf, sid1, 24, 80);
        try client.send(.attach, ap);
        const attached = try client.expect(.attached, 5000);
        const v2 = try protocol.decodeAttachedV2(attached);
        const pane_id = v2.pane_ids[0];

        const fp = try protocol.encodeFocusPanes(&buf, &.{pane_id});
        try client.send(.focus_panes, fp);

        posix.nanosleep(0, 200_000_000);
        _ = client.tryParse(.pane_output);
        client.read_len = 0;

        const ip = try protocol.encodePaneInput(&buf, pane_id, "pwd\n");
        try client.send(.pane_input, ip);

        const found = try pollForOutput(&client, &.{ "/tmp", "/private/tmp" }, 4000);
        try testing.expect(found);
    }

    // Detach, then attach to session 2, verify different cwd
    try client.send(.detach, &.{});
    posix.nanosleep(0, 50_000_000);
    client.read_len = 0;

    {
        const ap = try protocol.encodeAttach(&buf, sid2, 24, 80);
        try client.send(.attach, ap);
        const attached = try client.expect(.attached, 5000);
        const v2 = try protocol.decodeAttachedV2(attached);
        const pane_id = v2.pane_ids[0];

        const fp = try protocol.encodeFocusPanes(&buf, &.{pane_id});
        try client.send(.focus_panes, fp);

        posix.nanosleep(0, 200_000_000);
        _ = client.tryParse(.pane_output);
        client.read_len = 0;

        const ip = try protocol.encodePaneInput(&buf, pane_id, "pwd\n");
        try client.send(.pane_input, ip);

        const found = try pollForOutput(&client, &.{ "/var", "/private/var" }, 4000);
        try testing.expect(found);
    }
}

// ── CLI parsing tests ──

test "cli: -d sets working_directory" {
    const cli = @import("../../config/cli.zig");
    const result = cli.parse(&.{ "attyx", "-d", "/some/path" });
    try testing.expect(result.config.working_directory != null);
    try testing.expectEqualStrings("/some/path", result.config.working_directory.?);
}

test "cli: --working-directory sets working_directory" {
    const cli = @import("../../config/cli.zig");
    const result = cli.parse(&.{ "attyx", "--working-directory", "/another/path" });
    try testing.expect(result.config.working_directory != null);
    try testing.expectEqualStrings("/another/path", result.config.working_directory.?);
}

test "cli: no -d leaves working_directory null" {
    const cli = @import("../../config/cli.zig");
    const result = cli.parse(&.{"attyx"});
    try testing.expect(result.config.working_directory == null);
}

test "cli: applyCliOverrides applies -d" {
    const cli = @import("../../config/cli.zig");
    const config_mod = @import("../../config/config.zig");
    var config = config_mod.AppConfig{};
    cli.applyCliOverrides(&.{ "attyx", "-d", "/override/path" }, &config);
    try testing.expect(config.working_directory != null);
    try testing.expectEqualStrings("/override/path", config.working_directory.?);
}

test "cli: applyCliOverrides -d overrides existing working_directory" {
    const cli = @import("../../config/cli.zig");
    const config_mod = @import("../../config/config.zig");
    var config = config_mod.AppConfig{};
    config.working_directory = "/original";
    cli.applyCliOverrides(&.{ "attyx", "--working-directory", "/new" }, &config);
    try testing.expectEqualStrings("/new", config.working_directory.?);
}

// ── Helpers ──

/// Wait for captured stdout output from a PTY process. Returns the output string.
fn waitForOutput(pty: *Pty, timeout_ms: u32) ![]const u8 {
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    var elapsed: u32 = 0;
    const poll_interval: u32 = 50;

    while (elapsed < timeout_ms) {
        if (pty.stdout_read_fd >= 0) {
            var fds = [1]posix.pollfd{.{
                .fd = pty.stdout_read_fd,
                .events = 0x0001,
                .revents = 0,
            }};
            _ = posix.poll(&fds, @intCast(poll_interval)) catch break;
            if (fds[0].revents & 0x0001 != 0) {
                const n = posix.read(pty.stdout_read_fd, buf[total..]) catch break;
                if (n == 0) break; // EOF — child exited
                total += n;
                // Check if we have a complete line
                if (std.mem.indexOf(u8, buf[0..total], "\n") != null) break;
            } else {
                elapsed += poll_interval;
            }
        } else {
            break;
        }
    }
    if (total == 0) return error.NoOutput;
    return buf[0..total];
}

/// Poll a daemon client's socket for PTY output containing any of the expected strings.
fn pollForOutput(client: *TestClient, expected: []const []const u8, timeout_ms: u32) !bool {
    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) {
        var fds = [1]posix.pollfd{.{ .fd = client.fd, .events = 0x0001, .revents = 0 }};
        _ = posix.poll(&fds, 100) catch break;
        if (fds[0].revents & 0x0001 != 0) {
            const space = client.read_buf[client.read_len..];
            const n = posix.read(client.fd, space) catch break;
            if (n > 0) client.read_len += n;
        } else {
            elapsed += 100;
        }
        for (expected) |needle| {
            if (std.mem.indexOf(u8, client.read_buf[0..client.read_len], needle) != null)
                return true;
        }
    }
    return false;
}
